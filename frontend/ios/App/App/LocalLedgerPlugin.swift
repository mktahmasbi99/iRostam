import Capacitor
import Foundation

class LedgerViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(LocalLedgerPlugin())
    }
}

@objc(LocalLedgerPlugin)
class LocalLedgerPlugin: CAPPlugin, CAPBridgedPlugin {
    let identifier = "LocalLedgerPlugin"
    let jsName = "LocalLedger"
    let pluginMethods: [CAPPluginMethod] = [CAPPluginMethod(name: "startup", returnType: CAPPluginReturnPromise)]

    @objc func startup(_ call: CAPPluginCall) {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            let ledger = LocalLedger(databaseURL: directory.appendingPathComponent("irostam.sqlite3"))
            if call.getBool("create") == true {
                try ledger.initialize()
            }
            let timezone = TimeZone.current
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timezone
            formatter.dateFormat = "yyyy-MM-dd"
            call.resolve([
                "initialized": try ledger.isInitialized(),
                "today": formatter.string(from: Date()),
                "timezone": timezone.identifier
            ])
        } catch {
            call.reject("Could not open the local iRostam database.")
        }
    }
}
