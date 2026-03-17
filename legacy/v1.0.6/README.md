# lss-network-tools

Interactive network diagnostics for **macOS** and **Linux**, with per-run JSON exports, a consolidated human-readable report, and utilities for rebuilding reports from previous runs.

The tool is designed for interactive onsite diagnostics: run a daily audit for the local network, then optionally add one-off custom target scans into the same day folder without overwriting earlier results.

## Quick start

Preferred install method:

```bash
git clone https://github.com/lssolutions-ie/lss-network-tools.git
cd lss-network-tools
chmod +x *.sh
./install.sh
./lss-network-tools.sh
```

Alternative install method:

1. Download the latest release ZIP from GitHub.
2. Extract it.
3. Open Terminal in the extracted `lss-network-tools` folder.
4. Run:

```bash
chmod +x *.sh
./install.sh
./lss-network-tools.sh
```

## What it does

After choosing `Run LSS Network Tools` from the startup menu and selecting a network interface, the tool provides these scan functions:

1. **Interface Network Info**  
   Captures IP address, subnet mask, network range (CIDR), and MAC address.
2. **Internet Speed Test**  
   Runs `speedtest-cli` and captures public IP, test server, ping, download, and upload.
3. **Gateway Details**  
   Detects default gateway and performs full open-port scan.
4. **DHCP Network Scan**  
   Runs repeated DHCP discovery attempts, deduplicates noisy offers, scans open ports on each observed responder, and flags unusual responders as possible rogue DHCP for manual review.
5. **DNS Network Scan**  
   Scans the local network for hosts with DNS ports open.
6. **LDAP/AD Network Scan**  
   Scans for common Active Directory / LDAP service ports.
7. **SMB/NFS Network Scan**  
   Scans for file-sharing services (SMB/NFS/rpcbind/netbios).
8. **Printer/Print Server Network Scan**  
   Scans for common print service ports (LPD, IPP, JetDirect).
9. **Gateway Stress Test**  
   Runs repeated gateway latency and packet-loss checks to spot jitter and recovery issues under load. This is a high-impact test that targets only the detected local gateway/firewall and may disrupt routing, VPNs, or internet access on weak edge devices.
10. **Custom Target Port Scan**  
   Prompts for an IP address and runs a full open-port scan against that target.
11. **Custom Target Stress Test**  
   Prompts for an IP address and runs the same high-impact ICMP stress workflow against that specific target.
13. **Custom Target Identity Scan**  
   Prompts for an IP address and combines MAC/vendor discovery, optional online vendor enrichment, hostname lookup, and conservative service fingerprinting into a single device identity profile with `device_type_hint`, `confidence`, and `identity_summary`.
14. **Custom Target DNS Assessment**  
   Prompts for an IP address and tests whether the target is a working DNS resolver over UDP and TCP, whether recursion is available, whether reverse lookups work, and whether the service exposes a software hint such as `dnsmasq`.

Additional menu options:

- `000)` **Complete Network Audit** (runs functions 1–9 sequentially)
- `0)` Exit

Startup menu utilities:

- `1)` **Run LSS Network Tools**
- `2)` **Build LSS Network Tools Report From Previous Run**
- `3)` **Delete All Previous Runs**
- `4)` **Check For Updates**
- `5)` Exit

High-impact warning:
- `9)`, `11)`, and `000)` require typing `PROCEED` before a stress test runs.
- Stress tests send high-rate ICMP only to the chosen target and do not perform exploits or service attacks.
- If the target is a gateway or firewall, the test can still disrupt client connectivity. Run it only when service impact is acceptable.

## Key workflow features

- **Dependency checklist at startup** with optional auto-install via `install.sh` when required tools are missing.
- **Startup utility menu** for running scans, rebuilding reports from previous runs, deleting stored runs, and checking for updates.
- **Interactive interface selector** (on macOS, includes hardware port descriptions when available).
- **Run context prompt** for location and client name after interface selection.
- **Timestamped run folder per session** under `output/`, so prior runs stay intact.
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
- **Tag-based update check** that supports both Git clones and ZIP/manual installs.

## Supported platforms

- macOS
- Linux

## Installation details

Run from repo root:

```bash
./install.sh
```

`install.sh` will:

- Detect OS (macOS/Linux)
- On macOS, expect to run `install.sh` as your normal user. Homebrew may ask for your password during installation, but you should not run the whole installer with `sudo` just for that.
- Install Homebrew if missing on supported non-root setups
- Install required dependencies (for example: `nmap`, `jq`, `speedtest-cli`, `ping`, `tcpdump`, and platform-specific networking tools)
- Create `output/` if needed
- Ensure `lss-network-tools.sh` is executable
- If the extracted ZIP folder name looks like `lss-network-tools-<version>`, it will try to normalize it back to `lss-network-tools` when safe to do so

## Running

```bash
./lss-network-tools.sh
```

For cleaner troubleshooting output without spinner redraws:

```bash
./lss-network-tools.sh --debug
```

> Some scans (notably DHCP discovery) may require root privileges. On Linux root servers, the installer prefers native packages and does not require `sudo`.
> If `tcpdump` is installed and the tool is running as root, DHCP scan output will also record relay or proxy packet sources to help explain duplicate offers.
> If `curl` is available, Function `13` can also use an online MAC vendor lookup fallback when local vendor detection is incomplete.
> Stress tests are intentionally high-impact. If the target is a client gateway or firewall, consider disconnecting it from internet or running it after-hours if disruption would be unacceptable.
> `Check For Updates` supports both normal Git clones and ZIP/manual installs.
> For Git clones, it compares the local repository tag with the latest remote tag and can update with `git fetch` and `git pull`.
> For ZIP/manual installs, it compares the built-in app version with the latest remote tag and can download and replace the installation in place while preserving `output/`.
> For private repositories, Git or GitHub authentication may be required.
> On macOS, `install.sh` should normally be run as your regular user, while `lss-network-tools.sh` may still be run with elevated privileges when needed for certain scans.

## Output

### JSON scan output

Each run creates a folder inside:

```text
output/
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
- `Check For Updates` uses tags as the source of truth for published versions.
- For ZIP/manual installs, keep the `APP_VERSION` value in the script aligned with the tag you publish.
