# lss-network-tools — Claude Reference

This file is read by Claude at the start of every session. It covers architecture, patterns, and conventions needed to work consistently on this codebase.

---

## What This Is

A modular network auditing framework — single Bash script (`lss-network-tools.sh`) + installer (`install.sh`). Runs 19 tasks (network scans, device discovery, adoption) individually or as a full audit. Outputs structured JSON per task, generates text/PDF reports. Runs on macOS and Linux.

---

## Key Constants

```
APP_GITHUB_REPO  lssolutions-ie/lss-network-tools
Wrapper path     /usr/local/bin/lss-network-tools
macOS app root   /usr/local/share/lss-network-tools
Linux app root   /usr/local/lib/lss-network-tools
Linux data root  /var/lib/lss-network-tools
OUI cache        /usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt
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
SESSION_DEBUG_LOG    # temp debug capture
NETWORK_INTERRUPTED  # true if interface dropped mid-run
_LSS_STATUS_MSG      # one-shot status shown in startup_menu after update check or relaunch
_LSS_UPDATE_BANNER   # set when a newer version is available; shown in startup_menu header
PROGRAM_DEFAULTS_FILE  # $DATA_ROOT/program-defaults.json — set by configure_runtime_paths()
```

Mode flags (0/1): `DEBUG_MODE`, `UPDATE_MODE`, `VERSION_MODE`, `BUILD_WIFI_HELPER_MODE`, `WRITE_COMPLETIONS_MODE`, `INSTALL_DEPS_MODE`, `UNINSTALL_MODE`

---

## Startup Flow

```
parse_args()
→ early exits for --version / --build-wifi-helper / --write-completions / --install-deps / --uninstall / --update
→ detect_os()
→ ensure_standard_path()
→ configure_runtime_paths()
→ ensure_runtime_directories()
→ check_tools()              ← blocks if required dep missing, offers install.sh
→ warn_if_not_root()
→ initialize_debug_logging()
→ trap finalize_run EXIT
→ trap handle_err_exit ERR
→ quick update check (2s)
→ loop: startup_menu() → select_interface() → initialize_run_context() → main_menu()
```

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

**Multi-entry tasks** (10,13,14,15,16): output files named `prefix-device-N.json`, index tracked via `next_multi_entry_index()`.

**current_output_dir()**: returns `RUN_OUTPUT_DIR` if set, else `OUTPUT_DIR`.

---

## All 19 Tasks

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

Tasks 1–12 = core audit (run via `000`). Tasks 13–19 = custom/specialist.

---

## Task 18 — UniFi Scan Detail

Five-step pipeline in `unifi_device_scan()`:

1. **OUI cache** — fetch from IEEE registry max once per 30 days; 45 built-in blocks; cache at `/usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt`
2. **ARP discovery** — `nmap -n -sn $subnet` × 5 passes; deduplicate IP+MAC via Python temp script; sort numerically
3. **UDP 10001 sweep** — `nmap -sU -p 10001` × 10 passes; skips already-confirmed hosts each pass; 1s sleep between passes; catches devices on different VLANs that don't respond to ARP
4. **TLV fingerprinting** — Python script probes each host on UDP 10001 with PROBE_V1/V2; `confirmed={}` must be declared BEFORE the probe loop (bug history: was after, caused silent NameError → 0 confirmed)
5. **LLDP listener** — scapy sniff `ether proto 0x88cc` in background; reconciled at end
6. **SSH banner rescue** — for flagged (non-Ubiquiti OUI) devices: Python socket with 2s timeout (not `nc -z` — hangs on macOS when packets are dropped)

**Output JSON shape:** `{status, success, interface, subnet, devices_found, devices: [{mac, ip, model}], false_positives: [{mac, ip}]}`

**`devices_found`** counts only confirmed Ubiquiti devices (`devices[]`). Non-Ubiquiti MACs that passed UDP/LLDP checks go into `false_positives[]`. PDF report only renders `devices[]` — false positives are excluded from PDF, but appear in TXT report and View Results.

---

## Task 19 — UniFi Adoption Detail

In `unifi_adoption()`:

1. Load IPs from Task 18's `unifi-discovery.json` — only adopts `devices[]` (confirmed), never `false_positives[]`; if not found, print message and `return 0` (back to menu, not exit)
2. Prompt: controller domain (reads `unifi_domain` from Program Defaults, default `unifi.lssolutions.ie`), port (`unifi_port`, default `8080`), HTTPS (`unifi_https`, default `n`; auto-HTTPS if port 443), SSH username, SSH password (`read -r -s`)
3. Build `inform_url`
4. For each IP: `sshpass -p "$pass" ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR user@ip "mca-cli-op set-inform $inform_url"`
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

*Both platforms (optional — warn if missing):* sshpass (Task 19)

**`print_install_hint(tool)`** — gives correct install command per OS per tool. Add new tools here when adding deps.

**`--install-deps` mode** — called by update helper. Currently installs: sshpass. Add new post-install-only deps here. On macOS runs brew as `$SUDO_USER` (not root). On Linux runs apt-get.

---

## Update System

`perform_installed_update()` generates a temp bash helper script via heredoc and `exec`s it. The heredoc is generated by the **old** script before copying new files — any new install code must use `bash $SCRIPT_PATH --install-deps` (calls new script), NOT be embedded directly in the heredoc.

**Preserved during update:** `output/`, `raw/`, `tmp/`, `install.env`, `assets/`, `program-defaults.json` (macOS only — on Linux, `program-defaults.json` lives in `DATA_ROOT=/var/lib/lss-network-tools` which is separate from `APP_ROOT` and unaffected by updates).

Update helper sequence: rm old files → cp new files → `--install-deps` (to /dev/null) → merge assets → `--build-wifi-helper` → `--write-completions` → verify version → log → write `/tmp/.lss-last-update` → relaunch.

**Post-update status message:** The heredoc writes `echo "$remote_tag" > /tmp/.lss-last-update` before `exec`ing the relaunch. On next startup, `startup_menu()` reads this file, sets `_LSS_STATUS_MSG="Updated successfully to vX.Y.Z"`, deletes the file, and displays the message on first render (one-shot). This is necessary because `exec` starts a new process — shell variables cannot survive across it.

**curl during download:** `download_tag_zipball()` uses `curl -s` (silent) to suppress the progress meter. A `printf "  Downloading %s...\n"` line is printed before the curl call instead.

---

## Error Handling Patterns

```bash
set -euo pipefail              # strict mode throughout
trap finalize_run EXIT         # always runs: build report, copy debug log, write manifest
trap handle_err_exit ERR       # detects network drop, sets NETWORK_INTERRUPTED=true

command || true                # suppress expected failures
2>/dev/null                    # suppress stderr for optional commands
python3 ... 2>/dev/null || true  # Python subprocess failures don't exit script
```

**`finalize_run()`** — if not NETWORK_INTERRUPTED: builds report, copies debug log, writes manifest.json.

**`handle_err_exit()`** — checks if interface lost connection; if so sets NETWORK_INTERRUPTED and prints recovery message (suggests "Continue This Run").

---

## UI / Display Conventions

**2-space indent rule:** All user-visible CLI output uses a 2-space indent prefix. Every `printf` or `echo` with text content in menu/display functions must start with `  `. Blank `echo` lines are fine without. This applies to: `startup_menu`, `main_menu`, `check_tools`, `about_and_health`, `manage_results_for_run_dir`, `continue_run_from_dir`, `select_interface`, `initialize_run_context`, `check_for_updates`, `perform_installed_update`, and all interactive/display functions.

**Task output indenting:** The 19 task functions themselves do NOT use the 2-space prefix internally — they output flush-left. `run_task_with_results_output()` wraps each task run by redirecting stdout through an awk indenter:

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

Always write to a temp file, never use `python3 - <<'PYEOF' < $input_file` (file redirect overrides heredoc stdin):

```bash
local tmp_py
tmp_py="$(mktemp /tmp/lss-prefix-XXXXXX.py)"
cat > "$tmp_py" << 'PYEOF'
# python code here
PYEOF
python3 "$tmp_py" "$arg1" < "$input_file"
rm -f "$tmp_py"
```

---

## Run Context / Session

`initialize_run_context()` prompts for Location, Client Name, Note → builds `RUN_OUTPUT_DIR`:
```
output/{client-slug}-{location-slug}-{dd-mm-yyyy}[-{note-slug}]
```

Report file:
```
{RUN_OUTPUT_DIR}/lss-network-tools-report-{client}-{location}-{date}-{HH-MM}.txt
```

`current_output_dir()` returns `RUN_OUTPUT_DIR` if active, else `OUTPUT_DIR`.

---

## Continue This Run

`continue_run_from_dir()` — restores full RUN_* session state from a previous run directory, re-checks network (compares stored gateway to current), shows task completion status ([x] done, [!] corrupt, [ ] pending), lets user skip tasks, runs only pending/corrupt tasks.

---

## Manage Previous Runs / Manage Results

**`manage_previous_runs()`** — lists past run directories, lets user select one.

**`manage_results_for_run_dir(run_dir)`** — per-run action menu with options:
- **Continue Run** — calls `continue_run_from_dir()` after network check (`load_run_metadata_from_dir` + `check_continue_run_network`). Saves/restores `SELECTED_INTERFACE` around the network check.
- **Manage Results** — lists completed task JSON files; selecting one opens a sub-menu:
  - **1) View Results** — pretty-prints the JSON
  - **2) Edit Results** — shows a numbered list of top-level scalar fields with current values; user picks a field number to edit, `s` to save changes to file, `0` to cancel (discard). Works on a temp copy (`mktemp`), only writes back on `s`.
  - **000) Delete This Result** — red destructive option; requires typing `YES` or `yes` to confirm (`${var,,}` lowercase expansion)
- **000) Delete This Run** — deletes entire run directory; requires `YES`/`yes` confirmation

**Network check in Manage Results:** Before running a task from results viewer, `load_run_metadata_from_dir` must be called first (populates stored gateway/network), then `check_continue_run_network`. `SELECTED_INTERFACE` is saved before and restored after to avoid clobbering the active session interface.

---

## Menus

**`startup_menu()`:** 1) Run / 2) Manage Previous Runs / 3) Check For Updates / 4) About & Install Health / 5) Program Defaults / 6) Exit

On each render: checks `/tmp/.lss-last-update` (post-update marker) → sets `_LSS_STATUS_MSG` → deletes file. Displays `_LSS_UPDATE_BANNER` if a newer version is available. Displays `_LSS_STATUS_MSG` one-shot then clears it.

**`main_menu()`:** Lists all 19 tasks + `000` for complete audit + `0` back. Task number typed = task ID passed to `run_task_by_id()` via `run_task_with_results_output()`.

**`continue_run_from_dir()`:** Empty Enter or `0` both go back. Typing a task list (e.g. `1,3`) runs only those tasks. Task 10 (stress test) still requires explicit confirmation before running.

## Program Defaults

Stored in `$DATA_ROOT/program-defaults.json` (`PROGRAM_DEFAULTS_FILE`). Survives updates (preserved in macOS update helper; on Linux it's in `DATA_ROOT` which is separate from `APP_ROOT`).

**Helper functions:**
```bash
get_program_default(key, fallback)   # reads key from JSON, returns fallback if missing
set_program_default(key, value)      # upserts key into JSON file
```

**Defined keys:** `unifi_domain`, `unifi_port`, `unifi_https`

**`program_defaults_menu()`** — startup option 5. Adapts dynamically:
- Before setup (no file): 1=Setup, 2=View, 3=Edit
- After setup: 1=View, 2=Edit

**`_setup_program_defaults()`** — first-time wizard; domain prompt shows `Controller domain or IP:` without revealing the built-in default in the prompt text (default `unifi.lssolutions.ie` applied silently on empty Enter).

**Bug history:** `configure_runtime_paths()` has an early `return 0` in the `install.env` branch. `PROGRAM_DEFAULTS_FILE` must be set inside that branch before the return, not after — otherwise it stays empty in installed mode and `set_program_default` fails with "No such file or directory".

---

## check_tools() Output Format

`check_tools()` runs at startup (after `clear_screen_if_supported`). All output uses 2-space indent. All required and optional deps are listed under a single "Dependency Checklist:" heading — no sub-sections for optional tools. Status tags use fixed-width padding so content columns align:

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
- `brew_install_if_missing($cmd, $formula)` — skips if already installed; uses tap path for sshpass (`hudochenkov/sshpass/sshpass`)
- Linux: apt-get or dnf; always `pip3 install fpdf2` after package install
- Writes `install.env` to APP_TARGET_DIR with all paths — this is what switches the script into installed mode
