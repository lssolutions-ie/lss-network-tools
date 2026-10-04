import Foundation
import LSSCore

/// Editable state behind the New Run / Continue Run sheet. Turned into a
/// `RunTaskRequest` on every change so `ArgumentBuilder.problems` can be shown
/// inline; the SSH password stays here and is handed to
/// `RunCoordinator.start(_:sshPassword:)` only.
struct RunDraft: Equatable {
    enum SelectionMode: String, CaseIterable, Identifiable {
        case fullAudit = "Full audit (1–12)"
        case selected = "Selected tasks"
        var id: String { rawValue }
    }

    /// One inline problem of the sheet.
    enum Problem: Hashable, CustomStringConvertible {
        /// From `ArgumentBuilder.problems` (the CLI's own rules).
        case argument(ArgumentBuilder.Problem)
        /// A rule only the sheet checks: the port text, the helper route's
        /// Task 17 requirement, interface presence, the run directory.
        case sheet(String)

        var description: String {
            switch self {
            case .argument(let problem): problem.description
            case .sheet(let text): text
            }
        }
    }

    /// nil → a new run directory (`--client/--location`); otherwise `--run-dir`.
    var existingRun: RunSummary?
    var interface = ""
    /// The run's manifest interface when it is not present on this Mac now
    /// (`AppModel.makeDraft` then preselects the toolbar interface instead and
    /// the sheet says so).
    var interfaceMissingFromRun: String?
    var client = ""
    var location = ""
    var note = ""
    var preparedBy = ""
    var selectionMode: SelectionMode = .fullAudit
    var selectedTasks: Set<TaskID> = []

    // Tasks 13–16
    var targetIP = ""
    // Task 20
    var macAddress = ""
    // Task 17
    var building = ""
    var floor = ""
    var room = ""
    var accessPointPresent = false
    var accessPointLabel = ""
    /// CoreWLAN scan of the room made in the sheet (`--wifi-scan-json`). Kept
    /// when building/floor/room change afterwards: the room is only metadata.
    var wifiScan: WiFiScanResult?
    // Task 19
    var controllerHost = ""
    /// The port field as typed. Only a value that is an integer in 1…65535
    /// reaches the request (`controllerPort`); anything else non-empty is a
    /// problem — never silently dropped in favour of the Program Default.
    var controllerPortText = ""
    /// nil → the CLI's Program Defaults decide.
    var useHTTPS: Bool?
    var sshUser = ""
    var sshPassword = ""

    var skipPDF = false

    var isContinuing: Bool { existingRun != nil }

    var selection: RunTaskRequest.Selection {
        switch selectionMode {
        case .fullAudit: .fullAudit
        case .selected: .tasks(selectedTasks.sorted())
        }
    }

    /// The tasks that will run, ascending.
    var taskIDs: [TaskID] { selection.taskIDs }

    var context: RunTaskRequest.Context {
        if let existingRun {
            return .existingRun(directory: existingRun.directory)
        }
        return .newRun(client: client.trimmed, location: location.trimmed, note: note.trimmed)
    }

    /// `controllerPortText` as a port, when it is one (1–5 ASCII digits, 1…65535).
    var controllerPort: Int? { Self.parsePort(controllerPortText) }

    /// Non-empty port text that is not a valid port.
    var controllerPortInvalid: Bool { !controllerPortText.trimmed.isEmpty && controllerPort == nil }

    static func parsePort(_ text: String) -> Int? {
        let digits = text.trimmed
        guard (1...5).contains(digits.unicodeScalars.count),
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let port = Int(digits), (1...65535).contains(port) else { return nil }
        return port
    }

    /// The request as the sheet currently describes it (`stressConsent` is
    /// always false here; the consent dialog sets it on the copy it starts).
    var request: RunTaskRequest {
        var request = RunTaskRequest(
            selection: selection,
            context: context,
            interface: interface.isEmpty ? nil : interface,
            preparedBy: preparedBy.trimmed.isEmpty ? nil : preparedBy.trimmed,
            skipPDF: skipPDF
        )
        if request.requiresTarget {
            request.targetIP = targetIP.trimmed.isEmpty ? nil : targetIP.trimmed
        }
        if request.requiresMAC {
            request.macAddress = macAddress.trimmed.isEmpty ? nil : macAddress.trimmed
        }
        if request.requiresWireless {
            // With a scan attached, the engine records the interface CoreWLAN
            // actually scanned (`--wifi-interface`); without one it picks the
            // run's interface when wireless, else the first Wi-Fi interface.
            let scannedInterface = wifiScan.map(\.summary.interfaceName).flatMap {
                ArgumentBuilder.isValidInterfaceName($0) ? $0 : nil
            }
            request.wireless = RunTaskRequest.WirelessRoom(
                building: building.trimmed,
                floor: floor.trimmed,
                room: room.trimmed,
                accessPointPresent: accessPointPresent,
                accessPointLabel: accessPointPresent && !accessPointLabel.trimmed.isEmpty ? accessPointLabel.trimmed : nil,
                wifiInterface: scannedInterface,
                scanJSON: wifiScan?.url
            )
        }
        if request.requiresUniFi {
            request.unifi = RunTaskRequest.UniFiAdoption(
                controllerHost: controllerHost.trimmed.isEmpty ? nil : controllerHost.trimmed,
                controllerPort: controllerPort,
                https: useHTTPS,
                sshUser: sshUser.trimmed,
                sshPasswordProvided: !sshPassword.isEmpty
            )
        }
        return request
    }

    /// Inline validation: `ArgumentBuilder.problems` (consent excluded — the
    /// dialog handles it) plus the draft's own rules. Rules that need the app
    /// model (helper route, interface presence, run directory) are added by
    /// the sheet.
    var problems: [Problem] {
        var problems: [Problem] = ArgumentBuilder.problems(in: request).compactMap {
            if case .consentRequired = $0 { return nil }
            return .argument($0)
        }
        if request.requiresUniFi, controllerPortInvalid {
            let port = Problem.sheet("Controller port: must be a number between 1 and 65535")
            // Keep the form's order: the port follows the controller host and
            // precedes the SSH fields.
            if let sshIndex = problems.firstIndex(where: Self.isSSHProblem) {
                problems.insert(port, at: sshIndex)
            } else {
                problems.append(port)
            }
        }
        return problems
    }

    private static func isSSHProblem(_ problem: Problem) -> Bool {
        switch problem {
        case .argument(.sshUserRequired), .argument(.sshPasswordRequired): true
        case .argument(.invalidText(let field, _)): field == "SSH user"
        default: false
        }
    }

    var canStart: Bool { !taskIDs.isEmpty && problems.isEmpty }

    /// The password to hand to the coordinator, only when Task 19 is selected.
    var sshPasswordForStart: String? {
        request.requiresUniFi && !sshPassword.isEmpty ? sshPassword : nil
    }

    /// Tasks of the selection that use the target IP panel.
    var targetTasks: [TaskID] { taskIDs.filter(\.needsTargetIP) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// What `AppModel` hands to the sheet: the prefilled draft, and for automation
/// whether the consent dialog should open straight away.
struct NewRunSheetRequest: Identifiable {
    let id = UUID()
    var draft: RunDraft
    var presentConsentImmediately = false
}
