import Foundation
import Testing
import LSSXPC

/// The helper reports `LSSHelperBuildVersion` over XPC; the app bundle takes its version
/// from `macos/VERSION`. The two are *not* kept equal on purpose: launchd pins the registered
/// daemon to the helper binary's cdhash, and an ad-hoc cdhash changes whenever the binary
/// changes — so the helper's version (and therefore its binary) moves only when helper code
/// changes (`LSSHelper`, `LSSXPC`, `LSSCore`), and app-only releases keep the registration
/// (and the user's Login Items approval). This test keeps the helper version well-formed and
/// never ahead of the app version, which is what catches a helper bump without an app bump.
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

    @Test("LSSHelperBuildVersion is X.Y.Z and never ahead of macos/VERSION")
    func neverAheadOfAppVersion() throws {
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
        let text = try String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!text.isEmpty)
        #expect(text.range(of: pattern, options: .regularExpression) != nil, "VERSION is X.Y.Z")
        #expect(LSSHelperBuildVersion.range(of: pattern, options: .regularExpression) != nil, "LSSHelperBuildVersion is X.Y.Z")
        let app = text.split(separator: ".").compactMap { Int($0) }
        let helper = LSSHelperBuildVersion.split(separator: ".").compactMap { Int($0) }
        #expect(app.count == 3 && helper.count == 3)
        #expect(helper == app || helper.lexicographicallyPrecedes(app),
                "LSSHelperBuildVersion (\(LSSHelperBuildVersion)) is ahead of macos/VERSION (\(text)); bump the helper version only when LSSHelper, LSSXPC or LSSCore change, and bump macos/VERSION with it")
    }
}
