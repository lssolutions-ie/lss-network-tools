# Research: interactive surface of `lss-network-tools.sh` (v1.2.246)

Everything a non-interactive `--run-task` mode must bypass, and everything a GUI that drives the script must know about its I/O. Line numbers refer to v1.2.246 (HEAD 474e45d).

## Four facts that apply to every prompt

1. **`read -p` writes its prompt to stderr, and only when stdin is a terminal.** With stdin from a pipe no prompt text appears at all; a GUI cannot detect prompts by text unless it runs the script under a pty.
2. **EOF on stdin behaves differently inside and outside tasks.** Outside tasks `set -e` is active, so a failed `read` exits the script (EXIT trap runs). Inside tasks `set -e` is off (dispatchers call `run_task_by_id` inside `if !`), so a failed `read` just leaves the variable empty: Tasks 13–16 ignore `prompt_for_target_ip`'s return code and continue with an empty target; the two Task 17 loops spin forever; Tasks 19 and 20 fail validation and `return 0` without writing JSON.
3. **After `initialize_debug_logging` (L382) stdout and stderr are merged**: `exec > >(tee -a "$SESSION_DEBUG_LOG") 2>&1`. Only `check_tools`, `warn_if_not_root`, `parse_args` errors and the `--version/--update/--uninstall` modes keep separate streams.
4. **ANSI colour codes are always printed** (no TTY check), except the green highlighting in `select_interface`. Screen clears happen only when stdin is a TTY (`detect_output_tty`).

## A. Startup, run setup, top-level loop

| Function | Line | Prompt | Variable | Accepted input | Non-interactive substitute |
|---|---|---|---|---|---|
| `check_tools` | 4065 | `Do you want to install missing dependencies now using install.sh? (y/n):` (loops) | `choice` | y/yes → runs install.sh; n/no → exit 1 | Never prompt; print a machine-readable error and exit with a distinct code (3). Never run install.sh automatically. |
| `startup_menu` | 3315 | `Choose option:` | `choice` | 1 Run, 2 Previous Runs, 3 Updates, 4 About, 5 Program Defaults, 6 exit | Skip entirely. |
| `select_interface` | 4279 | `Enter selection:` | `choice` → `SELECTED_INTERFACE` | 0 back; 1..N (IPv4 interfaces first, loopback excluded) | `--interface X` (must be provided); validate against `list_interfaces` (L4140); warn but continue when `interface_has_valid_ip` fails. |
| `initialize_run_context` | 1468–1470 | `Location:`, `Client Name:`, `Note (optional …):` | `RUN_LOCATION`, `RUN_CLIENT_NAME`, `RUN_NOTE` | free text; empty → `Unknown` (note may be empty) | `--location`, `--client`, `--note` |
| `prompt_prepared_by` | 1521 | `Prepared by (full name):` | `RUN_PREPARED_BY` | free text | Only called from `build_report_for_run_dir`; optional `--prepared-by`. |
| top-level loop | 12447 | `Save report? [y/N]:` | `_save_choice` | only y/Y saves; **anything else `rm -rf`s the run directory** | Never reach it: call `finalize_run` + `generate_pdf_report` directly; `--yes` = save. |
| `run_all_tasks` → `confirm_gateway_stress_operation` | 12154 → 262 | `Proceed? [y/N]:` | `confirmation`; stores `HIGH_IMPACT_STRESS_CONFIRMED_TARGET` | `^[Yy]$` | `--yes`; otherwise refuse with a distinct exit code. |

## B. Main menu and runner loops

| Function | Line | Prompt | Accepted input | Substitute |
|---|---|---|---|---|
| `main_menu` | 12261 | `Enter selection:` | `000` audit; `0` summary; N; lists/ranges via `expand_task_selection` (11756) | `--run-task <id>` (optionally `000` or a list) |
| `run_task_with_results_output` | 12135, 12146 | `Press Enter to continue...` | Enter; skipped with 3rd arg `--no-pause` | Always `--no-pause`, or bypass the wrapper. |
| `show_multi_task_summary` | 11905, 11971, 12046 | `Choose option:` 1 save / 2 view / 3 continue / 4 delete; Press Enter; task list | — | N/A |

## C. Prompts inside tasks (reachable from `run_task_by_id`)

| Task | Line | Prompt | Variable | Accepted | Substitute |
|---|---|---|---|---|---|
| 13, 14, 15, 16 via `prompt_for_target_ip` | 1354 (callers 6864, 9033, 7399, 7174) | `Target IP Address:` / `Target DNS IP Address:` (error → stderr; loops) | `target_ip` (echoed on stdout, captured with `$(…)`); returns 1 on EOF and **callers ignore that** | dotted IPv4, octets 0–255 | `--target IP` (must be provided) |
| 10, 14 via `run_stress_test_for_target` → `confirm_gateway_stress_operation` | 8586 → 262 | yellow warning + `Proceed? [y/N]:` | `confirmation`; sets `HIGH_IMPACT_STRESS_CONFIRMED_TARGET` | `^[Yy]$` else "cancelled", return 1 | `--yes` required for 10/14. Task 10's description is `"the detected local gateway/firewall"` (matches `run_all_tasks`' default so one consent covers the audit); Task 14's is `"the specified target host $IP"`. Task 10 skips without prompting when the gateway is public (`status:"skipped"`, L9123). |
| 17 `wireless_site_survey` | 8380 | `Select wireless interface:` (only if `SELECTED_INTERFACE` is not wireless) | `sel` → `iface` | `00` → `_GOTO_MAIN_MENU`; `0` → return 0 no JSON; 1..N | `--wifi-interface W`, default first of `list_wireless_interfaces` |
| 17 | 8408–8410 | `Building name:`, `Floor:`, `Room / Area:` | `building`, `floor`, `room` | free text | `--building/--floor/--room` |
| 17 | 8419 | `Is there a Wi-Fi access point physically present in this room? (y/n):` (**loops forever on EOF**) | `ap_ans` | y/n | `--ap-present y|n` (default n) |
| 17 | 8422 | `AP label / ID (…):` | `ap_label` | free text | `--ap-label` |
| 17 | 8477 | `Choice:` 1 room / 2 floor / 3 building / 4 finished / 00 back (**loops forever on EOF**) | `choice` | 1 → 8480; 2 → 8484–85; 3 → 8489–91; 4 writes JSON; 00 saves partial as `completed_with_warnings` | Non-interactive: scan one room then behave as `4`. Multi-room needs its own protocol (GUI drives one room per invocation with `--run-dir`). |
| 19 `unifi_adoption` | 11428 | `Controller domain or IP [$_def_domain]:` | `controller_domain` | default from Program Defaults; scheme/path/port stripped; must match `^[A-Za-z0-9.-]+$` else `[ERROR]` + `return 0`, **no JSON** | `--controller` |
| 19 | 11440 | `Controller port [$_def_port]:` | `controller_port` | 1–65535 else return 0 no JSON | `--controller-port` |
| 19 | 11450/11457 | `Use HTTPS? [Y/n]` or `[y/N]` (skipped for port 443) | `use_https` | Y/n | `--https y|n` |
| 19 | 11466 | `SSH Username:` | `ssh_user` | free text | `--ssh-user` (must be provided) |
| 19 | 11467 | `read -r -s -p "SSH Password:"` | `ssh_pass` | no echo | **never argv**: env var (`LSS_SSH_PASSWORD`) or fd. sshpass already receives it via `SSHPASS` + `-e`. |
| 20 `find_device_by_mac` | 11596 | `Enter MAC address (any format):` | `raw_mac` → `norm_mac` | normalised to `aa:bb:cc:dd:ee:ff`; invalid → `[ERROR]` + `return 0`, **no JSON** | `--mac M` (must be provided) |

## D. Prompts not reachable from a single `--run-task`

`perform_installed_update` L774 `Install update? [y/N]` (**so `--update` is interactive**); `uninstall_installed_application` L1099/1103/1137 (`DELETE`); `build_report_for_run_dir` L1765/1769/1837; `delete_all_previous_runs` L1887; `check_continue_run_network` L2020/2037; `continue_run_from_dir` L2100/2157/2186/2210; `manage_results_for_run_dir` L2321–2636 (L2586 and L2610 read **`</dev/tty`** explicitly, so they fail without a controlling terminal); `compare_runs_cli` L2695/2857; `build_compare_report_for_run_dir` L2893–2920; `run_action_submenu` L2988/3012; `manage_previous_runs` L3051/3066; Program Defaults L3106–3254.

## E. Things that block without a `read`

- Task 4 (L9203–9206): when not root but `sudo` exists it runs `sudo nmap --script broadcast-dhcp-discover` → **sudo may prompt for a password**.
- Task 17 macOS helper (L8284–8330): `open -n -W LSS-WiFiScan.app` as `$SUDO_USER`; first run may show the Location Services dialog; 90 s cap.
- Task 19 (L11370–11376): may run `brew install` / `apt-get install -y sshpass`.
- `check_tools` may run `install.sh` interactively (its own freshness prompt; `LSS_SKIP_FRESHNESS_CHECK=1`).

## 1. `parse_args` (L1168), CLI flags, startup sequence

Recognised flags (no values): `--debug`, `--uninstall`, `--update`, `--version`, `--build-wifi-helper`, `--write-completions`, `--install-deps`. Anything else → `Unknown option` + usage, exit 1. New valued flags need `case` arms that `shift` twice; the completion list in `write_completion_files` (L979) must be updated too.

Top-level sequence (L12340–12463): `parse_args` → `--version` (prints `lss-network-tools vX`, exit 0) → `--build-wifi-helper` (detect_os, configure_runtime_paths, build; exit 0/1) → `--write-completions` → `--install-deps` → `detect_os`, `ensure_standard_path`, `configure_runtime_paths`, `ensure_runtime_directories` (mkdir OUTPUT_DIR/TMP_ROOT/raw, export TMPDIR) → `--uninstall` → `--update` (interactive) → `detect_output_tty`, `clear_screen_if_supported` → `check_tools` → `warn_if_not_root` → `initialize_debug_logging` (removes stale `.debug-session-<dead pid>.txt`; **exits 1 if OUTPUT_DIR is not writable** with "This program must be run with elevated privileges"; sets `SESSION_DEBUG_LOG`; global tee redirect) → traps `on_exit_trap EXIT`, `on_interrupt INT TERM`, `handle_err_exit ERR` → macOS `caffeinate -d -i -w $$ &` → update-banner `curl --max-time 2` → main loop (`startup_menu` → `select_interface` → `initialize_run_context` → `main_menu` → `Save report?`).

**Recommended `--run-task` insertion point:** after the traps; skip caffeinate (or keep), skip the banner check and the main loop. Set `SELECTED_INTERFACE`, build the run context from flags, call `run_task_by_id` directly (or a non-pausing wrapper), then `finalize_run` + `generate_pdf_report`, clear `RUN_OUTPUT_DIR`, exit with the task status. `check_tools` must not prompt.

## 2. `run_task_by_id` dispatch (L11801)

| ID | Function | Mid-task interaction |
|---|---|---|
| 1 | `interface_info "$SELECTED_INTERFACE"` | none |
| 2 | `internet_speed_test` | none (spinners) |
| 3 | `gateway_details "$SELECTED_INTERFACE"` | none |
| 4 | `dhcp_network_scan` | none; `sudo nmap` when not root |
| 5 | `dhcp_response_time` | none |
| 6–9 | `detect_dns_servers`, `detect_ldap_servers`, `detect_smb_nfs_servers`, `detect_print_servers` | none |
| 10 | `gateway_stress_test` → `run_stress_test_for_target` | stress confirmation |
| 11 | `vlan_trunk_scan` | none; tcpdump 10 s + 65 s |
| 12 | `duplicate_ip_detection` | none; arp-scan + root |
| 13 | `custom_target_port_scan` | target IP |
| 14 | `custom_target_stress_test` | target IP + stress confirmation |
| 15 | `custom_target_identity_scan` | target IP |
| 16 | `custom_target_dns_assessment` | target DNS IP |
| 17 | `wireless_site_survey` | interface pick, building/floor/room, AP y/n, AP label, navigation loop |
| 18 | `unifi_device_scan` | none; EUID check (returns 1) |
| 19 | `unifi_adoption` | controller host/port/https, SSH user, password |
| 20 | `find_device_by_mac` | MAC; EUID check (returns 0 — inconsistent with 18) |

Multi-entry tasks: 10, 13, 14, 15, 16 (`task_supports_multiple_entries` L1214; `next_multi_entry_index` L1268). `run_all_tasks` (L12149) confirms stress once, then runs 1–12 via `run_task_with_progress_output`, printing `Function N (title) failed — continuing…` on failure.

## 3. Output wrappers

- `run_task_with_results_output id title [--no-pause]` (L12098): clears screen, prints header `  Task N — Title`, description, rule; `SHOW_FUNCTION_HEADER=0`; `exec 8>&1; exec 1> >(awk '{print "  " $0; fflush()}' >&8)` (**stdout only**); `if ! run_task_by_id`; `exec 1>&8 8>&-; sleep 0.2`; footer; `Press Enter` unless `--no-pause`; returns 1 on failure. stderr bypasses the indenter (prompts, spinner frames, `>&2` errors) but still lands in the tee.
- `run_task_with_progress_output id title` (L11827, used by `run_all_tasks`): prints `  %3s)  Title...` without newline, runs `run_task_by_id "$id" >>"$SESSION_DEBUG_LOG" 2>&1`, then `  Done` / `  Failed`. **All task output goes to the debug log** → coarse per-task progress only.

Parseable progress markers (plain stdout lines, indented 2 spaces by the wrapper): `Stage N: …` (tasks 3, 4, 6–9, 10, 13–16), `Step 1/2`, `Step 2/2` (11), `Step 1:`/`Step 2:` (18), `DHCP discovery attempt N of M...` (4); spinner labels `ARP pass n/5`, `UDP pass n/10` (18).

## 4. Run context, finalize, manifest, traps

- `initialize_run_context` (L1453): resets stress consent; prompts; slugs via `sanitize_for_filename` (L281); `RUN_DATE_STAMP=dd-mm-yyyy`, `RUN_REPORT_TIME_STAMP=HH-MM`; `RUN_OUTPUT_DIR=$OUTPUT_DIR/{client}-{location}-{date}[-{note}]` with `-{HH-MM}[-N]` uniqueness suffix (L1497–1505); `RUN_REPORT_FILE`, `RUN_DEBUG_LOG=debug.txt`, `RUN_MANIFEST_FILE=manifest.json`; `mkdir -p` run dir + `raw/`; prints `  Run output directory: <path>` (parse this or add a machine line). `RUN_PREPARED_BY` not set here.
- A `--run-dir D` flag should mirror `continue_run_from_dir` (L2053): set `RUN_OUTPUT_DIR`, `RUN_DEBUG_LOG`, `RUN_MANIFEST_FILE`, call `load_run_metadata_from_dir` (L1685), and **not** touch `SESSION_DEBUG_LOG`.
- `finalize_run` (L3796): if `NETWORK_INTERRUPTED != true` and the run dir has `*.json` → `build_report_for_current_run` (prints `  Report built successfully: <file>`); copies session log to `debug.txt`; `write_manifest_for_current_run`; if `_LSS_EXITING=1` removes session log, stops spinner, `kill_registered_bg_pids`, kills caffeinate; else truncates the session log.
- `write_manifest_for_current_run` (L3660): keys as in research 03; runs `validate_json_file`.
- `generate_pdf_report` (L3760): silently returns 0 if `RUN_OUTPUT_DIR` empty, python3/.py/manifest missing; prints `  Generating PDF report...`, then `  PDF report:    <path>` or `  PDF generation failed: <err>`. PDF = `${RUN_REPORT_FILE%.txt}.pdf`. **The EXIT trap never generates a PDF.**
- Traps: `on_exit_trap` sets `_LSS_EXITING=1` → `finalize_run` (so a non-interactive run with `RUN_OUTPUT_DIR` set gets TXT+manifest at exit even without explicit save; clear `RUN_OUTPUT_DIR` after an explicit save). `on_interrupt` → `exit 130`. `handle_err_exit` only acts when `SELECTED_INTERFACE` and `RUN_OUTPUT_DIR` are set and `interface_has_valid_ip` fails; never fires inside tasks.

## 5. stdout vs stderr, spinners

- Explicit `>&2` writes: L710 curl error; L1370 invalid IP; L6190/6194 `spinner`; L6216/6235 `start_spinner_line`/`stop_spinner_line`; L8313/8324 Wi-Fi helper; L11770–11793 `expand_task_selection`.
- `spinner [msg]` (L6166) waits on `$!`, prints `\r<indent>[frame] msg` to stderr every 0.2 s (braille frames under UTF-8, else `-\|/`), ends with `\r\033[K`.
- `start_spinner_line label` (L6197) background subshell printing `\r<indent><label> <frame>` to stderr; `SPINNER_PID` (not registered; `finalize_run` stops it). `stop_spinner_line` (L6224) kills/waits and prints `\r\033[K`.
- **`--debug` (`DEBUG_MODE=1`) makes spinners print their label once as a normal line with no `\r` frames** — the easiest GUI-friendly mode. `monitor_nmap_progress` also prints `"$label none found"` in debug mode.
- GUI implications: handle `\r` and `\033[K` or force debug-style spinners (a new quiet flag); `clear` escapes only when stdin is a TTY.

## 6. `check_tools` (L3953) and `warn_if_not_root` (L3892)

Required: `nmap awk sed grep find mktemp jq speedtest-cli python3` + macOS `ipconfig ifconfig route networksetup ping tcpdump` / Linux `ip ping tcpdump`, plus python modules `scapy`, `fpdf`. Optional (warn): `ifconfig` (Linux), `sshpass`, `arp-scan`, airport/system_profiler, `iw`. Output: `Startup Check`, `Dependency Checklist:`, `[OK]      x` / `[MISSING] x` / `[WARN]    …`; install hints via `print_install_hint` (unindented). If anything required is missing: y/n loop (yes → `bash $SCRIPT_DIR/install.sh`, exit 1 on failure or if still missing; no → exit 1; EOF → set -e exit). Otherwise prints `All required dependencies are available.` and never prompts. `warn_if_not_root` prints one line when not root; never exits.

## 7. sudo and root expectations

The wrapper does not elevate; users run `sudo lss-network-tools`. In installed mode without root `initialize_debug_logging` finds `OUTPUT_DIR` unwritable → **exit 1**. So a non-root launch of the installed copy cannot reach any task; portable mode works if `SCRIPT_DIR` is writable.

| Task | Without root |
|---|---|
| 4 | `sudo nmap …` may prompt; tcpdump capture skipped |
| 5 | raw sockets; effectively needs root |
| 11 | `tcpdump -Z root -w` with no EUID check; captures nothing |
| 12 | arp-scan needs root; empty result → failure JSON |
| 18 | explicit check → `insufficient_privileges`, returns 1 |
| 20 | explicit check → `insufficient_privileges`, returns 0 |
| `nmap -sn` | no MAC addresses (degrades 15, ARP discovery) |
| 17 (macOS) | helper runs as `$SUDO_USER` via `sudo -u … open -W`; without sudo as current user |
| 19 | sshpass auto-install via `sudo -u $SUDO_USER brew` |

`invoking_user_home` (L332) resolves the real user's home via `SUDO_USER` (dscl/getent); used by `default_report_export_dir` (L1675) and `expand_user_path` (L349).
