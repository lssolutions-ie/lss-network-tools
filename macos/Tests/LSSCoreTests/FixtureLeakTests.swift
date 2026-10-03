import Foundation
import Testing

/// Structural leak checks over the committed fixtures. They need no secret: the
/// anonymiser's plaintext `--check` runs where the real data is, and these tests
/// make sure nothing that *looks* identifying survives in the repository.
///
/// (An earlier version hashed every replaced name with a public salt into a leak
/// list; that list was a guess-confirmation oracle for client names and was
/// removed. The fixture names are now derived with a private salt.)
@Suite("Fixture leak checks")
struct FixtureLeakTests {
    private static var fixturesRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    private static func files(under subdirectory: String, extensions: Set<String>) -> [URL] {
        let root = fixturesRoot.appending(path: subdirectory, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where extensions.contains(url.pathExtension) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { urls.append(url) }
        }
        return urls
    }

    private static func relative(_ url: URL) -> String {
        url.path(percentEncoded: false).replacingOccurrences(of: fixturesRoot.path(percentEncoded: false), with: "")
    }

    // MARK: - Public IPv4 literals

    /// RFC 1918, loopback, link-local, CGNAT, multicast/reserved, TEST-NET and the
    /// well-known public resolvers are allowed; anything else is a leak.
    static func isAllowedIPv4(_ ip: String) -> Bool {
        let allowedExact: Set<String> = ["0.0.0.0", "255.255.255.255", "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1",
                                         "9.9.9.9", "149.112.112.112", "208.67.222.222", "208.67.220.220"]
        if allowedExact.contains(ip) { return true }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return true } // not an address
        let (a, b, c) = (parts[0], parts[1], parts[2])
        if a == 10 || a == 127 || a == 0 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 169 && b == 254 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if (224...255).contains(a) { return true }            // multicast, reserved, netmasks
        if a == 192 && b == 0 && c == 2 { return true }       // TEST-NET-1
        if a == 198 && b == 51 && c == 100 { return true }    // TEST-NET-2
        if a == 203 && b == 0 && c == 113 { return true }     // TEST-NET-3
        return false
    }

    @Test("no public IPv4 literal appears in any fixture JSON (real, synthetic or assembled)")
    func noPublicIPv4() throws {
        let regex = try NSRegularExpression(pattern: #"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b"#)
        var scanned = 0
        for subdirectory in ["runs", "synthetic", "synthetic-run"] {
            for url in Self.files(under: subdirectory, extensions: ["json"]) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    guard let swiftRange = Range(match.range, in: text) else { continue }
                    let ip = String(text[swiftRange])
                    if !Self.isAllowedIPv4(ip) {
                        Issue.record("public IPv4 literal \(ip) in \(Self.relative(url))")
                    }
                }
            }
        }
        #expect(scanned >= 80, "expected the fixture tree to be present, scanned \(scanned) files")
    }

    // MARK: - Host names in the anonymised real runs

    /// Every dotted host-name-looking token in a real-run fixture must be a hashed
    /// replacement (`host-…`, `domain-…`, `isp-…`, `ssid-…`), a generic domain or a
    /// tooling domain. Hand-written synthetic fixtures use obviously fake names and
    /// are not subject to this rule.
    @Test("no raw host name survives in the anonymised real runs")
    func noRawHostnames() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9.-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{1,23})(?![A-Za-z0-9.-])"#)
        let hashed = try NSRegularExpression(pattern: #"^(host|domain|isp|ssid)-[0-9a-f]{6}(\.|$)"#)
        let keep: Set<String> = ["nmap.org", "example.com", "example.net", "example.org", "speedtest.net", "github.com",
                                 "apple.com", "ubnt.com", "ui.com", "home.arpa", "in-addr.arpa", "localdomain", "lan.local"]
        let fileExtensions: Set<String> = ["json", "txt", "pdf", "png", "sh", "py", "log", "csv", "html", "xml", "md",
                                           "grep", "pcap", "version", "app", "nse", "plist"]
        var scanned = 0
        for url in Self.files(under: "runs", extensions: ["json"]) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                let token = String(text[swiftRange]).lowercased()
                let labels = token.split(separator: ".").map(String.init)
                if keep.contains(token) { continue }
                if hashed.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil { continue }
                if let last = labels.last, fileExtensions.contains(last) { continue }
                if let first = labels.first, !first.contains(where: \.isLetter) { continue } // version numbers
                if labels.allSatisfy({ ["local", "lan", "home", "internal", "localdomain", "localhost", "arpa"].contains($0) }) { continue }
                Issue.record("host-name-like token “\(token)” in \(Self.relative(url))")
            }
        }
        #expect(scanned >= 60)
    }

    @Test("fixture directory and file names carry no client names, only hashed slugs and dates")
    func fixtureNamesAreHashed() throws {
        let runsRoot = Self.fixturesRoot.appending(path: "runs", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: runsRoot.path(percentEncoded: false))
            .filter { $0 != "README.md" && !$0.hasPrefix(".") }
        #expect(names.count == 6)
        let pattern = try NSRegularExpression(pattern: #"^client-[0-9a-f]{6}-site-[0-9a-f]{6}-\d{2}-\d{2}-\d{4}(-note-[0-9a-f]{6})?(-\d{2}-\d{2}(-\d+)?)?$"#)
        for name in names {
            #expect(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil, "unexpected fixture name \(name)")
            let reports = try FileManager.default.contentsOfDirectory(atPath: runsRoot.appending(path: name).path(percentEncoded: false))
                .filter { $0.hasPrefix("lss-network-tools-report-") }
            for report in reports {
                #expect(report.contains(name.prefix(27)), "report \(report) does not use the hashed slugs of \(name)")
            }
        }
    }
}
