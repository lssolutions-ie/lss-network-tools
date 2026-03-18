#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="lss-network-tools"
APP_SCRIPT="lss-network-tools.sh"
APP_GITHUB_REPO="lssolutions-ie/lss-network-tools"
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

print_section() {
  local title="$1"
  echo
  echo "$title"
  printf '%*s\n' "${#title}" '' | tr ' ' '='
  echo
}

print_substep() {
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

get_local_app_version() {
  awk -F'"' '/^APP_VERSION=/{print $2; exit}' "$SCRIPT_DIR/$APP_SCRIPT" 2>/dev/null || true
}

download_tag_zipball() {
  local tag="$1"
  local destination="$2"
  local zip_url="https://api.github.com/repos/${APP_GITHUB_REPO}/zipball/refs/tags/${tag}"

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  curl -fL "$zip_url" -o "$destination"
}

extract_update_archive() {
  local archive_file="$1"
  local destination_dir="$2"

  mkdir -p "$destination_dir"

  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive_file" -d "$destination_dir"
    return 0
  fi

  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$archive_file" -C "$destination_dir"
    return 0
  fi

  return 1
}

handoff_to_latest_installer() {
  local remote_tag="$1"
  local archive_file=""
  local extract_dir=""
  local source_root=""

  archive_file="$(mktemp "/tmp/${APP_NAME}-installer-update-XXXXXX.zip")"
  extract_dir="$(mktemp -d "/tmp/${APP_NAME}-installer-update-XXXXXX")"

  log "Downloading latest installer bundle for ${remote_tag}..."
  if ! download_tag_zipball "$remote_tag" "$archive_file"; then
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    fail "Failed to download the latest release bundle for ${remote_tag}."
  fi

  if ! extract_update_archive "$archive_file" "$extract_dir"; then
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    fail "Could not extract the latest installer bundle."
  fi

  source_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$source_root" || ! -f "$source_root/install.sh" ]]; then
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    fail "The downloaded release bundle did not contain a usable installer."
  fi

  log "Launching the latest installer from ${remote_tag}..."
  export LSS_SKIP_FRESHNESS_CHECK=1
  exec bash "$source_root/install.sh"
}

latest_remote_tag_from_github() {
  local api_url="https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=100"
  local response=""

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  if ! response="$(curl -fsSL "$api_url" 2>/dev/null)"; then
    return 1
  fi

  printf '%s\n' "$response" | grep -o '"name":[[:space:]]*"[^"]*"' | sed 's/.*"name":[[:space:]]*"\([^"]*\)"/\1/' | sort -V | tail -n 1
}

check_source_version_freshness() {
  local local_version=""
  local remote_tag=""
  local choice=""

  if [[ "${LSS_SKIP_FRESHNESS_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  local_version="$(get_local_app_version)"
  if [[ -z "$local_version" ]]; then
    log "[WARN] Could not determine local APP_VERSION before install."
    return 0
  fi

  print_section "Installer Preflight"
  print_substep "Checking whether this downloaded copy is current..."
  remote_tag="$(latest_remote_tag_from_github || true)"

  if [[ -z "$remote_tag" ]]; then
    log "[WARN] Could not read the latest GitHub tag. Continuing with the local copy."
    return 0
  fi

  log "Local version: $local_version"
  log "Latest available tag: $remote_tag"

  if [[ "$local_version" == "$remote_tag" ]]; then
    log "[OK] This installer matches the latest published version."
    return 0
  fi

  echo
  echo "Update Available Before Install"
  echo "==============================="
  echo
  echo "[install] WARNING: This downloaded copy is not the latest published version."
  echo "[install] Installing an older copy can reintroduce bugs that were already fixed."
  echo "[install] Type UPDATE to download the latest release bundle and relaunch install.sh automatically."
  echo
  read -r -p "Type UPDATE to continue with the latest version, or press Enter to cancel: " choice

  if [[ "$choice" == "UPDATE" ]]; then
    handoff_to_latest_installer "$remote_tag"
  fi

  fail "Installation cancelled because the local copy is outdated."
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

  print_section "Dependency Setup"
  print_substep "Installing required dependencies..."

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

  print_section "Application Deployment"
  print_substep "Deploying application files to $APP_TARGET_DIR"

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
  print_substep "Creating command wrapper at $WRAPPER_PATH"
  mkdir -p "$(dirname "$WRAPPER_PATH")"

  cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
exec "$APP_TARGET_DIR/$APP_SCRIPT" "\$@"
EOF

  chmod 755 "$WRAPPER_PATH"
}

print_install_summary() {
  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local reset='\033[0m'

  print_section "Install Complete"
  printf "${yellow}[install] Installation complete.${reset}\n"
  log "Command: $WRAPPER_PATH"
  log "App files: $APP_TARGET_DIR"

  if [[ "$OS" == "linux" ]]; then
    log "Data: $DATA_TARGET_DIR"
  else
    log "Data: $APP_TARGET_DIR/output"
  fi

  printf "${green}[install] Run: sudo %s${reset}\n" "$APP_NAME"
  printf "${green}[install] Uninstall later with: sudo %s --uninstall${reset}\n" "$APP_NAME"
  printf "${green}[install] If command completion does not work immediately, open a new shell.${reset}\n"
  printf "${green}[install] For zsh, you can also run: rehash && autoload -Uz compinit && compinit${reset}\n"
  append_install_audit_log "install" "success" "Application deployed to ${APP_TARGET_DIR}"
}

detect_os
require_root
check_source_version_freshness
install_dependencies
prepare_target_directories
deploy_application_files
write_wrapper
print_install_summary
