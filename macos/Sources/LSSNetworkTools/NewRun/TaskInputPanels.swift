import SwiftUI
import LSSCore

// Task-specific input panels of the New Run sheet. Each appears only while
// the selection contains the task that needs it (RunTaskRequest.requires*).

/// Tasks 13–16: one target IPv4 address shared by every custom-target task.
struct TargetPanel: View {
    @Binding var draft: RunDraft

    var body: some View {
        TextField("Target IPv4", text: $draft.targetIP, prompt: Text("e.g. 192.168.1.10"))
            .autocorrectionDisabled()
        Text("Used by \(taskList). Only an IPv4 address is accepted — not a host name.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var taskList: String {
        let tasks = draft.targetTasks
        if tasks.count == 1 { return "Task \(tasks[0].rawValue) (\(tasks[0].title))" }
        return "Tasks " + tasks.map { String($0.rawValue) }.joined(separator: ", ")
    }
}

/// Task 20: the MAC address to look for.
struct MACPanel: View {
    @Binding var draft: RunDraft

    var body: some View {
        TextField("MAC address", text: $draft.macAddress, prompt: Text("e.g. aa:bb:cc:dd:ee:ff"))
            .autocorrectionDisabled()
        Text("Task 20 finds the IP currently using this MAC on the subnet. Colons, hyphens, Cisco dots or 12 bare hex digits are all accepted.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Task 17: one room per invocation (PLAN §7.6); a continued run appends the
/// room to `wireless-survey.json`.
struct WirelessRoomPanel: View {
    @Binding var draft: RunDraft

    var body: some View {
        TextField("Building", text: $draft.building, prompt: Text("e.g. Main building"))
        TextField("Floor", text: $draft.floor, prompt: Text("e.g. 2"))
        TextField("Room", text: $draft.room, prompt: Text("e.g. Room 2.14"))
        Toggle("Access point physically present in this room", isOn: $draft.accessPointPresent)
        if draft.accessPointPresent {
            TextField("Access point label", text: $draft.accessPointLabel, prompt: Text("Optional — e.g. AP-2F-East"))
        }
        Text(draft.isContinuing
             ? "One room per run. This room is appended to the survey already in the run directory."
             : "One room per run. To survey the next room, continue this run from Previous Runs and enter the next room.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Task 19: controller + SSH credentials. The password is only ever passed to
/// `RunCoordinator.start(_:sshPassword:)`, which puts it in the child's
/// environment; it is never written to disk or into argv.
struct UniFiAdoptionPanel: View {
    @Binding var draft: RunDraft

    var body: some View {
        TextField("Controller host", text: $draft.controllerHost, prompt: Text("Program default"))
            .autocorrectionDisabled()
        TextField("Controller port", text: $draft.controllerPort, prompt: Text("Program default"))
        Picker("HTTPS", selection: $draft.useHTTPS) {
            Text("Program default").tag(Bool?.none)
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
        }
        .pickerStyle(.segmented)
        TextField("SSH user", text: $draft.sshUser, prompt: Text("e.g. ubnt"))
            .autocorrectionDisabled()
        SecureField("SSH password", text: $draft.sshPassword, prompt: Text("Required"))
        Text("Adopts the devices found by Task 18 in this run (confirmed UniFi devices only). The password is handed to the tool through its environment and is never stored.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
