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
    add("interface with slash", newRun(interface: "en0/1"), .invalidInterfaceName("en0/1"))
    add("interface leading dash", newRun(interface: "-x"), .invalidInterfaceName("-x"))
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
    add("client too long", newRun(client: String(repeating: "a", count: 121)), .invalidText(field: "Client", reason: "must be at most 120 characters"))
    add("client zero-width space", newRun(client: "Ac\u{200B}me"), .invalidText(field: "Client", reason: "contains invisible or bidirectional control characters"))
    // U+0085 and U+200B at either end would be trimmed as whitespace; inside the text they are refused.
    add("location C1 control", newRun(location: "H\u{85}Q"), .invalidText(field: "Location", reason: "contains invisible or bidirectional control characters"))
    add("note byte-order mark", newRun(note: "x\u{FEFF}"), .invalidText(field: "Note", reason: "contains invisible or bidirectional control characters"))
    request = newRun(); request.preparedBy = "L\u{202E}S"
    add("prepared-by bidi override", request, .invalidText(field: "Prepared by", reason: "contains invisible or bidirectional control characters"))
    request = newRun(); request.preparedBy = "L\u{2066}S\u{2069}"
    add("prepared-by bidi isolate", request, .invalidText(field: "Prepared by", reason: "contains invisible or bidirectional control characters"))
    let dotReason = "must not contain “.” or “..” path components"
    for (name, path) in [("traversal", "/usr/local/share/lss-network-tools/output/../output/acme-hq-03-10-2026"),
                         ("trailing /..", "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026/.."),
                         ("single dot", "/usr/local/share/lss-network-tools/output/./acme-hq-03-10-2026"),
                         ("trailing /.", "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026/.")] {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        add("run dir \(name)", RunTaskRequest(selection: .tasks([.dnsScan]), context: .existingRun(directory: url), interface: "en0"),
            .invalidText(field: "Run directory", reason: dotReason))
    }
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
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", wifiInterface: "Wi Fi")
    add("wireless interface invalid", request, .invalidInterfaceName("Wi Fi"))
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", scanJSON: URL(string: "scan.json")!)
    add("wireless scan file relative", request, .invalidWirelessField("Wi-Fi scan file"))
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: "Lobby", scanJSON: URL(filePath: "/Users/me/Library/../scans/x.json"))
    add("wireless scan file traversal", request, .invalidWirelessField("Wi-Fi scan file"))
    request = newRun(.tasks([.wirelessSurvey])); request.wireless = .init(building: "HQ", floor: "2", room: String(repeating: "r", count: 121))
    add("wireless room too long", request, .invalidWirelessField("Room"))
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
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "unifi_example.com", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host outside the class", request, .invalidText(field: "Controller", reason: "may only contain letters, digits, “.” and “-”"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "-unifi.example.com", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host leading dash", request, .invalidText(field: "Controller", reason: "must not start with “-”"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "https:///manage", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host empty after normalisation", request, .invalidText(field: "Controller", reason: "must be a host name or IP address"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "unifi.example.com:https", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host bad port suffix", request, .invalidText(field: "Controller", reason: "must not contain “:” unless it is followed by a port between 1 and 65535"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "unifi.example.com:70000", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host port suffix out of range", request, .invalidText(field: "Controller", reason: "must not contain “:” unless it is followed by a port between 1 and 65535"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "unifi.example.com:8443", controllerPort: 8080, sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host port suffix disagrees with the port field", request, .invalidText(field: "Controller", reason: "names port 8443, but the port field says 8080"))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(controllerHost: "unifi.exam\u{200B}ple.com", sshUser: "ubnt", sshPasswordProvided: true)
    add("unifi host zero-width space", request, .invalidText(field: "Controller", reason: "contains invisible or bidirectional control characters"))
    let userReason = "must start with a letter or digit and contain only letters, digits, “.”, “_” or “-”"
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: "ubnt user", sshPasswordProvided: true)
    add("unifi user with space", request, .invalidText(field: "SSH user", reason: userReason))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: ".ubnt", sshPasswordProvided: true)
    add("unifi user leading dot", request, .invalidText(field: "SSH user", reason: userReason))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: "ub;nt", sshPasswordProvided: true)
    add("unifi user semicolon", request, .invalidText(field: "SSH user", reason: userReason))
    request = newRun(.tasks([.unifiAdoption])); request.unifi = .init(sshUser: String(repeating: "u", count: 121), sshPasswordProvided: true)
    add("unifi user too long", request, .invalidText(field: "SSH user", reason: "must be at most 120 characters"))
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
        #expect(ArgumentBuilder.problems(in: newRun(client: String(repeating: "é", count: 120))).isEmpty, "120 scalars is the limit, not below it")
        #expect(ArgumentBuilder.problems(in: newRun(interface: "enp3s0")).isEmpty, "Linux interface names pass the shape check")

        var unifi = newRun(.tasks([.unifiAdoption]))
        unifi.unifi = .init(controllerHost: " HTTPS://unifi.example.com:8443/manage ", sshUser: "ubnt", sshPasswordProvided: true)
        #expect(ArgumentBuilder.problems(in: unifi).isEmpty, "scheme, path and a port suffix are normalised away")
        unifi.unifi = .init(controllerHost: "unifi.example.com:8443", controllerPort: 8443, sshUser: "admin.1_a-b", sshPasswordProvided: true)
        #expect(ArgumentBuilder.problems(in: unifi).isEmpty, "a port suffix that agrees with the port field is fine")
        unifi.unifi = .init(controllerHost: "10.0.0.2", controllerPort: 8080, https: false, sshUser: "ubnt", sshPasswordProvided: true)
        #expect(ArgumentBuilder.problems(in: unifi).isEmpty)
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
            macAddress: "00-00-5E-00-53-01",
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
            "--mac", "00:00:5e:00:53:01",
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

    @Test("UniFi: the controller travels normalised and a :port suffix becomes --controller-port")
    func controllerNormalisation() throws {
        var request = newRun(.tasks([.unifiAdoption]))
        request.unifi = .init(controllerHost: " HTTPS://unifi.example.com:8443/manage/site ", https: true, sshUser: "ubnt", sshPasswordProvided: true)
        #expect(try ArgumentBuilder.arguments(for: request).suffix(8)
            == ["--controller", "unifi.example.com", "--controller-port", "8443", "--https", "y", "--ssh-user", "ubnt"])

        request.unifi = .init(controllerHost: "http://10.0.0.2/", sshUser: "ubnt", sshPasswordProvided: true)
        #expect(try ArgumentBuilder.arguments(for: request).suffix(4) == ["--controller", "10.0.0.2", "--ssh-user", "ubnt"])

        request.unifi = .init(controllerHost: "unifi.example.com:8443", controllerPort: 8443, sshUser: "ubnt", sshPasswordProvided: true)
        #expect(try ArgumentBuilder.arguments(for: request).suffix(6)
            == ["--controller", "unifi.example.com", "--controller-port", "8443", "--ssh-user", "ubnt"])

        request.unifi = .init(controllerHost: "unifi.example.com:8443", controllerPort: 8080, sshUser: "ubnt", sshPasswordProvided: true)
        #expect(throws: Problem.invalidText(field: "Controller", reason: "names port 8443, but the port field says 8080")) {
            try ArgumentBuilder.arguments(for: request)
        }
    }

    @Test("the MAC is passed in its normalised form")
    func mac() throws {
        var request = newRun(.tasks([.findByMAC]))
        request.macAddress = " 0000.5E00.5301 "
        #expect(try ArgumentBuilder.arguments(for: request).suffix(2) == ["--mac", "00:00:5e:00:53:01"])
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

    @Test("--build-report rejects . and .. path components in both directories")
    func buildReportDotComponents() {
        let reason = "must not contain “.” or “..” path components"
        let traversal = URL(filePath: "/usr/local/share/lss-network-tools/output/../output/acme-hq-03-10-2026", directoryHint: .isDirectory)
        #expect(throws: Problem.invalidText(field: "Run directory", reason: reason)) {
            try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: traversal))
        }
        let trailing = URL(filePath: "/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026/..")
        #expect(throws: Problem.invalidText(field: "Run directory", reason: reason)) {
            try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: trailing))
        }
        let dotOutput = URL(filePath: "/usr/local/share/lss-network-tools/output/./acme-hq-03-10-2026", directoryHint: .isDirectory)
        #expect(throws: Problem.invalidText(field: "Output directory", reason: reason)) {
            try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: runDir, outputDirectory: dotOutput))
        }
        let tooLong = String(repeating: "p", count: 121)
        #expect(throws: Problem.invalidText(field: "Prepared by", reason: "must be at most 120 characters")) {
            try ArgumentBuilder.arguments(for: BuildReportRequest(runDirectory: runDir, preparedBy: tooLong))
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

    @Test("sudo command drops preserve-env names that are not environment variable names")
    func sudoDropsBadNames() {
        let mixed = ArgumentBuilder.sudoCommand(wrapper: "w", arguments: ["--run-task", "19"],
                                                preserveEnvironment: ["LSS_SSH_PASSWORD", "bad name", "lower", "A=B", "X,Y", "", "1A", "_OK1", "-x"])
        #expect(mixed.arguments == ["--preserve-env=LSS_SSH_PASSWORD,_OK1", "w", "--run-task", "19"])

        let none = ArgumentBuilder.sudoCommand(wrapper: "w", arguments: [], preserveEnvironment: ["a,b", "C D"])
        #expect(none.arguments == ["w"], "no valid name → no --preserve-env at all")
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
        ("  00:00:5e:00:53:01\n", "00:00:5e:00:53:01"),
        ("\t00-00-5E-00-53-01 ", "00:00:5e:00:53:01"),
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

    @Test("interface names: ^[A-Za-z][A-Za-z0-9._-]{0,14}$", arguments: [
        ("en0", true), ("en12", true), ("bridge100", true), ("utun3", true), ("awdl0", true), ("eth0", true), ("wlp3s0", true), ("lo0", true),
        ("abcdefghijklmno", true), ("e", true), ("EN0", true),
        // Linux shapes the old ^[a-z][a-z0-9]{1,14}$ rejected
        ("enp3s0", true), ("br-1234abcd", true), ("eth0.100", true), ("wlp2s0", true), ("en-0", true), ("en_0", true), ("en0.1", true),
        ("", false), ("en 0", false), (" en0", false), ("-en0", false), ("-x", false), ("en0\n", false), ("en/0", false), ("en0/", false),
        ("abcdefghijklmnop", false), ("0en", false), ("en0;rm", false), ("én0", false), ("en0\u{200B}", false),
    ])
    func interfaceNames(_ name: String, _ valid: Bool) {
        #expect(ArgumentBuilder.isValidInterfaceName(name) == valid, Comment(rawValue: name))
    }

    @Test("SSH user names: ^[A-Za-z0-9][A-Za-z0-9._-]*$", arguments: [
        ("ubnt", true), ("admin1", true), ("1st", true), ("a.b_c-d", true), ("UBNT", true),
        ("", false), ("-oProxyCommand=x", false), (".ubnt", false), ("_ubnt", false), ("ubnt user", false), ("ub;nt", false),
        ("übnt", false), ("ubnt\n", false), ("ubnt@host", false),
    ])
    func sshUsers(_ user: String, _ valid: Bool) {
        #expect(ArgumentBuilder.isValidSSHUser(user) == valid, Comment(rawValue: user))
    }

    @Test("environment variable names for sudo --preserve-env", arguments: [
        ("LSS_SSH_PASSWORD", true), ("_X", true), ("A1", true), ("A", true),
        ("", false), ("1A", false), ("lower", false), ("A-B", false), ("A=B", false), ("A,B", false), ("A B", false), ("Á", false),
    ])
    func environmentNames(_ name: String, _ valid: Bool) {
        #expect(ArgumentBuilder.isValidEnvironmentName(name) == valid, Comment(rawValue: name))
    }

    @Test("controller host normalisation mirrors unifi_adoption", arguments: [
        ("unifi.example.com", "unifi.example.com"),
        (" https://unifi.example.com/manage ", "unifi.example.com"),
        ("HTTP://10.0.0.2:8080/", "10.0.0.2:8080"),
        ("unifi.example.com:8443", "unifi.example.com:8443"),
        ("https://unifi.example.com:8443/manage/site/default", "unifi.example.com:8443"),
        ("https:///x", ""),
        ("", ""),
        ("ftp://unifi.example.com", "ftp:"),
    ])
    func controllerHosts(_ input: String, _ expected: String) {
        #expect(ArgumentBuilder.normalizedControllerHost(input) == expected, Comment(rawValue: input))
    }

    @Test("free-text rules: single line, no control / invisible characters, no leading dash, at most 120 scalars")
    func freeText() {
        #expect(ArgumentBuilder.freeTextProblem("Acme Ltd — Zoë") == nil)
        #expect(ArgumentBuilder.freeTextProblem(String(repeating: "x", count: 120)) == nil)
        #expect(ArgumentBuilder.freeTextProblem(String(repeating: "x", count: 121)) == "must be at most 120 characters")
        #expect(ArgumentBuilder.freeTextProblem("a\nb") == "must be a single line")
        #expect(ArgumentBuilder.freeTextProblem("a\u{1B}[2J") == "must not contain control characters")
        #expect(ArgumentBuilder.freeTextProblem("a\u{7F}") == "must not contain control characters")
        #expect(ArgumentBuilder.freeTextProblem("-a") == "must not start with “-”")
        for scalar in ["\u{80}", "\u{9F}", "\u{200B}", "\u{200F}", "\u{2028}", "\u{202E}", "\u{2066}", "\u{2069}", "\u{FEFF}"] {
            #expect(ArgumentBuilder.freeTextProblem("a\(scalar)b") == "contains invisible or bidirectional control characters", Comment(rawValue: scalar.unicodeScalars.map { String($0.value, radix: 16) }.joined()))
        }
        for scalar in ["\u{A0}", "\u{200A}", "\u{2010}", "\u{2027}", "\u{202F}", "\u{2065}", "\u{206A}", "\u{FEFE}"] {
            #expect(ArgumentBuilder.freeTextProblem("a\(scalar)b") == nil, Comment(rawValue: scalar.unicodeScalars.map { String($0.value, radix: 16) }.joined()))
        }
        // Paths are not length-limited but refuse dot components.
        #expect(ArgumentBuilder.pathProblem("/" + String(repeating: "p", count: 300)) == nil)
        #expect(ArgumentBuilder.pathProblem("/a/../b") == "must not contain “.” or “..” path components")
        #expect(ArgumentBuilder.pathProblem("/a/..") == "must not contain “.” or “..” path components")
        #expect(ArgumentBuilder.pathProblem("/a/./b") == "must not contain “.” or “..” path components")
        #expect(ArgumentBuilder.pathProblem("/a/.hidden/b") == nil, "a dot-prefixed name is not a dot component")
        #expect(ArgumentBuilder.pathProblem("/a\u{200B}/b") == "contains invisible or bidirectional control characters")
    }
}

private extension RunTaskRequest {
    func with(_ change: (inout RunTaskRequest) -> Void) -> RunTaskRequest {
        var copy = self
        change(&copy)
        return copy
    }
}
