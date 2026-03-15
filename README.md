# lss-network-tools

A small network diagnostic script for macOS and Linux.

It provides three functions for a selected network interface:

1. Interface network information (IP, subnet, network range, MAC)
2. Default gateway details and full open-port scan
3. DHCP server discovery and full open-port scans for discovered servers

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
