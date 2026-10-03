import SwiftUI
import LSSCore

/// Task 16 — resolver behaviour: UDP/TCP/PTR query results, recursion and version.bind.
struct DNSAssessmentDetailView: View {
    let task: TaskID
    let payload: DNSAssessmentPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyValueGroup("Target", rows: [
                ("Target IP", Fmt.text(payload.targetIp)),
                ("Hostname", Fmt.text(payload.hostname)),
                ("Query tool", Fmt.text(payload.queryTool)),
            ])

            if hasAssessment {
                HStack(spacing: 20) {
                    FlagBadge(label: "DNS service working", value: payload.dnsServiceWorking)
                    FlagBadge(label: "Recursion available", value: payload.recursionAvailable)
                }

                queryGroup("UDP query", probe: "example.com A", query: payload.udpQuery)
                queryGroup("TCP query", probe: "example.com A +tcp", query: payload.tcpQuery)
                queryGroup("Reverse PTR query", probe: "-x 8.8.8.8", query: payload.reversePtrQuery)

                KeyValueGroup("Software", rows: [
                    ("version.bind", Fmt.text(payload.versionBindResponse) ?? "not disclosed"),
                    ("Software hint", Fmt.text(payload.softwareHint)),
                    ("Upstream inference", Fmt.text(payload.upstreamDestinationInference) ?? "unknown from the client side"),
                    ("Note", Fmt.text(payload.upstreamVisibilityNote)),
                ])
            } else {
                SpecialistEmptyNote("The assessment did not run; only the target is recorded.")
            }
        }
    }

    /// The `dns_query_tool_missing` failure file carries only `target_ip` and `hostname`.
    private var hasAssessment: Bool {
        payload.queryTool != nil || payload.udpQuery != nil || payload.dnsServiceWorking != nil
    }

    private func queryGroup(_ title: String, probe: String, query: DNSAssessmentPayload.Query?) -> some View {
        KeyValueGroup("\(title) — \(probe)", rows: [
            ("Status", Fmt.text(query?.status)),
            ("Answers", Fmt.list(query?.answers) ?? (query == nil ? nil : "none")),
        ])
    }
}
