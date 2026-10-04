import Foundation

/// Turns a `RunTaskRequest` / `BuildReportRequest` / `DeleteRunRequest` into the argv
/// the CLI accepts (contract §2; flag grammar PLAN §7.1). Values are always separate argv
/// elements, never `--flag=value`; text never starts with `-`.
///
/// The value rules here are the GUI's pre-flight: they mirror the engine's
/// `noninteractive_validate` / `unifi_adoption` checks and the helper's
/// `RequestValidator`, so the New Run sheet reports a problem inline instead of
/// the run failing with a usage error later.
public enum ArgumentBuilder {
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case noTasksSelected
        case interfaceRequired
        case invalidInterfaceName(String)
        case clientRequired
        case locationRequired
        /// Control / invisible characters, newlines, a leading "-", too long, or
        /// a field-specific rule (controller host, SSH user, path components).
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

    /// Free-text values (client, location, note, prepared-by, room fields,
    /// controller, SSH user): at most this many Unicode scalars. Shared with
    /// `RequestValidator.maximumTextLength`.
    public static let maximumTextLength = 120

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
            } else if let reason = freeTextProblem(client) {
                problems.append(.invalidText(field: "Client", reason: reason))
            }
            let location = trimmed(location)
            if location.isEmpty {
                problems.append(.locationRequired)
            } else if let reason = freeTextProblem(location) {
                problems.append(.invalidText(field: "Location", reason: reason))
            }
            let note = trimmed(note)
            if !note.isEmpty, let reason = freeTextProblem(note) {
                problems.append(.invalidText(field: "Note", reason: reason))
            }
        case .existingRun(let directory):
            if let path = fileSystemPath(directory) {
                if let reason = pathProblem(path) {
                    problems.append(.invalidText(field: "Run directory", reason: reason))
                }
            } else {
                problems.append(.runDirectoryNotAbsolute(directory))
            }
        }
        let preparedBy = trimmed(request.preparedBy)
        if !preparedBy.isEmpty, let reason = freeTextProblem(preparedBy) {
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
                for (name, value) in fields where !value.isEmpty && freeTextProblem(value) != nil {
                    problems.append(.invalidWirelessField(name))
                }
                let wifi = trimmed(room.wifiInterface)
                if !wifi.isEmpty, !isValidInterfaceName(wifi) {
                    problems.append(.invalidInterfaceName(wifi))
                }
                if let scan = room.scanJSON {
                    if let path = fileSystemPath(scan), pathProblem(path) == nil {
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
                let endpoint = controllerEndpoint(host: unifi.controllerHost, port: unifi.controllerPort)
                if let problem = endpoint.problem {
                    problems.append(problem)
                }
                if let port = unifi.controllerPort, !(1...65535).contains(port) {
                    problems.append(.invalidText(field: "Controller port", reason: "must be between 1 and 65535"))
                }
                let user = trimmed(unifi.sshUser)
                if user.isEmpty {
                    problems.append(.sshUserRequired)
                } else if let reason = sshUserProblem(user) {
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
    /// task; every text value is trimmed. The controller host travels in its
    /// normalised form (no scheme, path or port; see `controllerEndpoint`).
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
            let endpoint = controllerEndpoint(host: unifi.controllerHost, port: unifi.controllerPort)
            if !endpoint.host.isEmpty { argv += ["--controller", endpoint.host] }
            if let port = endpoint.port { argv += ["--controller-port", String(port)] }
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
        if let reason = pathProblem(runDirectory) {
            throw Problem.invalidText(field: "Run directory", reason: reason)
        }
        var argv = ["--build-report", runDirectory]

        let preparedBy = trimmed(request.preparedBy)
        if !preparedBy.isEmpty {
            if let reason = freeTextProblem(preparedBy) {
                throw Problem.invalidText(field: "Prepared by", reason: reason)
            }
            argv += ["--prepared-by", preparedBy]
        }
        if request.skipPDF { argv.append("--no-pdf") }
        if let output = request.outputDirectory {
            guard let path = fileSystemPath(output) else { throw Problem.runDirectoryNotAbsolute(output) }
            if let reason = pathProblem(path) {
                throw Problem.invalidText(field: "Output directory", reason: reason)
            }
            argv += ["--output", path]
        }
        return argv
    }

    /// `--delete-run <dir>` — the same path rules as `--build-report`; the engine
    /// accepts no other flag with it, so none is rendered.
    public static func arguments(for request: DeleteRunRequest) throws -> [String] {
        guard let runDirectory = fileSystemPath(request.runDirectory) else {
            throw Problem.runDirectoryNotAbsolute(request.runDirectory)
        }
        if let reason = pathProblem(runDirectory) {
            throw Problem.invalidText(field: "Run directory", reason: reason)
        }
        return ["--delete-run", runDirectory]
    }

    /// `("/usr/bin/sudo", ["--preserve-env=A,B", wrapper] + arguments)`; the
    /// preserve flag is omitted when no valid name remains. Names must look like
    /// environment variables (`^[A-Z_][A-Z0-9_]*$`); anything else — spaces,
    /// commas, `=`, lower case — is dropped rather than joined into sudo's list.
    public static func sudoCommand(wrapper: String, arguments: [String], preserveEnvironment: [String]) -> (executable: String, arguments: [String]) {
        var argv: [String] = []
        let names = preserveEnvironment.filter(isValidEnvironmentName)
        if !names.isEmpty {
            argv.append("--preserve-env=" + names.joined(separator: ","))
        }
        argv.append(wrapper)
        argv.append(contentsOf: arguments)
        return ("/usr/bin/sudo", argv)
    }

    /// Every flag that takes exactly one value (grammar reused by the M4 request validator).
    public static let valueFlags: Set<String> = [
        "--run-task", "--build-report", "--delete-run", "--interface", "--client", "--location", "--note", "--run-dir",
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

    /// `^[A-Za-z][A-Za-z0-9._-]{0,14}$` — en0, bridge100, utun3, awdl0 and Linux
    /// names such as enp3s0, wlp2s0, eth0.100 or br-1234abcd (IFNAMSIZ − 1 = 15).
    /// Only the shape is checked here; the engine verifies the interface exists
    /// against `list_interfaces`. Names with spaces, `/`, a leading digit or `-`,
    /// or non-ASCII letters are refused.
    public static func isValidInterfaceName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 1, scalars.count <= 15 else { return false }
        guard isASCIILetter(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]*$` — the engine's `--ssh-user` rule (an ssh
    /// option such as `-oProxyCommand=…` can therefore never be smuggled in).
    public static func isValidSSHUser(_ user: String) -> Bool {
        let scalars = Array(user.unicodeScalars)
        guard let first = scalars.first, isASCIILetter(first) || ("0"..."9").contains(first) else { return false }
        return scalars.dropFirst().allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `^[A-Z_][A-Z0-9_]*$` — a name sudo's `--preserve-env=` list may carry.
    public static func isValidEnvironmentName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, ("A"..."Z").contains(first) || first == "_" else { return false }
        return scalars.dropFirst().allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Mirrors `unifi_adoption`: whitespace trimmed, a leading `http://` /
    /// `https://` (any case) removed, and everything from the first `/` dropped.
    /// The result may still carry a `:port` suffix, which `controllerEndpoint`
    /// moves into the port field; argv only ever carries the bare host.
    public static func normalizedControllerHost(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where host.lowercased().hasPrefix(scheme) {
            host.removeFirst(scheme.count)
            break
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        return host
    }

    /// The `--controller` / `--controller-port` values for Task 19, or the problem
    /// that stops them: the host is normalised, a `:port` suffix fills an empty
    /// port field (and must agree with a filled one — it is never dropped
    /// silently), and what remains must match the engine's `^[A-Za-z0-9.-]+$`.
    /// An empty host means "let the engine use its Program Default".
    static func controllerEndpoint(host rawHost: String?, port requestedPort: Int?) -> (host: String, port: Int?, problem: Problem?) {
        let field = "Controller"
        let raw = trimmed(rawHost)
        if raw.isEmpty { return ("", requestedPort, nil) }
        var host = normalizedControllerHost(raw)
        var port = requestedPort
        if let reason = freeTextProblem(host) {
            return (host, port, .invalidText(field: field, reason: reason))
        }
        if let colon = host.firstIndex(of: ":") {
            let suffix = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
            guard let suffixPort = parsePort(suffix) else {
                return (host, port, .invalidText(field: field, reason: "must not contain “:” unless it is followed by a port between 1 and 65535"))
            }
            if let requestedPort, requestedPort != suffixPort {
                return (host, port, .invalidText(field: field, reason: "names port \(suffixPort), but the port field says \(requestedPort)"))
            }
            port = suffixPort
        }
        if let reason = hostProblem(host) {
            return (host, port, .invalidText(field: field, reason: reason))
        }
        return (host, port, nil)
    }

    // MARK: - Helpers

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }

    /// 1–5 ASCII digits in 1…65535.
    private static func parsePort(_ text: String) -> Int? {
        let scalars = text.unicodeScalars
        guard (1...5).contains(scalars.count), scalars.allSatisfy({ ("0"..."9").contains($0) }),
              let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }

    /// C1 controls and the Unicode format / bidirectional characters that are
    /// invisible in a text field yet change how a report reads: U+0080–U+009F,
    /// U+200B–U+200F, U+2028–U+202E, U+2066–U+2069 and U+FEFF. Shared with
    /// `RequestValidator.isValidFreeText`.
    static func isInvisibleOrBidi(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x80...0x9F, 0x200B...0x200F, 0x2028...0x202E, 0x2066...0x2069, 0xFEFF: true
        default: false
        }
    }

    /// nil when `text` can travel as an argv value; otherwise the reason it
    /// cannot (newline, other control characters, invisible / bidirectional
    /// format characters, or a leading "-" that the CLI would read as a flag).
    /// Unicode letters are fine.
    static func textProblem(_ text: String) -> String? {
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { return "must be a single line" }
            if scalar.value < 0x20 || scalar.value == 0x7F { return "must not contain control characters" }
            if isInvisibleOrBidi(scalar) { return "contains invisible or bidirectional control characters" }
        }
        if text.hasPrefix("-") { return "must not start with “-”" }
        return nil
    }

    /// `textProblem` plus the helper's length limit (`maximumTextLength` scalars).
    static func freeTextProblem(_ text: String) -> String? {
        if let reason = textProblem(text) { return reason }
        if text.unicodeScalars.count > maximumTextLength { return "must be at most \(maximumTextLength) characters" }
        return nil
    }

    /// An absolute path the engine and helper will take: no control / invisible
    /// characters and no `.` or `..` component (including a trailing `/..`).
    static func pathProblem(_ path: String) -> String? {
        if let reason = textProblem(path) { return reason }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == "." || $0 == ".." }) { return "must not contain “.” or “..” path components" }
        return nil
    }

    /// `textProblem` + `freeTextProblem` + the SSH user name shape.
    private static func sshUserProblem(_ user: String) -> String? {
        if let reason = freeTextProblem(user) { return reason }
        if !isValidSSHUser(user) { return "must start with a letter or digit and contain only letters, digits, “.”, “_” or “-”" }
        return nil
    }

    /// The bare host part of a controller address (after `controllerEndpoint`
    /// has removed scheme, path and port).
    private static func hostProblem(_ host: String) -> String? {
        if host.isEmpty { return "must be a host name or IP address" }
        if let reason = textProblem(host) { return reason }
        if host.contains(where: \.isWhitespace) { return "must not contain spaces" }
        if host.contains("/") { return "must not contain “/”" }
        let allowed = host.unicodeScalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
        if !allowed { return "may only contain letters, digits, “.” and “-”" }
        return nil
    }

    /// The absolute file-system path a file URL denotes (trailing slash
    /// removed), or nil when the URL is not an absolute file path. The path as
    /// given (`relativePath`) is inspected so a relative URL that Foundation
    /// resolved against the current directory is still rejected. `.` / `..`
    /// components are kept, not resolved — `pathProblem` refuses them.
    static func fileSystemPath(_ url: URL) -> String? {
        guard url.isFileURL || url.scheme == nil else { return nil }
        let given = url.relativePath
        guard given.hasPrefix("/") else { return nil }
        var path = url.path(percentEncoded: false)
        if path.isEmpty { path = given }
        // Foundation may hand back a standardised path; keep the spelling the
        // caller gave when it contains dot components so they can be refused.
        if given.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) { path = given }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The stress tests the consent dialog has to name.
    private static func stressTasks(in selection: RunTaskRequest.Selection) -> [TaskID] {
        selection.taskIDs.filter(\.isStressTest)
    }
}
