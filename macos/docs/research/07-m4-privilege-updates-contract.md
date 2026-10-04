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
Rules (PLAN §8.2): the executable comes from `install.env` as read by the helper (never from the request); the wrapper and the script must be regular files, uid 0, mode without group/world write, not symlinks (checked with `lstat` + realpath). Grammar = `ArgumentBuilder.valueFlags` / `booleanFlags` only; exactly one of `--run-task` / `--build-report`; `--run-task` value `^(000|list|[0-9]{1,2}(,[0-9]{1,2})*)$` with ids 1–20; `--interface`/`--wifi-interface` `^[a-z][a-z0-9]{1,14}$`; `--target` IPv4 (`ArgumentBuilder.isValidIPv4`); `--mac` normalisable; `--controller-port` 1–65535; `--https`/`--ap-present` `y|n`; free text (`--client --location --note --prepared-by --building --floor --room --ap-label --controller --ssh-user`) `^[^\x00-\x1f\x7f]{1,120}$` and not starting with `-`; `--run-dir`/`--build-report`/`--output` must each pass the same run-directory rule — a real, root-owned, non-group/world-writable directory directly inside `DATA_ROOT/output`, reached without symlinks (`--output` is **not** allowed to name a caller-owned folder: the report file names are predictable and bash `>` / fpdf `output()` follow a planted symlink, so a root child writing there could be redirected); `--wifi-scan-json` must realpath inside `~<callerUID>/Library/Application Support/ie.lssolutions.lss-network-tools/scans/`, be a regular file < 2 MB owned by the caller; no flag twice; total request < 64 KB.

## 4. Helper (Sources/LSSHelper — HELPER agent)

`main.swift`: `NSXPCListener(machServiceName:)`, delegate `HelperService`. In `listener(_:shouldAcceptNewConnection:)`:
1. `connection.setCodeSigningRequirement(requirement)` where `requirement` = `anchor apple generic and identifier "ie.lssolutions.lss-network-tools" and certificate leaf[subject.OU] = "<TEAMID>"` when the helper's **own** signature carries a Team ID (read at launch with `SecCodeCopySelf` + `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier`; no build-time injection needed — a Developer ID build of the bundle signs the helper with the same team). Without a Team ID (ad-hoc builds) the requirement degrades to `identifier "ie.lssolutions.lss-network-tools"` plus the audit-token check: `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken])`, `SecCodeCheckValidity`, `SecCodeCopyPath` must resolve to the same `.app` bundle the helper runs from (helper executable → `../..` is `Contents` → the `.app`). Log loudly (os_log) when running without a Team ID.
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

* `scripts/make-dmg.sh [app] [out.dmg]` — refuses a non-release app (reads `.build-config` written by `build-app.sh`; `LSS_DMG_ALLOW_DEBUG=1` overrides), staging dir + `Applications` symlink → `hdiutil create … UDZO` → `hdiutil verify` → `codesign` of the image when `CODESIGN_IDENTITY` is set, prints the sha256. `make dmg` builds the universal release first.
* `scripts/notarize.sh <dmg|app>` — `xcrun notarytool submit --wait --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"` (the only accepted credential: a password on the command line would be visible in `ps`), then `xcrun stapler staple`; exits 0 with a clear "skipped" line when the profile or `CODESIGN_IDENTITY` is unset. `make notarize` = universal release → notarize the app → dmg → notarize the dmg.
* `scripts/release-appcast.sh [dist dir]` — uses Sparkle's `generate_appcast` from PATH or from the checksum-verified SwiftPM artifact (`swift package resolve` fetches it); no download tier. Signs with `SPARKLE_PRIVATE_KEY_FILE`, rewrites enclosure URLs to the `macos-vX.Y.Z` release, writes `macos/appcast.xml`, warns when an enclosure is unsigned (release built without `SPARKLE_PUBLIC_ED_KEY`); skipped cleanly when the key is unset. `make appcast`.
* `build-app.sh` validates `VERSION` (`x.y.z`), derives `CFBundleVersion = major·1000000 + minor·1000 + patch`, resolves the products directory with `swift build --show-bin-path` (debug and universal release), strips build-directory rpaths from both binaries, and records `release universal` / `debug arm64` in `app/.build-config`.
* `scripts/sign.sh` gains the inside-out order of §1; identity `CODESIGN_IDENTITY`, Team ID `CODESIGN_TEAM_ID`.

## 9. Verification (M4)
`make test` (validator tests: traversal, symlink, non-root script, writable script, unknown flag, bad values, oversized scan, run-dir outside output; all refused); `make build` → `codesign -dv --verbose=4` for app, helper, framework; `otool -L` shows `@rpath/Sparkle.framework`; `plutil -lint` on the daemon plist; `make run` → Settings → Register helper → record macOS's response (`launchctl print system/ie.lssolutions.lss-network-tools.helper`) — ad-hoc registration may be refused: record the exact outcome in QUESTIONS.md; Task 17 "Scan this room" → Location prompt → JSON written; `make dmg` → `hdiutil verify`; `make notarize`/`make appcast` print the clean skip. Screenshots: `m4-settings-privileges.png`, `m4-wifi-room.png`, `m4-updates.png`.

## 10. Ownership
* Integrator (before the agents start): Package.swift targets + Sparkle dep, `build-app.sh`/`sign.sh` embedding and signing, Info.plist.in keys, Resources (daemon plist, entitlements), scripts of §8, Makefile targets, LSSXPC/LSSHelper compiling stubs, docs.
* HELPER agent: §2–§5 (LSSXPC, LSSHelper, RequestValidator + tests, Privilege/*, RunCoordinator helper path, Settings privileges section, repair button).
* UPDATES+WIFI agent: §6–§7 (WiFi/*, Updates/*, Task 17 panel changes in NewRun, Settings updates section, menu item).

## 11. As implemented (write-back after M4 and the M5 reviews)

Where the code differs from §2–§7 above, the code is right and this list is the contract:

* **Protocol** (`LSSXPC`): methods are `run(request:output:reply:)`, `cancel(token:reply:)`, `repairRunPermissions(runDirectory:reply:)`, `version(reply:)`; `LSSHelperBuildVersion` (kept equal to `macos/VERSION`, now checked by a test), `LSSHelperCodeIdentifier`, and `LSSCodeRequirement` (requirement strings for both ends). A child killed by a signal reports `128 + signal`; the repair reply is the number of files changed.
* **Caller validation** (`CallerValidation.swift`): the Team ID is read from the helper's **own** signature at launch; with one, the requirement is the Developer-ID anchor + app identifier + team; without one (ad-hoc), the requirement is `identifier "<app>" and cdhash H"<cdhash of the enclosing .app>"` plus the pid-based same-bundle check. The connecting user must be a member of the **admin** group (`mbr_check_membership`, fail closed) — the helper is a password-less replacement for `sudo`, so it keeps sudo's rule. Each connection gets its own exported object carrying the caller's uid.
* **Validator** (`RequestValidator` in LSSCore): entry points `validate(arguments:sshPassword:callerUID:)` and `validate(requestJSON:callerUID:)` (the `HelperRunRequest` decoding lives in LSSHelper); extra refusal `malformedRequest`; `install.env` itself must be root-owned, not writable, not a symlink, and `APP_ROOT` must be its directory; the wrapper is used only if it exists and `exec`s exactly the checked script; run directories must be directly inside a root-owned, non-world-writable `output/`; `--build-report` accepts only `--prepared-by --output --no-pdf --debug`; **`--output` is accepted only when it is a run directory** (the caller-owned branch of §3 was a symlink-following root write and was removed); every executable, `install.env`, `DATA_ROOT/output` and every tool the engine will run as root must sit under root-owned, non-group/world-writable ancestors, and the tools the engine needs (`nmap jq python3 tcpdump speedtest-cli`, optional `arp-scan sshpass`) must resolve through the child's PATH to root-owned, non-writable binaries — otherwise the run is refused with `untrustedToolchain` and the app offers the sudo route (a user-owned Homebrew prefix is the common case; see QUESTIONS.md).
* **Helper runtime**: the Wi-Fi scan file is copied into a root-only directory before the engine reads it; children end when the app disconnects; at most four concurrent runs; the helper exits after 60 s idle; `LSS_PROGRESS_TOKEN` (per-run secret from the app) is placed in the child environment so events are `@@LSS <token> {…}`.
* **App side**: `PrivilegeMode` defaults to `.sudoTerminal`; the helper is used only when the mode is `.helper` **and** the helper answered `version()` with the right protocol version; Settings → Privileges hosts Register / Unregister / Open Login Items / Check Again and the mode picker; `--helper-status` / `--register-helper` automation flags. Runs that need `LSS-WiFiScan.app` (Task 17 without a CoreWLAN scan) never take the helper route.
* **Survey**: empty SSID/BSSID get the `(hidden)`/`--` placeholders like nil; one interface is scanned (the run's when it is Wi-Fi, else CoreWLAN's default) and `--wifi-interface` records it; scan files are pretty-printed, strongest first, deleted after 7 days; `--wifi-autoscan` automation flag.
* **Updates**: `SparkleController.shared` is created by the App struct; nothing starts without `SUPublicEDKey`.

### 11.1 Precise rules of the M5 fixes (as implemented)

* **Admin rule** — `AdminGroupMembership` (LSSXPC, shared by helper and app, unit-tested): `mbr_uid_to_uuid` / `mbr_gid_to_uuid(80)` / `mbr_check_membership`, resolved from libSystem with `dlsym` (the `<membership.h>` symbols are not in the Darwin module); any error is `.failed` and the connection is refused like a non-member. `HelperService.listener` applies it after `CallerValidation.accept`, on `connection.effectiveUserIdentifier`, and logs the uid; the app cannot tell this refusal from an unregistered helper (the connection is simply invalidated), so `HelperClient.ClientError.connection`'s text states the rule (`AdminGroupMembership.refusalExplanation`). `HelperService.init` takes `membershipCheck:` and `acceptCallerOverride:` only for out-of-process probes; `main.swift` uses the defaults.
* **Tool-chain rule** — `RequestValidator.checkToolchain`, run after every other rule and before `Validated` is returned. Effective search order = `effectiveSearchPath(prefix: Environment.engineSearchPathPrefix, childPATH:)` = `standardEngineSearchPathPrefix` (`/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin`, what `ensure_standard_path` prepends on macOS) followed by the child PATH entries, each folder once. (1) Every *existing* folder on that order, plus every component on the way to it (given spelling and `realpath`), must be root-owned and — symlinks excepted — not group/world writable; a folder behind the match counts too. (2) `requiredTools` = `nmap jq python3 tcpdump speedtest-cli`: the **first existing entry** on the order (whatever its kind) is the match and must resolve, with every component root-owned and non-writable, to a regular file with an execute bit. (3) `optionalTools` = `arp-scan sshpass`: same rule, only when an entry exists. (4) A required tool found nowhere is refused too (`path` empty; the engine would exit 3). Refusal: `untrustedToolchain(tool:path:reason:)` with `tool == RequestValidator.searchPathLabel` ("search path") for case (1); reasons are `is owned by uid N, not root`, `is writable by group or others`, `does not exist`, `is not a directory`, `is not a regular executable file`, `is not an absolute path`, prefixed with `passes through X, which …` / `resolves to X, which …` when the offending component is not the entry itself. Description: `The privileged helper does not run tools a non-root user can modify (<tool>: <path> <reason>). Use “sudo in the terminal pane” in Settings → Privileges or make the tool chain root-owned.`
* **Ancestor rule** — `untrustedAncestor(ancestor:of:reason:)`: every folder above `install.env`, the script, the wrapper and the canonical `DATA_ROOT/output` must be root-owned and not group/world writable (`checkAncestors`, same component walk). Checked after the entry's own checks, so the existing refusals keep precedence.
* **Progress token** — `HelperRunRequest.progressToken: String?` (Codable, optional, so older JSON decodes); `RequestValidator.validate(arguments:sshPassword:progressToken:callerUID:)` refuses a value outside `^[A-Za-z0-9_-]{8,64}$` (`isValidProgressToken`, = `ProgressLineParser.isValidToken`) with `badValue(flag: "LSS_PROGRESS_TOKEN", value: "(hidden)")` and otherwise places it in the child environment as `LSS_PROGRESS_TOKEN`; `secretEnvironmentKeys` (`LSS_SSH_PASSWORD`, `LSS_PROGRESS_TOKEN`) are never logged or printed. The engine (`noninteractive_setup`) copies and unsets the variable and writes `@@LSS <token> {json}`. `ProgressLineParser(token:)`: with a token only `@@LSS <token> {…}` (exactly one space each side) is an event; any other `@@LSS ` line is counted in `rejectedLineCount` and delivered as a human line; `malformedLineCount` keeps its meaning (tokened line, bad JSON). `token == nil` keeps the untokened grammar (fixtures, `2>progress.log` users; a tokened line is then malformed). `ProgressLineParser.makeToken()` = 32 lower-case hex characters from `SystemRandomNumberGenerator`. `RunCoordinator.start/buildReport` make one token per run, build the parser with it, and pass it as `environment["LSS_PROGRESS_TOKEN"]` + `sudo --preserve-env=LSS_PROGRESS_TOKEN[,LSS_SSH_PASSWORD]` on the terminal route, or `HelperRunRequest.progressToken` on the helper route. `simulate()` stays untokened.
* **Fail-closed client** — `HelperClient.currentConnection()` throws `ClientError.untrustedHelperRequirement` when `LSSCodeRequirement.helper(teamIdentifier:)` returns nil or `SecRequirementCreateWithString` fails; no `NSXPCConnection` is created. `cancel(token:)` then returns false.
* **Cancel semantics** — `RunCoordinator.cancel()` ends the run itself (`.finished(.interrupted)`) whenever nothing can receive a signal: helper version check in flight, the terminal route's settle window (the deferred launch is a `launchTask`, cancelled and guarded on `phase == .launching && !cancelRequested && generation == captured`), or no running pty process. `start()` and `buildReport()` cancel an active run first (while the helper token is still known), then `reset()`. Task 17 without `wireless.scanJSON` never takes the helper route: warning `task_17_needs_sudo`, terminal route.
* **Helper limits** — at most 4 runs in total and 2 per connecting uid (`maximumRunsPerCaller`); idle exit after 60 s unchanged. Logs carry the executable, argument count and flag *names* (`acceptedFlags` members) and which secret keys are set — never a value, the password or the token; refusals log the code only.
* **Version test** — `VersionConsistencyTests` asserts `LSSHelperBuildVersion == trim(macos/VERSION)`.
