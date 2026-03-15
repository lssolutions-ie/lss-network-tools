#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS=""

print_install_hint() {
  local tool="$1"
  if [[ "$OS" == "macos" ]]; then
    echo "Missing required tool: $tool"
    echo "Install with: brew install $tool"
  else
    echo "Missing required tool: $tool"
    echo "Install with: apt install $tool"
  fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux) OS="linux" ;;
    *)
      echo "Unsupported platform: $(uname -s)"
      exit 1
      ;;
  esac
}

check_tools() {
  local missing=0
  local base_tools=(nmap arp route awk sed grep)

  for tool in "${base_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      print_install_hint "$tool"
      missing=1
    fi
  done

  if [[ "$OS" == "macos" ]]; then
    for tool in ipconfig ifconfig; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        print_install_hint "$tool"
        missing=1
      fi
    done
  else
    if ! command -v ip >/dev/null 2>&1; then
      print_install_hint "iproute2"
      missing=1
    fi
    if ! command -v ifconfig >/dev/null 2>&1; then
      echo "Optional fallback missing: ifconfig"
      echo "Install with: apt install net-tools"
    fi
  fi

  if [[ "$missing" -eq 1 ]]; then
    echo "Please install missing required tools and rerun install.sh."
    exit 1
  fi
}

detect_os
check_tools
mkdir -p "$SCRIPT_DIR/output"
chmod +x "$SCRIPT_DIR/lss-network-tools.sh"

echo "Installation complete."
echo "Run: ./lss-network-tools.sh"
