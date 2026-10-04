# Research: installation layout, update system and Wi-Fi helper

Gathered 2026-10-03 from `lss-network-tools.sh` v1.2.246 (HEAD 474e45d) and `install.sh`, plus the live install on the development Mac (which runs v1.2.245). Line numbers refer to that commit.

## 1. Installation

### 1.1 install.sh paths (macOS)

| Variable | Value | Source |
|---|---|---|
| `APP_TARGET_DIR` | `${LSS_INSTALL_APP_DIR:-/usr/local/share/lss-network-tools}` | `detect_os()` L239-257 |
| `DATA_TARGET_DIR` | `${LSS_INSTALL_DATA_DIR:-$APP_TARGET_DIR}` (same dir as app on macOS) | L244 |
| `WRAPPER_PATH` | `${LSS_INSTALL_WRAPPER_PATH:-/usr/local/bin/lss-network-tools}` | L12 |
| `AUDIT_LOG_PATH` | `$DATA_TARGET_DIR/install-audit.log` | L245 |
| Linux | app `/usr/local/lib/lss-network-tools`, data `/var/lib/lss-network-tools` | L249-250 |

Run order: `detect_os` → `require_root` → `check_source_version_freshness` → `install_dependencies` → `prepare_target_directories` (creates `output`, `raw`, `tmp`) → `deploy_application_files` → `write_wrapper` → `write_completions` → `build_wifi_scan_helper` → `print_install_summary`.

Deployed files: `lss-network-tools.sh` (755), `install.sh` (755), `README.md`, `generate_pdf_report.py`, `generate_pdf_compare_report.py`, `assets/` (recursive copy), then `install.env`.

`install.env` (live, verbatim):
```
APP_ROOT="/usr/local/share/lss-network-tools"
DATA_ROOT="/usr/local/share/lss-network-tools"
INSTALL_WRAPPER_PATH="/usr/local/bin/lss-network-tools"
```

Wrapper `/usr/local/bin/lss-network-tools` (live, verbatim):
```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
exec "/usr/local/share/lss-network-tools/lss-network-tools.sh" "$@"
```

Brew runs as `SUDO_USER` via `run_macos_user_shell` (`sudo -u $BREW_USER env HOME=... PATH=... bash --noprofile --norc -lc "$cmd"`). Required brew formulae: nmap, jq, speedtest-cli, tcpdump, python3. Optional: `hudochenkov/sshpass/sshpass`, `arp-scan`. scapy and fpdf2 via `pip3` as the brew user. `LSS_SKIP_DEPS=1` skips dependencies; `LSS_SKIP_FRESHNESS_CHECK=1` skips the version check.

Completions: `bash $APP_TARGET_DIR/lss-network-tools.sh --write-completions` → `/usr/local/share/zsh/site-functions/_lss-network-tools` (fallback `~$SUDO_USER/.zsh/completions/`) and `/usr/local/etc/bash_completion.d/lss-network-tools`.

Wi-Fi helper step in install.sh gates on `command -v swiftc` (always true on stock macOS; the real check is inside the main script) and sets `LSS_BUILD_WIFI_HELPER=1`, which the main script never reads.

### 1.2 configure_runtime_paths() (main script L99-143)

Defaults: `APP_ROOT=DATA_ROOT=$SCRIPT_DIR`, `TMP_ROOT=$SCRIPT_DIR/tmp`, `INSTALL_MODE=portable`, `OUTPUT_DIR=$SCRIPT_DIR/output`. `SCRIPT_DIR` is the real script's directory because the wrapper `exec`s its absolute path.

- If `$SCRIPT_DIR/install.env` exists: source it; `INSTALL_MODE=installed`; `TMP_ROOT=$DATA_ROOT/tmp`, `OUTPUT_DIR=$DATA_ROOT/output`, `PROGRAM_DEFAULTS_FILE=$DATA_ROOT/program-defaults.json`; `return 0`.
- Else on macOS: installed only if `SCRIPT_DIR == /usr/local/share/lss-network-tools`, otherwise portable.
- `ensure_runtime_directories`: `mkdir -p $OUTPUT_DIR $TMP_ROOT $DATA_ROOT/raw`; `export TMPDIR=$TMP_ROOT`.
- `--version`, `--build-wifi-helper`, `--write-completions`, `--install-deps` exit before `configure_runtime_paths` (except `--build-wifi-helper`, which calls it). `--uninstall`/`--update` run after `ensure_runtime_directories`.
- `--version` prints exactly `lss-network-tools vX.Y.Z`.

### 1.3 Live install (`/usr/local/share/lss-network-tools`)

Everything is `root:wheel`, files 644, dirs 755, `ubiquiti-oui-cache.txt` 600. Contains repo-only leftovers (`.github/`, `CLAUDE.md`, `legacy/`, `ROADMAP.md`, `unifi-discover.nse`) from older updaters; the current updater excludes them. `output/` has 6 real runs.

**GUI consequence:** the tree is root-owned. A GUI running as the user can read outputs but cannot write/delete in `output/`, change `program-defaults.json`, build the helper, or read the OUI cache without elevation.

## 2. Update system

### 2.1 check_for_updates() (L923-977)

Installed mode only. `latest_remote_tag_from_github` does `curl -fsSL --connect-timeout 10 --max-time 15 -H @<0600 header file>` against `/repos/<repo>/tags?per_page=100`, keeps tags matching `^v[0-9]+\.[0-9]+\.[0-9]+$`, picks highest via `sort -V`. Token from `GITHUB_TOKEN` or `gh auth token` (run as `SUDO_USER`). If remote is not strictly newer: `_LSS_STATUS_MSG="Software is up to date"`. Otherwise `perform_installed_update`.

### 2.2 perform_installed_update() (L758-921)

1. `read -r -p "Install update <tag>? [y/N]"` on stdin.
2. Download zipball to `mktemp /tmp/lss-network-tools-update-zip-XXXXXX`; extract into `mktemp -d /tmp/lss-network-tools-update-XXXXXX`.
3. Write helper to `/tmp/lss-network-tools-apply-update-XXXXXX`; `exec bash "$helper_script"`.

Preserved names (macOS): `output`, `raw`, `tmp`, `install.env`, `assets`, `program-defaults.json`, `install-audit.log`, `ubiquiti-oui-cache.txt`, `LSS-WiFiScan.app`, `LSS-WiFiScan.app.version`. Linux: `install.env`, `assets`.

Helper sequence: verify payload (`lss-network-tools.sh` present, `--version` equals tag, `install.env` present in DEST) → `find DEST -mindepth 1 -maxdepth 1 <preserve> -exec rm -rf {} +` (**deletes every other top-level entry, including dotfiles**) → copy every top-level zipball item except `assets legacy .github .gitignore CLAUDE.md ROADMAP.md __pycache__` → `--install-deps` → merge assets without overwrite → `--build-wifi-helper` → `--write-completions` → verify version → audit log → `echo tag > $DATA_DIR/.lss-last-update` → `exec "$INSTALL_WRAPPER_PATH"` (or `exec sudo ...` if not root). **It relaunches the interactive TUI even when started with `--update`.**

### 2.3 Marker and startup banner

- `startup_menu()` reads first line of `$DATA_ROOT/.lss-last-update`, deletes the file, sets `_LSS_STATUS_MSG="Updated successfully to vX"` if it is a valid tag.
- Startup quick check (after traps): `curl --max-time 2` to `/tags?per_page=10` (no auth), `sort -V | tail -1`, banner only if strictly newer: `[UPDATE AVAILABLE] vX is available (you have vY) — select option 3 to update`.

### 2.4 Rules the GUI must respect

1. Store nothing in `APP_ROOT` except under preserved names; GUI state belongs in `~/Library/Application Support/<gui bundle id>/`.
2. **A new top-level repo directory (e.g. `macos/`) WILL be copied into `APP_ROOT` by the first CLI update because the exclusion list lives in the OLD script's heredoc.** The new script's heredoc must exclude `macos` so that subsequent updates clean it up; the first update after shipping the directory will copy it once (harmless but untidy) and the following update removes it. Alternative: ship the GUI only via its own release asset and keep `macos/` excluded.
3. Never rename or remove `install.env`.
4. Do not delete `$DATA_ROOT/.lss-last-update`; only read it.
5. Driving `--update` from a GUI: feed `y\n`, watch for `Update applied successfully. Installed Version: vX`, then the process `exec`s into the TUI (as root) — terminate it or send menu option 6; verify with `--version`.
6. Keep `LSS-WiFiScan.app` with bundle id `ie.lssolutions.wifi-scan`; `--uninstall` resets TCC for that id only.

## 3. Wi-Fi helper (LSS-WiFiScan.app)

- `_LSS_WIFI_HELPER="/usr/local/share/lss-network-tools/LSS-WiFiScan.app"` is hard-coded (ignores APP_ROOT / portable mode). Version cache `${_LSS_WIFI_HELPER}.version` holds `APP_VERSION`; rebuilt when it differs.
- Toolchain check: `xcode-select -p` then `xcrun --find swiftc`.
- `Info.plist`: `CFBundleIdentifier ie.lssolutions.wifi-scan`, `CFBundleName LSS Network Tools`, `CFBundleDisplayName LSS Network Tools - WiFi Scan`, `CFBundleExecutable LSS-WiFiScan`, `CFBundleIconFile AppIcon`, `CFBundleVersion 1`, `CFBundleShortVersionString 1.0`, `NSLocationWhenInUseUsageDescription "LSS Network Tools requires location access to read Wi-Fi network names (SSIDs) during wireless site surveys."`, `NSPrincipalClass NSApplication`. No `LSUIElement` (shows Dock icon, activates).
- Icon from `assets/wifi-scan-icon.png` via `sips` + `iconutil`.
- Swift source: argv[1] interface ("" = all), argv[2] result path. `writeResult` uses `atomically: false` (sticky /tmp). Authorization: authorized → scan; denied/restricted → `[]`; else `requestWhenInUseAuthorization()`; in the delegate `.notDetermined` keeps waiting. Scan: `scanForNetworks(withSSID: nil)` falling back to `cachedScanResults()`.
- Output: JSON array of `{ssid ("(hidden)" if nil), bssid ("--" if nil), rssi_dbm (null if 0), noise_floor_dbm (null if 0), channel (string), band ("2.4GHz"/"5GHz"/"6GHz"/""), channel_width ("20MHz".."160MHz"/""), phy_mode "--", security "--"}`. Denied permission and "no networks" are indistinguishable (`[]`).
- Compile: `swiftc LSS-WiFiScan.swift -o .../Contents/MacOS/LSS-WiFiScan -framework Foundation -framework AppKit -framework CoreLocation -framework CoreWLAN`; `codesign --force --sign -` (ad hoc, no entitlements, no hardened runtime).
- Run (`run_wifi_scan_helper_macos`): `tmp_result=$(mktemp /tmp/lss-wifi-result-XXXXXX)`, `chmod 666`; as root with `SUDO_USER`: `sudo -u $SUDO_USER open -n -W <app> --args <iface> <tmp_result> &`; bounded 90 s wait; `pkill -f .../LSS-WiFiScan` on timeout; reads result or `[]`.
- Fallbacks when helper not executable: inline Python using `airport -s` (gone on modern macOS) or `system_profiler SPAirPortDataType -json` dropping to `SUDO_USER` uid (returns no data as root), `bssid "--"`.

### 3.1 Doing the CoreWLAN scan in the GUI

- Must run as the logged-in user, inside a real `.app` launched via LaunchServices, with `NSLocationWhenInUseUsageDescription` (add `NSLocationUsageDescription` too).
- Sign stably: TCC ties the grant to the designated requirement; ad-hoc signatures change per build and can re-prompt. Developer ID or Apple Development signing preferred.
- Entitlements with hardened runtime: `com.apple.security.personal-information.location`. Sandbox + CoreWLAN scanning is unverified; an unsandboxed Developer ID app is safest.
- Reproduce the authorization flow (ignore the first `.notDetermined`) with a timeout.
- The GUI bundle id gets its own TCC entry; CLI `--uninstall` will not reset it.
- Alternative avoiding a second TCC entry: the GUI (already the user) runs the existing helper with `open -n -W .../LSS-WiFiScan.app --args <iface> <user-writable result path>`; no root needed to run it, root needed to (re)build it.

## 4. Program defaults

`$DATA_ROOT/program-defaults.json` (root 644, preserved). Live: `{"unifi_domain":"unifi.lssolutions.ie","unifi_port":"8080","unifi_https":"n"}` — all strings. `get_program_default key fallback`; `set_program_default key value` (validates object, mktemp + mv). Consumer: Task 19.

## 5. Run directory layout

`OUTPUT_DIR=/usr/local/share/lss-network-tools/output`.

- Run dir: `$OUTPUT_DIR/{client-slug}-{location-slug}-{dd-mm-yyyy}[-{note-slug}]`; slugs via `sanitize_for_filename` (lowercase, `[^a-z0-9._-]`→`-`, collapsed, empty→`unknown`). Existing dir → suffix `-{HH-MM}`, then `-{HH-MM}-2`, `-3`, …
- `RUN_REPORT_FILE=$RUN_OUTPUT_DIR/lss-network-tools-report-{client}-{location}-{dd-mm-yyyy}-{HH-MM}.txt` (note not included).
- `debug.txt`, `manifest.json`, `raw/` under the run dir. Live session log: `$OUTPUT_DIR/.debug-session-$$.txt` (tee of all stdout+stderr; tailable). `finalize_run` copies it to `debug.txt`.
- Task JSON: `<file from TASKS_DATA>`; multi-entry tasks (10, 13, 14, 15, 16) use `<base>-device-N.json`.
- Written while building the TXT report: `findings.json`, `remediation.json`.
- PDF: `${RUN_REPORT_FILE%.txt}.pdf`; `python3 $APP_ROOT/generate_pdf_report.py <run_dir> <app_root> <pdf_path> <prepared_by>`; needs `manifest.json`, `$APP_ROOT/assets/logo.png`, fonts from `assets/fonts` next to the script.
- Compare PDF: `<export_dir>/lss-compare-{dd-mm-yyyy-HH-MM}.pdf`, default `~SUDO_USER/Desktop`.
- `finalize_run` order: TXT (+findings/remediation) → copy debug log → `write_manifest_for_current_run`. Manifest is written **before** the PDF, so the PDF is never in `artifacts[]`.
- Manifest keys: `generated_at, client, location, note, prepared_by, run_directory, selected_interface, report_file (basename), debug_file, tasks[] {task_id, title, json_file, json_present, json_files[], raw_prefix}, artifacts[] {path, type (json|text|other)}`.
- "Save report? N" at the end of a run **deletes the run directory**.

Raw artifacts in `raw/`:

| Task | Files |
|---|---|
| 2 | `internet-speed-test-raw.txt` |
| 3 | `gateway-scan-nmap.grep` |
| 4 | `dhcp-scan-attempt-NN.txt`, `dhcp-scan-tcpdump-NN.txt` |
| 6-9 | `{dns-scan,ldap-ad-scan,smb-nfs-scan,print-server-scan}-nmap.grep` |
| 10/14 | `<prefix>-device-N-{baseline,jitter,large-packet,sustained,recovery}.txt`, `-ramping-{64,256,512,1024,1400}.txt` |
| 11 | `task-11-tagged-frames.txt`, `task-11-cdp-lldp.txt`, `task-11-tagged.pcap`, `task-11-cdp-lldp.pcap` |
| 12 | `duplicate-ip-arp-scan.txt` |
| 13 | `custom-target-port-scan-device-N-nmap.grep` |
| 15 | `custom-target-identity-scan-device-N-{discovery,arp,services}.txt` |
| 16 | `custom-target-dns-assessment-device-N-{udp,tcp,ptr,version-bind}.txt` |

**Recommendation:** locate reports with `manifest.json → report_file` and swap `.txt` for `.pdf`; never reconstruct the timestamp.

### 5.1 Regression found: report export directory ignored (v1.2.246)

`build_report_for_run_dir` sets `RUN_REPORT_FILE="$export_dir/lss-network-tools-report-<rundir>-HH-MM.txt"` (default: invoking user's Desktop). `build_report_for_current_run` then overwrites it whenever the path is **not** under `$RUN_OUTPUT_DIR/` (condition inverted in v1.2.246), so "Build A Report" writes the TXT/PDF into the run directory instead of the chosen export directory. Fix on `main`: regenerate only when `RUN_REPORT_FILE` is empty or points inside `OUTPUT_DIR` but not inside the current `RUN_OUTPUT_DIR` (a stale run path).
