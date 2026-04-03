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

**Output JSON shape:** `{status, success, interface, subnet, devices_found, devices: [{mac, ip}], false_positives: [{mac, ip}]}`

---

## Task 19 — UniFi Adoption Detail

In `unifi_adoption()`:

1. Load IPs from Task 18's `unifi-discovery.json` — if not found, print message and `return 0` (back to menu, not exit)
2. Prompt: controller domain, port (default 8080), HTTPS (auto if port 443), SSH username, SSH password (`read -r -s`)
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

**Preserved during update:** `output/`, `raw/`, `tmp/`, `install.env`, `assets/` (macOS also preserves these).

Update helper sequence: rm old files → cp new files → `--install-deps` → merge assets → `--build-wifi-helper` → `--write-completions` → verify version → log → relaunch.

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

## Colour Variables

Colours are declared **locally per function** — never global:
```bash
local red='\033[0;31m'
local green='\033[0;32m'
local yellow='\033[1;33m'
local reset='\033[0m'
```

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

## Menus

**`startup_menu()`:** Run / Manage Previous Runs / Check For Updates / About & Install Health / Exit

**`main_menu()`:** Lists all 19 tasks + `000` for complete audit + `0` back. Task number typed = task ID passed to `run_task_by_id()`.

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
