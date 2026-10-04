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
// The authentication gate's rights (§11.2, S3) are defined before the first request can
// arrive. A failure is logged and the helper keeps serving: root-owned tool chains need
// no right, and a run that does need one then fails closed (`authorizationUnavailable`).
AuthorizationGate.ensureRights(logger: service.logger)
let listener = NSXPCListener(machServiceName: LSSHelperMachServiceName)
listener.delegate = service
listener.resume()
service.start()
dispatchMain()
