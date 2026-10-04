import Foundation

/// Turns a `RunTaskRequest` / `BuildReportRequest` into the argv the CLI accepts
/// (contract §2; flag grammar PLAN §7.1). Values are always separate argv
/// elements, never `--flag=value`; text never starts with `-`.
public enum ArgumentBuilder {
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case noTasksSelected
        case interfaceRequired
        case invalidInterfaceName(String)
        case clientRequired
        case locationRequired
        /// Control characters, newlines or a leading "-" in a free-text field.
        case invalidText(field: String, reason: String)
        case runDirectoryNotAbsolute(URL)
        case targetRequired
        case invalidTarget(String)
        case macRequired
        case invalidMAC(String)
        /// Building, floor and room must all be non-empty for Task 17.
        case wirelessRoomRequired
        case invalidWirelessField(String)
        case sshUserRequired
        case sshPasswordRequired
        case consentRequired([TaskID])

        /// User-facing sentence shown inline in the New Run sheet.
        public var description: String {
            switch self {
            case .noTasksSelected: "Select at least one task."
            case .interfaceRequired: "Choose the network interface to audit."
            case .invalidInterfaceName(let name): "“\(name)” is not a valid interface name."
            case .clientRequired: "Enter the client name."
            case .locationRequired: "Enter the location."
            case .invalidText(let field, let reason): "\(field): \(reason)."
            case .runDirectoryNotAbsolute(let url): "The run directory must be an absolute path (\(url.path(percentEncoded: false)))."
            case .targetRequired: "Enter the target IPv4 address."
            case .invalidTarget(let text): "“\(text)” is not a valid IPv4 address."
            case .macRequired: "Enter the MAC address to look for."
            case .invalidMAC(let text): "“\(text)” is not a valid MAC address."
            case .wirelessRoomRequired: "Enter the building, floor and room for the survey."
            case .invalidWirelessField(let field): "\(field) contains characters the survey cannot store."
            case .sshUserRequired: "Enter the SSH user name for the UniFi devices."
            case .sshPasswordRequired: "Enter the SSH password for the UniFi devices."
            case .consentRequired(let tasks):
                "Tasks \(tasks.map { String($0.rawValue) }.joined(separator: ", ")) are stress tests and need explicit consent."
            }
        }
    }

    // MARK: - Validation

    /// Every problem, in form order (empty = valid). The order follows the New
    /// Run sheet top to bottom: selection, interface, run context (client /
    /// location / note or run directory, then prepared-by), target, MAC,
    /// wireless room, UniFi, and — always last — the stress-test consent, which
    /// the GUI pulls out of the inline list and turns into a dialog.
    public static func problems(in request: RunTaskRequest) -> [Problem] {
        var problems: [Problem] = []

        // Selection
        if request.selection.taskIDs.isEmpty {
            problems.append(.noTasksSelected)
        }

        // Interface — always required: the GUI fills it from the manifest for a
        // continued run, so a missing value is a form error, not a CLI default.
        let interface = trimmed(request.interface)
        if interface.isEmpty {
            problems.append(.interfaceRequired)
        } else if !isValidInterfaceName(interface) {
            problems.append(.invalidInterfaceName(interface))
        }

        // Run context
        switch request.context {
        case .newRun(let client, let location, let note):
            let client = trimmed(client)
            if client.isEmpty {
                problems.append(.clientRequired)
            } else if let reason = textProblem(client) {
                problems.append(.invalidText(field: "Client", reason: reason))
            }
            let location = trimmed(location)
            if location.isEmpty {
                problems.append(.locationRequired)
            } else if let reason = textProblem(location) {
                problems.append(.invalidText(field: "Location", reason: reason))
            }
            let note = trimmed(note)
            if !note.isEmpty, let reason = textProblem(note) {
                problems.append(.invalidText(field: "Note", reason: reason))
            }
        case .existingRun(let directory):
            if let path = fileSystemPath(directory) {
                if let reason = textProblem(path) {
                    problems.append(.invalidText(field: "Run directory", reason: reason))
                }
            } else {
                problems.append(.runDirectoryNotAbsolute(directory))
            }
        }
        let preparedBy = trimmed(request.preparedBy)
        if !preparedBy.isEmpty, let reason = textProblem(preparedBy) {
            problems.append(.invalidText(field: "Prepared by", reason: reason))
        }

        // Target (13–16)
        if request.requiresTarget {
            let target = trimmed(request.targetIP)
            if target.isEmpty {
                problems.append(.targetRequired)
            } else if !isValidIPv4(target) {
                problems.append(.invalidTarget(target))
            }
        }

        // MAC (20)
        if request.requiresMAC {
            let mac = trimmed(request.macAddress)
            if mac.isEmpty {
                problems.append(.macRequired)
            } else if normalizedMAC(mac) == nil {
                problems.append(.invalidMAC(mac))
            }
        }

        // Wireless room (17)
        if request.requiresWireless {
            if let room = request.wireless {
                let building = trimmed(room.building)
                let floor = trimmed(room.floor)
                let roomName = trimmed(room.room)
                if building.isEmpty || floor.isEmpty || roomName.isEmpty {
                    problems.append(.wirelessRoomRequired)
                }
                let fields = [("Building", building), ("Floor", floor), ("Room", roomName), ("AP label", trimmed(room.accessPointLabel))]
                for (name, value) in fields where !value.isEmpty && textProblem(value) != nil {
                    problems.append(.invalidWirelessField(name))
                }
                let wifi = trimmed(room.wifiInterface)
                if !wifi.isEmpty, !isValidInterfaceName(wifi) {
                    problems.append(.invalidInterfaceName(wifi))
                }
                if let scan = room.scanJSON {
                    if let path = fileSystemPath(scan), textProblem(path) == nil {
                        // fine
                    } else {
                        problems.append(.invalidWirelessField("Wi-Fi scan file"))
                    }
                }
            } else {
                problems.append(.wirelessRoomRequired)
            }
        }

        // UniFi (19): controller, port, SSH user, password — the sheet's order.
        if request.requiresUniFi {
            if let unifi = request.unifi {
                let host = trimmed(unifi.controllerHost)
                if !host.isEmpty, let reason = hostProblem(host) {
                    problems.append(.invalidText(field: "Controller", reason: reason))
                }
                if let port = unifi.controllerPort, !(1...65535).contains(port) {
                    problems.append(.invalidText(field: "Controller port", reason: "must be between 1 and 65535"))
                }
                let user = trimmed(unifi.sshUser)
                if user.isEmpty {
                    problems.append(.sshUserRequired)
                } else if let reason = textProblem(user) {
                    problems.append(.invalidText(field: "SSH user", reason: reason))
                }
                if !unifi.sshPasswordProvided {
                    problems.append(.sshPasswordRequired)
                }
            } else {
                problems.append(.sshUserRequired)
                problems.append(.sshPasswordRequired)
            }
        }

        // Consent — always last (the GUI shows it as a dialog, not inline).
        if request.requiresConsent, !request.stressConsent {
            problems.append(.consentRequired(stressTasks(in: request.selection)))
        }

        return problems
    }

    // MARK: - argv

    /// argv after the executable; throws the first `Problem`.
    ///
    /// Order (contract §2): `--run-task` · `--interface` · `--client --location
    /// [--note]` or `--run-dir` · `[--prepared-by]` · `[--no-pdf]` · `[--yes]` ·
    /// `[--target]` · `[--mac]` · wireless flags · UniFi flags · `[--debug]`.
    /// Task-specific flags are emitted only when the selection contains the
    /// task; every text value is trimmed.
    public static func arguments(for request: RunTaskRequest) throws -> [String] {
        if let first = problems(in: request).first { throw first }
        var argv: [String] = []

        switch request.selection {
        case .fullAudit:
            argv += ["--run-task", "000"]
        case .tasks:
            argv += ["--run-task", request.selection.taskIDs.map { String($0.rawValue) }.joined(separator: ",")]
        }

        argv += ["--interface", trimmed(request.interface)]

        switch request.context {
        case .newRun(let client, let location, let note):
            argv += ["--client", trimmed(client), "--location", trimmed(location)]
            let note = trimmed(note)
            if !note.isEmpty { argv += ["--note", note] }
        case .existingRun(let directory):
            guard let path = fileSystemPath(directory) else { throw Problem.runDirectoryNotAbsolute(directory) }
            argv += ["--run-dir", path]
        }

        let preparedBy = trimmed(request.preparedBy)
        if !preparedBy.isEmpty { argv += ["--prepared-by", preparedBy] }
        if request.skipPDF { argv.append("--no-pdf") }
        if request.stressConsent { argv.append("--yes") }

        if request.requiresTarget {
            argv += ["--target", trimmed(request.targetIP)]
        }

        if request.requiresMAC, let mac = normalizedMAC(trimmed(request.macAddress)) {
            argv += ["--mac", mac]
        }

        if request.requiresWireless, let room = request.wireless {
            let wifi = trimmed(room.wifiInterface)
            if !wifi.isEmpty { argv += ["--wifi-interface", wifi] }
            argv += ["--building", trimmed(room.building), "--floor", trimmed(room.floor), "--room", trimmed(room.room)]
            argv += ["--ap-present", room.accessPointPresent ? "y" : "n"]
            // The interactive flow only asks for a label when an AP is present,
            // so a label without an AP is never sent.
            let label = trimmed(room.accessPointLabel)
            if room.accessPointPresent, !label.isEmpty { argv += ["--ap-label", label] }
            if let scan = room.scanJSON, let path = fileSystemPath(scan) {
                argv += ["--wifi-scan-json", path]
            }
        }

        if request.requiresUniFi, let unifi = request.unifi {
            let host = trimmed(unifi.controllerHost)
            if !host.isEmpty { argv += ["--controller", host] }
            if let port = unifi.controllerPort { argv += ["--controller-port", String(port)] }
            if let https = unifi.https { argv += ["--https", https ? "y" : "n"] }
            argv += ["--ssh-user", trimmed(unifi.sshUser)]
        }

        if request.debug { argv.append("--debug") }
        return argv
    }

    /// `--build-report <dir> [--prepared-by P] [--no-pdf] [--output DIR]`.
    public static func arguments(for request: BuildReportRequest) throws -> [String] {
        guard let runDirectory = fileSystemPath(request.runDirectory) else {
            throw Problem.runDirectoryNotAbsolute(request.runDirectory)
        }
        if let reason = textProblem(runDirectory) {
            throw Problem.invalidText(field: "Run directory", reason: reason)
        }
        var argv = ["--build-report", runDirectory]

        let preparedBy = trimmed(request.preparedBy)
        if !preparedBy.isEmpty {
            if let reason = textProblem(preparedBy) {
                throw Problem.invalidText(field: "Prepared by", reason: reason)
            }
            argv += ["--prepared-by", preparedBy]
        }
        if request.skipPDF { argv.append("--no-pdf") }
        if let output = request.outputDirectory {
            guard let path = fileSystemPath(output) else { throw Problem.runDirectoryNotAbsolute(output) }
            if let reason = textProblem(path) {
                throw Problem.invalidText(field: "Output directory", reason: reason)
            }
            argv += ["--output", path]
        }
        return argv
    }

    /// `("/usr/bin/sudo", ["--preserve-env=A,B", wrapper] + arguments)`; the
    /// preserve flag is omitted when `preserveEnvironment` is empty.
    public static func sudoCommand(wrapper: String, arguments: [String], preserveEnvironment: [String]) -> (executable: String, arguments: [String]) {
        var argv: [String] = []
        if !preserveEnvironment.isEmpty {
            argv.append("--preserve-env=" + preserveEnvironment.joined(separator: ","))
        }
        argv.append(wrapper)
        argv.append(contentsOf: arguments)
        return ("/usr/bin/sudo", argv)
    }

    /// Every flag that takes exactly one value (grammar reused by the M4 request validator).
    public static let valueFlags: Set<String> = [
        "--run-task", "--build-report", "--interface", "--client", "--location", "--note", "--run-dir",
        "--target", "--mac", "--wifi-interface", "--building", "--floor", "--room", "--ap-present",
        "--ap-label", "--wifi-scan-json", "--controller", "--controller-port", "--https", "--ssh-user",
        "--prepared-by", "--output",
    ]

    public static let booleanFlags: Set<String> = ["--yes", "--no-pdf", "--debug"]

    // MARK: - Validators

    /// Exactly four decimal octets 0–255 separated by dots. No sign, no
    /// whitespace, no leading zeros except the single digit "0", ASCII digits only.
    public static func isValidIPv4(_ text: String) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3 else { return false }
            guard octet.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
            if octet.count > 1, octet.first == "0" { return false }
            guard let value = Int(octet), value <= 255 else { return false }
        }
        return true
    }

    /// `"aa:bb:cc:dd:ee:ff"` (lowercase, colon-separated) or nil.
    ///
    /// Accepts six colon- or hyphen-separated groups of one or two hex digits
    /// (`aa:bb:cc:dd:ee:ff`, `AA-BB-CC-DD-EE-FF`, and macOS `arp`'s zero-less
    /// `a:b:c:d:e:f`), three dotted groups of four (`aabb.ccdd.eeff`, Cisco), or
    /// twelve bare hex digits; surrounding whitespace is ignored. Mixed
    /// separators are rejected.
    public static func normalizedMAC(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func isHex(_ group: Substring) -> Bool {
            group.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
        }

        let separators = Set(trimmed.filter { $0 == ":" || $0 == "-" || $0 == "." })
        guard separators.count <= 1 else { return nil }

        var digits = ""
        if let separator = separators.first {
            let groups = trimmed.split(separator: separator, omittingEmptySubsequences: false)
            if separator == "." {
                guard groups.count == 3, groups.allSatisfy({ $0.count == 4 && isHex($0) }) else { return nil }
                digits = groups.joined()
            } else {
                guard groups.count == 6, groups.allSatisfy({ (1...2).contains($0.count) && isHex($0) }) else { return nil }
                digits = groups.map { $0.count == 1 ? "0" + $0 : String($0) }.joined()
            }
        } else {
            guard trimmed.count == 12, isHex(trimmed[...]) else { return nil }
            digits = trimmed
        }

        let lower = Array(digits.lowercased())
        guard lower.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { String(lower[$0...$0 + 1]) }.joined(separator: ":")
    }

    /// `^[a-z][a-z0-9]{1,14}$` — en0, bridge100, utun3, awdl0, eth0, wlp3s0.
    public static func isValidInterfaceName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2, scalars.count <= 15 else { return false }
        guard ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    // MARK: - Helpers

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil when `text` can travel as an argv value; otherwise the reason it
    /// cannot (newline, other control characters, or a leading "-" that the CLI
    /// would read as a flag). Unicode letters are fine.
    static func textProblem(_ text: String) -> String? {
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { return "must be a single line" }
            if scalar.value < 0x20 || scalar.value == 0x7F { return "must not contain control characters" }
        }
        if text.hasPrefix("-") { return "must not start with “-”" }
        return nil
    }

    private static func hostProblem(_ host: String) -> String? {
        if let reason = textProblem(host) { return reason }
        if host.contains(where: \.isWhitespace) { return "must not contain spaces" }
        return nil
    }

    /// The absolute file-system path a file URL denotes (trailing slash
    /// removed), or nil when the URL is not an absolute file path. The path as
    /// given (`relativePath`) is inspected so a relative URL that Foundation
    /// resolved against the current directory is still rejected.
    static func fileSystemPath(_ url: URL) -> String? {
        guard url.isFileURL || url.scheme == nil else { return nil }
        let given = url.relativePath
        guard given.hasPrefix("/") else { return nil }
        var path = url.path(percentEncoded: false)
        if path.isEmpty { path = given }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The stress tests the consent dialog has to name.
    private static func stressTasks(in selection: RunTaskRequest.Selection) -> [TaskID] {
        selection.taskIDs.filter(\.isStressTest)
    }
}
