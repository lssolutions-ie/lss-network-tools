import Foundation
import Testing
@testable import LSSCore

/// `real-task1-events.log` is the stderr of a real root run of
/// `lss-network-tools.sh v1.2.249 --run-task 1 …` (paths and slugs anonymised,
/// nothing else changed). It pins the event sequence the engine actually emits.
@Suite("Real root capture of the non-interactive engine")
struct RealCaptureTests {
    private var url: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/progress/real-task1-events.log")
    }

    @Test("the captured Task 1 run parses into the documented event sequence")
    func task1Sequence() throws {
        var parser = ProgressLineParser()
        var output = parser.feed(try Data(contentsOf: url))
        output.events += parser.flush().events
        #expect(parser.malformedLineCount == 0)
        #expect(output.lines.isEmpty, "a stderr-only capture carries no human lines")
        try #require(output.events.count == 7)
        let kinds = output.events.map(\.kind)

        if case .hello(let version, let pid, let tasks) = kinds[0] {
            #expect(version == "v1.2.249")
            #expect(pid != nil)
            #expect(tasks == [1])
        } else {
            Issue.record("first event is not hello: \(kinds[0])")
        }
        if case .runDirectory(let path, let created) = kinds[1] {
            #expect(path.hasSuffix("/output/acme-hq-04-10-2026"))
            #expect(created == true)
        } else {
            Issue.record("second event is not run_dir: \(kinds[1])")
        }
        #expect(kinds[2] == .taskStart(task: 1, title: "Interface Network Info", index: 1, total: 1))
        #expect(kinds[3] == .taskDone(task: 1, status: "success", exitCode: 0, jsonFiles: ["interface-network-info.json"]))
        if case .reportBuilt(let txt) = kinds[4] {
            #expect(txt?.hasSuffix(".txt") == true)
        } else {
            Issue.record("fifth event is not report_built: \(kinds[4])")
        }
        if case .pdfBuilt(let pdf) = kinds[5] {
            #expect(pdf?.hasSuffix(".pdf") == true)
        } else {
            Issue.record("sixth event is not pdf_built: \(kinds[5])")
        }
        #expect(kinds[6] == .bye(exitCode: 0))
        #expect(output.events[6].isTerminal)

        // The engine adds an absolute `path` to the report events; it must survive in `fields`.
        #expect(output.events[4].fields["path"]?.stringValue?.hasPrefix("/") == true)
        #expect(output.events[5].fields["path"]?.stringValue?.hasSuffix(".pdf") == true)
        #expect(output.events.allSatisfy { $0.timestamp != nil && $0.protocolVersion == 1 })
        #expect(output.events[2].taskID == .interfaceInfo)
    }

    struct ErrorCapture: CustomStringConvertible, Sendable {
        let file: String
        let code: String
        let exitCode: CLIExitCode
        let tasks: [Int]
        var description: String { file }
    }

    static let errorCaptures: [ErrorCapture] = [
        ErrorCapture(file: "real-consent-events.log", code: "consent_required", exitCode: .consentRequired, tasks: [10]),
        ErrorCapture(file: "real-not-root-events.log", code: "not_root", exitCode: .notRoot, tasks: [1]),
        ErrorCapture(file: "real-usage-events.log", code: "invalid_interface", exitCode: .usage, tasks: [1]),
    ]

    /// Unprivileged runs of v1.2.249 (`2>events.log`): validation errors follow `hello`
    /// immediately and `bye` carries the exit code the process returned.
    @Test("the captured error paths are hello → error → bye with the documented codes", arguments: errorCaptures)
    func errorPath(_ capture: ErrorCapture) throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/progress/\(capture.file)")
        var parser = ProgressLineParser()
        var output = parser.feed(try Data(contentsOf: url))
        output.events += parser.flush().events
        #expect(parser.malformedLineCount == 0)
        try #require(output.events.count == 3)
        if case .hello(let version, _, let tasks) = output.events[0].kind {
            #expect(version == "v1.2.249")
            #expect(tasks == capture.tasks)
        } else {
            Issue.record("\(capture.file): first event is not hello")
        }
        if case .error(let code, let message, _) = output.events[1].kind {
            #expect(code == capture.code)
            #expect(message?.isEmpty == false)
        } else {
            Issue.record("\(capture.file): second event is not error")
        }
        #expect(output.events[2].kind == .bye(exitCode: Int(capture.exitCode.rawValue)))
    }
}
