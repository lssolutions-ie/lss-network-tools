# LSS Network Tools — macOS GUI implementation plan

Status: draft for approval, 2026-10-03. Worktree `.claude/worktrees/macos-gui`, branch `macos-gui`, based on `main` @ 474e45d (v1.2.246).
Ground truth: `CLAUDE.md` and `macos/docs/research/01-install-update-wifi-helper.md`, `02-interactive-surface.md`, `03-json-schemas.md`, `04-pdf-contract.md`. Line numbers refer to v1.2.246.

---

## 1. Goals and non-goals

**Goals**

- A native SwiftUI app (macOS 14+, Swift 6 language mode, no Catalyst / Electron / web views) that *drives* the existing bash tool and *browses* its run directories.
- `lss-network-tools.sh` remains the only engine. Every scan, report and PDF is produced by the script and its Python helpers exactly as today.
- Everything (build, launch, screenshot, test, dmg, sign, notarize) runs from the command line without opening Xcode.
- Changes to the bash script are limited to (a) a non-interactive `--run-task` / `--build-report` mode, (b) adding `macos` to the updater's exclusion list, and (c) the small CLI bug fixes found during research (M0, listed below). Interactive behaviour is unchanged when the new flags/env vars are absent.
- `install.sh`, the wrapper and the update helper keep working for CLI-only users; the GUI stores nothing in `APP_ROOT` except what the script itself writes under preserved names (`output/`).

**Non-goals**

- No scan logic, report logic or JSON writers in Swift. The GUI never writes task JSON, `manifest.json`, `findings.json` or PDFs.
- No editing/deleting of results or runs from the GUI (root-owned `output/`; the CLI's Manage Results covers it). Listed in QUESTIONS.md.
- No driving of `--update`, `--uninstall`, Program Defaults or the compare-report flows from the GUI (they stay available in the embedded terminal).
- No Linux build (the GUI is macOS-only; the script keeps its Linux support untouched).
- No App Store / sandbox. The app reads `/usr/local/share/lss-network-tools` and talks to a root helper.

---

## 2. Architecture

### 2.1 Targets and module layout (`macos/`)

```
macos/
  Package.swift                 # swift-tools-version 6.0, platforms: [.macOS(.v14)]
  VERSION                       # GUI semver (0.1.0 at M1 … 1.0.0 at M5); independent of APP_VERSION
  Makefile
  README.md                     # M5: build / run / sign / release
  Sources/
    LSSCore/                    # library, Foundation only (no AppKit/SwiftUI) — unit-testable, linked by app AND helper
      Models/                   #   TaskID, TaskGroup, TaskStatus (open enum), Manifest, Findings, Remediation, 20 task models
      Decoding/                 #   RunLoader, TaskFileState, natural sort, lenient number decoding, JSONDecoder factory
      CLI/                      #   CLIInstall (install.env discovery), RunTaskRequest → argv builder, ProgressEvent, ProgressLineParser,
                                #   RequestValidator (shared allow-list grammar, used by the M4 helper)
    LSSXPC/                     # library, Foundation only — @objc XPC protocol + Codable request/response types (M4)
    LSSNetworkTools/            # executable: the SwiftUI app
      App/                      #   LSSNetworkToolsApp, AppModel, SidebarView, ToolbarItems, Screenshot (--screenshot flag)
      Terminal/                 #   TerminalPane (NSViewRepresentable over SwiftTerm), ProcessHost actor (pty + sudo)
      RunBrowser/               #   RunListView, RunDetailView, FindingsTable, TaskGridView, TaskDetail/* (one view per TaskViewKind), PDFPane
      NewRun/                   #   NewRunSheet, InterfacePicker (networksetup), RunSessionModel, StressConsentDialog, LiveLogPane
      Settings/                 #   SettingsView (CLI location, privilege mode, updates, prepared-by)
      Privilege/                #   PrivilegeMode, HelperClient (NSXPCConnection), HelperInstaller (SMAppService)         (M4)
      WiFi/                     #   CoreWLANScanner + LocationAuthorizer → wifi-scan JSON file for --wifi-scan-json          (M4)
      Updates/                  #   SparkleController                                                                        (M4)
    LSSHelper/                  # executable: privileged LaunchDaemon (Foundation + LSSCore + LSSXPC only)                   (M4)
  Tests/
    LSSCoreTests/               # Swift Testing: decode every fixture, parser tests, argv builder tests, TASKS_DATA drift test
    Fixtures/
      runs/<anonymised run dirs>/
      synthetic/                # hand-written JSON for tasks 13–20 and failure shapes (no real runs exist yet)
  Resources/
    Info.plist.in               # template; build script substitutes version, feed URL, ED key
    LSSHelper-Info.plist.in     # helper's embedded Info.plist (M4)
    ie.lssolutions.lss-network-tools.helper.plist   # LaunchDaemon plist → Contents/Library/LaunchDaemons (M4)
    LSSNetworkTools.entitlements, LSSHelper.entitlements (M4)
    AppIcon.png (1024×1024)     # → AppIcon.icns via sips + iconutil in build script
  scripts/
    build-app.sh  run-app.sh  screenshot.sh  test.sh  make-dmg.sh  sign.sh  notarize.sh  release-appcast.sh  anonymize-run.py
  appcast.xml                   # Sparkle feed, committed (served raw from GitHub)
  docs/  PLAN.md  DECISIONS.md  QUESTIONS.md  research/
```

Bundle ids: app `ie.lssolutions.lss-network-tools`, helper (Mach service + daemon label) `ie.lssolutions.lss-network-tools.helper`. The existing Wi-Fi helper keeps `ie.lssolutions.wifi-scan` (research 01 §2.4 rule 6).

### 2.2 Data flow

```
┌──────────────────────────── LSS Network Tools.app (user) ─────────────────────────────┐
│ SwiftUI views ◄── @MainActor @Observable models ◄── LSSCore (RunLoader, parsers)      │
│        │                         ▲                                                      │
│  New Run sheet                   │ ProgressEvent stream (@@LSS lines)                   │
│        ▼                         │                                                      │
│  ProcessHost actor ── M1–M3: SwiftTerm pty → /usr/bin/sudo /usr/local/bin/lss-network-tools [--run-task …]
│                   └── M4:    HelperClient ── XPC ──► LSSHelper (root LaunchDaemon) ──► wrapper → script
└───────────────────────────────────────────────────────────────────────────────────────┘
                                   │ stdout/stderr (pty bytes or pipe FileHandle)
                                   ▼
            /usr/local/share/lss-network-tools/output/<run-dir>/   (written ONLY by the script, as root)
                 manifest.json  findings.json  remediation.json  <task>.json  *.txt  *.pdf  debug.txt  raw/
                                   │ read-only, FileManager + DispatchSource vnode watcher
                                   ▼
                         Run browser (M2) — tables, charts, key-value groups, PDFKit
```

- The script is the single writer. The GUI only reads `output/` and only writes to its own Application Support directory.
- The run browser refreshes on (a) progress events `task_done`/`report_built`/`pdf_built`, (b) a `DispatchSource` vnode watcher on `output/` and on the active run dir, (c) manual refresh.
- The wrapper sets `PATH` with `/opt/homebrew/bin` first, which is what makes `python3` resolve to the Homebrew interpreter that has fpdf2 (research 04). The GUI and the M4 helper must always launch the **wrapper** (or export the same PATH); a launchd-started process otherwise inherits `/usr/bin:/bin:/usr/sbin:/sbin` and `python3` becomes the CLT 3.9.6 without fpdf2.

### 2.3 GUI state

| What | Where |
|---|---|
| Preferences (`selectedInterface`, `lastClient`, `lastLocation`, `preparedBy`, `privilegeMode`, `cliAppRootOverride`, `updatesEnabled`) | `UserDefaults` via `Defaults` keys, suite = bundle id |
| GUI process log, per-session run logs (`run-<ISO ts>.log`, raw bytes from the pty/pipe) | `~/Library/Application Support/ie.lssolutions.lss-network-tools/logs/` |
| Wi-Fi scan handoff files for `--wifi-scan-json` (M4) | `~/Library/Application Support/ie.lssolutions.lss-network-tools/scans/<uuid>.json` (0600, deleted after the task) |
| Sparkle state | Sparkle's own defaults (`SU*` keys) in the same suite |

Nothing is ever created under `APP_ROOT`/`DATA_ROOT`. `.lss-last-update` is never read or deleted by the GUI.

### 2.4 Locating the CLI (decision: no bundled copy)

`CLIInstall.detect()` in LSSCore, in order:

1. Parse `/usr/local/share/lss-network-tools/install.env` (`APP_ROOT`, `DATA_ROOT`, `INSTALL_WRAPPER_PATH`; regex on `^NAME="value"$`). Validate `APP_ROOT/lss-network-tools.sh` and `INSTALL_WRAPPER_PATH` exist.
2. Else parse the wrapper `/usr/local/bin/lss-network-tools` for its `exec "<path>"` line.
3. Else `Defaults[.cliAppRootOverride]` (developer/portable use; M1–M3 pty path only — the M4 helper refuses it, §8.2).
4. Else state `.notInstalled` → the main pane shows an onboarding card with the exact commands (`git clone … && sudo ./install.sh`) and an "Open Terminal here" button. No GUI feature that needs the script is enabled.

Capabilities probe (no root needed): `bash <script> --version` → CLI version shown in the toolbar; `bash <script> --run-task list` exit 0 → non-interactive mode available (M3+); otherwise the New Run sheet is disabled with "CLI v1.2.249 or newer required; update from the terminal (option 3)".

Why no bundled copy: executing a file inside a user-writable `.app` as root is a privilege-escalation hole (M4 helper), the CLI has its own installer/updater/dependency management (brew, pip), and two copies would drift.

### 2.5 Concurrency model (Swift 6 strict)

- All models used by views are `@MainActor @Observable final class`. Decoded data types in LSSCore are `Sendable` structs/enums.
- `ProcessHost` is an `actor` owning the SwiftTerm `LocalProcess` (M1–M3) or the XPC connection (M4). It exposes `AsyncStream<ProcessChunk>` (raw bytes for the terminal/log pane) and `AsyncStream<ProgressEvent>` (parsed `@@LSS` lines). SwiftTerm's delegate callbacks arrive on a dispatch queue and are forwarded with `Task { await host.received(…) }`; UI feeding happens on the main actor (`TerminalView.feed(byteArray:)`).
- `RunLoader` is an actor doing all file I/O; views never touch `FileManager`.
- `ProgressLineParser` is a pure, `Sendable` struct (byte buffer → events), fully unit-tested.
- ObjC APIs (SwiftTerm `TerminalView`, Sparkle `SPUStandardUpdaterController`, PDFKit, `NSXPCConnection`) are wrapped in `@MainActor` classes or the actor; `@preconcurrency import SwiftTerm` is allowed if its delegate protocols are not `Sendable`-annotated (DECISIONS.md entry when used).
- `TaskID`, `TaskGroup`, `TaskViewKind` are frozen enums in LSSCore with an exhaustive `switch` per view mapping.

---

## 3. Build system decision: SwiftPM + `scripts/build-app.sh` (no Xcode project)

**Decision: SwiftPM for all five milestones.** XcodeGen is not installed, would be a third-party build dependency (MIT, but unnecessary), and `.xcodeproj` buys nothing we cannot do with a shell script plus `codesign`: an `.app` is a directory layout, `Info.plist` is a text file, entitlements are applied with `codesign --entitlements`, and SMAppService only requires the daemon plist at `Contents/Library/LaunchDaemons/<label>.plist` and the helper binary inside the bundle. The only Xcode-exclusive conveniences (asset catalogs, automatic signing, storyboard compilation) are not needed: the icon is built with `sips` + `iconutil`, signing is manual by design (identity from an env var), and there are no storyboards. **An `.xcodeproj` never becomes necessary as long as we sign manually.** It would only be reconsidered for App Store distribution (sandbox + provisioning profiles), which is a non-goal.

`scripts/build-app.sh [debug|release] [--universal]`:

1. Toolchain checks: `xcode-select -p`; `xcrun metal --version` — on failure print `xcodebuild -downloadComponent MetalToolchain` and exit 3 (SwiftTerm ≥1.15 ships `Apple/Metal/Shaders.metal` as a processed resource).
2. `swift build -c <cfg> --product LSSNetworkTools [--product LSSHelper] -Xlinker -rpath -Xlinker @executable_path/../Frameworks` (release adds `--arch arm64 --arch x86_64`; products then live in `.build/apple/Products/Release`).
3. Assemble `.build/app/LSS Network Tools.app/Contents/`: `MacOS/LSSNetworkTools`, `MacOS/LSSHelper` (M4), `Frameworks/Sparkle.framework` copied from the SPM artifact xcframework (M4), `Resources/*.bundle` (every `*_*.bundle` SwiftPM produced — SwiftTerm's resource bundle is required at runtime; the generated `Bundle.module` falls back to `Bundle.main.resourceURL`), `Resources/AppIcon.icns`, `Info.plist` rendered from `Info.plist.in` (version from `macos/VERSION`, `CFBundleVersion` = commit count, `SUFeedURL`, `SUPublicEDKey` from `$SPARKLE_PUBLIC_ED_KEY` or omitted), `PkgInfo` = `APPL????`, `Library/LaunchDaemons/<label>.plist` (M4).
4. `scripts/sign.sh` (ad hoc when `CODESIGN_IDENTITY` is unset): inside-out — helper, Sparkle XPC services/Autoupdate/Updater.app, framework, resource bundles, then the app with `--entitlements` (M4+) and `--options runtime --timestamp` only when a real identity is present.
5. Print the bundle path and `codesign -dv` summary.

Rendered `Info.plist` keys: `CFBundleIdentifier`, `CFBundleName`/`CFBundleDisplayName` ("LSS Network Tools"), `CFBundleExecutable`, `CFBundlePackageType APPL`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion 14.0`, `NSPrincipalClass NSApplication`, `NSHighResolutionCapable`, `CFBundleIconFile AppIcon`, `LSApplicationCategoryType public.app-category.utilities`, `NSLocationWhenInUseUsageDescription` + `NSLocationUsageDescription` (M4), `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` (M4).

**Makefile targets**

| Target | Does |
|---|---|
| `check-toolchain` | Xcode, Metal toolchain, `swift --version`, `xcrun notarytool`, identities present/absent (informational) |
| `build` | `scripts/build-app.sh debug` → `.build/app/LSS Network Tools.app` |
| `release` | `scripts/build-app.sh release --universal` |
| `run` | `open -n "<app>"` (LaunchServices launch — required for TCC and `Bundle.main`) |
| `screenshot` | `scripts/screenshot.sh out=.build/screenshots/<ts>.png` (§11 "Screenshot automation") |
| `test` | `swift test --package-path macos` (Swift Testing; LSSCore only, no GUI needed) |
| `fixtures` | `scripts/anonymize-run.py` over the runs listed in `Tests/Fixtures/SOURCES.txt` |
| `dmg` | `release` + `scripts/make-dmg.sh` (hdiutil UDZO, `/Applications` symlink) |
| `sign` | `scripts/sign.sh` with `CODESIGN_IDENTITY` (skips with a clear message when unset) |
| `notarize` | `scripts/notarize.sh` (`xcrun notarytool submit --wait` + `stapler`; skips when identity/profile unset) |
| `appcast` | `scripts/release-appcast.sh` (download pinned Sparkle tools, `generate_appcast`, update `macos/appcast.xml`) |
| `clean` | `rm -rf macos/.build` |

---

## 4. Dependencies and licences

| Package | Licence | Used | Milestone | Purpose |
|---|---|---|---|---|
| SwiftTerm 1.20.x | MIT | yes | M1 | `TerminalView` + `LocalProcess` (pty, `forkpty`) for the embedded terminal and the M1–M3 sudo path |
| Sparkle 2.10.x | MIT | yes | M4 | App updates (SPM binary target; `generate_appcast`/`sign_update` from the matching release tarball, pinned + sha256) |
| Defaults 8.x | MIT | yes | M1 | Typed `UserDefaults` keys; Swift 6 ready |
| KeyboardShortcuts | MIT | **no** | — | Standard menu shortcuts via SwiftUI `.keyboardShortcut` suffice; no global hotkeys |
| SwiftUIX | MIT | **no** | — | Not needed; AppKit bridging is done with three small `NSViewRepresentable`s |
| Apple: SwiftUI, AppKit, Swift Charts, PDFKit, ServiceManagement, CoreWLAN, CoreLocation, Security, Observation | — | yes | M1–M4 | — |
| Swift Testing | Apple (in toolchain) | yes | M2 | Test target |
| Python 3 stdlib | — | yes | M2 | `anonymize-run.py` (no third-party modules) |

No other third-party code. If anything else is ever added it needs a one-line licence note here first.

---

## 5. Data model and decoding strategy

### 5.1 TaskID, groups, view kinds

```swift
enum TaskID: Int, CaseIterable, Sendable { case interfaceInfo = 1, speedTest, gatewayDetails, dhcpScan, dhcpResponseTime,
  dnsScan, ldapScan, smbNfsScan, printServerScan, gatewayStress, vlanTrunk, duplicateIP,
  customPortScan, customStress, customIdentity, customDNS, wirelessSurvey, unifiDiscovery, unifiAdoption, findByMAC }
enum TaskGroup { case coreAudit /*1–12*/, customTarget /*13–16*/, specialist /*17–20*/ }
```

Per task (static table in `TaskID`): `title` (mirrors `TASKS_DATA`), `baseFileName`, `isMultiEntry` (10, 13–16), `needsTarget` (13–16), `needsMAC` (20), `isStress` (10, 14), `isAudit` (1–12), `viewKind`. A Swift Testing test parses `TASKS_DATA` from `../lss-network-tools.sh` (relative to the package) and asserts titles/filenames match — a drift guard that costs nothing.

| Task | Primary view | Secondary |
|---|---|---|
| 1 | key-value (interface, ip, mask, CIDR, gateway, MAC, VM) | — |
| 2 | key-value (public IP, ISP, server, ping / down / up) | — |
| 3 | Table of `open_ports` | key-value gateway, skip banner |
| 4 | Table `servers[]` (ip, classification, offers, ports, rogue) | key-value counts; disclosure for `raw_attempts` |
| 5 | Swift Charts: `response_times_ms` per probe (nil = lost); key-value min/avg/max/loss | subnet utilisation group |
| 6–9 | Table `servers[]` (ip, ports, services, `smb_signing_required`, resolution test, PTR) | — |
| 10 / 14 | Swift Charts: ramping avg/max latency vs packet size + loss %; stage status strip | key-value baseline / jitter / large / sustained / recovery, indicators |
| 11 | Tables `cdp_neighbours`, `lldp_neighbours`; VLAN id chips | indicators |
| 12 | Table `duplicates[]` (ip, MACs, vendors) | counts |
| 13 | Table `open_ports` | key-value target/hostname |
| 15 | key-value identity (vendor, type hint, confidence, summary) | Table `services[]` |
| 16 | key-value flags | three query groups (udp/tcp/ptr: status + answers) |
| 17 | Rooms list (building/floor/room/AP) → Table `networks[]` (SSID, BSSID, RSSI, channel, band, width) | Chart: RSSI by SSID for the selected room |
| 18 | Table `devices[]` (MAC, IP, model, confidence) | `false_positives[]` section |
| 19 | key-value controller / inform URL / counts | Table `devices[]` (ip, result) |
| 20 | key-value (MAC queried, IP found, subnet) | — |
| all | status badge, `warnings[]`, `error` banner, "Raw JSON" tab (pretty-printed text) | |

### 5.2 Decoding rules (from research 03 hazards)

- One `JSONDecoder` factory: `keyDecodingStrategy = .convertFromSnakeCase`, dates decoded manually (`generated_at` is `dd-MM-yyyy HH:mm` local; wireless `timestamp` is ISO-8601 UTC).
- `TaskEnvelope` = `status: TaskStatus`, `success: Bool`, `error: TaskError?` (`decodeIfPresent`), `warnings: [String]` (`decodeIfPresent ?? []`), `skipReason`, `skipMessage`. `TaskStatus` is an **open enum**: `success`, `completedWithWarnings`, `failed`, `skipped`, `unknown(String)` — never throws. `success == false` with `.skipped` is expected.
- Every task-specific field is optional (failure files for 10, 11, 14, 15, 16 contain only the envelope).
- All metrics decode as `Double?` through a `LenientNumber` helper that accepts Int, Double, numeric String and `null` (`packet_loss_percent` is int-or-float; `channel` is a string; `scan_ports` is a CSV string kept as string; `services[].port` is `"22/tcp"` kept as string).
- `StressTestResult` decodes both `gateway` and `targetIp`, exposes `target: String?`; `stageStatus` values are open enums (`ok`/`failed`/`partial`/other).
- `WirelessNetwork`: everything optional except `ssid`; sentinels `"(hidden)"`, `"--"`, `"unknown"`, `""` are preserved in the model and rendered as a dash by the views (`Sentinel.display(_:)`).
- Task 19/20 have no `warnings` key; Task 18 `devices_found` includes probable devices; `confidence` missing = confirmed.
- Legacy shapes (old task 2 raw speedtest, task 4 `dhcp_servers_found`) are detected by key presence and surfaced as `TaskFileState.legacy(summary)` rather than decoded.

### 5.3 Run discovery (`RunLoader`)

- Enumerate `DATA_ROOT/output/*/` (directories only; skip `.debug-session-*.txt`).
- Prefer `manifest.json` (client, location, note, `generated_at`, `selected_interface`, `report_file`, `tasks[]`). **Fallback when the manifest is missing or corrupt**: glob known filenames for all 20 tasks, derive date from the directory name (`[0-9]{2}-[0-9]{2}-[0-9]{4}`), leave client/location as the slug text, mark the run `manifestMissing`.
- Multi-entry files: glob `<base>-device-*.json`, natural sort on N (`-device-2` before `-device-10`); for Task 10 also glob the non-indexed `gateway-stress-test.json` (skipped / early-failure results written by older CLI versions).
- PDF path: `manifest.report_file` with `.txt` → `.pdf`; else newest `*.pdf` in the run dir; TXT likewise. Never reconstruct the `HH-MM` stamp.
- Per-file state: `.present(Decoded)`, `.corrupt(Error)`, `.legacy`, `.missing`, `.unreadable` — EACCES (the 0600 stress files from older runs) is shown as **"Needs elevation to read"** with a hint (M1–M3: `sudo chmod 644 <file>` in the terminal; M4: "Repair permissions" button → helper op, §8.2).
- `findings.json` / `remediation.json` may be absent or newer than the task files; absence is a normal state in the UI.
- Run list sort: `generated_at` descending, fallback to directory mtime.

---

## 6. Fixture anonymisation script — `macos/scripts/anonymize-run.py`

Python 3 stdlib only. `anonymize-run.py <run-dir> <fixtures-root> [--salt-file macos/Tests/Fixtures/.salt] [--pdf] [--check]`, plus `sudo anonymize-run.py --stage <run-dir> <staging-dir>` for the 0600 problem.

- **Deterministic replacement**: every identifier is replaced by `prefix-<first 6 hex of HMAC-SHA256(salt, value)>`, so repeated runs for the same client map to the same fake name and tests can assert equality across fixtures. The salt file is committed (fixtures must be reproducible); it carries no secret.
- **Names**: `manifest.client` → `Client-xxxxxx`, `location` → `Site-xxxxxx`, `note` → `note-xxxxxx` (or empty), `prepared_by` → `Test Engineer`. The run directory name and `manifest.run_directory` / `report_file` are rebuilt from the new slugs with the original date/time parts preserved. TXT report and `debug.txt` are **dropped** (free text full of names); `raw/` is dropped (nmap/tcpdump text).
- **IPs**: `servers[].public_ip` (task 2) and every IPv4 literal anywhere in any JSON string/field that is not RFC1918, loopback, link-local, multicast, `0.0.0.0` or `255.255.255.255` is mapped deterministically into `198.51.100.0/24` / `203.0.113.0/24` (TEST-NET). Private IPs are kept verbatim so tables look real.
- **Hostnames**: `hostname`, `ptr_hostname`, `gateway_ptr`, `isp_name`, `test_server`, speed-test `location`, `cdp_neighbours[].device_id`, `lldp_neighbours[].system_name|system_description`, DNS `answers[]`/`resolved_ips` (public IPs mapped, names hashed), wireless `ssid` (school names) → `ssid-xxxxxx` except `(hidden)`. **MAC addresses and vendor strings (`vendors[]`, `vendor`, `model`) are left intact.**
- **`--pdf`**: regenerate the PDF for the anonymised run with `/opt/homebrew/bin/python3 $APP_ROOT/generate_pdf_report.py <fixture-run> $APP_ROOT <pdf> "Test Engineer"` (works as the user) so the PDFKit pane has a real, clean fixture. Manifest is rewritten first (the generator reads it).
- **`--check`**: greps the whole fixture tree for every original client/location/note token, public IP and SSID collected during the pass and fails if any remains — run by `make fixtures` and by a Swift test over `Tests/Fixtures/leak-check.txt`.
- **0600 files**: the script lists unreadable files and continues. To include them: `sudo python3 anonymize-run.py --stage <run> <staging>` copies the run and `chown -R $SUDO_USER` it (done outside the app, once), then the normal pass runs on the staging copy. If staging is not possible, the stress-test decoders are covered by `Tests/Fixtures/synthetic/`.
- **Synthetic fixtures**: no real files exist for tasks 13–20; hand-written JSON following research 03 (success, failure and skipped shapes, both Task 10 file names, 17 with mixed scanner key sets, 19/20 without `warnings`) lives under `synthetic/` and is clearly labelled.

---

## 7. Non-interactive CLI contract (M3) — `--run-task` and `--build-report`

### 7.1 Flags

| Flag | Value | Applies to | Notes |
|---|---|---|---|
| `--run-task` | `<id>` \| `<list>` (`1,3,5-7`, via `expand_task_selection`) \| `000` (= `get_audit_task_ids`) \| `list` | all | `list` prints `{"tasks":[{id,title,file,multi,group}]}` on stdout and exits 0 before `check_tools`, no root needed |
| `--build-report` | `<run-dir>` | report | `load_run_metadata_from_dir` → `build_report_for_current_run` → **always** `write_manifest_for_current_run` → `generate_pdf_report`; honours `--prepared-by`, `--output DIR` (default: inside the run dir), `--no-pdf`; emits `report_built` / `pdf_built`; exits 0/1 |
| `--interface` | interface name | all | required unless `--run-dir` manifest has `selected_interface`; validated against `list_interfaces` (exit 2); `interface_has_valid_ip` failure = warning, continue |
| `--client`, `--location`, `--note` | text | new run | empty → `Unknown` (note may be empty), exactly as `initialize_run_context` |
| `--run-dir` | absolute path under `OUTPUT_DIR` | continue run | mirrors `continue_run_from_dir` (§7.5); mutually exclusive with `--client/--location/--note` |
| `--yes` | — | 10, 14, 000 | stress consent; also means "save" (the `Save report?` prompt is never reached in NI mode) |
| `--target` | IPv4 | 13–16 | validated with the same regex/awk as `prompt_for_target_ip`; required (exit 2) |
| `--mac` | MAC, any format | 20 | normalised like `find_device_by_mac`; invalid → exit 2 |
| `--wifi-interface` | interface | 17 | default: `SELECTED_INTERFACE` if wireless, else first of `list_wireless_interfaces` |
| `--building`, `--floor`, `--room` | text | 17 | required (exit 2) |
| `--ap-present` | `y`\|`n` | 17 | default `n` |
| `--ap-label` | text | 17 | optional |
| `--wifi-scan-json` | file path | 17 | JSON array in the helper's `Network` shape; when given, used instead of `run_wireless_scan` (lets the GUI scan with CoreWLAN in M4) |
| `--controller`, `--controller-port`, `--https y\|n`, `--ssh-user` | | 19 | defaults from Program Defaults as today; `--ssh-user` required |
| `LSS_SSH_PASSWORD` (env) | | 19 | **never argv**; required when `--ssh-user` given (exit 2); already reaches `sshpass -e` via `SSHPASS` |
| `--prepared-by` | text | all | `RUN_PREPARED_BY` for the PDF cover (new-run flows never set it today) |
| `--no-pdf` | — | all | skip `generate_pdf_report` |
| `--debug` | — | all | unchanged; NI mode implies quiet spinners anyway |

`parse_args` gains `case` arms that `shift` for valued flags; the usage line and `write_completion_files` lists are updated. Interactive mode is untouched: all new globals default to empty and every injection site is `if [[ -n "${_LSS_NI_…}" ]]; then …; else <existing read>; fi`.

### 7.2 Exit codes

`0` every task `success`/`completed_with_warnings`/`skipped` · `1` at least one task failed or wrote no JSON · `2` usage/validation · `3` missing required dependency (`check_tools`) · `4` stress task requested without `--yes` · `5` not root · `130` interrupted (existing `on_interrupt`).

### 7.3 Progress protocol (stderr, prefix `@@LSS `)

One line per event: `@@LSS ` + compact JSON object, always containing `"v":1`, `"ts":"<ISO-8601 UTC>"`, `"event"`. Emitted by `emit_progress()`, a **no-op unless `_LSS_NONINTERACTIVE=1`**. It writes to fd 9, which NI mode dups from the original stderr (`exec 9>&2`) *before* `initialize_debug_logging` merges fd 1/2 into the tee — so progress lines never pollute `debug.txt` and survive the redirect; from the caller's side they are on stderr (a pty merges them with everything else, which is why the prefix exists). JSON is built with `printf` + a `json_escape` helper (not jq: `check_tools` may be reporting that jq is missing). Writes use `|| true` so a closed fd cannot trip `set -e`.

```
@@LSS {"v":1,"ts":"…","event":"hello","version":"v1.2.249","pid":4242,"tasks":[1,2,3]}
@@LSS {"v":1,"ts":"…","event":"run_dir","path":"/usr/local/share/lss-network-tools/output/acme-hq-03-10-2026","created":true}
@@LSS {"v":1,"ts":"…","event":"task_start","task":4,"title":"DHCP Network Scan","index":4,"total":12}
@@LSS {"v":1,"ts":"…","event":"task_stage","task":10,"stage":"ramping","label":"Stage 4: Ramping packet sizes"}
@@LSS {"v":1,"ts":"…","event":"task_done","task":4,"status":"success","rc":0,"json_files":["dhcp-scan.json"]}
@@LSS {"v":1,"ts":"…","event":"report_built","txt":"lss-network-tools-report-acme-hq-03-10-2026-14-05.txt"}
@@LSS {"v":1,"ts":"…","event":"pdf_built","pdf":"lss-network-tools-report-acme-hq-03-10-2026-14-05.pdf"}   | "pdf_failed","message"
@@LSS {"v":1,"ts":"…","event":"error","code":"missing_dependencies","message":"…","tools":["nmap"]}         | consent_required | not_root | usage | invalid_interface
@@LSS {"v":1,"ts":"…","event":"bye","exit_code":0}
```

`task_done.status` is read from the written JSON's `.status` with jq (`no_output` when the task wrote nothing); `json_files` is the set difference of `task_json_files` before/after for multi-entry tasks. `task_stage` is emitted in M3 for the stress stages (`run_stress_test_for_target`), Task 18 steps and Task 11 steps via a one-line `emit_stage` call next to the existing human line; for the other tasks the GUI heuristically matches `^\s*Stage \d+:` in the human stream (documented as best-effort).

### 7.4 Quiet spinners, `check_tools`, root

- `LSS_QUIET_SPINNER=1` (env) makes `spinner`, `start_spinner_line`, `stop_spinner_line` and `monitor_nmap_progress` take their existing `DEBUG_MODE` branch (one helper `spinner_is_quiet()` = `DEBUG_MODE==1 || LSS_QUIET_SPINNER==1`). NI mode sets it; interactive behaviour is unchanged unless the env var is set.
- `check_tools` in NI mode: identical checklist output, but when something required is missing it emits `error/missing_dependencies` and `exit 3` instead of the y/n loop. It never runs `install.sh`.
- Root: NI mode checks `EUID` right after `check_tools` (before `initialize_debug_logging`, which would otherwise exit 1 with a human message): emit `error/not_root`, `exit 5`.

### 7.5 Dispatcher `run_noninteractive()` — insertion point and semantics

Inserted after the three `trap` lines (research 02 §1), before caffeinate/banner/main loop: `if [[ "$RUN_TASK_MODE" -eq 1 ]]; then run_noninteractive; exit $?; fi` (caffeinate kept; banner skipped).

1. Validate everything up front (ids, interface, task-specific flags, consent) → exit 2/4 before any task runs.
2. Run context: new run → `initialize_run_context` is split into the prompts and a new `initialize_run_context_from_values "$client" "$location" "$note"` that contains the existing slug/dir/uniqueness/mkdir logic (the interactive function calls prompts → values, so it is behaviour-identical). `--run-dir D` → set `RUN_OUTPUT_DIR`, `RUN_DEBUG_LOG=D/debug.txt`, `RUN_MANIFEST_FILE=D/manifest.json`, `load_run_metadata_from_dir D`, `RUN_REPORT_FILE` from `manifest.report_file` (else a fresh name), **never touch `SESSION_DEBUG_LOG`** — exactly what `continue_run_from_dir` does (L2053). Emit `run_dir`.
3. Stress consent: `--yes` sets `_LSS_NI_STRESS_CONSENT=1`; `confirm_gateway_stress_operation` gains a first check: if NI and consent → set `HIGH_IMPACT_STRESS_CONFIRMED_TARGET="$target_description"`, `return 0`; if NI without consent → print the cancelled line, `return 1` (never `read`). Interactive path unchanged.
4. For each id: `emit task_start`; `if run_task_by_id "$id"; then rc=0; else rc=$?; fi` — same `if` form the interactive wrappers use, so errexit/ERR-trap semantics inside tasks are identical; `SHOW_FUNCTION_HEADER=0`; no awk indenter, no pause. `emit task_done`. Continue on failure (like `run_all_tasks`).
5. `finalize_run` (TXT + `findings.json` + `remediation.json` + `debug.txt` + manifest; `_LSS_EXITING=0` so the session log is truncated, not deleted) → `emit report_built`; unless `--no-pdf`, `generate_pdf_report` → `emit pdf_built|pdf_failed`; then **`RUN_OUTPUT_DIR=""`** so the EXIT trap does not build the report twice (CLAUDE.md rule). `emit bye`, exit per §7.2. The EXIT trap still runs `finalize_run` (now a no-op for the run) and kills registered background PIDs, spinner and caffeinate — `set -e`/trap semantics intact.

### 7.6 Task 17 multi-room protocol (decision: one room per invocation, append)

`--run-task 17 --run-dir D --building B --floor F --room R [--ap-present y --ap-label L] [--wifi-scan-json F]` scans one room and behaves like navigation choice `4`. If `D/wireless-survey.json` exists and is valid, the new room entry is **appended** to `survey[]` and `rooms_scanned` is incremented (jq merge, written via mktemp + mv + chmod 644); otherwise the file is created. The GUI's survey panel shows the rooms recorded so far and a "Scan this room" button — matching how a survey is actually walked. A batch `--rooms-json` was rejected: rooms are scanned minutes apart in different places. In M3 without `--wifi-scan-json`, the script keeps using `LSS-WiFiScan.app` via `sudo -u $SUDO_USER open -W` (works under the pty/sudo path because `SUDO_USER` is set).

### 7.7 Injection sites (complete list)

`parse_args` (L1168), `write_completion_files` (L979), `check_tools` missing branch (L4065), new `run_noninteractive`/`run_build_report`/`emit_progress`/`emit_stage`/`json_escape`/`spinner_is_quiet`, `initialize_run_context` split (L1453), `confirm_gateway_stress_operation` (L233), `prompt_for_target_ip` (L1347, returns `_LSS_NI_TARGET` when set — covers 13–16), `wireless_site_survey` (L8331: interface pick, three `read`s, AP loop, navigation loop, append logic), `unifi_adoption` (L11428–11467), `find_device_by_mac` (L11596), the three spinner functions (L6166–6240), `monitor_nmap_progress` (L6110), top level after the traps (L12406). Everything else is untouched. `bash -n` and a scripted interactive smoke (pty, via the GUI's own `ProcessHost` test harness) run before the M3 commit.

---

## 8. Sudo / privilege strategy

### 8.1 M1–M3: pty + `sudo`, password typed by the user (decision)

The embedded SwiftTerm pane runs `/usr/bin/sudo /usr/local/bin/lss-network-tools [--run-task …]` under a real pty (`LocalProcess`/`forkpty`), with `TERM=xterm-256color`, `LANG=en_US.UTF-8`, `LSS_QUIET_SPINNER=1` for NI runs. The user types the password into the terminal; it never passes through Swift memory, Defaults, argv or a file.

Rejected: `sudo -S` with a SwiftUI `SecureField` (password held in app memory, written to a pipe — gratuitous handling for an interim path); `sudo -A` + askpass helper (needs an extra executable, same memory concern); `osascript … with administrator privileges` (no streaming output, no pty, brittle quoting). The pty is what M1 already needs, and M4 removes passwords entirely.

Consequences, documented in the UI: `sudo`'s timestamp is per tty/session, so every spawned process re-prompts. The New Run sheet therefore runs *the whole selected queue in one process* (`--run-task 1,2,3` or `000`): one password per queue; running one more task later asks again. This disappears in M4.

### 8.2 M4: SMAppService LaunchDaemon + XPC (decision)

- Daemon plist `Contents/Library/LaunchDaemons/ie.lssolutions.lss-network-tools.helper.plist`: `Label`, `BundleProgram = Contents/MacOS/LSSHelper`, `MachServices = { "ie.lssolutions.lss-network-tools.helper": true }`, `AssociatedBundleIdentifiers = [app id]`. Registered with `SMAppService.daemon(plistName:)` → `.register()`; `.requiresApproval` → `SMAppService.openSystemSettingsLoginItems()` with an explanation; status shown in Settings with Register / Unregister.
- Helper: Foundation only, `NSXPCListener(machServiceName:)`, exported `@objc protocol LSSHelperProtocol`:
  `runTask(_ request: Data /* Codable RunTaskRequest */, output: FileHandle, reply: (Int32 exitCode, String? refusalReason) -> Void)`,
  `cancelTask(token:)`, `repairRunPermissions(runDir: String, reply:)`, `version(reply:)`.
  The app creates a `Pipe`, passes the write end; the helper dup2s it onto the child's stdout and stderr so the GUI reads one stream (progress lines + human output), exactly like the pty path. No pty needed: NI mode never prompts and spinners are quiet.
- Caller validation in `listener(_:shouldAcceptNewConnection:)`: `connection.setCodeSigningRequirement("anchor apple generic and identifier \"ie.lssolutions.lss-network-tools\" and certificate leaf[subject.OU] = \"<TEAMID>\"")` (the Team ID is baked in at build time from `CODESIGN_TEAM_ID`). When built without an identity (`LSS_DEV_UNSIGNED=1`), the requirement degrades to `identifier "ie.lssolutions.lss-network-tools"` **and** an audit-token check (`SecCodeCopyGuestWithAttributes` + `kSecGuestAttributeAudit`, `SecCodeCheckValidity`) that the caller's bundle path is the same bundle the helper was loaded from; the helper logs a loud warning. Release builds refuse to start in dev mode.
- Request allow-list (helper side, never trusting the app): executable must be `INSTALL_WRAPPER_PATH` or `APP_ROOT/lss-network-tools.sh` **as read by the helper itself** from `/usr/local/share/lss-network-tools/install.env`; both files must be regular, owner uid 0, mode without group/world write, not symlinks; args must match the exact §7.1 grammar (per-flag regexes: ids, interface `^[a-z0-9]+$`, IPv4, MAC, port, `y|n`, free text limited to `[^\x00-\x1f]{0,120}`); `--run-dir` must realpath to a child of `DATA_ROOT/output`; `--wifi-scan-json` must realpath into the calling user's `~/Library/Application Support/ie.lssolutions.lss-network-tools/scans/` (uid from the audit token) and be a regular file < 2 MB; `LSS_SSH_PASSWORD` arrives as a `Data` field in the request and is placed in the child environment only. Environment is built from scratch (`PATH` as in the wrapper with `/opt/homebrew/bin` first, `HOME=/var/root`, `LANG=en_US.UTF-8`, `LSS_QUIET_SPINNER=1`). No bundled copy of the script is ever executed (§2.4).
- `repairRunPermissions`: `chmod 0644` on regular `*.json` files directly inside one run dir under `output/` (fixes old 0600 stress files); refuses symlinks and anything else.
- Fallback: `PrivilegeMode` = `.helper` when registered and the `version()` ping succeeds, else `.sudoTerminal` (the M1–M3 path). The user can force either in Settings.
- What is known about signing: SMAppService needs the app to be code-signed and the helper to live inside the bundle; with an ad-hoc signature registration is reported to work for local testing but Team-ID-based XPC validation is impossible. With **0 identities on this Mac**, M4 delivers: helper built, unit-tested (request validation, path canonicalisation, env construction), registered and exercised ad hoc as far as macOS allows; end-to-end verification with Team-ID validation is recorded in QUESTIONS.md and the pty/sudo path remains the default until that is done.

### 8.3 Wi-Fi survey (Task 17) from the GUI (decision: GUI scans with CoreWLAN in M4)

When launched from the GUI in M4 the script runs under launchd (no `SUDO_USER`, no GUI session), so it cannot `open` `LSS-WiFiScan.app`. The GUI — a real `.app` launched by LaunchServices, running as the user — requests `CLLocationManager.requestWhenInUseAuthorization()` (ignore the first `.notDetermined`, 60 s timeout), scans with `CWInterface.scanForNetworks(withSSID: nil)` falling back to `cachedScanResults()`, writes the helper-shaped JSON array (`ssid, bssid, rssi_dbm, noise_floor_dbm, channel, band, channel_width, phy_mode, security`) to `…/scans/<uuid>.json` (0600) and passes `--wifi-scan-json`. Requires `NSLocationWhenInUseUsageDescription`/`NSLocationUsageDescription` and, under hardened runtime, `com.apple.security.personal-information.location`. The app's bundle id gets its own TCC entry (the CLI's `--uninstall` resets only `ie.lssolutions.wifi-scan`; noted in QUESTIONS.md). In M3 (pty + sudo) the script keeps using `LSS-WiFiScan.app`; `LSS-WiFiScan.app` stays installed for CLI users.

---

## 9. Sparkle, DMG

- `SUFeedURL = https://raw.githubusercontent.com/lssolutions-ie/lss-network-tools/main/macos/appcast.xml` — the feed is a committed file (no GitHub API, no rate limits, versioned). `releases/latest/download/…` was rejected because "latest" may be a CLI release without the asset.
- GUI releases are tagged `macos-vX.Y.Z` (does not match the CLI updater's `^v[0-9]+\.[0-9]+\.[0-9]+$`, so the CLI ignores them); the DMG `LSS-Network-Tools-X.Y.Z.dmg` is the release asset referenced by the appcast `enclosure`.
- Keys: `SUPublicEDKey` injected into Info.plist from `$SPARKLE_PUBLIC_ED_KEY`; `scripts/release-appcast.sh` runs `generate_appcast --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"` (tools downloaded from the pinned Sparkle release tarball, sha256-checked, into `.build/sparkle-tools/`). If the public key is absent the plist omits it, `SUEnableAutomaticChecks=false`, and the "Check for Updates…" menu item is disabled with a tooltip — Sparkle must never run unkeyed.
- Signing note: Sparkle verifies EdDSA and, when the running app is code-signed, that the update's signing identity matches. With ad-hoc builds the appcast, feed parsing, download and EdDSA verification can be tested, but the final install may be refused; the full update loop is only meaningful once a Developer ID exists (QUESTIONS.md).
- `scripts/make-dmg.sh`: staging dir with the app and an `Applications` symlink → `hdiutil create -volname "LSS Network Tools" -srcfolder <staging> -ov -format UDZO <dmg>`; `make notarize` then submits the DMG and staples both the DMG and the app inside.

---

## 10. Milestone plan

Common to every milestone: `make build && make run && make screenshot` and reading the PNG; full compiler output read after any failure; ROADMAP.md gets one line (`- **macos-gui M<n>** — …`; CLI-touching commits use the `**v1.2.NNN**` form); CLAUDE.md "In Progress" section updated; DECISIONS.md/QUESTIONS.md appended; one commit per milestone (plus fix-ups), each building and running before the next starts. Only commits that touch `lss-network-tools.sh` bump `APP_VERSION`: **M0** (v1.2.247, CLI fixes), **M1** (v1.2.248, updater exclusion) and **M3** (v1.2.249, `--run-task`/`--build-report`).

### M0 — CLI prerequisites (bash only; risk: low)

Fixes for bugs found during research, all on the `macos-gui` branch (they reach `main` with the PR; see QUESTIONS.md):
1. Report export regression (v1.2.246): `build_report_for_current_run` regenerates the report name only when `RUN_REPORT_FILE` is empty or points inside `OUTPUT_DIR` but not inside the current `RUN_OUTPUT_DIR`; export paths outside `OUTPUT_DIR` are honoured again.
2. `build_report_for_run_dir` always rewrites the manifest before generating the PDF (not only when missing).
3. Stress-test JSON (`run_stress_test_for_target`) gets `chmod 644` after the `mv` so the files are readable by non-root readers.
4. Task 10 early exits (skipped / `interface_info_missing` / `gateway_not_detected`) write to the next `-device-N.json` like every other Task 10 result, and `append_findings_summary` iterates all Task 10 device files (so stress findings and the remediation hint fire for real results).
5. Task 20 `insufficient_privileges` returns 1 like Task 18.
Verification: `bash -n`, shellcheck, helper tests under `/bin/bash` 3.2 (same harness as the v1.2.246 review). Commit: `v1.2.247: fix report export path, manifest refresh before PDF, stress-test JSON permissions and Task 10 file naming`.

### M1 — Shell (risk: medium — SwiftTerm resources + pty + sudo UX)

Scope: SwiftPM package; app skeleton; `NavigationSplitView` sidebar: **Run Audit**, **Tasks** grouped *Core Audit (1–12)*, *Custom Target (13–16)*, *Specialist (17–20)* (20 tasks; Task 20 = Find Device by MAC), **Previous Runs** (placeholder), **Settings** (CLI location state); main pane = SwiftTerm terminal running `sudo /usr/local/bin/lss-network-tools` (password typed in the terminal; relaunch button when the process exits); toolbar: selected interface (from Defaults, default-route interface via `route -n get default` parsing or `en0`), GUI version, CLI version; `--screenshot <path>` app flag; `macos` added to the updater exclusion list; `.gitignore` gets `macos/.build/`.

Files: `macos/Package.swift`, `VERSION`, `Makefile`, `Resources/Info.plist.in`, `Resources/AppIcon.png`, `scripts/build-app.sh`, `scripts/run-app.sh`, `scripts/screenshot.sh`, `scripts/sign.sh` (ad hoc only for now), `Sources/LSSCore/{Models/TaskID.swift, CLI/CLIInstall.swift}`, `Sources/LSSNetworkTools/{App/*, Terminal/*, Settings/SettingsView.swift}`, `Tests/LSSCoreTests/TaskIDTests.swift` (TASKS_DATA drift test). Modify: `lss-network-tools.sh` (updater exclusion `! -name macos`, `APP_VERSION`), `ROADMAP.md`, `CLAUDE.md` (new `## macos/ GUI` section + `## In Progress`), `.gitignore`.

Verification: `make check-toolchain` output; `make build` log (0 warnings in our targets); `make run`; `make screenshot` → `.build/screenshots/m1-shell.png` read back showing sidebar groups, terminal with the sudo prompt/startup menu, toolbar; `make test` passes the drift test; `bash -n lss-network-tools.sh`; `bash lss-network-tools.sh --version` prints the bumped version.

Commit: `v1.2.248: exclude macos/ from the update helper copy; add macOS GUI M1 shell (SwiftPM, SwiftTerm terminal, sidebar)`.

### M2 — Run browser (risk: low — pure decoding and views)

Scope: `RunLoader`, all models (§5), `RunListView` (client / location / date / note / task count / PDF badge), `RunDetailView` with tabs: **Findings** (Table, severity colour: high = red, warning = orange, info = blue, advice = gray; sortable), **Tasks** (20-cell completion grid from manifest + decoded status), **Task detail** (per `TaskViewKind`: `Table`, Swift Charts, key-value groups, raw JSON), **Report** (PDFKit `PDFView` + "Reveal in Finder" via `NSWorkspace.activateFileViewerSelecting`; TXT fallback), `Needs elevation` state for 0600 files, manifest-missing fallback, vnode watcher. Fixtures + anonymiser + tests.

Files: `Sources/LSSCore/{Models/*, Decoding/*}`, `Sources/LSSNetworkTools/RunBrowser/*`, `scripts/anonymize-run.py`, `Tests/Fixtures/{runs/*, synthetic/*, SOURCES.txt, .salt, leak-check.txt}`, `Tests/LSSCoreTests/{FixtureDecodingTests.swift (parametrised over every JSON under Fixtures), RunLoaderTests.swift, NaturalSortTests.swift, LenientNumberTests.swift}`.

Verification: `make fixtures` (with `--check`, and `--pdf` for at least one run) output; `make test` output listing every fixture file decoded; screenshots `m2-runs.png`, `m2-findings.png`, `m2-task5-chart.png`, `m2-pdf.png` read back. Parallel subagents: models for tasks 1–12 / 13–20 / manifest+findings, views per group, anonymiser.

Commit: `macos: M2 run browser — models, fixtures, tests, findings/tasks/PDF views`.

### M3 — Non-interactive execution (risk: high — 12k-line bash 3.2 script; interactive regressions)

Scope (bash, §7): flags, `emit_progress`, dispatcher, `--build-report`, injection sites, quiet spinners, `check_tools`/root behaviour, Task 17 append protocol, completions. Scope (GUI): `RunTaskRequest` → argv builder (LSSCore, unit-tested, mirrors the helper's allow-list grammar so M4 reuses it), `ProgressLineParser`, `ProcessHost` running `sudo … --run-task` in the pty, **New Run sheet** (interface picker parsed from `networksetup -listallhardwareports` blocks `Hardware Port / Device / Ethernet Address`, plus `ifconfig -l` for devices without a hardware port; client, location, note, prepared-by), run a single task / a selection / **Full audit (000)**, per-task progress list fed by `task_start/stage/done`, live log pane (the terminal view, where the sudo password is typed), task-specific input panels (target IP, MAC, wireless room form, UniFi controller + SSH credentials with the password passed only as env), **explicit confirmation dialog before 10/14/000** (the dialog's "I understand" sets `--yes`; without it the task is not even queued), "Continue run" from the run browser (`--run-dir`), "Rebuild report" (`--build-report`), run browser refresh as each JSON lands.

Files: modify `lss-network-tools.sh` (§7.7 sites), `README.md` (non-interactive flags section), `ROADMAP.md`, `CLAUDE.md`; add `Sources/LSSCore/CLI/{RunTaskRequest.swift, ArgumentBuilder.swift, ProgressEvent.swift, ProgressLineParser.swift}`, `Sources/LSSNetworkTools/NewRun/*`, `Tests/LSSCoreTests/{ArgumentBuilderTests.swift, ProgressParserTests.swift (fixtures: captured @@LSS streams incl. interleaved human output and split chunks)}`.

Verification: `bash -n`; `sudo bash lss-network-tools.sh --run-task list`; `sudo … --run-task 1,3 --interface en0 --client Test --location Lab --note gui 2>progress.log` → exit 0, `progress.log` lines parse; `--run-task 10` without `--yes` → exit 4 and no run dir left behind; non-root → 5; bad interface → 2; interactive smoke (startup menu, Task 1, Save report) via the GUI terminal — behaviour unchanged; `make test`; screenshots `m3-new-run.png`, `m3-progress.png`, `m3-stress-consent.png`. Parallel subagents: bash contract vs Swift parser/UI once §7 is frozen.

Commits: `v1.2.249: add non-interactive --run-task/--build-report mode with @@LSS progress protocol (no interactive change)` then `macos: M3 New Run sheet, live progress, continue run`.

### M4 — Privilege, updates, distribution (risk: high — no signing identity on this Mac)

Scope: `LSSXPC` + `LSSHelper` (§8.2), `HelperClient`, `HelperInstaller` (SMAppService), Settings privilege section, `PrivilegeMode` fallback, `repairRunPermissions` button on 0600 files; CoreWLAN survey (§8.3); Sparkle (§9) with `SparkleController` and "Check for Updates…" menu; `make dmg`, `sign.sh` (identity from `CODESIGN_IDENTITY`, Team ID from `CODESIGN_TEAM_ID`), `notarize.sh` (`NOTARY_KEYCHAIN_PROFILE`), `release-appcast.sh`, entitlements, daemon plist, hardened runtime when signed.

Files: `Sources/LSSXPC/*`, `Sources/LSSHelper/{main.swift, HelperService.swift, ChildProcess.swift}`, `Sources/LSSCore/CLI/RequestValidator.swift`, `Sources/LSSNetworkTools/{Privilege/*, WiFi/*, Updates/*}`, `Resources/{LSSHelper-Info.plist.in, ie.lssolutions.lss-network-tools.helper.plist, *.entitlements}`, `scripts/{make-dmg.sh, notarize.sh, release-appcast.sh}`, `macos/appcast.xml`, `Tests/LSSCoreTests/RequestValidatorTests.swift`. No bash change.

Verification: `make test` (validator: path traversal, symlinks, non-root-owned script, bad flags, oversized scan file all refused); `make build` embeds helper + plist + framework (`codesign -dv --verbose=4`, `otool -L` shows `@rpath/Sparkle.framework`); `make run` → Settings → Register helper → System Settings approval → `launchctl print system/ie.lssolutions.lss-network-tools.helper`; run Task 1 via the helper with no password (if ad-hoc registration works on this Mac; otherwise the attempt and macOS's response are recorded in QUESTIONS.md and the sudo path stays default); Task 17 via CoreWLAN with the Location prompt; `make dmg` → `hdiutil verify`; `make sign`/`make notarize` print the clean skip message; `make appcast` produces a valid feed from a test key pair in `.build/`; screenshots `m4-settings-helper.png`, `m4-wifi-room.png`, `m4-updates.png`.

Commit: `macos: M4 privileged helper (SMAppService/XPC), CoreWLAN survey, Sparkle, dmg/sign/notarize scripts`.

### M5 — Hardening (risk: low)

Scope: `/code-review high` on the whole `macos/` diff and the bash diff; `/security-review` focused on the XPC helper, argument validation, root code paths and the bash NI dispatcher; fix findings; `macos/README.md` (build, run, test, sign, notarize, release, troubleshooting incl. Metal toolchain and Screen Recording); README.md "macOS GUI" section; CLAUDE.md `macos/` section finalised; `VERSION` → 1.0.0; open the PR `macos-gui` → `main`.

Commit: `macos: M5 hardening — review fixes, README, docs`; PR body summarises milestones, evidence paths and open questions.

---

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Swift 6 strict concurrency vs SwiftTerm/Sparkle ObjC APIs (non-Sendable delegates, main-thread assumptions) | Wrap in `@MainActor` classes / the `ProcessHost` actor; `@preconcurrency import` where needed; no `nonisolated(unsafe)` without a DECISIONS line |
| SwiftTerm Metal toolchain requirement | `build-app.sh` checks `xcrun metal --version` and prints the download command; README troubleshooting |
| SwiftTerm resource bundle missing at runtime (crash on `Bundle.module`) | Build script copies every SwiftPM `*.bundle` into `Contents/Resources`; M1 smoke launch catches it |
| Root-owned `output/`; GUI cannot write | By design the GUI never writes there; everything goes through the script |
| 0600 stress-test JSON in old runs | `.unreadable` state with guidance (M2); `repairRunPermissions` (M4); M0 fix for new files |
| pty + sudo password UX; re-prompts per process | One process per queue; clear banner in the log pane; M4 removes it |
| SMAppService without a Developer ID | Dev-mode requirement + audit-token path check; pty fallback stays default; QUESTIONS.md item; validator unit tests do not need registration |
| Sparkle with ad-hoc signature may refuse to install | Feed/EdDSA/download tested locally; install step verified after signing exists; Sparkle disabled when unkeyed |
| CoreWLAN TCC (Location) prompt, SSIDs redacted without it | Real `.app` via LaunchServices, usage strings, authorisation flow with timeout, explicit "Location denied" UI; stable signing recommended |
| Updater copies `macos/` once into `APP_ROOT` | Exclusion added in M1 (first CLI commit of the branch after M0); harmless one-time copy; GUI never relies on it |
| GitHub API rate limits | GUI makes no API calls; Sparkle feed served from raw.githubusercontent.com |
| macOS 14 minimum vs 27 SDK | `platforms: [.macOS(.v14)]` makes the compiler enforce availability; `@available` guards for anything newer |
| Screenshot automation | Primary: the app's `--screenshot <path>` flag renders its own window via `NSView.cacheDisplay` (no TCC needed) after the first layout pass, then quits. Fallback: `screencapture -l <windowID> -x` (window id via `CGWindowListCopyWindowInfo`), which needs Screen Recording permission for the invoking terminal — the script detects an all-wallpaper image and says so |
| Interactive regressions from M3 bash edits | All injections behind empty-by-default globals; `bash -n`; interactive smoke through the pty before commit; `--run-task` code in one new function; portability rules from CLAUDE.md (bash 3.2, `${arr[@]+…}`, no `mktemp` suffix) |
| Daemon context differences (no `SUDO_USER`, no tty, PATH) | Helper executes the wrapper (sets PATH), builds a clean env; Task 17 via `--wifi-scan-json`; Task 19 sshpass auto-install prints the hint instead of installing |
| PDF generation needs fpdf2 for the invoking Python | Always launch via the wrapper (Homebrew PATH); `pdf_failed` event surfaces the message |

---

## 12. Decisions taken for the owner (mirrored in QUESTIONS.md)

- Developer ID: none on this Mac. Taken: ad-hoc builds, sign/notarize skip, helper verified only as far as ad hoc allows, pty/sudo stays default. Needed: a Developer ID Application certificate + Team ID (`CODESIGN_IDENTITY`, `CODESIGN_TEAM_ID`, `NOTARY_KEYCHAIN_PROFILE`).
- Sparkle EdDSA key pair: not generated for real; feed disabled when `SPARKLE_PUBLIC_ED_KEY` is absent. Needed: run `generate_keys` once, store the private key outside the repo.
- GUI release tags `macos-vX.Y.Z` and the committed `macos/appcast.xml`.
- Bundle id `ie.lssolutions.lss-network-tools` (app) / `.helper`; the GUI gets a second Location Services entry next to `ie.lssolutions.wifi-scan`; `--uninstall` does not reset it.
- No bundled copy of the script; the app requires the CLI install.
- Run deletion / result editing excluded from the GUI (root-owned files).
- One room per invocation for Task 17 (append protocol).
- Fixtures: six real runs anonymised; stress files need a one-time `sudo --stage`; tasks 13–20 synthetic until real runs exist.
- Universal (arm64 + x86_64) release builds.
- The research bugs are fixed on this branch as M0 (v1.2.247) rather than on `main`, because the owner asked for `main` to stay untouched until the merge.
