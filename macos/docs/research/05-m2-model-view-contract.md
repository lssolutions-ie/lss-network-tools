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
