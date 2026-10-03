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
# Colon-separated list of /tmp paths left behind by a parent installer that
# handed off to us (see handoff_to_latest_installer). Removed on exit.
HANDOFF_CLEANUP_PATHS="${LSS_HANDOFF_CLEANUP:-}"

log() {
  echo "[install] $*"
}

cleanup_handoff_artifacts() {
  local entry=""
  local old_ifs="$IFS"

  [[ -z "$HANDOFF_CLEANUP_PATHS" ]] && return 0

  IFS=':'
  for entry in $HANDOFF_CLEANUP_PATHS; do
    # Only ever remove the temp artefacts this installer family creates.
    case "$entry" in
      /tmp/"${APP_NAME}"-installer-update-*)
        rm -rf "$entry" 2>/dev/null || true
        ;;
    esac
  done
  IFS="$old_ifs"
  HANDOFF_CLEANUP_PATHS=""
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

  curl -fL --connect-timeout 10 --max-time 300 "$zip_url" -o "$destination"
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
  # The child installer removes these on exit (success or failure) via its EXIT trap.
  export LSS_HANDOFF_CLEANUP="${archive_file}:${extract_dir}"
  exec bash "$source_root/install.sh"
}

latest_remote_tag_from_github() {
  local api_url="https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=100"
  local response=""

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  if ! response="$(curl -fsSL --connect-timeout 10 --max-time 300 "$api_url" 2>/dev/null)"; then
    return 1
  fi

  printf '%s\n' "$response" | grep -o '"name":[[:space:]]*"[^"]*"' | sed 's/.*"name":[[:space:]]*"\([^"]*\)"/\1/' | sort -V | tail -n 1
}

# Prints the newest of two version strings using natural version ordering.
version_newest_of() {
  printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1
}

check_source_version_freshness() {
  local local_version=""
  local remote_tag=""
  local newest=""
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

  if ! command -v curl >/dev/null 2>&1; then
    log "[WARN] curl is not available, so the latest release could not be checked. Continuing with the local copy."
    return 0
  fi

  remote_tag="$(latest_remote_tag_from_github || true)"
  if [[ -z "$remote_tag" ]]; then
    log "[WARN] Could not read the latest GitHub tag (network or API error). Continuing with the local copy."
    return 0
  fi

  log "Local version: $local_version"
  log "Latest available tag: $remote_tag"

  if [[ "$local_version" == "$remote_tag" ]]; then
    log "[OK] This installer matches the latest published version."
    return 0
  fi

  if ! printf 'v1\nv2\n' | sort -V >/dev/null 2>&1; then
    log "[WARN] 'sort -V' is unavailable, so versions cannot be compared. Continuing with the local copy."
    return 0
  fi

  newest="$(version_newest_of "$local_version" "$remote_tag")"
  if [[ "$newest" == "$local_version" ]]; then
    # Local copy is newer than anything published (e.g. a development checkout).
    log "[OK] Local copy ($local_version) is newer than the latest published tag ($remote_tag)."
    return 0
  fi

  echo
  echo "Update Available Before Install"
  echo "==============================="
  echo
  echo "[install] WARNING: This downloaded copy ($local_version) is older than the latest published version ($remote_tag)."
  echo "[install] Installing an older copy can reintroduce bugs that were already fixed."
  echo "[install]   UPDATE   - download the latest release bundle and relaunch install.sh automatically"
  echo "[install]   CONTINUE - install this local copy anyway"
  echo "[install]   Enter    - cancel"
  echo
  read -r -p "Type UPDATE, CONTINUE, or press Enter to cancel: " choice || true
  choice="$(printf '%s' "$choice" | tr '[:lower:]' '[:upper:]')"

  case "$choice" in
    UPDATE)
      handoff_to_latest_installer "$remote_tag"
      ;;
    CONTINUE)
      log "[WARN] Continuing with the local copy ($local_version) as requested."
      return 0
      ;;
  esac

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

# Resolve a user's home directory without eval'ing an env-derived string.
# macOS: Directory Services; Linux: passwd database; fallback: $HOME.
resolve_user_home() {
  local user_name="$1"
  local user_home=""

  if [[ -n "$user_name" ]]; then
    if [[ "$OS" == "macos" ]]; then
      user_home="$(dscl . -read "/Users/$user_name" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    elif command -v getent >/dev/null 2>&1; then
      user_home="$(getent passwd "$user_name" 2>/dev/null | cut -d: -f6)"
    fi
  fi

  [[ -z "$user_home" ]] && user_home="${HOME:-}"
  printf '%s\n' "$user_home"
}

run_macos_user_shell() {
  local command_string="$1"
  local user_home=""
  local brew_path=""

  if [[ -z "$BREW_USER" ]]; then
    return 1
  fi

  user_home="$(resolve_user_home "$BREW_USER")"
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
  run_macos_user_shell '/bin/bash -c "$(curl -fsSL --connect-timeout 10 --max-time 300 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

  detect_brew_binary
  if [[ -z "$BREW_BIN" ]]; then
    fail "Homebrew installation failed."
  fi
}

# brew_install_if_missing <command> <formula> [optional-note]
# With a third argument the tool is optional: install failures log a warning
# (mentioning the note, e.g. "Task 19") instead of aborting the installer.
brew_install_if_missing() {
  local command_name="$1"
  local formula="$2"
  local optional_note="${3:-}"

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name"
    return 0
  fi

  if [[ -z "$BREW_USER" ]]; then
    if [[ -n "$optional_note" ]]; then
      log "[WARN] $command_name unavailable (needed for $optional_note only). Install later with: brew install $formula"
      return 0
    fi
    fail "Missing required tool '$command_name'. On macOS, rerun install.sh from your normal admin user with sudo so Homebrew can install missing packages."
  fi

  log "Installing $formula for missing command: $command_name"
  if run_macos_user_shell "\"$BREW_BIN\" install $formula"; then
    return 0
  fi

  if [[ -n "$optional_note" ]]; then
    log "[WARN] $command_name unavailable (needed for $optional_note only). Install later with: brew install $formula"
    return 0
  fi

  fail "Failed to install required tool '$command_name' (brew install $formula)."
}

# install_linux_optional_package <manager> <command> <package> <note>
# Optional tools are installed one at a time so a missing package never
# aborts the whole dependency step under set -e.
install_linux_optional_package() {
  local manager="$1"
  local command_name="$2"
  local package="$3"
  local optional_note="$4"

  if command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name"
    return 0
  fi

  if "$manager" install -y "$package" >/dev/null 2>&1 && command -v "$command_name" >/dev/null 2>&1; then
    log "[OK] $command_name"
    return 0
  fi

  log "[WARN] $command_name unavailable (needed for $optional_note only). Install later with: $manager install $package"
  return 0
}

install_linux_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y \
      nmap jq iproute2 iputils-ping tcpdump net-tools \
      zip unzip python3 python3-pip iw

    # Optional tools: non-fatal if the package is unavailable
    install_linux_optional_package apt-get sshpass sshpass "Task 19"
    install_linux_optional_package apt-get arp-scan arp-scan "Task 12"

    # speedtest-cli: try apt package first, fall back to pip3
    if ! apt-get install -y speedtest-cli 2>/dev/null; then
      log "speedtest-cli not available via apt — installing via pip3..."
      pip3 install --quiet speedtest-cli 2>/dev/null \
        || pip3 install --quiet --break-system-packages speedtest-cli 2>/dev/null \
        || log "[WARN] speedtest-cli install failed — Task 2 (Internet Speed Test) will not work"
    fi

    # scapy: try apt package first, fall back to pip3
    if ! apt-get install -y python3-scapy 2>/dev/null; then
      log "python3-scapy not available via apt — installing via pip3..."
      pip3 install --quiet scapy 2>/dev/null \
        || pip3 install --quiet --break-system-packages scapy 2>/dev/null \
        || log "[WARN] scapy install failed — Tasks 11 and 18 will not work"
    fi
    if ! python3 -c "import scapy" 2>/dev/null; then
      log "[WARN] scapy not importable after install attempt — Tasks 11 and 18 may not work"
    else
      log "[OK] python3-scapy"
    fi

    # fpdf2: pip3 only (no apt package)
    pip3 install --quiet fpdf2 2>/dev/null \
      || pip3 install --quiet --break-system-packages fpdf2 2>/dev/null \
      || log "[WARN] fpdf2 install failed — PDF report generation will not work"
    if python3 -c "import fpdf" 2>/dev/null; then
      log "[OK] python3-fpdf2"
    else
      log "[WARN] fpdf2 not importable after install attempt — PDF report generation will not work"
    fi
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y \
      nmap jq iproute iputils tcpdump net-tools \
      zip unzip python3 python3-pip iw

    # Optional tools: non-fatal if the package is unavailable
    install_linux_optional_package dnf sshpass sshpass "Task 19"
    install_linux_optional_package dnf arp-scan arp-scan "Task 12"

    # speedtest-cli: not in standard dnf repos — use pip3
    pip3 install --quiet speedtest-cli 2>/dev/null \
      || pip3 install --quiet --break-system-packages speedtest-cli 2>/dev/null \
      || log "[WARN] speedtest-cli install failed — Task 2 (Internet Speed Test) will not work"

    # scapy: try dnf package first, fall back to pip3
    if ! dnf install -y python3-scapy 2>/dev/null; then
      log "python3-scapy not available via dnf — installing via pip3..."
      pip3 install --quiet scapy 2>/dev/null \
        || pip3 install --quiet --break-system-packages scapy 2>/dev/null \
        || log "[WARN] scapy install failed — Tasks 11 and 18 will not work"
    fi
    if ! python3 -c "import scapy" 2>/dev/null; then
      log "[WARN] scapy not importable after install attempt — Tasks 11 and 18 may not work"
    else
      log "[OK] python3-scapy"
    fi

    # fpdf2: pip3 only
    pip3 install --quiet fpdf2 2>/dev/null \
      || pip3 install --quiet --break-system-packages fpdf2 2>/dev/null \
      || log "[WARN] fpdf2 install failed — PDF report generation will not work"
    if python3 -c "import fpdf" 2>/dev/null; then
      log "[OK] python3-fpdf2"
    else
      log "[WARN] fpdf2 not importable after install attempt — PDF report generation will not work"
    fi
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
  brew_install_if_missing python3 python3
  # Optional tools: a failed tap/formula logs a warning instead of aborting
  brew_install_if_missing sshpass hudochenkov/sshpass/sshpass "Task 19"
  brew_install_if_missing arp-scan arp-scan "Task 12"

  log "Checking Python scapy library..."
  if ! python3 -c "import scapy" 2>/dev/null; then
    log "Installing scapy via pip3..."
    if [[ -n "$BREW_USER" ]]; then
      run_macos_user_shell "pip3 install --quiet scapy 2>/dev/null || pip3 install --quiet --break-system-packages scapy 2>/dev/null" || true
    else
      pip3 install --quiet scapy 2>/dev/null || pip3 install --quiet --break-system-packages scapy 2>/dev/null || true
    fi
  fi
  if python3 -c "import scapy" 2>/dev/null; then
    log "[OK] python3 scapy"
  else
    fail "Failed to install Python scapy library. Install manually with: pip3 install scapy"
  fi

  log "Checking Python fpdf2 library..."
  if ! python3 -c "import fpdf" 2>/dev/null; then
    log "Installing fpdf2 via pip3..."
    if [[ -n "$BREW_USER" ]]; then
      run_macos_user_shell "pip3 install --quiet fpdf2 2>/dev/null || pip3 install --quiet --break-system-packages fpdf2 2>/dev/null" || true
    else
      pip3 install --quiet fpdf2 2>/dev/null || pip3 install --quiet --break-system-packages fpdf2 2>/dev/null || true
    fi
  fi
  if python3 -c "import fpdf" 2>/dev/null; then
    log "[OK] python3 fpdf2"
  else
    fail "Failed to install Python fpdf2 library. Install manually with: pip3 install fpdf2"
  fi

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
  local py_helper=""

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

  # Python report generators required by the main script at $APP_ROOT/
  for py_helper in generate_pdf_report.py generate_pdf_compare_report.py; do
    source_file="$SCRIPT_DIR/$py_helper"
    target_file="$APP_TARGET_DIR/$py_helper"
    if [[ ! -f "$source_file" ]]; then
      log "[WARN] $py_helper not found in $SCRIPT_DIR — PDF report generation will not work"
      continue
    fi
    if [[ "$source_file" != "$target_file" ]]; then
      install -m 755 "$source_file" "$target_file"
    else
      chmod 755 "$target_file"
    fi
  done

  if [[ -d "$SCRIPT_DIR/assets" && "$SCRIPT_DIR/assets" != "$APP_TARGET_DIR/assets" ]]; then
    mkdir -p "$APP_TARGET_DIR/assets"
    cp -R "$SCRIPT_DIR/assets/." "$APP_TARGET_DIR/assets/"
  fi

  cat > "$APP_TARGET_DIR/install.env" <<EOF
APP_ROOT="$APP_TARGET_DIR"
DATA_ROOT="$DATA_TARGET_DIR"
INSTALL_WRAPPER_PATH="$WRAPPER_PATH"
EOF
  chmod 644 "$APP_TARGET_DIR/install.env"
}

write_completions() {
  # Shell completions are owned by the main script (--write-completions); the
  # updater calls it the same way, so the installer just delegates to the
  # freshly deployed copy. Failure here must never abort the install.
  local deployed_script="$APP_TARGET_DIR/$APP_SCRIPT"

  if [[ ! -f "$deployed_script" ]]; then
    log "[WARN] $deployed_script not found — shell completions not installed."
    return 0
  fi

  print_substep "Installing zsh and bash completions via $APP_NAME --write-completions"
  if ! bash "$deployed_script" --write-completions 2>/dev/null; then
    log "[WARN] Shell completion setup failed. Retry later with: sudo $APP_NAME --write-completions"
  fi
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
  printf '%b[install] Installation complete.%b\n' "$yellow" "$reset"
  log "Command: $WRAPPER_PATH"
  log "App files: $APP_TARGET_DIR"

  if [[ "$OS" == "linux" ]]; then
    log "Data: $DATA_TARGET_DIR"
  else
    log "Data: $APP_TARGET_DIR/output"
  fi

  printf '%b[install] Run: sudo %s%b\n' "$green" "$APP_NAME" "$reset"
  printf '%b[install] Uninstall later with: sudo %s --uninstall%b\n' "$green" "$APP_NAME" "$reset"
  printf '%b[install] Tab completion installed for zsh and bash. Open a new shell to activate it.%b\n' "$green" "$reset"
  append_install_audit_log "install" "success" "Application deployed to ${APP_TARGET_DIR}"
}

build_wifi_scan_helper() {
  # Build the LSS-WiFiScan.app bundle used by the Wireless Site Survey task.
  # Done here at install/update time so it's ready when the task first runs.
  [[ "$OS" != "macos" ]] && return 0
  local deployed_script="$APP_TARGET_DIR/$APP_SCRIPT"
  [[ -f "$deployed_script" ]] || return 0
  if ! command -v swiftc >/dev/null 2>&1; then
    log "[SKIP] swiftc not found — Wi-Fi scan helper not built. Install Xcode Command Line Tools and re-run to build it."
    return 0
  fi
  log "Building Wi-Fi scan helper (LSS-WiFiScan.app)..."
  # Source the deployed script in a subshell to call the build function directly.
  # We suppress the main() execution by setting a flag the script honours.
  LSS_BUILD_WIFI_HELPER=1 bash "$deployed_script" --build-wifi-helper 2>/dev/null || \
    log "[WARN] Wi-Fi scan helper build failed. Run 'sudo lss-network-tools --build-wifi-helper' to retry."
}

trap cleanup_handoff_artifacts EXIT
detect_os
require_root
check_source_version_freshness
install_dependencies
prepare_target_directories
deploy_application_files
write_wrapper
write_completions
build_wifi_scan_helper
print_install_summary
