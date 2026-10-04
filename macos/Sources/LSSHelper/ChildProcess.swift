import Darwin
import Foundation

/// One CLI process started with `posix_spawn` (contract §4).
///
/// * stdin is `/dev/null`; stdout and stderr are both the descriptor received over XPC
///   (one stream, like the pty path);
/// * `POSIX_SPAWN_CLOEXEC_DEFAULT`: nothing else of the helper leaks into the child;
/// * `POSIX_SPAWN_SETSID`: the child leads a new session and process group, so
///   `terminate()` can reach the tools the script starts (nmap, tcpdump, python);
/// * signal dispositions are reset to their defaults and the mask is emptied, so the
///   script's INT/TERM trap works whatever the helper inherited from launchd.
///
/// Thread safety: `pid` is immutable; `exited` and the kill timer are guarded by `lock`.
/// That is the whole mutable state, hence `@unchecked Sendable`.
final class ChildProcess: @unchecked Sendable {
    static let terminationGracePeriod: TimeInterval = 5

    let pid: pid_t
    private let lock = NSLock()
    private var exited = false
    private var terminationRequested = false
    private var killTimer: DispatchWorkItem?

    private init(pid: pid_t) {
        self.pid = pid
    }

    struct SpawnError: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "posix_spawn failed: \(String(cString: strerror(code))) (\(code))" }
    }

    static func spawn(executable: String, arguments: [String], environment: [String: String], outputDescriptor: Int32) throws -> ChildProcess {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { throw SpawnError(code: errno) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SpawnError(code: errno) }
        defer { posix_spawnattr_destroy(&attributes) }

        var result = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        if result == 0 { result = posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDOUT_FILENO) }
        if result == 0 { result = posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDERR_FILENO) }
        guard result == 0 else { throw SpawnError(code: result) }

        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        result = posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM, SIGCHLD, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        if result == 0 { result = posix_spawnattr_setsigdefault(&attributes, &defaults) }
        if result == 0 { result = posix_spawnattr_setsigmask(&attributes, &emptyMask) }
        guard result == 0 else { throw SpawnError(code: result) }

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        result = posix_spawn(&pid, executable, &fileActions, &attributes, argv + [nil], envp + [nil])
        guard result == 0 else { throw SpawnError(code: result) }
        return ChildProcess(pid: pid)
    }

    /// Blocks until the child exits and returns its exit code (128 + signal when it was
    /// killed). `waitid(WNOWAIT)` leaves the zombie in place while `exited` is set, so a
    /// concurrent `terminate()` can never signal a recycled pid; `waitpid` then reaps it.
    func waitForExit() -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        lock.lock()
        exited = true
        killTimer?.cancel()
        killTimer = nil
        let cancelled = terminationRequested
        lock.unlock()
        // The script stops the tools it started; anything still in its process group
        // (after a SIGKILL, say) would keep running as root and hold the output pipe.
        // The zombie leader keeps the group id from being recycled until it is reaped.
        _ = kill(-pid, cancelled ? SIGKILL : SIGTERM)
        var status: Int32 = 0
        var reaped: pid_t
        repeat {
            reaped = waitpid(pid, &status, 0)
        } while reaped == -1 && errno == EINTR
        guard reaped == pid else { return -1 }
        return Self.exitCode(fromWaitStatus: status)
    }

    /// SIGTERM to the child's process group (the script's TERM trap exits 130 and stops
    /// its background tools), then SIGKILL to the group after the grace period.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !exited, killTimer == nil else { return }
        terminationRequested = true
        if kill(-pid, SIGTERM) != 0 { _ = kill(pid, SIGTERM) }
        let item = DispatchWorkItem { [weak self] in self?.forceKill() }
        killTimer = item
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGracePeriod, execute: item)
    }

    private func forceKill() {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else { return }
        if kill(-pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
    }

    /// `WIFEXITED` → `WEXITSTATUS`; `WIFSIGNALED` → 128 + `WTERMSIG`; anything else -1.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return -1
    }
}
