import Foundation
import Testing
@testable import LSSCore

@Suite("CLIExitCode")
struct CLIExitCodeTests {
    @Test("raw values mirror PLAN §7.2")
    func rawValues() {
        #expect(CLIExitCode.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 130])
        #expect(CLIExitCode(rawValue: 0) == .success)
        #expect(CLIExitCode(rawValue: 1) == .taskFailed)
        #expect(CLIExitCode(rawValue: 2) == .usage)
        #expect(CLIExitCode(rawValue: 3) == .missingDependencies)
        #expect(CLIExitCode(rawValue: 4) == .consentRequired)
        #expect(CLIExitCode(rawValue: 5) == .notRoot)
        #expect(CLIExitCode(rawValue: 130) == .interrupted)
    }

    @Test("codes the script never emits map to nil")
    func unknownCodes() {
        #expect(CLIExitCode(rawValue: 6) == nil)
        #expect(CLIExitCode(rawValue: 127) == nil)
        #expect(CLIExitCode(rawValue: -1) == nil)
    }

    @Test("every code has a distinct one-sentence summary", arguments: CLIExitCode.allCases)
    func summaries(code: CLIExitCode) {
        let summary = code.summary
        #expect(!summary.isEmpty)
        #expect(summary.hasSuffix("."))
        #expect(!summary.contains("\n"))
        let others = CLIExitCode.allCases.filter { $0 != code }.map(\.summary)
        #expect(!others.contains(summary))
    }
}
