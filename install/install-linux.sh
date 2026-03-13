#!/usr/bin/env bash
set -e
set -o pipefail

if [[ "$(uname)" != "Linux" ]]; then
  echo "This installer is intended for Linux."
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y nmap dnsutils speedtest-cli arp-scan curl python3 python3-pip
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y nmap bind-utils speedtest-cli arp-scan curl python3
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y nmap bind-utils speedtest-cli arp-scan curl python3
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -Sy --noconfirm nmap bind speedtest-cli arp-scan curl python
elif command -v apk >/dev/null 2>&1; then
  sudo apk add nmap bind-tools speedtest-cli arp-scan curl python3
else
  echo "No supported package manager found. Install nmap, dig, speedtest-cli, arp-scan, and curl manually."
  exit 1
fi

sudo cp lss-network-tools-linux.sh /usr/local/bin/lss-network-tools
sudo chmod +x /usr/local/bin/lss-network-tools

echo "Installation complete."
echo "Run the tool with:"
echo
echo "lss-network-tools"
