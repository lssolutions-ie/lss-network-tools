import Foundation
import Testing
import LSSXPC

/// The helper reports `LSSHelperBuildVersion` over XPC; the app bundle, the DMG and the
/// appcast take their version from `macos/VERSION`. The two are bumped by hand together —
/// this test is what catches a bump of one without the other.
@Suite("Helper build version")
struct VersionConsistencyTests {
    /// `macos/VERSION`, relative to this file (`macos/Tests/LSSCoreTests/`).
    private var versionFile: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // LSSCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .appending(path: "VERSION")
    }

    @Test("LSSHelperBuildVersion equals the trimmed content of macos/VERSION")
    func matchesVersionFile() throws {
        let text = try String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!text.isEmpty)
        #expect(text.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil, "VERSION is X.Y.Z")
        #expect(LSSHelperBuildVersion == text, "bump LSSHelperBuildVersion (Sources/LSSXPC/LSSHelperProtocol.swift) and macos/VERSION together")
    }
}
