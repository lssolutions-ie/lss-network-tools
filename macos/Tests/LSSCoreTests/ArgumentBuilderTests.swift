import Foundation
import Testing
@testable import LSSCore

private typealias Problem = ArgumentBuilder.Problem

private func newRun(_ selection: RunTaskRequest.Selection = .tasks([.interfaceInfo]),
                    client: String = "Acme", location: String = "HQ", note: String = "",
                    interface: String? = "en0") -> RunTaskRequest {
    RunTaskRequest(selection: selection, context: .newRun(client: client, location: location, note: note), interface: interface)
}

private let runDir = URL(filePath: "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026", directoryHint: .isDirectory)

/// One row of the problems table: a request and the problem it must produce.
private struct ProblemCase: Sendable, CustomTestStringConvertible {
    let name: String
    let request: RunTaskRequest
    let expected: Problem
    var testDescription: String { name }
}

private let problemCases: [ProblemCase] = {
    var request: RunTaskRequest
    var cases: [ProblemCase] = []
    func add(_ name: String, _ request: RunTaskRequest, _ expected: Problem) { cases.append(.init(name: name, request: request, expected: expected)) }

    add("empty selection", newRun(.tasks([])), .noTasksSelected)
    add("interface nil", newRun(interface: nil), .interfaceRequired)
    add("interface blank", newRun(interface: "  "), .interfaceRequired)
    add("interface upper-case", newRun(interface: "EN0"), .invalidInterfaceName("EN0"))
    add("interface with space", newRun(interface: "en 0"), .invalidInterfaceName("en 0"))
    add("client empty", newRun(client: " "), .clientRequired)
    add("location empty", newRun(location: ""), .locationRequired)
    add("client leading dash", newRun(client: "-Acme"), .invalidText(field: "Client", reason: "must not start with “-”"))
    add("client control char", newRun(client: "Ac\u{01}me"), .invalidText(field: "Client", reason: "must not contain control characters"))
    add("client newline", newRun(client: "Acme\nLtd"), .invalidText(field: "Client", reason: "must be a single line"))
    add("location DEL", newRun(location: "HQ\u{7F}"), .invalidText(field: "Location", reason: "must not contain control characters"))
    add("note leading dash", newRun(note: "-x"), .invalidText(field: "Note", reason: "must not start with “-”"))
    request = newRun(); request.preparedBy = "L\u{01}S"
    add("prepared-by control char", request, .invalidText(field: "Prepared by", reason: "must not contain control characters"))
    let relative = URL(string: "relative/dir")!
    add("run dir relative (URL(string:))", RunTaskRequest(selection: .tasks([.dnsScan]), context: .existingRun(directory: relative), interface: "en0"), .runDirectoryNotAbsolute(relative))
    let relativeFile = URL(filePath: "relative/dir")
    add("run dir relative (URL(filePath:))", RunTaskRequest(selection: .tasks([.dnsScan]), context: .existingRun(directory: relativeFile), interface: "en0"), .runDirectoryNotAbsolute(relativeFile))
    let remote = URL(string: "https://example.com/run")!
    add("run dir not a file URL", RunTaskRequest(selection: .tasks([.dnsScan]), context: .existingRun(directory: remote), interface: "en0"), .runDirectoryNotAbsolute(remote))
    add("target missing", newRun(.tasks([.customPortScan])), .targetRequired)
    request = newRun(.tasks([.customDNS])); request.targetIP = "10.0.0.256"
    add("target invalid", request, .invalidTarget("10.0.0.256"))
    add("mac missing", newRun(.tasks([.findByMAC])), .macRequired)
    request = newRun(.tasks([.findByMAC])); request.macAddress = "zz:bb:cc:dd:ee:ff"
    add("mac invalid", request, .invalidMAC("zz:bb:cc:dd:ee:ff"))
    add("wireless missing", newRun(.tasks([.wirelessSurvey])), .wirelessRoomRequired)
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: " ", room: "Lobby")
    add("wireless floor blank", request, .wirelessRoomRequired)
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lob\u{01}by")
    add("wireless room control char", request, .invalidWirelessField("Room"))
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", accessPointPresent: true, accessPointLabel: "-AP1")
    add("wireless label leading dash", request, .invalidWirelessField("AP label"))
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", wifiInterface: "Wi-Fi")
    add("wireless interface invalid", request, .invalidInterfaceName("Wi-Fi"))
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", scanJSON: URL(string: "scan.json")!)
    add("wireless scan file relative", request, .invalidWirelessField("Wi-Fi scan file"))
    add("unifi missing (user)", newRun(.tasks([.unifiAdoption])), .sshUserRequired)
    add("unifi missing (password)", newRun(.tasks([.unifiAdoption])), .sshPasswordRequired)
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: " ", sshPasswordProvided: true)
    add("unifi user blank", request, .sshUserRequired)
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: "-root", sshPasswordProvided: true)
    add("unifi user leading dash", request, .invalidText(field: "SSH user", reason: "must not start with “-”"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: "ubnt", sshPasswordProvided: false)
    add("unifi password missing", request, .sshPasswordRequired)
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerPort: 70000, sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi port too large", request, .invalidText(field: "Controller port", reason: "must be between 1 and 65535"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerPort: 0, sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi port zero", request, .invalidText(field: "Controller port", reason: "must be between 1 and 65535"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "unifi example.com", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host with space", request, .invalidText(field: "Controller", reason: "must not contain spaces"))
    add("consent task 10", newRun(.tasks([.gatewayStress])), .consentRequired([.gatewayStress]))
    add("consent full audit", newRun(.fullAudit), .consentRequired([.gatewayStress]))
    add("consent 10 and 14", newRun(.tasks([.customStress, .gatewayStress])), .consentRequired([.gatewayStress, .customStress]))
    return cases
}()

@Suite("ArgumentBuilder — problems")
struct ArgumentBuilderProblemTests {
    @Test("a complete request has no problems")
    func valid() {
        var request = newRun(.tasks([.interfaceInfo, .dnsScan]), note: "vlan 10")
        request.preparedBy = "Ladislav Stojaník"
        #expect(ArgumentBuilder.problems(in: request).isEmpty)
        #expect(ArgumentBuilder.problems(in: RunTaskRequest(selection: .fullAudit, context: .existingRun(directory: runDir), interface: "en0", stressConsent: true)).isEmpty)
        #expect(ArgumentBuilder.problems(in: newRun(client: "Zoë & Sons — Ürümqi")).isEmpty, "Unicode letters and punctuation are fine")
    }

    @Test("each problem is produced by the input that violates it", arguments: problemCases)
    fileprivate func table(_ testCase: ProblemCase) {
        let problems = ArgumentBuilder.problems(in: testCase.request)
        #expect(problems.contains(testCase.expected), "got \(problems)")
    }

    @Test("problems come in form order and consent is always last")
    func orderAndConsentLast() {
        var request = RunTaskRequest(selection: .tasks([.gatewayStress, .customPortScan]), context: .newRun(client: "", location: "HQ", note: ""), interface: nil)
        request.preparedBy = "-me"
        let problems = ArgumentBuilder.problems(in: request)
        #expect(problems == [
            .interfaceRequired,
            .clientRequired,
            .invalidText(field: "Prepared by", reason: "must not start with “-”"),
            .targetRequired,
            .consentRequired([.gatewayStress]),
        ])
        #expect(problems.last == .consentRequired([.gatewayStress]))
    }

    @Test("task-specific checks only apply when the task is selected")
    func onlyWhenSelected() {
        var request = newRun(.tasks([.interfaceInfo]))
        request.targetIP = "not an ip"
        request.macAddress = "nope"
        request.wireless = .init(building: "", floor: "", room: "")
        request.unifi = .init(sshUser: "", sshPasswordProvided: false)
        #expect(ArgumentBuilder.problems(in: request).isEmpty)
        #expect(!request.requiresTarget && !request.requiresMAC && !request.requiresWireless && !request.requiresUniFi && !request.requiresConsent)
    }

    @Test("every problem has a non-empty user-facing description")
    func descriptions() {
        let all: [Problem] = [
            .noTasksSelected, .interfaceRequired, .invalidInterfaceName("EN0"), .clientRequired, .locationRequired,
            .invalidText(field: "Client", reason: "must be a single line"), .runDirectoryNotAbsolute(URL(string: "x")!),
            .targetRequired, .invalidTarget("1.2.3"), .macRequired, .invalidMAC("zz"), .wirelessRoomRequired,
            .invalidWirelessField("Room"), .sshUserRequired, .sshPasswordRequired, .consentRequired([.gatewayStress, .customStress]),
        ]
        for problem in all {
            #expect(!problem.description.isEmpty, "\(problem)")
            #expect(problem.description.hasSuffix("."), "\(problem)")
        }
        #expect(Problem.invalidText(field: "Client", reason: "must be a single line").description == "Client: must be a single line.")
        #expect(Problem.consentRequired([.gatewayStress, .customStress]).description.contains("10, 14"))
        #expect(Problem.invalidInterfaceName("EN0").description.contains("EN0"))
    }
}

@Suite("ArgumentBuilder — argv")
struct ArgumentBuilderArgvTests {
    @Test("a maximal request renders every flag in contract order, trimmed")
    func maximal() throws {
        let request = RunTaskRequest(
            selection: .tasks([.findByMAC, .gatewayStress, .wirelessSurvey, .customPortScan, .unifiAdoption, .customPortScan]),
            context: .newRun(client: " Acme Ltd ", location: "HQ ", note: " vlan 10 "),
            interface: " en0 ",
            preparedBy: " L. Stojanik ",
            skipPDF: true,
            stressConsent: true,
            targetIP: " 10.0.0.5 ",
            macAddress: "FC-B2-14-9A-0B-D2",
            wireless: .init(building: "HQ", floor: " 2 ", room: "Meeting Room B", accessPointPresent: true,
                            accessPointLabel: "AP-201", wifiInterface: "en1", scanJSON: URL(filePath: "/tmp/scan.json")),
            unifi: .init(controllerHost: " unifi.example.com ", controllerPort: 8443, https: true, sshUser: "ubnt", sshPasswordProvided: true),
            debug: true)
        let argv = try ArgumentBuilder.arguments(for: request)
        #expect(argv == [
            "--run-task", "10,13,17,19,20",
            "--interface", "en0",
            "--client", "Acme Ltd", "--location", "HQ", "--note", "vlan 10",
            "--prepared-by", "L. Stojanik",
            "--no-pdf",
            "--yes",
            "--target", "10.0.0.5",
            "--mac", "fc:b2:14:9a:0b:d2",
            "--wifi-interface", "en1", "--building", "HQ", "--floor", "2", "--room", "Meeting Room B",
            "--ap-present", "y", "--ap-label", "AP-201", "--wifi-scan-json", "/tmp/scan.json",
            "--controller", "unifi.example.com", "--controller-port", "8443", "--https", "y", "--ssh-user", "ubnt",
            "--debug",
        ])
    }

    @Test("argv follows the flag grammar: every flag is known and every value flag has a value")
    func grammar() throws {
        var request = newRun(.tasks([.wirelessSurvey, .unifiAdoption, .findByMAC, .customStress]), note: "n")
        request.stressConsent = true
        request.targetIP = "10.0.0.9"
        request.macAddress = "aabbccddeeff"
        request.wireless = .init(building: "B", floor: "F", room: "R")
        request.unifi = .init(controllerHost: "c", controllerPort: 8080, https: false, sshUser: "u", sshPasswordProvided: true)
        request.skipPDF = true
        request.debug = true
        let argv = try ArgumentBuilder.arguments(for: request)
        var index = 0
        while index < argv.count {
            let flag = argv[index]
            #expect(flag.hasPrefix("--"), "unexpected bare value \(flag)")
            #expect(!flag.contains("="), "values are separate argv elements")
            if ArgumentBuilder.valueFlags.contains(flag) {
                let value = try #require(argv.indices.contains(index + 1) ? argv[index + 1] : nil, "\(flag) needs a value")
                #expect(!value.hasPrefix("-"), "\(flag) value \(value) looks like a flag")
                index += 2
            } else {
                #expect(ArgumentBuilder.booleanFlags.contains(flag), "unknown flag \(flag)")
                index += 1
            }
        }
        #expect(ArgumentBuilder.valueFlags.isDisjoint(with: ArgumentBuilder.booleanFlags))
    }

    @Test("full audit is 000 and selections are sorted and de-duplicated")
    func selections() throws {
        #expect(try ArgumentBuilder.arguments(for: newRun(.fullAudit, interface: "en0").with { $0.stressConsent = true })
            == ["--run-task", "000", "--interface", "en0", "--client", "Acme", "--location", "HQ", "--yes"])
        #expect(try ArgumentBuilder.arguments(for: newRun(.tasks([.dnsScan, .interfaceInfo, .dnsScan, .vlanTrunk]))).prefix(2)
            == ["--run-task", "1,6,11"])
    }

    @Test("an existing run is continued with --run-dir (trailing slash dropped)")
    func existingRun() throws {
        let request = RunTaskRequest(selection: .tasks([.wirelessSurvey]), context: .existingRun(directory: runDir), interface: "en0",
                                     wireless: .init(building: "HQ", floor: "2", room: "Lobby"))
        let argv = try ArgumentBuilder.arguments(for: request)
        #expect(argv == [
            "--run-task", "17", "--interface", "en0",
            "--run-dir", "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026",
            "--building", "HQ", "--floor", "2", "--room", "Lobby", "--ap-present", "n",
        ])
        let slashless = URL(filePath: "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026")
        let same = RunTaskRequest(selection: .tasks([.dnsScan]), context: .existingRun(directory: slashless), interface: "en0")
        #expect(try ArgumentBuilder.arguments(for: same).contains("/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026"))
    }

    @Test("optional flags are omitted when empty or not applicable")
    func omissions() throws {
        // empty / blank note, no prepared-by, no PDF skip, no consent, no debug
        #expect(try ArgumentBuilder.arguments(for: newRun(note: "   ")) == ["--run-task", "1", "--interface", "en0", "--client", "Acme", "--location", "HQ"])

        // --yes only with consent, even for non-stress tasks
        #expect(!(try ArgumentBuilder.arguments(for: newRun(.tasks([.dnsScan])))).contains("--yes"))
        #expect(try ArgumentBuilder.arguments(for: newRun(.tasks([.dnsScan])).with { $0.stressConsent = true }).contains("--yes"))

        // task-specific data is ignored when the task is not selected
        var request = newRun(.tasks([.interfaceInfo]))
        request.targetIP = "10.0.0.5"
        request.macAddress = "aa:bb:cc:dd:ee:ff"
        request.wireless = .init(building: "HQ", floor: "2", room: "Lobby")
        request.unifi = .init(controllerHost: "c", sshUser: "u", sshPasswordProvided: true)
        let argv = try ArgumentBuilder.arguments(for: request)
        for flag in ["--target", "--mac", "--building", "--floor", "--room", "--ap-present", "--ap-label", "--wifi-interface", "--wifi-scan-json", "--controller", "--controller-port", "--https", "--ssh-user"] {
            #expect(!argv.contains(flag), Comment(rawValue: flag))
        }
    }

    @Test("wireless: --ap-present is always sent; the label only with an AP")
    func wireless() throws {
        var request = newRun(.tasks([.wirelessSurvey]))
        request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", accessPointPresent: false, accessPointLabel: "AP-1")
        var argv = try ArgumentBuilder.arguments(for: request)
        #expect(argv.suffix(8) == ["--building", "HQ", "--floor", "2", "--room", "Lobby", "--ap-present", "n"])
        #expect(!argv.contains("--ap-label"))
        #expect(!argv.contains("--wifi-interface"))

        request.wireless?.accessPointPresent = true
        request.wireless?.accessPointLabel = "  "
        argv = try ArgumentBuilder.arguments(for: request)
        #expect(argv.suffix(2) == ["--ap-present", "y"])
        #expect(!argv.contains("--ap-label"), "a blank label is not sent")
    }

    @Test("UniFi: controller, port and https are optional; --https renders y/n")
    func unifi() throws {
        var request = newRun(.tasks([.unifiAdoption]))
        request.unifi = .init(sshUser: " ubnt ", sshPasswordProvided: true)
        #expect(try ArgumentBuilder.arguments(for: request).suffix(2) == ["--ssh-user", "ubnt"])

        request.unifi = .init(controllerHost: "unifi.lssolutions.ie", controllerPort: 443, https: false, sshUser: "ubnt", sshPasswordProvided: true)
        #expect(try ArgumentBuilder.arguments(for: request).suffix(8)
            == ["--controller", "unifi.lssolutions.ie", "--controller-port", "443", "--https", "n", "--ssh-user", "ubnt"])
    }

    @Test("the MAC is passed in its normalised form")
    func mac() throws {
        var request = newRun(.tasks([.findByMAC]))
        request.macAddress = " FCB2.149A.0BD2 "
        #expect(try ArgumentBuilder.arguments(for: request).suffix(2) == ["--mac", "fc:b2:14:9a:0b:d2"])
    }

    @Test("arguments(for:) throws the first problem")
    func throwsFirstProblem() {
        let request = RunTaskRequest(selection: .tasks([]), context: .newRun(client: "", location: "", note: ""), interface: nil)
        #expect(throws: Problem.noTasksSelected) { try ArgumentBuilder.arguments(for: request) }
        #expect(throws: Problem.consentRequired([.gatewayStress])) { try ArgumentBuilder.arguments(for: newRun(.tasks([.gatewayStress]))) }
    }

    @Test("--build-report renders its four flags in order")
    func buildReport() throws {
        let minimal = BuildReportRequest(runDirectory: runDir)
        #expect(try ArgumentBuilder.arguments(for: minimal) == ["--build-report", "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026"])

        let full = BuildReportRequest(runDirectory: runDir, preparedBy: " L. S. ", skipPDF: true, outputDirectory: URL(filePath: "/Users/me/Desktop/"))
        #expect(try ArgumentBuilder.arguments(for: full) == [
            "--build-report", "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026",
            "--prepared-by", "L. S.",
            "--no-pdf",
            "--output", "/Users/me/Desktop",
        ])
    }

    @Test("--build-report rejects relative directories and bad prepared-by text")
    func buildReportRejections() {
        let relative = URL(string: "relative/run")!
        #expect(throws: Problem.runDirectoryNotAbsolute(relative)) { try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: relative)) }
        #expect(throws: Problem.invalidText(field: "Prepared by", reason: "must not start with “-”")) {
            try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: runDir, preparedBy: "-x"))
        }
        let relativeOutput = URL(filePath: "exports")
        #expect(throws: Problem.runDirectoryNotAbsolute(relativeOutput)) {
            try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: runDir, outputDirectory: relativeOutput))
        }
    }

    @Test("sudo command with and without preserved environment")
    func sudo() {
        let plain = ArgumentBuilder.sudoCommand(wrapper: "/usr/local/bin/lss-network-tools", arguments: ["--run-task", "1"], preserveEnvironment: [])
        #expect(plain.executable == "/usr/bin/sudo")
        #expect(plain.arguments == ["/usr/local/bin/lss-network-tools", "--run-task", "1"])

        let withPassword = ArgumentBuilder.sudoCommand(wrapper: "/usr/local/bin/lss-network-tools", arguments: ["--run-task", "19"], preserveEnvironment: ["LSS_SSH_PASSWORD"])
        #expect(withPassword.arguments == ["--preserve-env=LSS_SSH_PASSWORD", "/usr/local/bin/lss-network-tools", "--run-task", "19"])

        let two = ArgumentBuilder.sudoCommand(wrapper: "w", arguments: [], preserveEnvironment: ["A", "B"])
        #expect(two.arguments == ["--preserve-env=A,B", "w"])
    }
}

@Suite("ArgumentBuilder — validators")
struct ArgumentBuilderValidatorTests {
    @Test("valid IPv4 addresses", arguments: ["10.0.0.1", "0.0.0.0", "255.255.255.255", "192.168.1.100", "1.2.3.4", "100.64.0.1"])
    func validIPv4(_ text: String) {
        #expect(ArgumentBuilder.isValidIPv4(text))
    }

    @Test("invalid IPv4 addresses", arguments: [
        "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.256", "01.2.3.4", "1.02.3.4", "1.2.3.+4", "+1.2.3.4", " 1.2.3.4", "1.2.3.4 ",
        "a.b.c.d", "1..2.3", "1.2.3.", ".1.2.3", "1.2.3.4\n", "١.٢.٣.٤", "1,2,3,4", "1.2.3.4/24", "-1.2.3.4", "1.2.3.4a", "1234.1.1.1",
    ])
    func invalidIPv4(_ text: String) {
        #expect(!ArgumentBuilder.isValidIPv4(text))
    }

    @Test("MAC normalisation", arguments: [
        ("aa:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff"),
        ("AA:BB:CC:DD:EE:FF", "aa:bb:cc:dd:ee:ff"),
        ("AA-BB-CC-DD-EE-FF", "aa:bb:cc:dd:ee:ff"),
        ("aabb.ccdd.eeff", "aa:bb:cc:dd:ee:ff"),
        ("AABB.CCDD.EEFF", "aa:bb:cc:dd:ee:ff"),
        ("aabbccddeeff", "aa:bb:cc:dd:ee:ff"),
        ("AABBCCDDEEFF", "aa:bb:cc:dd:ee:ff"),
        ("  fc:b2:14:9a:0b:d2\n", "fc:b2:14:9a:0b:d2"),
        ("\tFC-B2-14-9A-0B-D2 ", "fc:b2:14:9a:0b:d2"),
        ("a:b:c:d:e:f", "0a:0b:0c:0d:0e:0f"),
        ("0:1a:2b:3:4c:5", "00:1a:2b:03:4c:05"),
    ])
    func macValid(_ input: String, _ expected: String) {
        #expect(ArgumentBuilder.normalizedMAC(input) == expected)
    }

    @Test("MAC rejections", arguments: [
        "", "   ", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "gg:bb:cc:dd:ee:ff", "aabb-ccdd-eeff", "aa:bb-cc:dd:ee:ff",
        "aabbccddeef", "aabbccddeeff0", "aa bb cc dd ee ff", "aabb.ccdd.eef", "aabb.ccdd.eeff.0011", "aa::cc:dd:ee:ff",
        "aaa:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:f-", "ＡＡ:bb:cc:dd:ee:ff", "aa.bb.cc.dd.ee.ff",
    ])
    func macInvalid(_ input: String) {
        #expect(ArgumentBuilder.normalizedMAC(input) == nil, Comment(rawValue: input))
    }

    @Test("interface names", arguments: [
        ("en0", true), ("en12", true), ("bridge100", true), ("utun3", true), ("awdl0", true), ("eth0", true), ("wlp3s0", true), ("lo0", true),
        ("abcdefghijklmno", true),
        ("", false), ("e", false), ("EN0", false), ("en 0", false), (" en0", false), ("-en0", false), ("en0\n", false),
        ("abcdefghijklmnop", false), ("0en", false), ("en0;rm", false), ("en-0", false), ("en_0", false), ("én0", false), ("en0.1", false),
    ])
    func interfaceNames(_ name: String, _ valid: Bool) {
        #expect(ArgumentBuilder.isValidInterfaceName(name) == valid, Comment(rawValue: name))
    }
}

private extension RunTaskRequest {
    func with(_ change: (inout RunTaskRequest) -> Void) -> RunTaskRequest {
        var copy = self
        change(&copy)
        return copy
    }
}
