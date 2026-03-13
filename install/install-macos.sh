#!/usr/bin/env bash
set -e
set -o pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is not installed."
  echo "Install Homebrew from https://brew.sh/ and rerun this script."
  exit 1
fi

brew install nmap speedtest-cli arp-scan python

sudo cp lss-network-tools-macos.sh /usr/local/bin/lss-network-tools
sudo chmod +x /usr/local/bin/lss-network-tools

echo "Installation complete."
echo "Run the tool with:"
echo
echo "lss-network-tools"
