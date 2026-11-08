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
        CAPPluginMethod(name: "importBackup", returnType: CAPPluginReturnPromise)
    ]

    private let storage = DispatchQueue(label: "iRostam.storage")
    private var pickerCall: CAPPluginCall?

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
                    let counts = try ledger.importedCounts()
                    result["workouts"] = counts.workouts
                    result["sets"] = counts.sets
                    result["photos"] = counts.photos
                }
                call.resolve(result)
            } catch {
                call.reject("Could not open the local iRostam database.")
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

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCall?.resolve(["imported": false])
        pickerCall = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = pickerCall else { return }
        pickerCall = nil
        guard let source = urls.first else {
            call.resolve(["imported": false])
            return
        }
        storage.async {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let ledger = try self.ledger()
                var coordinationError: NSError?
                var outcome: Result<Void, Error>?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                    outcome = Result { try ledger.importBackup(from: url) }
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
