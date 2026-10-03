import LSSCore
import SwiftUI

/// Task 1 — Interface Network Info: the selected interface's addressing and
/// whether the host is a virtual machine.
struct InterfaceInfoDetailView: View {
    let task: TaskID
    let payload: InterfaceInfoPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Interface", rows: [
                ("Interface", Fmt.text(payload.interface)),
                ("IPv4 address", Fmt.text(payload.ipAddress)),
                ("Subnet mask", Fmt.text(payload.subnet)),
                ("Network range", Fmt.text(payload.network)),
                ("Default gateway", Fmt.text(payload.gateway)),
                ("MAC address", Fmt.text(payload.macAddress)),
            ])
            KeyValueGroup("Virtualisation", rows: [
                ("Virtual machine", Fmt.yesNo(payload.isVm)),
                ("Platform", Fmt.text(payload.vmPlatform)),
            ])
        }
    }
}
