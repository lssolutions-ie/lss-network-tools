# lss-network-tools — Claude Reference

This file is read by Claude at the start of every session. It covers architecture, patterns, and conventions needed to work consistently on this codebase.

---

## What This Is

A modular network auditing framework — single Bash script (`lss-network-tools.sh`) + installer (`install.sh`). Runs 20 tasks (network scans, device discovery, adoption) individually or as a full audit. Outputs structured JSON per task, generates text/PDF reports. Runs on macOS and Linux.

**Portability rules that have bitten before (read first):**
- The script runs under **macOS `/bin/bash` 3.2** via `#!/usr/bin/env bash`. No `${var,,}`/`${var^^}`, `declare -A`, `mapfile`, `|&`, `&>>`, `exec {fd}`, `[[ -v ]]`. Lower-case with `tr`.
- **Empty arrays are fatal under `set -u` in bash 3.2.** Expand with `${arr[@]+"${arr[@]}"}` unless the array is provably non-empty.
- **BSD `mktemp` does not randomise `XXXXXX` when a suffix follows it.** `mktemp /tmp/x-XXXXXX.py` returns the literal path. Never use a suffix; if a tool needs an extension (swiftc, iconutil) create a `mktemp -d` directory and put a fixed-name file inside.
- `set -e` and the ERR trap are **inert inside every task function** because the dispatchers call `run_task_by_id` inside `if !`. Task code must check return codes explicitly; do not rely on errexit to stop a failed `mktemp`/`cat >`.
- `if ! wait "$pid"; then rc=$?` always captures 0 (the `!` is applied first). Use `wait "$pid" && rc=0 || rc=$?`.
- GNU vs BSD: `tr -d` ranges (put `-` last), `stat -c` before `stat -f`, `ls -d`, `ifconfig` is optional on Linux (use `ip`), macOS `arp` omits leading zeros in MACs (use `normalize_mac`), macOS `route -n get default` ignores the interface (use `-ifscope`).

---

## In Progress

- **macOS GUI** (`macos/`, branch `macos-gui`) — milestones M0 ✓ (CLI fixes, v1.2.247), M1 ✓ (shell: sidebar + SwiftTerm, v1.2.248), M2 ✓ (run browser, typed models for all 20 tasks, fixtures + tests, GUI 0.2.0), M3 ✓ (non-interactive `--run-task`/`--build-report` v1.2.249, New Run sheet + live progress, GUI 0.3.0), M4 ✓ (SMAppService/XPC helper + RequestValidator, CoreWLAN survey, Sparkle, dmg/sign/notarize/appcast, GUI 0.4.0), M5 hardening (reviews, READMEs, PR). Plan: `macos/docs/PLAN.md`; decisions: `macos/docs/DECISIONS.md`; owner questions: `macos/docs/QUESTIONS.md`.

---

## Key Constants

```
APP_GITHUB_REPO  lssolutions-ie/lss-network-tools
Wrapper path     /usr/local/bin/lss-network-tools
macOS app root   /usr/local/share/lss-network-tools
Linux app root   /usr/local/lib/lss-network-tools
Linux data root  /var/lib/lss-network-tools
OUI cache        $DATA_ROOT/ubiquiti-oui-cache.txt  (macOS: /usr/local/share/lss-network-tools, Linux: /var/lib/lss-network-tools)
Update marker    $DATA_ROOT/.lss-last-update
```

---

## Installation Modes

| Mode | Trigger | Paths |
|------|---------|-------|
| `installed` | `install.env` exists | APP_ROOT/DATA_ROOT from install.env, wrapper at `/usr/local/bin` |
| `portable` | No install.env | Everything relative to SCRIPT_DIR |

`configure_runtime_paths()` determines mode. Updates only work in installed mode.

---

## Global Variables (top of script)

```bash
APP_VERSION          # e.g. v1.2.123 — bump for every commit
OS                   # "macos" or "linux" — set by detect_os()
INSTALL_MODE         # "installed" or "portable"
SELECTED_INTERFACE   # Active interface for all scans
RUN_OUTPUT_DIR       # e.g. output/client-location-dd-mm-yyyy
RUN_CLIENT_NAME / RUN_LOCATION / RUN_NOTE
RUN_CLIENT_SLUG / RUN_LOCATION_SLUG / RUN_NOTE_SLUG   # sanitized versions
RUN_REPORT_FILE      # .txt report path
SESSION_DEBUG_LOG    # temp debug capture (tee target; never reassign it mid-session)
NETWORK_INTERRUPTED  # true if interface dropped mid-run
HIGH_IMPACT_STRESS_CONFIRMED_TARGET  # target description the user consented to stress-test (per target, reset per run)
DHCP_CAPTURE_PID     # set by capture_dhcp_traffic(); stopped via stop_dhcp_capture()
_LSS_BG_PIDS         # registry of background PIDs (register_bg_pid/unregister_bg_pid); killed by finalize_run on exit
_LSS_EXITING         # 1 inside the EXIT trap so finalize_run can tell a real exit from a mid-session save
_START_FRESH_RUN     # set with _GOTO_MAIN_MENU by "Start a fresh run" in the network-mismatch prompt; startup loop proceeds to select_interface
_LSS_STATUS_MSG      # one-shot status shown in startup_menu after update check or relaunch
_LSS_UPDATE_BANNER   # set when a newer version is available; shown in startup_menu header
PROGRAM_DEFAULTS_FILE  # $DATA_ROOT/program-defaults.json — set by configure_runtime_paths()
```

Mode flags (0/1): `DEBUG_MODE`, `UPDATE_MODE`, `VERSION_MODE`, `BUILD_WIFI_HELPER_MODE`, `WRITE_COMPLETIONS_MODE`, `INSTALL_DEPS_MODE`, `UNINSTALL_MODE`, `RUN_TASK_MODE`, `BUILD_REPORT_MODE`

Non-interactive globals (all empty/0 in interactive mode): `_LSS_NONINTERACTIVE`, `_LSS_NI_*` (one per flag: `_LSS_NI_TARGET`, `_LSS_NI_STRESS_CONSENT`, `_LSS_NI_SSH_PASSWORD`, …), `_LSS_NI_FLAGS_SEEN`, `_LSS_NI_BYE_SENT`, `_LSS_PDF_LAST_ERROR`. **Rule:** a new `read` anywhere in the script must either be unreachable in NI mode (menu tree) or get an `if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]` branch that takes its value from a flag.

---

## Startup Flow

```
parse_args()
→ early exits for --version / --build-wifi-helper / --write-completions / --install-deps / --uninstall / --update
→ detect_os()
→ ensure_standard_path()
→ configure_runtime_paths()
→ ensure_runtime_directories()
→ detect_output_tty()        ← sets OUTPUT_IS_TTY so the first clear works
→ check_tools()              ← blocks if required dep missing, offers install.sh
→ warn_if_not_root()
→ initialize_debug_logging()
→ trap on_exit_trap EXIT     ← sets _LSS_EXITING=1 then finalize_run
→ trap on_interrupt INT TERM ← exit 130 so the EXIT trap (and bg-process cleanup) runs on Ctrl-C
→ trap handle_err_exit ERR
→ quick update check (2s)
→ loop: startup_menu() → select_interface() → initialize_run_context() → main_menu()
```

---

## Non-interactive Mode (v1.2.249, used by the macOS app)

`--run-task <id|csv|000|list>` and `--build-report <run-dir>` run the engine without prompts. Full contract: `macos/docs/PLAN.md` §7 and `macos/docs/research/06-m3-execution-contract.md` §1; user docs in README.md.

```
parse_args → early exits → NI setup (_LSS_NONINTERACTIVE=1; exec 9>&2; export LSS_QUIET_SPINNER=1)
→ `--run-task list` prints {"version","tasks":[{id,title,file,multi,group}]} and exits 0 (no root, before check_tools)
→ detect_os … ensure_runtime_directories
→ NI validation (exit 2 usage / 4 consent)  ← before check_tools and before any root requirement
→ check_tools (exit 3, never prompts)  →  root check (exit 5)  →  initialize_debug_logging → traps
→ run_noninteractive | run_build_report → exit 0 (all tasks success/warnings/skipped) or 1
```

- **Every prompt stays on the interactive branch.** New code is gated on `_LSS_NONINTERACTIVE`; every `read` has an NI bypass that takes its value from a flag (`_LSS_NI_TARGET` in `prompt_for_target_ip`, `--mac`, the Task 17 room flags, the Task 19 controller/SSH flags, `--yes` in `confirm_gateway_stress_operation`). Interactive output as non-root is byte-identical to v1.2.248.
- **Progress protocol:** `emit_progress <event> <"key":value fragments…>` writes `@@LSS {compact json}` with `"v":1,"ts"` to **fd 9**, a dup of the original stderr taken *before* `initialize_debug_logging` merges fd 1/2 into the tee, so progress never enters `debug.txt`. JSON is built with `json_escape`/`json_str_field`/`json_raw_field`/`json_str_array` (printf, not jq — jq may be the missing dependency). `emit_stage` sits next to the human "Stage N:" lines (Tasks 10/14/11/18); `emit_bye` is sent exactly once, also from the EXIT trap. Events: `hello, run_dir, task_start, task_stage, task_done, report_built, pdf_built|pdf_failed, warning, error, bye`.
- **Flags:** `--interface --client --location --note --run-dir --yes --target --mac --wifi-interface --building --floor --room --ap-present --ap-label --wifi-scan-json --controller --controller-port --https --ssh-user --prepared-by --output --no-pdf`; they are usage errors without `--run-task`/`--build-report` (`noninteractive_usage_error`). The Task 19 password is **only** read from `LSS_SSH_PASSWORD` (the GUI passes it with `sudo --preserve-env`).
- `initialize_run_context` is split into prompts + `initialize_run_context_from_values client location note` (the slug/dir/uniqueness logic); `--run-dir` mirrors `continue_run_from_dir` and never touches `SESSION_DEBUG_LOG`. Task 17 scans **one room per invocation** and appends to an existing `wireless-survey.json`.
- Tasks run as `if run_task_by_id "$id"; then rc=0; else rc=$?; fi` (same errexit semantics as the menus); `finalize_run` + `generate_pdf_report` run once, then `RUN_OUTPUT_DIR=""` so the EXIT trap does not build twice.
- `spinner_is_quiet()` (= `DEBUG_MODE` or `LSS_QUIET_SPINNER=1`) replaces the direct `DEBUG_MODE` tests in the spinner functions and `monitor_nmap_progress`.

---

## Task System

**TASKS_DATA** (pipe-delimited, lines ~45-66):
```
id|Title|output-file.json
```

**Key functions:**
```bash
task_output_path(id)          # current_output_dir/output-file.json
task_supports_multiple_entries(id)  # true for 10,13,14,15,16
run_task_by_id(id)            # dispatcher → calls task function
get_audit_task_ids()          # hardcoded "1 2 3 4 5 6 7 8 9 10 11 12"
get_task_ids()                # all IDs from TASKS_DATA
```

**Multi-entry tasks** (10,13,14,15,16): output files named `prefix-device-N.json`. `next_multi_entry_index()` returns max(existing N)+1 (not count+1, which overwrote files after a deletion). `task_json_files()` natural-sorts on N so `device-2` precedes `device-10`; the PDF generators do the same.

**current_output_dir()**: returns `RUN_OUTPUT_DIR` if set, else `OUTPUT_DIR`.

---

## All 20 Tasks

| ID | Name | Output File | Function |
|----|------|-------------|----------|
| 1 | Interface Network Info | interface-network-info.json | interface_info() |
| 2 | Internet Speed Test | internet-speed-test.json | internet_speed_test() |
| 3 | Gateway Details | gateway-scan.json | gateway_details() |
| 4 | DHCP Network Scan | dhcp-scan.json | dhcp_network_scan() |
| 5 | DHCP Response Time | dhcp-response-time.json | dhcp_response_time() |
| 6 | DNS Network Scan | dns-scan.json | detect_dns_servers() |
| 7 | LDAP/AD Network Scan | ldap-ad-scan.json | detect_ldap_servers() |
| 8 | SMB/NFS Network Scan | smb-nfs-scan.json | detect_smb_nfs_servers() |
| 9 | Printer/Print Server Scan | print-server-scan.json | detect_print_servers() |
| 10 | Gateway Stress Test | gateway-stress-test-device-*.json | gateway_stress_test() |
| 11 | VLAN/Trunk Detection | vlan-trunk-scan.json | vlan_trunk_scan() |
| 12 | Duplicate IP Detection | duplicate-ip-scan.json | duplicate_ip_detection() |
| 13 | Custom Target Port Scan | custom-target-port-scan-device-*.json | custom_target_port_scan() |
| 14 | Custom Target Stress Test | custom-target-stress-test-device-*.json | custom_target_stress_test() |
| 15 | Custom Target Identity Scan | custom-target-identity-scan-device-*.json | custom_target_identity_scan() |
| 16 | Custom Target DNS Assessment | custom-target-dns-assessment-device-*.json | custom_target_dns_assessment() |
| 17 | Wireless Site Survey | wireless-survey.json | wireless_site_survey() |
| 18 | Scan For UniFi Devices | unifi-discovery.json | unifi_device_scan() |
| 19 | UniFi Adoption | unifi-adoption.json | unifi_adoption() |
| 20 | Find Device by MAC | find-device-by-mac.json | find_device_by_mac() |

Tasks 1–12 = core audit (run via `000`). Tasks 13–20 = custom/specialist. Task 20 is vendor-neutral (plain ARP/MAC lookup, no UniFi logic).

Tasks 18 and 20 refuse to run without root (`insufficient_privileges` failure JSON) because nmap prints no MAC addresses without raw-socket privileges.

---

## Task 18 — UniFi Scan Detail

Five-step pipeline in `unifi_device_scan()`:

1. **OUI cache** — fetch from IEEE registry max once per 30 days; 45 built-in blocks; cache at `$DATA_ROOT/ubiquiti-oui-cache.txt`. The live list temp file (`tmp_live_ouis`) must survive until after Step 5 — `is_ubiquiti_oui` is called again during LLDP reconciliation.
2. **ARP discovery** — `nmap -n -sn $subnet` × 5 passes; deduplicate IP+MAC via Python temp script; sort numerically. ARP-table fallback MACs go through `normalize_mac` (macOS strips leading zeros).
3. **UDP 10001 sweep** — `nmap -sU -p 10001` × 10 passes; match `10001/open/udp` only (`open|filtered` is not a responder)
4. **TLV fingerprinting** — Python script probes each host on UDP 10001 with PROBE_V1/V2; `confirmed={}` must be declared BEFORE the probe loop (bug history: was after, caused silent NameError → 0 confirmed). A "TLV bind failed" on stderr (something else holding UDP 10001) is surfaced as a warning, not swallowed.
5. **LLDP listener** — scapy sniff `ether proto 0x88cc` in background with no timeout; killed by bash at the end
6. **SSH banner rescue** — for flagged (non-Ubiquiti OUI) devices: Python socket with 2s timeout (not `nc -z` — hangs on macOS when packets are dropped). A Dropbear banner only makes a host **probable** (`confidence: "probable"`), since Dropbear is stock on OpenWrt/NAS/cameras.

**All device JSON entries are built with `unifi_device_entry mac ip [model] [confidence]`** (jq, never string concatenation — device-supplied hostnames can contain quotes).

**Output JSON shape:** `{status, success, interface, subnet, devices_found, devices: [{mac, ip, model?, confidence?}], false_positives: [{mac, ip}]}`

**`devices_found`** counts `devices[]` (confirmed + probable). Non-Ubiquiti MACs that passed UDP/LLDP checks go into `false_positives[]`. PDF report only renders `devices[]` — false positives are excluded from PDF, but appear in TXT report and View Results.

---

## Task 19 — UniFi Adoption Detail

In `unifi_adoption()`:

1. Load IPs from Task 18's `unifi-discovery.json` — only adopts `devices[]` entries whose `confidence` is not `"probable"`; never `false_positives[]`; if not found, print message and `return 0` (back to menu, not exit)
2. Prompt: controller domain (reads `unifi_domain` from Program Defaults, default `unifi.lssolutions.ie`), port (`unifi_port`, default `8080`), HTTPS (`unifi_https`, default `n`; auto-HTTPS if port 443), SSH username, SSH password (`read -r -s`). The domain is stripped of any scheme/path and validated against `^[A-Za-z0-9.-]+$`; the port must be 1–65535.
3. Build `inform_url`
4. For each IP: `SSHPASS="$pass" sshpass -e ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR user@ip "mca-cli-op set-inform '$inform_url'"` — password via environment (`-e`), never `-p` on the command line. Exit codes are mapped: sshpass 5 = auth failed, 6 = host key, ssh 255 = unreachable.
5. **`ssh -n` is critical** — without it, ssh consumes the while loop's stdin and the loop ends after first successful connection

**sshpass auto-install:** if missing, attempts `apt-get install -y sshpass` (Linux) or `brew install hudochenkov/sshpass/sshpass` (macOS via SUDO_USER) before failing.

---

## Dependency Coverage

Every dependency must be handled at all four stages:

| Stage | Mechanism |
|-------|-----------|
| Fresh install | `install.sh` → `install_linux_dependencies()` / `install_macos_dependencies()` |
| Update | Update helper calls `bash $SCRIPT_PATH --install-deps` (uses NEW script after file copy) |
| Startup | `check_tools()` — required tools block; optional tools warn only |
| Health check | `about_and_health()` — full checklist with install hints |

**Current dependencies:**

*Both platforms (required):* nmap, jq, speedtest-cli, tcpdump, python3, scapy (pip), fpdf2 (pip), awk, sed, grep, find, mktemp

*Linux only (required):* ip (iproute2), ping (iputils-ping), iw (Task 17)

*macOS only (required):* ipconfig, ifconfig, route, networksetup, ping; airport or system_profiler (Task 17)

*Both platforms (optional — warn if missing):* sshpass (Task 19), arp-scan (Task 12); macOS: Xcode Command Line Tools for the Wi-Fi helper (detect with `xcode-select -p && xcrun --find swiftc`, NOT `command -v swiftc` — stock macOS ships a shim that always exists)

**`print_install_hint(tool)`** — gives correct install command per OS per tool. Add new tools here when adding deps.

**`--install-deps` mode** — called by update helper. Iterates a `cmd|brew formula|apt package|used by` list (currently sshpass, arp-scan). Add new post-install-only deps there. On macOS runs brew as `$SUDO_USER` (not root). On Linux runs apt-get or dnf. Failures are non-fatal.

**Dependency check after `install.sh` from `check_tools()`** rechecks the Python libraries (scapy, fpdf2) as well as the binaries.

---

## Update System

`perform_installed_update()` generates a temp bash helper script via heredoc and `exec`s it. The heredoc is generated by the **old** script before copying new files — any new install code must use `bash $SCRIPT_PATH --install-deps` (calls new script), NOT be embedded directly in the heredoc.

**Preserved during update (macOS, where APP_ROOT = DATA_ROOT):** `output/`, `raw/`, `tmp/`, `install.env`, `assets/`, `program-defaults.json`, `install-audit.log`, `ubiquiti-oui-cache.txt`, `LSS-WiFiScan.app`, `LSS-WiFiScan.app.version`. On Linux only `install.env` and `assets/` need preserving because `DATA_ROOT=/var/lib/lss-network-tools` is separate from `APP_ROOT`.

Update helper sequence: **verify payload** (main script present, `--version` equals the tag, `install.env` present in DEST) → rm old files → cp new files **excluding `assets/`, `legacy/`, `.github/`, `CLAUDE.md`, `ROADMAP.md`, `.gitignore`, `__pycache__`** → `--install-deps` → merge assets without overwriting (user logos survive) → `--build-wifi-helper` → `--write-completions` → verify version → log → write `$DATA_ROOT/.lss-last-update` → relaunch. The old `cp -R "$SOURCE_ROOT"/. "$DEST_DIR"/` clobbered user assets and made the merge loop a no-op.

**Version comparison** uses `sort -V` and only offers an update when the remote tag is strictly newer; a local dev build ahead of the latest tag is "up to date". `latest_remote_tag_from_github()` only accepts tags matching `^v[0-9]+\.[0-9]+\.[0-9]+$` because the tag is interpolated into a root-executed helper script.

**GitHub headers** are passed to curl with `-H @tempfile` so a token never appears in `ps`. Under sudo, `gh auth token` is run as `$SUDO_USER`.

**Post-update status message:** The heredoc writes `echo "$remote_tag" > "$DATA_DIR/.lss-last-update"` before `exec`ing the relaunch. On next startup, `startup_menu()` reads this file, sets `_LSS_STATUS_MSG="Updated successfully to vX.Y.Z"`, deletes the file, and displays the message on first render (one-shot). This is necessary because `exec` starts a new process — shell variables cannot survive across it. (It used to live in world-writable `/tmp`.)

**`--update` CLI mode** prints the outcome (`_LSS_STATUS_MSG` and any curl error) because no menu renders it.

**curl during download:** `download_tag_zipball()` uses `curl -s` (silent) to suppress the progress meter, with `--connect-timeout 10 --max-time 300`. A `printf "  Downloading %s...\n"` line is printed before the curl call instead.

---

## Error Handling Patterns

```bash
set -euo pipefail              # strict mode throughout (but see note below)
trap on_exit_trap EXIT         # _LSS_EXITING=1; finalize_run: build report, copy debug log, write manifest, kill bg pids
trap on_interrupt INT TERM     # exit 130 so the EXIT trap runs on Ctrl-C
trap handle_err_exit ERR       # detects network drop, sets NETWORK_INTERRUPTED=true

command || true                # suppress expected failures
2>/dev/null                    # suppress stderr for optional commands
python3 ... 2>/dev/null || true  # Python subprocess failures don't exit script
wait "$pid" && rc=0 || rc=$?   # NOT `if ! wait; then rc=$?` (always 0)
```

**errexit is inert inside tasks.** `run_task_with_results_output` / `run_task_with_progress_output` call `run_task_by_id` inside `if !`, which disables `set -e` and the ERR trap for the whole call tree. Task code must handle failures explicitly. `set -u` still applies.

**`finalize_run()`** — if not NETWORK_INTERRUPTED: builds report, copies debug log, writes manifest.json. Called from the EXIT trap and explicitly on "Save report". Callers that save mid-session must clear `RUN_OUTPUT_DIR` afterwards so the EXIT trap does not build the report twice. Mid-session it truncates the session debug log (tee still has it open); only on real exit does it delete it and kill registered background PIDs, the spinner and caffeinate.

**Background processes** (tcpdump, nmap sweeps, the Wi-Fi helper, LLDP sniffer) must be registered with `register_bg_pid "$!"` and unregistered when reaped; async children ignore SIGINT so nothing else stops them on Ctrl-C. `capture_dhcp_traffic` sets `DHCP_CAPTURE_PID` (do not start it inside `$(...)` — the PID would not be a child). Both tcpdump captures use `-Z root` because Debian/Ubuntu tcpdump drops privileges before opening the root-owned `-w` file.

**`handle_err_exit()`** — uses `interface_has_valid_ip` (OS-aware: `ip` on Linux, `ifconfig` on macOS) to check if the interface lost its address; if so sets NETWORK_INTERRUPTED and prints recovery message (suggests "Continue This Run").

---

## UI / Display Conventions

**2-space indent rule:** All user-visible CLI output uses a 2-space indent prefix. Every `printf` or `echo` with text content in menu/display functions must start with `  `. Blank `echo` lines are fine without. This applies to: `startup_menu`, `main_menu`, `check_tools`, `about_and_health`, `manage_results_for_run_dir`, `continue_run_from_dir`, `select_interface`, `initialize_run_context`, `check_for_updates`, `perform_installed_update`, and all interactive/display functions.

**Task output indenting:** The 20 task functions themselves do NOT use the 2-space prefix internally — they output flush-left. `run_task_with_results_output()` wraps each task run by redirecting stdout through an awk indenter:

```bash
exec 8>&1
exec 1> >(awk '{print "  " $0; fflush()}' >&8)
# ... run task ...
exec 1>&8 8>&-
```

**Why `exec 8>&1` not `exec {varname}>&1`:** macOS ships bash 3.2; named fd assignment (`exec {var}>&1`) requires bash 4.1+. Always use fixed fd numbers (8 is used throughout).

**Why no global awk redirect:** Spinner uses `\r` without newlines (awk buffers → spinner freezes); `clear` escape sequences get `  ` prepended (breaks clear); all existing `printf "  ..."` in menus would double-indent to 4 spaces.

**`fflush()` in awk:** Required so interactive prompts inside tasks (Tasks 17, 19) appear immediately rather than buffering until newline.

---

## Colour Variables

Colours are declared **locally per function** — never global. Always declare all colours a function uses:

```bash
local red='\033[0;31m'
local green='\033[0;32m'
local yellow='\033[1;33m'
local cyan='\033[0;36m'
local bold='\033[1m'
local reset='\033[0m'
```

Only declare the colours actually used in that function. Bug history: `check_continue_run_network()` and `wireless_site_survey()` were missing `cyan`/`bold` declarations — variables silently expanded to empty string (no colour, no error).

---

## Python Subprocess Pattern

Always write to a temp file, never use `python3 - <<'PYEOF' < $input_file` (file redirect overrides heredoc stdin). **No suffix after `XXXXXX`** — BSD mktemp returns the literal, non-random path otherwise (python3 does not need a `.py` extension):

```bash
local tmp_py
tmp_py="$(mktemp /tmp/lss-prefix-XXXXXX)"
cat > "$tmp_py" << 'PYEOF'
# python code here
PYEOF
python3 "$tmp_py" "$arg1" < "$input_file"
rm -f "$tmp_py"
```

In scapy scripts that parse a pcap, import contrib dissectors (`scapy.contrib.cdp`, `scapy.contrib.lldp`) **before** `rdpcap()`; otherwise frames are already dissected as `Raw` and `haslayer()` is always false.

Prompts whose output is captured with `$(...)` (e.g. `prompt_for_target_ip`) must print errors to stderr.

---

## Run Context / Session

`initialize_run_context()` prompts for Location, Client Name, Note → builds `RUN_OUTPUT_DIR`:
```
output/{client-slug}-{location-slug}-{dd-mm-yyyy}[-{note-slug}]
```
If that directory already exists (second run for the same client/location on the same day) it appends `-{HH-MM}` and then `-2`, `-3`… so an earlier run is never merged into or deleted by a later one. It also resets the stress-test consent.

Report file:
```
{RUN_OUTPUT_DIR}/lss-network-tools-report-{client}-{location}-{date}-{HH-MM}.txt
```

`current_output_dir()` returns `RUN_OUTPUT_DIR` if active, else `OUTPUT_DIR`.

---

## Continue This Run

`continue_run_from_dir()` — restores full RUN_* session state from a previous run directory, re-checks network (compares stored gateway to current, using the run's `SELECTED_INTERFACE` rather than the default-route interface), shows task completion status ([x] done, [!] corrupt, [ ] pending), lets user skip tasks, runs only pending/corrupt tasks. If the manifest has no `selected_interface`, it falls back to the active session interface or prompts via `select_interface` — it never runs tasks against a literal `"unknown"`. It must NOT reassign `SESSION_DEBUG_LOG`.

`check_continue_run_network()` returns 0 = proceed, 1 = cancel, 2 = "start a fresh run" (also sets `_START_FRESH_RUN=true` and `_GOTO_MAIN_MENU=true` so every menu unwinds to the startup loop, which then goes to `select_interface`).

---

## Manage Previous Runs / Manage Results

**`manage_previous_runs()`** — lists past run directories, lets user select one.

**`manage_results_for_run_dir(run_dir)`** — per-run action menu with options:
- **Continue Run** — calls `continue_run_from_dir()` after network check (`load_run_metadata_from_dir` + `check_continue_run_network`). Saves/restores `SELECTED_INTERFACE` around the network check.
- **Manage Results** — lists completed task JSON files; selecting one opens a sub-menu:
  - **1) View Results** — pretty-prints the JSON
  - **2) Edit Results** — shows a numbered list of top-level scalar fields with current values; user picks a field number to edit, `s` to save changes to file, `0` to cancel (discard). Works on a temp copy (`mktemp`), only writes back on `s`. The new value is coerced to the field's **original** JSON type (string stays string, bool parses true/false, int/float parse numerically).
  - **000) Delete This Result** — red destructive option; requires typing `YES` or `yes` to confirm (`[[ "$x" == "YES" || "$x" == "yes" ]]` — never `${var,,}`, which is bash 4 and crashes bash 3.2)
- **000) Delete This Run** — deletes entire run directory; requires `YES`/`yes` confirmation

**Network check in Manage Results:** Before running a task from results viewer, `load_run_metadata_from_dir` must be called first (populates stored gateway/network), then `check_continue_run_network`. `SELECTED_INTERFACE` is saved before and restored after to avoid clobbering the active session interface.

---

## Menus

**`startup_menu()`:** 1) Run / 2) Manage Previous Runs / 3) Check For Updates / 4) About & Install Health / 5) Program Defaults / 6) Exit

On each render: checks `$DATA_ROOT/.lss-last-update` (post-update marker) → sets `_LSS_STATUS_MSG` → deletes file. Displays `_LSS_UPDATE_BANNER` if a newer version is available. Displays `_LSS_STATUS_MSG` one-shot then clears it. After `manage_previous_runs` returns with `_START_FRESH_RUN=true`, it returns to the startup loop.

**`main_menu()`:** Lists all 20 tasks + `000` for complete audit + `0` back. Task number typed = task ID passed to `run_task_by_id()` via `run_task_with_results_output()`. `run_all_tasks` is called with `|| true` (declining the stress-test warning returns 1).

**Main loop "Save report?"** calls `finalize_run`, then `generate_pdf_report`, then clears `RUN_OUTPUT_DIR`.

**`continue_run_from_dir()`:** Empty Enter or `0` both go back. Typing a task list (e.g. `1,3`) runs only those tasks. Task 10 (stress test) still requires explicit confirmation before running.

## Program Defaults

Stored in `$DATA_ROOT/program-defaults.json` (`PROGRAM_DEFAULTS_FILE`). Survives updates (preserved in macOS update helper; on Linux it's in `DATA_ROOT` which is separate from `APP_ROOT`).

**Helper functions:**
```bash
get_program_default(key, fallback)   # reads key from JSON, returns fallback if missing
set_program_default(key, value)      # upserts key into JSON file (validates existing JSON first, writes via mktemp + mv)
```

**Defined keys:** `unifi_domain`, `unifi_port`, `unifi_https`

**`program_defaults_menu()`** — startup option 5. Adapts dynamically:
- Before setup (no file): 1=Setup, 2=View, 3=Edit
- After setup: 1=View, 2=Edit

**`_setup_program_defaults()`** — first-time wizard; domain prompt shows `Controller domain or IP:` without revealing the built-in default in the prompt text (default `unifi.lssolutions.ie` applied silently on empty Enter).

**Bug history:** `configure_runtime_paths()` has an early `return 0` in the `install.env` branch. `PROGRAM_DEFAULTS_FILE` must be set inside that branch before the return, not after — otherwise it stays empty in installed mode and `set_program_default` fails with "No such file or directory".

---

## check_tools() Output Format

`check_tools()` runs at startup (after `detect_output_tty` + `clear_screen_if_supported`). All output uses 2-space indent. All required and optional deps are listed under a single "Dependency Checklist:" heading — no sub-sections for optional tools. Status tags use fixed-width padding so content columns align:

```
  [OK]      tool-name          ← 6 spaces after [OK]
  [WARN]    message            ← 4 spaces after [WARN]
  [MISSING] tool-name          ← 1 space after [MISSING]
```

Same padding convention used in `about_and_health()`.

---

## Commit/Version Convention

- Every change = bump `APP_VERSION` in the `APP_VERSION=` line
- Version format: `v1.2.NNN`
- Always: commit → push → `gh release create vX.Y.Z`
- Commit messages: `vX.Y.Z: short description`

---

## install.sh Key Points

- `BREW_USER` = `$SUDO_USER` (the real user who ran `sudo install.sh`) — used to run brew as non-root
- `run_macos_user_shell($cmd)` — runs command as BREW_USER with correct HOME and PATH
- `brew_install_if_missing($cmd, $formula, [$optional_for])` — skips if already installed; uses tap path for sshpass (`hudochenkov/sshpass/sshpass`); with the third arg a failure is a `[WARN]`, not fatal
- Linux: apt-get or dnf; optional packages (sshpass, arp-scan) installed one by one so a missing package cannot fail the batch; always `pip3 install fpdf2` after package install
- Deploys: `lss-network-tools.sh`, `install.sh`, `generate_pdf_report.py`, `generate_pdf_compare_report.py`, `README.md`, `assets/`. (`unifi-discover.nse` was dead code and has been removed from the repo.)
- Freshness check compares with `sort -V` and only blocks when the local copy is strictly older; `UPDATE` / `CONTINUE` / Enter; `LSS_SKIP_FRESHNESS_CHECK=1` bypasses
- Completions are written by calling `bash <deployed script> --write-completions`, same as the updater
- Writes `install.env` to APP_TARGET_DIR with all paths — this is what switches the script into installed mode

---

## Reports

- `build_report_for_current_run` and `build_report_for_run_dir` build the TXT report; the PDF (`generate_pdf_report.py`) renders from `manifest.json`, so **always rewrite the manifest before generating a PDF** and after Manage Results adds or deletes a task's JSON (`build_report_for_run_dir` does this unconditionally since v1.2.247).
- Report-name guard in `build_report_for_current_run`: regenerate `RUN_REPORT_FILE` only when it is empty or points into a *different* run directory under `OUTPUT_DIR`. A path outside `OUTPUT_DIR` is an export destination chosen by the user and must be kept (v1.2.246 inverted this and wrote exports into the run dir).
- Every task JSON must end up 0644. `run_stress_test_for_target` builds its JSON in a `mktemp` file (0600) and `chmod 644`s it after the `mv`.
- Task 10 results, including skipped / early-failure ones, are written to `gateway-stress-test-device-N.json` (via `next_multi_entry_output_path 10`). `append_findings_summary` iterates every Task 10 file (plus the legacy non-indexed name for old runs).
- Reports exported outside the run dir default to the **invoking user's** Desktop (`invoking_user_home`, not `$HOME`, which is root's under sudo). Typed paths go through `expand_user_path` for `~`.
- `generate_pdf_compare_report.py` must read the same field names the bash writers emit; it drifted once and rendered `--` for Tasks 6–10, 14–16 and 19. When a JSON schema changes, update both Python files.
- DNS "open_resolver" is labelled "Recursion enabled (answers LAN clients)" everywhere — the probe only tests recursion from the LAN.

---

## macos/ GUI

A native SwiftUI app (macOS 14+, Swift 6 language mode) that drives this script and browses its run directories. **The bash script stays the engine**: the GUI never writes task JSON, manifests, findings or PDFs, and never bundles a copy of the script. Full design in `macos/docs/PLAN.md`; research on the script's JSON shapes, prompts, install layout and PDF contract in `macos/docs/research/`.

- **Layout:** `macos/Package.swift` (SwiftPM, no Xcode project), `Sources/LSSCore` (Foundation-only models, decoding, run loader, CLI discovery/contract; unit-tested), `Sources/LSSXPC` (XPC protocol + DTOs shared by app and helper), `Sources/LSSHelper` (privileged LaunchDaemon), `Sources/LSSNetworkTools` (the app), `Tests/LSSCoreTests` (Swift Testing), `Tests/Fixtures` (anonymised + synthetic runs), `scripts/` (build-app, sign, run-app, screenshot, check-toolchain, lint, anonymize-run, make-synthetic-run), `Makefile`.
- **Run browser (M2):** `RunLoader` (actor) scans `output/` — manifest or directory-name fallback, both Task 10 file names, natural `-device-N` sort, 0600 files flagged `.unreadable`. `TaskPayloadRegistry` routes each task to its typed payload (`Models/Tasks/CoreAuditPayloads.swift` for 1–12 + 14, `SpecialistPayloads.swift` for 13, 15–20); the SwiftUI views live in `RunBrowser/TaskDetail/` and are dispatched by `TaskPayloadView`. The type/view/file naming contract is `docs/research/05-m2-model-view-contract.md`. Adding a task = TASKS_DATA + `TaskID` + payload + view + registry case + fixture. Decoding is lenient by design (open status enum, `@Lenient*` wrappers, missing keys → nil); never make a field non-optional because one run had it.
- **Fixtures & tests:** `Tests/Fixtures/runs/` are real runs passed through `scripts/anonymize-run.py` (names/hosts/SSIDs hashed, public IPs → TEST-NET, free text dropped; the leak list is committed as hashes only), `synthetic/` holds hand-written shapes for tasks 10/13–20, `synthetic-run/` is one fictional 20-task run assembled by `scripts/make-synthetic-run.py` (`make fixtures` regenerates it and re-runs the leak scan). `make test` decodes every fixture and re-runs the hashed leak scan in Swift. Never commit `debug.txt`, `raw/`, TXT reports or an original PDF.
- **Build:** `cd macos && make build` → `~/Library/Caches/ie.lssolutions.lss-network-tools/build/app/LSS Network Tools.app`. Products live outside the checkout because `~/Documents` is iCloud-synced and the file-provider xattrs break `codesign`. Override with `LSS_GUI_BUILD_DIR`. `make run`, `make screenshot VIEW=audit|task-N|runs|settings`, `make test`, `make clean`.
- **Toolchain:** Xcode 26+/Swift 6; the **Metal toolchain component** must be installed (`xcodebuild -downloadComponent MetalToolchain`) because SwiftTerm ships a `.metal` shader; `scripts/check-toolchain.sh` reports this. Ad-hoc signing unless `CODESIGN_IDENTITY` is set.
- **Dependencies:** SwiftTerm (MIT), Defaults (MIT), Sparkle (MIT, binary xcframework; embedded as `Contents/Frameworks/Sparkle.framework`, disabled unless the build had `SPARKLE_PUBLIC_ED_KEY`). Nothing else without a licence note in PLAN.md.
- **Bundle (M4):** `build-app.sh` builds two products — the app and `LSSHelper` (the SMAppService LaunchDaemon, `Contents/MacOS/LSSHelper` + `Contents/Library/LaunchDaemons/ie.lssolutions.lss-network-tools.helper.plist`) — copies the Sparkle framework from the SwiftPM artifacts, adds the `@executable_path/../Frameworks` rpath, inserts the Sparkle keys with `plutil -insert`, and calls `sign.sh`, which signs inside-out (Sparkle XPC services/Autoupdate/Updater.app → framework → resource bundles → helper with identifier `ie.lssolutions.lss-network-tools.helper` and `Resources/LSSHelper.entitlements` → app with `Resources/LSSNetworkTools.entitlements`). `make dmg` / `make notarize` / `make appcast` wrap `scripts/{make-dmg,notarize,release-appcast}.sh`; each prints one "skipped" line when credentials or keys are absent. Contract: `docs/research/07-m4-privilege-updates-contract.md`.
- **CLI discovery:** `CLIInstall.detect()` reads `/usr/local/share/lss-network-tools/install.env`, then the wrapper's `exec` line, then a developer override; the wrapper is the preferred launcher because it exports the Homebrew-first PATH (fpdf2's python3). `CLIVersionProbe` runs `--version`.
- **Terminal:** `TerminalSession` owns one SwiftTerm terminal view with a pty child; it exposes an `outputTap` (every byte the child writes, on the main actor) and `send(text:)`. From M3 the interactive CLI starts only on demand ("Open Interactive CLI Session"); one pty process at a time. M4 adds an SMAppService helper path.
- **Execution (M3):** `RunTaskRequest` → `ArgumentBuilder.arguments(for:)` (deterministic flag order, `problems(in:)` for inline validation; `.consentRequired` is shown as a dialog, never bypassed) → `ArgumentBuilder.sudoCommand` (`/usr/bin/sudo [--preserve-env=LSS_SSH_PASSWORD] <wrapper> …`) → launched in the `TerminalSession`; `RunCoordinator` (`NewRun/`) feeds the byte tap through `ProgressLineParser` (streaming, pty-tolerant: CRLF, `\r` spinner segments, ANSI, events sharing a line with a spinner frame) and drives `RunProgressView` (phase banner incl. "awaiting password", per-task states, stages) and refreshes the run browser after each `task_done`. `RunCoordinator.simulate(stream:)` replays a fixture (`--simulate-progress <log>`) for screenshots and QA. Contract: `docs/research/06-m3-execution-contract.md`; fixtures under `Tests/Fixtures/progress/` are hand-written to that contract until a root capture replaces them.
- **Privileges (M4):** `PrivilegeMode` (Defaults `privilegeMode`; `sudoTerminal` default, `helper` opt-in), `HelperInstaller` (`SMAppService.daemon(plistName:)`), `HelperClient` (`NSXPCConnection(machServiceName:options: .privileged)`, requires `identifier "…helper"` plus the team anchor in signed builds) in `Privilege/`; helper side in `Sources/LSSHelper` (`HelperService`, `CallerValidation`, `ChildProcess`, `FileOperations`, `HelperDiagnostics` for `--diagnose/--check-arguments/--version`). `RequestValidator` (LSSCore, Foundation-only, injectable file system) is the **single allow-list**: adding a CLI flag means `parse_args` + `ArgumentBuilder.valueFlags/booleanFlags` + a per-flag rule in the validator + a test. The helper trusts nothing from the app: executable from `install.env` only (root-owned, not writable, not a symlink), run dirs canonical and directly inside `output/`, the Wi-Fi scan file copied into a root-only directory before use, environment built from scratch. `LSSHelperBuildVersion` in LSSXPC must equal `macos/VERSION`.
- **Wi-Fi survey (M4):** `WiFi/WiFiScanEngine|WiFiScanStore|WiFiScanner|WiFiScanRow` scan with CoreWLAN under the app's Location permission and write helper-shaped JSON (`ssid, bssid, rssi_dbm, noise_floor_dbm, channel, band, channel_width, phy_mode, security` — keep identical to `build_wifi_scan_helper_macos`) to `~/Library/Application Support/ie.lssolutions.lss-network-tools/scans/<uuid>.json` (0600, 7-day cleanup); the Task 17 panel's "Scan this room" sets `--wifi-scan-json` and `--wifi-interface`.
- **Updates (M4):** `SparkleController.shared` is the only Sparkle instance (created by the App struct; starts only when `SUPublicEDKey` is in Info.plist), `UpdatesSettingsSection`, "Check for Updates…" after About (disabled with an explanation in unkeyed builds). Feed = committed `macos/appcast.xml`, regenerated by `scripts/release-appcast.sh`.
- **Screenshots:** the app's `--screenshot <png> --view <v> --delay <s>` flags render the window with `cacheDisplay` (no Screen Recording permission); run-browser state is driven with `--output-dir <runs dir> --select-run N --tab overview|tasks|report --task N --collapse-grid`; the New Run sheet with `--view new-run [--task N]`, the consent dialog with `--view consent`, a replayed run with `--simulate-progress <log> [--simulate-interval ms]`, long forms with `--scroll-to-end`; `--helper-status` / `--register-helper` print the SMAppService state and exit. `scripts/screenshot.sh` / `make screenshot ARGS="…"` drive it. Evidence is committed under `macos/docs/screenshots/`.
- **Rules:** `TaskID` mirrors TASKS_DATA and a test parses the script to catch drift — update both when adding a task. GUI-only commits keep the current `APP_VERSION` prefix with a `macos` marker; only commits that touch `lss-network-tools.sh` bump `APP_VERSION`. The updater excludes `macos/` when copying a release into APP_ROOT.
