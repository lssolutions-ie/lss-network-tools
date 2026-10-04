import Foundation
import Testing
@testable import LSSCore

/// Tests/Fixtures/progress/, relative to this file (macos/Tests/LSSCoreTests/).
private var progressFixturesRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent() // LSSCoreTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Fixtures/progress", directoryHint: .isDirectory)
}

private let fixtureNames = ["full-audit", "single-task-17", "consent-required", "not-root", "missing-deps", "task-failed"]

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: progressFixturesRoot.appending(path: "\(name).log"))
}

private struct Parsed: Equatable {
    var events: [ProgressEvent] = []
    var lines: [String] = []
    var malformed = 0

    mutating func append(_ output: ProgressLineParser.Output) {
        events += output.events
        lines += output.lines
    }
}

/// Feeds `data` in chunks of `chunkSize` bytes (whole stream when nil), then flushes.
private func parse(_ data: Data, chunkSize: Int? = nil) -> Parsed {
    var parser = ProgressLineParser()
    var parsed = Parsed()
    if let chunkSize {
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + chunkSize, data.endIndex)
            parsed.append(parser.feed(data[start..<end]))
            start = end
        }
    } else {
        parsed.append(parser.feed(data))
    }
    parsed.append(parser.flush())
    parsed.malformed = parser.malformedLineCount
    return parsed
}

private func parseFixture(_ name: String) throws -> Parsed {
    parse(try fixtureData(name))
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "UTC")
    return components.date!
}

private let sampleEventLine = #"@@LSS {"v":1,"ts":"2026-10-03T18:30:00Z","event":"task_stage","task":10,"stage":"sustained","label":"Stage 6"}"#

private extension ProgressEvent.Kind {
    var name: String {
        switch self {
        case .hello: "hello"
        case .runDirectory: "run_dir"
        case .taskStart: "task_start"
        case .taskStage: "task_stage"
        case .taskDone: "task_done"
        case .reportBuilt: "report_built"
        case .pdfBuilt: "pdf_built"
        case .pdfFailed: "pdf_failed"
        case .warning: "warning"
        case .error: "error"
        case .bye: "bye"
        case .unknown(let event): "unknown(\(event))"
        }
    }
}

private extension Array where Element == ProgressEvent {
    func named(_ name: String) -> [ProgressEvent] { filter { $0.kind.name == name } }
    var byeExitCode: Int? {
        if case .bye(let code)? = last?.kind { return code }
        return nil
    }
}

// MARK: - Fixture streams

@Suite("ProgressLineParser — fixture streams")
struct ProgressLineParserFixtureTests {
    @Test("whole, byte-by-byte and 7-byte feeding give identical results", arguments: fixtureNames)
    func feedingStrategiesAgree(_ name: String) throws {
        let data = try fixtureData(name)
        let whole = parse(data)
        let bytewise = parse(data, chunkSize: 1)
        let sevens = parse(data, chunkSize: 7)
        #expect(whole == bytewise)
        #expect(whole == sevens)
        #expect(whole.malformed == 0)
        #expect(!whole.events.isEmpty)
    }

    @Test("every stream starts with hello and ends with bye; lines are clean", arguments: fixtureNames)
    func shape(_ name: String) throws {
        let parsed = try parseFixture(name)
        let first = try #require(parsed.events.first)
        if case .hello(let version, let pid, let tasks) = first.kind {
            #expect(version == "v1.2.249")
            #expect(pid != nil)
            #expect(!tasks.isEmpty)
        } else {
            Issue.record("first event is \(first.kind.name)")
        }
        let last = try #require(parsed.events.last)
        #expect(last.isTerminal)
        #expect(parsed.events.dropLast().allSatisfy { !$0.isTerminal })
        let code = try #require(parsed.events.byeExitCode)
        #expect(CLIExitCode(rawValue: Int32(code)) != nil)

        for event in parsed.events {
            #expect(event.protocolVersion == 1)
            #expect(event.timestamp != nil, "\(event.kind.name) has no timestamp")
            #expect(event.fields["event"]?.stringValue != nil)
        }
        let timestamps = parsed.events.compactMap(\.timestamp)
        #expect(timestamps == timestamps.sorted(), "timestamps are monotonic")

        for line in parsed.lines {
            #expect(!line.contains("\u{1B}"), "ANSI left in \(line.debugDescription)")
            #expect(!line.contains("\r"), "CR left in \(line.debugDescription)")
            #expect(!line.contains("\n"))
            #expect(!line.contains(ProgressLineParser.prefix), "event text leaked into lines")
            #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(line.last != " ")
        }
    }

    @Test("full-audit.log: 12 tasks, stress stages, warning, report and PDF")
    func fullAudit() throws {
        let parsed = try parseFixture("full-audit")
        #expect(parsed.events.count == 38)
        #expect(parsed.lines.first == "Password:", "sudo's prompt is the first human line")

        let hello = parsed.events[0]
        #expect(hello.kind == .hello(version: "v1.2.249", pid: 4242, tasks: Array(1...12)))
        #expect(hello.timestamp == utcDate(2026, 10, 3, 18, 30, 0))
        #expect(hello.protocolVersion == 1)
        #expect(hello.taskID == nil)
        #expect(hello.fields["pid"]?.numberValue == 4242)

        #expect(parsed.events[1].kind == .warning(code: "interface_no_ip", message: "Interface en0 has no IPv4 address yet; continuing."))
        #expect(parsed.events[2].kind == .runDirectory(path: "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026", created: true))

        let starts = parsed.events.named("task_start")
        #expect(starts.count == 12)
        for (offset, event) in starts.enumerated() {
            guard case .taskStart(let task, let title, let index, let total) = event.kind else { Issue.record("not a task_start"); continue }
            #expect(task == offset + 1)
            #expect(index == offset + 1)
            #expect(total == 12)
            #expect(title == TaskID(rawValue: task)?.title)
            #expect(event.taskID == TaskID(rawValue: task))
        }

        let dones = parsed.events.named("task_done")
        #expect(dones.count == 12)
        var statuses: [Int: String] = [:]
        var files: [Int: [String]] = [:]
        for event in dones {
            guard case .taskDone(let task, let status, let rc, let jsonFiles) = event.kind else { continue }
            statuses[task] = status
            files[task] = jsonFiles
            #expect(rc == 0)
        }
        #expect(statuses[4] == "completed_with_warnings")
        #expect(statuses[5] == "completed_with_warnings")
        #expect(statuses.filter { $0.value == "success" }.count == 10)
        #expect(files[10] == ["gateway-stress-test-device-1.json"])
        #expect(files[1] == ["interface-network-info.json"])

        let stages = parsed.events.named("task_stage").compactMap { event -> (Int, String?)? in
            if case .taskStage(let task, let stage, _) = event.kind { return (task, stage) }
            return nil
        }
        #expect(stages.filter { $0.0 == 10 }.map(\.1) == ["baseline", "jitter", "large_packet", "ramping", "sustained", "recovery"])
        #expect(stages.filter { $0.0 == 11 }.map(\.1) == ["dot1q_capture", "cdp_lldp_capture"])
        if case .taskStage(_, _, let label) = parsed.events.named("task_stage")[0].kind {
            #expect(label == "Stage 2: Baseline latency test (20 pings)")
        }

        #expect(parsed.events.named("warning").count == 1)
        #expect(parsed.events.named("report_built").first?.kind == .reportBuilt(txt: "lss-network-tools-report-acme-hq-03-10-2026-18-31.txt"))
        #expect(parsed.events.named("pdf_built").first?.kind == .pdfBuilt(pdf: "lss-network-tools-report-acme-hq-03-10-2026-18-31.pdf"))
        #expect(parsed.events.last?.kind == .bye(exitCode: 0))

        // Human lines: checklist survives ANSI stripping, spinners collapse to their result line,
        // and the one spinner frame that shared its line with an event is kept as a line.
        #expect(parsed.lines.contains("  [OK]      nmap"))
        #expect(parsed.lines.contains("  Dependency Checklist:"))
        #expect(parsed.lines.contains("Download Speed: 512.34 Mbps"))
        #expect(parsed.lines.contains("Upload Speed: 498.10 Mbps"))
        #expect(parsed.lines.contains("DHCP server 10.0.0.1 offered 10.0.0.57 (lease 86400s)"))
        #expect(parsed.lines.contains("Stage 6: Sustained load test (300 pings @ 0.02s interval)..."))
        #expect(parsed.lines.contains("[⠙] Pinging 10.0.0.1..."), "frame written before the event on the same line")
        #expect(parsed.lines.filter { $0.contains("⠙") }.count == 1)
        #expect(!parsed.lines.contains { $0.contains("⠋") }, "overwritten spinner frames never surface")
        #expect(!parsed.lines.contains { $0.hasPrefix("Download Speed: ⠋") })
        #expect(parsed.lines.contains("  (CDP advertises every 60s — this window ensures at least one full cycle is observed.)"))
        #expect(parsed.lines.contains("  PDF report:    /usr/local/share/lss-network-tools/output/acme-hq-03-10-2026/lss-network-tools-report-acme-hq-03-10-2026-18-31.pdf"))

        let stageLabels = parsed.lines.compactMap(ProgressLineParser.stageHeuristic)
        #expect(stageLabels.contains("Baseline latency test (20 pings)..."))
        #expect(stageLabels.contains("Determining gateway for interface en0..."))
        #expect(!stageLabels.contains { $0.hasPrefix("1/2") }, "Step lines are not stages")
    }

    @Test("single-task-17.log: continue run with an existing run directory")
    func singleTask17() throws {
        let parsed = try parseFixture("single-task-17")
        #expect(parsed.events.map(\.kind.name) == ["hello", "run_dir", "task_start", "warning", "task_done", "report_built", "pdf_built", "bye"])
        #expect(parsed.events[0].kind == .hello(version: "v1.2.249", pid: 5110, tasks: [17]))
        #expect(parsed.events[1].kind == .runDirectory(path: "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026", created: false))
        #expect(parsed.events[2].kind == .taskStart(task: 17, title: "Wireless Site Survey", index: 1, total: 1))
        #expect(parsed.events[2].taskID == .wirelessSurvey)
        #expect(parsed.events[3].kind == .warning(code: "task_17_helper_fallback", message: "LSS-WiFiScan.app is not installed; scanning with system_profiler (no RSSI)."))
        #expect(parsed.events[4].kind == .taskDone(task: 17, status: "success", exitCode: 0, jsonFiles: ["wireless-survey.json"]))
        #expect(parsed.events.byeExitCode == 0)
        #expect(parsed.lines.contains("--- HQ | Floor: 2 | Room/Area: Meeting Room B ---"))
        #expect(parsed.lines.contains("Networks found: 14"))
        #expect(parsed.lines.contains("Survey complete. 3 room(s) recorded."))
        #expect(parsed.lines.first != "Password:")
    }

    @Test("consent-required.log: hello, error, bye 4 and a single human line")
    func consentRequired() throws {
        let parsed = try parseFixture("consent-required")
        #expect(parsed.events.map(\.kind.name) == ["hello", "error", "bye"])
        #expect(parsed.events[0].kind == .hello(version: "v1.2.249", pid: 5201, tasks: [10]))
        #expect(parsed.events[1].kind == .error(code: "consent_required", message: "Task 10 (Gateway Stress Test) is a stress test; pass --yes to confirm.", tools: []))
        #expect(parsed.events[2].kind == .bye(exitCode: 4))
        #expect(CLIExitCode(rawValue: 4) == .consentRequired)
        #expect(parsed.lines == ["  Task 10 (Gateway Stress Test) floods the gateway with ICMP and needs --yes."])
    }

    @Test("not-root.log: checklist then error not_root, bye 5")
    func notRoot() throws {
        let parsed = try parseFixture("not-root")
        #expect(parsed.events.map(\.kind.name) == ["hello", "error", "bye"])
        #expect(parsed.events[1].kind == .error(code: "not_root", message: "This tool must run as root (use sudo).", tools: []))
        #expect(parsed.events.byeExitCode == 5)
        #expect(parsed.lines.contains("  [OK]      nmap"))
        #expect(parsed.lines.contains("  [OK]      python3-fpdf2"))
        #expect(parsed.lines.contains("  Error: lss-network-tools must run as root. Re-run with sudo."))
        #expect(parsed.lines.contains("  Startup Check"))
    }

    @Test("missing-deps.log: error missing_dependencies carries the tools, bye 3")
    func missingDeps() throws {
        let parsed = try parseFixture("missing-deps")
        #expect(parsed.events.map(\.kind.name) == ["hello", "error", "bye"])
        #expect(parsed.events[1].kind == .error(code: "missing_dependencies", message: "Required dependencies are missing: nmap, python3-fpdf2", tools: ["nmap", "python3-fpdf2"]))
        #expect(parsed.events[1].fields["tools"]?.arrayValue?.count == 2)
        #expect(parsed.events.byeExitCode == 3)
        #expect(parsed.lines.contains("  [MISSING] nmap"))
        #expect(parsed.lines.contains("  [MISSING] python3-fpdf2"))
        #expect(parsed.lines.contains("  [OK]      jq"))
    }

    @Test("task-failed.log: failed and no_output tasks, pdf_failed, bye 1")
    func taskFailed() throws {
        let parsed = try parseFixture("task-failed")
        #expect(parsed.events.count == 11)
        #expect(parsed.lines.first == "Password:")
        #expect(parsed.events[0].kind == .hello(version: "v1.2.249", pid: 5522, tasks: [3, 6, 9]))
        #expect(parsed.events[1].kind == .runDirectory(path: "/usr/local/share/lss-network-tools/output/acme-warehouse-03-10-2026", created: true))

        let dones = parsed.events.named("task_done")
        #expect(dones.count == 3)
        #expect(dones[0].kind == .taskDone(task: 3, status: "success", exitCode: 0, jsonFiles: ["gateway-scan.json"]))
        #expect(dones[1].kind == .taskDone(task: 6, status: "failed", exitCode: 1, jsonFiles: ["dns-scan.json"]))
        #expect(dones[2].kind == .taskDone(task: 9, status: "no_output", exitCode: 1, jsonFiles: []))
        #expect(dones[2].taskID == .printServerScan)

        #expect(parsed.events.named("report_built").count == 1)
        #expect(parsed.events.named("pdf_built").isEmpty)
        #expect(parsed.events.named("pdf_failed").first?.kind == .pdfFailed(message: "generate_pdf_report.py exited 1: assets/logo.png not found"))
        #expect(parsed.events.byeExitCode == 1)
        #expect(CLIExitCode(rawValue: 1) == .taskFailed)
        #expect(parsed.lines.contains("  PDF generation failed: assets/logo.png not found"))
    }
}

// MARK: - Line handling

@Suite("ProgressLineParser — line handling")
struct ProgressLineParserLineTests {
    @Test("CRLF and LF endings both terminate lines; the CR is dropped")
    func lineEndings() {
        var parser = ProgressLineParser()
        #expect(parser.feed("a\r\nb\r\n").lines == ["a", "b"])
        #expect(parser.feed("c\nd\n").lines == ["c", "d"])
        #expect(parser.feed("e\r\r\n").lines == ["e"], "stray CRs before the newline are dropped")
        #expect(parser.malformedLineCount == 0)
    }

    @Test("a bare CR keeps only the last segment: spinners collapse to their result")
    func carriageReturnSegments() {
        var parser = ProgressLineParser()
        #expect(parser.feed("\r[⠋] Scanning...\r[⠙] Scanning...\r\u{1B}[KDone\r\n").lines == ["Done"])
        #expect(parser.feed("\r[⠋] x\r\u{1B}[K\r\n").lines == [], "a cleared line yields nothing")
        #expect(parser.feed("\r[⠋] x\r\n").lines == ["[⠋] x"], "a frame that was never cleared is what the terminal shows")
        #expect(parser.feed("\rDownload Speed: ⠋\rDownload Speed: ⠙\r\u{1B}[KDownload Speed: 512.34 Mbps\r\n").lines == ["Download Speed: 512.34 Mbps"])
    }

    @Test("empty and whitespace-only lines are dropped; trailing whitespace trimmed, indentation kept")
    func whitespace() {
        var parser = ProgressLineParser()
        #expect(parser.feed("\r\n\r\n   \r\n\t\r\n").lines == [])
        #expect(parser.feed("  indented   \r\n").lines == ["  indented"])
        #expect(parser.feed("  \u{1B}[0;32m[OK]\u{1B}[0m      nmap\r\n").lines == ["  [OK]      nmap"])
    }

    @Test("partial lines are carried across feeds, including a split UTF-8 sequence")
    func partialLines() {
        var parser = ProgressLineParser()
        #expect(parser.feed("Pass").lines == [])
        #expect(parser.feed("word:\r\nnext").lines == ["Password:"])
        #expect(parser.feed(" line\r\n").lines == ["next line"])

        let bytes = Array("[⠙] Pinging...\r\n".utf8) // ⠙ is E2 A0 99
        #expect(parser.feed(bytes[0..<2]).lines == [], "fed one byte into the three-byte scalar")
        #expect(parser.feed(bytes[2...]).lines == ["[⠙] Pinging..."])

        var event = ProgressLineParser()
        #expect(event.feed("@@LSS {\"v\":1,\"event\":\"bye\",\"exit_").events.isEmpty)
        let out = event.feed("code\":0}\r\n")
        #expect(out.events.map(\.kind) == [.bye(exitCode: 0)])
        #expect(event.malformedLineCount == 0)
    }

    @Test("flush emits the pending partial line (sudo's Password: has no newline)")
    func flush() {
        var parser = ProgressLineParser()
        #expect(parser.feed("Password:") == ProgressLineParser.Output())
        #expect(parser.flush().lines == ["Password:"])
        #expect(parser.flush() == ProgressLineParser.Output(), "nothing left")

        #expect(parser.feed("@@LSS {\"v\":1,\"event\":\"bye\",\"exit_code\":4}").events.isEmpty)
        let tail = parser.flush()
        #expect(tail.events.map(\.kind) == [.bye(exitCode: 4)])
        #expect(tail.lines.isEmpty)
    }

    @Test("ANSI sequences are stripped: CSI, OSC (BEL and ST), two-byte escapes")
    func ansi() {
        #expect(ProgressLineParser.stripANSI("\u{1B}[0;32m[OK]\u{1B}[0m      nmap") == "[OK]      nmap")
        #expect(ProgressLineParser.stripANSI("\u{1B}[1;33mStartup Check\u{1B}[0m") == "Startup Check")
        #expect(ProgressLineParser.stripANSI("\u{1B}[?25lX\u{1B}[?25h") == "X")
        #expect(ProgressLineParser.stripANSI("\u{1B}[2K\rfoo") == "\rfoo", "CR survives")
        #expect(ProgressLineParser.stripANSI("\u{1B}]0;window title\u{07}text") == "text")
        #expect(ProgressLineParser.stripANSI("\u{1B}]0;window title\u{1B}\\text") == "text")
        #expect(ProgressLineParser.stripANSI("\u{1B}7abc\u{1B}8") == "abc")
        #expect(ProgressLineParser.stripANSI("\u{1B}=\u{1B}>abc") == "abc")
        #expect(ProgressLineParser.stripANSI("plain ⠋ text") == "plain ⠋ text")
        #expect(ProgressLineParser.stripANSI("a\u{1B}") == "a", "a lone trailing ESC is dropped")
        #expect(ProgressLineParser.stripANSI("\u{1B}[38;5;208mé\u{1B}[0m") == "é")
        #expect(ProgressLineParser.stripANSI("") == "")
    }
}

// MARK: - Events

@Suite("ProgressLineParser — events")
struct ProgressLineParserEventTests {
    @Test("an event sharing its physical line with a spinner frame is split into line + event")
    func eventAfterSpinnerFrame() {
        var parser = ProgressLineParser()
        let out = parser.feed("\r[⠋] Pinging...\r[⠙] Pinging..." + sampleEventLine + "\r\n")
        #expect(out.events.map(\.kind) == [.taskStage(task: 10, stage: "sustained", label: "Stage 6")])
        #expect(out.lines == ["[⠙] Pinging..."])
        #expect(parser.malformedLineCount == 0)
    }

    @Test("parse(line:) tolerates leading ANSI / whitespace and rejects non-progress lines")
    func parseLine() throws {
        let event = try #require(ProgressLineParser.parse(line: "\u{1B}[0m  " + sampleEventLine))
        #expect(event.kind == .taskStage(task: 10, stage: "sustained", label: "Stage 6"))
        #expect(event.taskID == .gatewayStress)
        #expect(event.timestamp == utcDate(2026, 10, 3, 18, 30, 0))
        #expect(event.protocolVersion == 1)
        #expect(event.fields["label"]?.stringValue == "Stage 6")

        #expect(ProgressLineParser.parse(line: sampleEventLine + "\r[⠹] Pinging...") != nil, "a frame after the JSON is ignored")
        #expect(ProgressLineParser.parse(line: "Stage 6: Sustained load test...") == nil)
        #expect(ProgressLineParser.parse(line: "@@LSS {not json}") == nil)
        #expect(ProgressLineParser.parse(line: "@@LSS") == nil, "prefix needs its trailing space")
        #expect(ProgressLineParser.parse(line: "@@LSS {\"v\":1}") == nil, "no event name")
        #expect(ProgressLineParser.parse(line: "") == nil)
        #expect(ProgressLineParser.prefix == "@@LSS ")
    }

    @Test("malformed progress lines are counted and dropped")
    func malformed() {
        var parser = ProgressLineParser()
        let out = parser.feed("@@LSS {not json}\r\n@@LSS {\"v\":1}\r\n@@LSS [1,2]\r\n@@LSS {\"v\":1,\"event\":\"task_start\"}\r\n@@LSS {\"v\":1,\"event\":\"run_dir\"}\r\n")
        #expect(out.events.isEmpty)
        #expect(out.lines.isEmpty)
        #expect(parser.malformedLineCount == 5)
        #expect(parser.feed("fine\r\n").lines == ["fine"])
        #expect(parser.malformedLineCount == 5)
    }

    @Test("unknown event names are preserved with their fields")
    func unknownKind() throws {
        let event = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"ts":"2026-10-03T18:30:00Z","event":"coffee","extra":"x"}"#))
        #expect(event.kind == .unknown(event: "coffee"))
        #expect(event.fields["extra"]?.stringValue == "x")
        #expect(event.taskID == nil)
        #expect(!event.isTerminal)
    }

    @Test("every documented event kind decodes with its fields")
    func allKinds() throws {
        func kind(_ json: String) throws -> ProgressEvent.Kind {
            try #require(ProgressLineParser.parse(line: "@@LSS " + json)).kind
        }
        #expect(try kind(#"{"v":1,"event":"hello","version":"v1.2.249","pid":7,"tasks":[1,3,5]}"#) == .hello(version: "v1.2.249", pid: 7, tasks: [1, 3, 5]))
        #expect(try kind(#"{"v":1,"event":"hello"}"#) == .hello(version: nil, pid: nil, tasks: []))
        #expect(try kind(#"{"v":1,"event":"run_dir","path":"/x","created":false}"#) == .runDirectory(path: "/x", created: false))
        #expect(try kind(#"{"v":1,"event":"run_dir","path":"/x"}"#) == .runDirectory(path: "/x", created: nil))
        #expect(try kind(#"{"v":1,"event":"task_start","task":4,"title":"DHCP Network Scan","index":4,"total":12}"#) == .taskStart(task: 4, title: "DHCP Network Scan", index: 4, total: 12))
        #expect(try kind(#"{"v":1,"event":"task_stage","task":18,"stage":"arp","label":"ARP discovery"}"#) == .taskStage(task: 18, stage: "arp", label: "ARP discovery"))
        #expect(try kind(#"{"v":1,"event":"task_done","task":4,"status":"success","rc":0,"json_files":["dhcp-scan.json"]}"#) == .taskDone(task: 4, status: "success", exitCode: 0, jsonFiles: ["dhcp-scan.json"]))
        #expect(try kind(#"{"v":1,"event":"report_built","txt":"r.txt"}"#) == .reportBuilt(txt: "r.txt"))
        #expect(try kind(#"{"v":1,"event":"pdf_built","pdf":"r.pdf"}"#) == .pdfBuilt(pdf: "r.pdf"))
        #expect(try kind(#"{"v":1,"event":"pdf_failed","message":"boom"}"#) == .pdfFailed(message: "boom"))
        #expect(try kind(#"{"v":1,"event":"warning","code":"interface_no_ip","message":"m"}"#) == .warning(code: "interface_no_ip", message: "m"))
        #expect(try kind(#"{"v":1,"event":"error","code":"usage","message":"m"}"#) == .error(code: "usage", message: "m", tools: []))
        #expect(try kind(#"{"v":1,"event":"error","code":"missing_dependencies","message":"m","tools":["nmap","jq"]}"#) == .error(code: "missing_dependencies", message: "m", tools: ["nmap", "jq"]))
        #expect(try kind(#"{"v":1,"event":"bye","exit_code":130}"#) == .bye(exitCode: 130))
        #expect(try kind(#"{"v":1,"event":"bye"}"#) == .bye(exitCode: nil))
    }

    @Test("numbers may arrive as numeric strings; booleans as strings")
    func lenientNumbers() throws {
        let done = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":"1","event":"task_done","task":"4","status":"success","rc":"0","json_files":["a.json"]}"#))
        #expect(done.kind == .taskDone(task: 4, status: "success", exitCode: 0, jsonFiles: ["a.json"]))
        #expect(done.protocolVersion == 1)
        let dir = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"run_dir","path":"/x","created":"false"}"#))
        #expect(dir.kind == .runDirectory(path: "/x", created: false))
        let bye = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"bye","exit_code":"5"}"#))
        #expect(bye.kind == .bye(exitCode: 5))
    }

    @Test("escaped strings decode (json_escape output)")
    func escapes() throws {
        let event = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"error","code":"usage","message":"Unknown flag \"--bogus\"\nSee --help — \\ end"}"#))
        #expect(event.kind == .error(code: "usage", message: "Unknown flag \"--bogus\"\nSee --help — \\ end", tools: []))
    }

    @Test("timestamps: Z suffix, fractional seconds, garbage and missing")
    func timestamps() throws {
        #expect(try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"ts":"2026-10-03T18:30:00Z","event":"bye"}"#)).timestamp == utcDate(2026, 10, 3, 18, 30, 0))
        #expect(try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"ts":"2026-10-03T18:30:00.250Z","event":"bye"}"#)).timestamp != nil)
        #expect(try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"ts":"yesterday","event":"bye"}"#)).timestamp == nil)
        let bare = try #require(ProgressLineParser.parse(line: #"@@LSS {"event":"bye"}"#))
        #expect(bare.timestamp == nil)
        #expect(bare.protocolVersion == nil)
        #expect(LSSJSON.parseISO8601("2026-10-03T18:30:00Z") == utcDate(2026, 10, 3, 18, 30, 0))
    }

    @Test("taskID and isTerminal")
    func accessors() throws {
        let start = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"task_start","task":4}"#))
        #expect(start.taskID == .dhcpScan)
        #expect(!start.isTerminal)
        let bogusTask = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"task_stage","task":99}"#))
        #expect(bogusTask.taskID == nil, "an id outside the catalog is not a TaskID")
        let bye = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"bye","exit_code":0}"#))
        #expect(bye.isTerminal)
        #expect(bye.taskID == nil)
        let hello = try #require(ProgressLineParser.parse(line: #"@@LSS {"v":1,"event":"hello","tasks":[1]}"#))
        #expect(!hello.isTerminal)
    }

    @Test("stage heuristic", arguments: [
        ("Stage 4: Ramping packet sizes", "Ramping packet sizes"),
        ("Stage 2: Baseline latency test (20 pings)...", "Baseline latency test (20 pings)..."),
        ("  stage 12 :  foo  ", "foo"),
        ("STAGE 1：Full-width colon", "Full-width colon"),
        ("\tStage 7: Recovery test (30 pings)...", "Recovery test (30 pings)..."),
        ("Stage: no number", nil),
        ("Stages 4: x", nil),
        ("Stage4: x", nil),
        ("Stage 4", nil),
        ("Stage 4 x", nil),
        ("Backstage 4: x", nil),
        ("Stage 4: ", nil),
        ("Step 1/2: Capturing 802.1Q tagged frames on en0 (10s)...", nil),
        ("", nil),
        ("Stag", nil),
    ] as [(String, String?)])
    func stageHeuristic(_ line: String, _ expected: String?) {
        #expect(ProgressLineParser.stageHeuristic(in: line) == expected, Comment(rawValue: line.debugDescription))
    }
}
