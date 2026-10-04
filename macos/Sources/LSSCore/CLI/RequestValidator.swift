import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the privileged helper is allowed to run (contract:
/// docs/research/07-m4-privilege-updates-contract.md §3, PLAN §8.2).
///
/// The helper never trusts the app for *what* to run:
/// * the executable comes from `install.env` as read here — `INSTALL_WRAPPER_PATH`
///   when that file exists (it must `exec` the script below), else
///   `APP_ROOT/lss-network-tools.sh`; install.env, the wrapper and the script must be
///   regular files owned by root, without group/world write, and reached without any
///   symbolic link (`lstat` + `realpath`);
/// * the argv must match the CLI's non-interactive grammar flag by flag
///   (`ArgumentBuilder.valueFlags` / `booleanFlags`, one value rule per flag);
/// * paths are canonicalised before they reach a root process: run directories must be
///   real, root-owned directories directly inside `DATA_ROOT/output`, the Wi-Fi scan file
///   a regular file the caller owns inside their `…/scans/` folder;
/// * the child's environment is built from scratch.
///
/// The validated argv carries canonical spellings (normalised MAC, canonical paths).
/// Foundation only; every file-system observation goes through `Environment` so the unit
/// tests can simulate root-owned files.
public struct RequestValidator: Sendable {

    // MARK: - Limits and grammar

    /// Whole request (JSON, or argv + password) must stay below this.
    public static let maximumRequestSize = 64 * 1024
    /// `--wifi-scan-json` files must be smaller than this.
    public static let maximumScanFileSize: Int64 = 2 * 1024 * 1024
    /// Free-text values: 1…120 Unicode scalars.
    public static let maximumTextLength = 120
    static let maximumPathLength = 1024
    static let maximumInstallEnvSize = 16 * 1024
    static let maximumWrapperSize = 64 * 1024
    static let maximumPasswordLength = 4096

    /// Where the app writes CoreWLAN scans, relative to the caller's home directory.
    public static let scansDirectoryRelativePath = "Library/Application Support/ie.lssolutions.lss-network-tools/scans"

    /// Flags whose value is free text: `^[^\x00-\x1f\x7f]{1,120}$`, not starting with "-".
    public static let freeTextFlags: Set<String> = [
        "--client", "--location", "--note", "--prepared-by", "--building", "--floor", "--room",
        "--ap-label", "--controller", "--ssh-user",
    ]

    /// The only flags `--build-report` may be combined with.
    public static let buildReportFlags: Set<String> = ["--build-report", "--prepared-by", "--output", "--no-pdf", "--debug"]

    /// The environment every child starts with (plus `LSS_SSH_PASSWORD` when provided).
    /// PATH is the wrapper's: Homebrew first, so `python3` is the one with fpdf2.
    public static let baseEnvironment: [String: String] = [
        "PATH": ProcessRunner.toolPATH,
        "HOME": "/var/root",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "TERM": "dumb",
        "LSS_QUIET_SPINNER": "1",
    ]

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
    /// root-owned files).
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

        public init(
            installEnvPath: String,
            fileStatus: @escaping @Sendable (String) -> FileStatus?,
            resolvePath: @escaping @Sendable (String) -> String?,
            readFile: @escaping @Sendable (_ path: String, _ limit: Int) -> Data?,
            homeDirectory: @escaping @Sendable (uid_t) -> String?
        ) {
            self.installEnvPath = installEnvPath
            self.fileStatus = fileStatus
            self.resolvePath = resolvePath
            self.readFile = readFile
            self.homeDirectory = homeDirectory
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
        case unknownFlag(String)
        case missingValue(String)
        case badValue(flag: String, value: String)
        case duplicateFlag(String)
        case runDirectoryOutsideOutput(String)
        case scanFileOutsideAllowed(String)
        case scanFileTooLarge(String)
        case requestTooLarge
        /// Both modes, `--run-dir` with `--client/--location/--note`, `--output` with
        /// `--run-task`, or a run flag with `--build-report`.
        case conflictingContext
        case noMode
        /// The request JSON did not decode, or its token is not a UUID-like string.
        case malformedRequest

        /// Stable, value-free name for logs.
        public var code: String {
            switch self {
            case .installEnvUnreadable: "installEnvUnreadable"
            case .executableNotRootOwned: "executableNotRootOwned"
            case .executableWritable: "executableWritable"
            case .executableIsSymlink: "executableIsSymlink"
            case .executableMissing: "executableMissing"
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
        /// shortened; the SSH password is never part of a refusal.
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
            case .unknownFlag(let flag):
                "“\(Self.shown(flag))” is not an argument the helper accepts."
            case .missingValue(let flag):
                "\(Self.shown(flag)) needs a value."
            case .badValue(let flag, let value):
                "Invalid value for \(Self.shown(flag)): “\(Self.shown(value))”."
            case .duplicateFlag(let flag):
                "\(Self.shown(flag)) appears more than once."
            case .runDirectoryOutsideOutput(let path):
                "\(Self.shown(path)) is not a run folder of the CLI (a real, root-owned folder directly inside DATA_ROOT/output; --output may also name a folder you own)."
            case .scanFileOutsideAllowed(let path):
                "The Wi-Fi scan file \(Self.shown(path)) is not a regular file you own inside ~/\(RequestValidator.scansDirectoryRelativePath)/."
            case .scanFileTooLarge(let path):
                "The Wi-Fi scan file \(Self.shown(path)) is 2 MB or larger."
            case .requestTooLarge:
                "The request is 64 KB or larger."
            case .conflictingContext:
                "The request combines arguments that cannot be used together (--run-task with --build-report or --output, --run-dir with --client/--location/--note, or run flags with --build-report)."
            case .noMode:
                "The request has neither --run-task nor --build-report."
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
        /// Built from scratch: `baseEnvironment` + `LSS_SSH_PASSWORD` when provided.
        public let environment: [String: String]
        /// `--run-dir` / `--build-report` target as the CLI expects it (`DATA_ROOT/output/<name>`).
        public let runDirectory: String?

        public init(executable: String, arguments: [String], environment: [String: String], runDirectory: String?) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.runDirectory = runDirectory
        }
    }

    public let environment: Environment

    public init(environment: Environment = .live) {
        self.environment = environment
    }

    // MARK: - Entry points

    /// `HelperRunRequest` JSON as it arrives over XPC: size, decoding and token, then
    /// `validate(arguments:sshPassword:callerUID:)`.
    public func validate(requestJSON data: Data, callerUID: uid_t) throws -> Validated {
        guard data.count < Self.maximumRequestSize else { throw Refusal.requestTooLarge }
        guard let wire = try? JSONDecoder().decode(WireRequest.self, from: data), Self.isValidToken(wire.token) else {
            throw Refusal.malformedRequest
        }
        return try validate(arguments: wire.arguments, sshPassword: wire.sshPassword, callerUID: callerUID)
    }

    /// Validates one request. `callerUID` comes from the XPC connection (audit token),
    /// never from the request.
    public func validate(arguments: [String], sshPassword: String?, callerUID: uid_t) throws -> Validated {
        let size = arguments.reduce(0) { $0 + $1.utf8.count + 4 } + (sshPassword?.utf8.count ?? 0)
        guard size < Self.maximumRequestSize else { throw Refusal.requestTooLarge }

        // Grammar: known flags only, each once, valued flags followed by a value.
        var values: [String: String] = [:]
        var order: [String] = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if ArgumentBuilder.valueFlags.contains(flag) {
                guard !order.contains(flag) else { throw Refusal.duplicateFlag(flag) }
                guard index + 1 < arguments.count, !Self.isFlag(arguments[index + 1]) else { throw Refusal.missingValue(flag) }
                values[flag] = arguments[index + 1]
                order.append(flag)
                index += 2
            } else if ArgumentBuilder.booleanFlags.contains(flag) {
                guard !order.contains(flag) else { throw Refusal.duplicateFlag(flag) }
                order.append(flag)
                index += 1
            } else {
                throw Refusal.unknownFlag(flag)
            }
        }

        // Exactly one mode, and a context the CLI accepts.
        let runTask = values["--run-task"] != nil
        let buildReport = values["--build-report"] != nil
        if runTask && buildReport { throw Refusal.conflictingContext }
        if !runTask && !buildReport { throw Refusal.noMode }
        if runTask {
            let newRunFlags = ["--client", "--location", "--note"].contains { values[$0] != nil }
            if values["--run-dir"] != nil && newRunFlags { throw Refusal.conflictingContext }
            if values["--output"] != nil { throw Refusal.conflictingContext }
        } else if order.contains(where: { !Self.buildReportFlags.contains($0) }) {
            throw Refusal.conflictingContext
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
            case "--run-dir", "--build-report":
                let directory = try runDirectoryArgument(value, record: record).argument
                replaced[flag] = directory
                runDirectory = directory
            case "--output":
                replaced[flag] = try outputDirectoryArgument(value, record: record, callerUID: callerUID)
            case "--wifi-scan-json":
                replaced[flag] = try scanFileArgument(value, callerUID: callerUID)
            default:
                guard Self.freeTextFlags.contains(flag), Self.isValidFreeText(value) else {
                    throw Refusal.badValue(flag: flag, value: value)
                }
            }
        }

        var childEnvironment = Self.baseEnvironment
        if let sshPassword, !sshPassword.isEmpty {
            guard sshPassword.utf8.count <= Self.maximumPasswordLength, !sshPassword.unicodeScalars.contains("\0") else {
                throw Refusal.badValue(flag: "LSS_SSH_PASSWORD", value: "(hidden)")
            }
            childEnvironment["LSS_SSH_PASSWORD"] = sshPassword
        }

        var argv: [String] = []
        for flag in order {
            argv.append(flag)
            if let value = values[flag] { argv.append(replaced[flag] ?? value) }
        }
        return Validated(executable: executable, arguments: argv, environment: childEnvironment, runDirectory: runDirectory)
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
    /// without symlinks; the CLI `source`s it as root. APP_ROOT must be the folder that
    /// holds it (the script reads `$SCRIPT_DIR/install.env`).
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
    }

    // MARK: - Path arguments

    /// A run directory: `<configured output>/<name>` for argv and the canonical path.
    func runDirectoryArgument(_ value: String, record: InstallRecord) throws -> (argument: String, canonical: String) {
        let refusal = Refusal.runDirectoryOutsideOutput(value)
        guard let path = Self.cleanAbsolutePath(value), let output = secureOutputDirectory(record) else { throw refusal }
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
    /// group/world write (otherwise anyone could plant entries the CLI writes through).
    func secureOutputDirectory(_ record: InstallRecord) -> String? {
        guard let canonical = environment.resolvePath(record.configuredOutput),
              let status = environment.fileStatus(canonical), status.kind == .directory,
              status.ownerUID == 0, !status.isGroupOrWorldWritable else { return nil }
        return canonical
    }

    /// `--output`: a run directory, or an existing directory the (non-root) caller owns.
    func outputDirectoryArgument(_ value: String, record: InstallRecord, callerUID: uid_t) throws -> String {
        let refusal = Refusal.runDirectoryOutsideOutput(value)
        guard let path = Self.cleanAbsolutePath(value) else { throw refusal }
        if let runDirectory = try? runDirectoryArgument(path, record: record) { return runDirectory.argument }
        guard callerUID != 0,
              let canonical = environment.resolvePath(path),
              let status = environment.fileStatus(canonical), status.kind == .directory,
              status.ownerUID == callerUID else { throw refusal }
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

    /// `^[^\x00-\x1f\x7f]{1,120}$` and not starting with "-".
    public static func isValidFreeText(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maximumTextLength, !value.hasPrefix("-") else { return false }
        return !scalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// `^[A-Za-z0-9-]{1,64}$` (the app sends `UUID().uuidString`).
    public static func isValidToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard (1...64).contains(scalars.count) else { return false }
        return scalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func isFlag(_ text: String) -> Bool {
        ArgumentBuilder.valueFlags.contains(text) || ArgumentBuilder.booleanFlags.contains(text)
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
    }
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
