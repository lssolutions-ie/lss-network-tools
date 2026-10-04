# lss-network-tools

Interactive network diagnostics for **macOS** and **Linux**, with per-run JSON exports, a consolidated human-readable report, and utilities for rebuilding reports from previous runs.

The tool is designed for interactive onsite diagnostics: run a daily audit for the local network, then optionally add one-off custom target scans into the same day folder without overwriting earlier results.

## Quick start

Recommended install method:

1. Download the latest release ZIP from GitHub.
2. Extract it.
3. Open Terminal in the extracted `lss-network-tools` folder.
4. Run:

```bash
chmod +x *.sh
sudo ./install.sh
sudo lss-network-tools
```

Alternative install method:

```bash
git clone https://github.com/lssolutions-ie/lss-network-tools.git
cd lss-network-tools
chmod +x *.sh
sudo ./install.sh
sudo lss-network-tools
```

After a successful install, the extracted or cloned source folder is no longer required for normal use.

## What it does

After choosing `Run LSS Network Tools` from the startup menu and selecting a network interface, the tool provides these scan functions:

1. **Interface Network Info**  
   Captures IP address, subnet mask, network range (CIDR), and MAC address.
2. **Internet Speed Test**  
   Runs `speedtest-cli` and captures public IP, test server, ping, download, and upload.
3. **Gateway Details**  
   Detects default gateway and performs full open-port scan.
4. **DHCP Network Scan**  
   Runs five DHCP discovery attempts with the interface's own MAC as the client hardware address (so DHCP snooping and Wi-Fi controllers treat the probe like a real client), records the options each server offered (router, subnet mask, DNS, domain, lease time), reads the lease this interface already holds (`ipconfig getpacket` / nmcli / systemd-networkd / dhclient) as independent evidence, captures the replies with `tcpdump -v -e` (responder MACs, real relay agents from `Gateway-IP`, servers seen passively), keeps every nmap error as a warning instead of reporting "no responders", and flags a responder as rogue only on evidence — more than one server identifier, a server that differs from the one that issued this interface's lease, an offered router off the subnet, or a server outside the subnet without a relay. Open TCP ports are informational only.
5. **DHCP Response Time**  
   Measures Discover→Offer latency with ten probes sent at layer 2 through scapy (source `0.0.0.0:68`, interface MAC, broadcast flag) and received with a BPF sniffer; falls back to the stdlib socket probe when scapy is unavailable and records which path was used. Reports per-server offer counts and latency, the offered options, and cross-checks Task 4: a probe that received nothing while discovery saw offers a moment ago is graded as a probe or receive-path problem (warning, never high), a responder discovery never saw is a possible second DHCP server (high). Loss is graded by medium (Wi-Fi tolerates more).
6. **DNS Network Scan**  
   Tests every DNS candidate, not just the local subnet: the subnet sweep (TCP and UDP 53 with DNS-aware host discovery, capped at a /22) plus the resolvers configured on the interface, the DNS servers in the DHCP offers and the system lease. Each server is tagged with its sources and tested with retried external queries (`google.com`, `microsoft.com`; response code, attempts and the Recursion Available bit recorded, recursion reported as enabled / disabled / unknown), the site's own domain and its AD SRV record when a domain is known, and an external name resolving to a private address is labelled as DNS filtering or rebinding.
7. **LDAP/AD Network Scan**  
   Scans for common Active Directory / LDAP service ports.
8. **SMB/NFS Network Scan**  
   Scans for file-sharing services (SMB/NFS/rpcbind/netbios).
9. **Printer/Print Server Network Scan**  
   Scans for common print service ports (LPD, IPP, JetDirect).
10. **Gateway Stress Test**  
   Runs repeated gateway latency and packet-loss checks to spot jitter and recovery issues under load. This is a high-impact test that targets only the detected local gateway/firewall and may disrupt routing, VPNs, or internet access on weak edge devices.
11. **VLAN/Trunk Detection**  
   Listens for tagged frames, CDP and LLDP to tell whether the port is a trunk and which VLANs are visible.
12. **Duplicate IP Detection**  
   ARP-scans the subnet for addresses that answer with more than one MAC.
13. **Custom Target Port Scan**  
   Prompts for an IP address and runs a full open-port scan against that target.
14. **Custom Target Stress Test**  
   Prompts for an IP address and runs the same high-impact ICMP stress workflow against that specific target.
15. **Custom Target Identity Scan**  
   Prompts for an IP address and combines MAC/vendor discovery, optional online vendor enrichment, hostname lookup, and conservative service fingerprinting into a single device identity profile with `device_type_hint`, `confidence`, and `identity_summary`.
16. **Custom Target DNS Assessment**  
   Prompts for an IP address and tests whether the target is a working DNS resolver over UDP and TCP, whether recursion is available, whether reverse lookups work, and whether the service exposes a software hint such as `dnsmasq`.
17. **Wireless Site Survey**  
   Scans Wi-Fi networks room by room (CoreWLAN helper on macOS, `iw` on Linux) and records SSID, BSSID, RSSI, channel and security per room.
18. **Scan For UniFi Devices**  
   Finds Ubiquiti devices on the subnet by OUI, UDP 10001 discovery, TLV fingerprinting and LLDP.
19. **UniFi Adoption**  
   Sets the inform URL on the devices Task 18 confirmed, over SSH.
20. **Find Device by MAC**  
   Vendor-neutral ARP/MAC lookup for one device on the subnet.

Results edited afterwards through Manage Results → Edit Results are stamped (`edited_at`), the manifest records each result file's SHA-256, and the TXT/PDF reports and the macOS app mark such results as edited; findings derived from an edited result are never graded higher than warning.

Additional menu options:

- `000)` **Complete Network Audit** (runs functions 1–12 sequentially)
- `0)` Exit

Startup menu utilities:

- `1)` **Run LSS Network Tools**
- `2)` **Manage Previous Runs** (continue a run, view / edit / delete results, delete a run)
- `3)` **Check For Updates**
- `4)` **About & Install Health**
- `5)` **Program Defaults**
- `6)` **Launch Graphical Interface** (macOS only — opens the installed app, see [macOS app](#macos-app))
- `7)` Exit (`6)` on Linux, where there is no graphical interface)

High-impact warning:
- `9)`, `11)`, and `000)` require typing `PROCEED` before a stress test runs.
- Stress tests send high-rate ICMP only to the chosen target and do not perform exploits or service attacks.
- If the target is a gateway or firewall, the test can still disrupt client connectivity. Run it only when service impact is acceptable.

## Key workflow features

- **Dependency checklist at startup** with optional auto-install via `install.sh` when required tools are missing.
- **Startup utility menu** for running scans, rebuilding reports from previous runs, and deleting stored runs.
- **Support utilities** for viewing installed paths/version and checking install health quickly.
- **Interactive interface selector** (on macOS, includes hardware port descriptions when available).
- **Run context prompt** for location and client name after interface selection.
- **Timestamped run folder per session** under the installed data root, so prior runs stay intact.
- **One folder per client/location/day** using `output/<client>-<location>-DD-MM-YYYY/`.
- **Progress indicators/spinners** for long-running scan stages.
- **Speedtest timeout protection** (fails gracefully if it takes too long).
- **JSON output for every scan** for automation and post-processing.
- **Per-run `manifest.json`** summarizing run metadata and all generated artifacts.
- **Raw evidence capture** under `raw/` for scan source output such as `nmap`, `speedtest-cli`, DHCP discovery, and stress-test ping stages.
- **Hostname enrichment** for custom target scans when reverse DNS is available.
- **Append-style custom target results** so repeated runs of `10`, `11`, and `13` on the same day become `device-1`, `device-2`, and so on instead of overwriting previous results.
- **DNS behavior assessment** for custom DNS targets, including UDP/TCP query checks, recursion visibility, reverse lookup checks, and `version.bind` probing when supported.
- **DHCP evidence capture** with unique responders, raw offer counts, and optional relay/proxy source visibility when `tcpdump` is available.
- **Per-run debug log** captured as `debug.txt` in the run folder for troubleshooting.
- **Optional `--debug` mode** that disables spinner redraws and keeps the session log much easier to troubleshoot.
- **Automatic report build on exit** into the same run folder as the JSON results.
- **Previous-run report rebuild** that can export a fresh TXT report to Desktop or another chosen directory without creating a new scan run.
- **Installed-mode update check** that compares the current version against the latest GitHub tag, creates a backup zip first, and then replaces app files while preserving data.
- **Install/update audit logging** in `install-audit.log` under the installed data root.
## Supported platforms

- macOS
- Linux

## Installation details

Run from the extracted or cloned project folder:

```bash
sudo ./install.sh
```

`install.sh` will:

- Detect OS (macOS/Linux)
- Require `sudo` / root
- Check whether the downloaded copy matches the latest published GitHub tag before changing the machine, and offer to download and relaunch the latest installer automatically if the bundle is outdated
- Install required dependencies
  - macOS: `nmap`, `jq`, `speedtest-cli`, `tcpdump`
  - Linux: `nmap`, `jq`, `iproute2`, `iputils-ping`, `tcpdump`, `net-tools`, `speedtest-cli`, `zip`, `unzip`
  - macOS system tools expected to already exist: `ipconfig`, `ifconfig`, `route`, `networksetup`, `ping`, `zip`
- On macOS, if Homebrew is missing, run the installer from your normal admin user with `sudo`; Homebrew may ask for your normal macOS admin password during first-time setup
- Deploy the application command to `/usr/local/bin/lss-network-tools`
- Deploy application files to:
  - macOS: `/usr/local/share/lss-network-tools`
  - Linux: `/usr/local/lib/lss-network-tools`
- Create runtime data directories:
  - macOS: `/usr/local/share/lss-network-tools/output`
  - Linux: `/var/lib/lss-network-tools/output`
  - Linux temp/data helpers: `/var/lib/lss-network-tools/raw` and `/var/lib/lss-network-tools/tmp`
- Overwrite the existing `lss-network-tools` command wrapper on reinstall
- Preserve existing scan data on reinstall
- On Linux, if the command does not autocomplete immediately after install, open a new shell or run `hash -r`

## Running

```bash
sudo lss-network-tools
```

For cleaner troubleshooting output without spinner redraws:

```bash
sudo lss-network-tools --debug
```

To print the installed version without launching the app:

```bash
lss-network-tools --version
```

If command completion does not work immediately after install or update, open a new shell.
For `zsh`, you can also run:

```bash
rehash
autoload -Uz compinit && compinit
```

To check for updates after install:

- Open `lss-network-tools`
- Choose `4) Check For Updates`
- Choose whether to create a backup first
- If you choose backup, enter a backup destination directory
- Confirm the update
- Relaunch the command after the updater exits

To remove the installed application later:

```bash
sudo lss-network-tools --uninstall
```

> The installed command is intended to be run with `sudo`.
> If `tcpdump` is installed and the tool is running as root, DHCP scan output will also record relay or proxy packet sources to help explain duplicate offers.
> If `curl` is available, Function `13` can also use an online MAC vendor lookup fallback when local vendor detection is incomplete.
> Stress tests are intentionally high-impact. If the target is a client gateway or firewall, consider disconnecting it from internet or running it after-hours if disruption would be unacceptable.

## macOS app

A native SwiftUI app (macOS 14+) lives in [`macos/`](macos/README.md). It drives this script
in non-interactive mode — New Run sheet with per-task inputs, explicit confirmation before stress
tests, live per-task progress with the terminal as the log — and browses the run directories the
script writes (findings by severity, typed views and charts per task, the PDF report, Continue
Run, Rebuild Report, Delete Run via `--delete-run`). The script remains the only engine; the app never writes task results
itself. Install it on your own Mac with `cd macos && make install` (Xcode 26+ with the Metal
toolchain component; builds the release app, copies it to `/Applications`, re-registers the
privileged helper and opens the Setup & Permissions window — run as your user, never with
`sudo`; `make build` alone for a development build). The app is ad-hoc signed for personal use;
no Developer ID or notarisation is involved. From the CLI, startup-menu option
`6) Launch Graphical Interface` (macOS only, v1.2.250) opens the installed app as the user who
ran `sudo`. See `macos/README.md` for the install steps, the Setup window and troubleshooting.

## Non-interactive mode (for the macOS app and scripting)

`--run-task` runs one task, a list of tasks or the full audit without any menus or prompts, writes the same JSON/TXT/PDF files as an interactive run, and reports progress as machine-readable lines. `--build-report` rebuilds the TXT/PDF report of an existing run directory. `--delete-run` removes a run directory (the "Delete This Run" menu action without its prompt). Nothing changes for interactive use: without these flags the script behaves exactly as before.

```bash
# Full audit (tasks 1–12) into a new run directory; --yes accepts the stress-test warning
sudo lss-network-tools --run-task 000 --interface en0 --client Acme --location HQ --yes

# One task into a new run, with a note and the report cover name
sudo lss-network-tools --run-task 1 --interface en0 --client Acme --location HQ --note "VLAN 10" --prepared-by "J. Smith"

# A selection (lists and ranges), no PDF
sudo lss-network-tools --run-task 1,3,6-9 --interface en0 --client Acme --location HQ --no-pdf

# Continue an existing run: one survey room per invocation, appended to wireless-survey.json
sudo lss-network-tools --run-task 17 --run-dir /usr/local/share/lss-network-tools/output/acme-hq-03-10-2026 \
  --building HQ --floor 1 --room "Lobby" --ap-present y --ap-label AP-101

# Custom target tasks (13–16) and Find Device by MAC (20)
sudo lss-network-tools --run-task 13 --interface en0 --client Acme --location HQ --target 192.168.1.10
sudo lss-network-tools --run-task 20 --interface en0 --client Acme --location HQ --mac 74:ac:b9:12:34:56

# UniFi adoption (19): the SSH password travels in the environment, never in argv — anything on the
# command line is visible to every user in `ps` and lands in the shell history (works in bash and zsh)
printf 'SSH password: '; read -r -s LSS_SSH_PASSWORD; echo; export LSS_SSH_PASSWORD
sudo --preserve-env=LSS_SSH_PASSWORD lss-network-tools --run-task 19 \
  --run-dir /usr/local/share/lss-network-tools/output/acme-hq-03-10-2026 --ssh-user ubnt --controller unifi.example.com
unset LSS_SSH_PASSWORD

# Rebuild the report (TXT + PDF) of a previous run
sudo lss-network-tools --build-report /usr/local/share/lss-network-tools/output/acme-hq-03-10-2026 --prepared-by "J. Smith"

# Delete a previous run (its task results, reports and debug log) — no confirmation prompt
sudo lss-network-tools --delete-run /usr/local/share/lss-network-tools/output/acme-hq-03-10-2026

# List the tasks as JSON (no root needed)
lss-network-tools --run-task list
```

### Flags

| Flag | Value | Applies to | Notes |
|---|---|---|---|
| `--run-task` | `<id>` · `1,3,5-7` · `000` · `list` | all | Ids separated by commas only (no spaces); `000` = the core audit (1–12); `list` prints `{"version":…,"tasks":[{id,title,file,multi,group}]}` on stdout and exits 0 without root, and must be the only option |
| `--build-report` | `<run-dir>` | report | Rebuilds the TXT report, rewrites `manifest.json`, generates the PDF; exits 0/1 |
| `--delete-run` | `<run-dir>` | delete | Removes the run directory with `rm -rf` after validation (exit 2 otherwise): an absolute path with no `.`/`..` components, directly inside the output directory, not the output directory itself, not a symbolic link, and it must look like a run (`manifest.json`, a task JSON file or a `lss-network-tools-report-*.txt`). Accepts only `--debug` besides; any other flag or mode is a usage error. Exits 0 when the directory is gone, 1 when `rm -rf` failed |
| `--interface` | interface name | all | Required for a new run; for `--run-dir` it defaults to the run's recorded interface. Must exist (`ifconfig -l` / `ip link`); a missing IPv4 address is a warning, not an error |
| `--client`, `--location`, `--note` | text | new run | Client and location are required and must not be blank (surrounding whitespace is trimmed); the note is optional |
| `--run-dir` | absolute path directly inside the output directory | continue run | Mutually exclusive with `--client/--location/--note`; the directory must exist |
| `--yes` | — | 10, 14, 000 | Required whenever the selection contains a stress test (exit 4 otherwise) |
| `--target` | IPv4 | 13–16 | Required |
| `--mac` | MAC in any format | 20 | Required; normalised to `aa:bb:cc:dd:ee:ff` |
| `--building`, `--floor`, `--room` | text | 17 | Required; one room per invocation (re-run with `--run-dir` for the next room — the entry is appended and `rooms_scanned` incremented) |
| `--ap-present` | `y` \| `n` | 17 | Default `n` |
| `--ap-label` | text | 17 | Optional, used when `--ap-present y` |
| `--wifi-interface` | interface | 17 | Default: the selected interface if it is wireless, else the first wireless interface |
| `--wifi-scan-json` | file | 17 | Use this file instead of scanning: a regular, readable file containing a JSON array of networks. On macOS it is required outside a `sudo` session (no `SUDO_USER`, e.g. under the app's privileged helper), because the Wi-Fi scan helper needs a logged-in user context |
| `--controller`, `--controller-port`, `--https y\|n`, `--ssh-user` | | 19 | Controller/port/HTTPS default to Program Defaults as in interactive mode; the port must be a decimal number 1–65535 (no leading zeros); `--ssh-user` is required and must be a plain account name (letters, digits, `.`, `_`, `-`; no leading `-`) |
| `LSS_SSH_PASSWORD` (environment variable) | | 19 | Required for task 19. The password is **never** accepted as an argument (arguments are visible in `ps` and in the shell history); with `sudo` use `--preserve-env=LSS_SSH_PASSWORD`. The script copies it and removes it from the environment so child processes do not inherit it |
| `--prepared-by` | text | all | Name printed on the report cover |
| `--output` | directory | `--build-report` | Save the rebuilt report there instead of inside the run directory; a usage error together with `--run-task` |
| `--no-pdf` | — | all | Skip PDF generation |
| `--debug` | — | all | Unchanged; non-interactive mode already prints spinner labels as plain lines |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every task finished with status `success`, `completed_with_warnings` or `skipped` |
| `1` | At least one task `failed`, wrote no JSON or has no `status`; the run directory could not be created; `--build-report` could not build the report or create the `--output` directory; or `--delete-run` could not remove the directory |
| `2` | Usage or validation error: unknown task or whitespace in the selection, `--run-task list` with other options, more than one mode at once, `--delete-run` with any flag other than `--debug` or with a directory that is missing, a symlink, the output directory itself or not a run, missing/invalid interface, target, MAC or run directory, blank `--client`/`--location`, `--run-dir` with `--client/--location/--note`, `--output` with `--run-task`, missing `--building/--floor/--room`, a `--wifi-scan-json` that is not a regular file holding a JSON array, Task 17 without `--wifi-scan-json` outside a `sudo` session on macOS, missing `--ssh-user` or `LSS_SSH_PASSWORD`, an invalid `--ssh-user`, `--controller`, `--controller-port`, `--https` or `--ap-present` |
| `3` | A required dependency is missing (the usual dependency checklist is printed; `install.sh` is never run automatically) |
| `4` | The selection includes a stress test (10, 14 or 000) and `--yes` was not given |
| `5` | Not running as root |
| `130` | Interrupted (Ctrl-C / SIGTERM) |

### Progress protocol

Progress is written to **stderr**, one line per event, as `@@LSS ` followed by a compact JSON object that always carries `"v":1`, `"ts"` (ISO-8601 UTC) and `"event"`. Everything the tasks print (the same human-readable output as the interactive mode, minus menus, screen clears and spinner redraws) goes to stdout, so `2>progress.log` yields a clean event stream (with stderr closed the events are simply dropped and the run proceeds). Events in order: `hello` (resolved task ids), `error`/`bye` on a validation failure, otherwise (after the dependency checklist on stdout) `run_dir`, then per task `task_start` → `task_stage`… → `task_done`, then `report_built`, `pdf_built` or `pdf_failed`, and finally `bye` (always the last line, with the exit code). When no task in the run — earlier invocations of a continued run included — has written any JSON, a `warning` with code `no_report` replaces the report events and a run directory created by this invocation is removed again; `report_failed` is the warning when task output exists but the report could not be written. Other `warning` lines may appear anywhere (e.g. `interface_no_ip`, `task_17_helper_fallback`). `--build-report` emits `hello`, `run_dir`, `report_built`, `pdf_built`/`pdf_failed`, `bye`; `--delete-run` emits `hello` (with `"tasks":[]`), then `run_deleted` with the removed `"path"` and `bye` with exit code 0, or an `error` with code `delete_failed` and `bye` with exit code 1.

```text
@@LSS {"v":1,"ts":"2026-10-03T14:05:01Z","event":"task_start","task":4,"title":"DHCP Network Scan","index":4,"total":12}
@@LSS {"v":1,"ts":"2026-10-03T14:05:48Z","event":"task_done","task":4,"status":"success","rc":0,"json_files":["dhcp-scan.json"]}
```

`task_done.status` is read from the task's JSON (`success`, `completed_with_warnings`, `failed`, `skipped`; `unknown` when the file has no `status`) or is `no_output` when the task wrote nothing; `json_files` lists only the files this invocation created or rewrote. `task_stage` is emitted for the stress-test stages (tasks 10 and 14), the two Task 11 captures and the Task 18 steps.

**Authenticated events.** A consumer that reads the events in-band from a pty (the macOS app) can set `LSS_PROGRESS_TOKEN` to a per-run secret matching `^[A-Za-z0-9_-]{8,64}$`; every line is then written as `@@LSS <token> {json}`, so device-supplied text echoed on stdout (an SSID or hostname containing `@@LSS {…}`) cannot forge an event. The script copies the token at start-up and removes it from the environment, so nmap, python or tcpdump never see it; with `sudo` pass it with `--preserve-env=LSS_PROGRESS_TOKEN`. Without the variable (or with a value that does not match the grammar) the format is unchanged. Consumers of `2>progress.log` can strip the token with `sed 's/^@@LSS [A-Za-z0-9_-]* /@@LSS /'`.

## Output

### JSON scan output

Each run creates a folder inside the installed output location:

```text
macOS: /usr/local/share/lss-network-tools/output/
Linux: /var/lib/lss-network-tools/output/
```

Run folder format:

- `output/<client>-<location>-DD-MM-YYYY/`

Possible files inside a run folder:

- `interface-network-info.json`
- `internet-speed-test.json`
- `gateway-scan.json`
- `dhcp-scan.json`
- `dns-scan.json`
- `ldap-ad-scan.json`
- `smb-nfs-scan.json`
- `print-server-scan.json`
- `gateway-stress-test.json`
- `custom-target-port-scan-device-<n>.json`
- `custom-target-stress-test-device-<n>.json`
- `custom-target-identity-scan-device-<n>.json`
- `custom-target-dns-assessment-device-<n>.json`
- `manifest.json`
- `debug.txt`
- `lss-network-tools-report-<client>-<location>-DD-MM-YYYY-HH-MM.txt`
- `raw/`

The report includes:

- Header metadata (location, client, timestamp, selected interface)
- Executed vs not-executed function summary
- Per-function sections generated from available JSON scan files
- Per-device sections for repeated custom target scans
- Key Findings
- Remediation Hints

The manifest includes:

- Run metadata (client, location, selected interface, generated time)
- Task list with expected JSON outputs
- Artifact inventory for JSON, report, debug, and raw evidence files

The install audit log includes:

- install events
- update events
- uninstall events
- update verification failures when relevant

The custom identity scan includes:

- Target IP and hostname
- MAC address and vendor
- Vendor source and lookup method
- Host state
- Device type hint
- Confidence level
- Human-readable identity summary
- Discovered services and version banners

The custom DNS assessment includes:

- Whether the DNS service actually answers queries
- Whether recursion appears to be available
- UDP and TCP DNS query status
- Reverse PTR lookup behavior
- `version.bind` software hints when exposed
- An explicit note that upstream forwarding destinations cannot be reliably inferred from client-side answers alone

## Notes

- Scans use `nmap`; runtime depends on network size and host responsiveness.
- `000)` can take a long time in larger networks.
- If `speedtest-cli` is unavailable or fails, other scan functions still work independently.
- Custom target functions `10`, `11`, `13`, and `14` are manual-only and are not included in `000)`.
- `Build LSS Network Tools Report From Previous Run` uses saved JSON data from an existing run folder and does not create a new scan run.

## Maintainer release checklist

Before publishing a new release:

1. Update `APP_VERSION` in `lss-network-tools.sh`
2. Commit the version bump
3. Push the commit to GitHub
4. Create and publish the matching tag/release
5. Sanity-check the published source by confirming the tag contains the expected `APP_VERSION`
