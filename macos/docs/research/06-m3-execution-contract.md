# 06 — M3 execution contract (bash ⇄ LSSCore ⇄ GUI)

Frozen before the M3 agents start. PLAN.md §7 is the source of truth for the bash
flags, exit codes and `@@LSS` events; this file pins the ordering details the plan
left open, and the Swift API that the GUI is written against. Deviations must be
written back here in the same commit.

## 1. Bash side (lss-network-tools.sh v1.2.249) — clarifications on PLAN §7

### 1.1 Startup order in non-interactive (NI) mode

```
parse_args "$@"                      # new flags; valued flags shift
--version / --build-wifi-helper / … # existing early exits unchanged
NI setup:   _LSS_NONINTERACTIVE=1 ; exec 9>&2 ; export LSS_QUIET_SPINNER=1
--run-task list                      # prints the listing JSON on stdout, exit 0 — before detect_os/check_tools, no root
detect_os / ensure_standard_path / configure_runtime_paths / ensure_runtime_directories
NI validation  → exit 2 / 4          # BEFORE check_tools and BEFORE any root requirement, so the GUI can
                                     # pre-flight a request as the user and the matrix below runs unprivileged
check_tools    → exit 3              # same checklist text; no y/n prompt, never runs install.sh
root check     → exit 5              # EUID != 0 → error/not_root; warn_if_not_root is skipped in NI mode
initialize_debug_logging             # merges fd 1/2 into the tee; fd 9 was dup'd before, so @@LSS never enters debug.txt
trap … EXIT / INT TERM / ERR         # unchanged
run_noninteractive | run_build_report ; exit $?
```

No `clear`, no banner, no awk indenter, no "Press Enter" pauses in NI mode. Every `read` in
the script stays on the interactive path (`if [[ -n "$_LSS_NONINTERACTIVE" ]]; then … else <read>; fi`).
`ensure_runtime_directories` must not abort the unprivileged validation path (if it needs root in
installed mode, run the NI validation before it or make its failure non-fatal in NI mode).

### 1.2 Events (stderr via fd 9, prefix `@@LSS `, compact JSON, `"v":1`, `"ts"` ISO-8601 UTC)

| event | fields | when |
|---|---|---|
| `hello` | `version`, `pid`, `tasks` (resolved ids after expanding `000`/ranges; `[]` for `--build-report` and `--delete-run`) | first line after NI setup |
| `run_dir` | `path`, `created` (true for a new run dir, false for `--run-dir`) | after the run context exists |
| `task_start` | `task`, `title`, `index` (1-based), `total` | before `run_task_by_id` |
| `task_stage` | `task`, `stage` (machine key, lowercase snake), `label` (human) | stress stages (10/14), Task 18 steps, Task 11 steps |
| `task_done` | `task`, `status` (`success`\|`completed_with_warnings`\|`failed`\|`skipped`\|`no_output`), `rc`, `json_files` (new files only) | after each task |
| `report_built` | `txt` (file name inside the run dir) | after finalize_run |
| `pdf_built` / `pdf_failed` | `pdf` / `message` | after generate_pdf_report (skipped with `--no-pdf`) |
| `warning` | `code`, `message` | e.g. `interface_no_ip`, `task_17_helper_fallback` |
| `error` | `code`, `message`, optional `tools` | `usage`, `invalid_interface`, `invalid_target`, `invalid_mac`, `invalid_run_dir`, `missing_dependencies`, `consent_required`, `not_root`, `delete_failed` (`--delete-run`, exit 1) |
| `run_deleted` | `path` | `--delete-run` only (v1.2.251): after the run directory was removed |
| `bye` | `exit_code` | last line, always (also on error exits) |

Strings are escaped by a `json_escape` helper (quotes, backslash, control characters → `\uXXXX` or `\n`), never by jq.
Each write is `printf … >&9 2>/dev/null || true`.

**As implemented (v1.2.249) — details that refine the table above:**
* `hello` is the very first line (before `detect_os`); validation errors follow it immediately. `--run-task list` emits no events at all. `bye` is always last, also `130` on Ctrl-C and on an unexpected `set -e` exit (sent from `on_exit_trap`, exactly once).
* Everything human (dependency checklist, task output, "Report built…") is on **stdout**; fd 9 (the original stderr) carries only `@@LSS` lines, so `2>progress.log` is a clean event log. Under the GUI's pty the two interleave.
* `error.code` for a missing required value uses the field code, not `usage`: missing `--interface` → `invalid_interface`, missing `--target` → `invalid_target`, missing `--mac` → `invalid_mac`. `usage` covers bad task selections, both modes at once, `--run-dir` together with `--client/--location/--note`, missing `--building/--floor/--room`, bad `--ap-present`/`--https`/`--controller-port`/`--controller`, a missing `--ssh-user` or `LSS_SSH_PASSWORD`, unknown options and missing values. Exit-1 codes: `run_dir_unavailable`, `report_failed`, `output_dir_unavailable`. Warning codes: `interface_no_ip`, `no_report` (no task wrote JSON), `task_17_helper_fallback`.
* `task_done.status` ∈ `success | completed_with_warnings | failed | skipped | no_output | unknown` (`unknown` when the JSON has no `.status`). Exit 1 also when a task returned 0 but wrote nothing (e.g. Task 19 without Task 18). `json_files` are basenames; a single-file task that rewrote its file (continue-run, Task 17 append) reports it again.
* `report_built` / `pdf_built` carry an extra `path` (absolute) because `--output` can place the report outside the run directory.
* `task_stage` keys — 10/14: `interface_info` (10) or `preparing` (14), `baseline`, `jitter`, `large_packet`, `ramping`, `sustained`, `recovery`; 11: `dot1q_capture`, `cdp_lldp_capture`; 18: `arp_discovery`, `udp_sweep`, `tlv_fingerprinting`, `oui_classification`, `ssh_banner_rescue`, `lldp_reconciliation`. Labels are the human line minus a trailing `...`.
* The manifest is rewritten after **every** task, so a browser refresh on `task_done` sees it. Continue-run keeps the manifest's `report_file` and `prepared_by` when the flags are absent. `--build-report` also requires root.
* `LSS_SSH_PASSWORD` is copied into `_LSS_NI_SSH_PASSWORD` and `unset` during NI setup so nmap/python children never inherit it.

**Review round (M5) additions:**
* **Authenticated events.** When the environment carries `LSS_PROGRESS_TOKEN` (`^[A-Za-z0-9_-]{8,64}$`; anything else is ignored), every event is written as `@@LSS <token> {json}`; the variable is captured into `_LSS_NI_PROGRESS_TOKEN` and `unset` before any child runs. The app generates a fresh token per run (sudo route: `--preserve-env=LSS_PROGRESS_TOKEN`; helper route: `HelperRunRequest.progressToken` → child environment) and `ProgressLineParser(token:)` accepts only correctly tokened lines — a device-supplied string echoed by the engine can no longer forge a `bye` or a `task_done`. Without the variable the plain `@@LSS {json}` format is unchanged (CLI users, fixtures); `sed 's/^@@LSS [A-Za-z0-9_-]* /@@LSS /'` strips a token from a captured log.
* **Validation additions (all `usage`, exit 2):** whitespace inside the `--run-task` selection (commas only — `"1 2"` used to be read as task 12); `--run-task list` combined with any other option; `--output` with `--run-task`; blank `--client`/`--location` for a new run (trimmed; `Unknown` is no longer invented); `--ssh-user` outside `^[A-Za-z0-9][A-Za-z0-9._-]*$`; `--controller-port` outside `^[1-9][0-9]{0,4}$` and 1–65535 (leading zeros rejected — `08` was passing through an octal error); `--wifi-scan-json` not a readable regular file containing a JSON array; on macOS, Task 17 without `--wifi-scan-json` when `SUDO_USER` is empty (no GUI session to open `LSS-WiFiScan.app` — the privileged-helper case).
* **Report gate.** The report and PDF are built only when at least one task has output in the run directory (`ni_run_has_task_output`). Otherwise `warning no_report` is emitted and, when this invocation created the directory, it is removed (mirroring the interactive "no result → delete" rule); `warning report_failed` is emitted when tasks have output but `finalize_run` failed. `--build-report` exits 1 on a failed report.
* **Closed stderr.** `exec 9>&2 || exec 9>/dev/null`: with stderr closed the run proceeds without events instead of dying before `hello`.
* `json_escape` is byte-oriented (`local LC_ALL=C`): only 0x00–0x1F/0x7F are escaped and UTF-8 passes through unchanged.
* Real unprivileged captures of the error paths live beside `real-task1-events.log` and are pinned by `RealCaptureTests`.

**As implemented (1.0.2 / v1.2.251):**
* **`--delete-run <run-dir>`** is a third non-interactive mode (`DELETE_RUN_MODE`), mutually exclusive with `--run-task`/`--build-report`; the only other flag it accepts is `--debug` (any other flag → `usage`, exit 2). Validation (exit 2, before `check_tools` and before the root check like the other modes): the directory must exist, be a directory, not be a symlink, resolve inside `$OUTPUT_DIR`, not be `$OUTPUT_DIR` itself, and look like a run (`manifest.json`, or a task JSON file named in `TASKS_DATA`, or a `lss-network-tools-report-*.txt`). Then root check (exit 5), `initialize_debug_logging`, traps, then `run_delete_run` (after the shared `noninteractive_hello`): remove the directory through `delete_run_directory` — the `rm -rf` shared with the interactive "000) Delete This Run" in `run_action_submenu`; the directory checks above are NI-only and live in `noninteractive_validate` → new event **`run_deleted`** (`path`) → `bye`, exit 0; when `rm -rf` fails (or the directory is still there) → `error` with code `delete_failed` (message names the path and suggests `sudo rm -rf`), exit 1. A regular file given to `--delete-run`/`--build-report`/`--run-dir` is reported as "is not a directory" (`invalid_run_dir`). Swift side: `DeleteRunRequest { runDirectory }`, `ArgumentBuilder.arguments(for: DeleteRunRequest)` → `["--delete-run", <path>]`, `valueFlags` gains `--delete-run`, `RequestValidator` accepts exactly one of the three modes and applies the run-directory rule (canonical, root-owned, directly inside `output/`) to its value; `RunCoordinator.Mode.delete` runs it like a report build and dismisses to idle on exit 0.
* **Display vs. parse.** `ProtocolLineFilter` (LSSCore) removes every line beginning with the 6-byte marker `@@LSS ` (`ProgressLineParser.prefix`, trailing space included — plain and tokened events; `@@LSSX…` or `@@LSS\n` stays visible, at most five bytes are ever held back) from the bytes the terminal displays, streaming without line buffering; `ProgressLineParser` still receives the raw bytes. Applied in `TappedTerminalView.dataReceived(slice:)` (pty route), `RunCoordinator.consumeHelperOutput` (helper route) and `simulate(stream:)`. The interactive CLI is unaffected because it never writes `@@LSS`.
* **§3.3 `RunProgressView`/`RunAuditScreen` superseded:** the terminal pane is a hidden-by-default log ("Show log"/"Hide log", `AppModel.showRunLog`, shown automatically in `.awaitingPassword`); while active the screen shows the banner, an overall progress bar (`completed = done + failed + skipped` of `tasks.count`, indeterminate while launching/awaiting password/authenticating/building the report) with elapsed time and the current stage above `TaskProgressList`; on `.finished` with an existing `runDirectory` it shows `RunResultsView(directory:focusTask:mode:)` (own `RunLoader`/`RunLoader.loadDetail(ofDirectory:)`, own `RunDetailSelection`, the Previous Runs subviews; `.task`/`.overview`/`.report` modes), otherwise "No results were written". The terminal remains mounted at a sane size while hidden (pty rows follow the view bounds).
* **§3.4 automation additions:** `--show-log`, `--results-run <index>` (after a simulated stream ends, `runDirectory` is set to that fixture run so the results render), `--view delete-confirm --select-run N`. Screenshots: `m7-progress.png`, `m7-results.png`, `m7-log.png`, `m7-delete.png`.

### 1.3 `--run-task list` output (stdout, exit 0)

```json
{"version":"v1.2.249","tasks":[{"id":1,"title":"Interface Network Info","file":"interface-network-info.json","multi":false,"group":"core"}, …]}
```
`group` ∈ `core` (1–12), `custom` (13–16), `specialist` (17–20). `multi` is true for 10, 13, 14, 15, 16.

### 1.4 How the GUI invokes the script (M3, pty + sudo)

```
/usr/bin/sudo [--preserve-env=LSS_SSH_PASSWORD] /usr/local/bin/lss-network-tools --run-task … 
```
* The wrapper (not the script) is launched so PATH contains Homebrew's python3 (fpdf2).
* `--preserve-env=LSS_SSH_PASSWORD` is added only when Task 19 has a password; the value is in the
  child's environment, never in argv.
* The sudo password is typed by the user in the terminal pane (M4 replaces this with the helper).
* Values are always separate argv elements (`--client "Acme"`), never `--flag=value`.
* Text values never start with `-` (the builder rejects them) and contain no control characters.

## 2. LSSCore API (Sources/LSSCore/CLI/) — written by the CORE agent, consumed by the GUI agent

All types are `public`, `Sendable`, `Hashable`; Foundation only.

```swift
// CLIExitCode.swift
public enum CLIExitCode: Int32, Sendable, Hashable, CaseIterable {
    case success = 0, taskFailed = 1, usage = 2, missingDependencies = 3,
         consentRequired = 4, notRoot = 5, interrupted = 130
    public var summary: String        // one user-facing sentence
}

// RunTaskRequest.swift
public struct RunTaskRequest: Sendable, Hashable {
    public enum Selection: Sendable, Hashable {
        case fullAudit                               // --run-task 000
        case tasks([TaskID])                         // --run-task 1,3,5 (builder sorts + de-duplicates)
        public var taskIDs: [TaskID] { get }         // fullAudit → TaskID.auditTasks
    }
    public enum Context: Sendable, Hashable {
        case newRun(client: String, location: String, note: String)
        case existingRun(directory: URL)             // --run-dir
    }
    public struct WirelessRoom: Sendable, Hashable {
        public var building: String, floor: String, room: String
        public var accessPointPresent: Bool
        public var accessPointLabel: String?
        public var wifiInterface: String?
        public var scanJSON: URL?                    // --wifi-scan-json (M4)
        public init(building:floor:room:accessPointPresent:accessPointLabel:wifiInterface:scanJSON:)
    }
    public struct UniFiAdoption: Sendable, Hashable {
        public var controllerHost: String?, controllerPort: Int?, https: Bool?
        public var sshUser: String
        public var sshPasswordProvided: Bool         // the password itself never enters the request
        public init(controllerHost:controllerPort:https:sshUser:sshPasswordProvided:)
    }
    public var selection: Selection
    public var context: Context
    public var interface: String?
    public var preparedBy: String?
    public var skipPDF: Bool
    public var stressConsent: Bool                   // --yes
    public var targetIP: String?                     // 13–16
    public var macAddress: String?                   // 20
    public var wireless: WirelessRoom?               // 17
    public var unifi: UniFiAdoption?                 // 19
    public var debug: Bool
    public init(selection:context:interface:preparedBy:skipPDF:stressConsent:targetIP:macAddress:wireless:unifi:debug:)  // all but the first two defaulted
    public var requiresConsent: Bool     // fullAudit, or tasks containing 10 or 14
    public var requiresTarget: Bool      // any of 13–16
    public var requiresMAC: Bool         // 20
    public var requiresWireless: Bool    // 17
    public var requiresUniFi: Bool       // 19
}

public struct BuildReportRequest: Sendable, Hashable {
    public var runDirectory: URL
    public var preparedBy: String?
    public var skipPDF: Bool
    public var outputDirectory: URL?                 // --output DIR
    public init(runDirectory:preparedBy:skipPDF:outputDirectory:)
}

// ArgumentBuilder.swift
public enum ArgumentBuilder {
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case noTasksSelected
        case interfaceRequired
        case invalidInterfaceName(String)
        case clientRequired
        case locationRequired
        case invalidText(field: String, reason: String)     // control chars, newline, leading "-"
        case runDirectoryNotAbsolute(URL)
        case targetRequired
        case invalidTarget(String)
        case macRequired
        case invalidMAC(String)
        case wirelessRoomRequired                           // building/floor/room all non-empty
        case invalidWirelessField(String)
        case sshUserRequired
        case sshPasswordRequired
        case consentRequired([TaskID])
        public var description: String                      // user-facing sentence, used inline in the sheet
    }
    /// Every problem, in form order (empty = valid). The sheet shows these inline.
    public static func problems(in request: RunTaskRequest) -> [Problem]
    /// argv after the executable; throws the first Problem.
    public static func arguments(for request: RunTaskRequest) throws -> [String]
    public static func arguments(for request: BuildReportRequest) throws -> [String]
    /// ("/usr/bin/sudo", ["--preserve-env=A,B", wrapper] + arguments); the preserve flag is omitted when the list is empty.
    public static func sudoCommand(wrapper: String, arguments: [String], preserveEnvironment: [String]) -> (executable: String, arguments: [String])
    public static let valueFlags: Set<String>      // every flag that takes one value (grammar reused by the M4 validator)
    public static let booleanFlags: Set<String>
    public static func isValidIPv4(_ text: String) -> Bool
    public static func normalizedMAC(_ text: String) -> String?   // "aa:bb:cc:dd:ee:ff" (lowercase) or nil
    public static func isValidInterfaceName(_ name: String) -> Bool
}
```

Argument order is deterministic: `--run-task <000|1,3,5>` · `--interface X` · `--client C --location L [--note N]` **or** `--run-dir D` · `[--prepared-by P]` · `[--no-pdf]` · `[--yes]` · `[--target IP]` · `[--mac M]` · `[--wifi-interface I] [--building B --floor F --room R] [--ap-present y|n] [--ap-label L] [--wifi-scan-json F]` · `[--controller H] [--controller-port N] [--https y|n] [--ssh-user U]` · `[--debug]`.
`--note` is passed only when non-empty. `--ap-present` is always passed for Task 17 (`y`/`n`).
`--yes` is passed only when `stressConsent` is true. Task-specific flags are passed only when the selection contains the task.

```swift
// ProgressEvent.swift
public struct ProgressEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case hello(version: String?, pid: Int?, tasks: [Int])
        case runDirectory(path: String, created: Bool?)
        case taskStart(task: Int, title: String?, index: Int?, total: Int?)
        case taskStage(task: Int, stage: String?, label: String?)
        case taskDone(task: Int, status: String?, exitCode: Int?, jsonFiles: [String])
        case reportBuilt(txt: String?)
        case pdfBuilt(pdf: String?)
        case pdfFailed(message: String?)
        case warning(code: String?, message: String?)
        case error(code: String?, message: String?, tools: [String])
        case bye(exitCode: Int?)
        case unknown(event: String)
    }
    public let kind: Kind
    public let timestamp: Date?
    public let protocolVersion: Int?
    public let fields: JSONValue                 // the whole object, for anything not modelled
    public var taskID: TaskID? { get }           // for task_* events
    public var isTerminal: Bool { get }          // bye
}

// ProgressLineParser.swift — streaming, tolerant of pty output
public struct ProgressLineParser: Sendable {
    public static let prefix = "@@LSS "
    public struct Output: Sendable, Hashable {
        public var events: [ProgressEvent]
        public var lines: [String]               // complete NON-progress lines, ANSI-stripped, "\r"-aware (last segment of a \r line)
    }
    public private(set) var malformedLineCount: Int
    public init()
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> Output   // partial lines carried across calls; UTF-8 split across chunks handled
    public mutating func feed(_ text: String) -> Output
    public mutating func flush() -> Output                                // pending partial line emitted
    public static func parse(line: String) -> ProgressEvent?             // leading ANSI/whitespace before the prefix allowed; nil if not a progress line; malformed JSON → nil (counted by feed)
    public static func stripANSI(_ text: String) -> String
    /// "Stage 4: Ramping packet sizes" → "Ramping packet sizes"; best-effort for tasks without task_stage events.
    public static func stageHeuristic(in line: String) -> String?
}

// CLITaskListing.swift — `--run-task list`
public struct CLITaskListing: Sendable, Hashable, Decodable {
    public struct Entry: Sendable, Hashable, Decodable { public let id: Int, title: String, file: String, multi: Bool, group: String }
    public let version: String?
    public let tasks: [Entry]
    public static func parse(_ data: Data) throws -> CLITaskListing
    public func drift(against catalog: [TaskID]) -> [String]   // human sentences: missing/extra ids, title or file mismatches
}
```

Tests (Tests/LSSCoreTests): `ArgumentBuilderTests` (every flag, order, rejection cases, sudo command), `ProgressLineParserTests` (fixture streams fed whole, byte-by-byte and in 7-byte chunks give identical events; CRLF; `\r` spinner lines; ANSI; interleaved human text; malformed JSON counted; stage heuristic), `CLITaskListingTests`, `CLIExitCodeTests`.

Fixture streams (Tests/Fixtures/progress/, hand-written to §1.2 — the real engine stream is captured once a root run is possible and must then be diffed against these):
`full-audit.log` (12 tasks, warnings, stress stages, report + pdf), `single-task-17.log` (continue run, Task 17 append), `consent-required.log`, `not-root.log`, `missing-deps.log`, `task-failed.log`.

## 3. GUI (Sources/LSSNetworkTools/) — written by the GUI agent

### 3.1 Terminal byte tap
`TerminalSession` keeps its API (`launch(executable:arguments:environment:)`, `terminate()`, `relaunch()`, `state`, `title`) and adds
`var outputTap: (@MainActor (ArraySlice<UInt8>) -> Void)?` invoked on the main actor for every chunk the child writes, plus
`func send(text: String)`. Implementation: subclass `LocalProcessTerminalView` and override `dataReceived(slice:)` if SwiftTerm marks it `open`
(check `~/Library/Caches/ie.lssolutions.lss-network-tools/build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`);
otherwise compose `TerminalView` + `LocalProcess` the way that file does (~120 lines). `TerminalHostView` keeps working.

### 3.2 RunCoordinator (NewRun/RunCoordinator.swift, @MainActor @Observable)
```swift
enum RunPhase: Equatable { case idle, launching, awaitingPassword, running, finished(CLIExitCode?), failedToLaunch(String) }
struct TaskProgress: Identifiable { let task: TaskID; var state: State; var stage: String?; var jsonFiles: [String]
    enum State: Equatable { case pending, running, done(status: String), failed(status: String), skipped } }
final class RunCoordinator {
    private(set) var phase: RunPhase
    private(set) var request: RunTaskRequest?
    private(set) var tasks: [TaskProgress]
    private(set) var runDirectory: URL?
    private(set) var reportTXT: String?, reportPDF: String?
    private(set) var lastError: (code: String?, message: String?)?
    private(set) var log: [String]                        // non-progress lines (capped, e.g. last 2 000)
    var isActive: Bool
    func start(_ request: RunTaskRequest, sshPassword: String?)   // builds argv, launches sudo in the shared TerminalSession, resets state
    func buildReport(_ request: BuildReportRequest)
    func cancel()                                                   // terminate()
    func simulate(stream: Data, interval: Duration)                  // automation / previews: feeds a fixture log through the parser
}
```
Behaviour: `hello` → `.running`; if no `hello` within 3 s and the tap saw "assword" → `.awaitingPassword` (banner: "Type your administrator password in the terminal below"); each `task_done` → `model.runBrowser.refresh()`; `bye`/process exit → `.finished(code)`; `task_stage`, and `stageHeuristic` on human lines while a task is running, update `stage`.

### 3.3 Views (NewRun/)
* `NewRunSheet` — Interface (model.interfaces, default model.selectedInterface), Client, Location, Note, Prepared by (persisted, `Defaults` key `preparedBy`), Tasks (Full audit 000 · Selected tasks with grouped checkboxes · a preselected single task when opened from a task screen), task-specific panels appear when the selection needs them (Target IP 13–16 · MAC 20 · Wireless room 17 · UniFi controller/port/HTTPS/SSH user + `SecureField` password 19), Skip PDF toggle, inline `ArgumentBuilder.problems` messages, **Start**. For `.existingRun` the title is "Continue run", tasks already present are ticked grey and unchecked by default.
* `StressConsentDialog` — shown by Start when `request.requiresConsent`: names the tasks (10/14 or the full audit), what they do (sustained ICMP flood of the gateway/target), "I understand, run it" sets `stressConsent = true` and starts; Cancel leaves the sheet open. Without it the run is never queued.
* `RunProgressView` — header (client — location, run dir, Reveal in Finder), per-task list with state icons + current stage, phase banner (awaiting password / running / finished with exit code summary / error), terminal pane below (the live log where the password is typed), Cancel, and when finished "Show in Previous Runs" (selects the run in the browser).
* `RunAuditScreen` replaces `TerminalScreen` for `.runAudit` and `.task(_)`: TaskHeader (tasks only) · "New Run…" / "Run Task N…" button · "Continue Previous Run…" (picker of `runBrowser.runs`) · `RunProgressView` when a run is active, else the terminal pane with an idle placeholder. **The interactive CLI no longer auto-starts**; Terminal ▸ "Open Interactive CLI Session" (and the Relaunch button) start it on demand (`AppModel.launchTerminal()` kept; `launchTerminalIfNeeded()` becomes a no-op unless the user asked).
* Run browser: `RunDetailView` header gains "Continue Run…" (sheet with `.existingRun`, interface from the manifest) and "Rebuild Report" (`BuildReportRequest`).

### 3.4 Automation (App/Automation.swift)
`--view new-run` opens the sheet (full audit); with `--task N` the sheet is preselected for task N. `--view consent` opens the sheet and the consent dialog.
`--simulate-progress <log file> [--simulate-interval <ms>]` runs `RunCoordinator.simulate` on the Run Audit screen.
Screenshots: `m3-new-run.png`, `m3-stress-consent.png`, `m3-progress.png` (simulated from `Tests/Fixtures/progress/full-audit.log`), `m3-task19-inputs.png`.

## 4. Ownership (no overlapping edits)
* BASH agent: `lss-network-tools.sh`, `README.md` (non-interactive section), nothing under `macos/`.
* CORE agent: `macos/Sources/LSSCore/CLI/{CLIExitCode,RunTaskRequest,ArgumentBuilder,ProgressEvent,ProgressLineParser,CLITaskListing}.swift`, `macos/Tests/LSSCoreTests/{ArgumentBuilderTests,ProgressLineParserTests,CLITaskListingTests,CLIExitCodeTests}.swift`, `macos/Tests/Fixtures/progress/`.
* GUI agent: `macos/Sources/LSSNetworkTools/{NewRun/*, Terminal/*, App/Automation.swift, App/AppModel.swift, App/ContentView.swift, App/LSSNetworkToolsApp.swift, Settings/SettingsView.swift, RunBrowser/RunDetailView.swift (header buttons only)}`.
* Integrator: ROADMAP.md, CLAUDE.md, DECISIONS.md, QUESTIONS.md, VERSION, screenshots, commits.
