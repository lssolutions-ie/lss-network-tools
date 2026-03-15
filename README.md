# lss-network-tools

Interactive network diagnostics for **macOS** and **Linux**, with JSON exports per scan and a consolidated human-readable report.

## Quick start

```bash
git clone https://github.com/korshakov/lss-network-tools.git
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
   Discovers DHCP server(s) and scans open ports on each discovered server.
5. **DNS Network Scan**  
   Scans the local network for hosts with DNS ports open.
6. **LDAP/AD Network Scan**  
   Scans for common Active Directory / LDAP service ports.
7. **SMB/NFS Network Scan**  
   Scans for file-sharing services (SMB/NFS/rpcbind/netbios).
8. **Printer/Print Server Network Scan**  
   Scans for common print service ports (LPD, IPP, JetDirect).

Additional menu options:

- `000)` **Complete Network Audit** (runs functions 1–8 sequentially)
- `00)` **Build Report** (creates a readable TXT report from existing JSON results)
- `0)` Exit

## Key workflow features

- **Dependency checklist at startup** with optional auto-install via `install.sh` when required tools are missing.
- **Interactive interface selector** (on macOS, includes hardware port descriptions when available).
- **Existing output protection** prompt: continue and clear prior data, or exit to back it up.
- **Progress indicators/spinners** for long-running scan stages.
- **Speedtest timeout protection** (fails gracefully if it takes too long).
- **JSON output for every scan** for automation and post-processing.
- **Client/location-aware report filenames** for easier organization.

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
- Install Homebrew if missing
- Install required dependencies (for example: `nmap`, `jq`, `speedtest-cli`, and platform-specific networking tools)
- Create `output/` if needed
- Ensure `lss-network-tools.sh` is executable

## Running

```bash
./lss-network-tools.sh
```

> Some scans (notably DHCP discovery) may require root privileges for best results.

## Output

### JSON scan output

All scan JSON files are written to:

```text
output/
```

Possible files:

- `output/interface-info.json`
- `output/internet-speed-test.json`
- `output/gateway-scan.json`
- `output/dhcp-scan.json`
- `output/dns-scan.json`
- `output/ldap-ad-scan.json`
- `output/smb-nfs-scan.json`
- `output/print-server-scan.json`

### Human-readable report output

Built reports are written to:

```text
reports/
```

Report filename format:

- `reports/lss-network-tools-report-<client>-<location>-YYYYMMDD-HHMMSS.txt`

The report includes:

- Header metadata (location, client, timestamp, selected interface)
- Executed vs not-executed function summary
- Per-function sections generated from available JSON scan files

## Notes

- Scans use `nmap`; runtime depends on network size and host responsiveness.
- `000)` can take a long time in larger networks.
- If `speedtest-cli` is unavailable or fails, other scan functions still work independently.
