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
