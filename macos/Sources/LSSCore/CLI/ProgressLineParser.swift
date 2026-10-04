import Foundation

/// Streaming parser for the pty byte stream of a non-interactive run: picks
/// `@@LSS {…}` events out of the interleaved human output and hands back the
/// other complete lines (ANSI-stripped) for the log / stage heuristic.
/// Partial lines and split UTF-8 sequences are carried across `feed` calls.
///
/// Line model (what a pty actually delivers):
/// * Lines end in `\n`; the `\r` a pty puts before it is dropped.
/// * A bare `\r` inside a line is a spinner overwriting itself; only the text
///   after the last `\r` is what the terminal shows, so only that segment is
///   kept (a `\r\e[K` that clears the line therefore yields nothing).
/// * `@@LSS ` may be preceded on the same physical line by a spinner frame
///   (the spinner is a background process writing to the same tty); the text
///   from the prefix to the end of the line is the event, the text before it
///   is a human line when non-empty.
///
/// Authentication: the engine echoes device-supplied strings (SSIDs, host
/// names, banners) on the same stream, so an in-band consumer could be fed a
/// forged `@@LSS {…}`. The app therefore gives every run a secret
/// (`LSS_PROGRESS_TOKEN`, `^[A-Za-z0-9_-]{8,64}$`) and the engine writes its
/// events as `@@LSS <token> {…}`. A parser created with that token treats only
/// lines carrying it as events; `@@LSS {…}` without the token, or with another
/// one, is not an event — it is counted in `rejectedLineCount` and delivered as
/// a human line, exactly as the terminal shows it. Without a token (fixtures,
/// `lss-network-tools --run-task … 2>progress.log` users) the untokened format
/// is the one accepted.
public struct ProgressLineParser: Sendable {
    public static let prefix = "@@LSS "

    public struct Output: Sendable, Hashable {
        public var events: [ProgressEvent]
        /// Complete non-progress lines, ANSI-stripped; for a `\r`-overwritten
        /// line (spinners) only the last segment is kept.
        public var lines: [String]

        public init(events: [ProgressEvent] = [], lines: [String] = []) {
            self.events = events
            self.lines = lines
        }
    }

    /// The per-run secret the events must carry (`@@LSS <token> {…}`), or nil
    /// for the untokened format.
    public let token: String?

    /// `@@LSS` lines whose JSON did not parse (or had no `event`).
    public private(set) var malformedLineCount = 0

    /// Lines that looked like events (`@@LSS …`) but did not carry this
    /// parser's token. Only ever non-zero when a token is set; such lines are
    /// delivered through `Output.lines` instead.
    public private(set) var rejectedLineCount = 0

    /// Bytes of the current, not yet newline-terminated line. Kept as bytes so a
    /// multi-byte UTF-8 sequence split across two `feed` calls decodes intact.
    private var pending: [UInt8] = []

    /// `token` should satisfy `isValidToken` (the shape the engine accepts in
    /// `LSS_PROGRESS_TOKEN`); `makeToken()` produces one.
    public init(token: String? = nil) {
        self.token = token
    }

    // MARK: - Tokens

    /// `^[A-Za-z0-9_-]{8,64}$` — the grammar `noninteractive_setup` accepts; a
    /// value outside it is ignored by the engine (events stay untokened).
    public static func isValidToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard (8...64).contains(scalars.count) else { return false }
        return scalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// 32 lower-case hex characters (128 bits) from the system's cryptographic
    /// random number generator.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    // MARK: - Feeding

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> Output {
        var output = Output()
        for byte in bytes {
            if byte == 0x0A {
                let line = pending
                pending.removeAll(keepingCapacity: true)
                process(lineBytes: line[...], into: &output)
            } else {
                pending.append(byte)
            }
        }
        return output
    }

    public mutating func feed(_ text: String) -> Output {
        feed(Array(text.utf8))
    }

    /// Emits whatever is still buffered as a final line (or event). A prompt
    /// without a newline (sudo's `Password:`) only surfaces here.
    public mutating func flush() -> Output {
        var output = Output()
        guard !pending.isEmpty else { return output }
        let line = pending
        pending.removeAll()
        process(lineBytes: line[...], into: &output)
        return output
    }

    /// Parses one complete line. Leading ANSI sequences / whitespace (or a
    /// spinner frame) before the marker are allowed; returns nil when the line
    /// is not a progress line (for this `token`) or its JSON is malformed.
    public static func parse(line: String, token: String? = nil) -> ProgressEvent? {
        guard let split = splitEvent(stripANSI(line), token: token) else { return nil }
        return parseEventText(split.json)
    }

    /// Removes CSI (`ESC [ … final`), OSC (`ESC ] … BEL` / `ESC \`) and other
    /// two-byte `ESC x` sequences. `\r`, `\t` and the text are left alone.
    public static func stripANSI(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{1B}") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                i += 1
                continue
            }
            let next = i + 1
            guard next < scalars.count else { break } // lone trailing ESC
            switch scalars[next] {
            case "[":
                // CSI: parameter / intermediate bytes 0x20–0x3F, final byte 0x40–0x7E.
                var j = next + 1
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) { j += 1 }
                i = min(j + 1, scalars.count)
            case "]":
                // OSC: up to BEL or ST (ESC \). An unterminated OSC eats the rest.
                var j = next + 1
                var end = scalars.count
                while j < scalars.count {
                    if scalars[j] == "\u{07}" { end = j + 1; break }
                    if scalars[j] == "\u{1B}" {
                        end = (j + 1 < scalars.count && scalars[j + 1] == "\\") ? j + 2 : j
                        break
                    }
                    j += 1
                }
                i = end
            default:
                // Two-byte escape (ESC 7, ESC 8, ESC =, ESC >, ESC M, …).
                i = next + 1
            }
        }
        return String(out)
    }

    /// `"Stage 4: Ramping packet sizes"` → `"Ramping packet sizes"`; best-effort
    /// for tasks that emit no `task_stage` events. Matches
    /// `^\s*Stage\s+(\d+)\s*[:：]\s*(.+)$` with a case-insensitive "stage" and
    /// returns the trailing label trimmed.
    public static func stageHeuristic(in line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        var i = 0
        func skipSpaces() { while i < scalars.count, scalars[i].properties.isWhitespace { i += 1 } }

        skipSpaces()
        let keyword = Array("stage".unicodeScalars)
        guard i + keyword.count <= scalars.count else { return nil }
        for (offset, expected) in keyword.enumerated() {
            let actual = scalars[i + offset]
            guard actual.properties.lowercaseMapping == String(expected) else { return nil }
        }
        i += keyword.count

        // At least one whitespace, then at least one digit.
        guard i < scalars.count, scalars[i].properties.isWhitespace else { return nil }
        skipSpaces()
        var digits = 0
        while i < scalars.count, ("0"..."9").contains(scalars[i]) { i += 1; digits += 1 }
        guard digits > 0 else { return nil }

        skipSpaces()
        guard i < scalars.count, scalars[i] == ":" || scalars[i] == "：" else { return nil }
        i += 1

        let label = String(String.UnicodeScalarView(scalars[i...])).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    // MARK: - Line processing

    private mutating func process(lineBytes: ArraySlice<UInt8>, into output: inout Output) {
        var bytes = lineBytes
        while bytes.last == 0x0D { bytes.removeLast() } // pty CRLF, and stray CRs right before the newline
        guard !bytes.isEmpty else { return }

        let stripped = Self.stripANSI(String(decoding: bytes, as: UTF8.self))
        if let split = Self.splitEvent(stripped, token: token) {
            let before = Self.lastSegment(split.before).trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { output.lines.append(before) }
            // Tokened: an `@@LSS ` written ahead of the genuine marker on the same
            // physical line is echoed text, not an event.
            if token != nil, split.before.contains(Self.prefix) { rejectedLineCount += 1 }
            if let event = Self.parseEventText(split.json) {
                output.events.append(event)
            } else {
                malformedLineCount += 1
            }
        } else {
            if token != nil, stripped.contains(Self.prefix) {
                // Looks like an event but does not carry this run's token: text the
                // engine echoed from a device. Shown as the terminal shows it.
                rejectedLineCount += 1
            }
            let line = Self.lastSegment(stripped[...])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { output.lines.append(line) }
        }
    }

    /// The text after the last bare `\r` (what the terminal shows), trailing
    /// whitespace removed, leading indentation kept.
    private static func lastSegment(_ text: Substring) -> String {
        let segment = text.split(separator: "\r", omittingEmptySubsequences: false).last ?? ""
        var result = String(segment)
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    /// Splits an ANSI-stripped line at the first event marker — `@@LSS <token> `
    /// when a token is set, `@@LSS ` otherwise. `json` runs from the marker to
    /// the end of the line, or to the next `\r` if a spinner frame was written
    /// after the JSON. nil when the marker does not occur.
    private static func splitEvent(_ stripped: String, token: String?) -> (before: Substring, json: Substring)? {
        let marker = token.map { prefix + $0 + " " } ?? prefix
        guard let range = stripped.range(of: marker) else { return nil }
        let before = stripped[..<range.lowerBound]
        var json = stripped[range.upperBound...]
        if let cr = json.firstIndex(of: "\r") { json = json[..<cr] }
        return (before, json)
    }

    /// `{…}` → event; nil when the JSON does not parse, is not an object or has
    /// no `event` (callers count that as malformed).
    private static func parseEventText(_ text: Substring) -> ProgressEvent? {
        let json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.hasPrefix("{"), let data = json.data(using: .utf8) else { return nil }
        // A plain decoder: LSSJSON's snake_case conversion would rename the keys
        // (`exit_code` → `exitCode`) inside `fields`.
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value,
              let name = object.string("event") else { return nil }
        guard let kind = makeKind(name: name, object: object) else { return nil }
        let timestamp = object.string("ts").flatMap(LSSJSON.parseISO8601)
        return ProgressEvent(kind: kind, timestamp: timestamp, protocolVersion: object.int("v"), fields: value)
    }

    /// Maps the `event` name to a `Kind` (contract §1.2). A known event missing
    /// the field the enum cannot do without (`task`, `path`) is malformed.
    private static func makeKind(name: String, object: [String: JSONValue]) -> ProgressEvent.Kind? {
        switch name {
        case "hello":
            return .hello(version: object.string("version"), pid: object.int("pid"), tasks: object.ints("tasks"))
        case "run_dir":
            guard let path = object.string("path") else { return nil }
            return .runDirectory(path: path, created: object.bool("created"))
        case "task_start":
            guard let task = object.int("task") else { return nil }
            return .taskStart(task: task, title: object.string("title"), index: object.int("index"), total: object.int("total"))
        case "task_stage":
            guard let task = object.int("task") else { return nil }
            return .taskStage(task: task, stage: object.string("stage"), label: object.string("label"))
        case "task_done":
            guard let task = object.int("task") else { return nil }
            return .taskDone(task: task, status: object.string("status"), exitCode: object.int("rc"), jsonFiles: object.strings("json_files"))
        case "report_built":
            return .reportBuilt(txt: object.string("txt"))
        case "pdf_built":
            return .pdfBuilt(pdf: object.string("pdf"))
        case "pdf_failed":
            return .pdfFailed(message: object.string("message"))
        case "warning":
            return .warning(code: object.string("code"), message: object.string("message"))
        case "error":
            return .error(code: object.string("code"), message: object.string("message"), tools: object.strings("tools"))
        case "bye":
            return .bye(exitCode: object.int("exit_code"))
        default:
            return .unknown(event: name)
        }
    }
}

// MARK: - Tolerant field access

private extension Dictionary where Key == String, Value == JSONValue {
    /// Strings as written; numbers and booleans rendered, so a numeric `status`
    /// or `version` still reads.
    func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let text)?: return text
        case .number(let number)?: return Self.render(number)
        case .bool(let flag)?: return flag ? "true" : "false"
        default: return nil
        }
    }

    /// Numbers, and numeric strings (`"task":"4"`).
    func int(_ key: String) -> Int? {
        guard let number = self[key]?.numberValue, number.isFinite, abs(number) < 9.0e15 else { return nil }
        return Int(number)
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0
        case .string(let text)?:
            switch text.lowercased() {
            case "true", "yes", "y", "1": return true
            case "false", "no", "n", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    func strings(_ key: String) -> [String] {
        (self[key]?.arrayValue ?? []).compactMap { item in
            switch item {
            case .string(let text): text
            case .number(let number): Self.render(number)
            default: nil
            }
        }
    }

    func ints(_ key: String) -> [Int] {
        (self[key]?.arrayValue ?? []).compactMap { item in
            guard let number = item.numberValue, number.isFinite, abs(number) < 9.0e15 else { return nil }
            return Int(number)
        }
    }

    private static func render(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}
