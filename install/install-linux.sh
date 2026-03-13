#!/usr/bin/env bash
set -e
set -o pipefail

if [[ "$(uname)" != "Linux" ]]; then
  echo "This installer is intended for Linux."
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y nmap speedtest-cli arp-scan
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y nmap speedtest-cli arp-scan
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y nmap speedtest-cli arp-scan
else
  echo "No supported package manager found. Install nmap, speedtest-cli, and arp-scan manually."
  exit 1
fi

sudo cp lss-linux-network-tools /usr/local/bin/lss
sudo chmod +x /usr/local/bin/lss

echo "Installation complete."
echo "Run the tool with:"
echo
echo "lss"
