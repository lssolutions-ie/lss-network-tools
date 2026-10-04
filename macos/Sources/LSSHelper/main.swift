import Foundation
import LSSXPC

// LSSHelper — the SMAppService LaunchDaemon (contract: docs/research/07-m4-privilege-updates-contract.md §4).
//
// launchd starts it on demand (MachServices) with no arguments; run by hand it only
// offers read-only diagnostics (HelperDiagnostics) and never listens.

if let code = HelperDiagnostics.run(CommandLine.arguments) {
    exit(code)
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: LSSHelperMachServiceName)
listener.delegate = service
listener.resume()
service.start()
dispatchMain()
