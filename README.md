## Installation

### Quick Start (Recommended)

Clone the repository and run the tool directly:

git clone https://github.com/korshakov/lss-macos-network-tools.git

cd lss-macos-network-tools

chmod +x install.sh

./install.sh

On first launch the tool will:

• Check required dependencies  
• Offer to install missing tools using Homebrew  
• Check for updates  
• Start the interactive network audit menu

No installation is required to run the tool this way.

---

### Install as a Global Command

If you want to run the tool from anywhere on your system:

sudo ./install.sh

This installs the command:

lss

You can then start the tool by running:

lss

---

### Homebrew Installation

You can also install the tool using the included Homebrew formula:

brew install ./homebrew-tools/Formula/lss-macos-network-tools.rb

After installation run:

lss
---

## New Features

- **Network Health Summary** (menu option 11): Runs a quick multi-check audit for gateway reachability, internet reachability, discovered device count, DHCP detection, exposed management interfaces, and remote access services.
- **Live scan progress indicators**: All major nmap-based scans now show friendly start messages, progress updates every 5 seconds, and a completion banner.
