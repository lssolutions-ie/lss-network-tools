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

    /// nil → a new run directory (`--client/--location`); otherwise `--run-dir`.
    var existingRun: RunSummary?
    var interface = ""
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
    // Task 19
    var controllerHost = ""
    var controllerPort = ""
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
            request.wireless = RunTaskRequest.WirelessRoom(
                building: building.trimmed,
                floor: floor.trimmed,
                room: room.trimmed,
                accessPointPresent: accessPointPresent,
                accessPointLabel: accessPointPresent && !accessPointLabel.trimmed.isEmpty ? accessPointLabel.trimmed : nil
            )
        }
        if request.requiresUniFi {
            request.unifi = RunTaskRequest.UniFiAdoption(
                controllerHost: controllerHost.trimmed.isEmpty ? nil : controllerHost.trimmed,
                controllerPort: Int(controllerPort.trimmed),
                https: useHTTPS,
                sshUser: sshUser.trimmed,
                sshPasswordProvided: !sshPassword.isEmpty
            )
        }
        return request
    }

    /// Inline validation. Consent is handled by the dialog, not the form.
    var problems: [ArgumentBuilder.Problem] {
        ArgumentBuilder.problems(in: request).filter {
            if case .consentRequired = $0 { return false }
            return true
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
