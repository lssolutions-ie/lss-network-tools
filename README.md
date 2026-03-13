# LSS macOS Network Tools

![Platform](https://img.shields.io/badge/platform-macOS-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Version](https://img.shields.io/badge/version-1.0.0-orange)

## Project description
LSS macOS Network Tools is a Bash-based CLI utility for professional network diagnostics and audit workflows on macOS. It helps engineers quickly inspect interface configuration, discover devices, run gateway and LAN scans, validate DHCP behavior, and export session reports for documentation.

## Features
- Dependency checks for `brew`, `nmap`, `arp-scan`, and `speedtest-cli`
- One-time `sudo` credential validation for smoother scan workflows
- Filtered interface detection to focus on real network adapters
- Device discovery with `arp-scan`
- Gateway reconnaissance and fingerprinting with `nmap`
- Rogue DHCP discovery script checks
- Local network mapping and service checks
- Internet speed testing with `speedtest-cli`
- Exportable session report with metadata header
- Built-in version flag: `--version`

## Requirements
- macOS Ventura, Sonoma, or Sequoia
- Homebrew
- nmap
- arp-scan
- speedtest-cli

## Installation
### Run from repository
```bash
git clone https://github.com/korshakov/lss-macos-network-tools.git
cd lss-macos-network-tools
chmod +x lss-macos-network-tools
./lss-macos-network-tools
```

### System installation
```bash
sudo ./install.sh
```

After installation, run:
```bash
lss
```

## Usage
```bash
./lss-macos-network-tools
```

Show version:
```bash
./lss-macos-network-tools --version
```

Installed command:
```bash
lss
```

## Export reports
When exiting the tool, choose report export to save a timestamped report on the Desktop using this naming format:

`LSS-NetInfo-Export-YYYY-MM-DD_HH-MM-SS.txt`

Each report includes metadata at the top:
- Generated timestamp
- Selected interface
- Detected gateway

## License
This project is licensed under the MIT License. See [LICENSE](LICENSE).
