#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS=""

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
  if command -v brew >/dev/null 2>&1; then
    ensure_brew_shellenv
    return
  fi

  log "Homebrew not found. Installing Homebrew..."

  if [[ "$OS" == "linux" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install -y curl
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
  brew update

  brew_install_if_missing nmap nmap
  brew_install_if_missing awk gawk
  brew_install_if_missing sed gnu-sed
  brew_install_if_missing grep grep
  brew_install_if_missing find findutils
  brew_install_if_missing mktemp coreutils
  brew_install_if_missing sudo sudo

  if [[ "$OS" == "linux" ]]; then
    brew_install_first_available ip iproute2 iproute2mac
    brew_install_first_available route net-tools
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

install_optional_tools() {
  if command -v speedtest >/dev/null 2>&1; then
    log "[OK] speedtest"
    return
  fi

  log "Installing optional speedtest tool"
  if brew info --formula speedtest >/dev/null 2>&1; then
    brew install speedtest
  else
    brew install speedtest-cli
  fi

  if command -v speedtest >/dev/null 2>&1; then
    log "[OK] speedtest"
  elif command -v speedtest-cli >/dev/null 2>&1; then
    log "[WARN] speedtest command not available, but speedtest-cli is installed"
  else
    log "[WARN] speedtest installation did not provide a runnable command"
  fi
}

detect_os
install_homebrew
install_required_tools
install_optional_tools

mkdir -p "$SCRIPT_DIR/output"
chmod +x "$SCRIPT_DIR/lss-network-tools.sh"

log "Installation complete."
log "Run: ./lss-network-tools.sh"
