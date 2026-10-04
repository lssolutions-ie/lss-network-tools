import Foundation
import Testing
@testable import LSSCore

/// Every JSON file under Tests/Fixtures must decode through the registry.
/// Real runs live in `runs/<run>/`, hand-written shapes in `synthetic/`.
private var fixturesRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent() // LSSCoreTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Fixtures", directoryHint: .isDirectory)
}

struct FixtureFile: CustomStringConvertible, Sendable {
    let url: URL
    let task: TaskID
    var description: String { url.path(percentEncoded: false).replacingOccurrences(of: fixturesRoot.path(percentEncoded: false), with: "") }
}

func allTaskFixtures() throws -> [FixtureFile] {
    var files: [FixtureFile] = []
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: fixturesRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
    for case let url as URL in enumerator where url.pathExtension == "json" {
        let name = url.lastPathComponent
        if ["manifest.json", "findings.json", "remediation.json", "provenance.json"].contains(name) { continue }
        if let task = RunLoader.task(forFileName: name) {
            files.append(FixtureFile(url: url, task: task))
        } else if name.hasPrefix("task-"),
                  let number = Int(name.dropFirst(5).prefix { $0.isNumber }),
                  let task = TaskID(rawValue: number) {
            files.append(FixtureFile(url: url, task: task))
        } else {
            Issue.record("fixture \(name) does not map to a task")
        }
    }
    return files.sorted { $0.url.path < $1.url.path }
}

@Suite("Fixtures decode through the registry")
struct FixtureDecodingTests {
    @Test("fixture tree is present")
    func treeExists() throws {
        let files = try allTaskFixtures()
        #expect(files.count >= 80, "expected the six real runs plus synthetic files, got \(files.count)")
        #expect(Set(files.map(\.task)).count == TaskID.allCases.count, "every task should have at least one fixture")
    }

    @Test("every task JSON decodes to a typed payload", arguments: try allTaskFixtures())
    func decodes(_ fixture: FixtureFile) throws {
        let data = try Data(contentsOf: fixture.url)
        let decoded = try TaskPayloadRegistry.decode(task: fixture.task, data: data)
        let (envelope, payload) = try #require(decoded, "no decoder for \(fixture)")
        #expect(type(of: payload).taskIDs.contains(fixture.task), "payload type does not own task \(fixture.task.rawValue) for \(fixture)")
        if case .other(let raw) = envelope.effectiveStatus {
            Issue.record("unexpected status '\(raw)' in \(fixture)")
        }
        // The generic tree must agree with the typed envelope.
        let raw = try LSSJSON.decode(JSONValue.self, from: data)
        if let status = raw["status"]?.stringValue {
            #expect(envelope.status?.rawValue == status)
        }
        #expect(raw["warnings"] == nil || raw["warnings"]?.arrayValue?.count == envelope.warnings.count)
    }

    @Test("real-run fixtures scan like live run directories")
    func realRunsScan() async throws {
        let runsRoot = fixturesRoot.appending(path: "runs", directoryHint: .isDirectory)
        let loader = RunLoader(outputDirectory: runsRoot, decoder: TaskPayloadRegistry.decode)
        let runs = await loader.listRuns()
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: runsRoot.path(percentEncoded: false))) ?? ["<unreadable: \(runsRoot.path(percentEncoded: false))>"]
        #expect(runs.count == 6, "runs: \(runs.map(\.name)); directory listing: \(listing)")
        for run in runs {
            #expect(run.hasManifest, "\(run.name) has no manifest")
            #expect(run.client?.hasPrefix("Client ") == true, "\(run.name) client was not anonymised")
            #expect(run.location?.hasPrefix("Site ") == true, "\(run.name) location was not anonymised")
            let detail = await loader.loadDetail(of: run)
            for file in detail.files {
                switch file.state {
                case .decoded: break
                case .rawOnly(_, _, let problem): Issue.record("\(run.name)/\(file.ref.fileName) not typed: \(problem ?? "no decoder")")
                case .corrupt(let message): Issue.record("\(run.name)/\(file.ref.fileName) corrupt: \(message)")
                case .unreadable: Issue.record("\(run.name)/\(file.ref.fileName) unreadable")
                }
            }
            // The manifest's present files must all be on disk unless recorded as skipped.
            let provenance = try? LSSJSON.decode(JSONValue.self, from: Data(contentsOf: run.directory.appending(path: "provenance.json")))
            let skipped = Set((provenance?["skipped_unreadable"]?.arrayValue ?? []).compactMap(\.stringValue)
                + (provenance?["skipped_unparseable"]?.arrayValue ?? []).compactMap(\.stringValue))
            let manifest = try #require(detail.manifest)
            for entry in manifest.tasks ?? [] where entry.jsonPresent == true {
                for name in entry.jsonFiles ?? [] where !skipped.contains(name) {
                    #expect(run.taskFiles.contains { $0.fileName == name }, "\(run.name): manifest lists \(name) but it is missing")
                }
            }
        }
        // Natural ordering and a PDF on the newest generation.
        #expect(runs.contains { $0.reportPDF != nil }, "at least one fixture should carry a regenerated PDF")
    }

    @Test("the synthetic full run covers all 20 tasks with typed payloads")
    func syntheticRunCoversAllTasks() async throws {
        let root = fixturesRoot.appending(path: "synthetic-run", directoryHint: .isDirectory)
        let loader = RunLoader(outputDirectory: root, decoder: TaskPayloadRegistry.decode)
        let run = try #require(await loader.listRuns().first)
        #expect(run.presentTasks == Set(TaskID.allCases))
        let detail = await loader.loadDetail(of: run)
        for file in detail.files {
            guard case .decoded(_, let payload, _) = file.state else {
                Issue.record("\(file.ref.fileName) is not typed")
                continue
            }
            #expect(type(of: payload).taskIDs.contains(file.task))
        }
        let stress = detail.files(for: .gatewayStress)
        #expect(stress.count == 1)
        if case .decoded(_, let payload, _) = try #require(stress.first).state {
            #expect((payload as? StressTestPayload)?.target == "10.42.0.1")
        }
    }
}
