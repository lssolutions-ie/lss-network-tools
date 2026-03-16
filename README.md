# lss-network-tools

Interactive network diagnostics for **macOS** and **Linux**, with per-run JSON exports and a consolidated human-readable report stored in the same run folder.

## Quick start

```bash
git clone https://github.com/lssolutions-ie/lss-network-tools.git
cd lss-network-tools
chmod +x *.sh
./install.sh
./lss-network-tools.sh
```

## What it does

After selecting a network interface, the tool provides these scan functions:

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

Additional menu options:

- `000)` **Complete Network Audit** (runs functions 1–9 sequentially)
- `0)` Exit

High-impact warning:
- `9)`, `11)`, and `000)` require explicit confirmation before a stress test runs.
- Stress tests send high-rate ICMP only to the chosen target and do not perform exploits or service attacks.
- If the target is a gateway or firewall, the test can still disrupt client connectivity. Run it only when service impact is acceptable.

## Key workflow features

- **Dependency checklist at startup** with optional auto-install via `install.sh` when required tools are missing.
- **Interactive interface selector** (on macOS, includes hardware port descriptions when available).
- **Run context prompt** for location and client name after interface selection.
- **Timestamped run folder per session** under `output/`, so prior runs stay intact.
- **Progress indicators/spinners** for long-running scan stages.
- **Speedtest timeout protection** (fails gracefully if it takes too long).
- **JSON output for every scan** for automation and post-processing.
- **DHCP evidence capture** with unique responders, raw offer counts, and optional relay/proxy source visibility when `tcpdump` is available.
- **Per-run debug log** captured as `debug.txt` in the run folder for troubleshooting.
- **Optional `--debug` mode** that disables spinner redraws and keeps debug output easier to read.
- **Automatic report build on exit** into the same run folder as the JSON results.

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
- Install Homebrew if missing on supported non-root setups
- Install required dependencies (for example: `nmap`, `jq`, `speedtest-cli`, `ping`, `tcpdump`, and platform-specific networking tools)
- Create `output/` if needed
- Ensure `lss-network-tools.sh` is executable

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
> Stress tests are intentionally high-impact. If the target is a client gateway or firewall, consider disconnecting it from internet or running it after-hours if disruption would be unacceptable.

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
- `custom-target-port-scan.json`
- `custom-target-stress-test.json`
- `debug.txt`
- `lss-network-tools-report-<client>-<location>-DD-MM-YYYY-HH-MM.txt`

The report includes:

- Header metadata (location, client, timestamp, selected interface)
- Executed vs not-executed function summary
- Per-function sections generated from available JSON scan files

## Notes

- Scans use `nmap`; runtime depends on network size and host responsiveness.
- `000)` can take a long time in larger networks.
- If `speedtest-cli` is unavailable or fails, other scan functions still work independently.
