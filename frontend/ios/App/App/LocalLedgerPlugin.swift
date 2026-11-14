import Capacitor
import Darwin
import Foundation
import UIKit
import UniformTypeIdentifiers

class LedgerViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(LocalLedgerPlugin())
    }
}

@objc(LocalLedgerPlugin)
class LocalLedgerPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    let identifier = "LocalLedgerPlugin"
    let jsName = "LocalLedger"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startup", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "changeWorkout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "history", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "importBackup", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exportBackup", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "restoreRecovery", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "automaticBackupStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listAutomaticBackups", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "restoreListedBackup", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteListedBackup", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "chooseBackupFolder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAutomaticBackup", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkAutomaticBackup", returnType: CAPPluginReturnPromise)
    ]

    private let storage = DispatchQueue(label: "iRostam.storage")
    private var pickerCall: CAPPluginCall?
    private var exportURL: URL?
    private var folderCall: CAPPluginCall?
    private var prefs: UserDefaults { .standard }

    private func ledger() throws -> LocalLedger {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        return LocalLedger(databaseURL: directory.appendingPathComponent("irostam.sqlite3"))
    }

    @objc func startup(_ call: CAPPluginCall) {
        storage.async {
            do {
                let ledger = try self.ledger()
                if call.getBool("create") == true {
                    try ledger.initialize()
                }
                let state = try ledger.state()
                if state == .imported { do { try self.saveAutomaticIfDue(ledger) } catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") } }
                let timezone = TimeZone.current
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timezone
                formatter.dateFormat = "yyyy-MM-dd"
                var result: [String: Any] = [
                    "state": state.rawValue,
                    "today": formatter.string(from: Date()),
                    "timezone": timezone.identifier,
                    "signingExpiresAt": AppDelegate.signingExpiry.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
                ]
                if state == .imported {
                    try ledger.prepareWorkouts()
                    let counts = try ledger.importedCounts()
                    result["workouts"] = counts.workouts
                    result["sets"] = counts.sets
                    result["photos"] = counts.photos
                    result["hasRecoveryBackup"] = ledger.hasRecoveryBackup
                }
                call.resolve(result)
            } catch {
                call.reject("Could not open the local iRostam database.")
            }
        }
    }

    @objc func history(_ call: CAPPluginCall) {
        guard let path = call.getString("path") else {
            call.reject("Missing local history path.")
            return
        }
        storage.async {
            do {
                call.resolve(try self.ledger().history(path))
            } catch {
                call.reject("Could not read this entry from the local database.")
            }
        }
    }

    @objc func changeWorkout(_ call: CAPPluginCall) {
        guard let path = call.getString("path"), let method = call.getString("method") else {
            call.reject("Missing workout action.")
            return
        }
        let payload = call.getObject("payload") ?? [:]
        storage.async {
            do {
                let ledger = try self.ledger()
                let result = try ledger.changeWorkout(path, method: method, payload: payload)
                self.prefs.set(self.prefs.integer(forKey: "ledgerRevision") + 1, forKey: "ledgerRevision")
                do { try self.saveAutomaticIfDue(ledger) } catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") }
                call.resolve(result)
            } catch let error as LocalLedger.WorkoutError {
                call.reject(error.localizedDescription)
            } catch {
                call.reject("Could not save this workout change.")
            }
        }
    }

    @objc func automaticBackupStatus(_ call: CAPPluginCall) { call.resolve(status()) }
    @objc func listAutomaticBackups(_ call: CAPPluginCall) {
        storage.async {
            guard let data = self.prefs.data(forKey: "autoBackupBookmark") else { call.resolve(["files": []]); return }
            var stale = false
            do {
                let folder = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard folder.startAccessingSecurityScopedResource() else { throw LocalLedger.Failure.database }
                defer { folder.stopAccessingSecurityScopedResource() }
                var coordinationError: NSError?, result: [[String: Any]] = []
                NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { location in
                    result = (try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]))?.compactMap { url in
                        guard !url.lastPathComponent.hasPrefix("."), url.pathExtension.lowercased() == "sqlite3",
                              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        return ["name": url.lastPathComponent, "category": url.lastPathComponent.hasPrefix("iRostam-auto-") ? "Automatic" : "On-demand",
                                "modifiedAt": values?.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                                "sizeBytes": values?.fileSize ?? 0]
                    } ?? []
                }
                if let coordinationError { throw coordinationError }
                call.resolve(["files": result])
            } catch { call.reject("Could not list backups in the selected folder. Check its access or choose it again.") }
        }
    }
    @objc func restoreListedBackup(_ call: CAPPluginCall) {
        guard let name = call.getString("name"), !name.contains("/"), name.hasSuffix(".sqlite3") else { call.reject("Choose a listed backup."); return }
        storage.async {
            do {
                guard let data = self.prefs.data(forKey: "autoBackupBookmark") else { throw LocalLedger.Failure.database }
                var stale = false
                let folder = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard folder.startAccessingSecurityScopedResource() else { throw LocalLedger.Failure.database }
                defer { folder.stopAccessingSecurityScopedResource() }
                let source = folder.appendingPathComponent(name)
                var coordinationError: NSError?, outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                    outcome = Result { try self.ledger().importBackup(from: url, replacing: true) }
                }
                if let coordinationError { throw coordinationError }; try outcome?.get()
                self.prefs.set(self.prefs.integer(forKey: "ledgerRevision") + 1, forKey: "ledgerRevision")
                do { try self.saveAutomaticIfDue(self.ledger()) } catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") }
                call.resolve(["imported": true])
            } catch { call.reject((error as? LocalLedger.Failure)?.localizedDescription ?? "Could not restore this backup.") }
        }
    }
    @objc func deleteListedBackup(_ call: CAPPluginCall) {
        guard let name = call.getString("name"), !name.contains("/"), name.hasSuffix(".sqlite3") else { call.reject("Choose a listed backup."); return }
        storage.async {
            do {
                guard let data = self.prefs.data(forKey: "autoBackupBookmark") else { throw LocalLedger.Failure.database }
                var stale = false
                let folder = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard folder.startAccessingSecurityScopedResource() else { throw LocalLedger.Failure.database }
                defer { folder.stopAccessingSecurityScopedResource() }
                let file = folder.appendingPathComponent(name); var coordinationError: NSError?, operationError: Error?
                NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &coordinationError) { url in do { try FileManager.default.removeItem(at: url) } catch { operationError = error } }
                if let coordinationError { throw coordinationError }; if let operationError { throw operationError }
                call.resolve(["deleted": true])
            } catch { call.reject("Could not delete this backup.") }
        }
    }
    @objc func checkAutomaticBackup(_ call: CAPPluginCall) {
        storage.async { do { try self.saveAutomaticIfDue(self.ledger()); call.resolve(self.status()) }
            catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError"); call.resolve(self.status()) } }
    }
    @objc func setAutomaticBackup(_ call: CAPPluginCall) {
        storage.async {
            self.prefs.set(call.getBool("enabled") ?? false, forKey: "autoBackupEnabled")
            let retention = max(1, call.getInt("retention") ?? self.retention)
            self.prefs.set(retention, forKey: "autoBackupRetention")
            if call.getBool("enabled") == true { do { try self.saveAutomaticIfDue(self.ledger()) } catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") } }
            call.resolve(self.status())
        }
    }
    @objc func chooseBackupFolder(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.pickerCall == nil, let presenter = self.bridge?.viewController else { call.reject("Could not open Files."); return }
            self.pickerCall = call; self.folderCall = call
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder]); picker.delegate = self; presenter.present(picker, animated: true)
        }
    }
    private func status() -> [String: Any] {
        let folderName = prefs.string(forKey: "autoBackupFolderName") ?? prefs.data(forKey: "autoBackupBookmark").flatMap { data -> String? in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale).lastPathComponent
        }
        return ["enabled": prefs.bool(forKey: "autoBackupEnabled"), "retention": retention,
         "lastSaved": prefs.string(forKey: "autoBackupLastSaved") as Any? ?? NSNull(), "error": prefs.string(forKey: "autoBackupError") as Any? ?? NSNull(),
         "hasFolder": prefs.data(forKey: "autoBackupBookmark") != nil, "folderName": folderName as Any? ?? NSNull()]
    }
    private var retention: Int {
        if let value = prefs.object(forKey: "autoBackupRetention") as? Int { return max(1, value) }
        if let old = prefs.object(forKey: "autoBackupSeven") as? Bool { return old ? 7 : 1 }
        return 3
    }
    private func saveAutomaticIfDue(_ ledger: LocalLedger) throws {
        guard prefs.bool(forKey: "autoBackupEnabled"), let bookmark = prefs.data(forKey: "autoBackupBookmark") else { return }
        let day = LocalLedger.dateFormatter("yyyy-MM-dd", zone: .current).string(from: Date()), revision = prefs.integer(forKey: "ledgerRevision")
        guard prefs.string(forKey: "autoBackupSavedDay") != day,
              (prefs.object(forKey: "autoBackupSavedRevision") as? Int) != revision else { return }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard folder.startAccessingSecurityScopedResource() else { throw LocalLedger.Failure.database }
        defer { folder.stopAccessingSecurityScopedResource() }
        let install = prefs.string(forKey: "autoBackupInstallId") ?? UUID().uuidString
        prefs.set(install, forKey: "autoBackupInstallId")
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { coordinatedFolder in
            let dir = coordinatedFolder
            let staged = dir.appendingPathComponent(".backup-\(UUID().uuidString).sqlite3")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try ledger.exportSnapshot(to: staged)
                let final = dir.appendingPathComponent("iRostam-auto-\(install)-\(day).sqlite3")
                guard rename(staged.path, final.path) == 0 else { throw LocalLedger.Failure.database }
                prefs.set(day, forKey: "autoBackupSavedDay"); prefs.set(revision, forKey: "autoBackupSavedRevision")
                prefs.set(ISO8601DateFormatter().string(from: Date()), forKey: "autoBackupLastSaved")
                prefs.removeObject(forKey: "autoBackupError")
                do {
                    let copies = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasPrefix("iRostam-auto-\(install)-") && $0.pathExtension == "sqlite3" }
                        .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    for old in copies.dropFirst(retention) { try FileManager.default.removeItem(at: old) }
                } catch { prefs.set("Saved to folder, but older backups could not be removed: \(error.localizedDescription)", forKey: "autoBackupError") }
            } catch { try? FileManager.default.removeItem(at: staged); operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    @objc func importBackup(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.pickerCall == nil, let presenter = self.bridge?.viewController else {
                call.reject("Could not open Files.")
                return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
            picker.delegate = self
            self.pickerCall = call
            presenter.present(picker, animated: true)
        }
    }

    @objc func exportBackup(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.pickerCall == nil, let presenter = self.bridge?.viewController else {
                call.reject("Could not open Files.")
                return
            }
            self.pickerCall = call
            self.storage.async {
                do {
                    let url = try self.ledger().exportBackup()
                    DispatchQueue.main.async {
                        self.exportURL = url
                        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                        picker.delegate = self
                        presenter.present(picker, animated: true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.pickerCall = nil
                        call.reject((error as? LocalLedger.Failure)?.localizedDescription ?? "Could not create the backup.")
                    }
                }
            }
        }
    }

    @objc func restoreRecovery(_ call: CAPPluginCall) {
        storage.async {
            do {
                try self.ledger().restoreRecoveryBackup()
                self.prefs.set(self.prefs.integer(forKey: "ledgerRevision") + 1, forKey: "ledgerRevision")
                do { try self.saveAutomaticIfDue(self.ledger()) } catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") }
                call.resolve(["imported": true])
            } catch {
                call.reject((error as? LocalLedger.Failure)?.localizedDescription ?? "Could not restore the previous ledger.")
            }
        }
    }

    private func completeExport(_ call: CAPPluginCall, saved: Bool) {
        if let exportURL {
            try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
            self.exportURL = nil
        }
        call.resolve(["saved": saved])
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let call = folderCall { folderCall = nil; pickerCall = nil; call.resolve(status()); return }
        guard let call = pickerCall else { return }
        pickerCall = nil
        if exportURL != nil {
            completeExport(call, saved: false)
        } else {
            call.resolve(["imported": false])
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = pickerCall else { return }
        pickerCall = nil
        if folderCall != nil {
            folderCall = nil
            guard let folder = urls.first else { call.resolve(status()); return }
            guard folder.startAccessingSecurityScopedResource() else {
                call.reject("Files did not grant access to that folder. Please choose it again.")
                return
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            do {
                let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                var stale = false
                let restored = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, restored.startAccessingSecurityScopedResource() else {
                    call.reject("iRostam could not keep access to that folder. Please choose it again.")
                    return
                }
                defer { restored.stopAccessingSecurityScopedResource() }
                prefs.set(bookmark, forKey: "autoBackupBookmark")
                prefs.set(restored.lastPathComponent, forKey: "autoBackupFolderName")
                prefs.removeObject(forKey: "autoBackupSavedDay")
                prefs.removeObject(forKey: "autoBackupSavedRevision")
                prefs.removeObject(forKey: "autoBackupLastSaved")
                storage.async {
                    do { try self.saveAutomaticIfDue(self.ledger()) }
                    catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") }
                    call.resolve(self.status())
                }
            }
            catch { call.reject("Could not save access to this folder.") }
            return
        }
        if exportURL != nil {
            completeExport(call, saved: !urls.isEmpty)
            return
        }
        guard let source = urls.first else {
            call.resolve(["imported": false])
            return
        }
        let replacing = call.getBool("replacing") == true
        storage.async {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let ledger = try self.ledger()
                var coordinationError: NSError?
                var outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                    outcome = Result { try ledger.importBackup(from: url, replacing: replacing) }
                }
                if let coordinationError { throw coordinationError }
                guard let outcome else { throw LocalLedger.Failure.database }
                try outcome.get()
                self.prefs.set(self.prefs.integer(forKey: "ledgerRevision") + 1, forKey: "ledgerRevision")
                do { try self.saveAutomaticIfDue(ledger) } catch { self.prefs.set(error.localizedDescription, forKey: "autoBackupError") }
                call.resolve(["imported": true])
            } catch let failure as LocalLedger.Failure {
                call.reject(failure.localizedDescription)
            } catch {
                call.reject("Could not read this backup from Files. If it is in iCloud Drive, download it first.")
            }
        }
    }
}
