# LSS Network Tools — Roadmap

## In Progress / Recently Shipped

- **v1.0.88** — Wireless scan: fix Location Services notification timing — guidance popup now appears FIRST (1s before the banner fires) so the user is already watching the top-right corner when the Allow/Deny banner appears
- **v1.0.87** — Wireless scan: fix Location Services flow — Swift location request now runs in background; osascript GUI dialog immediately tells user to click the notification banner at top-right before it disappears; falls back to opening System Settings if denied or timed out
- **v1.0.86** — Wireless scan: use Swift CLLocationManager to trigger the "Terminal would like to use your location" dialog on macOS — this is what actually adds Terminal to System Settings → Location Services so the user can enable it. Falls back to manual instructions if swift is not available.
- **v1.0.85** — Wireless scan: detect all-redacted SSIDs (macOS Location Services off), open System Settings automatically and re-scan after user enables it; fix signal display (null rssi stored as null not 0, noise removed from signal column); fix band normalisation (2GHz → 2.4GHz); fix sort order with null rssi values
- **v1.0.84** — Wireless scan: fix all-redacted SSID deduplication collapse (deduplicate removed, filter by selected iface only, skip awdl0/p2p0); add band, channel_width, phy_mode, noise_floor_dbm fields; PDF/TXT renderers updated to show new columns; Linux scanner updated to same schema
- **v1.0.83** — Fix wireless scan returning empty when run as sudo: system_profiler returns no Wi-Fi data in root context; Python subprocess now drops back to original user (SUDO_USER) via preexec_fn before calling system_profiler
- **v1.0.82** — Fix wireless scan: missing "import os" in embedded Python script caused NameError on os.path.isfile check; silently returned empty networks array
- **v1.0.81** — Fix wireless scan on macOS: system_profiler parser rewritten with correct field names (spairport_airport_interfaces, spairport_airport_other_local_wireless_networks, spairport_signal_noise, spairport_network_channel, spairport_security_mode); RSSI parsed from "-46 dBm / -96 dBm" string; channel extracted from "36 (5GHz, 20MHz)"; duplicate SSID deduplication via seen set
- **v1.0.80** — Fix: airport missing on macOS 15+ no longer counts as an install health issue; system_profiler fallback added for wireless scan; Check Install Health now shows software versions (app, nmap, jq, python3, fpdf2, scapy, speedtest-cli)
- **v1.0.79** — Startup dependency check now includes Task 17 wireless tools (airport on macOS, iw on Linux) as optional/non-blocking warnings; surfaced immediately after update relaunch so missing tools are not discovered mid-task
- **v1.0.78** — Task 17: PDF renderer (summary table + per-room network detail, top 5), TXT renderer, About page entry, custom task note updated to 13–17; Install Health adds airport/iw check for Task 17
- **v1.0.77** — Task 17: Wireless Site Survey — room-by-room Wi-Fi survey; verifies interface is wireless (prompts to switch if not); asks building/floor/room + AP presence (y/n) + optional AP label; scans and shows count + strongest network after each room; navigation menu to move room/floor/building or finish; outputs single JSON with full survey array. Not included in 000 audit.
- **v1.0.76** — Startup menu: About (option 5) now shows Python version and task count (total/audit/custom); Install Health (option 6) expanded to match startup dependency check (adds awk, sed, grep, find, mktemp, python3, python3-scapy, python3-fpdf2)
- **v1.0.75** — About This Report: custom task footer note now says "were also run" when tasks 13-16 actually ran (was always "may appear"); added comment explaining ran_task_ids or None fallback
- **v1.0.74** — Cover card: navy border and row separators (was grey), label colour navy, value colour muted grey (was swapped)
- **v1.0.73** — Cover metadata card redesigned: clean white card, uppercase muted labels, bold navy values, subtle row separators, no alternating backgrounds. About This Report: only shows tasks actually run in the report (json_present=true in manifest), not all 12 tasks.
- **v1.0.72** — Task 5: switch DHCP receive socket to SOCK_DGRAM on port 68 (macOS system DHCP uses BPF so port is free; DGRAM reliably delivers broadcast on Wi-Fi where SOCK_RAW misses frames); fall back to SOCK_RAW on Linux. Cover metadata card: switch value cells to multi_cell with dynamic row heights — prevents text overflowing card boundary on long values.
- **v1.0.71** — PDF: page 1 footer text white (was grey, invisible on navy strip); About page compressed to single page (LINE_H 4.2→3.8, font 7.5→7, smaller header/intro); Task 5 Probes/Replies display order fixed (was reversed)
- **v1.0.70** — Fix PDF layout: disable auto_page_break during cover() to prevent confidentiality strip overflowing to page 2; rewrite render_about_report() with manual page break checks and accurate row-height measurement via get_string_width(), redraw table header on continuation pages
- **v1.0.69** — Fix double "Press Enter" prompt after delete: startup menu already has its own pause; remove duplicate from inside delete_all_previous_runs
- **v1.0.68** — Fix bash 3.2 crash on macOS: replace ${confirmation,,} with =~ ^[Yy]$ in delete runs and stress test confirmation
- **v1.0.67** — Fix PDF crash: safe() now transliterates em dash, sigma, curly quotes and other common unicode before Helvetica encoding; subtitle string wrapped in safe()
- **v1.0.66** — PDF cover redesign: full-width navy band, centred logo, light-blue accent divider, decorative network topology nodes, drop-shadow metadata card with left accent bar, confidentiality strip; new "About This Report" page (page 2) with plain-English task descriptions
- **v1.0.65** — PDF: Key Findings and Remediation Hints moved to page 2; cover is now a standalone page 1
- **v1.0.64** — Integrity and transparency: VM detection in interface info, DHCP/speed/stress methodology notes, SMB signing detection per host (nmap smb2-security-mode), SMB signing finding + remediation hint; all notes surfaced in PDF
- **v1.0.63** — Simplify 000 audit stress test confirmation from "Type PROCEED" to y/N prompt
- **v1.0.62** — Fix VLAN manifest bug; enrich gateway port names (Zabbix/HTTP callouts); add NFS exposure and printer JetDirect findings with remediation hints
- **v1.0.61** — Simplify delete all runs confirmation: replace "Type DELETE" with y/N prompt
- **v1.0.60** — DHCP response time: replace SOCK_DGRAM port-68 receive with SOCK_RAW; eliminates competition with system DHCP client on macOS/Linux
- **v1.0.59** — Increase DHCP response time probe count from 5 to 10 for more reliable statistics
- **v1.0.58** — Fix interface list losing green colour after update relaunch: check stdin (fd 0) for TTY instead of stdout (fd 1), which is piped through tee when relaunched via exec sudo
- **v1.0.57** — DHCP Response Time: detect Wi-Fi interface (macOS + Linux), apply relaxed thresholds, surface Wi-Fi note in warnings and PDF report
- **v1.0.56** — Fix DHCP response time: replace scapy with pure Python stdlib socket approach (SOCK_DGRAM + SO_BROADCAST); eliminates BPF/promiscuous mode requirement; works on macOS and Linux
- **v1.0.55** — Fix DHCP response time: disable promiscuous mode on sniff (macOS blocks it; DHCP offers are broadcast so promisc not needed)
- **v1.0.54** — Fix DHCP response time Python crash: add outer exception handler, capture stderr, broaden BPF filter to port 67+68
- **v1.0.53** — Fix DHCP port scan fatal failure; switch to top-1000 ports, make timeout non-fatal; 000 audit continues past task failures
- **v1.0.52** — Task 5: DHCP Response Time — measures Discover-to-Offer latency (min/avg/max) using scapy; renumbers tasks 5-16
- **v1.0.51** — Fix misleading "authentication required" error on update check failure; repo is public, error now points to network/connectivity
- **v1.0.50** — Task 11: Duplicate IP Detection — ARP scan to find IPs responding with multiple MACs; custom tasks renumbered 12-15
- **v1.0.49** — Auto-relaunch after update; exec as root if already privileged, else sudo
- **v1.0.48** — Simplify update flow: remove backup prompt and TYPE UPDATE step, replace with y/N confirm
- **v1.0.47** — Fix PDF crash: self.note shadowed note() method, renamed to self.run_note
- **v1.0.46** — Renumber tasks: VLAN/Trunk=10, Custom Port Scan=11, Custom Stress=12 across menu, audit, PDF and TXT
- **v1.0.45** — Move task 12 (VLAN/Trunk) before custom tasks 10/11 in menu and audit order
- **v1.0.44** — Add optional Note field to runs; show time+client+note in previous run list; VLAN task moved before custom tasks in PDF
- **v1.0.43** — Function menu (1-14, 000) option 0 now returns to startup menu instead of quitting
- **v1.0.42** — Remove redundant 'Prepared By' prompt on menu exit; it is asked in report builder
- **v1.0.41** — Report bug fixes and improvements: task names in findings, remove Success field, DHCP relay-only note, VLAN PDF completeness, hint styling fix, jitter stddev annotation, function gap note, printer title fix, remove duplicate Generated field
- **v1.0.40** — PDF prettification: tighter cover, stage table, colour-coded flags, hint accents
- **v1.0.39** — Add --update CLI flag
- **v1.0.38** — Reduce cover page metadata card line spacing
- **v1.0.19** — PDF report output with cover page, logo, findings, remediation hints, and per-task sections
- **v1.0.18** — Task 12: VLAN/Trunk Detection (802.1Q passive capture, CDP/LLDP neighbour parsing via scapy)

---

## High Value / Low Effort

### ~~PDF Report Output~~ ✓ Done in v1.0.19
Cover page with logo, dark navy branding, client/location/date, executive summary with colour-coded severity badges, remediation hints, and full per-task audit results. Logo goes in `assets/logo.svg`. Dependency: `fpdf2` >= 2.7 (pip3, includes native SVG rendering).

### Stress Test Latency Visualisation
Render an ASCII chart of latency over time across the 7 stress stages using `awk` — no new dependencies. Makes the stress test section of the report far more compelling for client presentation.

---

## Medium Value / Medium Effort

### ~~ARP Table Dump + Conflict Detection~~ ✓ Done in v1.0.50 (Task 15)

### Port Scan Remediation Context (Task 11)
Add a built-in lookup table of common ports with risk context. Example: port 23 = Telnet = unencrypted remote access (high risk), port 512 = rexec = high risk. Makes the custom port scan report actionable without requiring auditor expertise on every port number.

### Task 16: Traceroute
Hop-by-hop path to the gateway and to a public IP (e.g. 1.1.1.1). Useful for diagnosing unexpected routing paths, extra hops, or traffic leaving the network through an unintended exit point. Reports number of hops, per-hop latency, and any unresponsive hops. Tools: `traceroute` (macOS/Linux), `tracepath` (Linux fallback).

### Task 17: NTP / Time Sync Check
Scan for NTP servers on the local network (port 123). Test whether the local clock is synchronised and measure offset. Out-of-sync clocks cause certificate errors, AD authentication failures, and log correlation issues — common in SME environments. Tools: `ntpdate -q`, `chronyc tracking`, `timedatectl`.

---

## Longer Term / Bigger Impact

### Headless / Unattended Mode (`--headless`)
Accept client name, location, and interface via CLI arguments or a config file. Run the full audit non-interactively. Enables cron scheduling, remote triggering, and overnight baseline captures.

### HTML Report
Standalone HTML report alongside TXT/PDF. Features: collapsible sections, colour-coded severity badges, embedded latency chart for stress test stages. Shareable without a PDF viewer.

### Comparative Runs
Compare a run against the previous run for the same client/location. Flag: new open ports, new hosts discovered, gateway changes, degraded stress test results. Requires JSON diffing between run folders — minimal new logic, high auditor value for recurring clients.

---

## Quick Wins

| Item | Description |
|------|-------------|
| `--list-runs` flag | Print all saved runs as a table (client, location, date, tasks completed) without launching the interactive menu |
| Run notes field | Free-text note prompt at run start ("pre-migration baseline", "post-incident check") stored in manifest.json and shown in the report header |
| Manifest integrity check | Detect missing or corrupt JSON files before building a report; show a clear summary of what is present vs absent |

---

## Completed

| Version | Feature |
|---------|---------|
| v1.0.78 | Task 17 report integration: PDF summary table + per-room detail (top 5), TXT renderer, About page entry, install health airport/iw check |
| v1.0.77 | Task 17: Wireless Site Survey — room-by-room Wi-Fi survey with building/floor/room navigation, AP presence tracking, and per-room network scan |
| v1.0.76 | Startup About and Install Health updated to reflect full current dependency and task set |
| v1.0.75 | About page: custom task note adapts to whether tasks 13-16 actually ran |
| v1.0.74 | Cover card: navy border/separators, label=navy, value=muted grey |
| v1.0.73 | Cover card: clean white, uppercase labels, bold navy values, subtle separators. About page: only shows tasks actually run in the report |
| v1.0.72 | Task 5: SOCK_DGRAM/port-68 receive on macOS (SOCK_RAW missed Wi-Fi broadcast frames); cover card multi_cell prevents value text overflow |
| v1.0.71 | PDF: footer text white on page 1 (navy strip); About page fits on one page (LINE_H/font reduced); Task 5 Probes/Replies order corrected |
| v1.0.70 | Fix PDF layout: set_auto_page_break(False) during cover() prevents strip overflow; render_about_report() rewritten with get_string_width() row measurement and manual page breaks, table header redrawn on continuation pages |
| v1.0.69 | Fix double "Press Enter" prompt after delete: startup menu already owns the pause; removed duplicate added in v1.0.68 from inside delete_all_previous_runs |
| v1.0.68 | Fix bash 3.2 crash on macOS: ${confirmation,,} replaced with =~ ^[Yy]$ in delete runs and stress test confirmation |
| v1.0.67 | Fix PDF crash: safe() transliterates em dash, sigma, curly quotes and other unicode; subtitle string wrapped in safe() |
| v1.0.66 | PDF cover redesign: full-width navy band, centred logo, light-blue accent divider, network topology decoration, drop-shadow metadata card, confidentiality strip; new "About This Report" page with plain-English task descriptions |
| v1.0.65 | PDF: Key Findings and Remediation Hints moved to dedicated page 2; cover is now a standalone page 1 |
| v1.0.64 | Integrity: VM detection (is_vm/vm_platform in interface-network-info.json); DHCP/speed/stress methodology notes in JSON and PDF; SMB signing detected via nmap smb2-security-mode, surfaced per host in PDF, finding + remediation hint added; gateway scan_scope field |
| v1.0.63 | Simplify 000 audit stress test confirmation from "Type PROCEED" to y/N prompt |
| v1.0.62 | Fix VLAN manifest json_present bug (task 11 wrongly in task_supports_multiple_entries); gateway finding now shows port names and calls out HTTP/Zabbix/Telnet; NFS exposure and printer JetDirect findings added with remediation hints |
| v1.0.61 | Simplify delete all runs confirmation from "Type DELETE" to y/N prompt |
| v1.0.60 | DHCP response time: SOCK_RAW receive instead of SOCK_DGRAM on port 68; kernel copies packet to raw socket without competing with system DHCP client |
| v1.0.59 | Increase DHCP response time probe count from 5 to 10 for more reliable statistics |
| v1.0.58 | Fix interface list losing green colour after update relaunch: use -t 0 (stdin) instead of -t 1 (stdout) for TTY detection; stdout is piped through tee post-update |
| v1.0.57 | DHCP Response Time: Wi-Fi detection (sysfs on Linux, networksetup on macOS); relaxed thresholds (>500ms elevated, >2000ms critical); Wi-Fi note in PDF |
| v1.0.56 | Fix DHCP response time: replace scapy with pure Python stdlib socket (SOCK_DGRAM + SO_BROADCAST + SO_REUSEPORT); no BPF, no promiscuous mode; compatible with macOS and Linux |
| v1.0.55 | Fix DHCP response time promiscuous mode error on macOS; DHCP offers are broadcast so promisc=False is sufficient |
| v1.0.54 | Fix DHCP response time Python crash: outer exception handler, stderr capture, broader BPF filter (port 67+68) |
| v1.0.53 | Fix DHCP task fatal port scan failure; switch nmap to top-1000 ports, make failure a warning; 000 audit continues past failures |
| v1.0.52 | Task 5: DHCP Response Time — measures Discover-to-Offer latency; tasks renumbered 5-16 |
| v1.0.51 | Fix misleading "authentication required" error on update check failure; now shows network connectivity hint |
| v1.0.50 | Task 11: Duplicate IP Detection — ARP scan to find IPs responding with multiple MACs; custom tasks renumbered 12-15 |
| v1.0.49 | Auto-relaunch after update; exec as root if already privileged, else sudo |
| v1.0.48 | Simplify update flow: remove backup prompt and TYPE UPDATE step, replace with y/N confirm |
| v1.0.47 | Fix PDF crash: self.note shadowed note() method, renamed to self.run_note |
| v1.0.46 | Renumber tasks: VLAN/Trunk=10, Custom Port Scan=11, Custom Stress=12 across menu, audit, PDF and TXT |
| v1.0.45 | Move task 12 (VLAN/Trunk) before custom tasks 10/11 in menu and audit order |
| v1.0.44 | Add optional Note field to runs; show time+client+note in previous run list; VLAN task moved before custom tasks in PDF |
| v1.0.43 | Function menu (1-14, 000) option 0 returns to startup menu instead of quitting |
| v1.0.42 | Remove redundant 'Prepared By' prompt on menu exit; asked in report builder |
| v1.0.41 | Report bug fixes and improvements: task names in findings, remove Success field, DHCP relay-only note, VLAN PDF completeness, hint styling fix, jitter stddev annotation, function gap note, printer title fix, remove duplicate Generated field |
| v1.0.40 | PDF prettification: tighter cover, stage table, colour-coded flags, hint accents |
| v1.0.39 | Add --update CLI flag |
| v1.0.38 | Reduce cover page metadata card line spacing |
| v1.0.29 | Preserve assets/ dir across updates; merge-only for new bundle assets |
| v1.0.28 | Fix stress target key (.gateway), add network/ports to scans, client name fallback on cover |
| v1.0.27 | Fix PDF data mapping: speed test servers[0]/test_server, stress stages, DHCP relay/servers |
| v1.0.26 | Fix PDF kv row drift: multi_cell new_x=LMARGIN + set_x reset on every row |
| v1.0.25 | Fix PDF encoding: safe() applied to all cell/multi_cell text, explicit cell widths |
| v1.0.19 | PDF report output with logo, cover page, and colour-coded findings |
| v1.0.18 | Task 12: VLAN/Trunk Detection |
| v1.0.17 | Bug fixes: SELECTED_INTERFACE init, remote_tag guard, indentation, task 12 comment |
| v1.0.16 | Installer self-refresh for outdated bundles, installer version freshness check |
| v1.0.14 | Fix Homebrew PATH under sudo |
| v1.0.13 | Homebrew bootstrap adjustment |
