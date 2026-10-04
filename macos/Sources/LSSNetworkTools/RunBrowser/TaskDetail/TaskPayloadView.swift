import SwiftUI
import LSSCore

/// Dispatches a decoded payload to its task-specific view. Falls back to a
/// short note (the container still offers the raw JSON) for anything unmatched.
struct TaskPayloadView: View {
    let task: TaskID
    let payload: any TaskPayload

    var body: some View {
        switch payload {
        case let p as InterfaceInfoPayload: InterfaceInfoDetailView(task: task, payload: p)
        case let p as SpeedTestPayload: SpeedTestDetailView(task: task, payload: p)
        case let p as GatewayScanPayload: GatewayScanDetailView(task: task, payload: p)
        case let p as DHCPScanPayload: DHCPScanDetailView(task: task, payload: p)
        case let p as DHCPResponseTimePayload: DHCPResponseTimeDetailView(task: task, payload: p)
        case let p as ServiceScanPayload: ServiceScanDetailView(task: task, payload: p)
        case let p as StressTestPayload: StressTestDetailView(task: task, payload: p)
        case let p as VLANTrunkPayload: VLANTrunkDetailView(task: task, payload: p)
        case let p as DuplicateIPPayload: DuplicateIPDetailView(task: task, payload: p)
        case let p as CustomPortScanPayload: CustomPortScanDetailView(task: task, payload: p)
        case let p as IdentityScanPayload: IdentityScanDetailView(task: task, payload: p)
        case let p as DNSAssessmentPayload: DNSAssessmentDetailView(task: task, payload: p)
        case let p as WirelessSurveyPayload: WirelessSurveyDetailView(task: task, payload: p)
        case let p as UniFiDiscoveryPayload: UniFiDiscoveryDetailView(task: task, payload: p)
        case let p as UniFiAdoptionPayload: UniFiAdoptionDetailView(task: task, payload: p)
        case let p as FindByMACPayload: FindByMACDetailView(task: task, payload: p)
        default:
            Text("No typed view for Task \(task.rawValue); use Raw JSON.")
                .foregroundStyle(.secondary)
        }
    }
}
