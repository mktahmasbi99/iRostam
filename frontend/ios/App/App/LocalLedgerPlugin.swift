import Capacitor
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
        CAPPluginMethod(name: "restoreRecovery", returnType: CAPPluginReturnPromise)
    ]

    private let storage = DispatchQueue(label: "iRostam.storage")
    private var pickerCall: CAPPluginCall?
    private var exportURL: URL?

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
                let timezone = TimeZone.current
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timezone
                formatter.dateFormat = "yyyy-MM-dd"
                var result: [String: Any] = [
                    "state": state.rawValue,
                    "today": formatter.string(from: Date()),
                    "timezone": timezone.identifier
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
                call.resolve(try self.ledger().changeWorkout(path, method: method, payload: payload))
            } catch let error as LocalLedger.WorkoutError {
                call.reject(error.localizedDescription)
            } catch {
                call.reject("Could not save this workout change.")
            }
        }
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
                call.resolve(["imported": true])
            } catch let failure as LocalLedger.Failure {
                call.reject(failure.localizedDescription)
            } catch {
                call.reject("Could not read this backup from Files. If it is in iCloud Drive, download it first.")
            }
        }
    }
}
