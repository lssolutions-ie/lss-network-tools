# Installation

## 🚀 Quick Start (Recommended)

Clone the repository and run the installer:

```bash
git clone https://github.com/korshakov/lss-network-tools.git
cd lss-network-tools
chmod +x install.sh
./install.sh
```

On first launch the tool will automatically:

- ✔ Check required dependencies  
- ✔ Offer to install missing tools using **Homebrew**  
- ✔ Check for updates  
- ✔ Start the **interactive network audit menu**

> No global installation is required when running the tool this way.

---

## 🌍 Install as a Global Command

If you want to run the tool from anywhere on your system:

```bash
sudo ./install.sh
```

This installs the command:

```bash
lss
```

You can then start the tool from any directory:

```bash
lss
```

---

## 🍺 Homebrew Installation

You can also install the tool using the included Homebrew formula:

```bash
brew install ./homebrew-tools/Formula/lss-network-tools.rb
```

After installation run:

```bash
lss
```

---

# ✨ New Features

## Network Health Summary

Menu option **11**

Runs a quick multi-check network audit:

- Gateway reachability
- Internet reachability
- Device discovery count
- DHCP server detection
- Exposed management interfaces
- Remote access services detection

---

## Live Scan Spinner

Scans now display a **live spinner animation** while commands execute.

Example:

```
Running network discovery... [|]
Running network discovery... [/]
Running network discovery... [-]
Running network discovery... [\]
```

Followed by a completion banner:

```
----------------------------------------
Scan complete
----------------------------------------
```

---

## Discovery Behavior

Discovery-based features always run a **fresh live scan** each time you select them.

This applies to:

- Discover Devices
- Network Map
- Network Topology Summary
- Network Health Summary

---

# 🎯 Project Goals

`lss-network-tools` is designed as a **portable network audit toolkit for macOS**.

It provides:

- Fast network discovery
- DHCP misconfiguration detection
- Gateway fingerprinting
- Remote access exposure detection
- Network topology summaries

All from a **single interactive CLI interface**.

---

# 📦 Requirements

The tool automatically installs missing dependencies using **Homebrew**.

Required tools include:

- `nmap`
- `arp-scan`
- `speedtest-cli`
- `Homebrew`
