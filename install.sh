#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="lss-network-tools"
APP_SCRIPT="lss-network-tools.sh"
OS=""
APP_TARGET_DIR="${LSS_INSTALL_APP_DIR:-}"
DATA_TARGET_DIR="${LSS_INSTALL_DATA_DIR:-}"
WRAPPER_PATH="${LSS_INSTALL_WRAPPER_PATH:-/usr/local/bin/${APP_NAME}}"
BREW_USER=""
BREW_BIN=""
AUDIT_LOG_PATH=""

log() {
  echo "[install] $*"
}

append_install_audit_log() {
  local action="$1"
  local status="$2"
  local detail="$3"
  local timestamp=""

  [[ -z "$AUDIT_LOG_PATH" ]] && return 0
  mkdir -p "$(dirname "$AUDIT_LOG_PATH")"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s | %s | %s | %s\n' "$timestamp" "$action" "$status" "$detail" >> "$AUDIT_LOG_PATH"
}

fail() {
  echo "[install] ERROR: $*" >&2
  exit 1
}

detect_os() {
  case "$(uname -s)" in
    Darwin)
      OS="macos"
      APP_TARGET_DIR="${APP_TARGET_DIR:-/usr/local/share/${APP_NAME}}"
      DATA_TARGET_DIR="${DATA_TARGET_DIR:-$APP_TARGET_DIR}"
      AUDIT_LOG_PATH="${DATA_TARGET_DIR}/install-audit.log"
      ;;
    Linux)
      OS="linux"
      APP_TARGET_DIR="${APP_TARGET_DIR:-/usr/local/lib/${APP_NAME}}"
      DATA_TARGET_DIR="${DATA_TARGET_DIR:-/var/lib/${APP_NAME}}"
      AUDIT_LOG_PATH="${DATA_TARGET_DIR}/install-audit.log"
      ;;
    *)
      fail "Unsupported platform: $(uname -s)"
      ;;
  esac
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "Run install.sh with sudo or as root."
  fi
}

detect_brew_user() {
  if [[ "$OS" == "macos" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    BREW_USER="$SUDO_USER"
  fi
}

detect_brew_binary() {
  if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    BREW_BIN="/opt/homebrew/bin/brew"
  elif [[ -x /usr/local/bin/brew ]]; then
    BREW_BIN="/usr/local/bin/brew"
  else
    BREW_BIN=""
  fi
}

run_macos_user_shell() {
  local command_string="$1"
  local user_home=""
  local brew_path=""

  if [[ -z "$BREW_USER" ]]; then
    return 1
  fi

  user_home="$(dscl . -read "/Users/$BREW_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [[ -z "$user_home" ]] && user_home="/Users/$BREW_USER"

  brew_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  sudo -u "$BREW_USER" env HOME="$user_home" PATH="$brew_path" bash --noprofile --norc -lc "$command_string"
}

ensure_homebrew() {
  if [[ "$OS" != "macos" ]]; then
    return 0
  fi

  detect_brew_binary
  if [[ -n "$BREW_BIN" ]]; then
    return 0
  fi

  if [[ -z "$BREW_USER" ]]; then
    fail "Homebrew is not installed. On macOS, run install.sh from your normal admin user with sudo so Homebrew can be installed if needed."
  fi

  log "Homebrew not found. Installing Homebrew for ${BREW_USER}..."
  log "Homebrew may prompt for your macOS password during first-time setup."
  run_macos_user_shell '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

  detect_brew_binary
  if [[ -z "$BREW_BIN" ]]; then
    fail "Homebrew installation failed."
  fi
}

brew_install_if_missing() {
  local command_name="$1"
  local formula="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name"
    return 0
  fi

  if [[ -z "$BREW_USER" ]]; then
    fail "Missing required tool '$command_name'. On macOS, rerun install.sh from your normal admin user with sudo so Homebrew can install missing packages."
  fi

  log "Installing $formula for missing command: $command_name"
  run_macos_user_shell "\"$BREW_BIN\" install $formula"
}

install_linux_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y nmap jq iproute2 iputils-ping tcpdump net-tools speedtest-cli zip unzip
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y nmap jq iproute iputils tcpdump net-tools speedtest-cli zip unzip
    return 0
  fi

  fail "No supported Linux package manager found. Expected apt-get or dnf."
}

install_macos_dependencies() {
  detect_brew_user
  ensure_homebrew

  brew_install_if_missing nmap nmap
  brew_install_if_missing jq jq
  brew_install_if_missing speedtest-cli speedtest-cli
  brew_install_if_missing tcpdump tcpdump

  log "[OK] ipconfig"
  log "[OK] ifconfig"
  log "[OK] route"
  log "[OK] networksetup"
  log "[OK] ping"
  log "[OK] zip"
}

install_dependencies() {
  if [[ "${LSS_SKIP_DEPS:-0}" == "1" ]]; then
    log "Skipping dependency installation because LSS_SKIP_DEPS=1"
    return 0
  fi

  log "Installing required dependencies..."

  if [[ "$OS" == "macos" ]]; then
    install_macos_dependencies
  else
    install_linux_dependencies
  fi
}

prepare_target_directories() {
  mkdir -p "$APP_TARGET_DIR"

  if [[ "$OS" == "linux" ]]; then
    mkdir -p "$DATA_TARGET_DIR/output" "$DATA_TARGET_DIR/raw" "$DATA_TARGET_DIR/tmp"
  else
    mkdir -p "$APP_TARGET_DIR/output" "$APP_TARGET_DIR/raw" "$APP_TARGET_DIR/tmp"
  fi
}

deploy_application_files() {
  local source_file=""
  local target_file=""

  log "Deploying application files to $APP_TARGET_DIR"

  source_file="$SCRIPT_DIR/$APP_SCRIPT"
  target_file="$APP_TARGET_DIR/$APP_SCRIPT"
  if [[ "$source_file" != "$target_file" ]]; then
    install -m 755 "$source_file" "$target_file"
  else
    chmod 755 "$target_file"
  fi

  source_file="$SCRIPT_DIR/install.sh"
  target_file="$APP_TARGET_DIR/install.sh"
  if [[ "$source_file" != "$target_file" ]]; then
    install -m 755 "$source_file" "$target_file"
  else
    chmod 755 "$target_file"
  fi

  if [[ -f "$SCRIPT_DIR/README.md" ]]; then
    source_file="$SCRIPT_DIR/README.md"
    target_file="$APP_TARGET_DIR/README.md"
    if [[ "$source_file" != "$target_file" ]]; then
      install -m 644 "$source_file" "$target_file"
    fi
  fi

  cat > "$APP_TARGET_DIR/install.env" <<EOF
APP_ROOT="$APP_TARGET_DIR"
DATA_ROOT="$DATA_TARGET_DIR"
INSTALL_WRAPPER_PATH="$WRAPPER_PATH"
EOF
  chmod 644 "$APP_TARGET_DIR/install.env"
}

write_wrapper() {
  log "Creating command wrapper at $WRAPPER_PATH"
  mkdir -p "$(dirname "$WRAPPER_PATH")"

  cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$APP_TARGET_DIR/$APP_SCRIPT" "\$@"
EOF

  chmod 755 "$WRAPPER_PATH"
}

print_install_summary() {
  log "Installation complete."
  log "Command: $WRAPPER_PATH"
  log "App files: $APP_TARGET_DIR"

  if [[ "$OS" == "linux" ]]; then
    log "Data: $DATA_TARGET_DIR"
  else
    log "Data: $APP_TARGET_DIR/output"
  fi

  log "Run: sudo ${APP_NAME}"
  log "Uninstall later with: sudo ${APP_NAME} --uninstall"
  log "If command completion does not work immediately, open a new shell."
  log "For zsh, you can also run: rehash && autoload -Uz compinit && compinit"
  append_install_audit_log "install" "success" "Application deployed to ${APP_TARGET_DIR}"
}

detect_os
require_root
install_dependencies
prepare_target_directories
deploy_application_files
write_wrapper
print_install_summary
