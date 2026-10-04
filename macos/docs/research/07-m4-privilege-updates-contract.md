# 07 — M4 contract: privileged helper, CoreWLAN survey, Sparkle, distribution

Frozen before the M4 agents start. PLAN.md §8–§9 hold the decisions; this file pins the
concrete names, files, build-script behaviour and the ownership split. Deviations are
written back here in the same commit.

## 1. Targets and files (Package.swift — integrator)

| Target | Kind | Deps | Purpose |
|---|---|---|---|
| `LSSXPC` | library | Foundation | `@objc` XPC protocol + `Codable` request DTOs shared by app and helper |
| `LSSHelper` | executable | LSSXPC, LSSCore | the LaunchDaemon (`Contents/MacOS/LSSHelper`) |
| `LSSNetworkTools` | executable | + LSSXPC, Sparkle | the app |
| `LSSCoreTests` | tests | + LSSXPC | `RequestValidatorTests` |

Sparkle dependency: `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")`, product `Sparkle` (MIT; binary xcframework). The app links `@rpath/Sparkle.framework`; `build-app.sh` copies the framework from the SwiftPM artifacts directory into `Contents/Frameworks/` and adds the rpath `@executable_path/../Frameworks` (`-Xlinker -rpath` at link time or `install_name_tool -add_rpath`).

Bundle layout after `make build`:
```
LSS Network Tools.app/Contents/
  MacOS/LSSNetworkTools
  MacOS/LSSHelper                                  ← daemon, signed with identifier ie.lssolutions.lss-network-tools.helper
  Library/LaunchDaemons/ie.lssolutions.lss-network-tools.helper.plist
  Frameworks/Sparkle.framework
  Resources/*.bundle, AppIcon.icns
  Info.plist  (adds NSLocationWhenInUseUsageDescription, NSLocationUsageDescription, SUFeedURL, SUPublicEDKey?, SUEnableAutomaticChecks)
```
`sign.sh` signs inside-out: Sparkle's nested XPC services and Autoupdate/Updater → Sparkle.framework → LSSHelper (identifier above, `LSSHelper.entitlements`) → the app (`LSSNetworkTools.entitlements`, `--options runtime` whenever an identity is set; ad-hoc otherwise, still with the entitlements). `codesign -dv --verbose=4` of every piece is printed at the end of the build.

## 2. XPC protocol (Sources/LSSXPC — HELPER agent)

```swift
public let LSSHelperMachServiceName = "ie.lssolutions.lss-network-tools.helper"
public let LSSHelperProtocolVersion = 1

@objc public protocol LSSHelperProtocol {
    /// Runs the CLI with an allow-listed argv. `request` is JSON of `HelperRunRequest`.
    /// The helper dup2s `output` onto the child's stdout+stderr (one stream, like the pty),
    /// closes its copy, and replies when the child exits. `refusal` is non-nil when the
    /// validator rejected the request (nothing was run; exitCode = -1).
    func run(request: Data, output: FileHandle, reply: @escaping @Sendable (Int32, String?) -> Void)
    /// Sends SIGTERM (then SIGKILL after 5 s) to the child started by the run with this token.
    func cancel(token: String, reply: @escaping @Sendable (Bool) -> Void)
    /// chmod 0644 on regular *.json files directly inside one run directory under DATA_ROOT/output.
    func repairRunPermissions(runDirectory: String, reply: @escaping @Sendable (Int32, String?) -> Void)
    /// Helper build version (= macos/VERSION) and protocol version.
    func version(reply: @escaping @Sendable (String, Int) -> Void)
}

public struct HelperRunRequest: Codable, Sendable, Hashable {
    public var token: String                 // UUID chosen by the app, used by cancel()
    public var arguments: [String]           // argv AFTER the executable, exactly ArgumentBuilder's output
    public var sshPassword: String?          // → LSS_SSH_PASSWORD in the child environment only
    public var callerUID: UInt32?            // informational; the helper uses the audit token, never this
}
```

## 3. RequestValidator (Sources/LSSCore/CLI/RequestValidator.swift — HELPER agent; Foundation only, unit-tested)

```swift
public struct RequestValidator: Sendable {
    public struct Environment: Sendable { public var installEnvPath: String; public var fileManager: FileManager; … }   // injectable for tests
    public enum Refusal: Error, Hashable, Sendable, CustomStringConvertible {
        case installEnvUnreadable(String), executableNotRootOwned(String), executableWritable(String), executableIsSymlink(String),
             executableMissing(String), unknownFlag(String), missingValue(String), badValue(flag: String, value: String),
             duplicateFlag(String), runDirectoryOutsideOutput(String), scanFileOutsideAllowed(String), scanFileTooLarge(String),
             requestTooLarge, conflictingContext, noMode
        public var description: String
    }
    public struct Validated: Sendable, Hashable {
        public let executable: String        // INSTALL_WRAPPER_PATH (preferred) or APP_ROOT/lss-network-tools.sh
        public let arguments: [String]
        public let environment: [String: String]   // built from scratch: PATH (Homebrew first), HOME=/var/root, LANG, LC_ALL, TERM=dumb, LSS_QUIET_SPINNER=1, LSS_SSH_PASSWORD?
        public let runDirectory: String?
    }
    public init(environment: Environment = .live)
    public func validate(_ request: HelperRunRequest, callerUID: uid_t) throws -> Validated
    public func validateRepair(runDirectory: String) throws -> String   // canonical path
}
```
Rules (PLAN §8.2): the executable comes from `install.env` as read by the helper (never from the request); the wrapper and the script must be regular files, uid 0, mode without group/world write, not symlinks (checked with `lstat` + realpath). Grammar = `ArgumentBuilder.valueFlags` / `booleanFlags` only; exactly one of `--run-task` / `--build-report`; `--run-task` value `^(000|list|[0-9]{1,2}(,[0-9]{1,2})*)$` with ids 1–20; `--interface`/`--wifi-interface` `^[a-z][a-z0-9]{1,14}$`; `--target` IPv4 (`ArgumentBuilder.isValidIPv4`); `--mac` normalisable; `--controller-port` 1–65535; `--https`/`--ap-present` `y|n`; free text (`--client --location --note --prepared-by --building --floor --room --ap-label --controller --ssh-user`) `^[^\x00-\x1f\x7f]{1,120}$` and not starting with `-`; `--run-dir`/`--build-report`/`--output` must realpath to a child of `DATA_ROOT/output` (`--output` may also be a directory the calling user owns); `--wifi-scan-json` must realpath inside `~<callerUID>/Library/Application Support/ie.lssolutions.lss-network-tools/scans/`, be a regular file < 2 MB owned by the caller; no flag twice; total request < 64 KB.

## 4. Helper (Sources/LSSHelper — HELPER agent)

`main.swift`: `NSXPCListener(machServiceName:)`, delegate `HelperService`. In `listener(_:shouldAcceptNewConnection:)`:
1. `connection.setCodeSigningRequirement(requirement)` where `requirement` = `anchor apple generic and identifier "ie.lssolutions.lss-network-tools" and certificate leaf[subject.OU] = "<TEAMID>"` when `LSS_TEAM_ID` was baked in at build time (`build-app.sh` writes `Sources/LSSHelper/BuildConfig.swift` from `CODESIGN_TEAM_ID`; the file is git-ignored and a committed default has `teamID = nil`), else `identifier "ie.lssolutions.lss-network-tools"` plus the audit-token check: `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken])`, `SecCodeCheckValidity`, `SecCodeCopyPath` must resolve to the same `.app` bundle the helper runs from (`Bundle.main.bundleURL` of the helper → `../../..`). Log loudly (os_log) when running without a Team ID.
2. `exportedInterface = NSXPCInterface(with: LSSHelperProtocol.self)`; `exportedObject = HelperService()`; resume.
`HelperService.run`: decode → `RequestValidator.validate` → `ChildProcess` (posix_spawn with the validated environment, stdout/stderr = the received fd, stdin = /dev/null, new session) → wait → reply(exit status). SIGTERM → SIGKILL on cancel. `repairRunPermissions` as specified. The helper never reads the app's Defaults, never trusts paths from the app, and never executes anything but the validated executable.

## 5. App side (Sources/LSSNetworkTools/Privilege — HELPER agent)

```swift
enum PrivilegeMode: String { case helper, sudoTerminal }          // Defaults key `privilegeMode`, default .sudoTerminal until the helper is verified
@MainActor @Observable final class HelperInstaller { status: SMAppService.Status; register(); unregister(); openLoginItems(); refresh() }
@MainActor @Observable final class HelperClient { func version() async throws -> (String, Int); func run(_ req: HelperRunRequest, onOutput: @MainActor (Data) -> Void) async throws -> Int32; func cancel(token:) async; func repair(runDirectory:) async throws }
```
`RunCoordinator.start` chooses the path: `.helper` when `HelperInstaller.status == .enabled` and `version()` succeeds → `HelperClient.run` with a `Pipe`, bytes go through the same `ProgressLineParser` and are also fed to the terminal view (`feed(byteArray:)`) so the log pane looks identical; otherwise the pty+sudo path from M3. Settings → "Privileges" section: status text, Register / Unregister / Open Login Items, mode picker, a "Repair file permissions" button on runs with unreadable files (`RunDetailView` shows it next to the lock badge).

## 6. CoreWLAN survey (Sources/LSSNetworkTools/WiFi — UPDATES+WIFI agent)

`WiFiScanner` (@MainActor): `CLLocationManager` delegate flow (ignore the first `.notDetermined`, 60 s timeout, `requestWhenInUseAuthorization()`), `CWWiFiClient.shared().interface(withName:)` / default interface, `scanForNetworks(withSSID: nil)` falling back to `cachedScanResults()`, maps to the helper JSON shape **exactly**:
`[{ "ssid": String ("(hidden)" when nil), "bssid": String ("--" when nil), "rssi_dbm": Int?, "noise_floor_dbm": Int?, "channel": String, "band": "2.4GHz"|"5GHz"|"6GHz"|"", "channel_width": "20MHz"|"40MHz"|"80MHz"|"160MHz"|"", "phy_mode": "--", "security": "--" }]`
(mirror `build_wifi_scan_helper_macos` in the bash script for the exact band/width mapping). Writes to `~/Library/Application Support/ie.lssolutions.lss-network-tools/scans/<uuid>.json` (0600) and returns the URL for `RunTaskRequest.WirelessRoom.scanJSON`. The Task 17 panel in the New Run sheet gets a "Scan this room" button showing the network count/strongest RSSI after scanning; the run then passes `--wifi-scan-json`. Authorization denied → explanation + "Open Privacy Settings". Info.plist: `NSLocationWhenInUseUsageDescription`, `NSLocationUsageDescription`; entitlement `com.apple.security.personal-information.location`.

## 7. Sparkle (Sources/LSSNetworkTools/Updates — UPDATES+WIFI agent)

`SparkleController` wraps `SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil)`; `enabled` = `Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey")` is a non-empty string. Menu "Check for Updates…" (app menu / Help) disabled with help text "Updates are not configured in this build" when disabled. Settings → "Updates" section: feed URL, automatic checks toggle (`SUEnableAutomaticChecks`, Sparkle's own setting), last check, "Check now". Info.plist keys: `SUFeedURL = https://raw.githubusercontent.com/lssolutions-ie/lss-network-tools/main/macos/appcast.xml`, `SUPublicEDKey` injected from `$SPARKLE_PUBLIC_ED_KEY` by `build-app.sh` (omitted when unset → `SUEnableAutomaticChecks = false`). GUI release tags `macos-vX.Y.Z`; asset `LSS-Network-Tools-X.Y.Z.dmg`.

## 8. Distribution scripts (integrator; already written)

* `scripts/make-dmg.sh [app] [out.dmg]` — staging dir + `Applications` symlink → `hdiutil create … UDZO` → `hdiutil verify`, prints the sha256. `make dmg`.
* `scripts/notarize.sh <dmg|app>` — `xcrun notarytool submit --wait` with `NOTARY_KEYCHAIN_PROFILE` (or `NOTARY_APPLE_ID`/`NOTARY_TEAM_ID`/`NOTARY_PASSWORD`), then `xcrun stapler staple`; exits 0 with a clear "skipped" line when no credentials are set. `make notarize` = notarize the app → dmg → notarize the dmg.
* `scripts/release-appcast.sh [dist dir]` — uses Sparkle's `generate_appcast` (from the SwiftPM artifact `bin/` directory when present, else the pinned release tarball matching `Package.resolved`, sha256 from `SPARKLE_TOOLS_SHA256` when set) with `SPARKLE_PRIVATE_KEY_FILE`; writes `macos/appcast.xml`; skipped cleanly when the key is unset. `make appcast`.
* `scripts/sign.sh` gains the inside-out order of §1; identity `CODESIGN_IDENTITY`, Team ID `CODESIGN_TEAM_ID`.

## 9. Verification (M4)
`make test` (validator tests: traversal, symlink, non-root script, writable script, unknown flag, bad values, oversized scan, run-dir outside output; all refused); `make build` → `codesign -dv --verbose=4` for app, helper, framework; `otool -L` shows `@rpath/Sparkle.framework`; `plutil -lint` on the daemon plist; `make run` → Settings → Register helper → record macOS's response (`launchctl print system/ie.lssolutions.lss-network-tools.helper`) — ad-hoc registration may be refused: record the exact outcome in QUESTIONS.md; Task 17 "Scan this room" → Location prompt → JSON written; `make dmg` → `hdiutil verify`; `make notarize`/`make appcast` print the clean skip. Screenshots: `m4-settings-privileges.png`, `m4-wifi-room.png`, `m4-updates.png`.

## 10. Ownership
* Integrator (before the agents start): Package.swift targets + Sparkle dep, `build-app.sh`/`sign.sh` embedding and signing, Info.plist.in keys, Resources (daemon plist, entitlements), scripts of §8, Makefile targets, LSSXPC/LSSHelper compiling stubs, docs.
* HELPER agent: §2–§5 (LSSXPC, LSSHelper, RequestValidator + tests, Privilege/*, RunCoordinator helper path, Settings privileges section, repair button).
* UPDATES+WIFI agent: §6–§7 (WiFi/*, Updates/*, Task 17 panel changes in NewRun, Settings updates section, menu item).
