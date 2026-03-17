#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS=""
PKG_PREFIX=()
ALLOW_BREW=1

log() {
  echo "[install] $*"
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

warn_about_root_usage() {
  if [[ "$OS" == "macos" && "$EUID" -eq 0 ]]; then
    log "Running install.sh as root on macOS is not recommended."
    log "Homebrew actions will be skipped. Re-run install.sh as your normal user if you need packages installed via Homebrew."
    log "If Homebrew asks for your password during installation, that is normal and does not mean you should run the entire installer with sudo."
    ALLOW_BREW=0
  fi
}

setup_package_prefix() {
  if [[ "$EUID" -eq 0 ]]; then
    PKG_PREFIX=()
  elif command -v sudo >/dev/null 2>&1; then
    PKG_PREFIX=(sudo)
  else
    PKG_PREFIX=()
  fi
}

ensure_brew_shellenv() {
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  elif [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
}

install_homebrew() {
  if [[ "$ALLOW_BREW" -eq 0 ]]; then
    return
  fi

  if [[ "$OS" == "linux" && "$EUID" -eq 0 ]]; then
    log "Running as root on Linux. Skipping Homebrew bootstrap and using system packages when available."
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    ensure_brew_shellenv
    return
  fi

  log "Homebrew not found. Installing Homebrew..."
  if [[ "$OS" == "macos" ]]; then
    log "Run this installer as your normal user on macOS. Homebrew may ask for your password, but do not run ./install.sh with sudo just for that."
  fi

  if [[ "$OS" == "linux" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      "${PKG_PREFIX[@]}" apt-get update
      "${PKG_PREFIX[@]}" apt-get install -y curl
    fi
  fi

  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ensure_brew_shellenv

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew installation failed. Please install Homebrew manually and re-run ./install.sh"
    exit 1
  fi
}

brew_install_if_missing() {
  local command_name="$1"
  local formula="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name"
    return
  fi

  log "Installing $formula for missing command: $command_name"
  brew install "$formula"

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name installed via $formula"
  else
    log "[WARN] $command_name still not found after installing $formula"
  fi
}

brew_install_first_available() {
  local command_name="$1"
  shift
  local formula

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name"
    return
  fi

  for formula in "$@"; do
    if brew info --formula "$formula" >/dev/null 2>&1; then
      log "Installing $formula for missing command: $command_name"
      brew install "$formula"
      break
    fi
  done

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name installed"
  else
    log "[WARN] $command_name is still missing after attempted installs: $*"
  fi
}

install_required_tools() {
  if [[ "$ALLOW_BREW" -eq 1 ]] && command -v brew >/dev/null 2>&1; then
    brew update
  fi

  if [[ "$ALLOW_BREW" -eq 1 ]] && command -v brew >/dev/null 2>&1; then
    brew_install_if_missing nmap nmap
    brew_install_if_missing awk gawk
    brew_install_if_missing sed gnu-sed
    brew_install_if_missing grep grep
    brew_install_if_missing find findutils
    brew_install_if_missing mktemp coreutils
    brew_install_if_missing tcpdump tcpdump
    if [[ "$OS" == "linux" ]]; then
      brew_install_first_available ping iputils inetutils
    fi
  fi

  if [[ "$OS" == "linux" ]]; then
    if [[ "$ALLOW_BREW" -eq 1 ]] && command -v brew >/dev/null 2>&1; then
      brew_install_first_available ip iproute2 iproute2mac
      brew_install_first_available route net-tools
    fi

    if command -v apt-get >/dev/null 2>&1; then
      if ! command -v nmap >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1 || ! command -v ping >/dev/null 2>&1 || ! command -v tcpdump >/dev/null 2>&1; then
        "${PKG_PREFIX[@]}" apt-get update
      fi
      command -v nmap >/dev/null 2>&1 || "${PKG_PREFIX[@]}" apt-get install -y nmap
      command -v jq >/dev/null 2>&1 || "${PKG_PREFIX[@]}" apt-get install -y jq
      command -v ip >/dev/null 2>&1 || "${PKG_PREFIX[@]}" apt-get install -y iproute2
      command -v ping >/dev/null 2>&1 || "${PKG_PREFIX[@]}" apt-get install -y iputils-ping
      command -v tcpdump >/dev/null 2>&1 || "${PKG_PREFIX[@]}" apt-get install -y tcpdump
      if ! command -v route >/dev/null 2>&1 && ! command -v ifconfig >/dev/null 2>&1; then
        "${PKG_PREFIX[@]}" apt-get install -y net-tools
      fi
    elif command -v dnf >/dev/null 2>&1; then
      command -v nmap >/dev/null 2>&1 || "${PKG_PREFIX[@]}" dnf install -y nmap
      command -v jq >/dev/null 2>&1 || "${PKG_PREFIX[@]}" dnf install -y jq
      command -v ip >/dev/null 2>&1 || "${PKG_PREFIX[@]}" dnf install -y iproute
      command -v ping >/dev/null 2>&1 || "${PKG_PREFIX[@]}" dnf install -y iputils
      command -v tcpdump >/dev/null 2>&1 || "${PKG_PREFIX[@]}" dnf install -y tcpdump
      if ! command -v route >/dev/null 2>&1 && ! command -v ifconfig >/dev/null 2>&1; then
        "${PKG_PREFIX[@]}" dnf install -y net-tools
      fi
    fi
  fi

  if [[ "$OS" == "macos" ]]; then
    local mac_cmd
    for mac_cmd in ipconfig ifconfig route networksetup; do
      if command -v "$mac_cmd" >/dev/null 2>&1; then
        log "[OK] $mac_cmd"
      else
        log "[WARN] macOS system command missing: $mac_cmd"
      fi
    done
  fi
}

install_speedtest_cli() {
  if command -v speedtest-cli >/dev/null 2>&1; then
    log "[OK] speedtest-cli"
    return
  fi

  log "Installing speedtest-cli"

  if [[ "$OS" == "macos" ]]; then
    if [[ "$ALLOW_BREW" -eq 1 ]] && command -v brew >/dev/null 2>&1; then
      brew install speedtest-cli
    else
      log "[WARN] speedtest-cli installation on macOS requires Homebrew. Re-run install.sh as a normal user if Homebrew installation is needed."
      return
    fi
  elif [[ "$OS" == "linux" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      "${PKG_PREFIX[@]}" apt-get update
      "${PKG_PREFIX[@]}" apt-get install -y speedtest-cli
    elif command -v dnf >/dev/null 2>&1; then
      "${PKG_PREFIX[@]}" dnf install -y speedtest-cli
    elif command -v brew >/dev/null 2>&1; then
      brew install speedtest-cli
    else
      log "[WARN] No supported package manager found (apt-get, dnf, or brew) for speedtest-cli installation"
      return
    fi
  fi

  if command -v speedtest-cli >/dev/null 2>&1; then
    log "[OK] speedtest-cli"
  else
    log "[WARN] speedtest-cli is still missing after installation attempt"
  fi
}

maybe_normalize_install_dir_name() {
  local current_dir="$SCRIPT_DIR"
  local parent_dir=""
  local current_name=""
  local target_dir=""

  parent_dir="$(dirname "$current_dir")"
  current_name="$(basename "$current_dir")"

  if [[ "$current_name" == "lss-network-tools" ]]; then
    return 0
  fi

  if [[ ! "$current_name" =~ ^lss-network-tools- ]]; then
    return 0
  fi

  target_dir="$parent_dir/lss-network-tools"
  if [[ -e "$target_dir" ]]; then
    log "[WARN] Cannot rename install folder because $target_dir already exists."
    return 0
  fi

  if mv "$current_dir" "$target_dir" 2>/dev/null; then
    log "Install folder renamed to: $target_dir"
    log "Run the tool from: $target_dir"
  else
    log "[WARN] Could not rename install folder to $target_dir"
  fi
}

detect_os
warn_about_root_usage
setup_package_prefix
install_homebrew
install_required_tools
install_speedtest_cli

mkdir -p "$SCRIPT_DIR/output"
chmod +x "$SCRIPT_DIR/lss-network-tools.sh"

log "Installation complete."
log "Run: ./lss-network-tools.sh"
maybe_normalize_install_dir_name
