import Foundation

/// Result of a short, non-interactive child process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

/// Runs short helper commands (`networksetup`, `route`, `<cli> --version`).
/// Not for the bash engine itself: that runs under a pty (M1–M3) or the
/// privileged helper (M4), both of which stream output.
public enum ProcessRunner {
    /// The PATH the CLI wrapper exports. Homebrew first, so `python3` resolves to
    /// the interpreter that has fpdf2 (research 04). Every process the GUI spawns
    /// uses this PATH; a launchd-started app otherwise inherits a bare one.
    public static let toolPATH =
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Base environment for anything the GUI launches.
    public static var baseEnvironment: [String: String] {
        [
            "PATH": toolPATH,
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }

    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox(
            executable: executable,
            arguments: arguments,
            environment: environment ?? baseEnvironment,
            currentDirectory: currentDirectory
        )
        return try await box.run()
    }
}

/// `Process`/`Pipe` are not Sendable; this box owns them for one run and is
/// only ever touched sequentially (launch, then reads after exit).
private final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()

    init(executable: String, arguments: [String], environment: [String: String], currentDirectory: URL?) {
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run() async throws -> ProcessResult {
        // Readers start before launch so a chatty child can never fill the pipe
        // buffer and deadlock against a termination-time read.
        let outTask = Task.detached { [self] in self.stdout.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { [self] in self.stderr.fileHandleForReading.readDataToEndOfFile() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // Unblock the readers: nothing will ever write to these pipes.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }

        let out = await outTask.value
        let err = await errTask.value
        return ProcessResult(
            status: status,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }
}
