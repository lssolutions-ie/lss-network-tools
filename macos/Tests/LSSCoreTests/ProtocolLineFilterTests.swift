import Foundation
import Testing
@testable import LSSCore

/// `ProtocolLineFilter` removes the `@@LSS …` event lines from what the terminal
/// shows and passes everything else through byte for byte, immediately.
@Suite("ProtocolLineFilter")
struct ProtocolLineFilterTests {
    private static let progressFixtures: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/progress", directoryHint: .isDirectory)

    /// The hand-written pty captures (CRLF, spinners, ANSI) and the real stderr
    /// captures (LF, events only).
    private static let handWritten = ["full-audit.log", "single-task-17.log", "consent-required.log", "not-root.log", "missing-deps.log", "task-failed.log"]
    private static let realCaptures = ["real-consent-events.log", "real-not-root-events.log", "real-usage-events.log", "real-task1-events.log"]

    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: Self.progressFixtures.appending(path: name)))
    }

    private func filtered(_ text: String) -> String {
        String(decoding: ProtocolLineFilter.filtered(Array(text.utf8)), as: UTF8.self)
    }

    // MARK: Reference implementation

    /// Line-oriented reference: a `\n`-terminated line (or the unterminated tail) is
    /// cut from the first `@@LSS ` that stands at the start of a display line — at
    /// column 0, or after the last `\r` with nothing but complete `ESC [ … K`
    /// sequences in between — up to and including the `\n`.
    private static func reference(_ bytes: [UInt8]) -> [UInt8] {
        let marker = ProtocolLineFilter.marker
        var out: [UInt8] = []
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            let lineEnd = min(end + 1, bytes.count)
            let line = Array(bytes[start..<lineEnd])
            var cut: Int?
            var i = 0
            while i + marker.count <= line.count {
                if Array(line[i..<i + marker.count]) == marker, isLineStart(line[..<i]) {
                    cut = i
                    break
                }
                i += 1
            }
            if let cut {
                out += line[..<cut]
            } else {
                out += line
            }
            start = lineEnd
        }
        return out
    }

    private static func isLineStart(_ prefix: ArraySlice<UInt8>) -> Bool {
        let afterReturn = prefix.lastIndex(of: 0x0D).map { prefix[prefix.index(after: $0)...] } ?? prefix
        let text = String(decoding: afterReturn, as: UTF8.self)
        return text.range(of: #"^(\u{1B}\[[0-9;]*K)*$"#, options: .regularExpression) != nil
    }

    // MARK: Event lines

    @Test("a plain event line is dropped with its line ending; the lines around it stay")
    func dropsPlainEvent() {
        #expect(filtered("a\r\n@@LSS {\"v\":1,\"event\":\"hello\"}\r\nb\r\n") == "a\r\nb\r\n")
        #expect(filtered("@@LSS {\"v\":1,\"event\":\"bye\",\"exit_code\":0}\n") == "")
        #expect(filtered("x\n@@LSS {}\n@@LSS {}\ny\n") == "x\ny\n")
    }

    @Test("a tokenised event line is dropped as well")
    func dropsTokenisedEvent() {
        let token = ProgressLineParser.makeToken()
        #expect(filtered("@@LSS \(token) {\"v\":1,\"event\":\"hello\"}\r\nnext\r\n") == "next\r\n")
    }

    @Test("an event after the spinner's \\r or \\r ESC[K is dropped; the spinner frame stays")
    func dropsEventAfterSpinnerReturn() {
        #expect(filtered("[⠋] Pinging...\r\u{1B}[K@@LSS {\"event\":\"task_stage\"}\r\nStage 3\r\n") == "[⠋] Pinging...\r\u{1B}[KStage 3\r\n")
        #expect(filtered("frame\r@@LSS {}\r\nnext\n") == "frame\rnext\n")
        #expect(filtered("frame\r\u{1B}[2K@@LSS {}\nnext\n") == "frame\r\u{1B}[2Knext\n", "ESC [ 2 K is an erase-in-line too")
        #expect(filtered("frame\r\u{1B}[K\u{1B}[K@@LSS {}\nnext\n") == "frame\r\u{1B}[K\u{1B}[Knext\n")
        #expect(filtered("\u{1B}[K@@LSS {}\nnext\n") == "\u{1B}[Knext\n", "an erase at column 0 keeps the column")
    }

    // MARK: Lines that stay

    @Test("false starts are released intact", arguments: ["@\n", "@@\n", "@@L\n", "@@LS\n", "@@LSS\n", "@@LSSX {}\n", "@ at\n", "@@ two\n", "@@Lx\n", "@@LS\r\n", "@@LSS-not\n"])
    func keepsFalseStarts(_ line: String) {
        #expect(filtered(line) == line)
        #expect(filtered("before\n" + line + "after\n") == "before\n" + line + "after\n")
    }

    @Test("text that merely contains the marker stays visible")
    func keepsMidLineMarker() {
        #expect(filtered("SSID: @@LSS fake {\"event\":\"bye\"}\n") == "SSID: @@LSS fake {\"event\":\"bye\"}\n")
        #expect(filtered("  @@LSS {}\n") == "  @@LSS {}\n", "indented text is not an event")
        #expect(filtered("\u{1B}[1m@@LSS {}\u{1B}[0m\n") == "\u{1B}[1m@@LSS {}\u{1B}[0m\n", "other ANSI sequences do not keep the column")
        #expect(filtered("\u{1B}[K;@@LSS {}\n") == "\u{1B}[K;@@LSS {}\n", "a byte after a complete erase ends the column-0 state")
        #expect(filtered("\u{1B}[1K@@LSS {}\n") == "\u{1B}[1K", "but digits inside the erase sequence are fine: the erase passes, the event goes")
        // An incomplete escape sequence before the marker is not a line start: the
        // line stays, and the dangling ESC is not glued onto the next line.
        #expect(filtered("\u{1B}@@LSS {}\nnext\n") == "\u{1B}@@LSS {}\nnext\n", "a bare ESC before the marker keeps the line")
        #expect(filtered("\u{1B}[@@LSS {}\nnext\n") == "\u{1B}[@@LSS {}\nnext\n", "ESC [ without the final K keeps the line")
        #expect(filtered("\u{1B}[1@@LSS {}\nnext\n") == "\u{1B}[1@@LSS {}\nnext\n", "an unfinished ESC [ <digits> keeps the line")
        #expect(filtered("\r\u{1B}@@LSS {}\nnext\n") == "\r\u{1B}@@LSS {}\nnext\n", "also after the spinner's \\r")
        for line in ["\u{1B}@@LSS {}\n", "\u{1B}[@@LSS {}\n", "\u{1B}[1@@LSS {}\n"] {
            #expect(Self.reference(Array(line.utf8)) == Array(line.utf8), "the reference keeps it too")
        }
        // The hand-written fixture line where a spinner frame and an event share a
        // physical line without a \r: kept, as documented on the type.
        #expect(filtered("[⠙] Pinging 10.0.0.1...@@LSS {\"event\":\"task_stage\"}\r\n") == "[⠙] Pinging 10.0.0.1...@@LSS {\"event\":\"task_stage\"}\r\n")
    }

    @Test("ordinary text passes through immediately, without a trailing newline")
    func passesPromptImmediately() {
        var filter = ProtocolLineFilter()
        #expect(filter.feed(Array("Password: ".utf8)) == Array("Password: ".utf8))
        #expect(filter.feed(Array("\r\n".utf8)) == Array("\r\n".utf8))
        #expect(filter.feed(Array("@@LSS {}\r\n".utf8)) == [])
        #expect(filter.feed(Array("done".utf8)) == Array("done".utf8))
        #expect(filter.flush() == [])
    }

    @Test("CRLF, LF and bare CR endings are preserved on kept lines")
    func lineEndings() {
        #expect(filtered("a\r\nb\nc\rd") == "a\r\nb\nc\rd")
        #expect(filtered("\r\n\r\n@@LSS {}\r\n\r\n") == "\r\n\r\n\r\n")
        #expect(filtered("\n\n") == "\n\n")
        #expect(filtered("") == "")
    }

    @Test("a split UTF-8 sequence is passed through untouched (bytes, not characters)")
    func utf8Bytes() {
        let text = Array("  \u{1B}[1;33mStartup Check\u{1B}[0m\r\n  ════\r\n".utf8)
        var filter = ProtocolLineFilter()
        var out: [UInt8] = []
        for byte in text { out += filter.feed([byte]) }
        #expect(out == text)
    }

    // MARK: Held bytes

    @Test("a held marker prefix is released by flush and discarded by reset")
    func flushAndReset() {
        var filter = ProtocolLineFilter()
        #expect(filter.feed(Array("@@LS".utf8)) == [], "a proper prefix of the marker is held back")
        #expect(filter.flush() == Array("@@LS".utf8))
        #expect(filter.feed(Array("S {}\n".utf8)) == Array("S {}\n".utf8), "after flush the bytes belong to an ordinary line")

        filter.reset()
        #expect(filter.feed(Array("@@L".utf8)) == [])
        filter.reset()
        #expect(filter.feed(Array("x\n".utf8)) == Array("x\n".utf8), "reset drops what was held")

        // A reset while dropping ends the drop: the next bytes are a new line.
        _ = filter.feed(Array("@@LSS {\"v\":".utf8))
        filter.reset()
        #expect(filter.feed(Array("fresh\n".utf8)) == Array("fresh\n".utf8))

        // flush while dropping keeps dropping.
        var dropping = ProtocolLineFilter()
        _ = dropping.feed(Array("@@LSS {".utf8))
        #expect(dropping.flush() == [])
        #expect(dropping.feed(Array("}\nnext\n".utf8)) == Array("next\n".utf8))
    }

    // MARK: Fixtures

    @Test("the real captures are events only, so the display is empty", arguments: realCaptures)
    func realCapturesVanish(_ name: String) throws {
        let bytes = try fixture(name)
        #expect(!bytes.isEmpty)
        #expect(ProtocolLineFilter.filtered(bytes).isEmpty)
    }

    @Test("the pty fixtures equal their line-filtered expectation", arguments: handWritten)
    func handWrittenFixtures(_ name: String) throws {
        let bytes = try fixture(name)
        let expected = Self.reference(bytes)
        let actual = ProtocolLineFilter.filtered(bytes)
        #expect(actual == expected, "\(name): filtered output differs from the line-filtered expectation")
        #expect(actual.count < bytes.count, "\(name): every fixture carries at least one event")

        // Every event the parser sees on the raw stream is gone from the display,
        // except the one hand-written line where a spinner frame precedes the event
        // without a \r (full-audit.log), which is kept by design.
        var parser = ProgressLineParser()
        var output = parser.feed(bytes)
        output.events += parser.flush().events
        let shown = String(decoding: actual, as: UTF8.self)
        let visibleEvents = shown.components(separatedBy: ProgressLineParser.prefix).count - 1
        #expect(visibleEvents == (name == "full-audit.log" ? 1 : 0), "\(name): \(visibleEvents) event lines still visible")
        if name == "full-audit.log" {
            #expect(shown.contains("] Pinging 10.0.0.1...@@LSS "))
        }
        #expect(output.events.count >= 3)
    }

    @Test("what the fixtures show is kept: prompts, checklist rows, task output", arguments: handWritten)
    func humanTextSurvives(_ name: String) throws {
        let bytes = try fixture(name)
        let shown = String(decoding: ProtocolLineFilter.filtered(bytes), as: UTF8.self)
        if name == "full-audit.log" || name == "task-failed.log" {
            #expect(shown.hasPrefix("Password:\r\n"))
        }
        if name != "consent-required.log" {
            #expect(shown.contains("Dependency Checklist:\r\n"))
            #expect(shown.contains("[OK]\u{1B}[0m      nmap\r\n") || shown.contains("[MISSING]\u{1B}[0m nmap\r\n"))
        }
        #expect(!shown.contains("\"event\":\"hello\""), "no event JSON on screen")
        #expect(!shown.contains("\"event\":\"bye\""))
    }

    @Test("chunking never changes the output: byte by byte and in pseudo-random chunks", arguments: handWritten + realCaptures)
    func chunkInvariance(_ name: String) throws {
        let bytes = try fixture(name)
        let oneShot = ProtocolLineFilter.filtered(bytes)

        var byteWise = ProtocolLineFilter()
        var out: [UInt8] = []
        for byte in bytes { out += byteWise.feed([byte]) }
        out += byteWise.flush()
        #expect(out == oneShot, "\(name): byte-by-byte differs")

        // Deterministic LCG so a failure reproduces.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound)) + 1
        }
        for _ in 0..<5 {
            var chunked = ProtocolLineFilter()
            var result: [UInt8] = []
            var index = 0
            while index < bytes.count {
                let length = min(next(37), bytes.count - index)
                result += chunked.feed(bytes[index..<index + length])
                index += length
            }
            result += chunked.flush()
            #expect(result == oneShot, "\(name): chunked differs")
        }
    }

    @Test("the marker is the parser's prefix")
    func markerMatchesParser() {
        #expect(ProtocolLineFilter.marker == Array("@@LSS ".utf8))
        #expect(ProtocolLineFilter.marker == Array(ProgressLineParser.prefix.utf8))
    }
}
