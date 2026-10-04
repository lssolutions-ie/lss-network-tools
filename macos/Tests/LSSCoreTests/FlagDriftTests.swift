import Foundation
import Testing
@testable import LSSCore

/// The engine's command-line grammar as read from `lss-network-tools.sh`.
struct EngineFlagGrammar: Equatable, Sendable {
    /// `--flag)` arms whose body consumes a value (`parse_args_require_value` / `shift`).
    var valued: Set<String> = []
    /// Arms without a value.
    var boolean: Set<String> = []
    /// The `compgen -W "…"` list of the bash completion function.
    var completion: Set<String> = []

    var all: Set<String> { valued.union(boolean) }

    /// Parses `parse_args() { … case "$1" in … esac … }`: every `--flag)` arm (also
    /// `--a|--b)`), valued when its body calls `parse_args_require_value "$@"` or
    /// `shift`s the value away, boolean otherwise; the `*)` arm and comments are
    /// skipped. nil when the function or its `case` cannot be found.
    static func parse(script: String) -> EngineFlagGrammar? {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("parse_args()") }),
              let end = lines[start...].firstIndex(where: { $0 == "}" }) else { return nil }
        let body = lines[start...end]
        guard let caseLine = body.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case \"$1\" in") }),
              let esac = body[caseLine...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "esac" }) else { return nil }

        var grammar = EngineFlagGrammar()
        var index = caseLine + 1
        while index < esac {
            let head = body[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard head.hasPrefix("--"), head.hasSuffix(")") else { continue }
            let patterns = head.dropLast().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard patterns.allSatisfy({ $0.range(of: "^--[a-z0-9-]+$", options: .regularExpression) != nil }) else { continue }

            var arm: [String] = []
            while index < esac {
                let line = body[index].trimmingCharacters(in: .whitespaces)
                index += 1
                if line == ";;" { break }
                arm.append(line)
            }
            let valued = arm.contains { $0.hasPrefix("parse_args_require_value") || $0 == "shift" || $0.hasPrefix("shift ") }
            for pattern in patterns {
                if valued { grammar.valued.insert(pattern) } else { grammar.boolean.insert(pattern) }
            }
        }

        if let range = script.range(of: #"compgen -W "[^"]*""#, options: .regularExpression) {
            let match = script[range]
            if let open = match.firstIndex(of: "\""), let close = match.lastIndex(of: "\""), open < close {
                grammar.completion = Set(match[match.index(after: open)..<close].split(separator: " ").map(String.init).filter { $0.hasPrefix("--") })
            }
        }
        return grammar
    }
}

/// Switches the engine accepts for its interactive / maintenance modes only. The
/// GUI never sends them, so `ArgumentBuilder` does not list them (`--debug` is the
/// one it shares). They must stay boolean.
private let interactiveOnlyFlags: Set<String> = [
    "--debug", "--uninstall", "--update", "--version", "--build-wifi-helper", "--write-completions", "--install-deps",
]

private let sampleScript = """
#!/usr/bin/env bash
_lss_completions() {
  COMPREPLY=($(compgen -W "--debug --alpha --beta" -- "$cur"))
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --debug)
        DEBUG_MODE=1
        ;;
      # ── a comment that ends with a parenthesis (exit 2)
      --alpha)
        # Mode first so a missing value still reports through the protocol.
        ALPHA_MODE=1
        parse_args_require_value "$@"
        _ALPHA="$2"
        shift
        ;;
      --beta|--gamma)
        _BETA="$2"
        shift
        ;;
      *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
    shift
  done
}

parse_args_require_value() {
  if [[ "$#" -lt 2 ]]; then
    exit 2
  fi
}
"""

/// `ArgumentBuilder`, `RequestValidator` and the engine's `parse_args` must agree on
/// every flag and its arity; `TaskIDTests` does the same for `TASKS_DATA`. Point
/// `LSS_ENGINE_SCRIPT` at an edited copy of the script to see these fail.
@Suite("Flag drift: parse_args ⇄ ArgumentBuilder ⇄ RequestValidator")
struct FlagDriftTests {
    private func engine() throws -> EngineFlagGrammar {
        let script = try String(contentsOf: engineScriptURL, encoding: .utf8)
        return try #require(EngineFlagGrammar.parse(script: script), "parse_args() not found in \(engineScriptURL.path(percentEncoded: false))")
    }

    @Test("the grammar parser reads arity from the arm body and skips `*)` and comments")
    func parserShape() throws {
        let grammar = try #require(EngineFlagGrammar.parse(script: sampleScript))
        #expect(grammar.valued == ["--alpha", "--beta", "--gamma"])
        #expect(grammar.boolean == ["--debug"])
        #expect(grammar.completion == ["--debug", "--alpha", "--beta"])
        #expect(EngineFlagGrammar.parse(script: "echo no parser here") == nil)
    }

    @Test("the real script parses to the expected shape")
    func realScriptShape() throws {
        let grammar = try engine()
        // 23 valued (`--run-task`, `--build-report`, `--delete-run` + the 20 run flags)
        // + 2 boolean non-interactive flags, 7 interactive-only switches. A lower
        // bound only; `builderFlagsExistInEngine` is what catches a dropped arm.
        #expect(grammar.valued.count >= 23, "valued: \(grammar.valued.sorted())")
        #expect(grammar.boolean.count >= 9, "boolean: \(grammar.boolean.sorted())")
        #expect(grammar.valued.isDisjoint(with: grammar.boolean))
        #expect(!grammar.completion.isEmpty, "completion list (compgen -W) not found")
    }

    @Test("every ArgumentBuilder flag is a parse_args arm with the same arity")
    func builderFlagsExistInEngine() throws {
        let grammar = try engine()
        for flag in ArgumentBuilder.valueFlags.sorted() {
            let detail = grammar.boolean.contains(flag) ? "takes no value in parse_args" : "is not a parse_args arm"
            #expect(grammar.valued.contains(flag), "\(flag) \(detail)")
        }
        for flag in ArgumentBuilder.booleanFlags.sorted() {
            let detail = grammar.valued.contains(flag) ? "takes a value in parse_args" : "is not a parse_args arm"
            #expect(grammar.boolean.contains(flag), "\(flag) \(detail)")
        }
    }

    @Test("every non-interactive flag parse_args accepts is known to ArgumentBuilder with the same arity")
    func engineFlagsKnownToBuilder() throws {
        let grammar = try engine()
        for flag in grammar.valued.sorted() where !interactiveOnlyFlags.contains(flag) {
            #expect(ArgumentBuilder.valueFlags.contains(flag), "\(flag) takes a value in parse_args but ArgumentBuilder.valueFlags lacks it")
        }
        for flag in grammar.boolean.sorted() where !interactiveOnlyFlags.contains(flag) {
            #expect(ArgumentBuilder.booleanFlags.contains(flag), "\(flag) is a switch in parse_args but ArgumentBuilder.booleanFlags lacks it")
        }
        for flag in interactiveOnlyFlags.sorted() {
            #expect(grammar.boolean.contains(flag), "\(flag) is expected to be an interactive-only switch")
        }
    }

    @Test("the completion list names every GUI flag and nothing parse_args lacks")
    func completionList() throws {
        let grammar = try engine()
        for flag in ArgumentBuilder.valueFlags.union(ArgumentBuilder.booleanFlags).sorted() {
            #expect(grammar.completion.contains(flag), "\(flag) is missing from the compgen -W completion list")
        }
        for flag in grammar.completion.sorted() {
            #expect(grammar.all.contains(flag), "completion lists \(flag), which parse_args does not accept")
        }
    }

    @Test("RequestValidator accepts exactly ArgumentBuilder's grammar")
    func validatorMatchesBuilder() {
        #expect(RequestValidator.valueFlags == ArgumentBuilder.valueFlags)
        #expect(RequestValidator.booleanFlags == ArgumentBuilder.booleanFlags)
        #expect(RequestValidator.acceptedFlags == ArgumentBuilder.valueFlags.union(ArgumentBuilder.booleanFlags))
        #expect(RequestValidator.structuredFlags.isDisjoint(with: RequestValidator.freeTextFlags))
        #expect(RequestValidator.buildReportFlags.isSubset(of: RequestValidator.acceptedFlags))
        #expect(RequestValidator.deleteRunFlags.isSubset(of: RequestValidator.acceptedFlags))
        #expect(RequestValidator.modeFlags.isSubset(of: RequestValidator.structuredFlags))
        #expect(RequestValidator.modeFlags.isSubset(of: RequestValidator.buildReportFlags.union(RequestValidator.deleteRunFlags).union(["--run-task"])))
        #expect(ArgumentBuilder.valueFlags.isDisjoint(with: ArgumentBuilder.booleanFlags))
        #expect(RequestValidator.maximumTextLength == ArgumentBuilder.maximumTextLength)
    }
}
