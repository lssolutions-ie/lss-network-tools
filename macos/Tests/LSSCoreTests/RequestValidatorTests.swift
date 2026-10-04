import Foundation
import Testing
@testable import LSSCore
import LSSXPC

private typealias Refusal = RequestValidator.Refusal

// MARK: - Fixture

/// A fake CLI install in a temporary directory: install.env, wrapper, script, an output
/// folder with one run, a home folder with a Wi-Fi scan file, and a `usr/bin` with the
/// tools the engine needs. Tests cannot create root-owned files, so the file-status shim
/// reports `rootOwned` paths — and every folder above the fixture root, which belongs
/// to the test user — as uid 0, and `owners` overrides individual owners. The temporary
/// root is canonicalised first (`/var` → `/private/var`), so "no symlink in the path"
/// holds for the fixture itself.
///
/// The engine's search order is pointed at fixture folders (`searchPrefix` for what
/// `ensure_standard_path` prepends, `childPATH` for the child's PATH); only `usrBin`
/// exists unless a test creates more.
///
/// Each test owns its fixture; nothing is shared across threads (`@unchecked Sendable`
/// only so the parametrised cases can carry it into their closures).
private final class InstallFixture: @unchecked Sendable {
    let root: String
    let appRoot: String
    let installEnv: String
    let script: String
    let wrapper: String
    let output: String
    let runDirectory: String
    let home: String
    let scans: String
    let scanFile: String
    let elsewhere: String
    /// The trusted tool folder (`<root>/usr/bin`) holding `RequestValidator.requiredTools`.
    let usrBin: String
    /// `<root>/opt/homebrew/bin` — the user-owned Homebrew prefix of the common case;
    /// absent until a test creates it.
    let brewBin: String
    let callerUID: uid_t = getuid()
    var rootOwned: Set<String>
    var owners: [String: uid_t] = [:]

    static let runName = "acme-hq-03-10-2026"

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lss-validator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try #require(LiveFileSystem.resolve(base.path(percentEncoded: false)))
        appRoot = root + "/share/lss-network-tools"
        installEnv = appRoot + "/install.env"
        script = appRoot + "/lss-network-tools.sh"
        wrapper = root + "/bin/lss-network-tools"
        output = appRoot + "/output"
        runDirectory = output + "/" + Self.runName
        home = root + "/home/tester"
        scans = home + "/" + RequestValidator.scansDirectoryRelativePath
        scanFile = scans + "/0B9A4B8E-6E2F-4C59-8E35-0D6B6F7A3C21.json"
        elsewhere = root + "/elsewhere"
        usrBin = root + "/usr/bin"
        brewBin = root + "/opt/homebrew/bin"
        rootOwned = [root, root + "/share", appRoot, installEnv, script, root + "/bin", wrapper, output, runDirectory,
                     root + "/usr", usrBin, root + "/opt"]
        for tool in RequestValidator.requiredTools { rootOwned.insert(usrBin + "/" + tool) }

        for directory in [appRoot, output, runDirectory, root + "/bin", scans, elsewhere, usrBin, root + "/opt"] {
            try mkdir(directory)
        }
        try writeInstallEnv()
        try write("#!/usr/bin/env bash\necho engine\n", to: script, mode: 0o755)
        try writeWrapper(execs: script)
        try write("[]\n", to: scanFile, mode: 0o600)
        for tool in RequestValidator.requiredTools {
            try write("#!/bin/sh\n", to: usrBin + "/" + tool, mode: 0o755)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// What `ensure_standard_path` prepends, relocated into the fixture.
    var searchPrefix: [String] {
        [brewBin, root + "/opt/homebrew/sbin", root + "/usr/local/bin", root + "/usr/local/sbin"]
    }

    /// The child's PATH, relocated into the fixture (same shape as `ProcessRunner.toolPATH`).
    var childPATH: String {
        (searchPrefix + [usrBin, root + "/bin", root + "/usr/sbin", root + "/sbin"]).joined(separator: ":")
    }

    /// `Validated.environment` without secrets.
    var expectedEnvironment: [String: String] {
        ["PATH": childPATH, "HOME": "/var/root", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "dumb", "LSS_QUIET_SPINNER": "1"]
    }

    var environment: RequestValidator.Environment {
        let root = root
        let rootOwned = rootOwned
        let owners = owners
        let callerUID = callerUID
        let home = home
        let live = RequestValidator.Environment.live
        return RequestValidator.Environment(
            installEnvPath: installEnv,
            fileStatus: { path in
                guard var status = live.fileStatus(path) else { return nil }
                if let owner = owners[path] {
                    status.ownerUID = owner
                } else if rootOwned.contains(path) {
                    status.ownerUID = 0
                } else if path == "/" || root.hasPrefix(path + "/") {
                    // The temporary folder's ancestors (…/T is the caller's, 0700) stand in
                    // for the root-owned system folders of a real install.
                    status.ownerUID = 0
                    status.permissions &= ~0o022
                }
                return status
            },
            resolvePath: live.resolvePath,
            readFile: live.readFile,
            homeDirectory: { $0 == callerUID ? home : nil },
            childSearchPath: childPATH,
            engineSearchPathPrefix: searchPrefix
        )
    }

    var validator: RequestValidator { RequestValidator(environment: environment) }

    func validate(_ arguments: [String], password: String? = nil, progressToken: String? = nil,
                  policy: ToolchainPolicy = .refuse) throws -> RequestValidator.Validated {
        try validator.validate(arguments: arguments, sshPassword: password, progressToken: progressToken, callerUID: callerUID,
                               toolchainPolicy: policy)
    }

    /// `<root>/opt/homebrew/bin`, owned by the test user — the common Apple-silicon
    /// layout — and the refusal the search-path rule produces for it.
    func makeUserOwnedHomebrew() throws -> Refusal {
        try mkdir(brewBin)
        return .untrustedToolchain(tool: RequestValidator.searchPathLabel, path: brewBin,
                                   reason: "passes through \(root + "/opt/homebrew"), which \(notRootReason)")
    }

    /// `is owned by uid <test user>, not root` — the reason the shim produces for a
    /// fixture entry that is not in `rootOwned`.
    var notRootReason: String { "is owned by uid \(callerUID), not root" }

    // MARK: File helpers

    func mkdir(_ path: String, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try chmod(path, mode)
    }

    func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: URL(filePath: path))
        try chmod(path, mode)
    }

    func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func symlink(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func writeInstallEnv(_ text: String? = nil) throws {
        try write(text ?? "APP_ROOT=\"\(appRoot)\"\nDATA_ROOT=\"\(appRoot)\"\nINSTALL_WRAPPER_PATH=\"\(wrapper)\"\n", to: installEnv)
    }

    func writeWrapper(execs target: String) throws {
        try write("#!/usr/bin/env bash\nset -euo pipefail\nexport PATH=\"/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}\"\nexec \"\(target)\" \"$@\"\n", to: wrapper, mode: 0o755)
    }
}

/// `--run-task 1 --interface en0 --client Acme --location HQ` + extra.
private func newRun(_ extra: [String] = []) -> [String] {
    ["--run-task", "1", "--interface", "en0", "--client", "Acme", "--location", "HQ"] + extra
}

private func continueRun(_ directory: String, _ extra: [String] = []) -> [String] {
    ["--run-task", "3", "--interface", "en0", "--run-dir", directory] + extra
}

private func wireless(scan: String) -> [String] {
    ["--run-task", "17", "--interface", "en0", "--client", "Acme", "--location", "HQ",
     "--building", "HQ", "--floor", "2", "--room", "Lobby", "--ap-present", "n", "--wifi-scan-json", scan]
}

// MARK: - Accepted requests

@Suite("RequestValidator — accepted requests")
struct RequestValidatorAcceptanceTests {
    @Test("maximal new-run request → exact executable, argv and environment")
    func maximalNewRun() throws {
        let fixture = try InstallFixture()
        let arguments = [
            "--run-task", "10,13,14,15,16,17,19,20", "--interface", "en0",
            "--client", "Acme Ltd", "--location", "Head Office — Café", "--note", "2nd floor",
            "--prepared-by", "L. Stojanik", "--no-pdf", "--yes",
            "--target", "10.0.0.5", "--mac", "AA-BB-CC-DD-EE-0F",
            "--wifi-interface", "en1", "--building", "HQ", "--floor", "2", "--room", "Lobby",
            "--ap-present", "y", "--ap-label", "AP-1", "--wifi-scan-json", fixture.scanFile,
            "--controller", "unifi.example.com", "--controller-port", "8443", "--https", "y",
            "--ssh-user", "ubnt", "--debug",
        ]
        let validated = try fixture.validate(arguments, password: "s3cret pass")

        var expectedArguments = arguments
        expectedArguments[expectedArguments.firstIndex(of: "AA-BB-CC-DD-EE-0F")!] = "aa:bb:cc:dd:ee:0f"
        var expectedEnvironment = fixture.expectedEnvironment
        expectedEnvironment["LSS_SSH_PASSWORD"] = "s3cret pass"

        #expect(validated.executable == fixture.wrapper)
        #expect(validated.arguments == expectedArguments)
        #expect(validated.environment == expectedEnvironment)
        #expect(validated.runDirectory == nil)
    }

    @Test("ArgumentBuilder output for a continued run passes unchanged")
    func argumentBuilderRoundTrip() throws {
        let fixture = try InstallFixture()
        let request = RunTaskRequest(
            selection: .tasks([.customPortScan, .wirelessSurvey, .unifiAdoption, .findByMAC]),
            context: .existingRun(directory: URL(filePath: fixture.runDirectory, directoryHint: .isDirectory)),
            interface: "en0",
            preparedBy: "Ladia",
            skipPDF: true,
            targetIP: "192.168.1.20",
            macAddress: "aa:bb:cc:dd:ee:ff",
            wireless: .init(building: "B1", floor: "G", room: "Hall", accessPointPresent: true, accessPointLabel: "AP 7",
                            wifiInterface: "en1", scanJSON: URL(filePath: fixture.scanFile)),
            unifi: .init(controllerHost: "unifi.lssolutions.ie", controllerPort: 8080, https: false, sshUser: "admin", sshPasswordProvided: true)
        )
        let arguments = try ArgumentBuilder.arguments(for: request)
        let validated = try fixture.validate(arguments, password: "pw")
        #expect(validated.arguments == arguments)
        #expect(validated.runDirectory == fixture.runDirectory)
        #expect(validated.environment["LSS_SSH_PASSWORD"] == "pw")
    }

    @Test("ArgumentBuilder output for --build-report passes unchanged")
    func buildReportRoundTrip() throws {
        let fixture = try InstallFixture()
        let request = BuildReportRequest(runDirectory: URL(filePath: fixture.runDirectory + "/", directoryHint: .isDirectory), preparedBy: "Ladia", skipPDF: true)
        let arguments = try ArgumentBuilder.arguments(for: request)
        let validated = try fixture.validate(arguments)
        #expect(validated.arguments == ["--build-report", fixture.runDirectory, "--prepared-by", "Ladia", "--no-pdf"])
        #expect(validated.runDirectory == fixture.runDirectory)
        #expect(validated.environment == fixture.expectedEnvironment)
    }

    @Test("ArgumentBuilder output for --delete-run passes unchanged; --debug is its only companion")
    func deleteRunRoundTrip() throws {
        let fixture = try InstallFixture()
        let request = DeleteRunRequest(runDirectory: URL(filePath: fixture.runDirectory + "/", directoryHint: .isDirectory))
        let arguments = try ArgumentBuilder.arguments(for: request)
        #expect(arguments == ["--delete-run", fixture.runDirectory])

        let validated = try fixture.validate(arguments)
        #expect(validated.executable == fixture.wrapper)
        #expect(validated.arguments == ["--delete-run", fixture.runDirectory])
        #expect(validated.environment == fixture.expectedEnvironment)
        #expect(validated.runDirectory == fixture.runDirectory)
        #expect(validated.toolchain == .trusted)

        let debug = try fixture.validate(["--delete-run", fixture.runDirectory, "--debug"])
        #expect(debug.arguments == ["--delete-run", fixture.runDirectory, "--debug"])
        #expect(debug.runDirectory == fixture.runDirectory)
        #expect(try fixture.validate(["--debug", "--delete-run", fixture.runDirectory]).arguments == ["--debug", "--delete-run", fixture.runDirectory])

        // Through a symlinked parent the CLI's own spelling is substituted, as for --run-dir.
        try fixture.symlink(fixture.root + "/output-link", to: fixture.output)
        let viaLink = try fixture.validate(["--delete-run", fixture.root + "/output-link/" + InstallFixture.runName])
        #expect(viaLink.arguments == ["--delete-run", fixture.runDirectory])

        // The same through the JSON entry point the helper uses.
        let wire = HelperRunRequest(arguments: arguments, progressToken: "0123456789abcdef")
        let viaJSON = try fixture.validator.validate(requestJSON: JSONEncoder().encode(wire), callerUID: fixture.callerUID)
        #expect(viaJSON.arguments == arguments)
        #expect(viaJSON.environment["LSS_PROGRESS_TOKEN"] == "0123456789abcdef")

        // The tool-chain policy applies to a deletion as to every request: the engine
        // runs check_tools before it does anything.
        let refusal = try fixture.makeUserOwnedHomebrew()
        #expect(throws: refusal) { try fixture.validate(arguments) }
        #expect(try fixture.validate(arguments, policy: .report).toolchain == .untrusted(refusal))
    }

    @Test("the refusal descriptions name all three modes")
    func modeDescriptions() {
        #expect(Refusal.noMode.description == "The request has none of --run-task, --build-report and --delete-run.")
        #expect(Refusal.conflictingContext.description.contains("--delete-run"))
        #expect(Refusal.runDirectoryOutsideOutput("/x").description.contains("--delete-run"))
        #expect(RequestValidator.modeFlags == ["--run-task", "--build-report", "--delete-run"])
        #expect(RequestValidator.deleteRunFlags == ["--delete-run", "--debug"])
    }

    @Test("--output must be a run directory; a folder the caller owns is refused")
    func outputDirectories() throws {
        let fixture = try InstallFixture()
        let exports = fixture.home + "/Desktop/exports"
        try fixture.mkdir(exports)
        try fixture.symlink(fixture.home + "/exports-link", to: exports)

        let intoRun = try fixture.validate(["--build-report", fixture.runDirectory, "--output", fixture.runDirectory + "/"])
        #expect(intoRun.arguments == ["--build-report", fixture.runDirectory, "--output", fixture.runDirectory])

        // The caller could plant `<exports>/lss-network-tools-report-….pdf` as a symlink
        // and have the root child write through it, so ownership is not enough.
        for path in [exports, fixture.home + "/exports-link/", fixture.home] {
            #expect(throws: Refusal.runDirectoryOutsideOutput(path)) {
                try fixture.validate(["--build-report", fixture.runDirectory, "--output", path])
            }
        }
    }

    @Test("the script runs directly when the wrapper does not exist")
    func scriptWithoutWrapper() throws {
        let fixture = try InstallFixture()
        try fixture.remove(fixture.wrapper)
        #expect(try fixture.validate(newRun()).executable == fixture.script)
        try fixture.writeInstallEnv("APP_ROOT=\(fixture.appRoot)\n")
        #expect(try fixture.validate(newRun()).executable == fixture.script)
    }

    @Test("a run directory given through a symlinked parent is passed in the CLI's spelling")
    func runDirectoryThroughSymlinkedParent() throws {
        let fixture = try InstallFixture()
        try fixture.symlink(fixture.root + "/output-link", to: fixture.output)
        let validated = try fixture.validate(continueRun(fixture.root + "/output-link/" + InstallFixture.runName))
        #expect(validated.arguments.last == fixture.runDirectory)
    }

    @Test("edge values that are valid", arguments: [
        ["--run-task", "list"],
        ["--run-task", "000", "--interface", "en0", "--client", "A", "--location", "B", "--yes"],
        ["--run-task", "1,2,20", "--interface", "bridge100", "--client", "Ü", "--location", String(repeating: "x", count: 120)],
        ["--run-task", "1", "--interface", "enp3s0", "--client", "A", "--location", "B"],
        ["--run-task", "1", "--interface", "br-1234abcd", "--client", "A", "--location", "B"],
        ["--run-task", "1", "--interface", "eth0.100", "--client", "A", "--location", "B", "--wifi-interface", "wlp2s0"],
        ["--run-task", "1", "--interface", "EN0", "--client", "A", "--location", "B"],
        newRun(["--ssh-user", "admin.1_a-b"]),
        newRun(["--ssh-user", "1st"]),
        newRun(["--controller", "unifi.example.com"]),
        ["--run-task", "1", "--interface", "en0", "--client", "Zoë & Sons — Ürümqi", "--location", "Café\u{A0}1"],
        newRun(["--target", "0.0.0.0"]),
        newRun(["--target", "255.255.255.255"]),
        newRun(["--controller-port", "1"]),
        newRun(["--controller-port", "65535"]),
        newRun(["--https", "n", "--ap-present", "n"]),
        newRun(["--mac", "a:b:c:d:e:f"]),
        newRun(["--mac", "aabb.ccdd.eeff"]),
    ])
    func validEdgeValues(_ arguments: [String]) throws {
        let fixture = try InstallFixture()
        _ = try fixture.validate(arguments)
    }

    @Test("an empty SSH password is not placed in the environment")
    func emptyPassword() throws {
        let fixture = try InstallFixture()
        #expect(try fixture.validate(newRun(), password: "").environment == fixture.expectedEnvironment)
    }

    @Test("HelperRunRequest JSON from the app decodes through validate(requestJSON:)")
    func requestJSON() throws {
        let fixture = try InstallFixture()
        let request = HelperRunRequest(arguments: newRun(), sshPassword: "pw", callerUID: 12345)
        let validated = try fixture.validator.validate(requestJSON: JSONEncoder().encode(request), callerUID: fixture.callerUID)
        #expect(validated.arguments == newRun())
        #expect(validated.environment["LSS_SSH_PASSWORD"] == "pw")
        #expect(validated.environment["LSS_PROGRESS_TOKEN"] == nil, "no token requested → none in the environment")
        #expect(validated.toolchain == .trusted)
    }

    @Test("a request carrying the authorization blob validates like one without it (protocol 2)")
    func requestJSONWithAuthorization() throws {
        let fixture = try InstallFixture()
        let blob = Data((0..<HelperAuthorization.externalFormLength).map { UInt8($0) })
        let request = HelperRunRequest(arguments: newRun(), sshPassword: "pw", progressToken: "0123456789abcdef", authorization: blob)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(HelperRunRequest.self, from: data) == request)

        let validated = try fixture.validator.validate(requestJSON: data, callerUID: fixture.callerUID)
        let plain = try fixture.validator.validate(requestJSON: JSONEncoder().encode(HelperRunRequest(
            token: request.token, arguments: newRun(), sshPassword: "pw", progressToken: "0123456789abcdef")), callerUID: fixture.callerUID)
        #expect(validated == plain, "the blob never reaches argv or the environment")
        #expect(!validated.arguments.contains(where: { $0.contains(blob.base64EncodedString()) }))
        #expect(!validated.environment.values.contains(where: { $0.contains(blob.base64EncodedString()) }))
    }

    @Test("the progress token travels only in the environment, on both entry points")
    func progressToken() throws {
        let fixture = try InstallFixture()
        let token = ProgressLineParser.makeToken()
        #expect(ProgressLineParser.isValidToken(token))

        let direct = try fixture.validate(newRun(), progressToken: token)
        #expect(direct.environment["LSS_PROGRESS_TOKEN"] == token)
        #expect(!direct.arguments.contains(token))
        var expected = fixture.expectedEnvironment
        expected["LSS_PROGRESS_TOKEN"] = token
        #expect(direct.environment == expected)

        let request = HelperRunRequest(arguments: newRun(), sshPassword: "pw", progressToken: token)
        let viaJSON = try fixture.validator.validate(requestJSON: JSONEncoder().encode(request), callerUID: fixture.callerUID)
        #expect(viaJSON.environment["LSS_PROGRESS_TOKEN"] == token)
        #expect(viaJSON.environment["LSS_SSH_PASSWORD"] == "pw")

        // A request encoded before the field existed still decodes.
        let legacy = Data(#"{"token":"ABC-123","arguments":["--run-task","list"]}"#.utf8)
        #expect(try fixture.validator.validate(requestJSON: legacy, callerUID: fixture.callerUID).environment["LSS_PROGRESS_TOKEN"] == nil)
    }

    @Test("progress tokens outside the engine's grammar are refused without echoing them",
          arguments: ["", "short", String(repeating: "a", count: 65), "has space 123", "tok;en-12345", "tökén-12345", "a1b2c3d4\n"])
    func badProgressToken(_ token: String) throws {
        let fixture = try InstallFixture()
        #expect(throws: Refusal.badValue(flag: "LSS_PROGRESS_TOKEN", value: "(hidden)")) {
            try fixture.validate(newRun(), progressToken: token)
        }
        #expect(!Refusal.badValue(flag: "LSS_PROGRESS_TOKEN", value: "(hidden)").description.contains(token) || token.isEmpty)
    }

    @Test("progress tokens the engine accepts", arguments: ["12345678", "a-b_c-d_e-f_g-h", String(repeating: "Z", count: 64), "0123456789abcdef0123456789abcdef"])
    func goodProgressToken(_ token: String) throws {
        let fixture = try InstallFixture()
        #expect(try fixture.validate(newRun(), progressToken: token).environment["LSS_PROGRESS_TOKEN"] == token)
    }

    @Test("validateRepair returns the canonical run directory")
    func repairAccepted() throws {
        let fixture = try InstallFixture()
        #expect(try fixture.validator.validateRepair(runDirectory: fixture.runDirectory + "/") == fixture.runDirectory)
        try fixture.symlink(fixture.root + "/output-link", to: fixture.output)
        #expect(try fixture.validator.validateRepair(runDirectory: fixture.root + "/output-link/" + InstallFixture.runName) == fixture.runDirectory)
    }
}

// MARK: - Refusals

/// One row of the refusal table.
private struct RefusalCase: Sendable, CustomTestStringConvertible {
    let name: String
    let prepare: @Sendable (InstallFixture) throws -> Void
    let arguments: @Sendable (InstallFixture) -> [String]
    let password: String?
    let expected: @Sendable (InstallFixture) -> Refusal

    init(_ name: String,
         prepare: @escaping @Sendable (InstallFixture) throws -> Void = { _ in },
         password: String? = nil,
         arguments: @escaping @Sendable (InstallFixture) -> [String],
         expected: @escaping @Sendable (InstallFixture) -> Refusal) {
        self.name = name
        self.prepare = prepare
        self.password = password
        self.arguments = arguments
        self.expected = expected
    }

    var testDescription: String { name }
}

private let refusalCases: [RefusalCase] = [
    // Run directories
    .init("run dir: ../ traversal back into output",
          arguments: { continueRun($0.output + "/../output/" + InstallFixture.runName) },
          expected: { .runDirectoryOutsideOutput($0.output + "/../output/" + InstallFixture.runName) }),
    .init("run dir: ../ traversal out of output",
          arguments: { continueRun($0.runDirectory + "/../../..") },
          expected: { .runDirectoryOutsideOutput($0.runDirectory + "/../../..") }),
    .init("run dir: ./ component",
          arguments: { continueRun($0.output + "/./" + InstallFixture.runName) },
          expected: { .runDirectoryOutsideOutput($0.output + "/./" + InstallFixture.runName) }),
    .init("run dir: symlink inside output to another run",
          prepare: { try $0.symlink($0.output + "/alias", to: $0.runDirectory); $0.rootOwned.insert($0.output + "/alias") },
          arguments: { continueRun($0.output + "/alias") },
          expected: { .runDirectoryOutsideOutput($0.output + "/alias") }),
    .init("run dir: symlink inside output pointing outside",
          prepare: { try $0.mkdir($0.elsewhere + "/run"); try $0.symlink($0.output + "/evil", to: $0.elsewhere + "/run") },
          arguments: { continueRun($0.output + "/evil") },
          expected: { .runDirectoryOutsideOutput($0.output + "/evil") }),
    .init("run dir: outside the output folder",
          prepare: { try $0.mkdir($0.elsewhere + "/run"); $0.rootOwned.insert($0.elsewhere + "/run") },
          arguments: { continueRun($0.elsewhere + "/run") },
          expected: { .runDirectoryOutsideOutput($0.elsewhere + "/run") }),
    .init("run dir: the output folder itself",
          arguments: { continueRun($0.output) },
          expected: { .runDirectoryOutsideOutput($0.output) }),
    .init("run dir: nested below a run",
          prepare: { try $0.mkdir($0.runDirectory + "/nested"); $0.rootOwned.insert($0.runDirectory + "/nested") },
          arguments: { continueRun($0.runDirectory + "/nested") },
          expected: { .runDirectoryOutsideOutput($0.runDirectory + "/nested") }),
    .init("run dir: does not exist",
          arguments: { continueRun($0.output + "/missing") },
          expected: { .runDirectoryOutsideOutput($0.output + "/missing") }),
    .init("run dir: relative path",
          arguments: { _ in continueRun("output/" + InstallFixture.runName) },
          expected: { _ in .runDirectoryOutsideOutput("output/" + InstallFixture.runName) }),
    .init("run dir: not owned by root",
          prepare: { $0.rootOwned.remove($0.runDirectory) },
          arguments: { continueRun($0.runDirectory) },
          expected: { .runDirectoryOutsideOutput($0.runDirectory) }),
    .init("run dir: group-writable",
          prepare: { try $0.chmod($0.runDirectory, 0o775) },
          arguments: { continueRun($0.runDirectory) },
          expected: { .runDirectoryOutsideOutput($0.runDirectory) }),
    .init("run dir: output folder writable by others",
          prepare: { try $0.chmod($0.output, 0o777) },
          arguments: { continueRun($0.runDirectory) },
          expected: { .runDirectoryOutsideOutput($0.runDirectory) }),
    .init("run dir: hidden name",
          prepare: { try $0.mkdir($0.output + "/.hidden"); $0.rootOwned.insert($0.output + "/.hidden") },
          arguments: { continueRun($0.output + "/.hidden") },
          expected: { .runDirectoryOutsideOutput($0.output + "/.hidden") }),
    .init("build report: traversal",
          arguments: { ["--build-report", $0.runDirectory + "/.."] },
          expected: { .runDirectoryOutsideOutput($0.runDirectory + "/..") }),
    .init("build report: /etc",
          arguments: { _ in ["--build-report", "/etc"] },
          expected: { _ in .runDirectoryOutsideOutput("/etc") }),
    .init("output: folder owned by another user outside output",
          prepare: { try $0.mkdir($0.elsewhere + "/exports"); $0.owners[$0.elsewhere + "/exports"] = 0 },
          arguments: { ["--build-report", $0.runDirectory, "--output", $0.elsewhere + "/exports"] },
          expected: { .runDirectoryOutsideOutput($0.elsewhere + "/exports") }),
    .init("output: folder the caller owns (symlink-plantable)",
          prepare: { try $0.mkdir($0.home + "/Desktop") },
          arguments: { ["--build-report", $0.runDirectory, "--output", $0.home + "/Desktop"] },
          expected: { .runDirectoryOutsideOutput($0.home + "/Desktop") }),
    .init("output: another run directory reached through a symlink",
          prepare: { try $0.symlink($0.output + "/alias", to: $0.runDirectory); $0.rootOwned.insert($0.output + "/alias") },
          arguments: { ["--build-report", $0.runDirectory, "--output", $0.output + "/alias"] },
          expected: { .runDirectoryOutsideOutput($0.output + "/alias") }),
    .init("output: the output folder itself",
          arguments: { ["--build-report", $0.runDirectory, "--output", $0.output] },
          expected: { .runDirectoryOutsideOutput($0.output) }),

    // --delete-run: the run-directory rule, and nothing but --debug beside it
    .init("delete run: with --run-task",
          arguments: { ["--delete-run", $0.runDirectory, "--run-task", "1"] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --build-report",
          arguments: { ["--build-report", $0.runDirectory, "--delete-run", $0.runDirectory] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --prepared-by",
          arguments: { ["--delete-run", $0.runDirectory, "--prepared-by", "Ladia"] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --no-pdf",
          arguments: { ["--delete-run", $0.runDirectory, "--no-pdf"] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --yes",
          arguments: { ["--yes", "--delete-run", $0.runDirectory] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --interface",
          arguments: { ["--delete-run", $0.runDirectory, "--interface", "en0"] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --output",
          arguments: { ["--delete-run", $0.runDirectory, "--output", $0.runDirectory] },
          expected: { _ in .conflictingContext }),
    .init("delete run: with --run-dir",
          arguments: { ["--delete-run", $0.runDirectory, "--run-dir", $0.runDirectory] },
          expected: { _ in .conflictingContext }),
    .init("delete run: duplicate",
          arguments: { ["--delete-run", $0.runDirectory, "--delete-run", $0.runDirectory] },
          expected: { _ in .duplicateFlag("--delete-run") }),
    .init("delete run: missing value",
          arguments: { _ in ["--delete-run"] },
          expected: { _ in .missingValue("--delete-run") }),
    .init("delete run: outside the output folder",
          prepare: { try $0.mkdir($0.elsewhere + "/run"); $0.rootOwned.insert($0.elsewhere + "/run") },
          arguments: { ["--delete-run", $0.elsewhere + "/run"] },
          expected: { .runDirectoryOutsideOutput($0.elsewhere + "/run") }),
    .init("delete run: the output folder itself",
          arguments: { ["--delete-run", $0.output] },
          expected: { .runDirectoryOutsideOutput($0.output) }),
    .init("delete run: the output folder with a trailing slash",
          arguments: { ["--delete-run", $0.output + "/"] },
          expected: { .runDirectoryOutsideOutput($0.output + "/") }),
    .init("delete run: symlink inside output to another run",
          prepare: { try $0.symlink($0.output + "/alias", to: $0.runDirectory); $0.rootOwned.insert($0.output + "/alias") },
          arguments: { ["--delete-run", $0.output + "/alias"] },
          expected: { .runDirectoryOutsideOutput($0.output + "/alias") }),
    .init("delete run: symlink inside output pointing outside",
          prepare: { try $0.mkdir($0.elsewhere + "/run"); try $0.symlink($0.output + "/evil", to: $0.elsewhere + "/run") },
          arguments: { ["--delete-run", $0.output + "/evil"] },
          expected: { .runDirectoryOutsideOutput($0.output + "/evil") }),
    .init("delete run: nested below a run",
          prepare: { try $0.mkdir($0.runDirectory + "/nested"); $0.rootOwned.insert($0.runDirectory + "/nested") },
          arguments: { ["--delete-run", $0.runDirectory + "/nested"] },
          expected: { .runDirectoryOutsideOutput($0.runDirectory + "/nested") }),
    .init("delete run: ../ traversal",
          arguments: { ["--delete-run", $0.runDirectory + "/.."] },
          expected: { .runDirectoryOutsideOutput($0.runDirectory + "/..") }),
    .init("delete run: does not exist",
          arguments: { ["--delete-run", $0.output + "/missing"] },
          expected: { .runDirectoryOutsideOutput($0.output + "/missing") }),
    .init("delete run: not owned by root",
          prepare: { $0.rootOwned.remove($0.runDirectory) },
          arguments: { ["--delete-run", $0.runDirectory] },
          expected: { .runDirectoryOutsideOutput($0.runDirectory) }),
    .init("delete run: /etc",
          arguments: { _ in ["--delete-run", "/etc"] },
          expected: { _ in .runDirectoryOutsideOutput("/etc") }),
    .init("delete run: relative path",
          arguments: { _ in ["--delete-run", "output/" + InstallFixture.runName] },
          expected: { _ in .runDirectoryOutsideOutput("output/" + InstallFixture.runName) }),
    .init("delete run: the DATA_ROOT itself",
          arguments: { ["--delete-run", $0.appRoot] },
          expected: { .runDirectoryOutsideOutput($0.appRoot) }),

    // Executables
    .init("script: symbolic link",
          prepare: { fixture in
              try fixture.remove(fixture.script)
              try fixture.write("#!/bin/sh\n", to: fixture.elsewhere + "/real.sh", mode: 0o755)
              fixture.rootOwned.insert(fixture.elsewhere + "/real.sh")
              try fixture.symlink(fixture.script, to: fixture.elsewhere + "/real.sh")
          },
          arguments: { _ in newRun() },
          expected: { .executableIsSymlink($0.script) }),
    .init("script: not owned by root",
          prepare: { $0.rootOwned.remove($0.script) },
          arguments: { _ in newRun() },
          expected: { .executableNotRootOwned($0.script) }),
    .init("script: group-writable",
          prepare: { try $0.chmod($0.script, 0o775) },
          arguments: { _ in newRun() },
          expected: { .executableWritable($0.script) }),
    .init("script: world-writable",
          prepare: { try $0.chmod($0.script, 0o757) },
          arguments: { _ in newRun() },
          expected: { .executableWritable($0.script) }),
    .init("script: missing",
          prepare: { try $0.remove($0.script) },
          arguments: { _ in newRun() },
          expected: { .executableMissing($0.script) }),
    .init("script: not executable",
          prepare: { try $0.chmod($0.script, 0o644) },
          arguments: { _ in newRun() },
          expected: { .executableMissing($0.script) }),
    .init("wrapper: symbolic link to the script",
          prepare: { try $0.remove($0.wrapper); try $0.symlink($0.wrapper, to: $0.script) },
          arguments: { _ in newRun() },
          expected: { .executableIsSymlink($0.wrapper) }),
    .init("wrapper: not owned by root",
          prepare: { $0.rootOwned.remove($0.wrapper) },
          arguments: { _ in newRun() },
          expected: { .executableNotRootOwned($0.wrapper) }),
    .init("wrapper: group-writable",
          prepare: { try $0.chmod($0.wrapper, 0o775) },
          arguments: { _ in newRun() },
          expected: { .executableWritable($0.wrapper) }),
    .init("wrapper: starts another script",
          prepare: { try $0.writeWrapper(execs: "/tmp/evil.sh") },
          arguments: { _ in newRun() },
          expected: { .executableMissing($0.wrapper) }),

    // install.env
    .init("install.env: missing",
          prepare: { try $0.remove($0.installEnv) },
          arguments: { _ in newRun() },
          expected: { .installEnvUnreadable("\($0.installEnv) does not exist") }),
    .init("install.env: not owned by root",
          prepare: { $0.rootOwned.remove($0.installEnv) },
          arguments: { _ in newRun() },
          expected: { .installEnvUnreadable("\($0.installEnv) is not owned by root") }),
    .init("install.env: writable by others",
          prepare: { try $0.chmod($0.installEnv, 0o666) },
          arguments: { _ in newRun() },
          expected: { .installEnvUnreadable("\($0.installEnv) is writable by group or others") }),
    .init("install.env: symbolic link",
          prepare: { fixture in
              try fixture.write("APP_ROOT=\(fixture.appRoot)\n", to: fixture.elsewhere + "/install.env")
              fixture.rootOwned.insert(fixture.elsewhere + "/install.env")
              try fixture.remove(fixture.installEnv)
              try fixture.symlink(fixture.installEnv, to: fixture.elsewhere + "/install.env")
          },
          arguments: { _ in newRun() },
          expected: { .installEnvUnreadable("\($0.installEnv) is or passes through a symbolic link") }),
    .init("install.env: no APP_ROOT",
          prepare: { try $0.writeInstallEnv("DATA_ROOT=\($0.appRoot)\n") },
          arguments: { _ in newRun() },
          expected: { _ in .installEnvUnreadable("APP_ROOT is missing or not a plain absolute path") }),
    .init("install.env: APP_ROOT bash would expand",
          prepare: { try $0.writeInstallEnv("APP_ROOT=\"$HOME/lss\"\n") },
          arguments: { _ in newRun() },
          expected: { _ in .installEnvUnreadable("APP_ROOT is missing or not a plain absolute path") }),
    .init("install.env: APP_ROOT is another folder",
          prepare: { try $0.writeInstallEnv("APP_ROOT=\($0.elsewhere)\n") },
          arguments: { _ in newRun() },
          expected: { .installEnvUnreadable("APP_ROOT \($0.elsewhere) is not the folder that holds install.env") }),

    // Grammar
    .init("unknown flag", arguments: { _ in newRun(["--evil"]) }, expected: { _ in .unknownFlag("--evil") }),
    .init("positional argument", arguments: { _ in newRun(["extra"]) }, expected: { _ in .unknownFlag("extra") }),
    .init("--flag=value form", arguments: { _ in ["--run-task=1"] }, expected: { _ in .unknownFlag("--run-task=1") }),
    .init("interactive-only flag", arguments: { _ in newRun(["--update"]) }, expected: { _ in .unknownFlag("--update") }),
    .init("missing value at the end", arguments: { _ in ["--run-task", "1", "--interface"] }, expected: { _ in .missingValue("--interface") }),
    .init("missing value before the next flag", arguments: { _ in ["--run-task", "--interface", "en0"] }, expected: { _ in .missingValue("--run-task") }),
    .init("duplicate valued flag", arguments: { _ in newRun(["--interface", "en1"]) }, expected: { _ in .duplicateFlag("--interface") }),
    .init("duplicate boolean flag", arguments: { _ in newRun(["--yes", "--yes"]) }, expected: { _ in .duplicateFlag("--yes") }),
    .init("both modes", arguments: { ["--run-task", "1", "--build-report", $0.runDirectory] }, expected: { _ in .conflictingContext }),
    .init("all three modes", arguments: { ["--run-task", "1", "--build-report", $0.runDirectory, "--delete-run", $0.runDirectory] }, expected: { _ in .conflictingContext }),
    .init("no mode", arguments: { _ in ["--interface", "en0", "--client", "Acme"] }, expected: { _ in .noMode }),
    .init("empty argv", arguments: { _ in [] }, expected: { _ in .noMode }),
    .init("--run-dir with --client", arguments: { continueRun($0.runDirectory, ["--client", "Acme"]) }, expected: { _ in .conflictingContext }),
    .init("--output with --run-task", arguments: { newRun(["--output", $0.runDirectory]) }, expected: { _ in .conflictingContext }),
    .init("run flag with --build-report", arguments: { ["--build-report", $0.runDirectory, "--interface", "en0"] }, expected: { _ in .conflictingContext }),

    // Wi-Fi scan file
    .init("scan file: outside the scans folder",
          prepare: { try $0.write("[]", to: $0.elsewhere + "/scan.json", mode: 0o600) },
          arguments: { wireless(scan: $0.elsewhere + "/scan.json") },
          expected: { .scanFileOutsideAllowed($0.elsewhere + "/scan.json") }),
    .init("scan file: too large",
          prepare: { try Data(count: 2 * 1024 * 1024).write(to: URL(filePath: $0.scans + "/big.json")) },
          arguments: { wireless(scan: $0.scans + "/big.json") },
          expected: { .scanFileTooLarge($0.scans + "/big.json") }),
    .init("scan file: owned by another user",
          prepare: { $0.owners[$0.scanFile] = 0 },
          arguments: { wireless(scan: $0.scanFile) },
          expected: { .scanFileOutsideAllowed($0.scanFile) }),
    .init("scan file: symlink to a file outside",
          prepare: { try $0.symlink($0.scans + "/link.json", to: "/etc/hosts") },
          arguments: { wireless(scan: $0.scans + "/link.json") },
          expected: { .scanFileOutsideAllowed($0.scans + "/link.json") }),
    .init("scan file: a directory",
          prepare: { try $0.mkdir($0.scans + "/dir.json") },
          arguments: { wireless(scan: $0.scans + "/dir.json") },
          expected: { .scanFileOutsideAllowed($0.scans + "/dir.json") }),
    .init("scan file: ../ traversal",
          arguments: { wireless(scan: $0.scans + "/../scans/" + ($0.scanFile as NSString).lastPathComponent) },
          expected: { .scanFileOutsideAllowed($0.scans + "/../scans/" + ($0.scanFile as NSString).lastPathComponent) }),
    .init("scan file: missing",
          arguments: { wireless(scan: $0.scans + "/missing.json") },
          expected: { .scanFileOutsideAllowed($0.scans + "/missing.json") }),

    // Size and password
    .init("oversized request",
          arguments: { _ in newRun(["--note", String(repeating: "x", count: 70_000)]) },
          expected: { _ in .requestTooLarge }),
    .init("SSH password with NUL", password: "pass\u{0}word",
          arguments: { _ in newRun() },
          expected: { _ in .badValue(flag: "LSS_SSH_PASSWORD", value: "(hidden)") }),
]

/// Flag/value pairs that must be refused as `badValue`, applied to `newRun()`
/// (replacing the flag's value when the base request already has it).
private let badValues: [(String, String)] = [
    ("--run-task", "0"), ("--run-task", "21"), ("--run-task", "1,,2"), ("--run-task", "1-3"), ("--run-task", "abc"),
    ("--run-task", ""), ("--run-task", "100"), ("--run-task", "000,1"), ("--run-task", "list,1"), ("--run-task", " 1"),
    ("--run-task", "+1"), ("--run-task", "1,2,"), ("--run-task", "00"), ("--run-task", "１"),
    ("--interface", "en/0"), ("--interface", "-en0"), ("--interface", "0en"), ("--interface", "en0;reboot"),
    ("--interface", "abcdefghijklmnop"), ("--interface", "en 0"), ("--interface", "én0"), ("--wifi-interface", "Wi Fi"),
    ("--target", "256.1.1.1"), ("--target", "1.2.3"), ("--target", "01.2.3.4"), ("--target", "1.2.3.4 "), ("--target", "localhost"),
    ("--mac", "zz:bb:cc:dd:ee:ff"), ("--mac", "aa:bb:cc"), ("--mac", "aa:bb:cc:dd:ee:ff:00"), ("--mac", "aa:bb-cc:dd:ee:ff"),
    ("--controller-port", "0"), ("--controller-port", "65536"), ("--controller-port", "80a"), ("--controller-port", "+80"),
    ("--controller-port", "123456"), ("--controller-port", ""),
    ("--https", "yes"), ("--https", "Y"), ("--https", "1"), ("--ap-present", "N"), ("--ap-present", "true"),
    ("--client", String(repeating: "a", count: 121)), ("--client", "Ac\u{01}me"), ("--location", "HQ\nAnnex"),
    ("--note", "DEL\u{7F}"), ("--prepared-by", "-me"), ("--building", ""), ("--room", "\t"), ("--floor", "-1"),
    ("--ssh-user", "-oProxyCommand=x"), ("--controller", "-x"), ("--ap-label", "\u{1B}[31mred"),
    // The engine's --ssh-user shape (^[A-Za-z0-9][A-Za-z0-9._-]*$)
    ("--ssh-user", "ubnt user"), ("--ssh-user", ".ubnt"), ("--ssh-user", "ub;nt"), ("--ssh-user", "ubnt@host"), ("--ssh-user", ""),
    // C1 controls and invisible / bidirectional format characters in free text
    ("--client", "Ac\u{200B}me"), ("--location", "HQ\u{85}"), ("--note", "\u{202E}x"), ("--prepared-by", "x\u{FEFF}"),
    ("--building", "B\u{2066}"), ("--controller", "unifi.example.com\u{200D}"),
]

@Suite("RequestValidator — refusals")
struct RequestValidatorRefusalTests {
    @Test("refusal table", arguments: refusalCases)
    fileprivate func refusal(_ row: RefusalCase) throws {
        let fixture = try InstallFixture()
        try row.prepare(fixture)
        let expected = row.expected(fixture)
        #expect(throws: expected) {
            try fixture.validate(row.arguments(fixture), password: row.password)
        }
    }

    @Test("bad values", arguments: badValues)
    func badValue(_ flag: String, _ value: String) throws {
        let fixture = try InstallFixture()
        var arguments = newRun()
        if let index = arguments.firstIndex(of: flag) {
            arguments[index + 1] = value
        } else {
            arguments += [flag, value]
        }
        #expect(throws: Refusal.badValue(flag: flag, value: value)) {
            try fixture.validate(arguments)
        }
    }

    @Test("oversized request JSON")
    func oversizedJSON() throws {
        let fixture = try InstallFixture()
        let request = HelperRunRequest(arguments: newRun(["--note", String(repeating: "y", count: 66_000)]))
        let data = try JSONEncoder().encode(request)
        #expect(throws: Refusal.requestTooLarge) {
            try fixture.validator.validate(requestJSON: data, callerUID: fixture.callerUID)
        }
    }

    @Test("malformed request JSON and bad tokens", arguments: [
        Data("not json".utf8),
        Data(#"{"arguments":["--run-task","1"]}"#.utf8),
        Data(#"{"token":"../../etc","arguments":["--run-task","list"]}"#.utf8),
        Data(#"{"token":"","arguments":["--run-task","list"]}"#.utf8),
    ])
    func malformedJSON(_ data: Data) throws {
        let fixture = try InstallFixture()
        #expect(throws: Refusal.malformedRequest) {
            try fixture.validator.validate(requestJSON: data, callerUID: fixture.callerUID)
        }
    }

    @Test("validateRepair refuses anything but a run directory")
    func repairRefusals() throws {
        let fixture = try InstallFixture()
        try fixture.mkdir(fixture.elsewhere + "/run")
        fixture.rootOwned.insert(fixture.elsewhere + "/run")
        try fixture.symlink(fixture.output + "/alias", to: fixture.runDirectory)
        for path in [fixture.output, fixture.output + "/alias", fixture.elsewhere + "/run", fixture.runDirectory + "/..", "relative", "/"] {
            #expect(throws: Refusal.runDirectoryOutsideOutput(path)) {
                try fixture.validator.validateRepair(runDirectory: path)
            }
        }
        try fixture.remove(fixture.installEnv)
        #expect(throws: Refusal.installEnvUnreadable("\(fixture.installEnv) does not exist")) {
            try fixture.validator.validateRepair(runDirectory: fixture.runDirectory)
        }
    }

    @Test("descriptions never contain control characters or the password")
    func descriptions() {
        let refusal = Refusal.badValue(flag: "--client", value: "A\u{1B}[2J\nB")
        #expect(!refusal.description.unicodeScalars.contains { $0.value < 0x20 })
        #expect(Refusal.badValue(flag: "LSS_SSH_PASSWORD", value: "(hidden)").description.contains("(hidden)"))
        #expect(Refusal.unknownFlag(String(repeating: "z", count: 500)).description.count < 260)
    }
}

// MARK: - Tool chain and ancestors

/// The engine runs `nmap`, `jq`, `python3`… as root from a Homebrew-first PATH; the
/// helper must refuse when any of that is writable by a non-root user.
@Suite("RequestValidator — tool chain and ancestors")
struct RequestValidatorToolchainTests {
    private static let searchPath = RequestValidator.searchPathLabel

    @Test("a root-owned tool chain is accepted, including a Homebrew prefix owned by root")
    func rootOwnedToolchain() throws {
        let fixture = try InstallFixture()
        _ = try fixture.validate(newRun())

        // Homebrew as a root-owned prefix: `bin/nmap` is a relative symlink into the Cellar.
        let homebrew = fixture.root + "/opt/homebrew"
        let cellar = homebrew + "/Cellar/nmap/7.98/bin"
        try fixture.mkdir(fixture.brewBin)
        try fixture.mkdir(cellar)
        try fixture.write("#!/bin/sh\n", to: cellar + "/nmap", mode: 0o755)
        try fixture.symlink(fixture.brewBin + "/nmap", to: "../Cellar/nmap/7.98/bin/nmap")
        for path in [homebrew, fixture.brewBin, fixture.brewBin + "/nmap", homebrew + "/Cellar", homebrew + "/Cellar/nmap",
                     homebrew + "/Cellar/nmap/7.98", cellar, cellar + "/nmap"] {
            fixture.rootOwned.insert(path)
        }
        _ = try fixture.validate(newRun())
    }

    @Test("the effective search order is the engine's prefix, then the child PATH, each folder once")
    func effectiveSearchPath() {
        let order = RequestValidator.effectiveSearchPath(
            prefix: ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"],
            childPATH: "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/sbin:/sbin"
        )
        #expect(order == ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(RequestValidator.effectiveSearchPath(prefix: RequestValidator.standardEngineSearchPathPrefix, childPATH: ProcessRunner.toolPATH)
            == ProcessRunner.toolPATH.split(separator: ":").map(String.init), "the live PATH already starts with the prefix")
    }

    @Test("a user-owned Homebrew prefix on the search path is refused before any tool is looked at")
    func userOwnedHomebrew() throws {
        let fixture = try InstallFixture()
        try fixture.mkdir(fixture.brewBin) // <root>/opt is root-owned, <root>/opt/homebrew and bin belong to the test user
        let homebrew = fixture.root + "/opt/homebrew"
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: fixture.brewBin,
                                                   reason: "passes through \(homebrew), which \(fixture.notRootReason)")) {
            try fixture.validate(newRun())
        }

        // Only the bin folder itself user-owned.
        fixture.rootOwned.insert(homebrew)
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: fixture.brewBin, reason: fixture.notRootReason)) {
            try fixture.validate(newRun())
        }

        // Writable by group, although root-owned.
        fixture.rootOwned.insert(fixture.brewBin)
        try fixture.chmod(fixture.brewBin, 0o775)
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: fixture.brewBin, reason: "is writable by group or others")) {
            try fixture.validate(newRun())
        }
        try fixture.chmod(fixture.brewBin, 0o755)
        _ = try fixture.validate(newRun())
    }

    @Test("a writable folder later in the order than the tools is refused as well")
    func writableLaterFolder() throws {
        let fixture = try InstallFixture()
        let sbin = fixture.root + "/sbin"
        try fixture.mkdir(sbin)
        fixture.rootOwned.insert(sbin)
        try fixture.chmod(sbin, 0o777)
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: sbin, reason: "is writable by group or others")) {
            try fixture.validate(newRun())
        }
    }

    @Test("a writable or user-owned ancestor of the tool folder is refused")
    func writableAncestor() throws {
        let fixture = try InstallFixture()
        let usr = fixture.root + "/usr"
        try fixture.chmod(usr, 0o775)
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: fixture.usrBin,
                                                   reason: "passes through \(usr), which is writable by group or others")) {
            try fixture.validate(newRun())
        }
        try fixture.chmod(usr, 0o755)
        fixture.rootOwned.remove(usr)
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: fixture.usrBin,
                                                   reason: "passes through \(usr), which \(fixture.notRootReason)")) {
            try fixture.validate(newRun())
        }
    }

    @Test("a tool that a non-root user owns, or that resolves to one, is refused")
    func userOwnedTool() throws {
        let fixture = try InstallFixture()
        let jq = fixture.usrBin + "/jq"
        fixture.rootOwned.remove(jq)
        #expect(throws: Refusal.untrustedToolchain(tool: "jq", path: jq, reason: fixture.notRootReason)) {
            try fixture.validate(newRun())
        }
        fixture.rootOwned.insert(jq)

        // Root-owned symlink to a file the user owns.
        let python = fixture.usrBin + "/python3"
        let target = fixture.elsewhere + "/python3"
        try fixture.remove(python)
        try fixture.write("#!/bin/sh\n", to: target, mode: 0o755)
        try fixture.symlink(python, to: target)
        fixture.rootOwned.insert(fixture.elsewhere)
        #expect(throws: Refusal.untrustedToolchain(tool: "python3", path: python, reason: "resolves to \(target), which \(fixture.notRootReason)")) {
            try fixture.validate(newRun())
        }
        fixture.rootOwned.insert(target)
        _ = try fixture.validate(newRun())

        // Group-writable tool.
        try fixture.chmod(fixture.usrBin + "/tcpdump", 0o775)
        #expect(throws: Refusal.untrustedToolchain(tool: "tcpdump", path: fixture.usrBin + "/tcpdump", reason: "is writable by group or others")) {
            try fixture.validate(newRun())
        }
    }

    @Test("the first existing entry on the order is the match: a user-owned shadow earlier in the order is refused")
    func shadowingEntry() throws {
        let fixture = try InstallFixture()
        let localBin = fixture.root + "/usr/local/bin"
        try fixture.mkdir(localBin)
        fixture.rootOwned.insert(fixture.root + "/usr/local")
        fixture.rootOwned.insert(localBin)
        try fixture.write("#!/bin/sh\n", to: localBin + "/nmap", mode: 0o644) // not even executable yet
        #expect(throws: Refusal.untrustedToolchain(tool: "nmap", path: localBin + "/nmap", reason: fixture.notRootReason)) {
            try fixture.validate(newRun())
        }
        fixture.rootOwned.insert(localBin + "/nmap")
        #expect(throws: Refusal.untrustedToolchain(tool: "nmap", path: localBin + "/nmap", reason: "is not a regular executable file")) {
            try fixture.validate(newRun())
        }
        try fixture.chmod(localBin + "/nmap", 0o755)
        _ = try fixture.validate(newRun())
    }

    @Test("a missing required tool is refused and says the engine would exit 3; a missing optional one is fine")
    func missingTools() throws {
        let fixture = try InstallFixture()
        _ = try fixture.validate(newRun()) // arp-scan and sshpass are absent
        try fixture.remove(fixture.usrBin + "/speedtest-cli")
        let refusal = Refusal.untrustedToolchain(tool: "speedtest-cli", path: "",
                                                 reason: "is not installed on the root search path (the engine would stop with exit code 3, missing dependency)")
        #expect(throws: refusal) { try fixture.validate(newRun()) }
        #expect(refusal.description.contains("exit code 3"))
        #expect(refusal.description.contains("sudo in the terminal pane"))

        // Not a trust question: authentication cannot make the engine find the tool, so
        // the helper's `.report` policy refuses it too, the verdict is `.unusable` (the
        // app shows "cannot run" and no dialog), and `--check-arguments` prints a refusal.
        #expect(!refusal.isClearedByAuthorization)
        #expect(throws: refusal) { try fixture.validate(newRun(), policy: .report) }
        #expect(fixture.validator.toolchainVerdict() == .unusable(refusal))
    }

    @Test("an optional tool is checked only when present")
    func optionalTool() throws {
        let fixture = try InstallFixture()
        let sshpass = fixture.usrBin + "/sshpass"
        try fixture.write("#!/bin/sh\n", to: sshpass, mode: 0o755)
        #expect(throws: Refusal.untrustedToolchain(tool: "sshpass", path: sshpass, reason: fixture.notRootReason)) {
            try fixture.validate(newRun())
        }
        fixture.rootOwned.insert(sshpass)
        _ = try fixture.validate(newRun())
        let arpScan = fixture.usrBin + "/arp-scan"
        try fixture.mkdir(arpScan) // a folder of that name is not a tool
        fixture.rootOwned.insert(arpScan)
        #expect(throws: Refusal.untrustedToolchain(tool: "arp-scan", path: arpScan, reason: "is not a regular executable file")) {
            try fixture.validate(newRun())
        }
    }

    @Test("a relative or empty PATH entry is refused")
    func relativePathEntry() throws {
        let fixture = try InstallFixture()
        var environment = fixture.environment
        environment.childSearchPath = fixture.childPATH + ":"
        #expect(throws: Refusal.untrustedToolchain(tool: Self.searchPath, path: "", reason: "is not an absolute path")) {
            try RequestValidator(environment: environment).validate(arguments: newRun(), sshPassword: nil, callerUID: fixture.callerUID)
        }
        environment.childSearchPath = "bin:" + fixture.childPATH
        let relative = Refusal.untrustedToolchain(tool: Self.searchPath, path: "bin", reason: "is not an absolute path")
        #expect(throws: relative) {
            try RequestValidator(environment: environment).validate(arguments: newRun(), sshPassword: nil, callerUID: fixture.callerUID)
        }
        // A malformed search path is the helper's own problem, not something an
        // administrator's password changes: hard refusal under `.report` as well.
        #expect(!relative.isClearedByAuthorization)
        #expect(throws: relative) {
            try RequestValidator(environment: environment).validate(arguments: newRun(), sshPassword: nil, callerUID: fixture.callerUID,
                                                                    toolchainPolicy: .report)
        }
        #expect(RequestValidator(environment: environment).toolchainVerdict() == .unusable(relative))
    }

    @Test("only ownership and writability verdicts are cleared by authentication")
    func clearedByAuthorization() {
        #expect(Refusal.untrustedToolchain(tool: "nmap", path: "/opt/homebrew/bin/nmap",
                                           reason: "passes through /opt/homebrew, which is owned by uid 501, not root").isClearedByAuthorization)
        #expect(Refusal.untrustedToolchain(tool: Self.searchPath, path: "/opt/homebrew/bin", reason: "is writable by group or others").isClearedByAuthorization)
        #expect(Refusal.untrustedToolchain(tool: "arp-scan", path: "/usr/bin/arp-scan", reason: "is not a regular executable file").isClearedByAuthorization)
        #expect(!Refusal.untrustedToolchain(tool: "speedtest-cli", path: "", reason: Refusal.missingToolReason).isClearedByAuthorization)
        #expect(!Refusal.untrustedToolchain(tool: Self.searchPath, path: "", reason: Refusal.relativePathReason).isClearedByAuthorization)
        #expect(!Refusal.executableNotRootOwned("/usr/local/bin/lss-network-tools").isClearedByAuthorization)
        #expect(!Refusal.untrustedAncestor(ancestor: "/usr/local", of: "/usr/local/share/x", reason: "is owned by uid 501, not root").isClearedByAuthorization)
        #expect(!Refusal.requestTooLarge.isClearedByAuthorization)
    }

    @Test("the refusal tells the user why and that administrator authentication clears it")
    func toolchainDescription() {
        let refusal = Refusal.untrustedToolchain(tool: "nmap", path: "/opt/homebrew/bin/nmap", reason: "passes through /opt/homebrew, which is owned by uid 501, not root")
        #expect(refusal.description == "The privileged helper runs tools a non-root user can modify only after administrator authentication (nmap: /opt/homebrew/bin/nmap passes through /opt/homebrew, which is owned by uid 501, not root).")
        #expect(refusal.code == "untrustedToolchain")
        let ancestor = Refusal.untrustedAncestor(ancestor: "/usr/local/share", of: "/usr/local/share/lss-network-tools/install.env", reason: "is owned by uid 501, not root")
        #expect(ancestor.description == "/usr/local/share, a folder on the way to /usr/local/share/lss-network-tools/install.env, is owned by uid 501, not root, so the helper does not trust anything below it.")
        #expect(ancestor.code == "untrustedAncestor")
    }

    // MARK: Report policy (the helper's authentication gate, contract §11.2)

    @Test("under .report a user-owned Homebrew prefix is reported, not refused, with argv and environment unchanged")
    func reportPolicyReportsUntrustedChain() throws {
        let fixture = try InstallFixture()
        let trusted = try fixture.validate(newRun(), password: "pw", progressToken: "0123456789abcdef", policy: .report)
        #expect(trusted.toolchain == .trusted)
        #expect(trusted == (try fixture.validate(newRun(), password: "pw", progressToken: "0123456789abcdef")),
                ".report and .refuse agree on a root-owned chain")

        let refusal = try fixture.makeUserOwnedHomebrew()
        // .refuse keeps throwing exactly what it threw before.
        #expect(throws: refusal) { try fixture.validate(newRun(), password: "pw", progressToken: "0123456789abcdef") }

        let reported = try fixture.validate(newRun(), password: "pw", progressToken: "0123456789abcdef", policy: .report)
        #expect(reported.toolchain == .untrusted(refusal))
        #expect(reported.executable == trusted.executable)
        #expect(reported.arguments == trusted.arguments)
        #expect(reported.environment == trusted.environment)
        #expect(reported.runDirectory == trusted.runDirectory)

        // The same through the JSON entry point.
        let request = HelperRunRequest(arguments: newRun(), sshPassword: "pw", progressToken: "0123456789abcdef")
        let data = try JSONEncoder().encode(request)
        #expect(throws: refusal) { try fixture.validator.validate(requestJSON: data, callerUID: fixture.callerUID) }
        let viaJSON = try fixture.validator.validate(requestJSON: data, callerUID: fixture.callerUID, toolchainPolicy: .report)
        #expect(viaJSON.toolchain == .untrusted(refusal))
        #expect(viaJSON.arguments == trusted.arguments)
    }

    @Test("under .report every other rule stays a hard refusal")
    func reportPolicyKeepsOtherRefusals() throws {
        let fixture = try InstallFixture()
        _ = try fixture.makeUserOwnedHomebrew()
        fixture.rootOwned.remove(fixture.script)
        #expect(throws: Refusal.executableNotRootOwned(fixture.script)) {
            try fixture.validate(newRun(), policy: .report)
        }
        fixture.rootOwned.insert(fixture.script)
        #expect(throws: Refusal.unknownFlag("--evil")) { try fixture.validate(newRun(["--evil"]), policy: .report) }
        #expect(throws: Refusal.runDirectoryOutsideOutput("/etc")) { try fixture.validate(["--build-report", "/etc"], policy: .report) }
        #expect(throws: Refusal.badValue(flag: "LSS_PROGRESS_TOKEN", value: "(hidden)")) {
            try fixture.validate(newRun(), progressToken: "short", policy: .report)
        }
    }

    @Test("toolchainVerdict() answers trusted / untrusted without reading the install record")
    func toolchainVerdict() throws {
        let fixture = try InstallFixture()
        #expect(fixture.validator.toolchainVerdict() == .trusted)
        try fixture.remove(fixture.installEnv) // the verdict concerns the tools, not the install
        #expect(fixture.validator.toolchainVerdict() == .trusted)

        let refusal = try fixture.makeUserOwnedHomebrew()
        #expect(fixture.validator.toolchainVerdict() == .untrusted(refusal))

        // A user-owned tool rather than a folder.
        let fresh = try InstallFixture()
        fresh.rootOwned.remove(fresh.usrBin + "/jq")
        #expect(fresh.validator.toolchainVerdict()
            == .untrusted(.untrustedToolchain(tool: "jq", path: fresh.usrBin + "/jq", reason: fresh.notRootReason)))
    }

    @Test("install.env, the script, the wrapper and the output folder must sit below trusted folders")
    func ancestorsOfInstall() throws {
        let fixture = try InstallFixture()
        let share = fixture.root + "/share"

        fixture.rootOwned.remove(share)
        #expect(throws: Refusal.untrustedAncestor(ancestor: share, of: fixture.installEnv, reason: fixture.notRootReason)) {
            try fixture.validate(newRun())
        }
        fixture.rootOwned.insert(share)

        try fixture.chmod(fixture.appRoot, 0o775)
        #expect(throws: Refusal.untrustedAncestor(ancestor: fixture.appRoot, of: fixture.installEnv, reason: "is writable by group or others")) {
            try fixture.validate(newRun())
        }
        try fixture.chmod(fixture.appRoot, 0o755)

        let bin = fixture.root + "/bin"
        fixture.rootOwned.remove(bin)
        #expect(throws: Refusal.untrustedAncestor(ancestor: bin, of: fixture.wrapper, reason: fixture.notRootReason)) {
            try fixture.validate(newRun())
        }
        fixture.rootOwned.insert(bin)

        // A separate DATA_ROOT (the Linux layout): its folders count for output/.
        let dataRoot = fixture.root + "/var/lib/lss-network-tools"
        try fixture.mkdir(dataRoot + "/output/" + InstallFixture.runName)
        for path in [dataRoot, dataRoot + "/output", dataRoot + "/output/" + InstallFixture.runName] { fixture.rootOwned.insert(path) }
        try fixture.writeInstallEnv("APP_ROOT=\"\(fixture.appRoot)\"\nDATA_ROOT=\"\(dataRoot)\"\nINSTALL_WRAPPER_PATH=\"\(fixture.wrapper)\"\n")
        #expect(throws: Refusal.untrustedAncestor(ancestor: fixture.root + "/var", of: dataRoot + "/output", reason: fixture.notRootReason)) {
            try fixture.validate(continueRun(dataRoot + "/output/" + InstallFixture.runName))
        }
        fixture.rootOwned.insert(fixture.root + "/var")
        fixture.rootOwned.insert(fixture.root + "/var/lib")
        #expect(try fixture.validate(continueRun(dataRoot + "/output/" + InstallFixture.runName)).runDirectory == dataRoot + "/output/" + InstallFixture.runName)
    }

    @Test("validateRepair applies the same ancestor rule")
    func repairAncestors() throws {
        let fixture = try InstallFixture()
        try fixture.chmod(fixture.root + "/share", 0o777)
        #expect(throws: Refusal.untrustedAncestor(ancestor: fixture.root + "/share", of: fixture.installEnv, reason: "is writable by group or others")) {
            try fixture.validator.validateRepair(runDirectory: fixture.runDirectory)
        }
    }
}

// MARK: - Code requirements (LSSXPC)

@Suite("LSSCodeRequirement")
struct CodeRequirementTests {
    @Test func teamRequirements() {
        #expect(LSSCodeRequirement.app(teamIdentifier: "AB12CD34EF", cdhash: nil)
            == #"anchor apple generic and identifier "ie.lssolutions.lss-network-tools" and certificate leaf[subject.OU] = "AB12CD34EF""#)
        #expect(LSSCodeRequirement.helper(teamIdentifier: "AB12CD34EF")
            == #"anchor apple generic and identifier "ie.lssolutions.lss-network-tools.helper" and certificate leaf[subject.OU] = "AB12CD34EF""#)
    }

    @Test func adHocRequirements() {
        let hash = String(repeating: "0a", count: 20)
        #expect(LSSCodeRequirement.app(teamIdentifier: nil, cdhash: hash)
            == "identifier \"ie.lssolutions.lss-network-tools\" and cdhash H\"\(hash)\"")
        #expect(LSSCodeRequirement.app(teamIdentifier: nil, cdhash: nil) == #"identifier "ie.lssolutions.lss-network-tools""#)
        #expect(LSSCodeRequirement.helper(teamIdentifier: nil) == #"identifier "ie.lssolutions.lss-network-tools.helper""#)
    }

    @Test("invalid inputs never produce a requirement", arguments: ["ab12cd34ef", "AB12CD34E", "AB12CD34EF\"", "AB12\" or true"])
    func invalidTeam(_ team: String) {
        #expect(LSSCodeRequirement.app(teamIdentifier: team, cdhash: nil) == nil)
        #expect(LSSCodeRequirement.helper(teamIdentifier: team) == nil)
    }

    @Test func invalidCDHash() {
        #expect(LSSCodeRequirement.app(teamIdentifier: nil, cdhash: "XYZ") == nil)
        #expect(LSSCodeRequirement.app(teamIdentifier: nil, cdhash: String(repeating: "A", count: 40)) == nil)
    }
}
