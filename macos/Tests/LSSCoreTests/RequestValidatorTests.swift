import Foundation
import Testing
@testable import LSSCore
import LSSXPC

private typealias Refusal = RequestValidator.Refusal

// MARK: - Fixture

/// A fake CLI install in a temporary directory: install.env, wrapper, script, an output
/// folder with one run, and a home folder with a Wi-Fi scan file. Tests cannot create
/// root-owned files, so the file-status shim reports `rootOwned` paths as uid 0 and
/// `owners` overrides individual owners. The temporary root is canonicalised first
/// (`/var` → `/private/var`), so "no symlink in the path" holds for the fixture itself.
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
        rootOwned = [installEnv, script, wrapper, output, runDirectory]

        for directory in [appRoot, output, runDirectory, root + "/bin", scans, elsewhere] {
            try mkdir(directory)
        }
        try writeInstallEnv()
        try write("#!/usr/bin/env bash\necho engine\n", to: script, mode: 0o755)
        try writeWrapper(execs: script)
        try write("[]\n", to: scanFile, mode: 0o600)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    var environment: RequestValidator.Environment {
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
                }
                return status
            },
            resolvePath: live.resolvePath,
            readFile: live.readFile,
            homeDirectory: { $0 == callerUID ? home : nil }
        )
    }

    var validator: RequestValidator { RequestValidator(environment: environment) }

    func validate(_ arguments: [String], password: String? = nil) throws -> RequestValidator.Validated {
        try validator.validate(arguments: arguments, sshPassword: password, callerUID: callerUID)
    }

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

private let expectedBaseEnvironment: [String: String] = [
    "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": "/var/root",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "TERM": "dumb",
    "LSS_QUIET_SPINNER": "1",
]

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
        var expectedEnvironment = expectedBaseEnvironment
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
        #expect(validated.environment == expectedBaseEnvironment)
    }

    @Test("--output may be a run directory or a folder the caller owns (canonicalised)")
    func outputDirectories() throws {
        let fixture = try InstallFixture()
        let exports = fixture.home + "/Desktop/exports"
        try fixture.mkdir(exports)
        try fixture.symlink(fixture.home + "/exports-link", to: exports)

        let intoRun = try fixture.validate(["--build-report", fixture.runDirectory, "--output", fixture.runDirectory])
        #expect(intoRun.arguments == ["--build-report", fixture.runDirectory, "--output", fixture.runDirectory])
        let owned = try fixture.validate(["--build-report", fixture.runDirectory, "--output", fixture.home + "/exports-link/"])
        #expect(owned.arguments == ["--build-report", fixture.runDirectory, "--output", exports])
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
        #expect(try fixture.validate(newRun(), password: "").environment == expectedBaseEnvironment)
    }

    @Test("HelperRunRequest JSON from the app decodes through validate(requestJSON:)")
    func requestJSON() throws {
        let fixture = try InstallFixture()
        let request = HelperRunRequest(arguments: newRun(), sshPassword: "pw", callerUID: 12345)
        let validated = try fixture.validator.validate(requestJSON: JSONEncoder().encode(request), callerUID: fixture.callerUID)
        #expect(validated.arguments == newRun())
        #expect(validated.environment["LSS_SSH_PASSWORD"] == "pw")
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
    ("--interface", "EN0"), ("--interface", "e"), ("--interface", "0en"), ("--interface", "en0;reboot"),
    ("--interface", "abcdefghijklmnop"), ("--interface", "en 0"), ("--wifi-interface", "Wi-Fi"),
    ("--target", "256.1.1.1"), ("--target", "1.2.3"), ("--target", "01.2.3.4"), ("--target", "1.2.3.4 "), ("--target", "localhost"),
    ("--mac", "zz:bb:cc:dd:ee:ff"), ("--mac", "aa:bb:cc"), ("--mac", "aa:bb:cc:dd:ee:ff:00"), ("--mac", "aa:bb-cc:dd:ee:ff"),
    ("--controller-port", "0"), ("--controller-port", "65536"), ("--controller-port", "80a"), ("--controller-port", "+80"),
    ("--controller-port", "123456"), ("--controller-port", ""),
    ("--https", "yes"), ("--https", "Y"), ("--https", "1"), ("--ap-present", "N"), ("--ap-present", "true"),
    ("--client", String(repeating: "a", count: 121)), ("--client", "Ac\u{01}me"), ("--location", "HQ\nAnnex"),
    ("--note", "DEL\u{7F}"), ("--prepared-by", "-me"), ("--building", ""), ("--room", "\t"), ("--floor", "-1"),
    ("--ssh-user", "-oProxyCommand=x"), ("--controller", "-x"), ("--ap-label", "\u{1B}[31mred"),
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
