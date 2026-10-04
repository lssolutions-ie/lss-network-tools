import Foundation
import Testing
@testable import LSSCore

@Suite("RunLoader")
struct RunLoaderTests {
    /// Builds a throw-away output directory with one run inside.
    private func makeOutput(_ body: (URL) throws -> Void) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "lss-runloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try body(output)
        return output
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("file names map to tasks, including device files and the legacy Task 10 name")
    func fileNameMapping() {
        #expect(RunLoader.task(forFileName: "interface-network-info.json") == .interfaceInfo)
        #expect(RunLoader.task(forFileName: "gateway-stress-test.json") == .gatewayStress)
        #expect(RunLoader.task(forFileName: "gateway-stress-test-device-3.json") == .gatewayStress)
        #expect(RunLoader.task(forFileName: "custom-target-port-scan-device-12.json") == .customPortScan)
        #expect(RunLoader.task(forFileName: "custom-target-port-scan.json") == .customPortScan)
        #expect(RunLoader.task(forFileName: "manifest.json") == nil)
        #expect(RunLoader.task(forFileName: "findings.json") == nil)
        #expect(RunLoader.task(forFileName: "dns-scan-device-1.json") == nil, "single-entry tasks have no device files")
    }

    @Test("natural sort puts device-2 before device-10")
    func naturalSort() {
        let names = ["x-device-10.json", "x-device-2.json", "x-device-1.json", "x.json"]
        #expect(NaturalSort.sortFileNames(names) == ["x.json", "x-device-1.json", "x-device-2.json", "x-device-10.json"])
        #expect(NaturalSort.deviceIndex(of: "gateway-stress-test-device-7.json") == 7)
        #expect(NaturalSort.deviceIndex(of: "gateway-stress-test.json") == nil)
    }

    @Test("a run with a manifest is summarised from it; files are listed and sorted")
    func scanWithManifest() async throws {
        let output = try makeOutput { output in
            let run = output.appending(path: "acme-hq-03-10-2026")
            try write("""
            {"generated_at":"03-10-2026 14:05","client":"Acme","location":"HQ","note":"vlan 10","prepared_by":"",
             "run_directory":"acme-hq-03-10-2026","selected_interface":"en0",
             "report_file":"lss-network-tools-report-acme-hq-03-10-2026-14-05.txt","debug_file":"debug.txt",
             "tasks":[{"task_id":1,"title":"Interface Network Info","json_file":"interface-network-info.json","json_present":true,"json_files":["interface-network-info.json"],"raw_prefix":"interface-network-info"}],
             "artifacts":[]}
            """, to: run.appending(path: "manifest.json"))
            try write(#"{"status":"success","success":true,"error":null,"warnings":[],"interface":"en0"}"#, to: run.appending(path: "interface-network-info.json"))
            try write(#"{"status":"failed","success":false,"error":{"code":"target_unreachable","message":"x"},"warnings":[],"gateway":"10.0.0.1"}"#, to: run.appending(path: "gateway-stress-test-device-10.json"))
            try write(#"{"status":"success","success":true,"error":null,"warnings":[],"gateway":"10.0.0.1"}"#, to: run.appending(path: "gateway-stress-test-device-2.json"))
            try write("report", to: run.appending(path: "lss-network-tools-report-acme-hq-03-10-2026-14-05.txt"))
            try write("%PDF-1.4", to: run.appending(path: "lss-network-tools-report-acme-hq-03-10-2026-14-05.pdf"))
            try write(#"{"findings":[{"severity":"high","title":"Open gateway","detail":"d","source":"gateway-scan.json"},{"severity":"info","title":"Info","detail":"d","source":"dns-scan.json"}]}"#, to: run.appending(path: "findings.json"))
            try write("junk", to: run.appending(path: "debug.txt"))
        }
        defer { try? FileManager.default.removeItem(at: output) }

        let loader = RunLoader(outputDirectory: output) { _, _ in nil }
        let runs = await loader.listRuns()
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.client == "Acme")
        #expect(run.location == "HQ")
        #expect(run.note == "vlan 10")
        #expect(run.preparedBy == nil, "empty prepared_by is a sentinel")
        #expect(run.interface == "en0")
        #expect(run.hasManifest)
        #expect(run.generatedAt != nil)
        #expect(run.reportTXT?.lastPathComponent == "lss-network-tools-report-acme-hq-03-10-2026-14-05.txt")
        #expect(run.reportPDF?.lastPathComponent == "lss-network-tools-report-acme-hq-03-10-2026-14-05.pdf")
        #expect(run.taskFiles.map(\.fileName) == [
            "interface-network-info.json",
            "gateway-stress-test-device-2.json",
            "gateway-stress-test-device-10.json",
        ])
        #expect(run.presentTasks == [.interfaceInfo, .gatewayStress])

        let detail = await loader.loadDetail(of: run)
        #expect(detail.findings.map(\.title) == ["Open gateway", "Info"], "high severity first")
        #expect(detail.findings.first?.task == .gatewayDetails)
        let stress = detail.files(for: .gatewayStress)
        #expect(stress.count == 2)
        if case .rawOnly(let envelope, _, let problem) = stress[1].state {
            #expect(envelope?.effectiveStatus == .failed)
            #expect(problem == nil, "no decoder registered means raw-only without a problem")
        } else {
            Issue.record("expected rawOnly state without a typed decoder")
        }
    }

    @Test("a run without a manifest falls back to the directory name and globbing")
    func scanWithoutManifest() async throws {
        let output = try makeOutput { output in
            let run = output.appending(path: "unknown-fr-06-04-2026-g")
            try write(#"{"status":"success","success":true}"#, to: run.appending(path: "dns-scan.json"))
            try write("not json at all", to: run.appending(path: "dhcp-scan.json"))
        }
        defer { try? FileManager.default.removeItem(at: output) }

        let loader = RunLoader(outputDirectory: output) { _, _ in nil }
        let run = try #require(await loader.listRuns().first)
        #expect(!run.hasManifest)
        #expect(run.client == nil)
        #expect(run.generatedAtText == "06-04-2026")
        #expect(run.generatedAt != nil)
        #expect(run.presentTasks == [.dnsScan, .dhcpScan])

        let detail = await loader.loadDetail(of: run)
        if case .corrupt = try #require(detail.files(for: .dhcpScan).first).state {} else {
            Issue.record("invalid JSON should be reported as corrupt")
        }
    }

    @Test("an unreadable file is reported as needing elevation")
    func unreadableFile() async throws {
        let output = try makeOutput { output in
            let run = output.appending(path: "client-site-01-01-2026")
            let file = run.appending(path: "gateway-stress-test-device-1.json")
            try write(#"{"status":"success","success":true}"#, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))
        }
        defer {
            let file = output.appending(path: "client-site-01-01-2026/gateway-stress-test-device-1.json")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: output)
        }

        let loader = RunLoader(outputDirectory: output) { _, _ in nil }
        let run = try #require(await loader.listRuns().first)
        #expect(run.unreadableCount == 1)
        let detail = await loader.loadDetail(of: run)
        if case .unreadable = try #require(detail.files.first).state {} else {
            Issue.record("expected the 0000 file to be unreadable")
        }
    }

    @Test("identical findings get distinct ids from their file position, assigned before sorting")
    func findingOrdinals() async throws {
        // Task 10 writes the same indicator finding for every device file, so two
        // byte-identical entries are normal; `findings.json` lists them after an
        // info-level entry so the sort has to move them.
        let output = try makeOutput { output in
            let run = output.appending(path: "acme-hq-03-10-2026")
            try write(#"{"status":"success","success":true}"#, to: run.appending(path: "dns-scan.json"))
            try write("""
            {"findings":[
              {"severity":"info","title":"Recursion enabled (answers LAN clients)","detail":"10.0.0.1","source":"dns-scan.json"},
              {"severity":"high","title":"Gateway degraded under load","detail":"Sustained avg 48 ms vs baseline 1 ms","source":"gateway-stress-test-device-1.json"},
              {"severity":"high","title":"Gateway degraded under load","detail":"Sustained avg 48 ms vs baseline 1 ms","source":"gateway-stress-test-device-1.json"}
            ]}
            """, to: run.appending(path: "findings.json"))
            try write("""
            {"hints":[
              {"severity":"advice","title":"Same hint","detail":"d","source":"dns-scan.json"},
              {"severity":"advice","title":"Same hint","detail":"d","source":"dns-scan.json"}
            ]}
            """, to: run.appending(path: "remediation.json"))
        }
        defer { try? FileManager.default.removeItem(at: output) }

        let loader = RunLoader(outputDirectory: output) { _, _ in nil }
        let run = try #require(await loader.listRuns().first)
        let detail = await loader.loadDetail(of: run)

        #expect(detail.findings.count == 3)
        #expect(Set(detail.findings.map(\.id)).count == 3, "every finding needs a distinct Identifiable id")
        #expect(detail.findings.map(\.ordinal) == [1, 2, 0], "ordinals follow findings.json, not the sorted order")
        #expect(detail.findings.map { $0.severity?.rawValue } == ["high", "high", "info"])
        let twins = detail.findings.filter { $0.ordinal != 0 }
        #expect(twins[0] != twins[1], "position is part of equality so SwiftUI diffs the rows apart")
        #expect(twins[0].title == twins[1].title && twins[0].detail == twins[1].detail && twins[0].source == twins[1].source)

        #expect(detail.hints.map(\.ordinal) == [0, 1])
        #expect(Set(detail.hints.map(\.id)).count == 2)

        // `ordinal` is never read from JSON.
        let decoded = try LSSJSON.decode(FindingsFile.self, from: Data(#"{"findings":[{"ordinal":7,"severity":"info","title":"t"}]}"#.utf8))
        #expect(decoded.findings?.first?.ordinal == 0)
    }

    @Test("loadDetail(ofDirectory:) builds the same summary as listRuns for a fixture run, whatever the URL spelling")
    func loadDetailOfDirectory() async throws {
        let runs = URL(filePath: #filePath)
            .deletingLastPathComponent() // LSSCoreTests
            .deletingLastPathComponent() // Tests
            .appending(path: "Fixtures/runs", directoryHint: .isDirectory)
        let name = "client-58566a-site-dc14c8-31-03-2026"
        let loader = RunLoader(outputDirectory: runs) { task, data in
            try TaskPayloadRegistry.decode(task: task, data: data)
        }
        let listed = try #require(await loader.listRuns().first { $0.name == name })
        let fromListing = await loader.loadDetail(of: listed)

        let detail = try #require(await loader.loadDetail(ofDirectory: listed.directory))
        #expect(detail.summary == listed)
        #expect(detail.summary.id == listed.id)
        #expect(detail.manifest != nil)
        #expect(detail.files.map(\.id) == fromListing.files.map(\.id))
        #expect(detail.findings.map(\.id) == fromListing.findings.map(\.id))
        #expect(detail.files.count == listed.taskFiles.count)
        #expect(detail.files.contains { if case .decoded = $0.state { true } else { false } }, "the registry decodes the fixture's task files")

        // Other spellings of the same directory: trailing slash, no directory hint.
        let path = runs.path(percentEncoded: false) + name
        let trailingSlash = try #require(await loader.loadDetail(ofDirectory: URL(filePath: path + "/")))
        #expect(trailingSlash.summary == listed)
        let noHint = try #require(await loader.loadDetail(ofDirectory: URL(filePath: path)))
        #expect(noHint.summary == listed)
        #expect(noHint.summary.id == listed.id, "RunSummary.id must match the listing's so selection survives")

        // A run outside the loader's output directory loads as well (the finished run
        // the coordinator points at may belong to another output root).
        let elsewhere = RunLoader(outputDirectory: FileManager.default.temporaryDirectory) { _, _ in nil }
        let outside = try #require(await elsewhere.loadDetail(ofDirectory: listed.directory))
        #expect(outside.summary.name == name)

        // nil for a missing directory and for a file.
        #expect(await loader.loadDetail(ofDirectory: runs.appending(path: "missing-run")) == nil)
        #expect(await loader.loadDetail(ofDirectory: listed.directory.appending(path: "manifest.json")) == nil)
    }

    @Test("a typed decoder's result is surfaced as decoded; its error as rawOnly with a problem")
    func decoderIntegration() async throws {
        struct Dummy: TaskPayload { static let taskIDs: [TaskID] = [.dnsScan]; var network: String? }
        let output = try makeOutput { output in
            let run = output.appending(path: "c-s-02-02-2026")
            try write(#"{"status":"success","success":true,"network":"10.0.0.0/24"}"#, to: run.appending(path: "dns-scan.json"))
            try write(#"{"status":"success","success":true}"#, to: run.appending(path: "ldap-ad-scan.json"))
        }
        defer { try? FileManager.default.removeItem(at: output) }

        struct Boom: Error {}
        let loader = RunLoader(outputDirectory: output) { task, data in
            switch task {
            case .dnsScan:
                let result = try LSSJSON.decode(TaskResult<Dummy>.self, from: data)
                return (result.envelope, result.payload)
            case .ldapScan:
                throw Boom()
            default:
                return nil
            }
        }
        let run = try #require(await loader.listRuns().first)
        let detail = await loader.loadDetail(of: run)
        if case .decoded(_, let payload, _) = try #require(detail.files(for: .dnsScan).first).state {
            #expect((payload as? Dummy)?.network == "10.0.0.0/24")
        } else {
            Issue.record("expected decoded state")
        }
        if case .rawOnly(_, _, let problem) = try #require(detail.files(for: .ldapScan).first).state {
            #expect(problem != nil)
        } else {
            Issue.record("expected rawOnly with a problem")
        }
    }
}

@Suite("Lenient wrappers — integer overflow guards")
struct LenientOverflowTests {
    private struct Probe: Decodable {
        @LenientString var channel: String?
        @LenientInt var count: Int?
    }

    private func decode(_ json: String) throws -> Probe {
        try LSSJSON.decode(Probe.self, from: Data(json.utf8))
    }

    @Test("a huge integral number does not trap in LenientString or LenientInt")
    func hugeNumbers() throws {
        let huge = try decode(#"{"channel": 1e300, "count": 1e300}"#)
        #expect(huge.channel == "1e+300", "kept as Swift spells the Double, not Int(1e300)")
        #expect(huge.count == nil)

        let negative = try decode(#"{"channel": -1e20, "count": -1e20}"#)
        #expect(negative.channel == "-1e+20")
        #expect(negative.count == nil)

        let edge = try decode(#"{"channel": 9e15, "count": 9000000000000001}"#)
        #expect(edge.channel == "9000000000000000.0", "the guard is strict at 9e15, so the Double spelling is kept")
        #expect(edge.count == nil)

        let text = try decode(#"{"channel": "1e300", "count": "1e300"}"#)
        #expect(text.channel == "1e300", "strings pass through untouched")
        #expect(text.count == nil)
    }

    @Test("ordinary numbers still convert")
    func ordinaryNumbers() throws {
        let probe = try decode(#"{"channel": 36, "count": 36.6}"#)
        #expect(probe.channel == "36")
        #expect(probe.count == 37)
        let fraction = try decode(#"{"channel": 2.5, "count": "12"}"#)
        #expect(fraction.channel == "2.5")
        #expect(fraction.count == 12)
        let large = try decode(#"{"channel": 8999999999999999, "count": -500000000000000}"#)
        #expect(large.channel == "8999999999999999")
        #expect(large.count == -500_000_000_000_000)
    }
}
