# M2 contract: task payload models, detail views, fixtures

This is the agreement between the pieces of the run browser so they can be written in parallel. Everything here lives under `macos/`.

## Decoding core (already written — do not modify)

- `Sources/LSSCore/Models/TaskEnvelope.swift` — `TaskStatus` (open enum), `TaskError`, `TaskEnvelope` (status/success/error/warnings/skip fields, tolerant of missing keys), `protocol TaskPayload: Decodable, Sendable { static var taskIDs: [TaskID] { get } }`, `TaskResult<Payload>` (envelope + payload decoded from the same object).
- `Sources/LSSCore/Decoding/Lenient.swift` — property wrappers `@Lenient` (`Double?` from number/string/null), `@LenientArray` (`[Double?]?`), `@LenientInt` (`Int?`), `@LenientString` (`String?` from string/number). Missing keys decode as nil.
- `Sources/LSSCore/Decoding/JSONValue.swift` — generic JSON tree + `prettyPrinted()`.
- `Sources/LSSCore/Decoding/LSSJSON.swift` — `LSSJSON.decoder()` (**`.convertFromSnakeCase`** — so `rssi_dbm` → `rssiDbm`, `smb_signing_required` → `smbSigningRequired`), `parseLocalDate`, `parseISO8601`, `describe(error)`, `Sentinel.value(_:)`, `NaturalSort.deviceIndex(of:)`.
- `Sources/LSSCore/Models/Manifest.swift` — `Manifest`, `Finding`, `FindingSeverity`, `FindingsFile`, `RemediationFile`.
- `Sources/LSSNetworkTools/RunBrowser/Components/DetailComponents.swift` — `KeyValueGroup(title, rows: [(label, value: String?)])`, `SectionCard(title, subtitle) { }`, `StatusBadge`, `FlagBadge(label:value:highlightTrue:)`, `EnvelopeHeader(envelope:)`, `Fmt.ms/mbps/percent/int/number/yesNo/list/ports/text`, `RawJSONView(json:)`.

## Payload model rules

- One `public struct <Name>Payload: TaskPayload` per task (6–9 share `ServiceScanPayload`; 10 and 14 share `StressTestPayload`). **Exact type names** (the registry and view dispatcher use them):

  | Task | Type | File |
  |---|---|---|
  | 1 | `InterfaceInfoPayload` | `Sources/LSSCore/Models/Tasks/CoreAuditPayloads.swift` |
  | 2 | `SpeedTestPayload` | same |
  | 3 | `GatewayScanPayload` | same |
  | 4 | `DHCPScanPayload` | same |
  | 5 | `DHCPResponseTimePayload` | same |
  | 6–9 | `ServiceScanPayload` | same |
  | 10, 14 | `StressTestPayload` | same |
  | 11 | `VLANTrunkPayload` | same |
  | 12 | `DuplicateIPPayload` | same |
  | 13 | `CustomPortScanPayload` | `Sources/LSSCore/Models/Tasks/SpecialistPayloads.swift` |
  | 15 | `IdentityScanPayload` | same |
  | 16 | `DNSAssessmentPayload` | same |
  | 17 | `WirelessSurveyPayload` | same |
  | 18 | `UniFiDiscoveryPayload` | same |
  | 19 | `UniFiAdoptionPayload` | same |
  | 20 | `FindByMACPayload` | same |

- Payloads contain **only task-specific fields**; the envelope fields (`status`, `success`, `error`, `warnings`, `skip_*`) are handled by `TaskEnvelope`. Do not redeclare them.
- Every property is optional. Use synthesized `Decodable` with the snake_case strategy (no manual CodingKeys unless a key cannot be converted). Numbers that research 03 marks as metrics use `@Lenient` (`Double?`); counts use `@LenientInt`; string-or-number fields (wireless `channel`, identity `services[].port`) use `@LenientString` or plain `String?` when the writer always emits a string; booleans are plain `Bool?`; arrays of numbers that may contain null (`response_times_ms`) use `@LenientArray`.
- Nested objects are nested `public struct`s inside the payload (`DHCPScanPayload.Server`, `StressTestPayload.Stage`, …), all `Decodable, Sendable, Hashable`, with `Identifiable` where a table needs it (use a stable `id` such as the IP, or `UUID()` is **not** allowed — prefer index-based `enumerated()` in the view instead).
- Stress test: declare both `gateway: String?` and `targetIp: String?` and expose `public var target: String? { gateway ?? targetIp }`; `stageStatus` values are `String?` (open: `ok`/`failed`/`partial`).
- Task 2: keep `servers: [Server]?` and add `public var server: Server? { servers?.first }`.
- Task 17: `WirelessSurveyPayload.Network` has everything optional except nothing — even `ssid` may be absent in theory; provide `displaySSID` that maps `(hidden)`/nil to "Hidden network".
- Task 18: `devices[].confidence: String?`; `public var isProbable: Bool { confidence == "probable" }`.
- Provide `public static let taskIDs: [TaskID]` on each payload (e.g. `ServiceScanPayload.taskIDs = [.dnsScan, .ldapScan, .smbNfsScan, .printServerScan]`).
- Every payload file ends with a `decode` helper used by the registry:
  - `CoreAuditPayloads.swift`: `public func decodeCoreAuditPayload(task: TaskID, data: Data) throws -> (TaskEnvelope, any TaskPayload)?` returning nil for tasks it does not own.
  - `SpecialistPayloads.swift`: `public func decodeSpecialistPayload(task: TaskID, data: Data) throws -> (TaskEnvelope, any TaskPayload)?`.
  Implementation pattern: `let r = try LSSJSON.decode(TaskResult<InterfaceInfoPayload>.self, from: data); return (r.envelope, r.payload)`.

## Detail view rules

- One view per payload in `Sources/LSSNetworkTools/RunBrowser/TaskDetail/` named after the payload without the suffix: `InterfaceInfoDetailView`, `SpeedTestDetailView`, `GatewayScanDetailView`, `DHCPScanDetailView`, `DHCPResponseTimeDetailView`, `ServiceScanDetailView`, `StressTestDetailView`, `VLANTrunkDetailView`, `DuplicateIPDetailView`, `CustomPortScanDetailView`, `IdentityScanDetailView`, `DNSAssessmentDetailView`, `WirelessSurveyDetailView`, `UniFiDiscoveryDetailView`, `UniFiAdoptionDetailView`, `FindByMACDetailView`.
- Signature: `struct XDetailView: View { let task: TaskID; let payload: XPayload; var body: some View { … } }` — the envelope header and the raw-JSON tab are rendered by the container, not by these views.
- Content per research/PLAN §5.1: `Table` for host/port/device lists (sortable where it helps), Swift Charts (`import Charts`) for Task 5 probe times, Task 10/14 ramping latency/loss and stage summary, Task 17 RSSI per room; `KeyValueGroup` for scalar groups; `FlagBadge` for indicators. Show sentinels as a dash via `Fmt.text`.
- Views must be pure functions of the payload: no file access, no model objects, no `@Environment(AppModel.self)`.
- Keep each view compact; empty collections show a short "none found" `Text`, never an empty table.

## Dispatch (written by the integrator after the models land)

- `Sources/LSSCore/Decoding/TaskPayloadRegistry.swift` calls `decodeCoreAuditPayload` then `decodeSpecialistPayload`.
- `Sources/LSSNetworkTools/RunBrowser/TaskDetail/TaskPayloadView.swift` switches on `payload as? XPayload` to the view above.

## Fixtures and tests

- Real anonymised runs: `Tests/Fixtures/runs/<run-dir>/…` (never a path component called `output`, which `.gitignore` excludes).
- Synthetic files for tasks 13–20 and failure/skipped shapes: `Tests/Fixtures/synthetic/task-NN-<case>.json` with a `README.md` explaining each one and the writer line in the script it mirrors.
- Tests live in `Tests/LSSCoreTests/`. Locate fixtures relative to `#filePath` (see `TaskIDTests.swift`). Every `*.json` under `Fixtures` must decode through the registry without throwing (`FixtureDecodingTests`), and each payload gets a focused test asserting a few real values from a fixture.
- `Tests/Fixtures/synthetic-v252/<run-dir>/` is a fictional run carrying every v1.2.252 field below (plus one `edited_at` file and one file whose manifest checksum is wrong); do not add core-task files (`task-04-*.json` etc.) to `synthetic/` — `SpecialistPayloadTests` decodes that directory through `decodeSpecialistPayload`, which returns nil for Tasks 1–12.

## v1.2.252 additions (engine release with GUI 1.0.6)

Every field here is optional; a pre-v1.2.252 file must keep decoding and rendering unchanged. Keys are listed as the engine writes them (snake_case); the Swift property is the camelCase conversion.

- **Envelope / manifest (all tasks).** `TaskEnvelope.editedAt: String?` (`edited_at`, ISO-8601 UTC stamped by Manage Results → Edit Results; `editedDate`, `wasEdited`). `Manifest.TaskEntry.sha256: String?` and `writtenAt: String?` (`expectedSHA256(for:)` returns the checksum only for the task's single result file — `json_file` or a one-element `json_files` — never across a multi-entry task's device files; `Manifest.entry(for:)`). `RunLoader` computes `TaskFile.integrity: TaskFileIntegrity` (`.edited(at:)` from the stamp, else `.verified` / `.modifiedSinceRun` from the checksum, else `.unverified`); `RunDetail.editedTasks`. Views: `EditedBadge` next to the status pill in `EnvelopeHeader(envelope:integrity:)`, a pencil in `TaskCell`, and "Edited after the run: Task N" in `RunHeader(editedTasks:)`.
- **Task 4 `DHCPScanPayload`.** `attemptsFailed: Int?`, `probeMac: String?`, `probeMacSource: String?` (`interface` | `nmap-default`), `systemLease: SystemLease?` (`server, assignedIp, router, dns[], domain, leaseTimeSeconds, obtainedAt, source`; the key is `null` for a static/unknown address), `dnsServersOffered: [String]?`, `replySourcesSeen: [ReplySource]?` (`{ip, mac}`), `relayAgentsSeen: [String]?`, `passiveServersSeen: [String]?`, `captureMessageTypes: [String: Int]?`. Per `Server`: `rogueReasons: [String]?` (`multiple_server_identifiers`, `differs_from_system_lease`, `offered_router_not_on_subnet`, `server_outside_subnet_without_relay`; `rogueReasonLabels`), `offeredRouter`, `offeredSubnetMask`, `offeredDns: [String]?`, `offeredDomain`, `leaseTimeSeconds: Int?`, `responderMac`, `nonOfferReplies: Int?`. Derived: `replySources` (new key, else the legacy `relay_sources_seen` which listed the same port-67 senders), `relayAgents` (nil before v1.2.252). View: "Discovery" rows, a "System lease" group, the responder table, a "Rogue reasons" card and an "Offered options per responder" table.
- **Task 5 `DHCPResponseTimePayload`.** `serversSeen: [String: ServerStats]?` (`offers, minMs, avgMs, maxMs`; `serversSeenRows` sorted most offers first), `multipleResponders: Bool?`, `offeredRouter`, `offeredDns`, `offeredDomain`, `leaseTimeSeconds`, `receiveMethod` (`bpf` | `socket`), `sendMethod` (`layer2` | `socket`; `probeMethodDescription`), `probeMac`, `probeOptions` (`"53,55,57,61,12"`), `intervalSeconds: Double?`, `unexpectedServers: [String]?`; `Indicators.probeInconsistent`, `Indicators.serverMismatch`. `packetLossPercent` is `null` on a v1.2.252 failure. View: extra Summary rows, two new `FlagBadge`s, a "Responders seen" table flagging servers discovery never saw, an "Offered options" group.
- **Task 6 `ServiceScanPayload` (DNS only).** `scannedRange: String?`, `rangeTruncated: Bool?`; per `Server`: `sources: [String]?` (`subnet-scan`, `configured`, `dhcp-offer`, `system-lease`; `sourceLabels`), `onSubnet: Bool?`, `transport: Transport?` (`tcp: open|closed|unknown`, `udp: open|open|filtered|closed|unknown`); `resolutionTest` may be `null` (probe did not run → "Not tested"); `ResolutionTest` gains `attempts: Int?`, `rcode: String?`, `ra: Bool?`, `recursion: String?` (`recursionState: Recursion` = `.enabled|.disabled|.unknown`, falling back to `open_resolver`), `externalPrivateAnswer: Bool?` (`answeredWithPrivateAddress` = either flag) and `internalTest: InternalTest?` (`domain, resolved, srvFound`). View: "Range swept" row, "Found via" tag column with an "outside subnet" marker, "Port 53" transport column, tri-state recursion label, private-answer label, internal-domain caption.
- PDF: `generate_pdf_report.py` / `generate_pdf_compare_report.py` render the same fields (labels "Reply Sources", "Relay Agents", "Recursion enabled (answers LAN clients): Yes/No/Unknown", "External name resolved to a private address (DNS filtering or rebinding)") and an orange "edited after the run" / "modified after the run" line from `edited_at` or the manifest checksum.
