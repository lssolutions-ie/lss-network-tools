import Foundation

/// Streaming byte filter that removes the engine's progress-protocol lines from
/// what the terminal *displays*. The raw stream still goes to `ProgressLineParser`
/// (it needs the events); only the bytes handed to the terminal view pass through
/// here. Everything that is not an event line is emitted at once — there is no
/// line buffering, so sudo's `Password:` prompt (no trailing newline) appears
/// immediately — and the only bytes ever held back are a partial `@@LSS ` marker
/// at the start of a line, at most five of them.
///
/// What counts as "the start of a line" follows the fixtures under
/// `Tests/Fixtures/progress/`:
/// * column 0 after `\n` (every real capture: `real-*.log`, LF or CRLF endings);
/// * directly after a bare `\r` — a terminal returns to column 0 there, so an event
///   following the spinner's `\r` starts a fresh display line;
/// * after `\r` followed by one or more complete erase-in-line sequences
///   (`ESC [ <digits;> K`): the spinner's `\r\x1b[K` before it hands the line over —
///   `full-audit.log` has `…Pinging 10.0.0.1...\r\x1b[K@@LSS {…}\r\n`, which displays
///   as `…Pinging 10.0.0.1...\r\x1b[K` followed by the next line.
///
/// A line that merely *contains* `@@LSS ` after other text — an echoed SSID, or the
/// hand-written fixture line where a spinner frame and an event share one physical
/// line without a `\r` in between (`[⠙] Pinging 10.0.0.1...@@LSS {…}`) — stays
/// visible untouched: matching only at the start of a line is what keeps
/// device-supplied strings from hiding the rest of their line. The real engine
/// never produces that case: non-interactive mode exports `LSS_QUIET_SPINNER=1`, so
/// events always follow a `\n`.
///
/// An event line is dropped up to and including its `\n`; the `\r` of a CRLF
/// ending goes with it. Any other ANSI sequence before the marker (`\x1b[1m@@LSS …`)
/// leaves the line visible — the engine never colours an event line — and so does
/// an *incomplete* erase sequence (`\x1b@@LSS`, `\x1b[@@LSS`, `\x1b[1@@LSS`): the
/// marker only counts when nothing of an escape sequence is pending, otherwise the
/// dangling `ESC` would be glued onto the next kept line and garble it.
///
/// The interactive CLI never writes `@@LSS `, so the same filter on an interactive
/// pty is a no-op apart from the marker-prefix hold-back, which a false start such
/// as `@@L` releases on the very next byte.
public struct ProtocolLineFilter: Sendable {
    /// The marker an event line starts with: `ProgressLineParser.prefix` (`@@LSS `),
    /// which covers both `@@LSS {…}` and `@@LSS <token> {…}`.
    public static let marker: [UInt8] = Array(ProgressLineParser.prefix.utf8)

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let escape: UInt8 = 0x1B

    /// Where an erase-in-line sequence stands while the filter is still "at the
    /// start of a line": nothing pending, `ESC` seen, `ESC [` plus parameters seen.
    private enum Erase: Sendable {
        case none, escape, csi
    }

    private enum State: Sendable {
        /// Column 0 of a display line (after `\n`, `\r`, or `\r` + erase sequences).
        case lineStart(Erase)
        /// The last `count` bytes were a proper prefix of `marker`; they are held back.
        case matchingPrefix(count: Int)
        /// An ordinary line: bytes pass through until `\n` (or `\r`, see above).
        case passing
        /// An event line: bytes are dropped up to and including `\n`.
        case dropping
    }

    private var state: State = .lineStart(.none)

    public init() {}

    // MARK: - Feeding

    /// Filters one chunk. Chunk boundaries may fall anywhere, including inside the
    /// marker; the output of any split of a stream equals the output of the
    /// stream fed in one piece.
    public mutating func feed(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        consume(bytes)
    }

    public mutating func feed(_ bytes: [UInt8]) -> [UInt8] {
        consume(bytes)
    }

    public mutating func feed(_ data: Data) -> [UInt8] {
        consume(data)
    }

    /// Releases a held marker prefix (at most `@@LSS`, five bytes) at the end of a
    /// stream so a final false start such as `@@L` is not lost. An event line that
    /// is still being dropped stays dropped.
    public mutating func flush() -> [UInt8] {
        guard case .matchingPrefix(let count) = state else { return [] }
        state = .passing
        return Array(Self.marker[..<count])
    }

    /// Back to the start of a line with nothing held back — for a new process.
    public mutating func reset() {
        state = .lineStart(.none)
    }

    /// One-shot convenience: `feed` + `flush` on a fresh filter.
    public static func filtered(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var filter = ProtocolLineFilter()
        var out = filter.consume(bytes)
        out += filter.flush()
        return out
    }

    // MARK: - State machine

    private mutating func consume(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount)
        for byte in bytes {
            switch state {
            case .lineStart(let erase):
                if byte == Self.marker[0], case .none = erase {
                    state = .matchingPrefix(count: 1)
                } else {
                    out.append(byte)
                    state = Self.stateAfterLineStartByte(byte, erase: erase)
                }
            case .matchingPrefix(let count):
                if byte == Self.marker[count] {
                    state = count + 1 == Self.marker.count ? .dropping : .matchingPrefix(count: count + 1)
                } else {
                    out.append(contentsOf: Self.marker[..<count])
                    out.append(byte)
                    state = Self.stateAfterPassingByte(byte)
                }
            case .passing:
                out.append(byte)
                state = Self.stateAfterPassingByte(byte)
            case .dropping:
                if byte == Self.lineFeed { state = .lineStart(.none) }
            }
        }
        return out
    }

    /// A byte at the start of a line that is not the marker's first byte: line
    /// terminators keep the column at 0, and so does a complete `ESC [ … K`.
    private static func stateAfterLineStartByte(_ byte: UInt8, erase: Erase) -> State {
        switch byte {
        case lineFeed, carriageReturn: return .lineStart(.none)
        case escape: return .lineStart(.escape)
        default: break
        }
        switch erase {
        case .escape where byte == UInt8(ascii: "["):
            return .lineStart(.csi)
        case .csi where (0x30...0x39).contains(byte) || byte == UInt8(ascii: ";"):
            return .lineStart(.csi)
        case .csi where byte == UInt8(ascii: "K"):
            return .lineStart(.none)
        default:
            return .passing
        }
    }

    private static func stateAfterPassingByte(_ byte: UInt8) -> State {
        byte == lineFeed || byte == carriageReturn ? .lineStart(.none) : .passing
    }
}
