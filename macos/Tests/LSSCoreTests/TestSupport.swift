import Foundation

/// `lss-network-tools.sh` at the repository root, located relative to this file
/// (macos/Tests/LSSCoreTests/ → ../../..). `LSS_ENGINE_SCRIPT` overrides the path so
/// the drift tests can be pointed at an edited copy of the engine (that is how
/// `FlagDriftTests` was shown to fail on a renamed, added or re-aritied flag).
var engineScriptURL: URL {
    if let override = ProcessInfo.processInfo.environment["LSS_ENGINE_SCRIPT"], !override.isEmpty {
        return URL(filePath: override)
    }
    return URL(filePath: #filePath)
        .deletingLastPathComponent() // LSSCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .deletingLastPathComponent() // repo root
        .appending(path: "lss-network-tools.sh")
}
