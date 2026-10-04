import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the privileged helper is allowed to run (contract:
/// docs/research/07-m4-privilege-updates-contract.md §3 and §11, PLAN §8.2).
///
/// The helper never trusts the app for *what* to run:
/// * the executable comes from `install.env` as read here — `INSTALL_WRAPPER_PATH`
///   when that file exists (it must `exec` the script below), else
///   `APP_ROOT/lss-network-tools.sh`; install.env, the wrapper and the script must be
///   regular files owned by root, without group/world write, reached without any
///   symbolic link (`lstat` + `realpath`), and every folder on the way to them must be
///   root-owned and not group/world writable (`untrustedAncestor`);
/// * the argv must match the CLI's non-interactive grammar flag by flag (the sets
///   below, one value rule per flag; `FlagDriftTests` keeps them equal to
///   `ArgumentBuilder`'s and to the engine's `parse_args`);
/// * paths are canonicalised before they reach a root process: `--run-dir`,
///   `--build-report`, `--delete-run` and `--output` must all be real, root-owned
///   directories directly inside `DATA_ROOT/output` (a caller-owned `--output` folder is
///   refused: the report
///   names are predictable and bash `>` / fpdf `output()` follow a planted symlink), the
///   Wi-Fi scan file a regular file the caller owns inside their `…/scans/` folder;
/// * the tools the engine will run as root (`requiredTools`, and `optionalTools` when
///   present) must resolve through the engine's effective search order to root-owned,
///   non-writable executables under root-owned, non-writable folders, and every
///   existing folder on that search order must itself be root-owned and not
///   group/world writable — otherwise `untrustedToolchain` (refused, or reported for
///   the helper's authentication gate): a user-owned Homebrew prefix would otherwise
///   hand unattended root to whoever can write it;
/// * the child's environment is built from scratch; the SSH password and the
///   per-run progress token travel only in it.
///
/// The validated argv carries canonical spellings (normalised MAC, canonical paths).
/// Foundation only; every file-system observation goes through `Environment` so the unit
/// tests can simulate root-owned files.
///
/// The tool-chain rule has two policies (`ToolchainPolicy`, contract §11.2): `.refuse`
/// throws `untrustedToolchain` as before; `.report` lets the request through with
/// `Validated.toolchain == .untrusted(refusal)` so the helper can demand administrator
/// authentication for exactly that case — the boundary `sudo` draws, where a user-owned
/// Homebrew prefix runs as root only after a password.
public struct RequestValidator: Sendable {

    // MARK: - Limits and grammar

    /// Whole request (JSON, or argv + password) must stay below this.
    public static let maximumRequestSize = 64 * 1024
    /// `--wifi-scan-json` files must be smaller than this.
    public static let maximumScanFileSize: Int64 = 2 * 1024 * 1024
    /// Free-text values: 1…120 Unicode scalars (the same limit the GUI pre-flight applies).
    public static let maximumTextLength = ArgumentBuilder.maximumTextLength
    static let maximumPathLength = 1024
    static let maximumInstallEnvSize = 16 * 1024
    static let maximumWrapperSize = 64 * 1024
    static let maximumPasswordLength = 4096

    /// Where the app writes CoreWLAN scans, relative to the caller's home directory.
    public static let scansDirectoryRelativePath = "Library/Application Support/ie.lssolutions.lss-network-tools/scans"

    /// Flags whose value is free text: 1…120 scalars, no C0/C1 control, DEL or
    /// invisible / bidirectional format character, not starting with "-"
    /// (`isValidFreeText`). `--ssh-user` additionally has to look like a user name.
    public static let freeTextFlags: Set<String> = [
        "--client", "--location", "--note", "--prepared-by", "--building", "--floor", "--room",
        "--ap-label", "--controller", "--ssh-user",
    ]

    /// Valued flags with a structural rule of their own in `validate` (selection,
    /// interface names, IPv4, MAC, port, y/n, and the three kinds of path).
    public static let structuredFlags: Set<String> = [
        "--run-task", "--build-report", "--delete-run", "--run-dir", "--output", "--interface", "--wifi-interface",
        "--target", "--mac", "--controller-port", "--https", "--ap-present", "--wifi-scan-json",
    ]

    /// Every flag that takes one value: `structuredFlags` ∪ `freeTextFlags`.
    public static let valueFlags: Set<String> = structuredFlags.union(freeTextFlags)

    /// Flags without a value.
    public static let booleanFlags: Set<String> = ["--yes", "--no-pdf", "--debug"]

    /// Everything the helper lets through the grammar check. Must equal
    /// `ArgumentBuilder.valueFlags ∪ booleanFlags` (asserted by `FlagDriftTests`).
    public static let acceptedFlags: Set<String> = valueFlags.union(booleanFlags)

    /// The only flags `--build-report` may be combined with.
    public static let buildReportFlags: Set<String> = ["--build-report", "--prepared-by", "--output", "--no-pdf", "--debug"]

    /// The only flags `--delete-run` may be combined with (the engine's rule: `--debug` only).
    public static let deleteRunFlags: Set<String> = ["--delete-run", "--debug"]

    /// The three non-interactive modes; a request carries exactly one of them.
    public static let modeFlags: Set<String> = ["--run-task", "--build-report", "--delete-run"]

    /// Environment variables that carry secrets: never logged, never printed.
    public static let secretEnvironmentKeys: Set<String> = ["LSS_SSH_PASSWORD", "LSS_PROGRESS_TOKEN"]

    // MARK: - Tool chain

    /// What `ensure_standard_path` prepends on macOS, in the order the engine then
    /// searches (the wrapper exports the same list). Everything here comes before the
    /// child's PATH, so a writable folder among them shadows every system tool.
    public static let standardEngineSearchPathPrefix = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]

    /// Tools the engine runs as root in every mode (`check_tools` blocks without them).
    /// `awk sed grep find mktemp` and the macOS networking commands live in `/usr/bin`,
    /// `/sbin` and `/usr/sbin`; the search-order rule (every existing folder ahead of
    /// them root-owned) is what keeps those from being shadowed.
    public static let requiredTools = ["nmap", "jq", "python3", "tcpdump", "speedtest-cli"]

    /// Tools the engine uses when present (Tasks 12 and 19): checked only if found.
    public static let optionalTools = ["arp-scan", "sshpass"]

    /// The `tool` of an `untrustedToolchain` refusal that concerns a search-path folder
    /// rather than a tool.
    public static let searchPathLabel = "search path"

    // MARK: - File-system shim

    /// What `lstat(2)` reports about one path (a final symlink is reported, not followed).
    public struct FileStatus: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case regular, directory, symlink, other }

        public var kind: Kind
        public var ownerUID: uid_t
        /// Permission bits (`st_mode & 07777`).
        public var permissions: mode_t
        public var size: Int64

        public init(kind: Kind, ownerUID: uid_t, permissions: mode_t, size: Int64) {
            self.kind = kind
            self.ownerUID = ownerUID
            self.permissions = permissions
            self.size = size
        }

        public var isGroupOrWorldWritable: Bool { permissions & 0o022 != 0 }
    }

    /// Every observation the validator makes. `.live` uses `lstat`, `realpath`,
    /// `open(O_NOFOLLOW)` and `getpwuid_r`; tests substitute owners (they cannot create
    /// root-owned files) and point the search path at fixture folders.
    public struct Environment: Sendable {
        /// `/usr/local/share/lss-network-tools/install.env` — never taken from a request.
        public var installEnvPath: String
        /// `lstat(2)`; nil when the path does not exist.
        public var fileStatus: @Sendable (String) -> FileStatus?
        /// `realpath(3)`; nil when the path does not resolve.
        public var resolvePath: @Sendable (String) -> String?
        /// Contents of a regular file of at most `limit` bytes, opened without following
        /// a final symlink; nil otherwise.
        public var readFile: @Sendable (_ path: String, _ limit: Int) -> Data?
        /// Home directory of a user id.
        public var homeDirectory: @Sendable (uid_t) -> String?
        /// The PATH the child receives (`ProcessRunner.toolPATH`: the wrapper's, Homebrew
        /// first so `python3` is the one with fpdf2).
        public var childSearchPath: String
        /// What the engine prepends to that PATH (`standardEngineSearchPathPrefix`).
        public var engineSearchPathPrefix: [String]

        public init(
            installEnvPath: String,
            fileStatus: @escaping @Sendable (String) -> FileStatus?,
            resolvePath: @escaping @Sendable (String) -> String?,
            readFile: @escaping @Sendable (_ path: String, _ limit: Int) -> Data?,
            homeDirectory: @escaping @Sendable (uid_t) -> String?,
            childSearchPath: String = ProcessRunner.toolPATH,
            engineSearchPathPrefix: [String] = RequestValidator.standardEngineSearchPathPrefix
        ) {
            self.installEnvPath = installEnvPath
            self.fileStatus = fileStatus
            self.resolvePath = resolvePath
            self.readFile = readFile
            self.homeDirectory = homeDirectory
            self.childSearchPath = childSearchPath
            self.engineSearchPathPrefix = engineSearchPathPrefix
        }

        public static let live = Environment(
            installEnvPath: CLIInstall.defaultInstallEnv.path(percentEncoded: false),
            fileStatus: LiveFileSystem.status(of:),
            resolvePath: LiveFileSystem.resolve(_:),
            readFile: LiveFileSystem.read(_:limit:),
            homeDirectory: LiveFileSystem.homeDirectory(of:)
        )
    }

    // MARK: - Results

    public enum Refusal: Error, Hashable, Sendable, CustomStringConvertible {
        case installEnvUnreadable(String)
        case executableNotRootOwned(String)
        case executableWritable(String)
        case executableIsSymlink(String)
        case executableMissing(String)
        /// A folder on the way to `of` (install.env, the script, the wrapper or
        /// `DATA_ROOT/output`) that a non-root user could rename or replace.
        case untrustedAncestor(ancestor: String, of: String, reason: String)
        /// A tool the engine would run as root — or a folder on its search path
        /// (`tool == searchPathLabel`) — that a non-root user can modify, or a required
        /// tool that is not installed (`path` empty).
        case untrustedToolchain(tool: String, path: String, reason: String)
        case unknownFlag(String)
        case missingValue(String)
        case badValue(flag: String, value: String)
        case duplicateFlag(String)
        case runDirectoryOutsideOutput(String)
        case scanFileOutsideAllowed(String)
        case scanFileTooLarge(String)
        case requestTooLarge
        /// More than one mode, `--run-dir` with `--client/--location/--note`, `--output`
        /// with `--run-task`, a run flag with `--build-report`, or anything but `--debug`
        /// with `--delete-run`.
        case conflictingContext
        case noMode
        /// The request JSON did not decode, or its token is not a UUID-like string.
        case malformedRequest

        /// The reason `checkTool` gives for a required tool that is nowhere on the order.
        static let missingToolReason = "is not installed on the root search path (the engine would stop with exit code 3, missing dependency)"
        /// The reason `checkToolchain` gives for an empty or relative PATH entry.
        static let relativePathReason = "is not an absolute path"

        /// Whether administrator authentication is an answer to this refusal (contract
        /// §11.2, S4). True only for an `untrustedToolchain` verdict about a binary or
        /// folder a non-root user can modify — the boundary `sudo` draws, which a
        /// password crosses. A required tool that is not installed (`path` empty; the
        /// engine would exit 3 whoever runs it) or a search path with a relative entry
        /// (the helper's own PATH is malformed) is not a trust question: it stays a hard
        /// refusal under every `ToolchainPolicy`, and the app must not show a dialog for it.
        public var isClearedByAuthorization: Bool {
            guard case .untrustedToolchain(_, let path, let reason) = self else { return false }
            return !path.isEmpty && reason != Self.relativePathReason
        }

        /// Stable, value-free name for logs.
        public var code: String {
            switch self {
            case .installEnvUnreadable: "installEnvUnreadable"
            case .executableNotRootOwned: "executableNotRootOwned"
            case .executableWritable: "executableWritable"
            case .executableIsSymlink: "executableIsSymlink"
            case .executableMissing: "executableMissing"
            case .untrustedAncestor: "untrustedAncestor"
            case .untrustedToolchain: "untrustedToolchain"
            case .unknownFlag: "unknownFlag"
            case .missingValue: "missingValue"
            case .badValue: "badValue"
            case .duplicateFlag: "duplicateFlag"
            case .runDirectoryOutsideOutput: "runDirectoryOutsideOutput"
            case .scanFileOutsideAllowed: "scanFileOutsideAllowed"
            case .scanFileTooLarge: "scanFileTooLarge"
            case .requestTooLarge: "requestTooLarge"
            case .conflictingContext: "conflictingContext"
            case .noMode: "noMode"
            case .malformedRequest: "malformedRequest"
            }
        }

        /// One sentence for the GUI. Request-supplied text is shown sanitised and
        /// shortened; the SSH password and the progress token are never part of a refusal.
        public var description: String {
            switch self {
            case .installEnvUnreadable(let reason):
                "The CLI install record cannot be trusted: \(Self.shown(reason))."
            case .executableNotRootOwned(let path):
                "\(Self.shown(path)) is not owned by root, so the helper will not run it."
            case .executableWritable(let path):
                "\(Self.shown(path)) is writable by users other than root, so the helper will not run it."
            case .executableIsSymlink(let path):
                "\(Self.shown(path)) is or passes through a symbolic link, so the helper will not run it."
            case .executableMissing(let path):
                "\(Self.shown(path)) is missing, is not an executable regular file, or does not start the installed CLI."
            case .untrustedAncestor(let ancestor, let of, let reason):
                "\(Self.shown(ancestor)), a folder on the way to \(Self.shown(of)), \(Self.shown(reason)), so the helper does not trust anything below it."
            case .untrustedToolchain(let tool, let path, let reason):
                if path.isEmpty {
                    "The privileged helper cannot run the CLI: \(Self.shown(tool)) \(Self.shown(reason)). Install it where root can find it, or use “sudo in the terminal pane” in Settings → Privileges to see the engine's own dependency checklist."
                } else {
                    "The privileged helper runs tools a non-root user can modify only after administrator authentication (\(Self.shown(tool)): \(Self.shown(path)) \(Self.shown(reason)))."
                }
            case .unknownFlag(let flag):
                "“\(Self.shown(flag))” is not an argument the helper accepts."
            case .missingValue(let flag):
                "\(Self.shown(flag)) needs a value."
            case .badValue(let flag, let value):
                "Invalid value for \(Self.shown(flag)): “\(Self.shown(value))”."
            case .duplicateFlag(let flag):
                "\(Self.shown(flag)) appears more than once."
            case .runDirectoryOutsideOutput(let path):
                "\(Self.shown(path)) is not a run folder of the CLI (a real, root-owned folder directly inside DATA_ROOT/output; this applies to --run-dir, --build-report, --delete-run and --output alike)."
            case .scanFileOutsideAllowed(let path):
                "The Wi-Fi scan file \(Self.shown(path)) is not a regular file you own inside ~/\(RequestValidator.scansDirectoryRelativePath)/."
            case .scanFileTooLarge(let path):
                "The Wi-Fi scan file \(Self.shown(path)) is 2 MB or larger."
            case .requestTooLarge:
                "The request is 64 KB or larger."
            case .conflictingContext:
                "The request combines arguments that cannot be used together (more than one of --run-task, --build-report and --delete-run; --output with --run-task; --run-dir with --client/--location/--note; run flags with --build-report; anything but --debug with --delete-run)."
            case .noMode:
                "The request has none of --run-task, --build-report and --delete-run."
            case .malformedRequest:
                "The request could not be decoded."
            }
        }

        /// Control characters replaced, at most 160 characters.
        static func shown(_ text: String) -> String {
            var result = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) ? "?" : scalar
            }))
            if result.count > 160 { result = String(result.prefix(159)) + "…" }
            return result
        }
    }

    public struct Validated: Sendable, Hashable {
        /// `INSTALL_WRAPPER_PATH` (when it exists) or `APP_ROOT/lss-network-tools.sh`.
        public let executable: String
        /// argv after the executable, canonical spellings substituted.
        public let arguments: [String]
        /// Built from scratch: `baseChildEnvironment` + `LSS_SSH_PASSWORD` and
        /// `LSS_PROGRESS_TOKEN` when provided.
        public let environment: [String: String]
        /// `--run-dir` / `--build-report` / `--delete-run` target as the CLI expects it
        /// (`DATA_ROOT/output/<name>`).
        public let runDirectory: String?
        /// Whether the tools the child will run as root are all root-owned. Always
        /// `.trusted` under `ToolchainPolicy.refuse` (an untrusted chain throws there);
        /// under `.report` the helper decides what the `.untrusted` verdict requires.
        /// Never `.unusable`: that verdict is thrown under both policies.
        public let toolchain: ToolchainVerdict

        public init(executable: String, arguments: [String], environment: [String: String], runDirectory: String?,
                    toolchain: ToolchainVerdict) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.runDirectory = runDirectory
            self.toolchain = toolchain
        }
    }

    public let environment: Environment

    public init(environment: Environment = .live) {
        self.environment = environment
    }

    /// The environment every child starts with (plus the secrets when provided).
    /// PATH is `Environment.childSearchPath`.
    public var baseChildEnvironment: [String: String] {
        [
            "PATH": environment.childSearchPath,
            "HOME": "/var/root",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb",
            "LSS_QUIET_SPINNER": "1",
        ]
    }

    // MARK: - Entry points

    /// `HelperRunRequest` JSON as it arrives over XPC: size, decoding and token, then
    /// `validate(arguments:sshPassword:progressToken:callerUID:toolchainPolicy:)`. Keys the
    /// wire struct does not know (the authorization blob) are ignored here; the helper
    /// reads them from its own decoding.
    public func validate(requestJSON data: Data, callerUID: uid_t, toolchainPolicy: ToolchainPolicy = .refuse) throws -> Validated {
        guard data.count < Self.maximumRequestSize else { throw Refusal.requestTooLarge }
        guard let wire = try? JSONDecoder().decode(WireRequest.self, from: data), Self.isValidToken(wire.token) else {
            throw Refusal.malformedRequest
        }
        return try validate(arguments: wire.arguments, sshPassword: wire.sshPassword, progressToken: wire.progressToken,
                            callerUID: callerUID, toolchainPolicy: toolchainPolicy)
    }

    /// Validates one request. `callerUID` comes from the XPC connection (audit token),
    /// never from the request. `progressToken` is the app's per-run secret for the
    /// `@@LSS <token> {…}` events; it must match `isValidProgressToken` and is placed in
    /// the child environment as `LSS_PROGRESS_TOKEN`. `toolchainPolicy` decides whether a
    /// tool chain a non-root user can modify is refused (`.refuse`, the default) or
    /// reported in `Validated.toolchain` (`.report`); every other rule is a refusal
    /// under both.
    public func validate(arguments: [String], sshPassword: String?, progressToken: String? = nil, callerUID: uid_t,
                         toolchainPolicy: ToolchainPolicy = .refuse) throws -> Validated {
        let size = arguments.reduce(0) { $0 + $1.utf8.count + 4 } + (sshPassword?.utf8.count ?? 0) + (progressToken?.utf8.count ?? 0)
        guard size < Self.maximumRequestSize else { throw Refusal.requestTooLarge }

        // Grammar: known flags only, each once, valued flags followed by a value.
        var values: [String: String] = [:]
        var order: [String] = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if Self.valueFlags.contains(flag) {
                guard !order.contains(flag) else { throw Refusal.duplicateFlag(flag) }
                guard index + 1 < arguments.count, !Self.isFlag(arguments[index + 1]) else { throw Refusal.missingValue(flag) }
                values[flag] = arguments[index + 1]
                order.append(flag)
                index += 2
            } else if Self.booleanFlags.contains(flag) {
                guard !order.contains(flag) else { throw Refusal.duplicateFlag(flag) }
                order.append(flag)
                index += 1
            } else {
                throw Refusal.unknownFlag(flag)
            }
        }

        // Exactly one mode, and a context the CLI accepts.
        let modes = order.filter(Self.modeFlags.contains)
        if modes.count > 1 { throw Refusal.conflictingContext }
        guard let mode = modes.first else { throw Refusal.noMode }
        switch mode {
        case "--run-task":
            let newRunFlags = ["--client", "--location", "--note"].contains { values[$0] != nil }
            if values["--run-dir"] != nil && newRunFlags { throw Refusal.conflictingContext }
            if values["--output"] != nil { throw Refusal.conflictingContext }
        case "--build-report":
            if order.contains(where: { !Self.buildReportFlags.contains($0) }) { throw Refusal.conflictingContext }
        default: // --delete-run
            if order.contains(where: { !Self.deleteRunFlags.contains($0) }) { throw Refusal.conflictingContext }
        }

        let record = try loadInstallRecord()
        let executable = try resolveExecutable(record)

        // Per-flag value rules, in argv order; canonical spellings replace the originals.
        var replaced: [String: String] = [:]
        var runDirectory: String?
        for flag in order {
            guard let value = values[flag] else { continue }
            switch flag {
            case "--run-task":
                guard Self.isValidTaskSelection(value) else { throw Refusal.badValue(flag: flag, value: value) }
            case "--interface", "--wifi-interface":
                guard ArgumentBuilder.isValidInterfaceName(value) else { throw Refusal.badValue(flag: flag, value: value) }
            case "--target":
                guard ArgumentBuilder.isValidIPv4(value) else { throw Refusal.badValue(flag: flag, value: value) }
            case "--mac":
                guard let mac = ArgumentBuilder.normalizedMAC(value) else { throw Refusal.badValue(flag: flag, value: value) }
                replaced[flag] = mac
            case "--controller-port":
                guard Self.isValidPort(value) else { throw Refusal.badValue(flag: flag, value: value) }
            case "--https", "--ap-present":
                guard value == "y" || value == "n" else { throw Refusal.badValue(flag: flag, value: value) }
            case "--run-dir", "--build-report", "--delete-run":
                let directory = try runDirectoryArgument(value, record: record).argument
                replaced[flag] = directory
                runDirectory = directory
            case "--output":
                // Same rule as the run directory: a folder the caller owns would let
                // them plant a symlink under the predictable report names and have
                // the root child write through it.
                replaced[flag] = try runDirectoryArgument(value, record: record).argument
            case "--wifi-scan-json":
                replaced[flag] = try scanFileArgument(value, callerUID: callerUID)
            case "--ssh-user":
                guard Self.isValidFreeText(value), ArgumentBuilder.isValidSSHUser(value) else {
                    throw Refusal.badValue(flag: flag, value: value)
                }
            default:
                guard Self.freeTextFlags.contains(flag), Self.isValidFreeText(value) else {
                    throw Refusal.badValue(flag: flag, value: value)
                }
            }
        }

        var childEnvironment = baseChildEnvironment
        if let sshPassword, !sshPassword.isEmpty {
            guard sshPassword.utf8.count <= Self.maximumPasswordLength, !sshPassword.unicodeScalars.contains("\0") else {
                throw Refusal.badValue(flag: "LSS_SSH_PASSWORD", value: "(hidden)")
            }
            childEnvironment["LSS_SSH_PASSWORD"] = sshPassword
        }
        if let progressToken {
            guard Self.isValidProgressToken(progressToken) else {
                throw Refusal.badValue(flag: "LSS_PROGRESS_TOKEN", value: "(hidden)")
            }
            childEnvironment["LSS_PROGRESS_TOKEN"] = progressToken
        }

        // The tools the child will run as root, through the search order the engine
        // builds from this PATH. Under `.refuse` this fails closed before anything is
        // spawned; under `.report` an *untrusted* verdict travels with the result and the
        // helper insists on administrator authentication for it. An *unusable* chain
        // (missing required tool, relative PATH entry) is refused under both policies:
        // no authentication would make that run succeed.
        let toolchain = toolchainVerdict(childPATH: childEnvironment["PATH"] ?? "")
        switch toolchain {
        case .trusted: break
        case .unusable(let refusal): throw refusal
        case .untrusted(let refusal): if toolchainPolicy == .refuse { throw refusal }
        }

        var argv: [String] = []
        for flag in order {
            argv.append(flag)
            if let value = values[flag] { argv.append(replaced[flag] ?? value) }
        }
        return Validated(executable: executable, arguments: argv, environment: childEnvironment, runDirectory: runDirectory,
                         toolchain: toolchain)
    }

    /// The tool-chain verdict on its own — `checkToolchain` against the PATH every child
    /// receives — without reading the install record. The helper answers
    /// `toolchainTrust` with it, so the app knows before a run whether the standard
    /// authentication dialog will be needed.
    public func toolchainVerdict() -> ToolchainVerdict {
        toolchainVerdict(childPATH: baseChildEnvironment["PATH"] ?? environment.childSearchPath)
    }

    func toolchainVerdict(childPATH: String) -> ToolchainVerdict {
        do {
            try checkToolchain(childPATH: childPATH)
            return .trusted
        } catch let refusal as Refusal {
            return refusal.isClearedByAuthorization ? .untrusted(refusal) : .unusable(refusal)
        } catch {
            // `checkToolchain` throws nothing else; stay closed should that ever change.
            return .untrusted(.untrustedToolchain(tool: Self.searchPathLabel, path: childPATH, reason: "could not be checked"))
        }
    }

    /// `repairRunPermissions`: the canonical path of one run directory directly inside
    /// `DATA_ROOT/output` (real, root-owned, not group/world writable).
    public func validateRepair(runDirectory: String) throws -> String {
        guard runDirectory.utf8.count < Self.maximumRequestSize else { throw Refusal.requestTooLarge }
        let record = try loadInstallRecord()
        return try runDirectoryArgument(runDirectory, record: record).canonical
    }

    // MARK: - Install record and executable

    struct InstallRecord {
        let appRoot: String
        /// `DATA_ROOT/output` spelled as the CLI computes it (`OUTPUT_DIR="$DATA_ROOT/output"`).
        let configuredOutput: String
        let wrapper: String?
    }

    /// install.env must be a regular root-owned file without group/world write, reached
    /// without symlinks and below trusted folders; the CLI `source`s it as root. APP_ROOT
    /// must be the folder that holds it (the script reads `$SCRIPT_DIR/install.env`).
    func loadInstallRecord() throws -> InstallRecord {
        let path = environment.installEnvPath
        guard let status = environment.fileStatus(path) else {
            throw Refusal.installEnvUnreadable("\(path) does not exist")
        }
        guard status.kind != .symlink, environment.resolvePath(path) == path else {
            throw Refusal.installEnvUnreadable("\(path) is or passes through a symbolic link")
        }
        guard status.kind == .regular else { throw Refusal.installEnvUnreadable("\(path) is not a regular file") }
        guard status.ownerUID == 0 else { throw Refusal.installEnvUnreadable("\(path) is not owned by root") }
        guard !status.isGroupOrWorldWritable else { throw Refusal.installEnvUnreadable("\(path) is writable by group or others") }
        try checkAncestors(of: path)
        guard let data = environment.readFile(path, Self.maximumInstallEnvSize),
              let text = String(data: data, encoding: .utf8) else {
            throw Refusal.installEnvUnreadable("\(path) cannot be read")
        }
        let values = CLIInstall.parseInstallEnv(text)
        guard let appRoot = values["APP_ROOT"].flatMap(Self.plainAbsolutePath) else {
            throw Refusal.installEnvUnreadable("APP_ROOT is missing or not a plain absolute path")
        }
        var dataRoot = appRoot
        if let raw = values["DATA_ROOT"], !raw.isEmpty {
            guard let parsed = Self.plainAbsolutePath(raw) else {
                throw Refusal.installEnvUnreadable("DATA_ROOT is not a plain absolute path")
            }
            dataRoot = parsed
        }
        var wrapper: String?
        if let raw = values["INSTALL_WRAPPER_PATH"], !raw.isEmpty {
            guard let parsed = Self.plainAbsolutePath(raw) else {
                throw Refusal.installEnvUnreadable("INSTALL_WRAPPER_PATH is not a plain absolute path")
            }
            wrapper = parsed
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard let resolvedRoot = environment.resolvePath(appRoot), resolvedRoot == environment.resolvePath(folder) else {
            throw Refusal.installEnvUnreadable("APP_ROOT \(appRoot) is not the folder that holds install.env")
        }
        let configuredOutput = dataRoot == "/" ? "/output" : dataRoot + "/output"
        return InstallRecord(appRoot: appRoot, configuredOutput: configuredOutput, wrapper: wrapper)
    }

    /// The script is always checked; the wrapper is used when it exists, after the same
    /// checks and only if it `exec`s exactly that script.
    func resolveExecutable(_ record: InstallRecord) throws -> String {
        let script = record.appRoot == "/" ? "/" + CLIInstall.scriptName : record.appRoot + "/" + CLIInstall.scriptName
        try checkExecutable(script)
        guard let wrapper = record.wrapper, environment.fileStatus(wrapper) != nil else { return script }
        try checkExecutable(wrapper)
        guard let data = environment.readFile(wrapper, Self.maximumWrapperSize),
              let text = String(data: data, encoding: .utf8),
              let target = CLIInstall.parseWrapper(text),
              environment.resolvePath(target) == script else {
            throw Refusal.executableMissing(wrapper)
        }
        return wrapper
    }

    func checkExecutable(_ path: String) throws {
        guard let status = environment.fileStatus(path) else { throw Refusal.executableMissing(path) }
        guard status.kind != .symlink, environment.resolvePath(path) == path else { throw Refusal.executableIsSymlink(path) }
        guard status.kind == .regular, status.permissions & 0o111 != 0 else { throw Refusal.executableMissing(path) }
        guard status.ownerUID == 0 else { throw Refusal.executableNotRootOwned(path) }
        guard !status.isGroupOrWorldWritable else { throw Refusal.executableWritable(path) }
        try checkAncestors(of: path)
    }

    // MARK: - Trust of folders and tools

    /// `untrustedAncestor` when a folder on the way to `path` is not root-owned, is
    /// group/world writable or is missing. `path` is canonical here (callers checked
    /// that it passes through no symlink), so one chain is walked.
    func checkAncestors(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if let problem = untrustedComponent(of: parent.isEmpty ? "/" : parent) {
            throw Refusal.untrustedAncestor(ancestor: problem.component, of: path, reason: problem.reason)
        }
    }

    /// Walks `path` from `/` down to the entry itself — in the given spelling and, when
    /// it resolves elsewhere, in its canonical spelling — and returns the first component
    /// that does not exist, is not owned by root, or (symbolic links excepted: a link has
    /// no mode of its own that matters, its owner and its folder decide where it points)
    /// is group/world writable.
    func untrustedComponent(of path: String) -> (component: String, reason: String)? {
        var chains = [path]
        if let resolved = environment.resolvePath(path), resolved != path { chains.append(resolved) }
        for chain in chains {
            for component in Self.components(of: chain) {
                guard let status = environment.fileStatus(component) else { return (component, "does not exist") }
                guard status.ownerUID == 0 else { return (component, "is owned by uid \(status.ownerUID), not root") }
                guard status.kind == .symlink || !status.isGroupOrWorldWritable else {
                    return (component, "is writable by group or others")
                }
            }
        }
        return nil
    }

    /// `"/a/b/c"` → `["/", "/a", "/a/b", "/a/b/c"]`; `"/"` → `["/"]`.
    static func components(of path: String) -> [String] {
        var result = ["/"]
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    /// The engine's effective tool search order: what `ensure_standard_path` prepends,
    /// then the child's PATH entries, each folder once (first occurrence wins).
    public static func effectiveSearchPath(prefix: [String], childPATH: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for entry in prefix + childPATH.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
            guard seen.insert(entry).inserted else { continue }
            order.append(entry)
        }
        return order
    }

    /// Fails closed when the engine, running as root from this PATH, would execute
    /// something a non-root user can modify:
    /// 1. every folder on the effective search order that exists must be root-owned, not
    ///    group/world writable and below trusted folders (a writable folder *anywhere*
    ///    on the order — ahead of or behind the current match — could receive a trojan
    ///    `nmap` between this check and the engine's lookup);
    /// 2. each required tool must resolve (first existing entry in the order, then
    ///    `realpath`) to a regular executable owned by root, not group/world writable,
    ///    below trusted folders; optional tools only when they exist;
    /// 3. a required tool that is nowhere on the order is refused as well — the engine
    ///    would stop with exit code 3 — so the reason is named here instead.
    func checkToolchain(childPATH: String) throws {
        let order = Self.effectiveSearchPath(prefix: environment.engineSearchPathPrefix, childPATH: childPATH)
        var folders: [String] = []
        for entry in order {
            // An empty or relative entry means "the current directory" to the shell.
            guard let folder = Self.cleanAbsolutePath(entry) ?? (entry == "/" ? "/" : nil) else {
                throw Refusal.untrustedToolchain(tool: Self.searchPathLabel, path: entry, reason: Refusal.relativePathReason)
            }
            folders.append(folder)
            guard environment.fileStatus(folder) != nil else { continue } // absent: the shell skips it too
            if let problem = untrustedComponent(of: folder) {
                throw Refusal.untrustedToolchain(tool: Self.searchPathLabel, path: folder, reason: Self.phrase(problem, path: folder, resolved: environment.resolvePath(folder)))
            }
            guard let resolved = environment.resolvePath(folder), environment.fileStatus(resolved)?.kind == .directory else {
                throw Refusal.untrustedToolchain(tool: Self.searchPathLabel, path: folder, reason: "is not a directory")
            }
        }
        for tool in Self.requiredTools { try checkTool(tool, in: folders, required: true) }
        for tool in Self.optionalTools { try checkTool(tool, in: folders, required: false) }
    }

    func checkTool(_ tool: String, in folders: [String], required: Bool) throws {
        for folder in folders {
            let entry = folder == "/" ? "/" + tool : folder + "/" + tool
            guard environment.fileStatus(entry) != nil else { continue }
            let resolved = environment.resolvePath(entry)
            if let problem = untrustedComponent(of: entry) {
                throw Refusal.untrustedToolchain(tool: tool, path: entry, reason: Self.phrase(problem, path: entry, resolved: resolved))
            }
            guard let resolved, let status = environment.fileStatus(resolved),
                  status.kind == .regular, status.permissions & 0o111 != 0 else {
                throw Refusal.untrustedToolchain(tool: tool, path: entry, reason: "is not a regular executable file")
            }
            return
        }
        if required {
            throw Refusal.untrustedToolchain(tool: tool, path: "", reason: Refusal.missingToolReason)
        }
    }

    /// "is owned by …" when the offending component is the entry itself, "resolves to
    /// X, which …" when it is the link's target, "passes through X, which …" otherwise.
    static func phrase(_ problem: (component: String, reason: String), path: String, resolved: String?) -> String {
        if problem.component == path { return problem.reason }
        if problem.component == resolved { return "resolves to \(problem.component), which \(problem.reason)" }
        return "passes through \(problem.component), which \(problem.reason)"
    }

    // MARK: - Path arguments

    /// A run directory: `<configured output>/<name>` for argv and the canonical path.
    func runDirectoryArgument(_ value: String, record: InstallRecord) throws -> (argument: String, canonical: String) {
        let refusal = Refusal.runDirectoryOutsideOutput(value)
        guard let path = Self.cleanAbsolutePath(value), let output = try secureOutputDirectory(record) else { throw refusal }
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { throw refusal }
        // lstat of the path as given: the run directory itself must not be a symlink.
        guard let given = environment.fileStatus(path), given.kind == .directory else { throw refusal }
        let canonical = output + "/" + name
        guard environment.resolvePath(path) == canonical,
              let status = environment.fileStatus(canonical), status.kind == .directory,
              status.ownerUID == 0, !status.isGroupOrWorldWritable else { throw refusal }
        return (record.configuredOutput + "/" + name, canonical)
    }

    /// Canonical `DATA_ROOT/output` when it is a real directory owned by root without
    /// group/world write (otherwise anyone could plant entries the CLI writes through),
    /// below trusted folders (`untrustedAncestor` otherwise).
    func secureOutputDirectory(_ record: InstallRecord) throws -> String? {
        guard let canonical = environment.resolvePath(record.configuredOutput),
              let status = environment.fileStatus(canonical), status.kind == .directory,
              status.ownerUID == 0, !status.isGroupOrWorldWritable else { return nil }
        try checkAncestors(of: canonical)
        return canonical
    }

    /// `--wifi-scan-json`: canonical path of a regular file < 2 MB owned by the caller,
    /// directly inside `<caller home>/Library/Application Support/ie.lssolutions.lss-network-tools/scans/`.
    func scanFileArgument(_ value: String, callerUID: uid_t) throws -> String {
        let refusal = Refusal.scanFileOutsideAllowed(value)
        guard callerUID != 0,
              let path = Self.cleanAbsolutePath(value),
              let home = environment.homeDirectory(callerUID), home.hasPrefix("/"),
              let allowed = environment.resolvePath(home + "/" + Self.scansDirectoryRelativePath),
              let canonical = environment.resolvePath(path),
              (canonical as NSString).deletingLastPathComponent == allowed,
              let status = environment.fileStatus(canonical), status.kind == .regular,
              status.ownerUID == callerUID else { throw refusal }
        guard status.size < Self.maximumScanFileSize else { throw Refusal.scanFileTooLarge(value) }
        return canonical
    }

    // MARK: - Value rules

    /// `^(000|list|[0-9]{1,2}(,[0-9]{1,2})*)$` with every id in 1…20.
    public static func isValidTaskSelection(_ value: String) -> Bool {
        if value == "000" || value == "list" { return true }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 20 else { return false }
        for part in parts {
            guard (1...2).contains(part.unicodeScalars.count),
                  part.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let id = Int(part), (1...20).contains(id) else { return false }
        }
        return true
    }

    /// 1–5 ASCII digits, 1…65535.
    public static func isValidPort(_ value: String) -> Bool {
        guard (1...5).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let port = Int(value) else { return false }
        return (1...65535).contains(port)
    }

    /// 1…120 scalars, not starting with "-", without C0/C1 controls, DEL or the
    /// invisible / bidirectional format characters (`ArgumentBuilder.isInvisibleOrBidi`).
    public static func isValidFreeText(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maximumTextLength, !value.hasPrefix("-") else { return false }
        return !scalars.contains { $0.value < 0x20 || $0.value == 0x7F || ArgumentBuilder.isInvisibleOrBidi($0) }
    }

    /// `^[A-Za-z0-9-]{1,64}$` (the app sends `UUID().uuidString`).
    public static func isValidToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard (1...64).contains(scalars.count) else { return false }
        return scalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `^[A-Za-z0-9_-]{8,64}$` — the engine's `LSS_PROGRESS_TOKEN` grammar
    /// (`ProgressLineParser.isValidToken`).
    public static func isValidProgressToken(_ token: String) -> Bool {
        ProgressLineParser.isValidToken(token)
    }

    static func isFlag(_ text: String) -> Bool {
        acceptedFlags.contains(text)
    }

    /// A request path: absolute, no control characters, no empty / "." / ".." components
    /// (trailing slashes are dropped). nil otherwise.
    static func cleanAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"), value.utf8.count <= maximumPathLength,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        var path = value
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path != "/" else { return nil }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return path
    }

    /// An install.env value bash would read literally: a clean absolute path without
    /// quotes, `$`, backticks, backslashes or other characters `source` interprets.
    static func plainAbsolutePath(_ value: String) -> String? {
        let allowed = value.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || "/._-+@ ".unicodeScalars.contains(scalar)
        }
        guard allowed else { return nil }
        if value == "/" { return "/" }
        return cleanAbsolutePath(value)
    }

    private struct WireRequest: Decodable {
        let token: String
        let arguments: [String]
        let sshPassword: String?
        let progressToken: String?
    }
}

/// The validator's view of the tools the engine will run as root (`checkToolchain`).
public enum ToolchainVerdict: Sendable, Hashable {
    /// Every folder on the search order and every tool resolve to root-owned,
    /// non-writable entries: the helper may run without a password.
    case trusted
    /// The `untrustedToolchain` refusal the validator would otherwise throw, about a tool
    /// or folder a non-root user can modify (`Refusal.isClearedByAuthorization`); under
    /// `ToolchainPolicy.report` the helper requires administrator authentication.
    case untrusted(RequestValidator.Refusal)
    /// An `untrustedToolchain` refusal no authentication clears — a required tool missing
    /// from the root search path, or a relative PATH entry. `validate` throws it under
    /// both policies; `toolchainVerdict()` reports it so the app shows "cannot run"
    /// rather than asking for a password.
    case unusable(RequestValidator.Refusal)
}

/// What `RequestValidator.validate` does with an untrusted tool chain.
public enum ToolchainPolicy: Sendable {
    /// Throw `Refusal.untrustedToolchain` (password-less runs: the default).
    case refuse
    /// Return `Validated.toolchain = .untrusted(refusal)`; argv and environment are
    /// what `.refuse` would have produced for a root-owned chain. An `.unusable`
    /// verdict is still thrown.
    case report
}

/// The real file system, without following a final symlink anywhere it matters.
enum LiveFileSystem {
    static func status(of path: String) -> RequestValidator.FileStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: RequestValidator.FileStatus.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return RequestValidator.FileStatus(kind: kind, ownerUID: info.st_uid, permissions: info.st_mode & 0o7777, size: Int64(info.st_size))
    }

    static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func read(_ path: String, limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.count <= limit ? data : nil
    }

    static func homeDirectory(of uid: uid_t) -> String? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        guard getpwuid_r(uid, &record, &buffer, buffer.count, &result) == 0, result != nil, let directory = record.pw_dir else {
            return nil
        }
        return String(cString: directory)
    }
}
