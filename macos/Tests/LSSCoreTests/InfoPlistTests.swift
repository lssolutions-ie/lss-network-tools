import Foundation
import Testing

/// `Resources/Info.plist.in` is the app's Info.plist with `@VERSION@`-style placeholders
/// (filled by `scripts/build-app.sh`). The privacy usage descriptions are what make
/// macOS show the Location and Local Network prompts the Setup & Permissions sheet
/// requests — without them the request is silently denied — so they are pinned here.
@Suite("Info.plist template")
struct InfoPlistTests {
    /// `macos/Resources/Info.plist.in`, relative to this file (`macos/Tests/LSSCoreTests/`).
    private var templateURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // LSSCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .appending(path: "Resources/Info.plist.in")
    }

    private func load() throws -> [String: Any] {
        let data = try Data(contentsOf: templateURL)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any], "Info.plist.in is a dictionary plist")
    }

    @Test("declares the Local Network usage description")
    func localNetworkUsage() throws {
        let plist = try load()
        let text = try #require(plist["NSLocalNetworkUsageDescription"] as? String)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("declares the Location usage description")
    func locationUsage() throws {
        let plist = try load()
        let text = try #require(plist["NSLocationWhenInUseUsageDescription"] as? String)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("lists the Bonjour service type the Setup sheet browses for")
    func bonjourServices() throws {
        let plist = try load()
        let services = try #require(plist["NSBonjourServices"] as? [String])
        #expect(services.contains("_services._dns-sd._udp"))
        #expect(services.contains("_http._tcp"), "the Setup sheet's Local Network request browses _http._tcp")
    }

    @Test("still requires macOS 14.0")
    func minimumSystemVersion() throws {
        let plist = try load()
        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
    }
}
