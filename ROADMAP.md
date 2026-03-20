# LSS Network Tools — Roadmap

## In Progress / Recently Shipped

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

### Task 15: Wireless Scan
Capture wireless environment data on the selected interface.
- SSIDs/BSSIDs in range
- Signal strength and channel
- Security mode (Open/WPA2/WPA3)
- Channel congestion (competing APs on same channel)
- Tools: `airport` (macOS), `iw`/`iwlist` (Linux)

### Stress Test Latency Visualisation
Render an ASCII chart of latency over time across the 7 stress stages using `awk` — no new dependencies. Makes the stress test section of the report far more compelling for client presentation.

---

## Medium Value / Medium Effort

### ~~ARP Table Dump + Conflict Detection~~ ✓ Done in v1.0.50 (Task 15)

### Port Scan Remediation Context (Task 11)
Add a built-in lookup table of common ports with risk context. Example: port 23 = Telnet = unencrypted remote access (high risk), port 512 = rexec = high risk. Makes the custom port scan report actionable without requiring auditor expertise on every port number.

### Task 16: Traceroute
Hop-by-hop path to the gateway and to a public IP (e.g. 1.1.1.1). Useful for diagnosing unexpected routing paths, extra hops, or traffic leaving the network through an unintended exit point. Tools: `traceroute` (macOS/Linux), `tracepath` (Linux fallback).

### Task 17: NTP / Time Sync Check
Scan for NTP servers on the local network (port 123). Test whether the local clock is synchronised. Out-of-sync clocks cause certificate errors, AD authentication failures, and log correlation issues — common in SME environments.

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
