# lss-network-tools

```bash
git clone https://github.com/korshakov/lss-network-tools.git
cd lss-network-tools
chmod +x *.sh
```

A small network diagnostic script for macOS and Linux.

It provides seven scan functions for a selected network interface:

1. Interface network information (IP, subnet, network range, MAC)
2. Default gateway details and full open-port scan
3. DHCP server discovery and full open-port scans for discovered servers
4. DNS network scan
5. LDAP/AD network scan
6. SMB/NFS network scan
7. Printer/Print Server network scan

Additional menu options:
- `000)` Run all tasks (runs functions 1-7 sequentially)
- `00)` Build Report (creates an ASCII human-readable `.txt` report from available JSON output files, in function order)
- `0)` Exit

Menu layout now includes visual separators:
- A major line separator between `Selected Interface` and the function list
- A major line separator between function `7)` and option `000)`
- A minor line separator between option `0)` and the `Enter selection` prompt

All results are printed to the terminal and exported as JSON files.

## Supported platforms

- macOS
- Linux

## Install

From the repository root:

```bash
./install.sh
```

The install script will:

- Check required tools
- Print installation instructions for missing tools
- Create the `output/` directory if needed
- Make `lss-network-tools.sh` executable

## Run

From the repository root:

```bash
./lss-network-tools.sh
```

## JSON output files

JSON files are stored in:

```text
output/
```

Files created by menu actions:

- `output/interface-info.json`
- `output/gateway-scan.json`
- `output/dhcp-scan.json`
- `output/dns-scan.json`
- `output/ldap-ad-scan.json`
- `output/smb-nfs-scan.json`
- `output/print-server-scan.json`
- `output/network-report-YYYYMMDD-HHMMSS.txt` (generated via option `00`)
