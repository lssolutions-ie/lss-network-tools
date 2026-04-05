#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="lss-network-tools"
APP_VERSION="v1.2.171"
APP_GITHUB_REPO="lssolutions-ie/lss-network-tools"
APP_ROOT="$SCRIPT_DIR"
DATA_ROOT="$SCRIPT_DIR"
TMP_ROOT="$SCRIPT_DIR/tmp"
INSTALL_MODE="portable"
INSTALL_WRAPPER_PATH="/usr/local/bin/lss-network-tools"
OUTPUT_DIR="$SCRIPT_DIR/output"
RUN_OUTPUT_DIR=""
RUN_DATE_STAMP=""
RUN_REPORT_TIME_STAMP=""
RUN_CLIENT_NAME=""
RUN_LOCATION=""
RUN_CLIENT_SLUG=""
RUN_LOCATION_SLUG=""
RUN_REPORT_FILE=""
RUN_PREPARED_BY=""
RUN_NOTE=""
RUN_NOTE_SLUG=""
HIGH_IMPACT_STRESS_CONFIRMED=0
SESSION_DEBUG_LOG=""
RUN_DEBUG_LOG=""
RUN_MANIFEST_FILE=""
OUTPUT_IS_TTY=0
DEBUG_MODE=0
UNINSTALL_MODE=0
VERSION_MODE=0
UPDATE_MODE=0
BUILD_WIFI_HELPER_MODE=0
WRITE_COMPLETIONS_MODE=0
INSTALL_DEPS_MODE=0

OS=""
SELECTED_INTERFACE=""
SHOW_FUNCTION_HEADER=1
TASK_OUTPUT_INDENT=""
SPINNER_PID=""
NETWORK_INTERRUPTED=false
_GOTO_MAIN_MENU=false
TASKS_DATA=$(cat <<'TASKS'
1|Interface Network Info|interface-network-info.json
2|Internet Speed Test|internet-speed-test.json
3|Gateway Details|gateway-scan.json
4|DHCP Network Scan|dhcp-scan.json
5|DHCP Response Time|dhcp-response-time.json
6|DNS Network Scan|dns-scan.json
7|LDAP/AD Network Scan|ldap-ad-scan.json
8|SMB/NFS Network Scan|smb-nfs-scan.json
9|Printer/Print Server Network Scan|print-server-scan.json
10|Gateway Stress Test|gateway-stress-test.json
11|VLAN/Trunk Detection|vlan-trunk-scan.json
12|Duplicate IP Detection|duplicate-ip-scan.json
13|Custom Target Port Scan|custom-target-port-scan.json
14|Custom Target Stress Test|custom-target-stress-test.json
15|Custom Target Identity Scan|custom-target-identity-scan.json
16|Custom Target DNS Assessment|custom-target-dns-assessment.json
17|Wireless Site Survey|wireless-survey.json
18|Scan For UniFi Devices|unifi-discovery.json
19|UniFi Adoption|unifi-adoption.json
20|Find Device by MAC|find-device-by-mac.json
TASKS
)

print_alert() {
  echo "ALERT: $1"
}

ensure_standard_path() {
  local extra_paths=()
  local path_entry=""

  if [[ "$OS" == "macos" ]]; then
    extra_paths=(/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin)
  else
    extra_paths=(/usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin)
  fi

  for path_entry in "${extra_paths[@]}"; do
    case ":$PATH:" in
      *":$path_entry:"*) ;;
      *) PATH="$path_entry:$PATH" ;;
    esac
  done

  export PATH
}

configure_runtime_paths() {
  local install_config="$SCRIPT_DIR/install.env"

  if [[ -f "$install_config" ]]; then
    # shellcheck disable=SC1090
    source "$install_config"
    INSTALL_MODE="installed"
    APP_ROOT="${APP_ROOT:-$SCRIPT_DIR}"
    DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR}"
    INSTALL_WRAPPER_PATH="${INSTALL_WRAPPER_PATH:-/usr/local/bin/$APP_NAME}"
    TMP_ROOT="$DATA_ROOT/tmp"
    OUTPUT_DIR="$DATA_ROOT/output"
    return 0
  fi

  case "$OS" in
    macos)
      if [[ "$SCRIPT_DIR" == "/usr/local/share/$APP_NAME" ]]; then
        INSTALL_MODE="installed"
        APP_ROOT="/usr/local/share/$APP_NAME"
        DATA_ROOT="$APP_ROOT"
      else
        INSTALL_MODE="portable"
        APP_ROOT="$SCRIPT_DIR"
        DATA_ROOT="$SCRIPT_DIR"
      fi
      ;;
    linux)
      if [[ "$SCRIPT_DIR" == "/usr/local/lib/$APP_NAME" ]]; then
        INSTALL_MODE="installed"
        APP_ROOT="/usr/local/lib/$APP_NAME"
        DATA_ROOT="/var/lib/$APP_NAME"
      else
        INSTALL_MODE="portable"
        APP_ROOT="$SCRIPT_DIR"
        DATA_ROOT="$SCRIPT_DIR"
      fi
      ;;
  esac

  TMP_ROOT="$DATA_ROOT/tmp"
  OUTPUT_DIR="$DATA_ROOT/output"
}

ensure_runtime_directories() {
  mkdir -p "$OUTPUT_DIR" "$TMP_ROOT"
  mkdir -p "$DATA_ROOT/raw"
  export TMPDIR="$TMP_ROOT"
}

validate_json_file() {
  local file="$1"
  if ! jq . "$file" >/dev/null 2>&1; then
    print_alert "JSON validation failed for $file"
    return 1
  fi
}

json_file_usable() {
  local file="$1"
  [[ -s "$file" ]] && jq . "$file" >/dev/null 2>&1
}

append_finding_record() {
  local current_json="$1"
  local severity="$2"
  local title="$3"
  local detail="$4"
  local source="$5"

  jq -cn \
    --argjson existing "$current_json" \
    --arg severity "$severity" \
    --arg title "$title" \
    --arg detail "$detail" \
    --arg source "$source" \
    '$existing + [{
      severity: $severity,
      title: $title,
      detail: $detail,
      source: $source
    }]'
}

wait_for_pid() {
  local pid="$1"
  local error_message="$2"

  if ! wait "$pid"; then
    echo "$error_message"
    return 1
  fi
}

confirm_gateway_stress_operation() {
  local context_label="${1:-Function 9}"
  local target_description="${2:-the detected local gateway/firewall}"
  local confirmation=""

  if [[ "$HIGH_IMPACT_STRESS_CONFIRMED" -eq 1 ]]; then
    return 0
  fi

  echo
  echo "WARNING: $context_label includes Gateway Stress Test."
  echo "This test only targets $target_description with ICMP."
  echo "It does not perform exploits or service attacks, but it can disrupt routing, VPNs, WAN access, or unstable devices."
  echo "Run this only when you accept possible service impact."
  echo "If the target is a gateway or firewall, consider disconnecting it from internet or performing this after-hours if disruption would be unacceptable."
  read -r -p "Proceed? [y/N]: " confirmation

  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Gateway Stress Test cancelled."
    return 1
  fi

  HIGH_IMPACT_STRESS_CONFIRMED=1
  return 0
}

task_field() {
  local task_id="$1"
  local field_index="$2"

  awk -F'|' -v id="$task_id" -v idx="$field_index" '$1 == id { print $idx; exit }' <<< "$TASKS_DATA"
}

sanitize_for_filename() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(echo "$value" | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"

  if [[ -z "$value" ]]; then
    value="unknown"
  fi

  echo "$value"
}

current_output_dir() {
  if [[ -n "$RUN_OUTPUT_DIR" ]]; then
    echo "$RUN_OUTPUT_DIR"
  else
    echo "$OUTPUT_DIR"
  fi
}

current_raw_output_dir() {
  printf '%s/raw\n' "$(current_output_dir)"
}

current_audit_log_path() {
  printf '%s/install-audit.log\n' "$DATA_ROOT"
}

append_audit_log() {
  local action="$1"
  local status="$2"
  local detail="$3"
  local audit_log=""
  local timestamp=""

  audit_log="$(current_audit_log_path)"
  mkdir -p "$(dirname "$audit_log")"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s | %s | %s | %s\n' "$timestamp" "$action" "$status" "$detail" >> "$audit_log"
}

version_matches() {
  local expected="$1"
  local reported=""

  reported="$(bash "$SCRIPT_DIR/$(basename "$BASH_SOURCE")" --version 2>/dev/null || true)"
  [[ "$reported" == "$APP_NAME $expected" ]]
}

initialize_debug_logging() {
  if [[ -n "$SESSION_DEBUG_LOG" ]]; then
    return
  fi

  find "$OUTPUT_DIR" -maxdepth 1 -type f -name '.debug-session-*.txt' -delete 2>/dev/null || true

  # Check stdin (fd 0) rather than stdout (fd 1) — stdout may already be
  # piped through tee when relaunched after an update via exec sudo.
  if [[ -t 0 ]]; then
    OUTPUT_IS_TTY=1
  fi

  if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "This program must be run with elevated privileges."
    echo "Please run: sudo lss-network-tools"
    exit 1
  fi

  SESSION_DEBUG_LOG="$OUTPUT_DIR/.debug-session-$$.txt"
  : > "$SESSION_DEBUG_LOG"
  exec > >(tee -a "$SESSION_DEBUG_LOG") 2>&1
}

is_installed_mode() {
  [[ "$INSTALL_MODE" == "installed" ]]
}

about_and_health() {
  local red='\033[0;31m'
  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local reset='\033[0m'
  local issues=0

  # ── System Info ──────────────────────────────────────────────────────────
  local audit_count custom_count total_count python_version
  audit_count="$(echo "$(get_audit_task_ids)" | wc -w | tr -d ' ')"
  total_count="$(get_task_ids | wc -w | tr -d ' ')"
  custom_count=$(( total_count - audit_count ))
  python_version="$(python3 --version 2>/dev/null || echo "not found")"

  echo
  echo "About / System Info"
  echo "==================="
  echo
  echo "Application:  $APP_NAME"
  echo "Version:      $APP_VERSION"
  echo "OS:           $OS"
  echo "Install Mode: $INSTALL_MODE"
  echo "Script Path:  $SCRIPT_DIR"
  echo "App Root:     $APP_ROOT"
  echo "Data Root:    $DATA_ROOT"
  echo "Wrapper:      $(installed_wrapper_path)"
  echo "Output Root:  $OUTPUT_DIR"
  echo "User:         $(id -un 2>/dev/null || echo unknown) (EUID $EUID)"
  echo "Python:       $python_version"
  echo "Tasks:        $total_count total ($audit_count core audit, $custom_count custom)"

  # ── Install Health ────────────────────────────────────────────────────────
  local path wrapper_path tool tools_to_check=()
  wrapper_path="$(installed_wrapper_path)"

  echo
  echo "Install Health"
  echo "=============="
  echo

  if is_installed_mode; then
    printf "${green}[OK]${reset} Installed mode detected\n"
  else
    printf "${yellow}[WARN]${reset} Installed mode not detected; running from a portable/source path\n"
    issues=$((issues + 1))
  fi

  for path in "$APP_ROOT" "$OUTPUT_DIR" "$TMP_ROOT"; do
    if [[ -e "$path" ]]; then
      printf "${green}[OK]${reset} %s\n" "$path"
    else
      printf "${red}[MISSING]${reset} %s\n" "$path"
      issues=$((issues + 1))
    fi
  done

  if [[ "$OS" == "linux" ]]; then
    for path in "$DATA_ROOT" "$DATA_ROOT/raw" "$DATA_ROOT/install-audit.log"; do
      if [[ -e "$path" ]]; then
        printf "${green}[OK]${reset} %s\n" "$path"
      else
        if [[ "$path" == "$DATA_ROOT/install-audit.log" ]]; then
          printf "${yellow}[WARN]${reset} %s (will appear after install/update/uninstall logging)\n" "$path"
        else
          printf "${red}[MISSING]${reset} %s\n" "$path"
          issues=$((issues + 1))
        fi
      fi
    done
  else
    for path in "$DATA_ROOT/raw" "$DATA_ROOT/install-audit.log"; do
      if [[ -e "$path" ]]; then
        printf "${green}[OK]${reset} %s\n" "$path"
      else
        if [[ "$path" == "$DATA_ROOT/install-audit.log" ]]; then
          printf "${yellow}[WARN]${reset} %s (will appear after install/update/uninstall logging)\n" "$path"
        else
          printf "${red}[MISSING]${reset} %s\n" "$path"
          issues=$((issues + 1))
        fi
      fi
    done
  fi

  if [[ -x "$wrapper_path" ]]; then
    printf "${green}[OK]${reset} %s\n" "$wrapper_path"
  else
    printf "${red}[MISSING]${reset} %s\n" "$wrapper_path"
    issues=$((issues + 1))
  fi

  echo
  echo "Dependencies"
  echo "------------"
  tools_to_check=(nmap jq speedtest-cli tcpdump awk sed grep find mktemp python3 sshpass)
  if [[ "$OS" == "macos" ]]; then
    tools_to_check+=(ipconfig ifconfig route networksetup ping)
  else
    tools_to_check+=(ip ping)
  fi
  for tool in "${tools_to_check[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf "${green}[OK]${reset} %s\n" "$tool"
    else
      printf "${red}[MISSING]${reset} %s\n" "$tool"
      issues=$((issues + 1))
    fi
  done
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import scapy" 2>/dev/null; then
      printf "${green}[OK]${reset} python3-scapy\n"
    else
      printf "${red}[MISSING]${reset} python3-scapy\n"
      issues=$((issues + 1))
    fi
    if python3 -c "import fpdf" 2>/dev/null; then
      printf "${green}[OK]${reset} python3-fpdf2\n"
    else
      printf "${red}[MISSING]${reset} python3-fpdf2\n"
      issues=$((issues + 1))
    fi
  fi

  echo
  echo "Software Versions"
  echo "-----------------"
  printf "%-20s %s\n" "lss-network-tools" "$APP_VERSION"
  if command -v nmap >/dev/null 2>&1; then
    printf "%-20s %s\n" "nmap" "$(nmap --version 2>/dev/null | head -1 | awk '{print $3}')"
  fi
  if command -v jq >/dev/null 2>&1; then
    printf "%-20s %s\n" "jq" "$(jq --version 2>/dev/null)"
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf "%-20s %s\n" "python3" "$(python3 --version 2>/dev/null)"
    printf "%-20s %s\n" "fpdf2" "$(python3 -c 'import fpdf; print(fpdf.__version__)' 2>/dev/null || echo 'not installed')"
    printf "%-20s %s\n" "scapy" "$(python3 -c 'import scapy; print(scapy.__version__)' 2>/dev/null || echo 'not installed')"
  fi
  if command -v speedtest-cli >/dev/null 2>&1; then
    printf "%-20s %s\n" "speedtest-cli" "$(speedtest-cli --version 2>/dev/null | head -1)"
  fi

  echo
  echo "Task 17 - Wireless Site Survey"
  echo "------------------------------"
  if [[ "$OS" == "macos" ]]; then
    if command -v swiftc >/dev/null 2>&1; then
      printf "${green}[OK]${reset} swiftc ($(swiftc --version 2>/dev/null | head -1))\n"
    else
      printf "${yellow}[WARN]${reset} swiftc not found — install Xcode Command Line Tools: xcode-select --install\n"
      issues=$((issues + 1))
    fi
    local helper_ver
    helper_ver="$(cat "${_LSS_WIFI_HELPER}.version" 2>/dev/null || true)"
    if [[ -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
      if [[ "$helper_ver" == "$APP_VERSION" ]]; then
        printf "${green}[OK]${reset} LSS-WiFiScan.app (${helper_ver})\n"
      else
        printf "${yellow}[WARN]${reset} LSS-WiFiScan.app outdated (built for ${helper_ver:-unknown}, current ${APP_VERSION}) — run: sudo lss-network-tools --build-wifi-helper\n"
        issues=$((issues + 1))
      fi
    else
      printf "${red}[MISSING]${reset} LSS-WiFiScan.app not built — run: sudo lss-network-tools --build-wifi-helper\n"
      issues=$((issues + 1))
    fi
    local tcc_val=""
    local tcc_readable=0
    if command -v sqlite3 >/dev/null 2>&1; then
      # macOS SIP protects TCC.db from all processes without Full Disk Access (even the file owner).
      # We try both user and system DBs and track whether sqlite3 could actually open either one.
      local real_home
      if [[ -n "${SUDO_USER:-}" ]]; then
        real_home="$(eval echo "~$SUDO_USER" 2>/dev/null)" || true
      else
        real_home="$HOME"
      fi
      local user_tcc_db="$real_home/Library/Application Support/com.apple.TCC/TCC.db"
      local sys_tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"
      local q="SELECT auth_value FROM access WHERE service='kTCCServiceLocation' AND client='ie.lssolutions.wifi-scan';"
      local out
      if out="$(sqlite3 "$user_tcc_db" "$q" 2>/dev/null)"; then
        tcc_readable=1
        tcc_val="$out"
      fi
      if [[ "$tcc_readable" -eq 0 ]]; then
        if out="$(sqlite3 "$sys_tcc_db" "$q" 2>/dev/null)"; then
          tcc_readable=1
          tcc_val="$out"
        fi
      fi
    fi
    if [[ "$tcc_readable" -eq 1 ]]; then
      case "$tcc_val" in
        2) printf "${green}[OK]${reset} Location Services authorized for LSS-WiFiScan\n" ;;
        0) printf "${red}[DENIED]${reset} Location Services denied — enable in System Settings → Privacy & Security → Location Services\n"
           issues=$((issues + 1)) ;;
        "") printf "${yellow}[WARN]${reset} Location Services not yet requested — run a Wireless Site Survey to authorize\n" ;;
        *) printf "${yellow}[WARN]${reset} Location Services status unknown (code $tcc_val)\n" ;;
      esac
    else
      # TCC.db is SIP-protected; sqlite3 cannot open it without Full Disk Access.
      # Treat as informational only — if a wireless survey has returned results, it is authorized.
      printf "       Location Services: cannot verify (TCC.db requires Full Disk Access)\n"
    fi
  else
    if command -v iw >/dev/null 2>&1; then
      printf "${green}[OK]${reset} iw (wireless scan)\n"
    else
      printf "${yellow}[WARN]${reset} iw not found — Task 17 wireless scan unavailable (install with: apt install iw)\n"
    fi
  fi

  echo
  echo "Task 18 - UniFi Device Scan"
  echo "---------------------------"
  local nse_path="$APP_ROOT/unifi-discover.nse"
  if [[ -f "$nse_path" ]]; then
    printf "${green}[OK]${reset} unifi-discover.nse\n"
  else
    printf "${red}[MISSING]${reset} unifi-discover.nse not found at $nse_path\n"
    issues=$((issues + 1))
  fi
  local _oui_cache_path="/usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt"
  if [[ -f "$_oui_cache_path" ]]; then
    local _oui_count _oui_age_days _oui_mtime _oui_now
    _oui_count="$(wc -l < "$_oui_cache_path" | tr -d ' ')"
    if [[ "$OS" == "macos" ]]; then
      _oui_mtime="$(stat -f %m "$_oui_cache_path" 2>/dev/null || echo 0)"
    else
      _oui_mtime="$(stat -c %Y "$_oui_cache_path" 2>/dev/null || echo 0)"
    fi
    _oui_now="$(date +%s)"
    _oui_age_days=$(( (_oui_now - _oui_mtime) / 86400 ))
    if find "$_oui_cache_path" -mtime -30 -print 2>/dev/null | grep -q .; then
      printf "${green}[OK]${reset} Ubiquiti OUI cache — %s blocks, %s day(s) old (refreshes monthly)\n" "$_oui_count" "$_oui_age_days"
    else
      printf "${yellow}[WARN]${reset} Ubiquiti OUI cache — %s blocks, %s day(s) old (will refresh on next scan)\n" "$_oui_count" "$_oui_age_days"
    fi
  else
    printf "${yellow}[WARN]${reset} Ubiquiti OUI cache not yet created (will fetch on first UniFi scan)\n"
  fi

  echo
  echo "Task 19 - UniFi Adoption"
  echo "------------------------"
  if command -v sshpass >/dev/null 2>&1; then
    printf "${green}[OK]${reset} sshpass\n"
  else
    if [[ "$OS" == "macos" ]]; then
      printf "${red}[MISSING]${reset} sshpass — install with: brew install hudochenkov/sshpass/sshpass\n"
    else
      printf "${red}[MISSING]${reset} sshpass — install with: sudo apt install sshpass\n"
    fi
    issues=$((issues + 1))
  fi

  echo
  if [[ "$issues" -eq 0 ]]; then
    echo "Install health looks good."
  else
    echo "Install health found $issues issue(s)."
  fi
}


installed_wrapper_path() {
  printf '%s\n' "$INSTALL_WRAPPER_PATH"
}

create_backup_zip() {
  local backup_destination="$1"
  local staging_dir=""
  local backup_name=""

  if ! command -v zip >/dev/null 2>&1; then
    echo "Backup requires the zip command, but it is not available."
    return 1
  fi

  mkdir -p "$backup_destination"
  backup_name="${APP_NAME}-backup-$(date +%Y%m%d-%H%M%S).zip"
  staging_dir="$(mktemp -d "/tmp/${APP_NAME}-backup-XXXXXX")" || return 1

  if [[ "$OS" == "linux" ]]; then
    cp -R "$APP_ROOT" "$staging_dir/app"
    cp -R "$DATA_ROOT" "$staging_dir/data"
  else
    cp -R "$APP_ROOT" "$staging_dir/app"
  fi

  (
    cd "$staging_dir"
    zip -qr "$backup_destination/$backup_name" .
  )

  rm -rf "$staging_dir"
  echo "$backup_destination/$backup_name"
}

github_api_headers() {
  local token="${GITHUB_TOKEN:-}"

  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi

  if [[ -n "$token" ]]; then
    printf 'Authorization: Bearer %s\n' "$token"
  fi
  printf 'Accept: application/vnd.github+json\n'
  printf 'User-Agent: %s\n' "$APP_NAME"
}

prompt_for_github_token() {
  local token=""
  local choice=""

  echo
  echo "Authentication may be required for this repository."
  read -r -p "Would you like to enter a GitHub token with read access now? (y/N): " choice
  if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    return 1
  fi

  read -r -s -p "GitHub Token: " token
  echo

  if [[ -z "$token" ]]; then
    return 1
  fi

  GITHUB_TOKEN="$token"
  export GITHUB_TOKEN
  return 0
}

print_private_repo_auth_hint() {
  echo "Authentication may be required to access update metadata or downloads."
  echo "For private repositories, use a GitHub token with read access or authenticate GitHub CLI if available."
}

latest_remote_tag_from_github() {
  local api_url="https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=100"
  local response="" curl_err="" tmp_err
  tmp_err="$(mktemp /tmp/lss-curl-err-XXXXXX)"

  local curl_cmd=(curl -fsSL --max-time 15)
  while IFS= read -r header; do
    [[ -n "$header" ]] && curl_cmd+=(-H "$header")
  done < <(github_api_headers)

  if ! response="$("${curl_cmd[@]}" "$api_url" 2>"$tmp_err")"; then
    curl_err="$(cat "$tmp_err" 2>/dev/null || true)"
    rm -f "$tmp_err"
    [[ -n "$curl_err" ]] && echo "curl error: $curl_err" >&2
    return 1
  fi
  rm -f "$tmp_err"

  jq -r '.[].name' <<< "$response" 2>/dev/null | sort -V | tail -n 1
}

download_tag_zipball() {
  local tag="$1"
  local destination="$2"
  local zip_url="https://api.github.com/repos/${APP_GITHUB_REPO}/zipball/refs/tags/${tag}"
  local -a curl_args=(curl -fL)
  local header

  while IFS= read -r header; do
    [[ -n "$header" ]] && curl_args+=(-H "$header")
  done < <(github_api_headers)

  curl_args+=(-o "$destination" "$zip_url")
  "${curl_args[@]}"
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

  echo "ZIP extraction requires unzip or bsdtar."
  return 1
}

perform_installed_update() {
  local remote_tag="${1:?remote_tag is required}"
  local archive_file=""
  local extract_dir=""
  local source_root=""
  local helper_script=""
  local confirmation=""
  local preserve_find_args=()
  local script_path=""

  if ! is_installed_mode; then
    echo "Updates are only supported from an installed deployment."
    return 1
  fi

  echo "Current Version: ${APP_VERSION}"
  echo "Latest Available Tag: ${remote_tag}"
  echo
  read -r -p "Install update ${remote_tag}? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Update cancelled."
    return 0
  fi

  archive_file="$(mktemp "/tmp/${APP_NAME}-update-XXXXXX.zip")" || return 1
  extract_dir="$(mktemp -d "/tmp/${APP_NAME}-update-XXXXXX")" || return 1

  if ! download_tag_zipball "$remote_tag" "$archive_file"; then
    echo "Failed to download update archive for ${remote_tag}."
    echo "Check that this machine has internet access and that api.github.com is reachable."
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    return 1
  fi

  if ! extract_update_archive "$archive_file" "$extract_dir"; then
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    return 1
  fi

  source_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$source_root" || ! -d "$source_root" ]]; then
    echo "Failed to locate the extracted update payload."
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    return 1
  fi

  helper_script="$(mktemp "/tmp/${APP_NAME}-apply-update-XXXXXX.sh")" || return 1
  script_path="$APP_ROOT/$(basename "$BASH_SOURCE")"

  if [[ "$OS" == "macos" ]]; then
    preserve_find_args=(
      ! -name output
      ! -name raw
      ! -name tmp
      ! -name install.env
      ! -name assets
    )
  else
    preserve_find_args=(
      ! -name install.env
      ! -name assets
    )
  fi

  cat > "$helper_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SOURCE_ROOT="$source_root"
DEST_DIR="$APP_ROOT"
ARCHIVE_FILE="$archive_file"
EXTRACT_DIR="$extract_dir"
HELPER_SCRIPT="$helper_script"
SCRIPT_PATH="$script_path"
AUDIT_LOG_PATH="$(current_audit_log_path)"

find "\$DEST_DIR" -mindepth 1 -maxdepth 1 ${preserve_find_args[*]} -exec rm -rf {} +
cp -R "\$SOURCE_ROOT"/. "\$DEST_DIR"/
chmod +x "\$DEST_DIR"/*.sh 2>/dev/null || true
bash "\$SCRIPT_PATH" --install-deps 2>/dev/null || true
# Merge new bundle assets without overwriting user-placed files (e.g. logo.svg)
if [[ -d "\$SOURCE_ROOT/assets" ]]; then
  find "\$SOURCE_ROOT/assets" -type d | while read -r src_dir; do
    dest_dir="\$DEST_DIR/\${src_dir#\$SOURCE_ROOT/}"
    mkdir -p "\$dest_dir"
  done
  find "\$SOURCE_ROOT/assets" -type f | while read -r src_file; do
    dest_file="\$DEST_DIR/\${src_file#\$SOURCE_ROOT/}"
    [[ -f "\$dest_file" ]] || cp "\$src_file" "\$dest_file"
  done
fi
bash "\$SCRIPT_PATH" --build-wifi-helper 2>/dev/null || true
bash "\$SCRIPT_PATH" --write-completions 2>/dev/null || true
REPORTED_VERSION="\$(bash "\$SCRIPT_PATH" --version 2>/dev/null || true)"
mkdir -p "\$(dirname "\$AUDIT_LOG_PATH")"
if [[ "\$REPORTED_VERSION" != "${APP_NAME} $remote_tag" ]]; then
  printf '%s | %s | %s | %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "update" "failed" "Expected ${APP_NAME} $remote_tag but saw \$REPORTED_VERSION" >> "\$AUDIT_LOG_PATH"
  echo
  echo "Update verification failed."
  echo "Expected version: ${APP_NAME} $remote_tag"
  echo "Reported version: \$REPORTED_VERSION"
  rm -f "\$ARCHIVE_FILE"
  rm -rf "\$EXTRACT_DIR"
  rm -f "\$HELPER_SCRIPT"
  exit 1
fi
printf '%s | %s | %s | %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "update" "success" "Installed version ${remote_tag}" >> "\$AUDIT_LOG_PATH"
rm -f "\$ARCHIVE_FILE"
rm -rf "\$EXTRACT_DIR"
rm -f "\$HELPER_SCRIPT"
echo
echo "Update applied successfully. Installed Version: $remote_tag"
echo "Relaunching ${APP_NAME}..."
sleep 1
if [[ "\$(id -u)" -eq 0 ]]; then
  exec "$INSTALL_WRAPPER_PATH"
else
  exec sudo "$INSTALL_WRAPPER_PATH"
fi
EOF
  chmod +x "$helper_script"

  echo
  echo "Applying update and exiting current session..."
  exec bash "$helper_script"
}

check_for_updates() {
  local remote_tag=""

  echo
  echo "Check For Updates"
  echo "================="
  echo

  if ! is_installed_mode; then
    echo "Updates are only supported from an installed deployment."
    return 1
  fi

  echo "Current Version: $APP_VERSION"
  echo
  echo "Checking remote tags..."

  local curl_err_out=""
  remote_tag="$(latest_remote_tag_from_github 2>/tmp/lss-update-err || true)"
  curl_err_out="$(cat /tmp/lss-update-err 2>/dev/null || true)"
  rm -f /tmp/lss-update-err
  if [[ -z "$remote_tag" ]]; then
    echo "Unable to reach GitHub API (https://api.github.com)."
    [[ -n "$curl_err_out" ]] && echo "Error: $curl_err_out"
    echo "Check that this machine has internet access and that api.github.com is reachable."
    echo "Update check failed."
    return 1
  fi

  echo "Latest Available Tag: $remote_tag"

  if [[ "$remote_tag" == "$APP_VERSION" ]]; then
    echo
    echo "This installation is already up to date."
    return 0
  fi

  echo
  echo "An update is available."
  perform_installed_update "$remote_tag"
}

write_completion_files() {
  local zsh_system_dir="/usr/local/share/zsh/site-functions"
  local zsh_dir=""
  local bash_dir
  local real_home

  # When running under sudo, write zshrc edits to the invoking user's home
  if [[ -n "${SUDO_USER:-}" ]]; then
    real_home=$(eval echo "~${SUDO_USER}")
  else
    real_home="$HOME"
  fi
  local zsh_user_dir="$real_home/.zsh/completions"

  if [[ "$OS" == "macos" ]]; then
    bash_dir="/usr/local/etc/bash_completion.d"
  else
    bash_dir="/etc/bash_completion.d"
  fi

  # Try system dir first; fall back to user dir (always writable)
  mkdir -p "$zsh_system_dir" 2>/dev/null || true
  if [[ -w "$zsh_system_dir" ]]; then
    zsh_dir="$zsh_system_dir"
  else
    mkdir -p "$zsh_user_dir" 2>/dev/null || true
    if [[ -w "$zsh_user_dir" ]]; then
      zsh_dir="$zsh_user_dir"
    fi
  fi

  if [[ -n "$zsh_dir" ]]; then
    cat > "$zsh_dir/_lss-network-tools" <<'ZSHCOMP'
#compdef lss-network-tools

_lss-network-tools() {
  local -a opts
  opts=(
    '--version:Print version and exit'
    '--update:Check for and install updates'
    '--uninstall:Uninstall the application'
    '--build-wifi-helper:Build the Wi-Fi scan helper'
    '--debug:Enable debug output'
  )
  _describe 'options' opts
}

_lss-network-tools "$@"
ZSHCOMP
    chmod 644 "$zsh_dir/_lss-network-tools"

    # Ensure ~/.zshrc initialises the completion system.
    # If using the user dir, also add it to fpath.
    local zshrc="$real_home/.zshrc"
    local needs_compinit=0
    local needs_fpath=0

    if [[ ! -f "$zshrc" ]] || ! grep -q "compinit" "$zshrc" 2>/dev/null; then
      needs_compinit=1
    fi
    if [[ "$zsh_dir" == "$zsh_user_dir" ]]; then
      if [[ ! -f "$zshrc" ]] || ! grep -q '\.zsh/completions' "$zshrc" 2>/dev/null; then
        needs_fpath=1
      fi
    fi

    if [[ "$needs_fpath" -eq 1 || "$needs_compinit" -eq 1 ]]; then
      {
        echo ""
        echo "# lss-network-tools tab completion"
        [[ "$needs_fpath" -eq 1 ]] && echo 'fpath=(~/.zsh/completions $fpath)'
        [[ "$needs_compinit" -eq 1 ]] && echo 'autoload -Uz compinit && compinit'
      } >> "$zshrc"
      # If we wrote as root, restore ownership to the real user
      if [[ -n "${SUDO_USER:-}" ]]; then
        chown "${SUDO_USER}" "$zshrc" 2>/dev/null || true
      fi
    fi
  fi

  mkdir -p "$bash_dir" 2>/dev/null || true
  if [[ -w "$bash_dir" ]]; then
    cat > "$bash_dir/lss-network-tools" <<'BASHCOMP'
_lss_network_tools_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "--version --update --uninstall --build-wifi-helper --debug" -- "$cur"))
}
complete -F _lss_network_tools_completions lss-network-tools
BASHCOMP
    chmod 644 "$bash_dir/lss-network-tools"
  fi
}

uninstall_installed_application() {
  local wrapper_path=""
  local uninstall_choice=""
  local backup_choice=""
  local backup_dir=""
  local backup_file=""

  if ! is_installed_mode; then
    echo "This command only works from an installed deployment."
    return 1
  fi

  wrapper_path="$(installed_wrapper_path)"

  echo
  echo "Uninstall LSS Network Tools"
  echo "==========================="
  echo
  echo "This will remove the installed application and all stored data."
  if [[ "$OS" == "linux" ]]; then
    echo "App path: $APP_ROOT"
    echo "Data path: $DATA_ROOT"
  else
    echo "Installed path: $APP_ROOT"
  fi
  echo
  echo "Backup data before uninstall?"
  echo "1) Yes"
  echo "2) No"
  echo "3) Cancel"
  echo
  read -r -p "Choose option: " backup_choice

  case "$backup_choice" in
    1)
      read -r -p "Enter backup destination directory: " backup_dir
      if [[ -z "$backup_dir" ]]; then
        echo "Backup cancelled because no destination was provided."
        return 1
      fi
      case "$backup_dir" in
        "$APP_ROOT"|"$APP_ROOT"/*|"$DATA_ROOT"|"$DATA_ROOT"/*)
          echo "Backup destination cannot be inside the installed application or data directories."
          return 1
          ;;
      esac
      backup_file="$(create_backup_zip "$backup_dir")" || return 1
      echo "Backup created: $backup_file"
      ;;
    2)
      ;;
    3)
      echo "Uninstall cancelled."
      return 0
      ;;
    *)
      echo "Uninstall cancelled."
      return 1
      ;;
  esac

  echo
  read -r -p "Type DELETE to permanently remove LSS Network Tools: " uninstall_choice
  if [[ "$uninstall_choice" != "DELETE" ]]; then
    echo "Uninstall cancelled."
    return 0
  fi

  append_audit_log "uninstall" "success" "Installed application removal started"
  rm -f "$wrapper_path"
  rm -rf "$APP_ROOT"
  if [[ "$OS" == "linux" ]]; then
    rm -rf "$DATA_ROOT"
  fi

  # Remove shell completions
  rm -f "/usr/local/share/zsh/site-functions/_lss-network-tools" 2>/dev/null || true
  rm -f "$HOME/.zsh/completions/_lss-network-tools" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    rm -f "$(eval echo "~${SUDO_USER}")/.zsh/completions/_lss-network-tools" 2>/dev/null || true
  fi
  rm -f "/usr/local/etc/bash_completion.d/lss-network-tools" 2>/dev/null || true
  rm -f "/etc/bash_completion.d/lss-network-tools" 2>/dev/null || true

  # Remove Location Services TCC entry for LSS-WiFiScan.app (macOS only)
  if [[ "$OS" == "macos" ]]; then
    tccutil reset Location ie.lssolutions.wifi-scan 2>/dev/null || true
  fi

  echo "LSS Network Tools has been removed."
  return 0
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --debug)
        DEBUG_MODE=1
        ;;
      --uninstall)
        UNINSTALL_MODE=1
        ;;
      --update)
        UPDATE_MODE=1
        ;;
      --version)
        VERSION_MODE=1
        ;;
      --build-wifi-helper)
        BUILD_WIFI_HELPER_MODE=1
        ;;
      --write-completions)
        WRITE_COMPLETIONS_MODE=1
        ;;
      --install-deps)
        INSTALL_DEPS_MODE=1
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: lss-network-tools [--debug] [--uninstall] [--update] [--version] [--build-wifi-helper] [--write-completions]"
        exit 1
        ;;
    esac
    shift
  done
}

task_output_path() {
  local task_id="$1"
  local output_file

  output_file="$(task_output_file "$task_id")"
  if [[ -z "$output_file" ]]; then
    return 1
  fi

  printf '%s/%s\n' "$(current_output_dir)" "$output_file"
}

task_supports_multiple_entries() {
  case "$1" in
    10|13|14|15|16) return 0 ;;
    *) return 1 ;;
  esac
}

task_output_glob() {
  local task_id="$1"
  local output_file

  output_file="$(task_output_file "$task_id")"
  if [[ -z "$output_file" ]]; then
    return 1
  fi

  if task_supports_multiple_entries "$task_id"; then
    printf '%s-device-*.json\n' "${output_file%.json}"
  else
    printf '%s\n' "$output_file"
  fi
}

task_json_files() {
  local task_id="$1"
  local file_path
  local file_glob

  if task_supports_multiple_entries "$task_id"; then
    file_glob="$(task_output_glob "$task_id")"
    find "$(current_output_dir)" -maxdepth 1 -type f -name "$file_glob" | sort | while IFS= read -r file_path; do
      if json_file_usable "$file_path"; then
        echo "$file_path"
      fi
    done
  else
    file_path="$(task_output_path "$task_id")"
    if json_file_usable "$file_path"; then
      echo "$file_path"
    fi
  fi
}

next_multi_entry_output_path() {
  local task_id="$1"
  local entry_index

  entry_index="$(next_multi_entry_index "$task_id")"
  multi_entry_output_path_for_index "$task_id" "$entry_index"
}

next_multi_entry_index() {
  local task_id="$1"
  local output_file
  local prefix
  local count

  output_file="$(task_output_file "$task_id")"
  if [[ -z "$output_file" ]]; then
    return 1
  fi

  prefix="${output_file%.json}"
  count="$(find "$(current_output_dir)" -maxdepth 1 -type f -name "${prefix}-device-*.json" | wc -l | awk '{print $1}')"
  printf '%d\n' "$((count + 1))"
}

multi_entry_output_path_for_index() {
  local task_id="$1"
  local entry_index="$2"
  local output_file
  local prefix

  output_file="$(task_output_file "$task_id")"
  if [[ -z "$output_file" ]]; then
    return 1
  fi

  prefix="${output_file%.json}"
  printf '%s/%s-device-%s.json\n' "$(current_output_dir)" "$prefix" "$entry_index"
}

task_raw_prefix() {
  local task_id="$1"
  local output_file

  output_file="$(task_output_file "$task_id")"
  if [[ -z "$output_file" ]]; then
    return 1
  fi

  output_file="${output_file%.json}"
  printf '%s/%s\n' "$(current_raw_output_dir)" "$output_file"
}

next_multi_entry_raw_prefix() {
  local task_id="$1"
  local entry_index

  entry_index="$(next_multi_entry_index "$task_id")"
  multi_entry_raw_prefix_for_index "$task_id" "$entry_index"
}

multi_entry_raw_prefix_for_index() {
  local task_id="$1"
  local entry_index="$2"
  local output_file
  local prefix

  output_file="$(task_output_file "$task_id")"
  if [[ -z "$output_file" ]]; then
    return 1
  fi

  prefix="${output_file%.json}"
  printf '%s/%s-device-%s\n' "$(current_raw_output_dir)" "$prefix" "$entry_index"
}

copy_raw_artifact() {
  local source_file="$1"
  local destination_file="$2"

  mkdir -p "$(dirname "$destination_file")"
  cp "$source_file" "$destination_file"
  chmod 644 "$destination_file" 2>/dev/null || true
}

prompt_for_target_ip() {
  local prompt_text="${1:-Target IP Address: }"
  local target_ip=""

  while true; do
    read -r -p "$prompt_text" target_ip
    if [[ "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && awk -F'.' '
      NF == 4 {
        for (i = 1; i <= 4; i++) {
          if ($i < 0 || $i > 255) {
            exit 1
          }
        }
        exit 0
      }
      { exit 1 }
    ' <<< "$target_ip"; then
      echo "$target_ip"
      return 0
    fi

    echo "Invalid IPv4 address. Try again."
  done
}

resolve_target_hostname() {
  local target_ip="$1"
  local hostname=""

  if command -v dig >/dev/null 2>&1; then
    hostname="$(dig +short -x "$target_ip" 2>/dev/null | sed -n '1p' | sed 's/\.$//')" || true
  fi

  if [[ -z "$hostname" ]] && command -v host >/dev/null 2>&1; then
    hostname="$(host "$target_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF; exit}' | sed 's/\.$//')" || true
  fi

  if [[ -z "$hostname" ]] && command -v nslookup >/dev/null 2>&1; then
    hostname="$(nslookup "$target_ip" 2>/dev/null | awk -F'= ' '/name =/ {print $2; exit}' | sed 's/\.$//')" || true
  fi

  if [[ -z "$hostname" ]]; then
    echo "unknown"
  else
    echo "$hostname"
  fi
}

ip_in_cidr() {
  local ip="$1"
  local cidr="$2"
  local network_ip prefix target_network

  [[ -z "$ip" || -z "$cidr" ]] && return 1
  network_ip="${cidr%/*}"
  prefix="${cidr#*/}"
  target_network="$(calculate_network "$ip" "$prefix" 2>/dev/null || true)"
  [[ -n "$target_network" && "$target_network" == "$cidr" ]]
}

collect_custom_target_warnings() {
  local target_ip="$1"
  local iface="$2"
  local warnings=()
  local iface_details=""
  local iface_ip=""
  local gateway_ip=""
  local network_cidr=""

  iface_details="$(get_interface_details "$iface")"
  IFS='|' read -r iface_ip _ _ _ gateway_ip <<< "$iface_details"
  network_cidr="$(get_interface_network_cidr "$iface" 2>/dev/null || true)"

  if [[ -n "$iface_ip" && "$target_ip" == "$iface_ip" ]]; then
    warnings+=("The target IP matches the current machine on interface $iface.")
  fi
  if [[ -n "$gateway_ip" && "$target_ip" == "$gateway_ip" ]]; then
    warnings+=("The target IP matches the current default gateway for interface $iface.")
  fi
  if [[ -n "$network_cidr" ]] && ! ip_in_cidr "$target_ip" "$network_cidr"; then
    warnings+=("The target IP appears to be outside the selected interface subnet $network_cidr.")
  fi

  if [[ "${#warnings[@]}" -gt 0 ]]; then
    printf '%s\n' "${warnings[@]}"
  fi
}

lookup_mac_vendor_online() {
  local mac_address="$1"
  local vendor_name=""

  [[ -z "$mac_address" ]] && return 0

  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi

  vendor_name="$(curl -fsS --max-time 3 "https://api.macvendors.com/$mac_address" 2>/dev/null || true)"
  if [[ -n "$vendor_name" ]]; then
    printf '%s\n' "$vendor_name"
  fi
}

initialize_run_context() {
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}New Run Setup${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  read -r -p "  Location: " RUN_LOCATION
  read -r -p "  Client Name: " RUN_CLIENT_NAME
  read -r -p "  Note (optional — e.g. VLAN 10, Server Room, Guest WiFi): " RUN_NOTE

  if [[ -z "$RUN_LOCATION" ]]; then
    RUN_LOCATION="Unknown"
  fi

  if [[ -z "$RUN_CLIENT_NAME" ]]; then
    RUN_CLIENT_NAME="Unknown"
  fi

  RUN_LOCATION_SLUG="$(sanitize_for_filename "$RUN_LOCATION")"
  RUN_CLIENT_SLUG="$(sanitize_for_filename "$RUN_CLIENT_NAME")"
  RUN_DATE_STAMP="$(date '+%d-%m-%Y')"
  RUN_REPORT_TIME_STAMP="$(date '+%H-%M')"

  if [[ -n "$RUN_NOTE" ]]; then
    RUN_NOTE_SLUG="$(sanitize_for_filename "$RUN_NOTE")"
    RUN_OUTPUT_DIR="$OUTPUT_DIR/${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}-${RUN_NOTE_SLUG}"
  else
    RUN_NOTE_SLUG=""
    RUN_OUTPUT_DIR="$OUTPUT_DIR/${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}"
  fi

  RUN_REPORT_FILE="$RUN_OUTPUT_DIR/lss-network-tools-report-${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}-${RUN_REPORT_TIME_STAMP}.txt"
  RUN_DEBUG_LOG="$RUN_OUTPUT_DIR/debug.txt"
  RUN_MANIFEST_FILE="$RUN_OUTPUT_DIR/manifest.json"

  mkdir -p "$RUN_OUTPUT_DIR"
  mkdir -p "$(current_raw_output_dir)"

  echo
  printf "  ${cyan}Run output directory:${reset} %s\n" "$RUN_OUTPUT_DIR"
  echo
}

prompt_prepared_by() {
  local name=""
  echo
  read -r -p "Prepared by (full name): " name
  RUN_PREPARED_BY="${name:-}"
}

build_report_for_current_run() {
  local json_count
  local report_file
  local timestamp
  local ran_summary=""
  local missing_summary=""
  local func_id title file_name file_path description
  local task_files=()
  local entry_index
  local report_interface
  local interface_info_file
  local detected_iface

  if [[ -z "$RUN_OUTPUT_DIR" ]]; then
    echo "Run output directory is not initialized."
    return 1
  fi

  json_count="$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' | while IFS= read -r json_path; do
    if json_file_usable "$json_path"; then
      echo "$json_path"
    fi
  done | wc -l | awk '{print $1}')"
  if [[ "$json_count" -eq 0 ]]; then
    echo "No JSON scan files found in $RUN_OUTPUT_DIR"
    return 1
  fi

  if [[ -z "$RUN_REPORT_FILE" || "$RUN_REPORT_FILE" == "$RUN_OUTPUT_DIR/"* ]]; then
    RUN_REPORT_TIME_STAMP="$(date '+%H-%M')"
    RUN_REPORT_FILE="$RUN_OUTPUT_DIR/lss-network-tools-report-${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}-${RUN_REPORT_TIME_STAMP}.txt"
  fi
  report_file="$RUN_REPORT_FILE"
  timestamp="$(date '+%d-%m-%Y %H:%M')"

  if [[ -n "${SELECTED_INTERFACE:-}" ]]; then
    report_interface="$SELECTED_INTERFACE"
  else
    interface_info_file="$(task_output_path 1)"
    if [[ -f "$interface_info_file" ]]; then
      detected_iface="$(jq -r '.interface // empty' "$interface_info_file" 2>/dev/null)"
      report_interface="${detected_iface:-unknown}"
    else
      report_interface="unknown"
    fi
  fi

  {
    echo "==============================================="
    echo "     LSS NETWORK TOOLS - REPORT"
    echo "==============================================="
    echo "Location: $RUN_LOCATION"
    echo "Client: $RUN_CLIENT_NAME"
    if [[ -n "$RUN_NOTE" ]]; then
      echo "Note: $RUN_NOTE"
    fi
    echo "Generated: $timestamp"
    echo "Prepared By: ${RUN_PREPARED_BY:-Unknown}"
    echo "Selected Interface: $report_interface"
    echo
  } > "$report_file"

  for func_id in $(get_task_ids); do
    title="$(task_title "$func_id")"
    if [[ -n "$(task_json_files "$func_id")" ]]; then
      ran_summary+="[x] ${func_id}) ${title}"$'\n'
    else
      missing_summary+="[ ] ${func_id}) ${title}"$'\n'
    fi
  done

  {
    echo "Executed Functions"
    echo "------------------"
    if [[ -n "$ran_summary" ]]; then
      printf "%b" "$ran_summary"
    else
      echo "none"
    fi
    echo
    echo "Not Executed"
    echo "------------"
    if [[ -n "$missing_summary" ]]; then
      printf "%b" "$missing_summary"
    else
      echo "none"
    fi
    echo
  } >> "$report_file"

  for func_id in $(get_task_ids); do
    title="$(task_title "$func_id")"
    task_files=()
    while IFS= read -r file_path; do
      [[ -n "$file_path" ]] && task_files+=("$file_path")
    done < <(task_json_files "$func_id")
    if [[ "${#task_files[@]}" -eq 0 ]]; then
      continue
    fi

    entry_index=0
    for file_path in "${task_files[@]}"; do
      entry_index=$((entry_index + 1))
      description="$(task_description "$func_id")"
      {
        echo "================================================"
        if task_supports_multiple_entries "$func_id"; then
          echo "$func_id: $title - Device $entry_index"
        else
          echo "$func_id: $title"
        fi
        echo "Description: $description"
        echo "================================================"
      } >> "$report_file"

      case "$func_id" in
        1) render_interface_info_report "$file_path" "$report_file" ;;
        2) render_speed_test_report "$file_path" "$report_file" ;;
        3) render_gateway_report "$file_path" "$report_file" ;;
        4) render_dhcp_report "$file_path" "$report_file" ;;
        5) render_dhcp_response_time_report "$file_path" "$report_file" ;;
        6) render_generic_network_scan_report "$file_path" "$report_file" "DNS" ;;
        7) render_generic_network_scan_report "$file_path" "$report_file" "LDAP/AD" ;;
        8) render_generic_network_scan_report "$file_path" "$report_file" "SMB/NFS" ;;
        9) render_generic_network_scan_report "$file_path" "$report_file" "Printer" ;;
        10) render_gateway_stress_report "$file_path" "$report_file" ;;
        11) render_vlan_trunk_report "$file_path" "$report_file" ;;
        12) render_duplicate_ip_report "$file_path" "$report_file" ;;
        13) render_custom_target_port_scan_report "$file_path" "$report_file" ;;
        14) render_custom_target_stress_report "$file_path" "$report_file" ;;
        15) render_custom_target_identity_report "$file_path" "$report_file" ;;
        16) render_custom_target_dns_assessment_report "$file_path" "$report_file" ;;
        17) render_wireless_site_survey_report "$file_path" "$report_file" ;;
        18) render_unifi_discovery_report "$file_path" "$report_file" ;;
        19) render_unifi_adoption_report "$file_path" "$report_file" ;;
        20) render_find_device_by_mac_report "$file_path" "$report_file" ;;
      esac

      echo >> "$report_file"
    done
  done

  append_findings_summary "$report_file"
  append_remediation_hints "$report_file"

  echo "Report built successfully: $report_file"
}

default_report_export_dir() {
  if [[ -d "$HOME/Desktop" ]]; then
    echo "$HOME/Desktop"
  else
    echo "$HOME"
  fi
}

load_run_metadata_from_dir() {
  local run_dir="$1"
  local manifest_file="$run_dir/manifest.json"

  if json_file_usable "$manifest_file"; then
    RUN_LOCATION="$(jq -r '.location // "Unknown"' "$manifest_file" 2>/dev/null)"
    RUN_CLIENT_NAME="$(jq -r '.client // "Unknown"' "$manifest_file" 2>/dev/null)"
    RUN_NOTE="$(jq -r '.note // ""' "$manifest_file" 2>/dev/null)"
    SELECTED_INTERFACE="$(jq -r '.selected_interface // "unknown"' "$manifest_file" 2>/dev/null)"
  else
    local dirname_base date_match before_date after_date
    dirname_base="$(basename "$run_dir")"
    date_match="$(printf '%s\n' "$dirname_base" | grep -oE '[0-9]{2}-[0-9]{2}-[0-9]{4}' | head -1 || true)"
    if [[ -n "$date_match" ]]; then
      before_date="${dirname_base%%-${date_match}*}"
      after_date="${dirname_base##*${date_match}}"
      after_date="${after_date#-}"
      [[ "$after_date" == "$dirname_base" ]] && after_date=""
      RUN_LOCATION="$(printf '%s' "$before_date" | tr '-' ' ')"
      RUN_CLIENT_NAME=""
      RUN_NOTE="$(printf '%s' "$after_date" | tr '-' ' ')"
      RUN_DATE_STAMP="$date_match"
    else
      RUN_LOCATION="Unknown"
      RUN_CLIENT_NAME=""
      RUN_NOTE=""
    fi
  fi

  RUN_LOCATION_SLUG="$(sanitize_for_filename "$RUN_LOCATION")"
  RUN_CLIENT_SLUG="$(sanitize_for_filename "$RUN_CLIENT_NAME")"
  RUN_NOTE_SLUG="$(sanitize_for_filename "$RUN_NOTE")"
  RUN_DATE_STAMP="$(date '+%d-%m-%Y')"
}

build_report_for_run_dir() {
  local run_dir="$1"
  local export_dir=""
  local export_choice=""
  local report_name=""
  local previous_output_dir="${RUN_OUTPUT_DIR:-}"
  local previous_report_file="${RUN_REPORT_FILE:-}"
  local previous_debug_log="${RUN_DEBUG_LOG:-}"
  local previous_manifest_file="${RUN_MANIFEST_FILE:-}"
  local previous_location="${RUN_LOCATION:-}"
  local previous_client="${RUN_CLIENT_NAME:-}"
  local previous_note="${RUN_NOTE:-}"
  local previous_location_slug="${RUN_LOCATION_SLUG:-}"
  local previous_client_slug="${RUN_CLIENT_SLUG:-}"
  local previous_note_slug="${RUN_NOTE_SLUG:-}"
  local previous_date_stamp="${RUN_DATE_STAMP:-}"
  local previous_selected_interface="${SELECTED_INTERFACE:-}"

  export_dir="$(default_report_export_dir)"
  report_name="lss-network-tools-report-$(basename "$run_dir")-$(date '+%H-%M').txt"

  while true; do
    echo
    echo "Report $report_name will be saved to $export_dir."
    echo "Would you like it somewhere else?"
    echo "1) Yes"
    echo "2) No"
    echo "3) Cancel"
    echo "00) Back to Main Menu"
    echo
    read -r -p "Choose option: " export_choice

    case "$export_choice" in
      1)
        read -r -p "New directory: " export_dir
        if [[ -z "$export_dir" ]]; then
          echo "No directory provided."
          continue
        fi
        mkdir -p "$export_dir" 2>/dev/null || {
          echo "Unable to create or access directory: $export_dir"
          continue
        }
        break
        ;;
      2)
        mkdir -p "$export_dir" 2>/dev/null || true
        break
        ;;
      3) return 0 ;;
      00) _GOTO_MAIN_MENU=true; return 0 ;;
      *) echo "Invalid selection. Enter 1, 2, 3 or 00." ;;
    esac
  done

  RUN_OUTPUT_DIR="$run_dir"
  RUN_DEBUG_LOG="$run_dir/debug.txt"
  RUN_MANIFEST_FILE="$run_dir/manifest.json"
  load_run_metadata_from_dir "$run_dir"
  RUN_REPORT_FILE="$export_dir/$report_name"

  prompt_prepared_by

  if ! build_report_for_current_run; then
    RUN_OUTPUT_DIR="$previous_output_dir"
    RUN_REPORT_FILE="$previous_report_file"
    RUN_DEBUG_LOG="$previous_debug_log"
    RUN_MANIFEST_FILE="$previous_manifest_file"
    RUN_LOCATION="$previous_location"
    RUN_CLIENT_NAME="$previous_client"
    RUN_NOTE="$previous_note"
    RUN_LOCATION_SLUG="$previous_location_slug"
    RUN_CLIENT_SLUG="$previous_client_slug"
    RUN_NOTE_SLUG="$previous_note_slug"
    RUN_DATE_STAMP="$previous_date_stamp"
    SELECTED_INTERFACE="$previous_selected_interface"
    return 0
  fi

  echo "TXT report:    $RUN_REPORT_FILE"
  if [[ ! -f "$RUN_MANIFEST_FILE" ]]; then
    write_manifest_for_current_run || true
  fi
  generate_pdf_report || true

  RUN_OUTPUT_DIR="$previous_output_dir"
  RUN_REPORT_FILE="$previous_report_file"
  RUN_DEBUG_LOG="$previous_debug_log"
  RUN_MANIFEST_FILE="$previous_manifest_file"
  RUN_LOCATION="$previous_location"
  RUN_CLIENT_NAME="$previous_client"
  RUN_NOTE="$previous_note"
  RUN_LOCATION_SLUG="$previous_location_slug"
  RUN_CLIENT_SLUG="$previous_client_slug"
  RUN_NOTE_SLUG="$previous_note_slug"
  RUN_DATE_STAMP="$previous_date_stamp"
  SELECTED_INTERFACE="$previous_selected_interface"

  echo
  read -r -p "Press Enter to continue..." _
}

list_all_run_dirs() {
  find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
    printf '%s\t%s\n' "$(stat -f '%m' "$dir" 2>/dev/null || stat -c '%Y' "$dir" 2>/dev/null || echo 0)" "$dir"
  done | sort -rn | awk -F'\t' '{print $2}'
}

run_dir_label() {
  local run_dir="$1"
  local manifest_file="$run_dir/manifest.json"
  local m_client m_location m_note generated_at label
  if [[ -f "$manifest_file" ]]; then
    m_client="$(jq -r '.client // ""' "$manifest_file" 2>/dev/null)"
    m_location="$(jq -r '.location // ""' "$manifest_file" 2>/dev/null)"
    m_note="$(jq -r '.note // ""' "$manifest_file" 2>/dev/null)"
    generated_at="$(jq -r '.generated_at // ""' "$manifest_file" 2>/dev/null)"
    if [[ -n "$m_client" ]]; then
      label="${m_client} / ${m_location}"
    else
      label="${m_location}"
    fi
    [[ -n "$m_note" ]] && label="${label} — ${m_note}"
    [[ -n "$generated_at" ]] && label="${label}  [${generated_at}]"
  else
    label="$(basename "$run_dir")"
  fi
  echo "$label"
}

delete_all_previous_runs() {
  local confirmation=""
  local run_count=0

  run_count="$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | awk '{print $1}')"
  if [[ "$run_count" -eq 0 ]]; then
    echo
    echo "No previous runs found in $OUTPUT_DIR."
    return 0
  fi

  echo
  echo "Delete All Previous Runs"
  echo "========================"
  echo "This will permanently remove all run folders under:"
  echo "$OUTPUT_DIR"
  echo
  read -r -p "Are you sure? [y/N]: " confirmation

  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Deletion cancelled."
    return 0
  fi

  find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  find "$OUTPUT_DIR" -maxdepth 1 -type f -name '.debug-session-*.txt' -delete 2>/dev/null || true
  echo "All previous runs have been deleted."
}

task_has_corrupt_json() {
  local task_id="$1"
  local file_path file_glob

  if task_supports_multiple_entries "$task_id"; then
    file_glob="$(task_output_glob "$task_id")"
    while IFS= read -r file_path; do
      [[ -n "$file_path" ]] && ! json_file_usable "$file_path" && return 0
    done < <(find "$(current_output_dir)" -maxdepth 1 -type f -name "$file_glob" 2>/dev/null)
  else
    file_path="$(task_output_path "$task_id")"
    [[ -f "$file_path" ]] && ! json_file_usable "$file_path" && return 0
  fi
  return 1
}

check_continue_run_network() {
  local run_dir="$1"
  local info_file="$run_dir/interface-network-info.json"
  local stored_gateway stored_network

  if ! json_file_usable "$info_file"; then
    return 0
  fi

  stored_gateway="$(jq -r '.gateway // empty' "$info_file" 2>/dev/null)"
  stored_network="$(jq -r '.network // empty' "$info_file" 2>/dev/null)"

  [[ -z "$stored_gateway" && -z "$stored_network" ]] && return 0

  local yellow='\033[1;33m'
  local green='\033[0;32m'
  local reset='\033[0m'

  # Derive current gateway + network from the active default interface
  _derive_current_net() {
    local cur_iface
    if [[ "$OS" == "macos" ]]; then
      cur_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    else
      cur_iface="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    fi
    _cur_iface="${cur_iface:-$SELECTED_INTERFACE}"
    _current_gateway="$(get_gateway_ip "$_cur_iface" 2>/dev/null || true)"
    _current_network="$(get_interface_network_cidr "$_cur_iface" 2>/dev/null || true)"
  }

  local _cur_iface _current_gateway _current_network
  _derive_current_net

  # No mismatch — proceed silently
  if [[ "$_current_gateway" == "$stored_gateway" && "$_current_network" == "$stored_network" ]]; then
    return 0
  fi

  while true; do
    _derive_current_net

    # Mismatch resolved after interface switch — proceed
    if [[ "$_current_gateway" == "$stored_gateway" && "$_current_network" == "$stored_network" ]]; then
      printf "${green}Network matches the original run. Proceeding.${reset}\n"
      SELECTED_INTERFACE="$_cur_iface"
      return 0
    fi

    # Build active interface list with gateway + network for each
    local iface_names=() iface_labels=() iface_gateways=() iface_networks=()
    while IFS= read -r iface; do
      [[ "$iface" == "lo0" || "$iface" == "lo" ]] && continue
      if interface_has_ipv4 "$iface"; then
        local details ip mac gw net description label
        details="$(get_interface_details "$iface")"
        IFS='|' read -r ip _ _ mac gw <<< "$details"
        net="$(get_interface_network_cidr "$iface" 2>/dev/null || true)"
        label="$iface"
        if [[ "$OS" == "macos" ]]; then
          description="$(get_interface_description "$iface" 2>/dev/null || true)"
          [[ -n "$description" ]] && label="$iface ($description)"
        fi
        iface_names+=("$iface")
        iface_labels+=("$label")
        iface_gateways+=("${gw:-unknown}")
        iface_networks+=("${net:-unknown}")
      fi
    done < <(list_interfaces)

    echo
    printf "${yellow}Warning: Current network does not match this run's original network.${reset}\n"
    echo
    printf "  %-12s %-28s %s\n" "" "Original Run" "Current (${_cur_iface})"
    printf "  %-12s %-28s %s\n" "Gateway:" "${stored_gateway:-unknown}" "${_current_gateway:-unknown}"
    printf "  %-12s %-28s %s\n" "Network:" "${stored_network:-unknown}" "${_current_network:-unknown}"
    echo
    if [[ "${#iface_names[@]}" -gt 0 ]]; then
      echo "  Active interfaces:"
      local i
      for i in "${!iface_names[@]}"; do
        local match_note=""
        if [[ "${iface_gateways[$i]}" == "$stored_gateway" && "${iface_networks[$i]}" == "$stored_network" ]]; then
          match_note=" ${green}← matches original run${reset}"
        fi
        printf "  %s) %-30s  GW: %-18s Net: %b%b\n" \
          "$((i+1))" "${iface_labels[$i]}" "${iface_gateways[$i]}" "${iface_networks[$i]}" "$match_note"
      done
      echo
    fi

    echo "Continuing on a different network may produce a misleading report."
    echo
    echo "1) Start a fresh new run on this network"
    echo "2) Continue this run as-is"
    [[ "${#iface_names[@]}" -gt 0 ]] && echo "3) Switch to a different interface"
    echo "00) Back to Main Menu"
    echo "0) Cancel"
    echo
    local choice
    read -r -p "Choose option: " choice
    case "$choice" in
      1) return 2 ;;
      2) return 0 ;;
      3)
        if [[ "${#iface_names[@]}" -eq 0 ]]; then
          echo "No active interfaces available."
          sleep 1
          continue
        fi
        local iface_choice
        read -r -p "Interface number (0 to go back): " iface_choice
        if [[ "$iface_choice" == "0" ]]; then continue; fi
        if [[ "$iface_choice" =~ ^[0-9]+$ ]] && (( iface_choice >= 1 && iface_choice <= ${#iface_names[@]} )); then
          SELECTED_INTERFACE="${iface_names[$((iface_choice - 1))]}"
        else
          echo "Invalid selection."
          sleep 1
        fi
        ;;
      00) _GOTO_MAIN_MENU=true; return 1 ;;
      0) return 1 ;;
      *) echo "Invalid selection."; sleep 1 ;;
    esac
  done
}

continue_run_from_dir() {
  local run_dir="$1"
  local pending_ids=()
  local task_id title

  local previous_output_dir="${RUN_OUTPUT_DIR:-}"
  local previous_report_file="${RUN_REPORT_FILE:-}"
  local previous_debug_log="${RUN_DEBUG_LOG:-}"
  local previous_manifest_file="${RUN_MANIFEST_FILE:-}"
  local previous_location="${RUN_LOCATION:-}"
  local previous_client="${RUN_CLIENT_NAME:-}"
  local previous_note="${RUN_NOTE:-}"
  local previous_location_slug="${RUN_LOCATION_SLUG:-}"
  local previous_client_slug="${RUN_CLIENT_SLUG:-}"
  local previous_note_slug="${RUN_NOTE_SLUG:-}"
  local previous_date_stamp="${RUN_DATE_STAMP:-}"
  local previous_selected_interface="${SELECTED_INTERFACE:-}"
  local previous_session_debug="${SESSION_DEBUG_LOG:-}"

  _restore_continue_state() {
    RUN_OUTPUT_DIR="$previous_output_dir"
    RUN_REPORT_FILE="$previous_report_file"
    RUN_DEBUG_LOG="$previous_debug_log"
    RUN_MANIFEST_FILE="$previous_manifest_file"
    RUN_LOCATION="$previous_location"
    RUN_CLIENT_NAME="$previous_client"
    RUN_NOTE="$previous_note"
    RUN_LOCATION_SLUG="$previous_location_slug"
    RUN_CLIENT_SLUG="$previous_client_slug"
    RUN_NOTE_SLUG="$previous_note_slug"
    RUN_DATE_STAMP="$previous_date_stamp"
    SELECTED_INTERFACE="$previous_selected_interface"
    SESSION_DEBUG_LOG="$previous_session_debug"
  }

  RUN_OUTPUT_DIR="$run_dir"
  RUN_DEBUG_LOG="$run_dir/debug.txt"
  RUN_MANIFEST_FILE="$run_dir/manifest.json"
  SESSION_DEBUG_LOG="$RUN_DEBUG_LOG"
  load_run_metadata_from_dir "$run_dir"

  # Fix 2: network mismatch check
  local net_check
  check_continue_run_network "$run_dir"
  net_check=$?
  if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then
    _restore_continue_state
    return 0
  fi
  if [[ "$net_check" -ne 0 ]]; then
    _restore_continue_state
    return 0
  fi

  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local green='\033[0;32m'
  local red='\033[0;31m'
  local reset='\033[0m'

  while true; do
    # Refresh task status on each loop iteration
    pending_ids=()
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Continue This Run${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    for task_id in $(get_task_ids); do
      title="$(task_title "$task_id")"
      if [[ -n "$(task_json_files "$task_id")" ]] && ! task_has_corrupt_json "$task_id"; then
        printf "  ${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "$task_id" "$title"
      elif task_has_corrupt_json "$task_id"; then
        printf "  ${red}[!]${reset}  ${bold}%2s)${reset}  %s\n" "$task_id" "$title"
        pending_ids+=("$task_id")
      else
        printf "  [ ]  %2s)  %s\n" "$task_id" "$title"
        pending_ids+=("$task_id")
      fi
    done
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    if [[ "${#pending_ids[@]}" -eq 0 ]]; then
      printf "  ${green}All tasks complete for this run.${reset}\n"
      echo
      break
    fi

    local run_input run_filter=()
    read -r -p "  Tasks to run (e.g. 1,3,4 — Enter = run all, 0 = back): " run_input
    if [[ "$run_input" == "0" ]]; then
      _restore_continue_state
      return 0
    fi
    if [[ -n "$run_input" ]]; then
      IFS=', ' read -r -a run_filter <<< "$run_input"
    fi

    local run_ids=()
    for task_id in "${pending_ids[@]}"; do
      if [[ "${#run_filter[@]}" -eq 0 ]]; then
        run_ids+=("$task_id")
      else
        for s in "${run_filter[@]}"; do
          [[ "$s" == "$task_id" ]] && run_ids+=("$task_id") && break
        done
      fi
    done

    if [[ "${#run_ids[@]}" -eq 0 ]]; then
      printf "  No matching pending tasks. Try again.\n"
      echo
      continue
    fi

    local needs_stress_confirm=0
    for task_id in "${run_ids[@]}"; do
      [[ "$task_id" == "10" ]] && needs_stress_confirm=1
    done
    if [[ "$needs_stress_confirm" -eq 1 ]]; then
      if ! confirm_gateway_stress_operation "Continue Run"; then
        _restore_continue_state
        return 0
      fi
    fi

    for task_id in "${run_ids[@]}"; do
      title="$(task_title "$task_id")"
      if ! run_task_with_results_output "$task_id" "$title"; then
        echo "Task $task_id ($title) failed — continuing with remaining tasks."
      fi
    done
    write_manifest_for_current_run || true

    echo
    local _post_choice
    while true; do
      echo "1) Continue with another task"
      echo "2) Save Run and Go Back"
      echo
      read -r -p "Choose: " _post_choice
      case "$_post_choice" in
        1) echo; break ;;
        2)
          _restore_continue_state
          return 0
          ;;
        *) echo "Choose 1 or 2." ;;
      esac
    done
  done

  _restore_continue_state
}

view_results_for_run_dir() {
  local run_dir="$1"
  local previous_output_dir="${RUN_OUTPUT_DIR:-}"
  local available_ids=()
  local task_id title choice_str
  local tmp_out entry_index file_path description
  local cyan='\033[0;36m'
  local yellow='\033[1;33m'
  local bold='\033[1m'
  local green='\033[0;32m'
  local reset='\033[0m'

  RUN_OUTPUT_DIR="$run_dir"
  # Restore RUN_OUTPUT_DIR on any exit from this function, including crashes
  trap 'RUN_OUTPUT_DIR="$previous_output_dir"; trap - RETURN' RETURN

  while true; do
    # Rebuild available list each iteration
    available_ids=()
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Task Results${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    for task_id in $(get_task_ids); do
      title="$(task_title "$task_id")"
      if [[ -n "$(task_json_files "$task_id")" ]]; then
        available_ids+=("$task_id")
        printf "  ${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "$task_id" "$title"
      else
        printf "  [ ]  %2s)  %s\n" "$task_id" "$title"
      fi
    done
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    if [[ "${#available_ids[@]}" -eq 0 ]]; then
      printf "  No task results available for this run.\n"
      echo
      read -r -p "  Press Enter to continue..." _
      return
    fi

    read -r -p "  Enter task numbers to view (e.g. 1,3), 0 to go back, 00 for main menu: " choice_str

    [[ "$choice_str" == "00" ]] && { _GOTO_MAIN_MENU=true; return; }
    [[ "$choice_str" == "0" ]] && return
    [[ -z "${choice_str// /}" ]] && continue

    local -a choice_arr=()
    IFS=',' read -ra choice_arr <<< "$choice_str"

    local selected_ids=()
    local valid=true
    local c
    for c in "${choice_arr[@]+"${choice_arr[@]}"}"; do
      c="${c// /}"
      [[ -z "$c" ]] && continue
      if [[ "$c" =~ ^[0-9]+$ ]] && run_task_exists "$c"; then
        if [[ -n "$(task_json_files "$c")" ]]; then
          selected_ids+=("$c")
        else
          echo "No results for task $c yet."
          valid=false
          break
        fi
      else
        echo "Invalid selection: $c"
        valid=false
        break
      fi
    done
    [[ "$valid" == "false" ]] && continue
    [[ "${#selected_ids[@]}" -eq 0 ]] && continue

    tmp_out="$(mktemp)"
    for task_id in "${selected_ids[@]}"; do
      title="$(task_title "$task_id")"
      description="$(task_description "$task_id")"
      entry_index=0
      while IFS= read -r file_path; do
        [[ -z "$file_path" ]] && continue
        entry_index=$((entry_index + 1))
        {
          printf "${cyan}================================================${reset}\n"
          if task_supports_multiple_entries "$task_id"; then
            printf "${bold}%s: %s — Device %s${reset}\n" "$task_id" "$title" "$entry_index"
          else
            printf "${bold}%s: %s${reset}\n" "$task_id" "$title"
          fi
          printf "${cyan}%s${reset}\n" "Description: $description"
          printf "${cyan}================================================${reset}\n"
        } >> "$tmp_out"
        case "$task_id" in
          1)  render_interface_info_report "$file_path" "$tmp_out" ;;
          2)  render_speed_test_report "$file_path" "$tmp_out" ;;
          3)  render_gateway_report "$file_path" "$tmp_out" ;;
          4)  render_dhcp_report "$file_path" "$tmp_out" ;;
          5)  render_dhcp_response_time_report "$file_path" "$tmp_out" ;;
          6)  render_generic_network_scan_report "$file_path" "$tmp_out" "DNS" ;;
          7)  render_generic_network_scan_report "$file_path" "$tmp_out" "LDAP/AD" ;;
          8)  render_generic_network_scan_report "$file_path" "$tmp_out" "SMB/NFS" ;;
          9)  render_generic_network_scan_report "$file_path" "$tmp_out" "Printer" ;;
          10) render_gateway_stress_report "$file_path" "$tmp_out" ;;
          11) render_vlan_trunk_report "$file_path" "$tmp_out" ;;
          12) render_duplicate_ip_report "$file_path" "$tmp_out" ;;
          13) render_custom_target_port_scan_report "$file_path" "$tmp_out" ;;
          14) render_custom_target_stress_report "$file_path" "$tmp_out" ;;
          15) render_custom_target_identity_report "$file_path" "$tmp_out" ;;
          16) render_custom_target_dns_assessment_report "$file_path" "$tmp_out" ;;
          17) render_wireless_site_survey_report "$file_path" "$tmp_out" ;;
          18) render_unifi_discovery_report "$file_path" "$tmp_out" ;;
          19) render_unifi_adoption_report "$file_path" "$tmp_out" ;;
          20) render_find_device_by_mac_report "$file_path" "$tmp_out" ;;
        esac
        echo >> "$tmp_out"
      done < <(task_json_files "$task_id")
    done

    echo
    cat "$tmp_out"
    rm -f "$tmp_out"
    echo
    read -r -p "Press Enter to continue..." _
  done
}

compare_runs_cli() {
  local run_dir_a="$1"
  local label_a
  label_a="$(run_dir_label "$run_dir_a")"

  local run_dirs=()
  while IFS= read -r dir; do
    [[ "$dir" == "$run_dir_a" ]] && continue
    [[ -n "$dir" ]] && run_dirs+=("$dir")
  done < <(list_all_run_dirs)

  if [[ "${#run_dirs[@]}" -eq 0 ]]; then
    echo "No other runs available to compare with."
    return 0
  fi

  echo
  echo "Compare with which run?"
  echo
  local idx
  for idx in "${!run_dirs[@]}"; do
    printf "  %2d) %s\n" "$(( idx + 1 ))" "$(run_dir_label "${run_dirs[$idx]}")"
  done
  echo "   0) Cancel"
  echo
  local choice
  read -r -p "Choose: " choice
  [[ "$choice" == "0" || -z "$choice" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "${#run_dirs[@]}" ]]; then
    echo "Invalid selection."
    return 0
  fi

  local run_dir_b="${run_dirs[$(( choice - 1 ))]}"
  local label_b
  label_b="$(run_dir_label "$run_dir_b")"

  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  # Terminal width and column sizes — stty size reads actual tty dimensions
  local term_width col_w
  term_width="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  [[ -z "$term_width" || "$term_width" -lt 40 ]] && term_width="${COLUMNS:-0}"
  [[ "$term_width" -lt 40 ]] && term_width="$(tput cols 2>/dev/null || echo 120)"
  [[ "$term_width" -lt 40 ]] && term_width=120
  col_w=$(( (term_width * 2 / 3 - 3) / 2 ))
  local effective_width=$(( col_w * 2 + 3 ))

  # Helper: render a single task's JSON to a plain-text file using existing renderers
  # Optional 4th arg: direct file path override (used for multi-entry device files)
  _cmp_render() {
    local tid="$1" rdir="$2" out="$3" fp_override="${4:-}"
    local prev_dir="${RUN_OUTPUT_DIR:-}"
    local fp
    if [[ -n "$fp_override" && -f "$fp_override" ]]; then
      fp="$fp_override"
    else
      RUN_OUTPUT_DIR="$rdir"
      fp="$(task_output_path "$tid" 2>/dev/null || true)"
      RUN_OUTPUT_DIR="$prev_dir"
    fi
    [[ -z "$fp" || ! -f "$fp" ]] && { printf "(not run)\n" > "$out"; return; }
    case "$tid" in
      1)  render_interface_info_report              "$fp" "$out" ;;
      2)  render_speed_test_report                  "$fp" "$out" ;;
      3)  render_gateway_report                     "$fp" "$out" ;;
      4)  render_dhcp_report                        "$fp" "$out" ;;
      5)  render_dhcp_response_time_report          "$fp" "$out" ;;
      6)  render_generic_network_scan_report        "$fp" "$out" "DNS" ;;
      7)  render_generic_network_scan_report        "$fp" "$out" "LDAP/AD" ;;
      8)  render_generic_network_scan_report        "$fp" "$out" "SMB/NFS" ;;
      9)  render_generic_network_scan_report        "$fp" "$out" "Printer" ;;
      10) render_gateway_stress_report              "$fp" "$out" ;;
      11) render_vlan_trunk_report                  "$fp" "$out" ;;
      12) render_duplicate_ip_report                "$fp" "$out" ;;
      13) render_custom_target_port_scan_report     "$fp" "$out" ;;
      14) render_custom_target_stress_report        "$fp" "$out" ;;
      15) render_custom_target_identity_report      "$fp" "$out" ;;
      16) render_custom_target_dns_assessment_report "$fp" "$out" ;;
      17) render_wireless_site_survey_report        "$fp" "$out" ;;
      18) render_unifi_discovery_report             "$fp" "$out" ;;
      19) render_unifi_adoption_report              "$fp" "$out" ;;
      20) render_find_device_by_mac_report          "$fp" "$out" ;;
      *)  printf "(unsupported)\n" > "$out" ;;
    esac
  }

  clear_screen_if_supported

  # Column header — client / location / date per run
  local client_a location_a date_a client_b location_b date_b
  client_a="$(jq -r '.client // ""'      "$run_dir_a/manifest.json" 2>/dev/null || true)"
  location_a="$(jq -r '.location // ""'  "$run_dir_a/manifest.json" 2>/dev/null || true)"
  date_a="$(jq -r '.generated_at // ""'  "$run_dir_a/manifest.json" 2>/dev/null || true)"
  client_b="$(jq -r '.client // ""'      "$run_dir_b/manifest.json" 2>/dev/null || true)"
  location_b="$(jq -r '.location // ""'  "$run_dir_b/manifest.json" 2>/dev/null || true)"
  date_b="$(jq -r '.generated_at // ""'  "$run_dir_b/manifest.json" 2>/dev/null || true)"
  python3 -c "w=$col_w; print('─'*w + '   ' + '─'*w)"
  printf "${bold}%-${col_w}s   %-${col_w}s${reset}\n" "Client: $client_a" "Client: $client_b"
  printf "${bold}%-${col_w}s   %-${col_w}s${reset}\n" "Location: $location_a" "Location: $location_b"
  printf "${bold}%-${col_w}s   %-${col_w}s${reset}\n" "Date: $date_a" "Date: $date_b"
  python3 -c "w=$col_w; print('─'*w + '   ' + '─'*w)"

  # Helper: render one comparison section given explicit file paths for each side
  _cmp_section() {
    local _tid="$1" _title="$2" _fa="${3:-}" _fb="${4:-}"
    local _header="Task ${_tid} — ${_title}"
    local _hpad=$(( (effective_width - ${#_header}) / 2 ))
    [[ "$_hpad" -lt 0 ]] && _hpad=0
    echo
    python3 -c "print('\033[1;33m' + '='*$effective_width + '\033[0m')"
    echo
    printf "%${_hpad}s${bold}%s${reset}\n" "" "$_header"
    echo
    python3 -c "print('\033[1;33m' + '='*$effective_width + '\033[0m')"
    echo
    printf "%-${col_w}s   %-${col_w}s\n" "Date: $date_a" "Date: $date_b"
    echo
    python3 -c "print('\033[0;36m' + '='*$col_w + '   ' + '='*$col_w + '\033[0m')"
    echo
    local _ta _tb
    _ta="$(mktemp /tmp/lss-cmp-XXXXXX)"
    _tb="$(mktemp /tmp/lss-cmp-XXXXXX)"
    _cmp_render "$_tid" "$run_dir_a" "$_ta" "$_fa"
    _cmp_render "$_tid" "$run_dir_b" "$_tb" "$_fb"
    python3 - "$_ta" "$_tb" "$col_w" << 'PYEOF'
import sys, textwrap
fa, fb, col_w = sys.argv[1], sys.argv[2], int(sys.argv[3])
def wrap_line(line, w):
    if len(line) <= w:
        return [line]
    indent = ' ' * (len(line) - len(line.lstrip()))
    chunks = textwrap.wrap(line, w, subsequent_indent=indent,
                           break_long_words=True, break_on_hyphens=False)
    return chunks if chunks else [line[:w]]
def read_lines(path):
    with open(path) as f:
        return [l.rstrip('\n') for l in f]
left_raw  = read_lines(fa)
right_raw = read_lines(fb)
n = max(len(left_raw), len(right_raw), 1)
for i in range(n):
    lw = wrap_line(left_raw[i]  if i < len(left_raw)  else '', col_w)
    rw = wrap_line(right_raw[i] if i < len(right_raw) else '', col_w)
    for j in range(max(len(lw), len(rw))):
        l = lw[j] if j < len(lw) else ''
        r = rw[j] if j < len(rw) else ''
        print(f'{l:<{col_w}}   {r}')
PYEOF
    rm -f "$_ta" "$_tb"
    echo
    python3 -c "print('\033[0;36m' + '='*$col_w + '   ' + '='*$col_w + '\033[0m')"
    echo
    python3 -c "print('\033[1;33m' + '='*$effective_width + '\033[0m')"
  }

  local prev_dir="${RUN_OUTPUT_DIR:-}"
  for task_id in $(get_task_ids); do
    local title; title="$(task_title "$task_id")"

    if task_supports_multiple_entries "$task_id"; then
      # Collect actual device files from both runs
      local files_a=() files_b=()
      RUN_OUTPUT_DIR="$run_dir_a"
      while IFS= read -r f; do [[ -n "$f" ]] && files_a+=("$f"); done < <(task_json_files "$task_id" 2>/dev/null || true)
      RUN_OUTPUT_DIR="$run_dir_b"
      while IFS= read -r f; do [[ -n "$f" ]] && files_b+=("$f"); done < <(task_json_files "$task_id" 2>/dev/null || true)
      RUN_OUTPUT_DIR="$prev_dir"
      local n_dev=$(( ${#files_a[@]} > ${#files_b[@]} ? ${#files_a[@]} : ${#files_b[@]} ))
      [[ "$n_dev" -eq 0 ]] && continue
      for (( dev_idx=0; dev_idx<n_dev; dev_idx++ )); do
        local fa_dev="" fb_dev=""
        [[ $dev_idx -lt ${#files_a[@]} ]] && fa_dev="${files_a[$dev_idx]}"
        [[ $dev_idx -lt ${#files_b[@]} ]] && fb_dev="${files_b[$dev_idx]}"
        _cmp_section "$task_id" "$title (device $(( dev_idx + 1 )))" "$fa_dev" "$fb_dev"
      done
    else
      RUN_OUTPUT_DIR="$run_dir_a"; local fa; fa="$(task_output_path "$task_id" 2>/dev/null || true)"
      RUN_OUTPUT_DIR="$run_dir_b"; local fb; fb="$(task_output_path "$task_id" 2>/dev/null || true)"
      RUN_OUTPUT_DIR="$prev_dir"
      [[ ! -f "$fa" && ! -f "$fb" ]] && continue
      _cmp_section "$task_id" "$title" "$fa" "$fb"
    fi
  done

  echo
  read -r -p "Press Enter to continue..." _
}

build_compare_report_for_run_dir() {
  local run_dir_a="$1"

  local run_dirs=()
  while IFS= read -r dir; do
    [[ "$dir" == "$run_dir_a" ]] && continue
    [[ -n "$dir" ]] && run_dirs+=("$dir")
  done < <(list_all_run_dirs)

  if [[ "${#run_dirs[@]}" -eq 0 ]]; then
    echo "No other runs available to compare with."
    return 0
  fi

  echo
  echo "Compare with which run?"
  echo
  local idx
  for idx in "${!run_dirs[@]}"; do
    printf "  %2d) %s\n" "$(( idx + 1 ))" "$(run_dir_label "${run_dirs[$idx]}")"
  done
  echo "   0) Cancel"
  echo
  local choice
  read -r -p "Choose: " choice
  [[ "$choice" == "0" || -z "$choice" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "${#run_dirs[@]}" ]]; then
    echo "Invalid selection."
    return 0
  fi

  local run_dir_b="${run_dirs[$(( choice - 1 ))]}"

  local export_dir
  export_dir="$(default_report_export_dir)"
  local pdf_name="lss-compare-$(date '+%d-%m-%Y-%H-%M').pdf"

  while true; do
    echo
    echo "PDF will be saved to $export_dir/$pdf_name"
    echo "Would you like it somewhere else?"
    echo "1) Yes"
    echo "2) No"
    echo "3) Cancel"
    echo
    local export_choice
    read -r -p "Choose option: " export_choice
    case "$export_choice" in
      1)
        read -r -p "New directory: " export_dir
        if [[ -z "$export_dir" ]]; then
          echo "No directory provided."
          continue
        fi
        mkdir -p "$export_dir" 2>/dev/null || { echo "Unable to create directory: $export_dir"; continue; }
        break
        ;;
      2) mkdir -p "$export_dir" 2>/dev/null || true; break ;;
      3) return 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done

  local pdf_path="$export_dir/$pdf_name"
  local py_script="$APP_ROOT/generate_pdf_compare_report.py"

  if [[ ! -f "$py_script" ]]; then
    echo "Compare PDF generator not found: $py_script"
    return 0
  fi
  if ! python3 -c "import fpdf" 2>/dev/null; then
    echo "PDF generation skipped: fpdf2 not installed (pip3 install fpdf2)"
    return 0
  fi

  echo "Generating comparison PDF..."
  local pdf_err
  pdf_err="$(python3 "$py_script" "$run_dir_a" "$run_dir_b" "$pdf_path" "$APP_ROOT" 2>&1 >/dev/null || true)"
  if [[ -f "$pdf_path" ]]; then
    echo "PDF saved: $pdf_path"
  else
    echo "PDF generation failed${pdf_err:+: $pdf_err}"
  fi
}

run_action_submenu() {
  local run_dir="$1"
  local label=""
  local choice=""
  local confirmation=""
  local txt_file=""
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local red='\033[0;31m'
  local bold='\033[1m'
  local reset='\033[0m'

  label="$(run_dir_label "$run_dir")"

  while true; do
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}%s${reset}\n" "$label"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    printf "  ${bold}1)${reset}  Build A Report\n"
    printf "  ${red}${bold}2)${reset}  Delete This Run\n"
    printf "  ${bold}3)${reset}  View Results\n"
    printf "  ${bold}4)${reset}  Continue This Run\n"
    printf "  ${bold}5)${reset}  Compare This Run\n"
    printf "  ${bold}6)${reset}  Build Compared Report\n"
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold} 00)${reset}  Back to Main Menu\n"
    printf "  ${bold}  0)${reset}  Back\n"
    echo
    read -r -p "  Choose option: " choice
    case "$choice" in
      0) return 0 ;;
      00) _GOTO_MAIN_MENU=true; return 0 ;;
      1)
        build_report_for_run_dir "$run_dir" || true
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      2)
        echo
        read -r -p "Delete '$(basename "$run_dir")'? [y/N]: " confirmation
        if [[ "$confirmation" =~ ^[Yy]$ ]]; then
          rm -rf "$run_dir"
          echo "Run deleted."
          return 0
        else
          echo "Deletion cancelled."
        fi
        ;;
      3)
        view_results_for_run_dir "$run_dir" || true
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      4)
        continue_run_from_dir "$run_dir" || true
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      5)
        compare_runs_cli "$run_dir" || true
        ;;
      6)
        build_compare_report_for_run_dir "$run_dir" || true
        ;;
      *) echo "Invalid selection. Try again."; sleep 1 ;;
    esac
  done
}

manage_previous_runs() {
  local run_dirs=()
  local run_dir=""
  local idx choice label
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local red='\033[0;31m'
  local bold='\033[1m'
  local reset='\033[0m'

  while true; do
    clear_screen_if_supported
    run_dirs=()
    while IFS= read -r run_dir; do
      [[ -n "$run_dir" ]] && run_dirs+=("$run_dir")
    done < <(list_all_run_dirs)

    echo
    printf "  ${yellow}${bold}Manage Previous Runs${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    if [[ "${#run_dirs[@]}" -eq 0 ]]; then
      printf "  No previous runs found.\n"
      echo
      read -r -p "  Press Enter to return to the main menu..." _
      return 0
    fi

    idx=1
    for run_dir in "${run_dirs[@]}"; do
      label="$(run_dir_label "$run_dir")"
      printf "  ${bold}%2d)${reset}  %s\n" "$idx" "$label"
      idx=$((idx + 1))
    done
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${red}${bold}000)${reset}  Delete All Runs\n"
    printf "  ${bold}  0)${reset}  Back To Main Menu\n"
    echo
    read -r -p "  Choose run: " choice

    case "$choice" in
      0) return 0 ;;
      000)
        delete_all_previous_runs || true
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#run_dirs[@]} )); then
          run_dir="${run_dirs[$((choice - 1))]}"
          run_action_submenu "$run_dir" || true
          [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        else
          echo "Invalid selection. Try again."
          sleep 1
        fi
        ;;
    esac
  done
}

startup_menu() {
  local choice=""
  local yellow='\033[1;33m'
  local green='\033[0;32m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'
  while true; do
    _GOTO_MAIN_MENU=false
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}LSS Network Tools${reset}  ${yellow}%s${reset}\n" "$APP_VERSION"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    # Show update banner if a newer version was found at startup
    if [[ -n "${_LSS_UPDATE_BANNER:-}" ]]; then
      printf "  ${green}[UPDATE AVAILABLE]${reset} %s is available (you have %s) — select option 3 to update\n" "${_LSS_UPDATE_BANNER}" "${APP_VERSION}"
      echo
    fi
    printf "  ${bold}1)${reset}  Run LSS Network Tools\n"
    printf "  ${bold}2)${reset}  Manage Previous Runs\n"
    printf "  ${bold}3)${reset}  Check For Updates\n"
    printf "  ${bold}4)${reset}  About & Install Health\n"
    printf "  ${bold}5)${reset}  Exit\n"
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    read -r -p "  Choose option: " choice

    case "$choice" in
      1) return 0 ;;
      2)
        clear_screen_if_supported
        manage_previous_runs || true
        ;;
      3)
        clear_screen_if_supported
        check_for_updates
        echo
        read -r -p "Press Enter to return to the startup menu..." _
        ;;
      4)
        clear_screen_if_supported
        about_and_health
        echo
        read -r -p "Press Enter to return to the startup menu..." _
        ;;
      5) exit 0 ;;
      *)
        echo "Invalid selection. Try again."
        sleep 1
        ;;
    esac
  done
}

append_findings_summary() {
  local report_file="$1"
  local findings_json="[]"
  local findings_file="$RUN_OUTPUT_DIR/findings.json"
  local file status count gateway target_ip software_hint indicator
  local open_port_count open_ports_label
  local severity title detail source

  for task_id in $(get_audit_task_ids); do
    file="$(task_output_path "$task_id" 2>/dev/null || true)"
    [[ -z "$file" ]] && continue
    if ! json_file_usable "$file"; then
      continue
    fi
    status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
    label="$(task_title "$task_id")"
    if [[ "$status" == "failed" ]]; then
      title="${label} failed"
      detail="$(jq -r '.error.message // "The scan reported a failure."' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "warning" "$title" "$detail" "$(basename "$file")")"
    elif [[ "$status" == "completed_with_warnings" ]]; then
      title="${label} completed with warnings"
      detail="$(jq -r '(.warnings // []) | if length > 0 then join(" ") else "The scan completed with warnings." end' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "info" "$title" "$detail" "$(basename "$file")")"
    fi
  done

  file="$(task_output_path 3 2>/dev/null || true)"
  if json_file_usable "$file"; then
    local gw3_status gw3_ip
    gw3_status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
    if [[ "$gw3_status" == "skipped" ]]; then
      gw3_ip="$(jq -r '.gateway_ip // "unknown"' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "warning" "No local firewall detected — LAN directly exposed to carrier infrastructure" "The default gateway IP ($gw3_ip) is publicly routable, indicating this network is connected directly to enterprise or carrier infrastructure (such as a Juniper or Cisco core router) without a dedicated local firewall or NAT boundary. Gateway port scanning and stress testing were skipped. Users on this LAN share address space and trust level with upstream provider infrastructure, and have no local traffic filtering or segmentation." "gateway-scan.json")"
    fi
    open_port_count="$(jq -r '(.open_ports // []) | length' "$file" 2>/dev/null)"
    if [[ "$open_port_count" =~ ^[0-9]+$ ]] && (( open_port_count >= 3 )); then
      gateway="$(jq -r '.gateway_ip // "unknown"' "$file" 2>/dev/null)"
      open_ports_label="$(jq -r '(.open_ports // []) | map(
        . as $p |
        if $p == 21 then "21/FTP"
        elif $p == 22 then "22/SSH"
        elif $p == 23 then "23/Telnet"
        elif $p == 25 then "25/SMTP"
        elif $p == 53 then "53/DNS"
        elif $p == 80 then "80/HTTP"
        elif $p == 443 then "443/HTTPS"
        elif $p == 3389 then "3389/RDP"
        elif $p == 8007 then "8007/HTTP-Alt"
        elif $p == 8080 then "8080/HTTP-Alt"
        elif $p == 8443 then "8443/HTTPS-Alt"
        elif $p == 10050 then "10050/Zabbix-Agent"
        elif $p == 10051 then "10051/Zabbix-Server"
        else (. | tostring)
        end
      ) | join(", ")' "$file" 2>/dev/null)"
      local gw_notes=""
      if jq -e '(.open_ports // []) | any(. == 80)' "$file" >/dev/null 2>&1; then
        gw_notes="${gw_notes} Unencrypted HTTP (port 80) is accessible — confirm HTTPS-only management is enforced."
      fi
      if jq -e '(.open_ports // []) | any(. == 10050)' "$file" >/dev/null 2>&1; then
        gw_notes="${gw_notes} Port 10050 (Zabbix Agent) is exposed — restrict access to the Zabbix server IP only."
      fi
      if jq -e '(.open_ports // []) | any(. == 23)' "$file" >/dev/null 2>&1; then
        gw_notes="${gw_notes} Telnet (port 23) is open — this is unencrypted and should be disabled."
      fi
      local gw_severity="info"
      (( open_port_count >= 8 )) && gw_severity="high"
      (( open_port_count >= 5 && open_port_count < 8 )) && gw_severity="warning"
      local gw_title="Gateway exposes open ports"
      (( open_port_count >= 8 )) && gw_title="Gateway exposes many open ports"
      (( open_port_count >= 5 && open_port_count < 8 )) && gw_title="Gateway exposes multiple open ports"
      findings_json="$(append_finding_record "$findings_json" "$gw_severity" "$gw_title" "Gateway $gateway has $open_port_count open TCP port(s): ${open_ports_label}.${gw_notes}" "gateway-scan.json")"
    fi
  fi

  file="$(task_output_path 4 2>/dev/null || true)"
  if json_file_usable "$file"; then
    if [[ "$(jq -r '.rogue_dhcp_suspected // false' "$file" 2>/dev/null)" == "true" ]]; then
      detail="$(jq -r 'if (.suspected_rogue_servers // []) | length > 0 then "Suspected rogue DHCP responders: " + ((.suspected_rogue_servers // []) | join(", ")) else "A possible rogue DHCP responder was observed." end' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "high" "Possible rogue DHCP responder observed" "$detail" "dhcp-scan.json")"
    fi
    if [[ "$(jq -r '.dhcp_responders_observed // 0' "$file" 2>/dev/null)" == "0" ]]; then
      findings_json="$(append_finding_record "$findings_json" "warning" "No DHCP responders were observed" "DHCP discovery completed without observing any responder. This may still be normal in some environments, but it should be verified." "dhcp-scan.json")"
    fi
  fi

  file="$(task_output_path 5 2>/dev/null || true)"
  if json_file_usable "$file"; then
    local dhcp_avg_ms dhcp_loss
    dhcp_avg_ms="$(jq -r '.avg_ms // empty' "$file" 2>/dev/null)"
    dhcp_loss="$(jq -r '.packet_loss_percent // 0' "$file" 2>/dev/null)"
    if [[ "$dhcp_loss" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($dhcp_loss > 0)}"; then
      findings_json="$(append_finding_record "$findings_json" "high" "DHCP server did not respond to all probes" "Packet loss observed during DHCP response time test: ${dhcp_loss}% of Discover packets received no Offer." "dhcp-response-time.json")"
    fi
    if [[ -n "$dhcp_avg_ms" ]] && awk "BEGIN{exit !($dhcp_avg_ms > 500)}"; then
      findings_json="$(append_finding_record "$findings_json" "high" "DHCP response time is critically slow" "Average DHCP Offer latency was ${dhcp_avg_ms} ms. This will cause delays or failures during device boot and network reconnection." "dhcp-response-time.json")"
    elif [[ -n "$dhcp_avg_ms" ]] && awk "BEGIN{exit !($dhcp_avg_ms > 200)}"; then
      findings_json="$(append_finding_record "$findings_json" "warning" "DHCP response time is elevated" "Average DHCP Offer latency was ${dhcp_avg_ms} ms. Healthy DHCP servers typically respond within 50 ms." "dhcp-response-time.json")"
    fi
  fi

  file="$(task_output_path 10 2>/dev/null || true)"
  if json_file_usable "$file"; then
    for indicator in high_jitter latency_under_load packet_loss slow_recovery; do
      if [[ "$(jq -r ".indicators.${indicator} // false" "$file" 2>/dev/null)" == "true" ]]; then
        case "$indicator" in
          high_jitter)
            severity="warning"
            title="Gateway stress test detected high jitter"
            detail="The gateway showed elevated jitter under the stress profile."
            ;;
          latency_under_load)
            severity="high"
            title="Gateway latency increased heavily under load"
            detail="The gateway showed significantly higher latency during the sustained load stage."
            ;;
          packet_loss)
            severity="high"
            title="Gateway stress test detected packet loss"
            detail="Packet loss was observed during one or more gateway stress stages."
            ;;
          slow_recovery)
            severity="warning"
            title="Gateway recovered slowly after stress"
            detail="The gateway did not return to baseline latency quickly after the stress stages."
            ;;
        esac
        findings_json="$(append_finding_record "$findings_json" "$severity" "$title" "$detail" "gateway-stress-test.json")"
      fi
    done
  fi

  file="$(task_output_path 6 2>/dev/null || true)"
  if json_file_usable "$file"; then
    count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      findings_json="$(append_finding_record "$findings_json" "info" "DNS services were detected on the local network" "The DNS scan identified $count host(s) with DNS-related ports open." "dns-scan.json")"
    fi
  fi

  file="$(task_output_path 7 2>/dev/null || true)"
  if json_file_usable "$file"; then
    count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      findings_json="$(append_finding_record "$findings_json" "info" "Active Directory / LDAP services detected on the local network" "The LDAP/AD scan identified $count host(s) with directory service ports open (Kerberos, LDAP, LDAPS, or Global Catalog). Confirm these are expected domain controllers for this site." "ldap-ad-scan.json")"
    fi
  fi

  file="$(task_output_path 11 2>/dev/null || true)"
  if json_file_usable "$file"; then
    if [[ "$(jq -r '.indicators.trunk_port_suspected // false' "$file" 2>/dev/null)" == "true" ]]; then
      local vlan_ids_label
      vlan_ids_label="$(jq -r '(.observed_vlan_ids // []) | if length > 0 then map(tostring) | join(", ") else "unknown" end' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "warning" "Trunk port suspected — 802.1Q tagged frames observed" "Tagged frames were captured on the selected interface. Observed VLAN IDs: ${vlan_ids_label}. This port may be configured as a trunk rather than an access port." "vlan-trunk-scan.json")"
    fi
    if [[ "$(jq -r '.indicators.cdp_exposed // false' "$file" 2>/dev/null)" == "true" ]]; then
      local cdp_count lldp_count neighbour_label
      cdp_count="$(jq -r '(.cdp_neighbours // []) | length' "$file" 2>/dev/null)"
      lldp_count="$(jq -r '(.lldp_neighbours // []) | length' "$file" 2>/dev/null)"
      neighbour_label=""
      if [[ "$cdp_count" -gt 0 ]]; then
        neighbour_label="$(jq -r '(.cdp_neighbours // []) | map(.device_id) | join(", ")' "$file" 2>/dev/null)"
      elif [[ "$lldp_count" -gt 0 ]]; then
        neighbour_label="$(jq -r '(.lldp_neighbours // []) | map(.system_name) | join(", ")' "$file" 2>/dev/null)"
      fi
      findings_json="$(append_finding_record "$findings_json" "warning" "CDP/LLDP neighbour frames received — switch identity disclosed" "Neighbour discovery frames were captured, revealing upstream switch details. Neighbours: ${neighbour_label:-unknown}. CDP/LLDP should be disabled on access ports in security-sensitive environments." "vlan-trunk-scan.json")"
    fi
    if [[ "$(jq -r '.indicators.multiple_vlans_visible // false' "$file" 2>/dev/null)" == "true" ]]; then
      local multi_vlan_ids
      multi_vlan_ids="$(jq -r '(.observed_vlan_ids // []) | map(tostring) | join(", ")' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "info" "Multiple VLAN IDs visible on the selected interface" "Tagged frames carrying more than one VLAN ID were observed: ${multi_vlan_ids}. This may indicate a misconfigured trunk or inter-VLAN routing on the same port." "vlan-trunk-scan.json")"
    fi
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if ! json_file_usable "$file"; then
      continue
    fi
    if [[ "$(jq -r '.dns_service_working // false' "$file" 2>/dev/null)" == "true" ]]; then
      target_ip="$(jq -r '.target_ip // "unknown"' "$file" 2>/dev/null)"
      software_hint="$(jq -r '.software_hint // "unknown"' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "warning" "Custom target is operating as a DNS resolver" "Target $target_ip answered DNS queries successfully. Software hint: $software_hint." "$(basename "$file")")"
    fi
  done < <(task_json_files 16)

  file="$(task_output_path 12 2>/dev/null || true)"
  if json_file_usable "$file"; then
    local dup_count dup_ips_label
    dup_count="$(jq -r '.duplicate_count // 0' "$file" 2>/dev/null)"
    if [[ "$dup_count" =~ ^[0-9]+$ ]] && (( dup_count > 0 )); then
      dup_ips_label="$(jq -r '[.duplicates[]? | .ip + " (" + (.macs | join(", ")) + ")"] | join("; ")' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "high" "Duplicate IP addresses detected on the network" "$dup_count IP address(es) responded to ARP from more than one MAC: ${dup_ips_label}. This indicates an IP conflict or possible ARP spoofing." "duplicate-ip-scan.json")"
    fi
  fi

  file="$(task_output_path 8 2>/dev/null || true)"
  if json_file_usable "$file"; then
    local nfs_hosts nfs_count
    nfs_hosts="$(jq -r '[.servers[]? | select(.detected_services[]? | test("^nfs$")) | .ip] | join(", ")' "$file" 2>/dev/null)"
    nfs_count="$(jq -r '[.servers[]? | select(.detected_services[]? | test("^nfs$"))] | length' "$file" 2>/dev/null)"
    if [[ "$nfs_count" =~ ^[0-9]+$ ]] && (( nfs_count > 0 )); then
      findings_json="$(append_finding_record "$findings_json" "warning" "NFS shares exposed on the network" "${nfs_count} host(s) have NFS (port 2049) accessible: ${nfs_hosts}. NFS without strict host-based access controls allows any network host to attempt to mount available shares." "smb-nfs-scan.json")"
    fi
    local smb_no_sign_hosts smb_no_sign_count
    smb_no_sign_hosts="$(jq -r '[.servers[]? | select((.open_ports[]? | . == 445) and .smb_signing_required == false) | .ip] | join(", ")' "$file" 2>/dev/null)"
    smb_no_sign_count="$(jq -r '[.servers[]? | select((.open_ports[]? | . == 445) and .smb_signing_required == false)] | length' "$file" 2>/dev/null)"
    if [[ "$smb_no_sign_count" =~ ^[0-9]+$ ]] && (( smb_no_sign_count > 0 )); then
      findings_json="$(append_finding_record "$findings_json" "warning" "SMB signing not required on one or more hosts" "${smb_no_sign_count} host(s) with SMB (port 445) do not enforce signing: ${smb_no_sign_hosts}. Without mandatory signing, SMB traffic is vulnerable to relay and man-in-the-middle attacks." "smb-nfs-scan.json")"
    fi
  fi

  file="$(task_output_path 9 2>/dev/null || true)"
  if json_file_usable "$file"; then
    local printer_count jetdirect_count jetdirect_hosts all_printer_ips
    printer_count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"
    if [[ "$printer_count" =~ ^[0-9]+$ ]] && (( printer_count > 0 )); then
      jetdirect_count="$(jq -r '[.servers[]? | select(.open_ports[]? | . == 9100)] | length' "$file" 2>/dev/null)"
      jetdirect_hosts="$(jq -r '[.servers[]? | select(.open_ports[]? | . == 9100) | .ip] | join(", ")' "$file" 2>/dev/null)"
      all_printer_ips="$(jq -r '[.servers[]?.ip] | join(", ")' "$file" 2>/dev/null)"
      if [[ "$jetdirect_count" =~ ^[0-9]+$ ]] && (( jetdirect_count > 0 )); then
        findings_json="$(append_finding_record "$findings_json" "warning" "Printers with unauthenticated JetDirect port exposed" "${jetdirect_count} of ${printer_count} printer(s) have port 9100 (JetDirect/raw printing) open: ${jetdirect_hosts}. This port accepts print jobs without authentication and can be used to retrieve previously printed documents on some models." "print-server-scan.json")"
      else
        findings_json="$(append_finding_record "$findings_json" "info" "Printers detected on the network" "${printer_count} printer(s) detected: ${all_printer_ips}." "print-server-scan.json")"
      fi
    fi
  fi

  jq -n --argjson findings "$findings_json" '{findings: $findings}' > "$findings_file"
  validate_json_file "$findings_file"

  {
    echo "================================================"
    echo "Key Findings"
    echo "================================================"
    if [[ "$(jq -r '(.findings // []) | length' "$findings_file" 2>/dev/null)" == "0" ]]; then
      echo "No notable findings were generated from the current scan set."
    else
      jq -r '.findings[] | "- [" + (.severity | ascii_upcase) + "] " + .title + " - " + .detail' "$findings_file"
    fi
    echo
  } >> "$report_file"
}

append_remediation_hints() {
  local report_file="$1"
  local findings_file="$RUN_OUTPUT_DIR/findings.json"
  local remediation_json="[]"

  if ! json_file_usable "$findings_file"; then
    return 0
  fi

  if jq -e '.findings[]? | select(.source == "gateway-scan.json" and (.title | test("No local firewall detected"; "i")))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Install a dedicated local firewall" "A dedicated local firewall should be installed between the ISP uplink and the LAN. Devices such as a Juniper or Cisco core router are designed for carrier or enterprise backbone routing — not for local LAN protection. Without a local firewall the site has no NAT boundary, no application-layer filtering, no intrusion detection, and no segmentation between LAN users and upstream provider infrastructure. Recommended options include Fortinet FortiGate, Sophos XGS, Cisco Meraki MX, pfSense, or an equivalent. The firewall should provide: NAT (private RFC 1918 LAN addressing), stateful inspection, DNS and DHCP services for the LAN, and a clear management boundary between the ISP handoff and the internal network." "gateway-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "gateway-scan.json" and (.title | test("Gateway exposes"; "i")))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Review gateway exposure" "Check whether all exposed gateway services are expected on the LAN side. Pay particular attention to management interfaces and monitoring ports." "gateway-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "gateway-stress-test.json")' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Investigate gateway resilience" "Review firewall CPU load, IDS/IPS, traffic shaping, NIC offload settings, and hardware age if the stress profile showed packet loss, high jitter, or degraded recovery." "gateway-stress-test.json")"
  fi

  if jq -e '.findings[]? | select(.source == "dhcp-scan.json" and (.title | test("rogue DHCP|No DHCP responders"; "i")))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Verify DHCP behavior" "Check switch VLAN assignment, DHCP relay or helper configuration, and whether the observed DHCP responders match the client’s expected infrastructure." "dhcp-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "dns-scan.json" or (.title | test("DNS resolver"; "i")))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Review DNS roles" "Confirm whether the detected DNS-capable hosts are expected to serve DNS, and inspect their forwarding or recursion configuration if they appear unusual." "dns")"
  fi

  if jq -e '.findings[]? | select(.source == "ldap-ad-scan.json" and (.title | test("completed with warnings"; "i") | not))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Validate directory expectations" "If Active Directory services are expected on this site, confirm the selected subnet and check whether LDAP, Kerberos, or Global Catalog ports are being filtered or hosted elsewhere." "ldap-ad-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "smb-nfs-scan.json" and (.title | test("NFS"; "i")) and (.title | test("completed with warnings"; "i") | not))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Restrict NFS access" "Configure /etc/exports to limit NFS mounts to specific authorised client IPs or subnets. Consider whether NFS is still required or can be replaced with a protocol that supports authentication and encryption (e.g. SMB with signing, or SFTP)." "smb-nfs-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "smb-nfs-scan.json" and (.title | test("SMB signing"; "i")))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Enable mandatory SMB signing" "On Windows Server: enable 'Microsoft network server: Digitally sign communications (always)' via Group Policy (Computer Configuration > Windows Settings > Security Settings > Local Policies > Security Options). On Linux/Samba: set 'server signing = mandatory' in smb.conf and restart the service. Mandatory SMB signing prevents relay attacks where an attacker intercepts and forwards authentication exchanges." "smb-nfs-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "print-server-scan.json" and (.title | test("completed with warnings"; "i") | not))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Secure printer access" "Disable raw printing (port 9100/JetDirect) on printers where it is not required, or restrict it to the print server IP only. Enable authentication on printer management interfaces and keep firmware up to date." "print-server-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "vlan-trunk-scan.json" and (.title | test("completed with warnings"; "i") | not))' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Review VLAN and trunk configuration" "If tagged frames or CDP/LLDP neighbours were observed, confirm with the client whether this port should be an access port. Disable CDP and LLDP on access ports where not required. If multiple VLANs are visible, verify VLAN segmentation is enforced at the switch level and review inter-VLAN routing policy." "vlan-trunk-scan.json")"
  fi

  {
    echo "================================================"
    echo "Remediation Hints"
    echo "================================================"
    if [[ "$(jq -r 'length' <<< "$remediation_json" 2>/dev/null)" == "0" ]]; then
      echo "No remediation hints were generated from the current findings."
    else
      jq -r '.[] | "- " + .title + " - " + .detail' <<< "$remediation_json"
    fi
    echo
  } >> "$report_file"

  jq -n --argjson hints "$remediation_json" '{hints: $hints}' \
    > "$RUN_OUTPUT_DIR/remediation.json" 2>/dev/null || true
}

write_manifest_for_current_run() {
  local manifest_file="$RUN_MANIFEST_FILE"
  local timestamp
  local selected_interface_value="${SELECTED_INTERFACE:-unknown}"
  local task_entries="[]"
  local raw_entries="[]"
  local task_id title json_name raw_prefix
  local task_files_json="[]"
  local relative_path
  local artifact_type

  if [[ -z "$RUN_OUTPUT_DIR" ]]; then
    return 1
  fi

  timestamp="$(date '+%d-%m-%Y %H:%M')"

  for task_id in $(get_task_ids); do
    title="$(task_title "$task_id")"
    json_name="$(task_output_file "$task_id")"
    [[ -z "$json_name" ]] && continue
    raw_prefix="$(task_raw_prefix "$task_id" 2>/dev/null || true)"
    task_files_json="$(task_json_files "$task_id" | while IFS= read -r path; do
      [[ -n "$path" ]] && basename "$path"
    done | jq -R . | jq -s .)"
    [[ -z "$task_files_json" ]] && task_files_json="[]"

    task_entries="$(jq -cn \
      --argjson existing "$task_entries" \
      --arg task_id "$task_id" \
      --arg title "$title" \
      --arg json_file "$json_name" \
      --argjson json_present "$(if [[ "$task_files_json" != "[]" ]]; then echo true; else echo false; fi)" \
      --argjson json_files "$task_files_json" \
      --arg raw_prefix "$(basename "$raw_prefix")" \
      '$existing + [{
        task_id: ($task_id | tonumber),
        title: $title,
        json_file: $json_file,
        json_present: $json_present,
        json_files: $json_files,
        raw_prefix: $raw_prefix
      }]' )"
  done

  while IFS= read -r artifact_path; do
    [[ -z "$artifact_path" ]] && continue
    relative_path="${artifact_path#$RUN_OUTPUT_DIR/}"

    case "$relative_path" in
      *.json)
        artifact_type="json"
        ;;
      *.txt)
        artifact_type="text"
        ;;
      *)
        artifact_type="other"
        ;;
    esac

    raw_entries="$(jq -cn \
      --argjson existing "$raw_entries" \
      --arg path "$relative_path" \
      --arg type "$artifact_type" \
      '$existing + [{
        path: $path,
        type: $type
      }]' )"
  done < <(find "$RUN_OUTPUT_DIR" -type f ! -name 'manifest.json' | sort)

  jq -n \
    --arg generated_at "$timestamp" \
    --arg location "$RUN_LOCATION" \
    --arg client "$RUN_CLIENT_NAME" \
    --arg note "${RUN_NOTE:-}" \
    --arg prepared_by "${RUN_PREPARED_BY:-}" \
    --arg run_directory "$(basename "$RUN_OUTPUT_DIR")" \
    --arg selected_interface "$selected_interface_value" \
    --arg report_file "$(basename "$RUN_REPORT_FILE")" \
    --arg debug_file "$(basename "$RUN_DEBUG_LOG")" \
    --argjson tasks "$task_entries" \
    --argjson artifacts "$raw_entries" \
    '{
      generated_at: $generated_at,
      client: $client,
      location: $location,
      note: $note,
      prepared_by: $prepared_by,
      run_directory: $run_directory,
      selected_interface: $selected_interface,
      report_file: $report_file,
      debug_file: $debug_file,
      tasks: $tasks,
      artifacts: $artifacts
    }' > "$manifest_file"

  validate_json_file "$manifest_file"
}

generate_pdf_report() {
  local py_script="$APP_ROOT/generate_pdf_report.py"
  local pdf_path="${RUN_REPORT_FILE%.txt}.pdf"
  local pdf_out

  if [[ -z "$RUN_OUTPUT_DIR" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  if ! python3 -c "import fpdf" 2>/dev/null; then
    echo "PDF generation skipped: fpdf2 not installed (pip3 install fpdf2)"
    return 0
  fi
  if [[ ! -f "$py_script" ]]; then
    return 0
  fi
  if [[ ! -f "$RUN_MANIFEST_FILE" ]]; then
    return 0
  fi

  echo "Generating PDF report..."
  local pdf_err
  pdf_err="$(python3 "$py_script" "$RUN_OUTPUT_DIR" "$APP_ROOT" "$pdf_path" "${RUN_PREPARED_BY:-}" 2>&1 >/dev/null || true)"
  if [[ -f "$pdf_path" ]]; then
    echo "PDF report:    $pdf_path"
  else
    echo "PDF generation failed${pdf_err:+: $pdf_err}"
  fi
}

finalize_run() {
  if [[ "$NETWORK_INTERRUPTED" != "true" ]]; then
    if [[ -n "$RUN_OUTPUT_DIR" ]] && [[ -n "$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]]; then
      build_report_for_current_run || true
    fi
  fi

  if [[ -n "$RUN_OUTPUT_DIR" && -n "$SESSION_DEBUG_LOG" && -f "$SESSION_DEBUG_LOG" ]]; then
    cp "$SESSION_DEBUG_LOG" "$RUN_DEBUG_LOG" 2>/dev/null || true
  fi

  if [[ -n "$RUN_OUTPUT_DIR" ]]; then
    write_manifest_for_current_run || true
  fi

  if [[ -n "$SESSION_DEBUG_LOG" && -f "$SESSION_DEBUG_LOG" ]]; then
    rm -f "$SESSION_DEBUG_LOG" 2>/dev/null || true
  fi

}

handle_err_exit() {
  # Only act if we're mid-run with a known interface
  if [[ -z "$SELECTED_INTERFACE" ]] || [[ -z "$RUN_OUTPUT_DIR" ]]; then
    return
  fi
  # Check whether the interface has disappeared OR lost its IP address
  # (covers both physical unplug and WiFi/network drop where interface stays up)
  local iface_up=true
  if ! ifconfig "$SELECTED_INTERFACE" &>/dev/null 2>&1; then
    iface_up=false
  elif ! ifconfig "$SELECTED_INTERFACE" 2>/dev/null | grep -q 'inet '; then
    iface_up=false
  fi
  if [[ "$iface_up" == "false" ]]; then
    NETWORK_INTERRUPTED=true
    stop_spinner_line 2>/dev/null || true
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "  Network connection lost during the audit."
    echo ""
    echo "  '$SELECTED_INTERFACE' lost its connection mid-scan."
    echo "  Tasks completed so far have been saved."
    echo ""
    echo "  Please reconnect, then use 'Manage Previous Runs' →"
    echo "  'Continue This Run' to resume from where it stopped."
    echo "────────────────────────────────────────────────────────"
  fi
}

interface_has_valid_ip() {
  local iface="$1"
  local ip
  if ! ifconfig "$iface" &>/dev/null 2>&1; then
    return 1
  fi
  ip="$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
  [[ -z "$ip" ]] && return 1
  [[ "$ip" == 169.254.* ]] && return 1
  return 0
}

warn_if_not_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Some scans may not work correctly without root privileges."
  fi
}

clear_screen_if_supported() {
  if [[ "$OUTPUT_IS_TTY" -eq 1 ]]; then
    if command -v clear >/dev/null 2>&1 && [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]]; then
      clear
    else
      printf '\033[2J\033[H'
    fi
  fi
}

print_install_hint() {
  local tool="$1"
  if [[ "$OS" == "macos" ]]; then
    case "$tool" in
      python3-scapy)
        echo "Missing required Python library: scapy"
        echo "Install with: pip3 install scapy"
        ;;
      python3-fpdf2)
        echo "Missing required Python library: fpdf2"
        echo "Install with: pip3 install fpdf2"
        ;;
      sshpass)
        echo "Missing required tool: sshpass"
        echo "Install with: brew install hudochenkov/sshpass/sshpass"
        ;;
      *)
        echo "Missing required tool: $tool"
        echo "Install with: brew install $tool"
        ;;
    esac
  else
    echo "Missing required tool: $tool"
    case "$tool" in
      iproute2|iputils-ping|tcpdump|sshpass)
        echo "Install with: apt-get install $tool"
        ;;
      python3-scapy)
        echo "Install with: apt-get install python3-scapy"
        ;;
      python3-fpdf2)
        echo "Missing required Python library: fpdf2"
        echo "Install with: pip3 install fpdf2"
        ;;
      *)
        echo "Install with: apt-get install $tool"
        ;;
    esac
  fi
}

check_tools() {
  local missing=0
  local red='[0;31m'
  local green='[0;32m'
  local yellow='[1;33m'
  local reset='[0m'
  local base_tools=(nmap awk sed grep find mktemp jq speedtest-cli python3)
  local os_tools=()
  local missing_tools=()
  local tool
  local choice

  if [[ "$OS" == "macos" ]]; then
    os_tools=(ipconfig ifconfig route networksetup ping tcpdump)
  else
    os_tools=(ip ping tcpdump)
  fi

  echo
  printf "${yellow}Startup Check${reset}\n"
  printf "${yellow}========================${reset}\n"
  echo
  echo "Dependency Checklist:"

  for tool in "${base_tools[@]}" "${os_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf "${green}[OK]${reset} %s\n" "$tool"
    else
      printf "${red}[MISSING]${reset} %s\n" "$tool"
      missing=1
      if [[ "$tool" == "ip" ]]; then
        missing_tools+=("iproute2")
      elif [[ "$tool" == "ping" && "$OS" == "linux" ]]; then
        missing_tools+=("iputils-ping")
      elif [[ "$tool" == "tcpdump" ]]; then
        missing_tools+=("tcpdump")
      else
        missing_tools+=("$tool")
      fi
    fi
  done

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import scapy" 2>/dev/null; then
      printf "${green}[OK]${reset} python3-scapy\n"
    else
      printf "${red}[MISSING]${reset} python3-scapy\n"
      missing=1
      missing_tools+=("python3-scapy")
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import fpdf" 2>/dev/null; then
      printf "${green}[OK]${reset} python3-fpdf2\n"
    else
      printf "${red}[MISSING]${reset} python3-fpdf2\n"
      missing=1
      missing_tools+=("python3-fpdf2")
    fi
  fi

  if [[ "$OS" == "linux" ]] && ! command -v ifconfig >/dev/null 2>&1; then
    echo
    echo "Optional fallback missing: ifconfig"
    echo "Install with: apt install net-tools"
  fi

  echo
  echo "Optional - Task 19 UniFi Adoption:"
  if command -v sshpass >/dev/null 2>&1; then
    printf "${green}[OK]${reset} sshpass\n"
  else
    if [[ "$OS" == "macos" ]]; then
      printf "${yellow}[WARN]${reset} sshpass not found — Task 19 unavailable (install with: brew install hudochenkov/sshpass/sshpass)\n"
    else
      printf "${yellow}[WARN]${reset} sshpass not found — Task 19 unavailable (install with: apt install sshpass)\n"
    fi
  fi

  echo
  echo "Optional - Task 17 Wireless Site Survey:"
  if [[ "$OS" == "macos" ]]; then
    local airport_bin="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    if [[ -x "$airport_bin" ]]; then
      printf "${green}[OK]${reset} airport (wireless scan)\n"
    elif command -v system_profiler >/dev/null 2>&1; then
      printf "${green}[OK]${reset} system_profiler (wireless scan fallback — airport not available on this macOS version)\n"
    else
      printf "${yellow}[WARN]${reset} No wireless scan tool available — Task 17 unavailable on this Mac\n"
    fi
  else
    if command -v iw >/dev/null 2>&1; then
      printf "${green}[OK]${reset} iw (wireless scan)\n"
    else
      printf "${yellow}[WARN]${reset} iw not found — Task 17 wireless scan unavailable (install with: apt install iw)\n"
    fi
  fi

  if [[ "$missing" -eq 1 ]]; then
    echo
    echo "Missing required dependencies:"
    for tool in "${missing_tools[@]}"; do
      print_install_hint "$tool"
    done

    while true; do
      echo
      read -r -p "Do you want to install missing dependencies now using install.sh? (y/n): " choice
      case "$choice" in
        y|Y|yes|YES|Yes)
          echo "Running install.sh to install all required dependencies..."
          if ! bash "$SCRIPT_DIR/install.sh"; then
            echo "install.sh failed. Cannot continue without required dependencies."
            exit 1
          fi

          echo "Rechecking dependencies after install..."
          missing=0
          missing_tools=()
          for tool in "${base_tools[@]}" "${os_tools[@]}"; do
            if command -v "$tool" >/dev/null 2>&1; then
              printf "${green}[OK]${reset} %s\n" "$tool"
            else
              printf "${red}[MISSING]${reset} %s\n" "$tool"
              missing=1
              if [[ "$tool" == "ip" ]]; then
                missing_tools+=("iproute2")
              elif [[ "$tool" == "ping" && "$OS" == "linux" ]]; then
                missing_tools+=("iputils-ping")
              elif [[ "$tool" == "tcpdump" ]]; then
                missing_tools+=("tcpdump")
              else
                missing_tools+=("$tool")
              fi
            fi
          done

          if [[ "$missing" -eq 0 ]]; then
            echo "All required dependencies are installed. Continuing..."
            return
          fi

          echo "Dependencies are still missing after install.sh: ${missing_tools[*]}"
          echo "Everything is required to run this program correctly. Exiting."
          exit 1
          ;;
        n|N|no|NO|No)
          echo "Everything is required to run this program correctly. Exiting."
          exit 1
          ;;
        *)
          echo "Invalid selection. Enter y or n."
          ;;
      esac
    done
  fi

  if [[ "$missing" -eq 0 ]]; then
    echo
    printf "${green}All required dependencies are available.${reset}\n"
  fi
}


list_interfaces() {
  if [[ "$OS" == "macos" ]]; then
    ifconfig -l | tr ' ' '\n' | sed '/^$/d'
  else
    ip -o link show | awk -F': ' '{print $2}' | awk -F'@' '{print $1}'
  fi
}

get_interface_description() {
  local iface="$1"
  local description=""

  if [[ "$OS" != "macos" ]]; then
    echo ""
    return
  fi

  description="$(networksetup -listallhardwareports 2>/dev/null | awk -v dev="$iface" '
    /^Hardware Port: / { port = substr($0, 16) }
    /^Device: / {
      if (substr($0, 9) == dev) {
        print port
        exit
      }
    }
  ')"

  if [[ -z "$description" && "$iface" == "lo0" ]]; then
    description="Loopback"
  fi

  echo "$description"
}

select_interface() {
  local interfaces=()
  local ordered_interfaces=()
  local ipv4_interfaces=()
  local other_interfaces=()
  local idx=1
  local choice
  local display_label
  local status_suffix
  local red='\033[0;31m'
  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'
  local has_ipv4=false

  while IFS= read -r iface; do
    interfaces+=("$iface")
  done < <(list_interfaces)

  if [[ "${#interfaces[@]}" -eq 0 ]]; then
    echo "No network interfaces found."
    exit 1
  fi

  while true; do
    ordered_interfaces=()
    ipv4_interfaces=()
    other_interfaces=()

    for iface in "${interfaces[@]}"; do
      if interface_has_ipv4 "$iface"; then
        ipv4_interfaces+=("$iface")
      else
        other_interfaces+=("$iface")
      fi
    done
    ordered_interfaces=("${ipv4_interfaces[@]}" "${other_interfaces[@]}")

    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Select Network Interface${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    if [[ "${#ipv4_interfaces[@]}" -gt 0 ]]; then
      printf "  Active Interfaces:\n"
    else
      printf "  ${red}WARNING: No IPv4 address was detected on any interface.${reset}\n"
      printf "  Possible causes: disconnected cable, Wi-Fi not connected, no DHCP offer received,\n"
      printf "  or an unconfigured interface.\n"
      echo
      printf "  Other Interfaces:\n"
    fi
    echo
    idx=1
    for iface in "${ordered_interfaces[@]}"; do
      display_label="$iface"
      status_suffix=""
      has_ipv4=false

      if [[ "$OS" == "macos" ]]; then
        local description
        description="$(get_interface_description "$iface")"
        if [[ -n "$description" ]]; then
          display_label="$iface ($description)"
        fi
      fi

      if interface_has_ipv4 "$iface"; then
        local details ip
        details="$(get_interface_details "$iface")"
        IFS='|' read -r ip _ _ _ _ <<< "$details"
        has_ipv4=true
        if [[ -n "$ip" ]]; then
          display_label="$display_label ($ip)"
        fi
      else
        status_suffix=" (no IPv4 address detected)"
      fi

      if [[ "$iface" == "lo0" ]]; then
        status_suffix=" (loopback)"
      fi

      if [[ "$has_ipv4" == "false" && "${#ipv4_interfaces[@]}" -gt 0 && "$idx" == "$((${#ipv4_interfaces[@]} + 1))" ]]; then
        echo
        printf "  Other Interfaces:\n"
        echo
      fi

      if [[ "$has_ipv4" == "true" && "$OUTPUT_IS_TTY" -eq 1 ]]; then
        printf "  ${bold}%2d)${reset}  ${green}%s%s${reset}\n" "$idx" "$display_label" "$status_suffix"
      else
        printf "  ${bold}%2d)${reset}  %s%s\n" "$idx" "$display_label" "$status_suffix"
      fi
      idx=$((idx + 1))
    done
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}  0)${reset}  Back to Main Menu\n"
    echo
    read -r -p "  Enter selection: " choice

    if [[ "$choice" == "0" ]]; then
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ordered_interfaces[@]} )); then
      SELECTED_INTERFACE="${ordered_interfaces[$((choice - 1))]}"
      clear_screen_if_supported
      if ! interface_has_valid_ip "$SELECTED_INTERFACE"; then
        if interface_has_ipv4 "$SELECTED_INTERFACE"; then
          echo "Warning: $SELECTED_INTERFACE has a self-assigned address (169.254.x.x) — no DHCP lease."
          echo "The interface is up but has no routable IP. Check your cable or DHCP server."
        else
          echo "Warning: $SELECTED_INTERFACE does not currently have an IPv4 address."
          echo "Interface info and network-range scans may fail on bridge/physical-only interfaces."
          echo "On Proxmox or Debian bridge hosts, you may want a bridge interface such as vmbr0 instead."
        fi
        echo
      fi
      return
    fi

    echo "Invalid selection. Try again."
  done
}

mask_to_prefix() {
  local mask="$1"
  echo "$mask" | awk -F'.' '{
    bits=0
    for(i=1;i<=4;i++){
      n=$i+0
      while(n>0){bits+=n%2; n=int(n/2)}
    }
    print bits
  }'
}

cidr_to_mask() {
  local prefix="$1"
  local mask=""
  local i octet remaining

  remaining="$prefix"
  for i in 1 2 3 4; do
    if (( remaining >= 8 )); then
      octet=255
      remaining=$((remaining - 8))
    elif (( remaining > 0 )); then
      octet=$((256 - 2 ** (8 - remaining)))
      remaining=0
    else
      octet=0
    fi

    if [[ -z "$mask" ]]; then
      mask="$octet"
    else
      mask="$mask.$octet"
    fi
  done
  echo "$mask"
}

calculate_network() {
  local ip="$1"
  local prefix="$2"
  awk -v ip="$ip" -v p="$prefix" 'BEGIN{
    split(ip, a, ".")
    ipint = (a[1]*16777216) + (a[2]*65536) + (a[3]*256) + a[4]
    hostsize = 2^(32-p)
    netint = int(ipint/hostsize)*hostsize
    o1 = int(netint/16777216); rem = netint%16777216
    o2 = int(rem/65536); rem = rem%65536
    o3 = int(rem/256); o4 = rem%256
    printf "%d.%d.%d.%d/%d\n", o1, o2, o3, o4, p
  }'
}

get_interface_details() {
  local iface="$1"
  local ip=""
  local mask=""
  local prefix=""
  local mac=""
  local gateway=""

  if [[ "$OS" == "macos" ]]; then
    ip="$(ifconfig "$iface" | awk '/inet /{print $2; exit}')"
    local hexmask
    hexmask="$(ifconfig "$iface" | awk '/inet /{for(i=1;i<=NF;i++) if($i=="netmask") {print $(i+1); exit}}')"
    if [[ "$hexmask" =~ ^0x ]]; then
      mask="$(printf "%d.%d.%d.%d" "$((16#${hexmask:2:2}))" "$((16#${hexmask:4:2}))" "$((16#${hexmask:6:2}))" "$((16#${hexmask:8:2}))")"
    fi
    mac="$(ifconfig "$iface" | awk '/ether /{print $2; exit}')"
  else
    local ip_cidr
    ip_cidr="$(ip -o -4 addr show dev "$iface" scope global | awk '{print $4; exit}')"
    if [[ -n "$ip_cidr" ]]; then
      ip="${ip_cidr%/*}"
      prefix="${ip_cidr#*/}"
      mask="$(cidr_to_mask "$prefix")"
    elif command -v ifconfig >/dev/null 2>&1; then
      ip="$(ifconfig "$iface" | awk '/inet /{print $2; exit}')"
      mask="$(ifconfig "$iface" | awk '/inet /{for(i=1;i<=NF;i++) if($i=="netmask") {print $(i+1); exit}}')"
    fi
    mac="$(ip link show "$iface" | awk '/link\/(ether|loopback)/{print $2; exit}')"
  fi

  gateway="$(get_gateway_ip "$iface")"
  printf '%s|%s|%s|%s|%s\n' "$ip" "$mask" "$prefix" "$mac" "$gateway"
}

interface_has_ipv4() {
  local iface="$1"
  local details=""
  local ip=""
  local mask=""

  details="$(get_interface_details "$iface")"
  IFS='|' read -r ip mask _ _ _ <<< "$details"

  [[ -n "$ip" && -n "$mask" ]]
}

is_loopback_interface() {
  local iface="$1"
  [[ "$iface" == "lo0" || "$iface" == "lo" ]]
}

is_virtual_or_tunnel_interface() {
  local iface="$1"
  [[ "$iface" =~ ^(utun|gif|stf|awdl|llw|anpi|ap|vmenet|bridge|tun|tap|virbr|docker|br-) ]]
}

active_interface_summary() {
  local iface=""
  local details=""
  local ip=""
  local entries=()

  while IFS= read -r iface; do
    [[ -z "$iface" ]] && continue
    details="$(get_interface_details "$iface")"
    IFS='|' read -r ip _ _ _ _ <<< "$details"
    if [[ -n "$ip" ]]; then
      entries+=("$iface ($ip)")
    fi
  done < <(list_interfaces)

  if [[ "${#entries[@]}" -gt 0 ]]; then
    join_by ", " "${entries[@]}"
  fi
}

print_interface_info_failure() {
  local iface="$1"
  local ip="$2"
  local mask="$3"
  local active_summary=""

  echo "Error: Unable to collect complete IPv4 interface details for $iface."

  if [[ -z "$ip" && -z "$mask" ]]; then
    if is_loopback_interface "$iface"; then
      echo "The selected interface is loopback-only and is not suitable for LAN scanning."
    elif is_virtual_or_tunnel_interface "$iface"; then
      echo "The selected interface appears to be a virtual, tunnel, or bridge-style interface without an IPv4 address."
    else
      echo "No IPv4 address and subnet mask were detected on this interface."
    fi
    echo "Possible causes include a disconnected cable, Wi-Fi not being connected, no DHCP offer being received, or the wrong interface being selected."
  elif [[ -z "$ip" ]]; then
    echo "A subnet mask was detected, but no IPv4 address was found on this interface."
    echo "This can happen when the interface is down, waiting for DHCP, or only partially configured."
  elif [[ -z "$mask" ]]; then
    echo "An IPv4 address was detected ($ip), but the subnet mask could not be determined."
    echo "This may be caused by unusual OS command output or a partially configured interface."
  fi

  active_summary="$(active_interface_summary)"
  if [[ -n "$active_summary" ]]; then
    echo "Try one of the active interfaces instead: $active_summary"
  fi
}

detect_vm_platform() {
  # Linux: systemd-detect-virt is the most reliable method
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt="$(systemd-detect-virt --vm 2>/dev/null)"
    if [[ -n "$virt" && "$virt" != "none" ]]; then
      echo "$virt"
      return 0
    fi
  fi
  # Linux fallback: cpuinfo hypervisor flag + DMI vendor
  if [[ -f /proc/cpuinfo ]] && grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
    local vendor
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')" || true
    case "$vendor" in
      *vmware*)     echo "vmware"     ;;
      *qemu*|*kvm*) echo "kvm"        ;;
      *virtualbox*) echo "virtualbox" ;;
      *microsoft*)  echo "hyperv"     ;;
      *xen*)        echo "xen"        ;;
      *)            echo "vm"         ;;
    esac
    return 0
  fi
  # macOS: kern.hv_vmm_present = 1 when running inside a hypervisor
  if [[ "$OS" == "macos" ]] && [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" == "1" ]]; then
    echo "vm"
    return 0
  fi
  echo "none"
}

write_interface_info_json() {
  local status="$1"
  local success="$2"
  local error_code="$3"
  local error_message="$4"
  local iface="$5"
  local ip="$6"
  local mask="$7"
  local network="$8"
  local gateway="$9"
  local mac="${10}"
  shift 10
  local warnings=("$@")
  local warnings_json

  warnings_json="$(json_string_array_from_array warnings)"

  local vm_platform is_vm
  vm_platform="$(detect_vm_platform)"
  is_vm="false"
  [[ "$vm_platform" != "none" ]] && is_vm="true"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --arg interface "$iface" \
    --arg ip_address "$ip" \
    --arg subnet "$mask" \
    --arg network "$network" \
    --arg gateway "$gateway" \
    --arg mac_address "$mac" \
    --argjson is_vm "$is_vm" \
    --arg vm_platform "$vm_platform" \
    --argjson warnings "$warnings_json" \
    '{
      status: $status,
      success: $success,
      error: (if $error_code == "" and $error_message == "" then null else {code: $error_code, message: $error_message} end),
      warnings: $warnings,
      interface: $interface,
      ip_address: (if $ip_address == "" then null else $ip_address end),
      subnet: (if $subnet == "" then null else $subnet end),
      network: (if $network == "" then null else $network end),
      gateway: (if $gateway == "" then null else $gateway end),
      mac_address: (if $mac_address == "" then null else $mac_address end),
      is_vm: $is_vm,
      vm_platform: (if $vm_platform == "none" then null else $vm_platform end)
    }' > "$(task_output_path 1)"

  validate_json_file "$(task_output_path 1)"
}

interface_info() {
  local iface="$1"
  local silent_mode="${2:-}"
  local details=""
  local ip=""
  local mask=""
  local prefix=""
  local network=""
  local mac=""
  local gateway=""
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()

  details="$(get_interface_details "$iface")"
  IFS='|' read -r ip mask prefix mac gateway <<< "$details"

  if [[ -z "$ip" || -z "$mask" ]]; then
    success="false"
    status="failed"
    if [[ -z "$ip" && -z "$mask" ]]; then
      if is_loopback_interface "$iface"; then
        error_code="loopback_interface_selected"
        error_message="The selected interface is loopback-only and is not suitable for LAN scanning."
      elif is_virtual_or_tunnel_interface "$iface"; then
        error_code="no_ipv4_on_virtual_interface"
        error_message="The selected interface appears to be a virtual, tunnel, or bridge-style interface without an IPv4 address."
      else
        error_code="no_ipv4_or_subnet_detected"
        error_message="No IPv4 address or subnet mask was detected on the selected interface."
      fi
    elif [[ -z "$ip" ]]; then
      error_code="ipv4_address_missing"
      error_message="A subnet mask was detected, but no IPv4 address was found on the selected interface."
    else
      error_code="subnet_mask_missing"
      error_message="An IPv4 address was detected, but the subnet mask could not be determined."
    fi
    write_interface_info_json "$status" "$success" "$error_code" "$error_message" "$iface" "$ip" "$mask" "" "$gateway" "$mac"
    if [[ "$silent_mode" != "silent" ]]; then
      print_interface_info_failure "$iface" "$ip" "$mask"
    fi
    return 1
  fi

  if [[ -z "$prefix" ]]; then
    prefix="$(mask_to_prefix "$mask")"
  fi
  network="$(calculate_network "$ip" "$prefix")"

  if [[ -z "$network" ]]; then
    success="false"
    status="failed"
    error_code="network_range_calculation_failed"
    error_message="IPv4 details were found, but the network range could not be calculated."
    write_interface_info_json "$status" "$success" "$error_code" "$error_message" "$iface" "$ip" "$mask" "" "$gateway" "$mac"
    if [[ "$silent_mode" != "silent" ]]; then
      echo "Error: IPv4 details were found for $iface, but the network range could not be calculated."
      echo "IP Address: $ip"
      echo "Subnet Mask: $mask"
      echo "This may indicate malformed interface data or unexpected OS command output."
    fi
    return 1
  fi

  if [[ -z "$gateway" ]]; then
    gateway=""
    warnings+=("No default gateway was detected for this interface. Local subnet scans may still work, but internet-dependent tests may fail.")
  fi
  if [[ -z "$mac" ]]; then
    warnings+=("The MAC address could not be read for this interface.")
  fi
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    status="completed_with_warnings"
  fi

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 && "$silent_mode" != "silent" ]]; then
    echo
    echo "Interface Network Info"
  fi
  if [[ "$silent_mode" != "silent" ]]; then
    echo "Interface: $iface"
    echo "IP Address: $ip"
    echo "Subnet Mask: $mask"
    echo "Network Range: $network"
    if [[ -n "$gateway" ]]; then
      echo "Gateway: $gateway"
    else
      echo "Gateway: not detected"
      echo "Warning: No default gateway was detected for $iface. Local subnet scans may still work, but internet-dependent tests may fail."
    fi
    if [[ -n "$mac" ]]; then
      echo "MAC Address: $mac"
    else
      echo "MAC Address: not detected"
      echo "Warning: The MAC address could not be read for $iface."
    fi
  fi

  mkdir -p "$(current_output_dir)"

  if [[ "${#warnings[@]}" -gt 0 ]]; then
    write_interface_info_json "$status" "$success" "$error_code" "$error_message" "$iface" "$ip" "$mask" "$network" "$gateway" "$mac" "${warnings[@]}"
  else
    write_interface_info_json "$status" "$success" "$error_code" "$error_message" "$iface" "$ip" "$mask" "$network" "$gateway" "$mac"
  fi

  return 0
}

get_gateway_ip() {
  local iface="$1"
  if [[ "$OS" == "macos" ]]; then
    route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
  else
    local gw
    gw="$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')"
    if [[ -z "$gw" ]]; then
      gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
    fi
    echo "$gw"
  fi
}

is_rfc1918_ip() {
  local ip="$1"
  local a b c
  IFS='.' read -r a b c _ <<< "$ip"
  [[ "$a" -eq 10 ]] && return 0
  [[ "$a" -eq 172 && "$b" -ge 16 && "$b" -le 31 ]] && return 0
  [[ "$a" -eq 192 && "$b" -eq 168 ]] && return 0
  return 1
}

get_interface_network_cidr() {
  local iface="$1"
  local details=""
  local ip=""
  local mask=""
  local prefix=""

  details="$(get_interface_details "$iface")"
  IFS='|' read -r ip mask prefix _ _ <<< "$details"

  if [[ -z "$ip" || -z "$mask" ]]; then
    return 1
  fi

  if [[ -z "$prefix" ]]; then
    prefix="$(mask_to_prefix "$mask")"
  fi

  calculate_network "$ip" "$prefix"
}

label_port_service() {
  case "$1" in
    88) echo "kerberos" ;;
    111) echo "rpcbind" ;;
    139) echo "smb-netbios" ;;
    389) echo "ldap" ;;
    445) echo "smb" ;;
    53) echo "dns" ;;
    515) echo "printer-lpd" ;;
    631) echo "printer-ipp" ;;
    636) echo "ldaps" ;;
    9100) echo "printer-jetdirect" ;;
    2049) echo "nfs" ;;
    3268) echo "ldap-global-catalog" ;;
    3269) echo "ldaps-global-catalog" ;;
    *) echo "port-$1" ;;
  esac
}

array_contains() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

json_string_array() {
  if [[ "$#" -eq 0 ]]; then
    echo "[]"
    return
  fi

  printf '%s\n' "$@" | jq -R . | jq -s .
}

json_string_array_from_array() {
  local array_name="$1"
  local count

  eval "count=\${#${array_name}[@]}"
  if [[ "$count" -eq 0 ]]; then
    echo "[]"
    return
  fi

  eval "json_string_array \"\${${array_name}[@]}\""
}

extract_dhcp_offer_records() {
  local file="$1"

  awk '
    /Response [0-9]+ of [0-9]+:/ {
      if (server_id != "" || offered_ip != "") {
        printf "%s\t%s\n", server_id, offered_ip
      }
      server_id = ""
      offered_ip = ""
      next
    }
    /Server Identifier:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) {
          server_id = $i
        }
      }
      next
    }
    /IP Offered:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) {
          offered_ip = $i
        }
      }
      next
    }
    END {
      if (server_id != "" || offered_ip != "") {
        printf "%s\t%s\n", server_id, offered_ip
      }
    }
  ' "$file"
}

capture_dhcp_traffic() {
  local iface="$1"
  local output_file="$2"

  if ! command -v tcpdump >/dev/null 2>&1 || [[ "$EUID" -ne 0 ]]; then
    return 1
  fi

  tcpdump -ni "$iface" -l port 67 or port 68 > "$output_file" 2>/dev/null &
  echo $!
}

extract_dhcp_packet_sources() {
  local file="$1"

  awk '
    /IP [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.67 >/ {
      line = $0
      sub(/^.*IP /, "", line)
      sub(/\.67 >.*$/, "", line)
      if (line ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        print line
      }
    }
  ' "$file"
}

extract_dhcp_attempt_excerpt() {
  local file="$1"

  awk '
    NR <= 40 {
      print
    }
  ' "$file"
}

count_unique_offer_keys_for_server() {
  local target="$1"
  shift || true

  if [[ "$#" -eq 0 ]]; then
    echo 0
    return
  fi

  printf '%s\n' "$@" | awk -F'|' -v target="$target" '$1 == target {count++} END {print count+0}'
}

classify_dhcp_server() {
  local server_ip="$1"
  local gateway_ip="$2"
  shift 2
  local ports=("$@")

  if [[ -n "$gateway_ip" && "$server_ip" == "$gateway_ip" ]]; then
    echo "gateway"
    return
  fi

  if array_contains "67" "${ports[@]}" || array_contains "68" "${ports[@]}"; then
    echo "dhcp-service-host"
    return
  fi

  if array_contains "88" "${ports[@]}" || array_contains "389" "${ports[@]}" || array_contains "636" "${ports[@]}" || array_contains "3268" "${ports[@]}" || array_contains "3269" "${ports[@]}"; then
    echo "directory-infrastructure"
    return
  fi

  if array_contains "53" "${ports[@]}" || array_contains "80" "${ports[@]}" || array_contains "443" "${ports[@]}"; then
    echo "network-infrastructure"
    return
  fi

  if array_contains "135" "${ports[@]}" || array_contains "139" "${ports[@]}" || array_contains "445" "${ports[@]}" || array_contains "3389" "${ports[@]}" || array_contains "5985" "${ports[@]}"; then
    echo "windows-infrastructure"
    return
  fi

  echo "unknown"
}

scan_servers_by_ports() {
  local title="$1"
  local description="$2"
  local port_list="$3"
  local output_file="$4"
  local network
  local scan_file
  local json_file
  local raw_file
  local result_count=0
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()
  local warnings_json

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "$title"
  fi
  echo "Stage 1: Getting network range for interface $SELECTED_INTERFACE..."

  network="$(get_interface_network_cidr "$SELECTED_INTERFACE")"
  if [[ -z "$network" ]]; then
    echo "Error: Unable to determine the network range for $SELECTED_INTERFACE."
    echo "Possible causes include no IPv4 address on the selected interface, a missing subnet mask, or selecting a bridge, tunnel, or otherwise non-routed interface."
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "network_range_not_detected" \
      --arg error_message "Unable to determine the network range for the selected interface." \
      --arg network "" \
      --arg scan_ports "$port_list" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, network: null, scan_ports: $scan_ports, servers: []}' > "$(current_output_dir)/$output_file"
    validate_json_file "$(current_output_dir)/$output_file"
    return 1
  fi

  echo "Done."
  echo "Network Range: $network"
  echo
  echo "Stage 2: Scanning $description ports ($port_list)..."

  scan_file="$(mktemp)"
  if [[ -z "$scan_file" || ! -f "$scan_file" ]]; then
    echo "Error: Unable to create a temporary file for the $description scan."
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "tempfile_creation_failed" \
      --arg error_message "Unable to create a temporary file for the scan." \
      --arg network "$network" \
      --arg scan_ports "$port_list" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, network: $network, scan_ports: $scan_ports, servers: []}' > "$(current_output_dir)/$output_file"
    validate_json_file "$(current_output_dir)/$output_file"
    return 1
  fi
  raw_file="$(current_raw_output_dir)/${output_file%.json}-nmap.grep"
  nmap -n -p "$port_list" --open "$network" -oG - > "$scan_file" 2>/dev/null &
  local scan_pid=$!
  monitor_nmap_progress "$scan_pid" "$scan_file" 300 "host_ports" "Matches Found:" "Port scan failed for network $network." || {
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "network_port_scan_failed" \
      --arg error_message "The network port scan did not complete successfully." \
      --arg network "$network" \
      --arg scan_ports "$port_list" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, network: $network, scan_ports: $scan_ports, servers: []}' > "$(current_output_dir)/$output_file"
    validate_json_file "$(current_output_dir)/$output_file"
    rm -f "$scan_file"
    return 1
  }

  copy_raw_artifact "$scan_file" "$raw_file"

  json_file="$(current_output_dir)/$output_file"
  warnings_json='[]'
  jq -n \
    --arg status "$status" \
    --argjson success true \
    --argjson warnings "$warnings_json" \
    --arg network "$network" \
    --arg scan_ports "$port_list" \
    '{status: $status, success: $success, error: null, warnings: $warnings, network: $network, scan_ports: $scan_ports, servers: []}' > "$json_file"

  while IFS='|' read -r host_ip open_ports; do
    local ports_array=()
    local service_names=()
    local port
    local i

    if [[ -n "$open_ports" ]]; then
      while IFS= read -r port; do
        [[ -n "$port" ]] && ports_array+=("$port")
      done < <(echo "$open_ports" | tr ',' '\n' | sed '/^$/d')
    fi

    if [[ "${#ports_array[@]}" -eq 0 ]]; then
      continue
    fi

    for i in "${!ports_array[@]}"; do
      service_names+=("$(label_port_service "${ports_array[$i]}")")
    done

    jq \
      --arg ip "$host_ip" \
      --argjson open_ports "$(ports_to_json_array "${ports_array[@]}")" \
      --argjson detected_services "$(printf '%s\n' "${service_names[@]}" | jq -R . | jq -s .)" \
      '.servers += [{ip: $ip, open_ports: $open_ports, detected_services: $detected_services}]' \
      "$json_file" > "$json_file.tmp"
    mv "$json_file.tmp" "$json_file"

    echo "Server: $host_ip"
    echo "Open Ports: ${ports_array[*]}"
    echo "Detected Services: ${service_names[*]}"
    echo

    result_count=$((result_count + 1))
  done < <(awk '
    /Host: / && /Ports: / {
      ip = ""
      if (match($0, /Host: [0-9.]+/)) {
        ip = substr($0, RSTART + 6, RLENGTH - 6)
      }
      if (ip == "") {
        next
      }

      split($0, parts, "Ports: ")
      if (length(parts) < 2) {
        next
      }

      n = split(parts[2], p, ",")
      open = ""
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", p[i])
        split(p[i], f, "/")
        if (f[2] == "open" && f[1] ~ /^[0-9]+$/) {
          if (open != "") {
            open = open ","
          }
          open = open f[1]
        }
      }

      if (open != "") {
        print ip "|" open
      }
    }
  ' "$scan_file")

  rm -f "$scan_file"

  if [[ "$result_count" -eq 0 ]]; then
    warnings+=("The scan completed, but no matching hosts were found on the selected network range.")
    status="completed_with_warnings"
  fi

  warnings_json="$(json_string_array_from_array warnings)"
  jq \
    --arg status "$status" \
    --argjson success "$success" \
    --argjson warnings "$warnings_json" \
    '.status = $status
     | .success = $success
     | .warnings = $warnings' \
    "$json_file" > "$json_file.tmp" || {
      echo "Failed to finalize JSON output for $title."
      return 1
    }
  mv "$json_file.tmp" "$json_file"

  echo "$title results found: $result_count"
  validate_json_file "$json_file"
  return 0
}


enrich_dns_resolution() {
  local json_file="$1"
  local dns_ips=()
  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && dns_ips+=("$ip")
  done < <(jq -r '.servers[]?.ip // empty' "$json_file" 2>/dev/null)

  [[ "${#dns_ips[@]}" -eq 0 ]] && return 0

  local bold='\033[1m'
  local reset='\033[0m'
  printf "${bold}Resolution test (google.com):${reset}\n"
  echo
  local tmp_py
  tmp_py="$(mktemp /tmp/lss-dns-test-XXXXXX)"
  cat > "$tmp_py" << 'PYEOF'
import sys, socket, time, struct, random, json

def dns_query(server_ip, domain, timeout=3):
    txid = random.randint(0, 65535)
    header = struct.pack('!HHHHHH', txid, 0x0100, 1, 0, 0, 0)
    question = b''
    for label in domain.split('.'):
        e = label.encode()
        question += bytes([len(e)]) + e
    question += b'\x00' + struct.pack('!HH', 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        start = time.time()
        sock.sendto(header + question, (server_ip, 53))
        data, _ = sock.recvfrom(512)
        elapsed = round((time.time() - start) * 1000, 1)
        rcode = struct.unpack('!H', data[2:4])[0] & 0x000F
        ancount = struct.unpack('!H', data[6:8])[0]
        return (rcode == 0 and ancount > 0), elapsed
    except Exception:
        return False, None
    finally:
        sock.close()

results = []
for ip in sys.argv[1:]:
    resolved, ms = dns_query(ip, 'google.com')
    results.append({'ip': ip, 'resolved': resolved, 'response_ms': ms})
print(json.dumps(results))
PYEOF

  local result_json
  result_json="$(python3 "$tmp_py" "${dns_ips[@]}" 2>/dev/null || echo '[]')"
  rm -f "$tmp_py"

  local idx=0
  for ip in "${dns_ips[@]}"; do
    local resolved ms
    resolved="$(printf '%s' "$result_json" | jq -r ".[$idx].resolved // false" 2>/dev/null)"
    ms="$(printf '%s' "$result_json" | jq -r ".[$idx].response_ms // \"null\"" 2>/dev/null)"
    if [[ "$resolved" == "true" ]]; then
      printf "  ${bold}%-16s${reset}  OK  (%s ms)\n" "$ip" "$ms"
    else
      printf "  ${bold}%-16s${reset}  FAILED\n" "$ip"
    fi
    local ms_json="null"
    [[ "$ms" != "null" && -n "$ms" ]] && ms_json="$ms"
    jq \
      --arg ip "$ip" \
      --argjson resolved "$([ "$resolved" == "true" ] && echo true || echo false)" \
      --argjson ms "$ms_json" \
      '(.servers[] | select(.ip == $ip)) += {resolution_test: {domain: "google.com", resolved: $resolved, response_ms: $ms}}' \
      "$json_file" > "$json_file.tmp" 2>/dev/null && mv "$json_file.tmp" "$json_file" || true
    idx=$(( idx + 1 ))
  done
  echo
}

detect_dns_servers() {
  scan_servers_by_ports \
    "DNS Network Scan" \
    "DNS" \
    "53" \
    "dns-scan.json"
  local json_file
  json_file="$(task_output_path 6 2>/dev/null || true)"
  if json_file_usable "$json_file"; then
    enrich_dns_resolution "$json_file"
  fi
}

detect_ldap_servers() {
  scan_servers_by_ports \
    "LDAP/AD Network Scan" \
    "LDAP/AD" \
    "88,389,636,3268,3269" \
    "ldap-ad-scan.json"
}

enrich_smb_signing() {
  local json_file="$1"
  local smb_hosts=()
  local ip

  # Collect IPs with port 445 open
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && smb_hosts+=("$ip")
  done < <(jq -r '.servers[]? | select(.open_ports[]? | . == 445) | .ip' "$json_file" 2>/dev/null)

  if [[ "${#smb_hosts[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "SMB Signing: checking ${#smb_hosts[@]} host(s) with port 445 open..."

  local nmap_out
  nmap_out="$(nmap -p 445 --script smb2-security-mode --open "${smb_hosts[@]}" 2>/dev/null || true)"

  local current_ip=""
  local signing_required=""

  # Parse nmap output line by line
  while IFS= read -r line; do
    if [[ "$line" =~ ^Nmap\ scan\ report\ for\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      # Flush previous host
      if [[ -n "$current_ip" && -n "$signing_required" ]]; then
        jq \
          --arg ip "$current_ip" \
          --argjson req "$signing_required" \
          '(.servers[] | select(.ip == $ip)) .smb_signing_required = $req' \
          "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
      fi
      current_ip="${BASH_REMATCH[1]}"
      signing_required=""
    elif [[ -n "$current_ip" ]]; then
      if echo "$line" | grep -qi "signing enabled and required"; then
        signing_required="true"
      elif echo "$line" | grep -qi "signing enabled but not required\|signing disabled"; then
        signing_required="false"
      fi
    fi
  done <<< "$nmap_out"

  # Flush last host
  if [[ -n "$current_ip" && -n "$signing_required" ]]; then
    jq \
      --arg ip "$current_ip" \
      --argjson req "$signing_required" \
      '(.servers[] | select(.ip == $ip)) .smb_signing_required = $req' \
      "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
  fi
}

detect_smb_nfs_servers() {
  scan_servers_by_ports \
    "SMB/NFS Network Scan" \
    "SMB/NFS" \
    "111,139,445,2049" \
    "smb-nfs-scan.json"
  local json_file
  json_file="$(task_output_path 8 2>/dev/null || true)"
  if json_file_usable "$json_file"; then
    enrich_smb_signing "$json_file"
  fi
}

detect_print_servers() {
  scan_servers_by_ports \
    "Printer/Print Server Network Scan" \
    "Printer/Print Server" \
    "515,631,9100" \
    "print-server-scan.json"
}

vlan_trunk_scan() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  local tmp_pcap_tagged
  local tmp_pcap_cdp_lldp
  local tmp_py
  local tmp_raw_tagged
  local tmp_raw_cdp_lldp
  local tagged_result
  local cdp_lldp_result
  local tagged_frames_observed=false
  local observed_vlan_ids="[]"
  local cdp_neighbours="[]"
  local lldp_neighbours="[]"
  local indicators_trunk=false
  local indicators_cdp=false
  local indicators_multi_vlan=false
  local warnings=()
  local warnings_json="[]"
  local status="success"
  local success=true
  local cdp_pid
  local tagged_pid

  json_file="$(task_output_path 11)"

  echo
  echo "VLAN / Trunk Detection"
  echo "======================"

  if [[ -z "$iface" ]]; then
    jq -n '{status:"failed",success:false,error:{code:"NO_INTERFACE",message:"No network interface selected."},warnings:[]}' > "$json_file"
    echo "No interface selected. Skipping."
    return 1
  fi

  tmp_pcap_tagged="$(mktemp /tmp/lss-vlan-tagged-XXXXXX.pcap)"
  tmp_pcap_cdp_lldp="$(mktemp /tmp/lss-vlan-cdp-XXXXXX.pcap)"
  tmp_py="$(mktemp /tmp/lss-vlan-py-XXXXXX)"
  tmp_raw_tagged="$(mktemp /tmp/lss-vlan-raw-tagged-XXXXXX.txt)"
  tmp_raw_cdp_lldp="$(mktemp /tmp/lss-vlan-raw-cdp-XXXXXX.txt)"

  # Step 1: Passive 802.1Q frame capture (10 seconds)
  echo "Step 1/2: Capturing 802.1Q tagged frames on ${iface} (10s)..."
  tcpdump -i "$iface" -w "$tmp_pcap_tagged" -q ether proto 0x8100 2>/dev/null &
  tagged_pid=$!
  sleep 10
  kill "$tagged_pid" 2>/dev/null || true
  wait "$tagged_pid" 2>/dev/null || true

  # Parse tagged frames
  cat > "$tmp_py" <<'PYEOF'
import sys, json
try:
    from scapy.all import rdpcap, Dot1Q
    pkts = rdpcap(sys.argv[1])
    tagged = [p for p in pkts if p.haslayer(Dot1Q)]
    vlan_ids = sorted(set(p[Dot1Q].vlan for p in tagged))
    print(json.dumps({"tagged_frames_observed": len(tagged) > 0, "observed_vlan_ids": vlan_ids, "frame_count": len(tagged)}))
except Exception as e:
    print(json.dumps({"tagged_frames_observed": False, "observed_vlan_ids": [], "frame_count": 0, "parse_error": str(e)}))
PYEOF
  tagged_result="$(python3 "$tmp_py" "$tmp_pcap_tagged" 2>/dev/null || echo '{"tagged_frames_observed":false,"observed_vlan_ids":[],"frame_count":0}')"
  tagged_frames_observed="$(jq -r '.tagged_frames_observed // false' <<< "$tagged_result")"
  observed_vlan_ids="$(jq -c '.observed_vlan_ids // []' <<< "$tagged_result")"

  if [[ "$tagged_frames_observed" == "true" ]]; then
    echo "  Tagged frames observed. VLAN IDs: $(jq -r '.observed_vlan_ids | map(tostring) | join(", ")' <<< "$tagged_result")"
  else
    echo "  No 802.1Q tagged frames observed."
    warnings+=("No 802.1Q tagged frames were observed during the passive capture window. The port may be configured as an untagged access port.")
  fi

  # Write raw tagged frame summary
  {
    echo "=== 802.1Q Tagged Frame Capture ==="
    echo "Interface: ${iface}"
    echo "Capture Duration: 10 seconds"
    echo ""
    python3 - "$tmp_pcap_tagged" <<'PYEOF'
import sys
try:
    from scapy.all import rdpcap, Dot1Q
    pkts = rdpcap(sys.argv[1])
    tagged = [p for p in pkts if p.haslayer(Dot1Q)]
    print(f"Total frames captured: {len(pkts)}")
    print(f"Tagged frames (802.1Q): {len(tagged)}")
    for i, p in enumerate(tagged[:50]):
        print(f"  Frame {i+1}: VLAN {p[Dot1Q].vlan} | Priority {p[Dot1Q].prio} | DEI {p[Dot1Q].id} | Type 0x{p[Dot1Q].type:04x}")
except Exception as e:
    print(f"Parse error: {e}")
PYEOF
  } > "$tmp_raw_tagged" 2>&1 || true

  # Step 2: CDP and LLDP capture (65 seconds)
  echo "Step 2/2: Capturing CDP and LLDP neighbour frames on ${iface} (65s)..."
  echo "  (CDP advertises every 60s — this window ensures at least one full cycle is observed.)"
  tcpdump -i "$iface" -w "$tmp_pcap_cdp_lldp" -q \
    '(ether host 01:00:0c:cc:cc:cc) or (ether proto 0x88cc)' 2>/dev/null &
  cdp_pid=$!
  sleep 65
  kill "$cdp_pid" 2>/dev/null || true
  wait "$cdp_pid" 2>/dev/null || true

  # Parse CDP and LLDP with scapy
  cat > "$tmp_py" <<'PYEOF'
import sys, json

result = {"cdp_neighbours": [], "lldp_neighbours": [], "raw_frame_count": 0}

def safe_decode(val):
    if val is None:
        return ""
    if isinstance(val, (bytes, bytearray)):
        return val.decode("utf-8", errors="replace").strip()
    return str(val).strip()

try:
    from scapy.all import rdpcap
    pkts = rdpcap(sys.argv[1])
    result["raw_frame_count"] = len(pkts)

    seen_cdp = set()
    seen_lldp = set()

    for pkt in pkts:
        # CDP
        try:
            from scapy.contrib.cdp import CDPv2_HDR
            if pkt.haslayer(CDPv2_HDR):
                neighbour = {"device_id": "", "platform": "", "port_id": "", "native_vlan": None, "vtp_domain": "", "duplex": ""}
                layer = pkt[CDPv2_HDR].payload
                while layer and layer.__class__.__name__ != "NoPayload":
                    name = layer.__class__.__name__
                    try:
                        if "DeviceID" in name:
                            neighbour["device_id"] = safe_decode(getattr(layer, "val", ""))
                        elif "Platform" in name:
                            neighbour["platform"] = safe_decode(getattr(layer, "val", ""))
                        elif "PortID" in name:
                            neighbour["port_id"] = safe_decode(getattr(layer, "val", ""))
                        elif "NativeVLAN" in name:
                            neighbour["native_vlan"] = int(getattr(layer, "vlan", 0))
                        elif "VTP" in name:
                            neighbour["vtp_domain"] = safe_decode(getattr(layer, "val", ""))
                        elif "Duplex" in name:
                            neighbour["duplex"] = "full" if getattr(layer, "duplex", False) else "half"
                    except Exception:
                        pass
                    try:
                        layer = layer.payload
                    except Exception:
                        break
                key = neighbour["device_id"]
                if key and key not in seen_cdp:
                    seen_cdp.add(key)
                    result["cdp_neighbours"].append(neighbour)
        except Exception:
            pass

        # LLDP
        try:
            from scapy.contrib.lldp import LLDPDU
            if pkt.haslayer(LLDPDU):
                neighbour = {"system_name": "", "chassis_id": "", "port_id": "", "system_description": ""}
                layer = pkt[LLDPDU]
                while layer and layer.__class__.__name__ != "NoPayload":
                    name = layer.__class__.__name__
                    try:
                        if "SystemName" in name:
                            neighbour["system_name"] = safe_decode(getattr(layer, "system_name", getattr(layer, "value", "")))
                        elif "ChassisID" in name:
                            neighbour["chassis_id"] = safe_decode(getattr(layer, "id", ""))
                        elif "PortID" in name:
                            neighbour["port_id"] = safe_decode(getattr(layer, "id", ""))
                        elif "SystemDescription" in name:
                            neighbour["system_description"] = safe_decode(getattr(layer, "description", getattr(layer, "value", "")))
                    except Exception:
                        pass
                    try:
                        layer = layer.payload
                    except Exception:
                        break
                key = neighbour.get("chassis_id") or neighbour.get("system_name")
                if key and key not in seen_lldp:
                    seen_lldp.add(key)
                    result["lldp_neighbours"].append(neighbour)
        except Exception:
            pass

except Exception as e:
    result["parse_error"] = str(e)

print(json.dumps(result))
PYEOF
  cdp_lldp_result="$(python3 "$tmp_py" "$tmp_pcap_cdp_lldp" 2>/dev/null || echo '{"cdp_neighbours":[],"lldp_neighbours":[],"raw_frame_count":0}')"
  cdp_neighbours="$(jq -c '.cdp_neighbours // []' <<< "$cdp_lldp_result")"
  lldp_neighbours="$(jq -c '.lldp_neighbours // []' <<< "$cdp_lldp_result")"

  local cdp_count lldp_count vlan_count
  cdp_count="$(jq 'length' <<< "$cdp_neighbours")"
  lldp_count="$(jq 'length' <<< "$lldp_neighbours")"
  vlan_count="$(jq 'length' <<< "$observed_vlan_ids")"

  if [[ "$cdp_count" -gt 0 ]]; then
    echo "  CDP neighbours found: ${cdp_count}"
    jq -r '.[] | "    - " + .device_id + " (" + .platform + ") port " + .port_id' <<< "$cdp_neighbours" || true
  fi
  if [[ "$lldp_count" -gt 0 ]]; then
    echo "  LLDP neighbours found: ${lldp_count}"
    jq -r '.[] | "    - " + .system_name + " chassis " + .chassis_id' <<< "$lldp_neighbours" || true
  fi
  if [[ "$cdp_count" -eq 0 && "$lldp_count" -eq 0 ]]; then
    echo "  No CDP or LLDP neighbour frames received."
    warnings+=("No CDP or LLDP neighbour frames were received in the 65s capture window. The upstream switch may have neighbour discovery disabled on this port, or it may be a non-Cisco/non-standard device.")
  fi

  # Write raw CDP/LLDP summary
  {
    echo "=== CDP / LLDP Capture ==="
    echo "Interface: ${iface}"
    echo "Capture Duration: 65 seconds"
    echo ""
    python3 - "$tmp_pcap_cdp_lldp" <<'PYEOF'
import sys
try:
    from scapy.all import rdpcap
    pkts = rdpcap(sys.argv[1])
    print(f"Total frames captured: {len(pkts)}")
    for i, p in enumerate(pkts[:100]):
        print(f"  Frame {i+1}: {p.summary()}")
except Exception as e:
    print(f"Parse error: {e}")
PYEOF
  } > "$tmp_raw_cdp_lldp" 2>&1 || true

  # Compute indicators
  [[ "$tagged_frames_observed" == "true" ]] && indicators_trunk=true
  [[ "$cdp_count" -gt 0 || "$lldp_count" -gt 0 ]] && indicators_cdp=true
  [[ "$vlan_count" -gt 1 ]] && indicators_multi_vlan=true

  # Build warnings JSON
  local w
  for w in "${warnings[@]}"; do
    warnings_json="$(jq -n --argjson arr "$warnings_json" --arg m "$w" '$arr + [$m]')"
  done

  # Determine status
  if [[ "$tagged_frames_observed" == "false" && "$cdp_count" -eq 0 && "$lldp_count" -eq 0 ]]; then
    status="completed_with_warnings"
  fi

  # Write JSON output
  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg iface "$iface" \
    --argjson tagged_frames_observed "$tagged_frames_observed" \
    --argjson observed_vlan_ids "$observed_vlan_ids" \
    --argjson cdp_neighbours "$cdp_neighbours" \
    --argjson lldp_neighbours "$lldp_neighbours" \
    --argjson warnings "$warnings_json" \
    --argjson ind_trunk "$indicators_trunk" \
    --argjson ind_cdp "$indicators_cdp" \
    --argjson ind_multi "$indicators_multi_vlan" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
      interface: $iface,
      tagged_frames_observed: $tagged_frames_observed,
      observed_vlan_ids: $observed_vlan_ids,
      cdp_neighbours: $cdp_neighbours,
      lldp_neighbours: $lldp_neighbours,
      double_tag_probe: {attempted: false, vulnerable: null},
      indicators: {
        trunk_port_suspected: $ind_trunk,
        cdp_exposed: $ind_cdp,
        multiple_vlans_visible: $ind_multi
      }
    }' > "$json_file"

  validate_json_file "$json_file"

  # Save raw artifacts
  copy_raw_artifact "$tmp_raw_tagged" "$(current_raw_output_dir)/task-11-tagged-frames.txt"
  copy_raw_artifact "$tmp_raw_cdp_lldp" "$(current_raw_output_dir)/task-11-cdp-lldp.txt"
  copy_raw_artifact "$tmp_pcap_tagged" "$(current_raw_output_dir)/task-11-tagged.pcap"
  copy_raw_artifact "$tmp_pcap_cdp_lldp" "$(current_raw_output_dir)/task-11-cdp-lldp.pcap"

  # Cleanup temp files
  rm -f "$tmp_pcap_tagged" "$tmp_pcap_cdp_lldp" "$tmp_py" "$tmp_raw_tagged" "$tmp_raw_cdp_lldp" 2>/dev/null || true
}

duplicate_ip_detection() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  local network
  local raw_file
  local scan_output
  local tmp_py
  local duplicate_count=0
  local total_hosts=0
  local duplicates_json="[]"
  local warnings=()
  local warnings_json="[]"
  local status="success"
  local success=true

  json_file="$(task_output_path 12)"

  echo
  echo "Duplicate IP Detection"
  echo "======================"

  if [[ -z "$iface" ]]; then
    jq -n '{status:"failed",success:false,error:{code:"NO_INTERFACE",message:"No network interface selected."},warnings:[],network:null,interface:null,total_hosts_seen:0,duplicate_count:0,duplicates:[]}' > "$json_file"
    echo "No interface selected. Skipping."
    return 1
  fi

  if ! hash arp-scan 2>/dev/null; then
    echo "Error: arp-scan is not installed."
    echo "  macOS: brew install arp-scan"
    echo "  Linux: apt install arp-scan  /  yum install arp-scan"
    jq -n \
      --arg iface "$iface" \
      '{status:"failed",success:false,error:{code:"NO_ARP_SCAN",message:"arp-scan is not installed. Install it with: brew install arp-scan (macOS) or apt/yum install arp-scan (Linux)."},warnings:[],network:null,interface:$iface,total_hosts_seen:0,duplicate_count:0,duplicates:[]}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi

  network="$(get_interface_network_cidr "$iface")"
  if [[ -z "$network" ]]; then
    echo "Error: Unable to determine network range for $iface."
    jq -n \
      --arg iface "$iface" \
      '{status:"failed",success:false,error:{code:"NO_NETWORK",message:"Unable to determine network range for the selected interface."},warnings:[],network:null,interface:$iface,total_hosts_seen:0,duplicate_count:0,duplicates:[]}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi

  echo "Interface:  $iface"
  echo "Network:    $network"
  echo "Scanning for duplicate IPs using ARP (may take 10-30 seconds)..."

  raw_file="$(current_raw_output_dir)/duplicate-ip-arp-scan.txt"
  scan_output="$(arp-scan --interface="$iface" --localnet 2>/dev/null || true)"
  echo "$scan_output" > "$raw_file"

  tmp_py="$(mktemp /tmp/lss-dupip-XXXXXX)"
  cat > "$tmp_py" <<'PYEOF'
import sys, json, re, collections

lines = sys.stdin.read().splitlines()
ip_macs    = collections.OrderedDict()
ip_vendors = collections.OrderedDict()

for line in lines:
    parts = line.split('\t')
    if len(parts) < 2:
        continue
    ip = parts[0].strip()
    if not ip or not ip[0].isdigit():
        continue
    mac    = parts[1].strip() if len(parts) > 1 else ""
    vendor = parts[2].strip() if len(parts) > 2 else ""
    vendor = re.sub(r'\s*\(DUP:\s*\d+\)', '', vendor).strip()
    if ip not in ip_macs:
        ip_macs[ip]    = []
        ip_vendors[ip] = []
    if mac not in ip_macs[ip]:
        ip_macs[ip].append(mac)
        ip_vendors[ip].append(vendor)

duplicates = []
for ip, macs in ip_macs.items():
    if len(macs) > 1:
        duplicates.append({"ip": ip, "macs": macs, "vendors": ip_vendors[ip]})

print(json.dumps({
    "total_hosts_seen": len(ip_macs),
    "duplicate_count":  len(duplicates),
    "duplicates":        duplicates,
}))
PYEOF

  local py_result
  py_result="$(echo "$scan_output" | python3 "$tmp_py" 2>/dev/null || echo '{"total_hosts_seen":0,"duplicate_count":0,"duplicates":[]}')"
  rm -f "$tmp_py"

  total_hosts="$(jq -r '.total_hosts_seen // 0'  <<< "$py_result")"
  duplicate_count="$(jq -r '.duplicate_count  // 0'  <<< "$py_result")"
  duplicates_json="$(jq -c '.duplicates      // []' <<< "$py_result")"

  echo "Hosts seen: $total_hosts"
  if [[ "$duplicate_count" -gt 0 ]]; then
    echo "WARNING: $duplicate_count duplicate IP(s) detected!"
    jq -r '.duplicates[] | "  " + .ip + "  →  " + (.macs | join(", "))' <<< "$py_result"
    warnings+=("$duplicate_count IP address(es) responded to ARP from more than one MAC address, indicating an IP conflict or ARP spoofing.")
    status="completed_with_warnings"
  else
    echo "No duplicate IPs detected."
  fi

  warnings_json="$(printf '%s\n' "${warnings[@]+"${warnings[@]}"}" | jq -Rs '[split("\n")[] | select(length > 0)]')"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg iface "$iface" \
    --arg network "$network" \
    --argjson total_hosts "$total_hosts" \
    --argjson duplicate_count "$duplicate_count" \
    --argjson duplicates "$duplicates_json" \
    --argjson warnings "$warnings_json" \
    '{
      status:           $status,
      success:          $success,
      error:            null,
      warnings:         $warnings,
      interface:        $iface,
      network:          $network,
      total_hosts_seen: $total_hosts,
      duplicate_count:  $duplicate_count,
      duplicates:       $duplicates
    }' > "$json_file"

  validate_json_file "$json_file"
  return 0
}


ports_to_json_array() {
  local values=("$@")
  local json=""
  local i

  for i in "${!values[@]}"; do
    if [[ "$i" -gt 0 ]]; then
      json+=", "
    fi
    json+="${values[$i]}"
  done

  echo "[$json]"
}

ports_to_csv() {
  local values=("$@")
  local joined=""
  local i

  if [[ "${#values[@]}" -eq 0 ]]; then
    echo "none found"
    return
  fi

  for i in "${!values[@]}"; do
    if [[ "$i" -gt 0 ]]; then
      joined+=", "
    fi
    joined+="${values[$i]}"
  done

  echo "$joined"
}

extract_grepable_open_ports_csv() {
  local file="$1"

  awk '
    /Ports:/ {
      split($0, parts, "Ports: ")
      if (length(parts) < 2) {
        next
      }

      n = split(parts[2], ports, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", ports[i])
        split(ports[i], fields, "/")
        if (fields[2] == "open" && fields[1] ~ /^[0-9]+$/) {
          if (!(fields[1] in seen)) {
            seen[fields[1]] = 1
            order[++count] = fields[1]
          }
        }
      }
    }
    END {
      for (i = 1; i <= count; i++) {
        if (i > 1) {
          printf ", "
        }
        printf "%s", order[i]
      }
    }
  ' "$file"
}

extract_grepable_host_port_matches_csv() {
  local file="$1"

  awk '
    /Host: / && /Ports: / {
      ip = ""
      if (match($0, /Host: [0-9.]+/)) {
        ip = substr($0, RSTART + 6, RLENGTH - 6)
      }
      if (ip == "") {
        next
      }

      split($0, parts, "Ports: ")
      if (length(parts) < 2) {
        next
      }

      n = split(parts[2], p, ",")
      open = ""
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", p[i])
        split(p[i], f, "/")
        if (f[2] == "open" && f[1] ~ /^[0-9]+$/) {
          if (open != "") {
            open = open ","
          }
          open = open f[1]
        }
      }

      if (open != "") {
        latest[ip] = open
        if (!(ip in seen)) {
          seen[ip] = 1
          order[++count] = ip
        }
      }
    }
    END {
      for (i = 1; i <= count; i++) {
        ip = order[i]
        if (i > 1) {
          printf ", "
        }
        printf "%s(%s)", ip, latest[ip]
      }
    }
  ' "$file"
}

monitor_nmap_progress() {
  local pid="$1"
  local output_file="$2"
  local timeout_seconds="$3"
  local mode="$4"
  local label="$5"
  local error_message="$6"
  local start_time elapsed
  local final_display=""

  start_time="$(date +%s)"

  if [[ "$DEBUG_MODE" -eq 0 ]]; then
    start_spinner_line "$label"
  fi

  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= timeout_seconds )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      stop_spinner_line
      echo "Port scan timed out after ${timeout_seconds}s."
      return 124
    fi

    sleep 0.2
  done

  local process_exit_code=0
  if ! wait "$pid"; then
    process_exit_code=$?
  fi

  stop_spinner_line

  if [[ "$mode" == "host_ports" ]]; then
    final_display="$(extract_grepable_host_port_matches_csv "$output_file")"
  else
    final_display="$(extract_grepable_open_ports_csv "$output_file")"
  fi

  if [[ -n "$final_display" ]]; then
    echo "$label $final_display"
  elif [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "$label none found"
  fi

  if [[ "$process_exit_code" -ne 0 ]]; then
    echo "$error_message"
    return "$process_exit_code"
  fi

  return 0
}

spinner() {
  local pid=$!
  local message="${1:-Scanning...}"
  local i=0
  local -a spin_frames
  local _indent="${TASK_OUTPUT_INDENT:-}"

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "$message"
    wait "$pid"
    return
  fi

  if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"UTF-8"* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"utf8"* ]]; then
    spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  else
    spin_frames=("-" "\\" "|" "/")
  fi

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s[%s] %s" "$_indent" "${spin_frames[$i]}" "$message" >&2
    i=$(( (i + 1) % ${#spin_frames[@]} ))
    sleep 0.2
  done
  printf "\r\033[K" >&2
}

start_spinner_line() {
  local label="$1"
  local i=0
  local -a spin_frames
  local _indent="${TASK_OUTPUT_INDENT:-}"

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "$label"
    return
  fi

  if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"UTF-8"* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"utf8"* ]]; then
    spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  else
    spin_frames=("-" "\\" "|" "/")
  fi

  (
    while true; do
      printf "\r%s%s %s" "$_indent" "$label" "${spin_frames[$i]}" >&2
      i=$(( (i + 1) % ${#spin_frames[@]} ))
      sleep 0.2
    done
  ) &
  SPINNER_PID=$!
}

stop_spinner_line() {
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    return
  fi

  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1
    wait "$SPINNER_PID" 2>/dev/null
    SPINNER_PID=""
  fi

  printf "\r\033[K" >&2
}

run_with_stage_spinner() {
  local pid="$1"
  local timeout_seconds="$2"
  local start_time elapsed

  start_time="$(date +%s)"
  start_spinner_line "Processing results..."

  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= timeout_seconds )); then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      stop_spinner_line
      printf "%s\n" "Speedtest timed out after ${timeout_seconds}s."
      return 124
    fi
    sleep 0.2
  done

  local process_exit_code=0
  if ! wait "$pid"; then
    process_exit_code=$?
  fi
  stop_spinner_line

  if [[ "$process_exit_code" -eq 0 ]]; then
    echo "Processing results... done."
  fi

  return "$process_exit_code"
}

monitor_speedtest_progress() {
  local pid="$1"
  local output_file="$2"
  local timeout_seconds="$3"
  local green='\033[0;32m'
  local reset='\033[0m'
  local start_time elapsed
  local public_ip=""
  local isp_name=""
  local server_name=""
  local ping_latency=""
  local download_speed=""
  local upload_speed=""
  local info_printed=0
  local download_spinner_active=0
  local upload_spinner_active=0
  local hosted_line hosted_server hosted_ping

  start_time="$(date +%s)"

  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= timeout_seconds )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      stop_spinner_line
      echo "Speedtest timed out after ${timeout_seconds}s."
      return 124
    fi

    if [[ -z "$public_ip" ]]; then
      public_ip="$(sed -nE 's/^Testing from .* \(([0-9.]+)\)\.\.\./\1/p' "$output_file" | tail -n 1)"
      isp_name="$(sed -nE 's/^Testing from (.*) \([0-9.]+\)\.\.\./\1/p' "$output_file" | tail -n 1)"
    fi

    if [[ -z "$server_name" || -z "$ping_latency" ]]; then
      hosted_line="$(sed -nE 's/^Hosted by (.*): ([0-9]+([.][0-9]+)?) ms$/\1|\2/p' "$output_file" | tail -n 1)"
      if [[ -n "$hosted_line" ]]; then
        hosted_server="${hosted_line%|*}"
        hosted_ping="${hosted_line##*|}"
        hosted_server="$(printf '%s' "$hosted_server" | sed 's/ \[[^]]*\]$//')"
        [[ -n "$hosted_server" ]] && server_name="$hosted_server"
        [[ -n "$hosted_ping" ]] && ping_latency="$hosted_ping"
      fi
    fi

    if [[ "$info_printed" -eq 0 && -n "$public_ip" && -n "$server_name" && -n "$ping_latency" ]]; then
      echo
      echo "Public IP: $public_ip"
      [[ -n "$isp_name" ]] && echo "ISP: $isp_name"
      echo "Connected to server: $server_name"
      echo "Ping: $ping_latency ms"
      if [[ "$DEBUG_MODE" -eq 0 ]]; then
        start_spinner_line "Download Speed:"
      fi
      download_spinner_active=1
      info_printed=1
    fi

    if [[ -z "$download_speed" ]]; then
      download_speed="$(sed -nE 's/^Download:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' "$output_file" | tail -n 1)"
    fi

    if [[ "$download_spinner_active" -eq 1 && -n "$download_speed" ]]; then
      stop_spinner_line
      echo "Download Speed: ${download_speed} Mbps"
      if [[ "$DEBUG_MODE" -eq 0 ]]; then
        start_spinner_line "Upload Speed:"
      fi
      download_spinner_active=0
      upload_spinner_active=1
    fi

    if [[ -z "$upload_speed" ]]; then
      upload_speed="$(sed -nE 's/^Upload:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' "$output_file" | tail -n 1)"
    fi

    if [[ "$upload_spinner_active" -eq 1 && -n "$upload_speed" ]]; then
      stop_spinner_line
      echo "Upload Speed: ${upload_speed} Mbps"
      upload_spinner_active=0
    fi

    sleep 0.2
  done

  local process_exit_code=0
  if ! wait "$pid"; then
    process_exit_code=$?
  fi

  stop_spinner_line

  if [[ "$process_exit_code" -ne 0 ]]; then
    return "$process_exit_code"
  fi

  if [[ -z "$download_speed" ]]; then
    download_speed="$(sed -nE 's/^Download:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' "$output_file" | tail -n 1)"
  fi

  if [[ -z "$upload_speed" ]]; then
    upload_speed="$(sed -nE 's/^Upload:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' "$output_file" | tail -n 1)"
  fi

  if [[ "$info_printed" -eq 0 ]]; then
    [[ -n "$public_ip" ]] && echo "Public IP: $public_ip"
    [[ -n "$isp_name" ]] && echo "ISP: $isp_name"
    [[ -n "$server_name" ]] && echo "Connected to server: $server_name"
    [[ -n "$ping_latency" ]] && echo "Ping: $ping_latency ms"
  fi

  if [[ "$download_spinner_active" -eq 1 && -n "$download_speed" ]]; then
    echo "Download Speed: ${download_speed} Mbps"
  fi

  if [[ "$upload_spinner_active" -eq 1 && -n "$upload_speed" ]]; then
    echo "Upload Speed: ${upload_speed} Mbps"
  fi

  return 0
}

render_speed_test_report() {
  local file="$1"
  local report_file="$2"
  local server location download upload public_ip isp_name ping
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"

  if jq -e '.servers and (.servers | type == "array") and (.servers | length > 0)' "$file" >/dev/null 2>&1; then
    public_ip="$(jq -r '.servers[0].public_ip // "unknown"' "$file" 2>/dev/null)"
    isp_name="$(jq -r '.servers[0].isp_name // empty' "$file" 2>/dev/null)"
    server="$(jq -r '.servers[0].test_server // "unknown"' "$file" 2>/dev/null)"
    location="$(jq -r '.servers[0].location // empty' "$file" 2>/dev/null)"
    ping="$(jq -r '(.servers[0].ping_ms // "unavailable")' "$file" 2>/dev/null)"
    download="$(jq -r 'if .servers[0].download_mbps then .servers[0].download_mbps else empty end' "$file" 2>/dev/null | awk '{printf "%.2f Mbps", $1}')"
    upload="$(jq -r 'if .servers[0].upload_mbps then .servers[0].upload_mbps else empty end' "$file" 2>/dev/null | awk '{printf "%.2f Mbps", $1}')"
  else
    public_ip="$(jq -r '.client.ip // "unknown"' "$file" 2>/dev/null)"
    isp_name=""
    server="$(jq -r '.server.name // "unknown"' "$file" 2>/dev/null)"
    location="$(jq -r '.server.location // .server.country // empty' "$file" 2>/dev/null)"
    ping="$(jq -r '(.ping // "unavailable")' "$file" 2>/dev/null)"
    download="$(jq -r 'if .download then (.download / 1000000) else empty end' "$file" 2>/dev/null | awk '{printf "%.2f Mbps", $1}')"
    upload="$(jq -r 'if .upload then (.upload / 1000000) else empty end' "$file" 2>/dev/null | awk '{printf "%.2f Mbps", $1}')"
  fi

  if [[ -n "$location" ]]; then
    server="$server ($location)"
  fi

  {
    echo "Status: ${status:-unknown}"
    [[ -n "$error_code" ]]    && echo "Error Code: $error_code"
    [[ -n "$error_message" ]] && echo "Error Message: $error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && echo "Warnings: $warning_count"
    echo "Public IP: ${public_ip:-unknown}"
    [[ -n "$isp_name" ]] && echo "ISP: ${isp_name}"
    echo "Connected to server: ${server:-unknown}"
    echo "Ping: ${ping:-unavailable} ms"
    echo "Download Speed: ${download:-unavailable}"
    echo "Upload Speed: ${upload:-unavailable}"
  } >> "$report_file"
}

write_speed_test_json() {
  local status="$1"
  local success="$2"
  local error_code="$3"
  local error_message="$4"
  local public_ip="$5"
  local isp_name="$6"
  local server_name="$7"
  local server_location="$8"
  local ping_latency="$9"
  local download_speed="${10}"
  local upload_speed="${11}"
  shift 11
  local warnings=("$@")
  local warnings_json

  warnings_json="$(json_string_array_from_array warnings)"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --arg public_ip "$public_ip" \
    --arg isp_name "$isp_name" \
    --arg server_name "$server_name" \
    --arg location "$server_location" \
    --arg ping_latency "$ping_latency" \
    --arg download_speed "$download_speed" \
    --arg upload_speed "$upload_speed" \
    --argjson warnings "$warnings_json" \
    '{
      status: $status,
      success: $success,
      error: (if $error_code == "" and $error_message == "" then null else {code: $error_code, message: $error_message} end),
      warnings: $warnings,
      speed_tests_found: (if $success then 1 else 0 end),
      servers: [
        {
          public_ip: $public_ip,
          isp_name: (if $isp_name == "" then null else $isp_name end),
          test_server: $server_name,
          location: $location,
          ping_ms: (if $ping_latency == "" or $ping_latency == "unavailable" then null else ($ping_latency | tonumber) end),
          download_mbps: (if $download_speed == "" or $download_speed == "unavailable" then null else ($download_speed | tonumber) end),
          upload_mbps: (if $upload_speed == "" or $upload_speed == "unavailable" then null else ($upload_speed | tonumber) end),
          timestamp: ""
        }
      ],
      methodology: "Single point-in-time measurement using speedtest-cli. Results may vary with network congestion and time of day. Run multiple tests for a representative baseline."
    }' > "$(task_output_path 2)"

  validate_json_file "$(task_output_path 2)"
}

write_gateway_scan_json() {
  local status="$1"
  local success="$2"
  local error_code="$3"
  local error_message="$4"
  local gateway_ip="$5"
  shift 5
  local rest=("$@")
  local split_index=-1
  local i
  local ports=()
  local warnings=()
  local warnings_json

  for ((i=0; i<${#rest[@]}; i++)); do
    if [[ "${rest[$i]}" == "__WARNINGS__" ]]; then
      split_index="$i"
      break
    fi
  done

  if (( split_index >= 0 )); then
    ports=("${rest[@]:0:split_index}")
    warnings=("${rest[@]:$((split_index + 1))}")
  else
    ports=(${rest[@]+"${rest[@]}"})
  fi

  warnings_json="$(json_string_array_from_array warnings)"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --arg gateway_ip "$gateway_ip" \
    --argjson open_ports "$(ports_to_json_array ${ports[@]+"${ports[@]}"})" \
    --argjson warnings "$warnings_json" \
    '{
      status: $status,
      success: $success,
      error: (if $error_code == "" and $error_message == "" then null else {code: $error_code, message: $error_message} end),
      warnings: $warnings,
      gateway_ip: (if $gateway_ip == "" then null else $gateway_ip end),
      open_ports: $open_ports,
      scan_scope: "All TCP ports (1-65535)"
    }' > "$(task_output_path 3)"

  validate_json_file "$(task_output_path 3)"
}

write_dhcp_failure_json() {
  local error_code="$1"
  local error_message="$2"
  local discovery_attempts="${3:-5}"
  local warnings_json='[]'

  jq -n \
    --arg status "failed" \
    --argjson success false \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --argjson discovery_attempts "$discovery_attempts" \
    --argjson warnings "$warnings_json" \
    '{
      status: $status,
      success: $success,
      error: {code: $error_code, message: $error_message},
      warnings: $warnings,
      dhcp_responders_observed: 0,
      discovery_attempts: $discovery_attempts,
      offers_observed: 0,
      raw_offers_observed: 0,
      relay_sources_seen: [],
      tcpdump_capture_used: false,
      rogue_dhcp_suspected: false,
      suspected_rogue_servers: [],
      discovery_note: "",
      raw_attempts: [],
      servers: []
    }' > "$(task_output_path 4)"

  validate_json_file "$(task_output_path 4)"
}

update_dhcp_json_status() {
  local file="$1"
  local status="$2"
  local success="$3"
  local error_code="$4"
  local error_message="$5"
  shift 5
  local warnings=("$@")
  local warnings_json

  warnings_json="$(json_string_array_from_array warnings)"

  jq \
    --arg status "$status" \
    --argjson success "$success" \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --argjson warnings "$warnings_json" \
    '.status = $status
     | .success = $success
     | .error = (if $error_code == "" and $error_message == "" then null else {code: $error_code, message: $error_message} end)
     | .warnings = $warnings' \
    "$file" > "$file.tmp" || return 1

  mv "$file.tmp" "$file"
  validate_json_file "$file"
}

internet_speed_test() {
  local result
  local timeout_seconds=90
  local result_file
  local raw_file
  local pid
  local exit_code
  local public_ip isp_name server_name server_location ping_latency download_speed upload_speed
  local raw_server_name raw_server_location
  local download_display upload_display
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "=============================="
    echo "Running Function: Internet Speed Test"
    echo "=============================="
  fi

  if ! command -v speedtest-cli >/dev/null 2>&1; then
    echo "speedtest-cli not installed."
    echo
    echo "Install instructions:"
    echo
    echo "macOS:"
    echo "brew install speedtest-cli"
    echo
    echo "Linux:"
    echo "apt-get install speedtest-cli"
    echo "or"
    echo "dnf install speedtest-cli"
    if command -v jq >/dev/null 2>&1; then
      write_speed_test_json "failed" "false" "dependency_missing_speedtest_cli" "speedtest-cli is not installed." "unknown" "" "unknown" "" "unavailable" "unavailable" "unavailable"
    fi
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for writing speedtest JSON output."
    return 1
  fi

  result_file="$(mktemp)"
  if [[ -z "$result_file" || ! -f "$result_file" ]]; then
    echo "Unable to create a temporary file for the speed test."
    write_speed_test_json "failed" "false" "tempfile_creation_failed" "Unable to create a temporary file for the speed test." "unknown" "" "unknown" "" "unavailable" "unavailable" "unavailable"
    return 1
  fi
  speedtest-cli --secure > "$result_file" 2>&1 &
  pid=$!
  monitor_speedtest_progress "$pid" "$result_file" "$timeout_seconds"
  exit_code=$?
  result="$(cat "$result_file")"
  raw_file="$(task_raw_prefix 2)-raw.txt"
  printf '%s\n' "$result" > "$raw_file"
  rm -f "$result_file"

  if [[ "$exit_code" -ne 0 ]]; then
    status="failed"
    success="false"
    if [[ "$exit_code" -eq 124 ]]; then
      error_code="speedtest_timeout"
      error_message="The speed test timed out before completing."
    elif printf '%s\n' "$result" | grep -qi 'Unable to connect to servers'; then
      error_code="speedtest_backend_unreachable"
      error_message="The internet connection may still be working, but speedtest-cli could not reach any test server."
    else
      error_code="speedtest_command_failed"
      error_message="speedtest-cli exited with an error."
    fi
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "unknown" "" "unknown" "" "unavailable" "unavailable" "unavailable"
    echo "Speedtest failed. Raw output:"
    echo "$result"
    return 1
  fi

  if ! printf '%s\n' "$result" | grep -q '^Download:'; then
    status="failed"
    success="false"
    error_code="speedtest_output_incomplete"
    error_message="speedtest-cli finished, but the expected download result was not present in the output."
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "unknown" "" "unknown" "" "unavailable" "unavailable" "unavailable"
    echo "Speedtest failed. Raw output:"
    echo "$result"
    return 1
  fi

  public_ip="$(printf '%s\n' "$result" | sed -nE 's/^Testing from .* \(([0-9.]+)\)\.\.\./\1/p' | tail -n 1)"
  isp_name="$(printf '%s\n' "$result" | sed -nE 's/^Testing from (.*) \([0-9.]+\)\.\.\./\1/p' | tail -n 1)"
  raw_server_name="$(printf '%s\n' "$result" | sed -nE 's/^Hosted by (.*): ([0-9]+([.][0-9]+)?) ms$/\1/p' | tail -n 1 | sed 's/ \[[^]]*\]$//')"
  raw_server_location=""
  ping_latency="$(printf '%s\n' "$result" | sed -nE 's/^Hosted by (.*): ([0-9]+([.][0-9]+)?) ms$/\2/p' | tail -n 1)"
  download_speed="$(printf '%s\n' "$result" | sed -nE 's/^Download:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' | tail -n 1)"
  upload_speed="$(printf '%s\n' "$result" | sed -nE 's/^Upload:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' | tail -n 1)"

  [[ -z "$download_speed" ]] && download_speed="unavailable"
  [[ -z "$upload_speed" ]] && upload_speed="unavailable"
  [[ -z "$public_ip" ]] && public_ip="unknown"
  [[ -z "$isp_name" ]] && isp_name=""
  [[ -z "$raw_server_name" ]] && raw_server_name="unknown"
  [[ -z "$ping_latency" ]] && ping_latency="unavailable"

  if [[ "$public_ip" == "unknown" ]]; then
    warnings+=("The public IP address could not be parsed from speedtest-cli output.")
  fi
  if [[ "$raw_server_name" == "unknown" ]]; then
    warnings+=("The test server name could not be parsed from speedtest-cli output.")
  fi
  if [[ "$ping_latency" == "unavailable" ]]; then
    warnings+=("Ping latency was not available in the speedtest output.")
  fi
  if [[ "$download_speed" == "unavailable" ]]; then
    warnings+=("Download speed was not available in the speedtest output.")
  fi
  if [[ "$upload_speed" == "unavailable" ]]; then
    warnings+=("Upload speed was not available in the speedtest output.")
  fi
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    status="completed_with_warnings"
  fi

  server_name="$raw_server_name"
  server_location="$raw_server_location"

  if [[ -n "$server_location" ]]; then
    server_name="$server_name $server_location"
  fi

  download_display="$download_speed Mbps"
  upload_display="$upload_speed Mbps"
  [[ "$download_speed" == "unavailable" ]] && download_display="unavailable"
  [[ "$upload_speed" == "unavailable" ]] && upload_display="unavailable"

  echo

  if [[ "${#warnings[@]}" -gt 0 ]]; then
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "$public_ip" "$isp_name" "$raw_server_name" "$raw_server_location" "$ping_latency" "$download_speed" "$upload_speed" "${warnings[@]}"
  else
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "$public_ip" "$isp_name" "$raw_server_name" "$raw_server_location" "$ping_latency" "$download_speed" "$upload_speed"
  fi

  return 0
}

gateway_details() {
  local iface="$1"
  local gateway_ip
  local ports=()
  local port
  local raw_file
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Gateway Details"
  fi
  echo "Stage 1: Determining gateway for interface $iface..."

  gateway_ip="$(get_gateway_ip "$iface")"
  if [[ -z "$gateway_ip" ]]; then
    status="failed"
    success="false"
    error_code="gateway_not_detected"
    error_message="No default gateway could be determined for the selected interface."
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" ""
    echo "Error: Unable to determine the default gateway for interface $iface."
    echo "Possible causes include no active default route, a disconnected interface, a bridge-only interface, or a host that is not using this interface for its default route."
    return 1
  fi

  echo "Done."
  echo
  echo "Gateway IP: $gateway_ip"
  if ! is_rfc1918_ip "$gateway_ip"; then
    echo "Warning: Gateway IP $gateway_ip is publicly routable."
    echo "This indicates the LAN is directly connected to enterprise or carrier infrastructure"
    echo "(e.g. a Juniper or Cisco core router) without a local firewall or NAT boundary."
    echo "Gateway port scan and stress test have been skipped — these devices actively filter"
    echo "probe traffic and a full scan would time out without useful results."
    jq -n \
      --arg gateway_ip "$gateway_ip" \
      '{
        status: "skipped",
        success: false,
        skip_reason: "gateway_public_ip",
        skip_message: ("Gateway IP " + $gateway_ip + " is publicly routable. The LAN appears to be directly connected to enterprise or carrier infrastructure (e.g. a Juniper or Cisco core router) without a local firewall or NAT boundary. Port scanning and stress testing have been skipped — these devices protect their control plane and actively filter probe traffic, making scan results unreliable."),
        error: null,
        warnings: [],
        gateway_ip: $gateway_ip,
        open_ports: [],
        scan_scope: "All TCP ports (1-65535)"
      }' > "$(task_output_path 3)"
    validate_json_file "$(task_output_path 3)"
    return 0
  fi
  echo
  echo "Stage 2: Scanning gateway ports (this may take up to 1 minute)..."

  local gateway_scan_file
  gateway_scan_file="$(mktemp)"
  if [[ -z "$gateway_scan_file" || ! -f "$gateway_scan_file" ]]; then
    status="failed"
    success="false"
    error_code="tempfile_creation_failed"
    error_message="Unable to create a temporary file for the gateway scan."
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" "$gateway_ip"
    echo "Error: Unable to create a temporary file for the gateway scan."
    return 1
  fi
  raw_file="$(task_raw_prefix 3)-nmap.grep"

  nmap -p- --open -T4 "$gateway_ip" -oG - > "$gateway_scan_file" 2>/dev/null &
  local gateway_scan_pid=$!
  monitor_nmap_progress "$gateway_scan_pid" "$gateway_scan_file" 120 "ports" "Open Ports:" "Gateway port scan failed for $gateway_ip." || {
    status="failed"
    success="false"
    error_code="gateway_port_scan_failed"
    error_message="The gateway port scan did not complete successfully."
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" "$gateway_ip"
    rm -f "$gateway_scan_file"
    return 1
  }
  echo

  copy_raw_artifact "$gateway_scan_file" "$raw_file"

  while IFS= read -r port; do
    [[ -n "$port" ]] && ports+=("$port")
  done < <(awk '
    /Ports:/ {
      split($0, parts, "Ports: ")
      if (length(parts) < 2) {
        next
      }

      n = split(parts[2], ports, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", ports[i])
        split(ports[i], fields, "/")
        if (fields[2] == "open" && fields[1] ~ /^[0-9]+$/) {
          print fields[1]
        }
      }
    }
  ' "$gateway_scan_file")
  rm -f "$gateway_scan_file"

  if [[ "${#ports[@]}" -eq 0 ]]; then
    warnings+=("The gateway responded, but no open TCP ports were detected during the scan.")
    status="completed_with_warnings"
  fi

  if [[ "${#warnings[@]}" -gt 0 ]]; then
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" "$gateway_ip" ${ports[@]+"${ports[@]}"} "__WARNINGS__" "${warnings[@]}"
  else
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" "$gateway_ip" ${ports[@]+"${ports[@]}"}
  fi
}

custom_target_port_scan() {
  local target_ip
  local hostname
  local ports=()
  local port
  local json_file
  local scan_file
  local raw_file
  local entry_index
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()
  local warnings_json

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Custom Target Port Scan"
  fi

  target_ip="$(prompt_for_target_ip "Target IP Address: ")"
  hostname="$(resolve_target_hostname "$target_ip")"
  while IFS= read -r warning; do
    [[ -n "$warning" ]] && warnings+=("$warning")
  done < <(collect_custom_target_warnings "$target_ip" "$SELECTED_INTERFACE")
  echo "Target IP: $target_ip"
  echo "Hostname: $hostname"
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    for warning in "${warnings[@]}"; do
      echo "Warning: $warning"
    done
  fi
  echo
  echo "Stage 1: Scanning all open ports on target (this may take up to 10 minutes)..."

  scan_file="$(mktemp)"
  entry_index="$(next_multi_entry_index 13)"
  raw_file="$(multi_entry_raw_prefix_for_index 13 "$entry_index")-nmap.grep"
  json_file="$(multi_entry_output_path_for_index 13 "$entry_index")"
  if [[ -z "$scan_file" || ! -f "$scan_file" ]]; then
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "tempfile_creation_failed" \
      --arg error_message "Unable to create a temporary file for the custom port scan." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname, scan_type: "custom_target_port_scan", open_ports: []}' > "$json_file"
    validate_json_file "$json_file"
    echo "Error: Unable to create a temporary file for the custom port scan."
    return 1
  fi
  nmap -p- --open -T4 --min-rate 1000 "$target_ip" -oG - > "$scan_file" 2>/dev/null &
  local scan_pid=$!
  monitor_nmap_progress "$scan_pid" "$scan_file" 600 "ports" "Open Ports:" "Custom target port scan failed for $target_ip." || {
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "custom_target_port_scan_failed" \
      --arg error_message "The custom target port scan did not complete successfully." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname, scan_type: "custom_target_port_scan", open_ports: []}' > "$json_file"
    validate_json_file "$json_file"
    rm -f "$scan_file"
    return 1
  }
  echo

  copy_raw_artifact "$scan_file" "$raw_file"

  while IFS= read -r port; do
    [[ -n "$port" ]] && ports+=("$port")
  done < <(awk '
    /Ports:/ {
      split($0, parts, "Ports: ")
      if (length(parts) < 2) {
        next
      }

      n = split(parts[2], raw_ports, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw_ports[i])
        split(raw_ports[i], fields, "/")
        if (fields[2] == "open" && fields[1] ~ /^[0-9]+$/) {
          print fields[1]
        }
      }
    }
  ' "$scan_file")
  rm -f "$scan_file"

  if [[ "${#ports[@]}" -eq 0 ]]; then
    warnings+=("The scan completed, but no open TCP ports were detected on the target.")
    status="completed_with_warnings"
  elif [[ "${#warnings[@]}" -gt 0 ]]; then
    status="completed_with_warnings"
  fi
  warnings_json="$(json_string_array_from_array warnings)"
  jq -n \
    --arg status "$status" \
    --argjson success true \
    --argjson warnings "$warnings_json" \
    --arg target_ip "$target_ip" \
    --arg hostname "$hostname" \
    --argjson open_ports "$(ports_to_json_array ${ports[@]+"${ports[@]}"})" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
      target_ip: $target_ip,
      hostname: $hostname,
      scan_type: "custom_target_port_scan",
      open_ports: $open_ports
    }' > "$json_file"

  validate_json_file "$json_file"
}

guess_device_type_from_identity() {
  local combined="$1"
  local vendor="$2"
  local hostname="$3"
  local lowered

  lowered="$(printf '%s %s %s' "$combined" "$vendor" "$hostname" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lowered" == *shelly* || "$lowered" == *espressif* ]]; then
    echo "iot-device-or-smart-relay"
    return
  fi

  case "$lowered" in
    *opnsense*|*pfsense*|*unbound*|*tomcat*|*firewall*|*routeros*|*mikrotik*|*fortinet*|*sonicwall*)
      echo "firewall-or-router"
      ;;
    *netgear*|*gs110tp*|*gs*switch*|*switch*)
      echo "network-switch"
      ;;
    *asus*|*asuswrt*|*mesh*|*access\ point*|*wireless\ router*|*wifi*)
      echo "access-point-or-router"
      ;;
    *printer*|*ipp*|*jetdirect*|*cups*)
      echo "printer"
      ;;
    *samba*|*microsoft-ds*|*netbios*|*synology*|*qnap*|*nfs*)
      echo "nas-or-file-server"
      ;;
    *microsoft*|*windows*|*winrm*|*rdp*)
      echo "windows-host"
      ;;
    *openssh*|*ubuntu*|*debian*|*apache*|*nginx*|*linux*)
      echo "linux-host"
      ;;
    *camera*|*rtsp*|*onvif*|*hikvision*|*dahua*)
      echo "camera-or-nvr"
      ;;
    *cisco*|*aruba*|*ubiquiti*|*unifi*|*wireless*)
      echo "network-device"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

guess_identity_confidence() {
  local combined="$1"
  local vendor="$2"
  local hostname="$3"
  local device_type="$4"
  local lowered

  lowered="$(printf '%s %s %s' "$combined" "$vendor" "$hostname" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lowered" == *openssh* && "$lowered" == *unbound* && "$lowered" == *tomcat* ]]; then
    echo "high"
    return
  fi

  case "$lowered" in
    *opnsense*|*pfsense*|*netgear*|*gs110tp*|*asus*|*unifi*|*aruba*|*fortinet*|*sonicwall*|*shelly*|*espressif*)
      echo "high"
      return
      ;;
  esac

  case "$device_type" in
    firewall-or-router|network-switch|access-point-or-router|printer|nas-or-file-server|camera-or-nvr|iot-device-or-smart-relay)
      echo "medium"
      ;;
    *)
      echo "low"
      ;;
  esac
}

build_identity_summary() {
  local vendor="$1"
  local device_type="$2"
  local combined="$3"
  local lowered

  lowered="$(printf '%s %s' "$vendor" "$combined" | tr '[:upper:]' '[:lower:]')"

  case "$lowered" in
    *opnsense*)
      echo "Likely OPNsense firewall"
      return
      ;;
    *pfsense*)
      echo "Likely pfSense firewall"
      return
      ;;
    *netgear*|*gs110tp*)
      echo "Likely Netgear switch"
      return
      ;;
    *asus*|*mesh*)
      echo "Likely Asus mesh AP or router"
      return
      ;;
    *shelly*|*espressif*)
      echo "Likely Shelly or Espressif-based IoT device"
      return
      ;;
  esac

  case "$device_type" in
    firewall-or-router) echo "Likely firewall or router appliance" ;;
    network-switch) echo "Likely managed switch" ;;
    access-point-or-router) echo "Likely access point or router" ;;
    iot-device-or-smart-relay) echo "Likely IoT device or smart relay" ;;
    printer) echo "Likely network printer" ;;
    nas-or-file-server) echo "Likely NAS or file server" ;;
    windows-host) echo "Likely Windows host" ;;
    linux-host) echo "Likely Linux-based host" ;;
    camera-or-nvr) echo "Likely IP camera or NVR" ;;
    network-device) echo "Likely network infrastructure device" ;;
    *) echo "Unknown device identity" ;;
  esac
}

parse_dig_status() {
  local file="$1"
  awk '
    /status:/ {
      if (match($0, /status: [A-Z]+/)) {
        value = substr($0, RSTART + 8, RLENGTH - 8)
        print value
        exit
      }
    }
  ' "$file"
}

parse_dig_flags() {
  local file="$1"
  awk '
    /flags:/ {
      line = $0
      sub(/^.*flags:[[:space:]]*/, "", line)
      sub(/;.*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$file"
}

parse_dig_short_answers() {
  local file="$1"
  awk '
    BEGIN { in_answer=0 }
    /^;; ANSWER SECTION:/ { in_answer=1; next }
    /^;; / && in_answer { in_answer=0 }
    in_answer && NF >= 5 {
      print $NF
    }
  ' "$file"
}

custom_target_dns_assessment() {
  local target_ip
  local hostname
  local json_file
  local raw_prefix
  local entry_index
  local query_tool=""
  local udp_file
  local tcp_file
  local ptr_file
  local version_file
  local udp_status="unknown"
  local tcp_status="unknown"
  local ptr_status="unknown"
  local recursion_available=false
  local dns_service_working=false
  local udp_answers_json="[]"
  local tcp_answers_json="[]"
  local ptr_answers_json="[]"
  local version_response=""
  local software_hint="unknown"
  local status="success"
  local success="true"
  local warnings=()
  local warnings_json

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Custom Target DNS Assessment"
  fi

  target_ip="$(prompt_for_target_ip "Target DNS IP Address: ")"
  hostname="$(resolve_target_hostname "$target_ip")"
  while IFS= read -r warning; do
    [[ -n "$warning" ]] && warnings+=("$warning")
  done < <(collect_custom_target_warnings "$target_ip" "$SELECTED_INTERFACE")
  echo "Target IP: $target_ip"
  echo "Hostname: $hostname"
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    for warning in "${warnings[@]}"; do
      echo "Warning: $warning"
    done
  fi
  echo

  if command -v dig >/dev/null 2>&1; then
    query_tool="dig"
  elif command -v nslookup >/dev/null 2>&1; then
    query_tool="nslookup"
  else
    echo "This function requires dig or nslookup."
    entry_index="$(next_multi_entry_index 16)"
    json_file="$(multi_entry_output_path_for_index 16 "$entry_index")"
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "dns_query_tool_missing" \
      --arg error_message "This function requires dig or nslookup." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi

  entry_index="$(next_multi_entry_index 16)"
  raw_prefix="$(multi_entry_raw_prefix_for_index 16 "$entry_index")"

  echo "Stage 1: Testing UDP DNS resolution..."
  udp_file="$(mktemp)"
  if [[ "$query_tool" == "dig" ]]; then
    dig @"$target_ip" example.com A +time=3 +tries=1 > "$udp_file" 2>&1 || true
  else
    nslookup example.com "$target_ip" > "$udp_file" 2>&1 || true
  fi
  copy_raw_artifact "$udp_file" "${raw_prefix}-udp.txt"

  echo "Stage 2: Testing TCP DNS resolution..."
  tcp_file="$(mktemp)"
  if [[ "$query_tool" == "dig" ]]; then
    dig @"$target_ip" example.com A +tcp +time=3 +tries=1 > "$tcp_file" 2>&1 || true
  else
    printf 'TCP assessment requires dig; skipped with nslookup fallback.\n' > "$tcp_file"
  fi
  copy_raw_artifact "$tcp_file" "${raw_prefix}-tcp.txt"

  echo "Stage 3: Testing reverse PTR lookup..."
  ptr_file="$(mktemp)"
  if [[ "$query_tool" == "dig" ]]; then
    dig @"$target_ip" -x 8.8.8.8 +time=3 +tries=1 > "$ptr_file" 2>&1 || true
  else
    nslookup 8.8.8.8 "$target_ip" > "$ptr_file" 2>&1 || true
  fi
  copy_raw_artifact "$ptr_file" "${raw_prefix}-ptr.txt"

  echo "Stage 4: Probing version.bind..."
  version_file="$(mktemp)"
  if [[ "$query_tool" == "dig" ]]; then
    dig @"$target_ip" version.bind TXT CH +time=3 +tries=1 > "$version_file" 2>&1 || true
  else
    printf 'version.bind probe requires dig; skipped with nslookup fallback.\n' > "$version_file"
  fi
  copy_raw_artifact "$version_file" "${raw_prefix}-version-bind.txt"

  if [[ "$query_tool" == "dig" ]]; then
    udp_status="$(parse_dig_status "$udp_file")"
    tcp_status="$(parse_dig_status "$tcp_file")"
    ptr_status="$(parse_dig_status "$ptr_file")"
    udp_answers_json="$(parse_dig_short_answers "$udp_file" | jq -R . | jq -s .)"
    tcp_answers_json="$(parse_dig_short_answers "$tcp_file" | jq -R . | jq -s .)"
    ptr_answers_json="$(parse_dig_short_answers "$ptr_file" | jq -R . | jq -s .)"

    if parse_dig_flags "$udp_file" | grep -qw 'ra'; then
      recursion_available=true
    fi

    version_response="$(awk '
      BEGIN { in_answer=0 }
      /^;; ANSWER SECTION:/ { in_answer=1; next }
      /^;; / && in_answer { in_answer=0 }
      in_answer && NF >= 5 {
        print $NF
        exit
      }
    ' "$version_file" | tr -d '"')"
  else
    if grep -qi 'Address:' "$udp_file" && grep -qi 'Name:' "$udp_file"; then
      udp_status="NOERROR"
      recursion_available=true
      dns_service_working=true
    fi
    if grep -qi 'Address:' "$ptr_file" || grep -qi 'name =' "$ptr_file"; then
      ptr_status="NOERROR"
    fi
  fi

  [[ -z "$udp_status" ]] && udp_status="unknown"
  [[ -z "$tcp_status" ]] && tcp_status="unknown"
  [[ -z "$ptr_status" ]] && ptr_status="unknown"
  [[ -z "$version_response" ]] || software_hint="$version_response"

  if [[ "$dns_service_working" == "false" ]]; then
    if [[ "$udp_status" == "NOERROR" && "$(jq 'length' <<< "$udp_answers_json")" -gt 0 ]]; then
      dns_service_working=true
    fi
  fi
  if [[ "$dns_service_working" == "false" ]]; then
    warnings+=("The target did not behave like a working recursive DNS resolver for the test queries.")
    status="completed_with_warnings"
  fi
  if [[ "$query_tool" == "nslookup" ]]; then
    warnings+=("TCP and version.bind assessment is limited when dig is not available.")
    status="completed_with_warnings"
  fi

  echo "DNS Service Working: $dns_service_working"
  echo "Recursion Available: $recursion_available"
  echo "UDP Query Status: $udp_status"
  echo "TCP Query Status: $tcp_status"
  echo "PTR Query Status: $ptr_status"
  echo "Software Hint: ${software_hint:-unknown}"
  echo "Upstream Destination Inference: unknown"
  echo "Note: Client-side DNS answers cannot reliably reveal where this resolver forwards upstream traffic. That requires packet capture on the DNS host, firewall, or gateway."

  json_file="$(multi_entry_output_path_for_index 16 "$entry_index")"
  warnings_json="$(json_string_array_from_array warnings)"
  jq -n \
    --arg status "$status" \
    --argjson success true \
    --argjson warnings "$warnings_json" \
    --arg target_ip "$target_ip" \
    --arg hostname "$hostname" \
    --arg query_tool "$query_tool" \
    --arg udp_status "$udp_status" \
    --arg tcp_status "$tcp_status" \
    --arg ptr_status "$ptr_status" \
    --arg version_response "$version_response" \
    --arg software_hint "$software_hint" \
    --arg upstream_destination_inference "unknown" \
    --arg upstream_visibility_note "Client-side DNS answers cannot reliably reveal where this resolver forwards upstream traffic. Capture on the resolver host, gateway, or firewall is required." \
    --argjson dns_service_working "$dns_service_working" \
    --argjson recursion_available "$recursion_available" \
    --argjson udp_answers "$udp_answers_json" \
    --argjson tcp_answers "$tcp_answers_json" \
    --argjson ptr_answers "$ptr_answers_json" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
      target_ip: $target_ip,
      hostname: $hostname,
      query_tool: $query_tool,
      dns_service_working: $dns_service_working,
      recursion_available: $recursion_available,
      udp_query: {
        status: $udp_status,
        answers: $udp_answers
      },
      tcp_query: {
        status: $tcp_status,
        answers: $tcp_answers
      },
      reverse_ptr_query: {
        status: $ptr_status,
        answers: $ptr_answers
      },
      version_bind_response: (if $version_response == "" then null else $version_response end),
      software_hint: $software_hint,
      upstream_destination_inference: $upstream_destination_inference,
      upstream_visibility_note: $upstream_visibility_note
    }' > "$json_file"

  validate_json_file "$json_file"

  rm -f "$udp_file" "$tcp_file" "$ptr_file" "$version_file"
}

custom_target_identity_scan() {
  local target_ip
  local hostname
  local json_file
  local raw_prefix
  local discovery_file
  local services_file
  local entry_index
  local mac_address=""
  local vendor_name=""
  local vendor_source="unknown"
  local lookup_method="nmap"
  local arp_output=""
  local online_vendor=""
  local host_state="unknown"
  local device_type_hint="unknown"
  local confidence="low"
  local identity_summary="Unknown device identity"
  local services_json="[]"
  local combined_service_text=""
  local combined_identity_text=""
  local status="success"
  local success="true"
  local warnings=()
  local warnings_json

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Custom Target Identity Scan"
  fi

  target_ip="$(prompt_for_target_ip "Target IP Address: ")"
  hostname="$(resolve_target_hostname "$target_ip")"
  while IFS= read -r warning; do
    [[ -n "$warning" ]] && warnings+=("$warning")
  done < <(collect_custom_target_warnings "$target_ip" "$SELECTED_INTERFACE")
  echo "Target IP: $target_ip"
  echo "Hostname: $hostname"
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    for warning in "${warnings[@]}"; do
      echo "Warning: $warning"
    done
  fi
  echo
  echo "Stage 1: Discovering MAC address and vendor..."

  entry_index="$(next_multi_entry_index 15)"
  raw_prefix="$(multi_entry_raw_prefix_for_index 15 "$entry_index")"
  discovery_file="$(mktemp)"
  json_file="$(multi_entry_output_path_for_index 15 "$entry_index")"
  if [[ -z "$discovery_file" || ! -f "$discovery_file" ]]; then
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "tempfile_creation_failed" \
      --arg error_message "Unable to create a temporary file for custom identity discovery." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi
  nmap -sn "$target_ip" > "$discovery_file" 2>/dev/null &
  local discovery_pid=$!
  spinner
  wait_for_pid "$discovery_pid" "Custom target identity discovery failed for $target_ip." || {
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "custom_identity_discovery_failed" \
      --arg error_message "The custom target identity discovery scan did not complete successfully." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname}' > "$json_file"
    validate_json_file "$json_file"
    rm -f "$discovery_file"
    return 1
  }
  echo

  copy_raw_artifact "$discovery_file" "${raw_prefix}-discovery.txt"

  mac_address="$(awk '
    /MAC Address:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
          print toupper($i)
          exit
        }
      }
    }
  ' "$discovery_file")"

  vendor_name="$(awk '
    /MAC Address:/ {
      line = $0
      sub(/^.*MAC Address: [0-9A-Fa-f:]+[[:space:]]*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^\(.*\)$/) {
        sub(/^\(/, "", line)
        sub(/\)$/, "", line)
      }
      print line
      exit
    }
  ' "$discovery_file")"

  if [[ -n "$vendor_name" && "$vendor_name" != "Unknown" && "$vendor_name" != "unknown" ]]; then
    vendor_source="nmap"
  fi

  if [[ -z "$mac_address" ]]; then
    ping -c 1 "$target_ip" >/dev/null 2>&1 || true
    if [[ "$OS" == "macos" ]]; then
      arp_output="$(arp -n "$target_ip" 2>/dev/null || true)"
    else
      arp_output="$(ip neigh show "$target_ip" 2>/dev/null || true)"
      if [[ -z "$arp_output" && "$(command -v arp || true)" != "" ]]; then
        arp_output="$(arp -n "$target_ip" 2>/dev/null || true)"
      fi
    fi

    if [[ -n "$arp_output" ]]; then
      mac_address="$(printf '%s\n' "$arp_output" | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
              print toupper($i)
              exit
            }
          }
        }
      ')"
      if [[ -n "$mac_address" ]]; then
        lookup_method="arp-cache"
        printf '%s\n' "$arp_output" > "${raw_prefix}-arp.txt"
      fi
    fi
  fi

  if [[ -n "$mac_address" && ( -z "$vendor_name" || "$vendor_name" == "Unknown" || "$vendor_name" == "unknown" ) ]]; then
    online_vendor="$(lookup_mac_vendor_online "$mac_address")"
    if [[ -n "$online_vendor" ]]; then
      vendor_name="$online_vendor"
      vendor_source="macvendors-api"
    fi
  fi

  [[ -z "$vendor_name" ]] && vendor_name="unknown"
  [[ "$vendor_source" == "unknown" && "$vendor_name" != "unknown" ]] && vendor_source="nmap"

  echo "MAC Address: ${mac_address:-unknown}"
  echo "Vendor: ${vendor_name}"
  echo "Vendor Source: ${vendor_source}"
  echo "Lookup Method: ${lookup_method}"
  echo
  echo "Stage 2: Running conservative service fingerprint scan..."

  services_file="$(mktemp)"
  if [[ -z "$services_file" || ! -f "$services_file" ]]; then
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "tempfile_creation_failed" \
      --arg error_message "Unable to create a temporary file for custom identity fingerprinting." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname}' > "$json_file"
    validate_json_file "$json_file"
    rm -f "$discovery_file"
    return 1
  fi
  nmap -Pn -sV --version-light "$target_ip" > "$services_file" 2>/dev/null &
  local scan_pid=$!
  spinner
  wait_for_pid "$scan_pid" "Custom target identity fingerprint failed for $target_ip." || {
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "custom_identity_fingerprint_failed" \
      --arg error_message "The custom target identity fingerprint scan did not complete successfully." \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, target_ip: $target_ip, hostname: $hostname}' > "$json_file"
    validate_json_file "$json_file"
    rm -f "$discovery_file" "$services_file"
    return 1
  }
  echo

  copy_raw_artifact "$services_file" "${raw_prefix}-services.txt"

  host_state="$(awk '
    /^Host is up/ { print "up"; found=1; exit }
    /Note: Host seems down/ { print "down"; found=1; exit }
    END {
      if (!found) {
        print "unknown"
      }
    }
  ' "$services_file")"

  services_json="$(awk '
    BEGIN { in_ports=0 }
    /^PORT[[:space:]]+STATE[[:space:]]+SERVICE/ { in_ports=1; next }
    in_ports && /^Service detection performed/ { in_ports=0; next }
    in_ports && /^[0-9]+\/[a-z]+[[:space:]]+/ {
      port_proto = $1
      state = $2
      service = $3
      version = ""
      if (NF > 3) {
        for (i = 4; i <= NF; i++) {
          if (version != "") {
            version = version " "
          }
          version = version $i
        }
      }
      printf "%s\t%s\t%s\t%s\n", port_proto, state, service, version
    }
  ' "$services_file" | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({
        port: .[0],
        state: .[1],
        service: .[2],
        version: (.[3] // "")
      })
  ')"

  combined_service_text="$(jq -r '.[] | [.service, .version] | join(" ")' <<< "$services_json" 2>/dev/null | tr '\n' ' ')"
  combined_identity_text="$(printf '%s %s %s' "$combined_service_text" "$vendor_name" "$hostname")"
  device_type_hint="$(guess_device_type_from_identity "$combined_service_text" "$vendor_name" "$hostname")"
  confidence="$(guess_identity_confidence "$combined_service_text" "$vendor_name" "$hostname" "$device_type_hint")"
  identity_summary="$(build_identity_summary "$vendor_name" "$device_type_hint" "$combined_identity_text")"
  if [[ "$host_state" == "down" ]]; then
    warnings+=("The target appears to be down or not responding to the fingerprint scan.")
  fi
  if [[ -z "$mac_address" ]]; then
    warnings+=("No MAC address could be identified for the target.")
  fi
  if jq -e 'length == 0' <<< "$services_json" >/dev/null 2>&1; then
    warnings+=("No service banners were identified on the target.")
  fi
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    status="completed_with_warnings"
  fi

  echo "Host State: $host_state"
  echo "Device Type Hint: $device_type_hint"
  echo "Confidence: $confidence"
  echo "Identity Summary: $identity_summary"
  echo "Discovered Services:"
  jq -r 'if length == 0 then "none found" else .[] | "- \(.port) | \(.state) | \(.service) | \((.version // "") | if . == "" then "no version banner" else . end)" end' <<< "$services_json"

  warnings_json="$(json_string_array_from_array warnings)"
  jq -n \
    --arg status "$status" \
    --argjson success true \
    --argjson warnings "$warnings_json" \
    --arg target_ip "$target_ip" \
    --arg hostname "$hostname" \
    --arg mac_address "$mac_address" \
    --arg vendor "$vendor_name" \
    --arg vendor_source "$vendor_source" \
    --arg lookup_method "$lookup_method" \
    --arg host_state "$host_state" \
    --arg device_type_hint "$device_type_hint" \
    --arg confidence "$confidence" \
    --arg identity_summary "$identity_summary" \
    --argjson services "$services_json" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
      target_ip: $target_ip,
      hostname: $hostname,
      mac_address: (if $mac_address == "" then null else $mac_address end),
      vendor: $vendor,
      vendor_source: $vendor_source,
      lookup_method: $lookup_method,
      host_state: $host_state,
      device_type_hint: $device_type_hint,
      confidence: $confidence,
      identity_summary: $identity_summary,
      services: $services
    }' > "$json_file"

  validate_json_file "$json_file"

  rm -f "$discovery_file" "$services_file"
}

extract_ping_summary_line() {
  local file="$1"
  awk '/(round-trip|rtt|min\/avg\/max)/ && /(stddev|mdev|min\/avg\/max)/ { line=$0 } END { print line }' "$file"
}

extract_ping_loss_percent() {
  local file="$1"
  local value=""

  value="$(sed -nE 's/.* ([0-9]+([.][0-9]+)?)% packet loss.*/\1/p' "$file" | head -n 1)"

  if [[ -n "$value" ]]; then
    echo "$value"
  else
    echo "0"
  fi
}

calculate_ping_metric_from_output() {
  local file="$1"
  local metric="$2"

  awk -v metric="$metric" '
    {
      line = $0
      value = ""

      if (line ~ /time=/) {
        sub(/^.*time=/, "", line)
        value = line
      } else if (line ~ /time</) {
        sub(/^.*time</, "", line)
        value = line
      } else {
        next
      }

      sub(/ ms.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

      if (value == "1" && $0 ~ /time</) {
        value = "0.5"
      }

      if (value !~ /^[0-9.]+$/) {
        next
      }

      num = value + 0
      count++
      sum += num
      sumsq += (num * num)

      if (count == 1 || num > max) {
        max = num
      }
    }
    END {
      if (count == 0) {
        exit
      }

      avg = sum / count
      variance = (sumsq / count) - (avg * avg)
      if (variance < 0) {
        variance = 0
      }
      stddev = sqrt(variance)

      if (metric == "avg") {
        printf "%.3f", avg
      } else if (metric == "max") {
        printf "%.3f", max
      } else if (metric == "stddev") {
        printf "%.3f", stddev
      }
    }
  ' "$file"
}

run_ping_stage() {
  local output_file="$1"
  shift

  "$@" > "$output_file" 2>&1 &
  local ping_pid=$!
  spinner "Running..."
  if ! wait "$ping_pid"; then
    return 1
  fi
}

is_wireless_interface() {
  local iface="$1"
  if [[ "$OS" == "macos" ]]; then
    networksetup -listallhardwareports 2>/dev/null | awk -v dev="$iface" '
      /Hardware Port: Wi-Fi/{wifi=1}
      wifi && /Device: / && $2==dev{found=1}
      /Hardware Port:/ && !/Wi-Fi/{wifi=0}
      END{exit !found}'
  else
    [[ -d "/sys/class/net/$iface/wireless" ]]
  fi
}

list_wireless_interfaces() {
  if [[ "$OS" == "macos" ]]; then
    networksetup -listallhardwareports 2>/dev/null | awk '
      /Hardware Port: Wi-Fi/{wifi=1}
      wifi && /Device:/{print $2; wifi=0}
      /Hardware Port:/ && !/Wi-Fi/{wifi=0}'
  else
    if command -v iw >/dev/null 2>&1; then
      iw dev 2>/dev/null | awk '/Interface/{print $2}'
    else
      ls /sys/class/net/*/wireless 2>/dev/null | awk -F/ '{print $5}'
    fi
  fi
}

run_wireless_scan() {
  local iface="$1"

  # On macOS: use the compiled LSS-WiFiScan.app bundle (CoreWLAN + Location Services).
  # This produces a proper authorization dialog and returns real SSIDs.
  if [[ "$(uname)" == "Darwin" ]] && [[ -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
    run_wifi_scan_helper_macos "$iface"
    return
  fi

  local tmp_py rc
  tmp_py="$(mktemp /tmp/lss-wifi-scan-XXXXXX)"
  cat > "$tmp_py" <<'PYEOF'
import sys, json, subprocess, re, os

iface   = sys.argv[1]
os_type = sys.argv[2]

def scan_macos(iface):
    airport = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    if os.path.isfile(airport) and os.access(airport, os.X_OK):
        return _scan_macos_airport(airport)
    return _scan_macos_system_profiler(iface)

def _scan_macos_airport(airport):
    try:
        result = subprocess.run([airport, "-s"], capture_output=True, text=True, timeout=15)
        lines = result.stdout.split('\n')
        networks = []
        bssid_re = re.compile(r'([0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2})', re.IGNORECASE)
        for line in lines[1:]:
            m = bssid_re.search(line)
            if not m:
                continue
            bssid = m.group(1).lower()
            ssid = line[:m.start()].strip() or '(hidden)'
            rest = line[m.end():].split()
            try:
                rssi = int(rest[0]) if rest else 0
            except ValueError:
                rssi = 0
            channel  = rest[1] if len(rest) > 1 else ''
            security = ' '.join(rest[4:]) if len(rest) > 4 else 'Open'
            networks.append({'ssid': ssid, 'bssid': bssid, 'rssi_dbm': rssi, 'channel': channel, 'security': security})
        return networks
    except Exception:
        return []

def _scan_macos_system_profiler(iface):
    try:
        # system_profiler returns no Wi-Fi data when run as root (sudo).
        # Drop back to the original user before calling it.
        preexec_fn = None
        sudo_user = os.environ.get('SUDO_USER', '')
        if sudo_user and os.getuid() == 0:
            import pwd
            try:
                pw = pwd.getpwnam(sudo_user)
                uid, gid = pw.pw_uid, pw.pw_gid
                def _drop():
                    os.setgid(gid)
                    os.setuid(uid)
                preexec_fn = _drop
            except Exception:
                pass
        result = subprocess.run(
            ['system_profiler', 'SPAirPortDataType', '-json'],
            capture_output=True, text=True, timeout=30,
            preexec_fn=preexec_fn
        )
        data = json.loads(result.stdout)
        networks = []

        def parse_sec(raw):
            raw = (raw or '').lower()
            if 'wpa3' in raw:       return 'WPA3'
            if 'enterprise' in raw: return 'WPA2-Enterprise'
            if 'wpa2' in raw:       return 'WPA2'
            if 'wpa' in raw:        return 'WPA'
            return 'Open'

        def parse_signal(raw):
            # e.g. "-46 dBm / -96 dBm" -> rssi=-46, noise=-96
            if raw is None:
                return None, None
            try:
                parts = str(raw).split('/')
                rssi  = int(parts[0].split()[0])
                noise = int(parts[1].split()[0]) if len(parts) > 1 else None
                return rssi, noise
            except (ValueError, IndexError):
                return None, None

        def parse_channel_info(raw):
            # e.g. "36 (5GHz, 160MHz)" -> channel="36", band="5GHz", width="160MHz"
            raw = str(raw) if raw else ''
            channel = raw.split()[0] if raw else ''
            band, width = '', ''
            m = re.search(r'\(([^)]+)\)', raw)
            if m:
                parts = [p.strip() for p in m.group(1).split(',')]
                for p in parts:
                    if 'GHz' in p: band  = p
                    if 'MHz' in p: width = p
            # Normalize 2GHz -> 2.4GHz (system_profiler sometimes omits the .4)
            if band in ('2GHz', '2 GHz'):
                band = '2.4GHz'
            return channel, band, width

        def norm_phy(raw):
            raw = (raw or '').lower()
            if 'ax' in raw: return '802.11ax (Wi-Fi 6)'
            if 'ac' in raw: return '802.11ac (Wi-Fi 5)'
            if 'n'  in raw: return '802.11n (Wi-Fi 4)'
            if 'a'  in raw: return '802.11a'
            if 'g'  in raw: return '802.11g'
            if 'b'  in raw: return '802.11b'
            return raw or 'unknown'

        for entry in (data.get('SPAirPortDataType') or []):
            for wifi_iface in (entry.get('spairport_airport_interfaces') or []):
                # Skip non-Wi-Fi interfaces (awdl0, p2p0, etc.)
                if wifi_iface.get('_name') != iface:
                    continue
                cur    = wifi_iface.get('spairport_current_network_information')
                others = wifi_iface.get('spairport_airport_other_local_wireless_networks') or []
                for net in ([cur] if cur else []) + others:
                    if not net:
                        continue
                    ssid = net.get('_name') or '(hidden)'
                    rssi, noise = parse_signal(net.get('spairport_signal_noise'))
                    channel, band, width = parse_channel_info(net.get('spairport_network_channel'))
                    networks.append({
                        'ssid':            ssid,
                        'bssid':           '--',
                        'rssi_dbm':        rssi,
                        'noise_floor_dbm': noise,
                        'channel':         channel,
                        'band':            band,
                        'channel_width':   width,
                        'phy_mode':        norm_phy(net.get('spairport_network_phymode')),
                        'security':        parse_sec(net.get('spairport_security_mode')),
                    })
        return networks
    except Exception:
        return []

def scan_linux(iface):
    try:
        result = subprocess.run(['iw', 'dev', iface, 'scan'], capture_output=True, text=True, timeout=30)
        networks = []
        current = None
        for line in result.stdout.split('\n'):
            s = line.strip()
            if s.startswith('BSS '):
                if current:
                    networks.append(current)
                bssid = s.split()[1].split('(')[0].lower()
                current = {'ssid': '', 'bssid': bssid, 'rssi_dbm': 0, 'noise_floor_dbm': None,
                           'channel': '', 'band': '', 'channel_width': '', 'phy_mode': '', 'security': 'Open'}
            elif current is None:
                continue
            elif s.startswith('SSID:'):
                current['ssid'] = s[5:].strip() or '(hidden)'
            elif 'signal:' in s:
                try:
                    current['rssi_dbm'] = int(float(s.split('signal:')[1].split('dBm')[0].strip()))
                except (ValueError, IndexError):
                    pass
            elif '* primary channel:' in s:
                try:
                    current['channel'] = s.split(':')[1].strip()
                except IndexError:
                    pass
            elif '* channel width:' in s:
                try:
                    current['channel_width'] = s.split(':')[1].strip()
                except IndexError:
                    pass
            elif s.startswith('RSN:') or 'WPA2' in s:
                current['security'] = 'WPA2'
            elif s.startswith('WPA:') or ('WPA' in s and 'WPA2' not in s):
                if current.get('security') == 'Open':
                    current['security'] = 'WPA'
        if current:
            networks.append(current)
        return networks
    except Exception:
        return []

nets = scan_macos(iface) if os_type == 'macos' else scan_linux(iface)
print(json.dumps(nets))
PYEOF

  python3 "$tmp_py" "$iface" "$OS" 2>/dev/null
  rc=$?
  rm -f "$tmp_py"
  if [[ "$rc" -ne 0 ]]; then
    echo "[]"
  fi
}

_LSS_WIFI_HELPER="/usr/local/share/lss-network-tools/LSS-WiFiScan.app"

build_wifi_scan_helper_macos() {
  # Builds a proper macOS app bundle that uses CoreWLAN for Wi-Fi scanning.
  # A real app bundle (not a CLI script) can properly request Location Services
  # authorization — macOS shows a modal dialog and adds the app to the
  # System Settings → Privacy & Security → Location Services list.
  # The built binary is cached at $_LSS_WIFI_HELPER.
  # Rebuild if the helper doesn't exist or was built for a different app version
  local _helper_ver_file="${_LSS_WIFI_HELPER}.version"
  if [[ -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
    local _cached_ver
    _cached_ver="$(cat "$_helper_ver_file" 2>/dev/null)" || true
    [[ "$_cached_ver" == "$APP_VERSION" ]] && return 0
    echo "  Wi-Fi scan helper outdated — rebuilding..."
  fi

  local swiftc_bin
  swiftc_bin="$(command -v swiftc 2>/dev/null || true)"
  if [[ -z "$swiftc_bin" ]]; then
    echo "  NOTE: Xcode Command Line Tools not found (swiftc missing)."
    echo "  Install them with:  xcode-select --install"
    echo "  Then re-run the Wireless Site Survey."
    return 1
  fi

  echo "  Building Wi-Fi scan helper (first time only, ~20 seconds)..."
  mkdir -p "$_LSS_WIFI_HELPER/Contents/MacOS"

  mkdir -p "$_LSS_WIFI_HELPER/Contents/Resources"

  cat > "$_LSS_WIFI_HELPER/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ie.lssolutions.wifi-scan</string>
    <key>CFBundleName</key>
    <string>LSS Network Tools</string>
    <key>CFBundleDisplayName</key>
    <string>LSS Network Tools - WiFi Scan</string>
    <key>CFBundleExecutable</key>
    <string>LSS-WiFiScan</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>LSS Network Tools requires location access to read Wi-Fi network names (SSIDs) during wireless site surveys.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST_EOF

  # Build AppIcon.icns from assets/wifi-scan-icon.png if it exists
  local icon_src="$SCRIPT_DIR/assets/wifi-scan-icon.png"
  local icon_dst="$_LSS_WIFI_HELPER/Contents/Resources/AppIcon.icns"
  if [[ -f "$icon_src" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    local iconset_dir
    iconset_dir="$(mktemp -d /tmp/lss-AppIcon-XXXXXX.iconset)"
    local ok=1
    for size in 16 32 64 128 256 512; do
      sips -z $size $size "$icon_src" --out "$iconset_dir/icon_${size}x${size}.png"      >/dev/null 2>&1 || ok=0
      sips -z $((size*2)) $((size*2)) "$icon_src" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || ok=0
    done
    if [[ "$ok" -eq 1 ]]; then
      iconutil -c icns "$iconset_dir" -o "$icon_dst" 2>/dev/null && \
        echo "  App icon built from assets/wifi-scan-icon.png."
    fi
    rm -rf "$iconset_dir"
  fi

  local tmp_src
  tmp_src="$(mktemp /tmp/lss-wifiscan-XXXXXX.swift)"
  cat > "$tmp_src" << 'SWIFT_EOF'
// LSS-WiFiScan.app
// Requests Location Services authorization (shows proper modal dialog on first run).
// Once authorized, reads Wi-Fi networks via CoreWLAN cachedScanResults() — which
// returns real SSIDs (not "<redacted>") because this app is location-authorized.
import AppKit
import CoreLocation
import CoreWLAN
import Foundation

let kIface  = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let kOutput = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/lss-wifi-result.json"

func writeResult(_ str: String) {
    // atomically:false — direct write; atomically:true uses rename() which fails
    // on /tmp (sticky bit) when the file is owned by root but written by user.
    try? str.write(toFile: kOutput, atomically: false, encoding: .utf8)
}


func parseSignal(_ raw: Any?) -> (Int?, Int?) {
    guard let s = raw as? String else { return (nil, nil) }
    let parts = s.components(separatedBy: "/")
    let rssi  = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") }
    let noise = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") : nil
    return (rssi, noise)
}

func parseChannel(_ raw: Any?) -> (String, String, String) {
    guard let s = raw as? String, !s.isEmpty else { return ("", "", "") }
    let ch = s.components(separatedBy: " ").first ?? ""
    var band = "", width = ""
    if let m = s.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
        let inner = String(s[m]).dropFirst().dropLast()
        for part in inner.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.contains("GHz") { band = part == "2GHz" ? "2.4GHz" : part }
            if part.contains("MHz") { width = part }
        }
    }
    return (ch, band, width)
}

func normSec(_ raw: Any?) -> String {
    let s = (raw as? String ?? "").lowercased()
    if s.contains("wpa3")       { return "WPA3" }
    if s.contains("enterprise") { return "WPA2-Enterprise" }
    if s.contains("wpa2")       { return "WPA2" }
    if s.contains("wpa")        { return "WPA" }
    return "Open"
}

func normPhy(_ raw: Any?) -> String {
    let s = (raw as? String ?? "").lowercased()
    if s.contains("ax") { return "802.11ax (Wi-Fi 6)" }
    if s.contains("ac") { return "802.11ac (Wi-Fi 5)" }
    if s.contains("n")  { return "802.11n (Wi-Fi 4)" }
    if s.contains("a")  { return "802.11a" }
    if s.contains("g")  { return "802.11g" }
    return s.isEmpty ? "--" : s
}

func normBandCW(_ band: CWChannelBand) -> String {
    switch band {
    case .band2GHz: return "2.4GHz"
    case .band5GHz: return "5GHz"
    case .band6GHz: return "6GHz"
    default:        return ""
    }
}

func normWidthCW(_ w: CWChannelWidth) -> String {
    switch w {
    case .width20MHz:  return "20MHz"
    case .width40MHz:  return "40MHz"
    case .width80MHz:  return "80MHz"
    case .width160MHz: return "160MHz"
    default:           return ""
    }
}

func scanViaCoreWLAN() -> [[String: Any]] {
    let client = CWWiFiClient.shared()
    let ifaces: [CWInterface]
    if kIface.isEmpty {
        ifaces = client.interfaces() ?? [client.interface()].compactMap { $0 }
    } else {
        ifaces = [client.interface(withName: kIface)].compactMap { $0 }
    }
    var results: [[String: Any]] = []
    for iface in ifaces {
        // Try a live scan first; fall back to background-scan cache if entitlements block it.
        // Both paths return real SSIDs because this app is location-authorized.
        var networks: Set<CWNetwork>
        do {
            networks = try iface.scanForNetworks(withSSID: nil)
        } catch {
            networks = iface.cachedScanResults() ?? []
        }
        if networks.isEmpty {
            networks = iface.cachedScanResults() ?? []
        }
        for net in networks {
            let ssid  = net.ssid ?? "(hidden)"
            let rssi  = net.rssiValue      // 0 when unknown
            let noise = net.noiseMeasurement
            let ch    = net.wlanChannel
            var e: [String: Any] = [:]
            e["ssid"]            = ssid
            e["bssid"]           = net.bssid ?? "--"
            e["rssi_dbm"]        = rssi != 0 ? rssi : NSNull()
            e["noise_floor_dbm"] = noise != 0 ? noise : NSNull()
            e["channel"]         = ch.map { "\($0.channelNumber)" } ?? ""
            e["band"]            = ch.map { normBandCW($0.channelBand) } ?? ""
            e["channel_width"]   = ch.map { normWidthCW($0.channelWidth) } ?? ""
            e["phy_mode"]        = "--"
            e["security"]        = "--"
            results.append(e)
        }
    }
    return results
}

func scanNetworks() {
    let results = scanViaCoreWLAN()
    if let data = try? JSONSerialization.data(withJSONObject: results),
       let str  = String(data: data, encoding: .utf8) {
        writeResult(str)
    } else {
        writeResult("[]")
    }
    NSApp.terminate(nil)
}

class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    let locationManager = CLLocationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        locationManager.delegate = self
        let status: CLAuthorizationStatus
        if #available(macOS 11.0, *) { status = locationManager.authorizationStatus }
        else { status = CLLocationManager.authorizationStatus() }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: scanNetworks()
        case .denied, .restricted: writeResult("[]"); NSApp.terminate(nil)
        default: locationManager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status: CLAuthorizationStatus
        if #available(macOS 11.0, *) { status = manager.authorizationStatus }
        else { status = CLLocationManager.authorizationStatus() }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: scanNetworks()
        default: writeResult("[]"); NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT_EOF

  "$swiftc_bin" "$tmp_src" \
    -o "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" \
    -framework Foundation -framework AppKit \
    -framework CoreLocation -framework CoreWLAN \
    2>/tmp/lss-swiftc-err.txt
  local rc=$?
  rm -f "$tmp_src"

  if [[ $rc -ne 0 ]]; then
    echo "  Wi-Fi helper build failed. See /tmp/lss-swiftc-err.txt"
    return 1
  fi

  chmod 755 "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan"
  codesign --force --sign - "$_LSS_WIFI_HELPER" 2>/dev/null || \
    codesign --force --sign - "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" 2>/dev/null || true
  echo "$APP_VERSION" > "${_LSS_WIFI_HELPER}.version"
  echo "  Wi-Fi scan helper built successfully."
  return 0
}

run_wifi_scan_helper_macos() {
  # Run the compiled LSS-WiFiScan.app bundle to scan Wi-Fi via CoreWLAN.
  # The app handles Location Services authorization itself (shows a proper
  # modal dialog on first run). Results are written to a temp file.
  local iface="$1"
  local tmp_result
  tmp_result="$(mktemp /tmp/lss-wifi-result-XXXXXX.json)"
  # The app runs as the logged-in user (via open), not root.
  # Make the result file world-writable so the app can write its output.
  chmod 666 "$tmp_result" 2>/dev/null || true

  local run_as=""
  [[ "$(id -u)" == "0" ]] && [[ -n "${SUDO_USER:-}" ]] && run_as="$SUDO_USER"

  if [[ -n "$run_as" ]]; then
    sudo -u "$run_as" open -n -W "$_LSS_WIFI_HELPER" --args "$iface" "$tmp_result" 2>/dev/null || true
  else
    open -n -W "$_LSS_WIFI_HELPER" --args "$iface" "$tmp_result" 2>/dev/null || true
  fi

  local result
  result="$(cat "$tmp_result" 2>/dev/null)"
  # Surface any scan error logged by the app
  if [[ -f "${tmp_result}.err" ]]; then
    echo "  [WiFi scan error: $(cat "${tmp_result}.err")]" >&2
    rm -f "${tmp_result}.err"
  fi
  rm -f "$tmp_result"
  echo "${result:-[]}"
}

wireless_site_survey() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  local survey_json="[]"
  local building="" floor="" room=""
  local ap_present_bool ap_label ap_ans
  local scan_result entry_json timestamp net_count strongest_info
  local choice
  local rooms_scanned=0
  local wifi_ifaces=()
  local i sel wi

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Wireless Site Survey"
    echo "===================="
  fi

  # Verify the selected interface is a wireless interface
  if ! is_wireless_interface "$iface"; then
    echo
    echo "Selected interface ($iface) is not a wireless interface."
    echo

    while IFS= read -r wi; do
      [[ -n "$wi" ]] && wifi_ifaces+=("$wi")
    done < <(list_wireless_interfaces)

    if [[ "${#wifi_ifaces[@]}" -eq 0 ]]; then
      echo "No wireless interfaces found on this system."
      json_file="$(task_output_path 17)"
      jq -n '{status:"failed",success:false,error:{code:"NO_WIRELESS_INTERFACE",message:"No wireless interface available on this system."},warnings:[],scan_type:"wireless_site_survey",interface:null,rooms_scanned:0,survey:[]}' > "$json_file"
      validate_json_file "$json_file"
      return 1
    fi

    echo "Wireless interfaces available:"
    for i in "${!wifi_ifaces[@]}"; do
      printf "  %s) %s\n" "$((i + 1))" "${wifi_ifaces[$i]}"
    done
    echo "  00) Back to Main Menu"
    echo "  0) Cancel"
    echo

    while true; do
      read -r -p "Select wireless interface: " sel
      if [[ "$sel" == "00" ]]; then
        _GOTO_MAIN_MENU=true
        return 0
      fi
      if [[ "$sel" == "0" ]]; then
        return 0
      fi
      if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#wifi_ifaces[@]} )); then
        iface="${wifi_ifaces[$((sel - 1))]}"
        break
      fi
      echo "Invalid selection. Try again."
    done
    echo
    echo "Using interface: $iface"
  fi

  # Build the Wi-Fi helper if it wasn't built at install/update time
  # (e.g. swiftc was absent then, or updating from a version before v1.0.91).
  if [[ "$(uname)" == "Darwin" ]] && [[ ! -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
    build_wifi_scan_helper_macos || true
  fi

  echo
  echo "Each scan records all visible Wi-Fi networks from your current position."
  echo

  read -r -p "Building name: " building
  read -r -p "Floor: " floor
  read -r -p "Room / Area: " room

  while true; do
    echo
    echo "--- $building | Floor: $floor | Room/Area: $room ---"
    echo

    # Ask about AP presence
    while true; do
      read -r -p "Is there a Wi-Fi access point physically present in this room? (y/n): " ap_ans
      if [[ "$ap_ans" =~ ^[Yy]$ ]]; then
        ap_present_bool=true
        read -r -p "AP label / ID (e.g. AP-101, press Enter to skip): " ap_label
        break
      elif [[ "$ap_ans" =~ ^[Nn]$ ]]; then
        ap_present_bool=false
        ap_label=""
        break
      fi
      echo "Please enter y or n."
    done

    echo
    echo "Scanning... (this takes a few seconds)"
    scan_result="$(run_wireless_scan "$iface")"
    if [[ -z "$scan_result" ]] || [[ "$scan_result" == "null" ]]; then
      scan_result="[]"
    fi

    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    net_count="$(jq 'length' <<< "$scan_result" 2>/dev/null || echo 0)"

    if (( net_count > 0 )); then
      strongest_info="$(jq -r '[.[] | select(.rssi_dbm != null)] | sort_by(.rssi_dbm) | reverse | .[0] | "\(.ssid) (\(.rssi_dbm) dBm, ch \(.channel), \(.security))"' <<< "$scan_result" 2>/dev/null || echo "unknown")"
    else
      strongest_info="none"
    fi

    echo
    echo "Networks found: $net_count"
    if (( net_count > 0 )); then
      echo "Strongest:      $strongest_info"
    fi

    entry_json="$(jq -n \
      --arg building "$building" \
      --arg floor "$floor" \
      --arg room "$room" \
      --argjson ap_present "$ap_present_bool" \
      --arg ap_label "$ap_label" \
      --arg timestamp "$timestamp" \
      --argjson networks "$scan_result" \
      '{building:$building,floor:$floor,room:$room,ap_present:$ap_present,ap_label:(if $ap_label == "" then null else $ap_label end),timestamp:$timestamp,networks:$networks}')"

    survey_json="$(jq -n --argjson arr "$survey_json" --argjson e "$entry_json" '$arr + [$e]')"
    rooms_scanned=$((rooms_scanned + 1))

    # Navigation menu
    echo
    echo "1) Move to another room  (same floor)"
    echo "2) Move to another floor (same building)"
    echo "3) Move to another building"
    echo "4) Finished"
    echo "00) Back to Main Menu"
    echo

    while true; do
      read -r -p "Choice: " choice
      case "$choice" in
        1)
          read -r -p "Room / Area: " room
          break
          ;;
        2)
          read -r -p "Floor: " floor
          read -r -p "Room / Area: " room
          break
          ;;
        3)
          read -r -p "Building name: " building
          read -r -p "Floor: " floor
          read -r -p "Room / Area: " room
          break
          ;;
        4)
          break 2
          ;;
        00)
          _GOTO_MAIN_MENU=true
          break 2
          ;;
        *)
          echo "Please enter 1, 2, 3, 4 or 00."
          ;;
      esac
    done
  done

  [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0

  json_file="$(task_output_path 17)"
  jq -n \
    --arg status "success" \
    --argjson success true \
    --arg interface "$iface" \
    --argjson rooms_scanned "$rooms_scanned" \
    --argjson survey "$survey_json" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: [],
      scan_type: "wireless_site_survey",
      interface: $interface,
      rooms_scanned: $rooms_scanned,
      survey: $survey
    }' > "$json_file"

  validate_json_file "$json_file"
  echo
  echo "Survey complete. $rooms_scanned room(s) recorded."
}

run_stress_test_for_target() {
  local target_ip="$1"
  local iface="$2"
  local task_id="$3"
  local context_label="$4"
  local target_description="$5"
  local stage_subject_label="$6"
  local json_function_name="$7"
  local report_target_key="$8"
  local baseline_file jitter_file large_file sustained_file recovery_file
  local ramp_file ramp_summary ramp_avg ramp_max ramp_loss size idx
  local -a ramp_sizes ramping_files ramping_avgs ramping_maxes ramping_losses
  local baseline_summary jitter_summary large_summary sustained_summary recovery_summary
  local baseline_avg baseline_max baseline_stddev
  local jitter_stddev jitter_max jitter_loss
  local large_avg large_max large_loss
  local sustained_avg sustained_max sustained_loss
  local recovery_avg
  local high_jitter=false
  local latency_under_load=false
  local packet_loss=false
  local slow_recovery=false
  local returned_to_baseline=false
  local json_file
  local json_tmp
  local raw_prefix
  local entry_index=""
  local hostname
  local stage_warning=""
  local stage_failure=false
  local warning_json="null"
  local baseline_status="ok"
  local jitter_status="ok"
  local large_status="ok"
  local sustained_status="ok"
  local recovery_status="ok"
  local ramping_status="ok"
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()

  if ! confirm_gateway_stress_operation "$context_label" "$target_description"; then
    return 1
  fi

  if ! command -v ping >/dev/null 2>&1; then
    echo "ping is required for stress testing."
    if [[ "$OS" == "macos" ]]; then
      echo "ping should be available as a macOS system command."
    else
      echo "Install with: apt-get install iputils-ping"
      echo "or"
      echo "dnf install iputils"
    fi
    if task_supports_multiple_entries "$task_id"; then
      json_file="$(multi_entry_output_path_for_index "$task_id" "$(next_multi_entry_index "$task_id")")"
    else
      json_file="$(task_output_path "$task_id")"
    fi
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "ping_dependency_missing" \
      --arg error_message "ping is required for stress testing." \
      --arg function "$json_function_name" \
      --arg target_key "$report_target_key" \
      --arg target_ip "$target_ip" \
      --arg hostname "unknown" \
      --arg interface "$iface" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: $function, ($target_key): $target_ip, hostname: $hostname, interface: $interface}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi

  echo "Done."
  hostname="$(resolve_target_hostname "$target_ip")"
  echo "$stage_subject_label: $target_ip"
  echo "Hostname: $hostname"
  echo "Interface: $iface"
  echo

  if task_supports_multiple_entries "$task_id"; then
    entry_index="$(next_multi_entry_index "$task_id")"
    raw_prefix="$(multi_entry_raw_prefix_for_index "$task_id" "$entry_index")"
    json_file="$(multi_entry_output_path_for_index "$task_id" "$entry_index")"
  else
    raw_prefix="$(task_raw_prefix "$task_id")"
    json_file="$(task_output_path "$task_id")"
  fi

  baseline_file="$(mktemp)"
  jitter_file="$(mktemp)"
  large_file="$(mktemp)"
  ramp_sizes=(64 256 512 1024 1400)
  sustained_file="$(mktemp)"
  recovery_file="$(mktemp)"
  if [[ -z "$baseline_file" || -z "$jitter_file" || -z "$large_file" || -z "$sustained_file" || -z "$recovery_file" ]]; then
    echo "Error: Unable to create temporary files for the stress test."
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "tempfile_creation_failed" \
      --arg error_message "Unable to create temporary files for the stress test." \
      --arg function "$json_function_name" \
      --arg target_key "$report_target_key" \
      --arg target_ip "$target_ip" \
      --arg hostname "$hostname" \
      --arg interface "$iface" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: $function, ($target_key): $target_ip, hostname: $hostname, interface: $interface}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi

  echo "Stage 2: Baseline latency test (20 pings)..."
  if ! run_ping_stage "$baseline_file" ping -c 20 "$target_ip"; then
    baseline_status="failed"
    stage_failure=true
    echo "Warning: baseline latency test failed. Continuing with remaining stages."
  fi

  if ! interface_has_valid_ip "$iface"; then
    echo ""
    echo "Interface $iface lost its IP address after the baseline test — stress test aborted."
    jq -n --arg ec "interface_disconnected" \
      --arg em "Interface $iface lost its IP address after the baseline test. The stress test was aborted to avoid running further stages on a disconnected interface." \
      --arg fn "$json_function_name" --arg tk "$report_target_key" --arg tip "$target_ip" --arg hn "$hostname" --arg if_ "$iface" \
      '{status:"failed",success:false,error:{code:$ec,message:$em},warnings:[],function:$fn,($tk):$tip,hostname:$hn,interface:$if_}' > "$json_file"
    validate_json_file "$json_file" || true
    rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file"
    return 1
  fi

  echo "Stage 3: Jitter test (200 pings @ 0.05s interval)..."
  if ! run_ping_stage "$jitter_file" ping -i 0.05 -c 200 "$target_ip"; then
    jitter_status="failed"
    stage_failure=true
    echo "Warning: jitter test failed. Continuing with remaining stages."
  fi

  if ! interface_has_valid_ip "$iface"; then
    echo ""
    echo "Interface $iface lost its IP address during the jitter test — stress test aborted."
    jq -n --arg ec "interface_disconnected" \
      --arg em "Interface $iface lost its IP address during the jitter test. The stress test was aborted to avoid running further stages on a disconnected interface." \
      --arg fn "$json_function_name" --arg tk "$report_target_key" --arg tip "$target_ip" --arg hn "$hostname" --arg if_ "$iface" \
      '{status:"failed",success:false,error:{code:$ec,message:$em},warnings:[],function:$fn,($tk):$tip,hostname:$hn,interface:$if_}' > "$json_file"
    validate_json_file "$json_file" || true
    rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file"
    return 1
  fi

  echo "Stage 4: Large packet test (100 pings @ 1400 bytes)..."
  if ! run_ping_stage "$large_file" ping -s 1400 -c 100 "$target_ip"; then
    large_status="failed"
    stage_failure=true
    echo "Warning: large packet test failed. Continuing with remaining stages."
  fi

  echo "Stage 5: Ramping test (20 pings per packet size)..."
  for size in "${ramp_sizes[@]}"; do
    ramp_file="$(mktemp)"
    ramping_files+=("$ramp_file")
  done

  if ! interface_has_valid_ip "$iface"; then
    echo ""
    echo "Interface $iface lost its IP address during the large packet test — stress test aborted."
    jq -n --arg ec "interface_disconnected" \
      --arg em "Interface $iface lost its IP address during the large packet test. The stress test was aborted to avoid running further stages on a disconnected interface." \
      --arg fn "$json_function_name" --arg tk "$report_target_key" --arg tip "$target_ip" --arg hn "$hostname" --arg if_ "$iface" \
      '{status:"failed",success:false,error:{code:$ec,message:$em},warnings:[],function:$fn,($tk):$tip,hostname:$hn,interface:$if_}' > "$json_file"
    validate_json_file "$json_file" || true
    rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file" "${ramping_files[@]:-}"
    return 1
  fi

  for idx in "${!ramp_sizes[@]}"; do
    if ! run_ping_stage "${ramping_files[$idx]}" ping -s "${ramp_sizes[$idx]}" -c 20 "$target_ip"; then
      ramping_status="partial"
      stage_failure=true
      echo "Warning: ramping test failed for packet size ${ramp_sizes[$idx]}. Continuing with remaining stages."
    fi
  done

  if ! interface_has_valid_ip "$iface"; then
    echo ""
    echo "Interface $iface lost its IP address during the ramping test — stress test aborted."
    jq -n --arg ec "interface_disconnected" \
      --arg em "Interface $iface lost its IP address during the ramping test. The stress test was aborted to avoid running further stages on a disconnected interface." \
      --arg fn "$json_function_name" --arg tk "$report_target_key" --arg tip "$target_ip" --arg hn "$hostname" --arg if_ "$iface" \
      '{status:"failed",success:false,error:{code:$ec,message:$em},warnings:[],function:$fn,($tk):$tip,hostname:$hn,interface:$if_}' > "$json_file"
    validate_json_file "$json_file" || true
    rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file" "${ramping_files[@]:-}"
    return 1
  fi

  echo "Stage 6: Sustained load test (300 pings @ 0.02s interval)..."
  if ! run_ping_stage "$sustained_file" ping -i 0.02 -c 300 "$target_ip"; then
    sustained_status="failed"
    stage_failure=true
    echo "Warning: sustained load test failed. Continuing with remaining stages."
  fi

  if ! interface_has_valid_ip "$iface"; then
    echo ""
    echo "Interface $iface lost its IP address during the sustained load test — stress test aborted."
    jq -n --arg ec "interface_disconnected" \
      --arg em "Interface $iface lost its IP address during the sustained load test. The stress test was aborted to avoid running further stages on a disconnected interface." \
      --arg fn "$json_function_name" --arg tk "$report_target_key" --arg tip "$target_ip" --arg hn "$hostname" --arg if_ "$iface" \
      '{status:"failed",success:false,error:{code:$ec,message:$em},warnings:[],function:$fn,($tk):$tip,hostname:$hn,interface:$if_}' > "$json_file"
    validate_json_file "$json_file" || true
    rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file" "${ramping_files[@]:-}"
    return 1
  fi

  echo "Stage 7: Recovery test (30 pings)..."
  if ! run_ping_stage "$recovery_file" ping -c 30 "$target_ip"; then
    recovery_status="failed"
    stage_failure=true
    echo "Warning: recovery test failed. Continuing to build partial results."
  fi

  baseline_summary="$(extract_ping_summary_line "$baseline_file")"
  jitter_summary="$(extract_ping_summary_line "$jitter_file")"
  large_summary="$(extract_ping_summary_line "$large_file")"
  sustained_summary="$(extract_ping_summary_line "$sustained_file")"
  recovery_summary="$(extract_ping_summary_line "$recovery_file")"

  baseline_avg="$(parse_ping_metric "$baseline_summary" 2 "$baseline_file")"
  baseline_max="$(parse_ping_metric "$baseline_summary" 3 "$baseline_file")"
  baseline_stddev="$(parse_ping_metric "$baseline_summary" 4 "$baseline_file")"

  jitter_stddev="$(parse_ping_metric "$jitter_summary" 4 "$jitter_file")"
  jitter_max="$(parse_ping_metric "$jitter_summary" 3 "$jitter_file")"
  jitter_loss="$(extract_ping_loss_percent "$jitter_file")"

  large_avg="$(parse_ping_metric "$large_summary" 2 "$large_file")"
  large_max="$(parse_ping_metric "$large_summary" 3 "$large_file")"
  large_loss="$(extract_ping_loss_percent "$large_file")"

  for idx in "${!ramp_sizes[@]}"; do
    ramp_summary="$(extract_ping_summary_line "${ramping_files[$idx]}")"
    ramp_avg="$(parse_ping_metric "$ramp_summary" 2 "${ramping_files[$idx]}")"
    ramp_max="$(parse_ping_metric "$ramp_summary" 3 "${ramping_files[$idx]}")"
    ramp_loss="$(extract_ping_loss_percent "${ramping_files[$idx]}")"
    [[ -z "$ramp_avg" ]] && ramp_avg="0"
    [[ -z "$ramp_max" ]] && ramp_max="0"
    [[ -z "$ramp_loss" ]] && ramp_loss="0"
    ramping_avgs+=("$ramp_avg")
    ramping_maxes+=("$ramp_max")
    ramping_losses+=("$ramp_loss")
  done

  sustained_avg="$(parse_ping_metric "$sustained_summary" 2 "$sustained_file")"
  sustained_max="$(parse_ping_metric "$sustained_summary" 3 "$sustained_file")"
  sustained_loss="$(extract_ping_loss_percent "$sustained_file")"

  recovery_avg="$(parse_ping_metric "$recovery_summary" 2 "$recovery_file")"

  [[ -z "$baseline_avg" ]] && baseline_avg="0"
  [[ -z "$baseline_max" ]] && baseline_max="0"
  [[ -z "$baseline_stddev" ]] && baseline_stddev="0"
  [[ -z "$jitter_stddev" ]] && jitter_stddev="0"
  [[ -z "$jitter_max" ]] && jitter_max="0"
  [[ -z "$jitter_loss" ]] && jitter_loss="0"
  [[ -z "$large_avg" ]] && large_avg="0"
  [[ -z "$large_max" ]] && large_max="0"
  [[ -z "$large_loss" ]] && large_loss="0"
  [[ -z "$sustained_avg" ]] && sustained_avg="0"
  [[ -z "$sustained_max" ]] && sustained_max="0"
  [[ -z "$sustained_loss" ]] && sustained_loss="0"
  [[ -z "$recovery_avg" ]] && recovery_avg="0"

  if awk -v s="$jitter_stddev" 'BEGIN { exit !(s > 3) }'; then
    high_jitter=true
  fi

  if awk -v load="$sustained_avg" -v base="$baseline_avg" 'BEGIN { if (base <= 0) exit 1; exit !(load > (base * 5)) }'; then
    latency_under_load=true
  fi

  if awk -v j="$jitter_loss" -v l="$large_loss" -v s="$sustained_loss" 'BEGIN { exit !((j > 0) || (l > 0) || (s > 0)) }'; then
    packet_loss=true
  fi

  if awk -v r="$recovery_avg" -v b="$baseline_avg" 'BEGIN { if (b <= 0) exit 1; exit !(r > (b * 2)) }'; then
    slow_recovery=true
  fi

  if [[ "$slow_recovery" == "false" ]]; then
    returned_to_baseline=true
  fi

  if [[ "$stage_failure" == "true" ]]; then
    stage_warning="One or more stress sub-tests failed on this host or target. Results may be partial."
    warnings+=("$stage_warning")
    status="completed_with_warnings"
  fi
  if [[ -n "$stage_warning" ]]; then
    warning_json="$(printf '%s' "$stage_warning" | jq -R .)"
  fi

  json_tmp="$(mktemp)"
  if ! jq -n \
    --arg status "$status" \
    --argjson success true \
    --argjson warnings "$(json_string_array_from_array warnings)" \
    --arg function "$json_function_name" \
    --arg target_key "$report_target_key" \
    --arg target_ip "$target_ip" \
    --arg hostname "$hostname" \
    --arg interface "$iface" \
    --argjson completed_with_warnings "$stage_failure" \
    --argjson warning "$warning_json" \
    --arg baseline_status "$baseline_status" \
    --arg jitter_status "$jitter_status" \
    --arg large_status "$large_status" \
    --arg ramping_status "$ramping_status" \
    --arg sustained_status "$sustained_status" \
    --arg recovery_status "$recovery_status" \
    --argjson baseline_avg "$baseline_avg" \
    --argjson baseline_max "$baseline_max" \
    --argjson baseline_stddev "$baseline_stddev" \
    --argjson jitter_stddev "$jitter_stddev" \
    --argjson jitter_max "$jitter_max" \
    --argjson jitter_loss "$jitter_loss" \
    --argjson large_avg "$large_avg" \
    --argjson large_max "$large_max" \
    --argjson large_loss "$large_loss" \
    --argjson sustained_avg "$sustained_avg" \
    --argjson sustained_max "$sustained_max" \
    --argjson sustained_loss "$sustained_loss" \
    --argjson recovery_avg "$recovery_avg" \
    --argjson returned_to_baseline "$returned_to_baseline" \
    --argjson high_jitter "$high_jitter" \
    --argjson latency_under_load "$latency_under_load" \
    --argjson packet_loss "$packet_loss" \
    --argjson slow_recovery "$slow_recovery" \
    --argjson ramp_sizes "$(ports_to_json_array "${ramp_sizes[@]}")" \
    --argjson ramping_avgs "$(ports_to_json_array "${ramping_avgs[@]}")" \
    --argjson ramping_maxes "$(ports_to_json_array "${ramping_maxes[@]}")" \
    --argjson ramping_losses "$(ports_to_json_array "${ramping_losses[@]}")" '
      {
        status: $status,
        success: $success,
        error: null,
        warnings: $warnings,
        function: $function,
        ($target_key): $target_ip,
        hostname: $hostname,
        interface: $interface,
        completed_with_warnings: $completed_with_warnings,
        warning: $warning,
        stage_status: {
          baseline: $baseline_status,
          jitter: $jitter_status,
          large_packet: $large_status,
          ramping: $ramping_status,
          sustained: $sustained_status,
          recovery: $recovery_status
        },
        baseline: {
          avg_latency_ms: $baseline_avg,
          max_latency_ms: $baseline_max,
          stddev_ms: $baseline_stddev
        },
        jitter_test: {
          stddev_ms: $jitter_stddev,
          max_latency_ms: $jitter_max,
          packet_loss_percent: $jitter_loss
        },
        large_packet_test: {
          avg_latency_ms: $large_avg,
          max_latency_ms: $large_max,
          packet_loss_percent: $large_loss
        },
        ramping_test: [
          range(0; ($ramp_sizes | length)) as $i
          | {
              packet_size: $ramp_sizes[$i],
              avg_latency_ms: $ramping_avgs[$i],
              max_latency_ms: $ramping_maxes[$i],
              packet_loss_percent: $ramping_losses[$i]
            }
        ],
        sustained_test: {
          avg_latency_ms: $sustained_avg,
          max_latency_ms: $sustained_max,
          packet_loss_percent: $sustained_loss
        },
        recovery: {
          avg_latency_ms: $recovery_avg,
          returned_to_baseline: $returned_to_baseline
        },
        indicators: {
          high_jitter: $high_jitter,
          latency_under_load: $latency_under_load,
          packet_loss: $packet_loss,
          slow_recovery: $slow_recovery
        },
        methodology: "ICMP-based point-in-time stress test. Measures latency and packet loss under staged load; does not test throughput. Results represent conditions at the time of the test and may differ under real traffic or at different times of day."
      }' > "$json_tmp"; then
    rm -f "$json_tmp"
    echo "Failed to build stress-test JSON output."
    return 1
  fi

  mv "$json_tmp" "$json_file"

  copy_raw_artifact "$baseline_file" "${raw_prefix}-baseline.txt"
  copy_raw_artifact "$jitter_file" "${raw_prefix}-jitter.txt"
  copy_raw_artifact "$large_file" "${raw_prefix}-large-packet.txt"
  copy_raw_artifact "$sustained_file" "${raw_prefix}-sustained.txt"
  copy_raw_artifact "$recovery_file" "${raw_prefix}-recovery.txt"
  for idx in "${!ramp_sizes[@]}"; do
    copy_raw_artifact "${ramping_files[$idx]}" "${raw_prefix}-ramping-${ramp_sizes[$idx]}.txt"
  done

  rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file" "${ramping_files[@]}"

  echo
  echo "Baseline Latency"
  echo "Average: $baseline_avg ms"
  echo "Max: $baseline_max ms"
  echo "StdDev: $baseline_stddev ms"
  echo
  echo "Jitter Test"
  echo "StdDev: $jitter_stddev ms"
  echo "Max: $jitter_max ms"
  echo "Packet Loss: $jitter_loss%"
  echo
  echo "Large Packet Test"
  echo "Average: $large_avg ms"
  echo "Max: $large_max ms"
  echo "Packet Loss: $large_loss%"
  echo
  echo "Ramping Test"
  echo "------------------------------"
  for idx in "${!ramp_sizes[@]}"; do
    printf "%s bytes\tAvg: %s ms | Max: %s ms | Loss: %s%%\n" "${ramp_sizes[$idx]}" "${ramping_avgs[$idx]}" "${ramping_maxes[$idx]}" "${ramping_losses[$idx]}"
  done
  echo
  echo "Sustained Load Test"
  echo "Average: $sustained_avg ms"
  echo "Max: $sustained_max ms"
  echo "Packet Loss: $sustained_loss%"
  echo
  echo "Recovery"
  if [[ "$returned_to_baseline" == "true" ]]; then
    echo "Target returned to baseline: YES"
  else
    echo "Target returned to baseline: NO"
  fi
  echo
  if ! validate_json_file "$json_file"; then
    echo "Stress-test JSON validation failed."
    return 1
  fi
}

custom_target_stress_test() {
  local target_ip

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Custom Target Stress Test"
  fi

  target_ip="$(prompt_for_target_ip "Target IP Address: ")"
  echo "Stage 1: Preparing custom target stress test..."
  run_stress_test_for_target \
    "$target_ip" \
    "$SELECTED_INTERFACE" \
    "13" \
    "Function 13" \
    "the specified target host $target_ip" \
    "Target IP" \
    "custom_target_stress_test" \
    "target_ip"
}

parse_ping_metric() {
  local summary_line="$1"
  local metric_index="$2"
  local file="${3:-}"
  local value
  value="$(echo "$summary_line" | awk -F'=' '{print $2}' | awk -F'/' -v idx="$metric_index" '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $idx); print $idx}')"
  value="$(echo "$value" | sed 's/[^0-9.]*//g')"

  if [[ -n "$value" ]]; then
    echo "$value"
    return
  fi

  if [[ -z "$file" ]]; then
    return
  fi

  case "$metric_index" in
    2) calculate_ping_metric_from_output "$file" "avg" ;;
    3) calculate_ping_metric_from_output "$file" "max" ;;
    4) calculate_ping_metric_from_output "$file" "stddev" ;;
  esac
}

gateway_stress_test() {
  local interface_info_file
  local gateway
  local iface

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Gateway Stress Test"
  fi

  echo "Stage 1: Running Interface Network Info..."
  interface_info "$SELECTED_INTERFACE" silent

  interface_info_file="$(task_output_path 1)"

  if [[ ! -f "$interface_info_file" ]]; then
    echo "Gateway could not be detected."
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "interface_info_missing" \
      --arg error_message "Gateway detection failed because Interface Network Info output was not available." \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: "gateway_stress_test", gateway: null, hostname: "unknown", interface: null}' > "$(task_output_path 10)"
    validate_json_file "$(task_output_path 10)"
    return 1
  fi

  gateway="$(jq -r '.gateway // empty' "$interface_info_file")"
  iface="$(jq -r '.interface // empty' "$interface_info_file")"

  if [[ -z "$gateway" && -n "$iface" ]]; then
    gateway="$(get_gateway_ip "$iface")"
  fi

  if [[ -z "$gateway" || "$gateway" == "null" ]]; then
    echo "Gateway could not be detected."
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "gateway_not_detected" \
      --arg error_message "No default gateway could be determined for the selected interface." \
      --arg interface "$iface" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: "gateway_stress_test", gateway: null, hostname: "unknown", interface: $interface}' > "$(task_output_path 10)"
    validate_json_file "$(task_output_path 10)"
    return 1
  fi

  [[ -z "$iface" || "$iface" == "null" ]] && iface="$SELECTED_INTERFACE"

  if ! is_rfc1918_ip "$gateway"; then
    echo "Gateway IP $gateway is publicly routable — stress test skipped."
    echo "See Gateway Details (Task 3) for details."
    jq -n \
      --arg gateway "$gateway" \
      --arg interface "$iface" \
      '{
        status: "skipped",
        success: false,
        skip_reason: "gateway_public_ip",
        skip_message: ("Gateway IP " + $gateway + " is publicly routable. Stress testing has been skipped — the device is enterprise or carrier infrastructure not designed to serve a local LAN, and the test would produce no meaningful results."),
        error: null,
        warnings: [],
        function: "gateway_stress_test",
        gateway: $gateway,
        hostname: "unknown",
        interface: $interface
      }' > "$(task_output_path 10)"
    validate_json_file "$(task_output_path 10)"
    return 0
  fi

  run_stress_test_for_target \
    "$gateway" \
    "$iface" \
    "10" \
    "Function 10" \
    "the detected local gateway/firewall" \
    "Gateway" \
    "gateway_stress_test" \
    "gateway"
}

dhcp_network_scan() {
  local raw_server_ids=()
  local unique_servers=()
  local suspected_rogue_servers=()
  local relay_sources_seen=()
  local raw_attempt_excerpts=()
  local relay_source
  local server
  local idx
  local dhcp_output_file
  local tcpdump_output_file
  local json_file
  local -a dhcp_cmd
  local discovery_attempts=5
  local attempt
  local gateway_ip=""
  local raw_prefix
  local raw_offers_observed=0
  local unique_offers_observed=0
  local rogue_detected=false
  local discovery_note="DHCP detection uses repeated broadcast discovery attempts. Only responders that replied to at least one attempt are listed. Offer counts are deduplicated by Server Identifier and IP Offered to reduce relay noise."
  local offer_record
  local server_id
  local offered_ip
  local -a unique_offer_keys=()
  local attempt_excerpt
  local tcpdump_pid=""
  local tcpdump_enabled=false
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "DHCP Network Scan"
  fi
  echo "Stage 1: Discovering DHCP servers on interface $SELECTED_INTERFACE..."
  raw_prefix="$(task_raw_prefix 4)"

  dhcp_output_file="$(mktemp)"
  if [[ -z "$dhcp_output_file" || ! -f "$dhcp_output_file" ]]; then
    echo "Error: Unable to create a temporary file for DHCP discovery."
    write_dhcp_failure_json "tempfile_creation_failed" "Unable to create a temporary file for DHCP discovery." "$discovery_attempts"
    return 1
  fi
  if [[ "$EUID" -eq 0 ]]; then
    dhcp_cmd=(nmap --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE")
  elif command -v sudo >/dev/null 2>&1; then
    dhcp_cmd=(sudo nmap --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE")
  else
    echo "DHCP discovery usually requires root privileges. Re-run as root or install sudo."
    write_dhcp_failure_json "dhcp_privilege_required" "DHCP discovery usually requires root privileges. Re-run as root or install sudo." "$discovery_attempts"
    return 1
  fi

  gateway_ip="$(get_gateway_ip "$SELECTED_INTERFACE")"
  if ! command -v tcpdump >/dev/null 2>&1; then
    warnings+=("tcpdump is not available, so relay or proxy DHCP sources cannot be captured.")
  elif [[ "$EUID" -ne 0 ]]; then
    warnings+=("tcpdump capture was skipped because the script is not running as root.")
  fi

  for ((attempt = 1; attempt <= discovery_attempts; attempt++)); do
    echo "DHCP discovery attempt $attempt of $discovery_attempts..."
    tcpdump_output_file="$(mktemp)"
    if [[ -z "$tcpdump_output_file" || ! -f "$tcpdump_output_file" ]]; then
      echo "Error: Unable to create a temporary file for DHCP packet capture."
      rm -f "$dhcp_output_file"
      write_dhcp_failure_json "tempfile_creation_failed" "Unable to create a temporary file for DHCP packet capture." "$discovery_attempts"
      return 1
    fi
    tcpdump_pid="$(capture_dhcp_traffic "$SELECTED_INTERFACE" "$tcpdump_output_file" || true)"
    if [[ -n "$tcpdump_pid" ]]; then
      tcpdump_enabled=true
      sleep 1
    fi

    "${dhcp_cmd[@]}" > "$dhcp_output_file" 2>/dev/null &
    local dhcp_discovery_pid=$!
    spinner
    wait_for_pid "$dhcp_discovery_pid" "DHCP discovery attempt $attempt failed." || {
      if [[ -n "$tcpdump_pid" ]]; then
        kill "$tcpdump_pid" 2>/dev/null || true
        wait "$tcpdump_pid" 2>/dev/null || true
      fi
      rm -f "$tcpdump_output_file"
      rm -f "$dhcp_output_file"
      write_dhcp_failure_json "dhcp_discovery_attempt_failed" "A DHCP discovery attempt did not complete successfully." "$discovery_attempts"
      return 1
    }

    if [[ -n "$tcpdump_pid" ]]; then
      kill "$tcpdump_pid" 2>/dev/null || true
      wait "$tcpdump_pid" 2>/dev/null || true
      tcpdump_pid=""
    fi

    while IFS= read -r offer_record; do
      [[ -z "$offer_record" ]] && continue
      raw_offers_observed=$((raw_offers_observed + 1))
      server_id="${offer_record%%$'\t'*}"
      offered_ip="${offer_record#*$'\t'}"
      if [[ "$offered_ip" == "$offer_record" ]]; then
        offered_ip=""
      fi

      if [[ -n "$server_id" ]]; then
        raw_server_ids+=("$server_id")
      fi

      local offer_key="${server_id}|${offered_ip}"
      if [[ "${#unique_offer_keys[@]}" -eq 0 ]] || ! array_contains "$offer_key" "${unique_offer_keys[@]}"; then
        unique_offer_keys+=("$offer_key")
        unique_offers_observed=$((unique_offers_observed + 1))
      fi
    done < <(extract_dhcp_offer_records "$dhcp_output_file")

    while IFS= read -r relay_source; do
      [[ -z "$relay_source" ]] && continue
      if [[ "${#relay_sources_seen[@]}" -eq 0 ]] || ! array_contains "$relay_source" "${relay_sources_seen[@]}"; then
        relay_sources_seen+=("$relay_source")
      fi
    done < <(extract_dhcp_packet_sources "$tcpdump_output_file")

    attempt_excerpt="$(extract_dhcp_attempt_excerpt "$dhcp_output_file")"
    raw_attempt_excerpts+=("$attempt_excerpt")

    copy_raw_artifact "$dhcp_output_file" "$(printf '%s-attempt-%02d.txt' "$raw_prefix" "$attempt")"
    if [[ -s "$tcpdump_output_file" ]]; then
      copy_raw_artifact "$tcpdump_output_file" "$(printf '%s-tcpdump-%02d.txt' "$raw_prefix" "$attempt")"
    fi

    rm -f "$tcpdump_output_file"
  done

  rm -f "$dhcp_output_file"

  if [[ "${#raw_server_ids[@]}" -gt 0 ]]; then
    while IFS= read -r server; do
      [[ -n "$server" ]] && unique_servers+=("$server")
    done < <(printf "%s\n" "${raw_server_ids[@]}" | awk '!seen[$0]++')
  fi

  echo "DHCP responders observed: ${#unique_servers[@]}"
  echo "Unique DHCP offers observed across attempts: $unique_offers_observed"
  echo "Raw DHCP offers captured across attempts: $raw_offers_observed"

  if [[ "${#unique_servers[@]}" -gt 0 ]]; then
    for idx in "${!unique_servers[@]}"; do
      echo "DHCP IP Address: ${unique_servers[$idx]}"
    done
  fi

  echo

  json_file="$(task_output_path 4)"
  jq -n \
    --arg status "success" \
    --argjson success true \
    --argjson warnings '[]' \
    --argjson dhcp_responders_observed "${#unique_servers[@]}" \
    --argjson discovery_attempts "$discovery_attempts" \
    --argjson offers_observed "$unique_offers_observed" \
    --argjson raw_offers_observed "$raw_offers_observed" \
    --argjson relay_sources_seen "$(json_string_array_from_array relay_sources_seen)" \
    --argjson tcpdump_capture_used "$tcpdump_enabled" \
    --arg discovery_note "$discovery_note" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
      dhcp_responders_observed: $dhcp_responders_observed,
      discovery_attempts: $discovery_attempts,
      offers_observed: $offers_observed,
      raw_offers_observed: $raw_offers_observed,
      relay_sources_seen: $relay_sources_seen,
      tcpdump_capture_used: $tcpdump_capture_used,
      rogue_dhcp_suspected: false,
      suspected_rogue_servers: [],
      discovery_note: $discovery_note,
      raw_attempts: [],
      servers: []
    }' > "$json_file" || {
      echo "Failed to create DHCP JSON output."
      return 1
    }

  for idx in "${!raw_attempt_excerpts[@]}"; do
    jq \
      --argjson attempt "$((idx + 1))" \
      --arg output_excerpt "${raw_attempt_excerpts[$idx]}" \
      '.raw_attempts += [{
        attempt: $attempt,
        output_excerpt: $output_excerpt
      }]' \
      "$json_file" > "$json_file.tmp" || {
        echo "Failed to append DHCP raw attempt data."
        return 1
      }
    mv "$json_file.tmp" "$json_file"
  done

  if [[ "${#unique_servers[@]}" -eq 0 ]]; then
    warnings+=("No DHCP responders were observed during the discovery attempts. This does not necessarily mean that no DHCP server exists on the network.")
    status="completed_with_warnings"
    if [[ "${#warnings[@]}" -gt 0 ]]; then
      update_dhcp_json_status "$json_file" "$status" "$success" "$error_code" "$error_message" "${warnings[@]}" || {
        echo "Failed to finalize DHCP JSON status."
        return 1
      }
    else
      update_dhcp_json_status "$json_file" "$status" "$success" "$error_code" "$error_message" || {
        echo "Failed to finalize DHCP JSON status."
        return 1
      }
    fi
    validate_json_file "$json_file"
    return 0
  fi

  echo "Stage 2: Scanning for ports on DHCP server(s)..."

  for idx in "${!unique_servers[@]}"; do
    local open_ports=()
    local dhcp_scan_file
    local port
    local classification
    local suspected_rogue=false
    local offer_count=0
    server="${unique_servers[$idx]}"

    echo
    echo "Scanning common ports on Server $((idx + 1))..."

    dhcp_scan_file="$(mktemp)"
    local port_scan_ok=true
    if [[ -z "$dhcp_scan_file" || ! -f "$dhcp_scan_file" ]]; then
      warnings+=("Could not create temp file for port scan of DHCP server $server. Port data will be absent.")
      port_scan_ok=false
    else
      nmap --top-ports 1000 --open "$server" -oG - > "$dhcp_scan_file" 2>/dev/null &
      local dhcp_scan_pid=$!
      monitor_nmap_progress "$dhcp_scan_pid" "$dhcp_scan_file" 180 "ports" "Open Ports:" "DHCP server port scan failed for $server." || {
        rm -f "$dhcp_scan_file"
        warnings+=("Port scan of DHCP server $server did not complete. Port data will be absent.")
        port_scan_ok=false
      }
    fi
    echo

    if [[ "$port_scan_ok" == "true" ]]; then
      while IFS= read -r port; do
        [[ -n "$port" ]] && open_ports+=("$port")
      done < <(awk '
        /Ports:/ {
          split($0, parts, "Ports: ")
          if (length(parts) < 2) {
            next
          }

          n = split(parts[2], ports, ",")
          for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", ports[i])
            split(ports[i], fields, "/")
            if (fields[2] == "open" && fields[1] ~ /^[0-9]+$/) {
              print fields[1]
            }
          }
        }
      ' "$dhcp_scan_file")
      rm -f "$dhcp_scan_file"
    fi

    offer_count="$(printf '%s\n' "${raw_server_ids[@]}" | awk -v target="$server" '$0 == target {count++} END {print count+0}')"
    classification="$(classify_dhcp_server "$server" "$gateway_ip" ${open_ports[@]+"${open_ports[@]}"})"
    if [[ "$classification" == "unknown" ]]; then
      suspected_rogue=true
      rogue_detected=true
      suspected_rogue_servers+=("$server")
    fi

    echo "Unique Offers Observed: $(count_unique_offer_keys_for_server "$server" "${unique_offer_keys[@]:-}")"
    echo "Raw Offers Captured: $offer_count"
    echo "Classification: $classification"
    if [[ "$port_scan_ok" == "true" && "${#open_ports[@]}" -eq 0 ]]; then
      echo "Warning: No open TCP ports were detected on this DHCP responder."
      warnings+=("No open TCP ports were detected on DHCP responder $server.")
    fi
    if [[ "$suspected_rogue" == "true" ]]; then
      echo "Suspected Rogue DHCP Responder: YES"
    else
      echo "Suspected Rogue DHCP Responder: NO"
    fi

    jq \
      --arg ip "$server" \
      --argjson open_ports "$(ports_to_json_array ${open_ports[@]+"${open_ports[@]}"})" \
      --argjson offers_observed "$(count_unique_offer_keys_for_server "$server" "${unique_offer_keys[@]:-}")" \
      --argjson raw_offers_observed "$offer_count" \
      --arg classification "$classification" \
      --argjson suspected_rogue "$suspected_rogue" \
      '.servers += [{
        ip: $ip,
        open_ports: $open_ports,
        offers_observed: $offers_observed,
        raw_offers_observed: $raw_offers_observed,
        classification: $classification,
        suspected_rogue: $suspected_rogue
      }]' \
      "$json_file" > "$json_file.tmp" || {
        echo "Failed to append DHCP server data for $server."
        return 1
      }
    mv "$json_file.tmp" "$json_file"
  done

  jq \
    --argjson rogue_dhcp_suspected "$rogue_detected" \
    --argjson suspected_rogue_servers "$(json_string_array_from_array suspected_rogue_servers)" \
    '.rogue_dhcp_suspected = $rogue_dhcp_suspected
     | .suspected_rogue_servers = $suspected_rogue_servers' \
    "$json_file" > "$json_file.tmp" || {
      echo "Failed to finalize DHCP JSON output."
      return 1
    }
  mv "$json_file.tmp" "$json_file"

  if [[ "${#warnings[@]}" -gt 0 ]]; then
    status="completed_with_warnings"
  fi
  if [[ "${#warnings[@]}" -gt 0 ]]; then
    update_dhcp_json_status "$json_file" "$status" "$success" "$error_code" "$error_message" "${warnings[@]}" || {
      echo "Failed to finalize DHCP JSON status."
      return 1
    }
  else
    update_dhcp_json_status "$json_file" "$status" "$success" "$error_code" "$error_message" || {
      echo "Failed to finalize DHCP JSON status."
      return 1
    }
  fi

  validate_json_file "$json_file"
}

dhcp_response_time() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  local tmp_py
  local probe_count=10
  local status="success"
  local success=true
  local warnings=()
  local warnings_json="[]"

  json_file="$(task_output_path 5)"

  echo
  echo "DHCP Response Time"
  echo "=================="

  if [[ -z "$iface" ]]; then
    jq -n '{status:"failed",success:false,error:{code:"NO_INTERFACE",message:"No network interface selected."},warnings:[],interface:null,probe_count:0,responded_count:0,response_times_ms:[],min_ms:null,avg_ms:null,max_ms:null,packet_loss_percent:100,server_ip:null,indicators:{slow_response:false,high_loss:false}}' > "$json_file"
    echo "No interface selected. Skipping."
    return 1
  fi

  # Detect Wi-Fi: Linux uses sysfs wireless dir; macOS uses networksetup
  local is_wifi=false
  if [[ -d "/sys/class/net/$iface/wireless" ]]; then
    is_wifi=true
  elif networksetup -listallhardwareports 2>/dev/null | awk -v dev="$iface" '
    /Hardware Port: Wi-Fi/{wifi=1}
    wifi && /Device: / && $2==dev{found=1}
    /Hardware Port:/ && !/Wi-Fi/{wifi=0}
    END{exit !found}'; then
    is_wifi=true
  fi

  echo "Interface:   $iface"
  $is_wifi && echo "Type:        Wi-Fi (wireless)"
  echo "Probes:      $probe_count"
  echo "Sending DHCP Discover broadcasts and timing Offer responses..."

  tmp_py="$(mktemp /tmp/lss-dhcp-rt-XXXXXX)"
  cat > "$tmp_py" <<'PYEOF'
import sys, json, time, random, socket, struct

iface       = sys.argv[1]
probe_count = int(sys.argv[2])

DHCP_MAGIC = b'\x63\x82\x53\x63'

def make_dhcp_discover(xid, mac_bytes):
    chaddr = bytes(mac_bytes) + b'\x00' * 10
    bootp = struct.pack('!BBBBIHH4s4s4s4s16s64s128s',
        1,           # op: BOOTREQUEST
        1,           # htype: Ethernet
        6,           # hlen: MAC address length
        0,           # hops
        xid,         # transaction ID
        0,           # secs elapsed
        0x8000,      # flags: broadcast bit set (server must broadcast reply)
        b'\x00'*4,   # ciaddr: client IP (0.0.0.0 — not yet assigned)
        b'\x00'*4,   # yiaddr
        b'\x00'*4,   # siaddr
        b'\x00'*4,   # giaddr
        chaddr,      # chaddr: client hardware address (16 bytes)
        b'\x00'*64,  # sname
        b'\x00'*128, # file
    )
    options = (
        DHCP_MAGIC +
        b'\x35\x01\x01' +  # option 53: DHCP Message Type = Discover (1)
        b'\xff'             # option 255: End
    )
    return bootp + options

def parse_server_ip(bootp, sender_ip):
    # Prefer DHCP option 54 (Server Identifier)
    if len(bootp) > 240 and bootp[236:240] == DHCP_MAGIC:
        i = 240
        while i < len(bootp) - 2:
            opt = bootp[i]
            if opt == 255:
                break
            if opt == 0:
                i += 1
                continue
            length = bootp[i+1]
            if opt == 54 and length == 4:
                return socket.inet_ntoa(bootp[i+2:i+6])
            i += 2 + length
    # Fallback: siaddr field in BOOTP header (bytes 20-23)
    if len(bootp) >= 24:
        siaddr = socket.inet_ntoa(bootp[20:24])
        if siaddr != '0.0.0.0':
            return siaddr
    return sender_ip

def is_dhcp_offer(bootp, xid):
    if len(bootp) < 244:
        return False
    if bootp[0] != 2:  # BOOTREPLY
        return False
    if bootp[236:240] != DHCP_MAGIC:
        return False
    if struct.unpack('!I', bootp[4:8])[0] != xid:
        return False
    i = 240
    while i < len(bootp) - 2:
        opt = bootp[i]
        if opt == 255:
            break
        if opt == 0:
            i += 1
            continue
        length = bootp[i+1]
        if opt == 53 and length == 1:
            return bootp[i+2] == 2  # DHCP Offer
        i += 2 + length
    return False

def extract_bootp_from_raw(raw):
    # raw = IP header + UDP header + BOOTP payload
    # Parse IP header length (variable due to options)
    if len(raw) < 28:
        return None, None
    ip_hdr_len = (raw[0] & 0x0f) * 4
    if len(raw) < ip_hdr_len + 8:
        return None, None
    # UDP header: src(2) dst(2) len(2) cksum(2)
    dst_port = struct.unpack('!H', raw[ip_hdr_len+2:ip_hdr_len+4])[0]
    if dst_port != 68:
        return None, None
    # Extract source IP from IP header (bytes 12-15)
    src_ip = socket.inet_ntoa(raw[12:16])
    bootp  = raw[ip_hdr_len+8:]
    return bootp, src_ip

results   = []
server_ip = None

# Receive strategy:
#   1. Try SOCK_DGRAM bound to port 68 (preferred on macOS — the system DHCP
#      client uses BPF internally, so port 68 is usually free; DGRAM reliably
#      delivers broadcast UDP on Wi-Fi where SOCK_RAW sometimes misses frames).
#   2. Fall back to SOCK_RAW(IPPROTO_UDP) when port 68 is not bindable (Linux,
#      where dhclient or systemd-networkd holds port 68 as a real UDP socket).
use_raw   = False
recv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
recv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if hasattr(socket, 'SO_REUSEPORT'):
    recv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
recv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    recv_sock.bind(('', 68))
except OSError:
    # Port 68 is held exclusively — fall back to SOCK_RAW
    recv_sock.close()
    try:
        recv_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_UDP)
        use_raw = True
    except PermissionError:
        print(json.dumps({"error": "probe_error: cannot bind port 68 and raw socket requires root"}))
        sys.exit(0)

# Send socket — standard DGRAM broadcast
send_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
send_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

def pin_sock_to_iface(sock, iface):
    """Pin a socket to a specific interface, cross-platform."""
    # Linux: SO_BINDTODEVICE (SOL_SOCKET, 25)
    try:
        sock.setsockopt(socket.SOL_SOCKET, 25, iface.encode() + b'\x00')
        return
    except (AttributeError, OSError):
        pass
    # macOS: IP_BOUND_IF (IPPROTO_IP, 25) — pins by interface index, works
    # for both send and recv on any interface without needing a pre-existing IP.
    try:
        idx = socket.if_nametoindex(iface)
        sock.setsockopt(socket.IPPROTO_IP, 25, struct.pack('I', idx))
    except (AttributeError, OSError):
        pass

pin_sock_to_iface(recv_sock, iface)
pin_sock_to_iface(send_sock, iface)

try:
    for i in range(probe_count):
        mac_bytes    = [random.randint(0x00, 0xff) for _ in range(6)]
        mac_bytes[0] = mac_bytes[0] & 0xfe  # clear multicast bit
        xid          = random.randint(1, 0xffffffff)
        pkt          = make_dhcp_discover(xid, mac_bytes)

        t_start   = time.time()
        send_sock.sendto(pkt, ('255.255.255.255', 67))
        got_offer = False
        deadline  = t_start + 5

        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            recv_sock.settimeout(remaining)
            try:
                raw, addr = recv_sock.recvfrom(1500)
                if use_raw:
                    bootp, src_ip = extract_bootp_from_raw(raw)
                else:
                    # SOCK_DGRAM delivers the BOOTP payload directly (no IP/UDP headers)
                    bootp, src_ip = raw, addr[0]
                if bootp is not None and is_dhcp_offer(bootp, xid):
                    elapsed_ms = round((time.time() - t_start) * 1000, 1)
                    results.append(elapsed_ms)
                    if server_ip is None:
                        server_ip = parse_server_ip(bootp, src_ip)
                    got_offer = True
                    break
            except socket.timeout:
                break

        if not got_offer:
            results.append(None)

        if i < probe_count - 1:
            time.sleep(0.5)

except Exception as e:
    print(json.dumps({"error": f"probe_error: {e}"}))
    sys.exit(0)
finally:
    recv_sock.close()
    send_sock.close()

responded = [r for r in results if r is not None]
loss_pct  = round((probe_count - len(responded)) / probe_count * 100, 1)
avg_ms    = round(sum(responded) / len(responded), 1) if responded else None
min_ms    = min(responded) if responded else None
max_ms    = max(responded) if responded else None

print(json.dumps({
    "probe_count":         probe_count,
    "responded_count":     len(responded),
    "response_times_ms":   results,
    "min_ms":              min_ms,
    "avg_ms":              avg_ms,
    "max_ms":              max_ms,
    "packet_loss_percent": loss_pct,
    "server_ip":           server_ip,
}))
PYEOF

  local py_result
  local py_stderr_log
  py_stderr_log="$(mktemp /tmp/lss-dhcp-rt-stderr-XXXXXX.txt)"
  py_result="$(python3 "$tmp_py" "$iface" "$probe_count" 2>"$py_stderr_log" || echo '{"error":"python_failed"}')"
  rm -f "$tmp_py"

  # Surface stderr into the JSON error if the script itself crashed
  if [[ "$(jq -r '.error // empty' <<< "$py_result" 2>/dev/null)" == "python_failed" ]]; then
    local stderr_content
    stderr_content="$(cat "$py_stderr_log" 2>/dev/null | head -3 | tr '\n' ' ')" || true
    py_result="$(jq -n --arg e "python_failed: ${stderr_content}" '{error: $e}')"
  fi
  rm -f "$py_stderr_log"

  if [[ "$(jq -r '.error // empty' <<< "$py_result")" != "" ]]; then
    local err_msg
    err_msg="$(jq -r '.error' <<< "$py_result")"
    echo "Error: $err_msg"
    jq -n \
      --arg iface "$iface" \
      --arg err "$err_msg" \
      '{status:"failed",success:false,error:{code:"PROBE_FAILED",message:$err},warnings:[],interface:$iface,probe_count:0,responded_count:0,response_times_ms:[],min_ms:null,avg_ms:null,max_ms:null,packet_loss_percent:100,server_ip:null,indicators:{slow_response:false,high_loss:false}}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi

  local responded_count packet_loss avg_ms min_ms max_ms server_ip_val
  responded_count="$(jq -r '.responded_count // 0'         <<< "$py_result")"
  packet_loss="$(    jq -r '.packet_loss_percent // 0'     <<< "$py_result")"
  avg_ms="$(         jq -r '.avg_ms // "null"'             <<< "$py_result")"
  min_ms="$(         jq -r '.min_ms // "null"'             <<< "$py_result")"
  max_ms="$(         jq -r '.max_ms // "null"'             <<< "$py_result")"
  server_ip_val="$(  jq -r '.server_ip // empty'           <<< "$py_result")"

  echo "Responded:   $responded_count / $probe_count"
  echo "Loss:        ${packet_loss}%"
  if [[ "$avg_ms" != "null" && -n "$avg_ms" ]]; then
    echo "Min/Avg/Max: ${min_ms} / ${avg_ms} / ${max_ms} ms"
  fi
  [[ -n "$server_ip_val" ]] && echo "DHCP Server: $server_ip_val"

  local ind_slow=false ind_loss=false

  if [[ "$responded_count" -eq 0 ]]; then
    warnings+=("No DHCP Offer was received for any of the $probe_count Discover probes. Verify DHCP service is active and reachable on this interface.")
    ind_loss=true
    status="completed_with_warnings"
  else
    if awk "BEGIN{exit !($packet_loss > 0)}"; then
      warnings+=("Packet loss observed: ${packet_loss}% of DHCP Discover probes received no Offer.")
      ind_loss=true
      status="completed_with_warnings"
    fi
    if $is_wifi; then
      # Wi-Fi naturally adds 100–500 ms — use relaxed thresholds
      if [[ "$avg_ms" != "null" ]] && awk "BEGIN{exit !($avg_ms > 2000)}"; then
        warnings+=("DHCP response time is critically slow (avg ${avg_ms} ms) even for a Wi-Fi connection. Re-test on a wired connection; wired servers should respond within 50 ms.")
        ind_slow=true
        status="completed_with_warnings"
      elif [[ "$avg_ms" != "null" ]] && awk "BEGIN{exit !($avg_ms > 500)}"; then
        warnings+=("DHCP response time is elevated (avg ${avg_ms} ms). This was measured over Wi-Fi, which adds inherent latency; re-test on a wired connection for a reliable baseline.")
        ind_slow=true
        status="completed_with_warnings"
      fi
    else
      if [[ "$avg_ms" != "null" ]] && awk "BEGIN{exit !($avg_ms > 500)}"; then
        warnings+=("DHCP response time is critically slow (avg ${avg_ms} ms). Healthy servers typically respond within 50 ms.")
        ind_slow=true
        status="completed_with_warnings"
      elif [[ "$avg_ms" != "null" ]] && awk "BEGIN{exit !($avg_ms > 200)}"; then
        warnings+=("DHCP response time is elevated (avg ${avg_ms} ms). Healthy servers typically respond within 50 ms.")
        ind_slow=true
        status="completed_with_warnings"
      fi
    fi
  fi

  warnings_json="$(printf '%s\n' "${warnings[@]+"${warnings[@]}"}" | jq -Rs '[split("\n")[] | select(length > 0)]')"

  local times_json
  times_json="$(jq -c '.response_times_ms' <<< "$py_result")"

  local avg_arg min_arg max_arg
  avg_arg="$(jq -c '.avg_ms' <<< "$py_result")"
  min_arg="$(jq -c '.min_ms' <<< "$py_result")"
  max_arg="$(jq -c '.max_ms' <<< "$py_result")"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg iface "$iface" \
    --argjson probe_count "$probe_count" \
    --argjson responded_count "$responded_count" \
    --argjson times "$times_json" \
    --argjson avg_ms "$avg_arg" \
    --argjson min_ms "$min_arg" \
    --argjson max_ms "$max_arg" \
    --argjson loss "$packet_loss" \
    --arg server_ip "$server_ip_val" \
    --argjson ind_slow "$ind_slow" \
    --argjson ind_loss "$ind_loss" \
    --argjson is_wifi "$is_wifi" \
    --argjson warnings "$warnings_json" \
    '{
      status:               $status,
      success:              $success,
      error:                null,
      warnings:             $warnings,
      methodology:          "DHCP Discover-to-Offer latency measured using UDP broadcast probes. Each probe sends a DHCP Discover and waits for the matching Offer. Offers are received via SOCK_DGRAM on port 68 (macOS) or SOCK_RAW (Linux). Results reflect point-in-time conditions; latency may differ under peak load or when many devices are renewing leases simultaneously.",
      interface:            $iface,
      is_wifi:              $is_wifi,
      probe_count:          $probe_count,
      responded_count:      $responded_count,
      response_times_ms:    $times,
      min_ms:               $min_ms,
      avg_ms:               $avg_ms,
      max_ms:               $max_ms,
      packet_loss_percent:  $loss,
      server_ip:            (if $server_ip == "" then null else $server_ip end),
      indicators: {
        slow_response: $ind_slow,
        high_loss:     $ind_loss
      }
    }' > "$json_file"

  validate_json_file "$json_file"
  return 0
}

render_interface_info_report() {
  local file="$1"
  local report_file="$2"
  local iface ip subnet network mac gateway
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  ip="$(jq -r '.ip_address // "unknown"' "$file" 2>/dev/null)"
  subnet="$(jq -r '.subnet // "unknown"' "$file" 2>/dev/null)"
  network="$(jq -r '.network // "unknown"' "$file" 2>/dev/null)"
  gateway="$(jq -r '.gateway // "unknown"' "$file" 2>/dev/null)"
  mac="$(jq -r '.mac_address // "unknown"' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Interface: ${iface:-unknown}"
    echo "IP Address: ${ip:-unknown}"
    echo "Subnet Mask: ${subnet:-unknown}"
    echo "Network Range: ${network:-unknown}"
    echo "Gateway: ${gateway:-unknown}"
    echo "MAC Address: ${mac:-unknown}"
  } >> "$report_file"
}

render_gateway_report() {
  local file="$1"
  local report_file="$2"
  local gateway ports
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  gateway="$(jq -r '.gateway_ip // "unknown"' "$file" 2>/dev/null)"
  ports="$(jq -r '(.open_ports // []) | map(tostring) | join(", ")' "$file" 2>/dev/null)"

  if [[ "$status" == "skipped" ]]; then
    local skip_message
    skip_message="$(jq -r '.skip_message // "Scan was skipped."' "$file" 2>/dev/null)"
    {
      echo "Status: skipped"
      echo "Gateway IP: ${gateway:-unknown}"
      echo "Reason: $skip_message"
    } >> "$report_file"
    return 0
  fi

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Gateway IP: ${gateway:-unknown}"
    if [[ -n "$ports" ]]; then
      echo "Open Ports: $ports"
    else
      echo "Open Ports: none found"
    fi
  } >> "$report_file"
}

render_gateway_stress_report() {
  local file="$1"
  local report_file="$2"
  local gateway iface baseline_avg sustained_avg high_jitter latency_under_load packet_loss slow_recovery
  local completed_with_warnings warning stage_status
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  gateway="$(jq -r '.gateway // "unknown"' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"

  if [[ "$status" == "skipped" ]]; then
    local skip_message
    skip_message="$(jq -r '.skip_message // "Stress test was skipped."' "$file" 2>/dev/null)"
    {
      echo "Status: skipped"
      echo "Gateway IP: ${gateway:-unknown}"
      echo "Reason: $skip_message"
    } >> "$report_file"
    return 0
  fi
  completed_with_warnings="$(jq -r '.completed_with_warnings // false' "$file" 2>/dev/null)"
  warning="$(jq -r '.warning // empty' "$file" 2>/dev/null)"
  stage_status="$(jq -r '.stage_status // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' "$file" 2>/dev/null)"
  baseline_avg="$(jq -r '.baseline.avg_latency_ms // "unavailable"' "$file" 2>/dev/null)"
  sustained_avg="$(jq -r '.sustained_test.avg_latency_ms // "unavailable"' "$file" 2>/dev/null)"
  high_jitter="$(jq -r '.indicators.high_jitter // false' "$file" 2>/dev/null)"
  latency_under_load="$(jq -r '.indicators.latency_under_load // false' "$file" 2>/dev/null)"
  packet_loss="$(jq -r '.indicators.packet_loss // false' "$file" 2>/dev/null)"
  slow_recovery="$(jq -r '.indicators.slow_recovery // false' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Gateway IP: ${gateway}"
    echo "Interface: ${iface}"
    echo "Completed With Warnings: ${completed_with_warnings}"
    if [[ -n "$warning" ]]; then
      echo "Warning: ${warning}"
    fi
    if [[ -n "$stage_status" ]]; then
      echo "Stage Status: ${stage_status}"
    fi
    echo "Baseline Avg Latency: ${baseline_avg} ms"
    echo "Sustained Avg Latency: ${sustained_avg} ms"
    echo "High Jitter: ${high_jitter}"
    echo "Latency Under Load: ${latency_under_load}"
    echo "Packet Loss Detected: ${packet_loss}"
    echo "Slow Recovery: ${slow_recovery}"
  } >> "$report_file"
}

render_custom_target_port_scan_report() {
  local file="$1"
  local report_file="$2"
  local target_ip hostname
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  target_ip="$(jq -r '.target_ip // "unknown"' "$file" 2>/dev/null)"
  hostname="$(jq -r '.hostname // "unknown"' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Target IP: ${target_ip}"
    echo "Hostname: ${hostname}"
  } >> "$report_file"

  jq -r '"Open Ports: " + ((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end)' "$file" >> "$report_file"
}

render_custom_target_stress_report() {
  local file="$1"
  local report_file="$2"
  local target_ip hostname iface baseline_avg sustained_avg high_jitter latency_under_load packet_loss slow_recovery
  local completed_with_warnings warning stage_status
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  target_ip="$(jq -r '.target_ip // "unknown"' "$file" 2>/dev/null)"
  hostname="$(jq -r '.hostname // "unknown"' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  completed_with_warnings="$(jq -r '.completed_with_warnings // false' "$file" 2>/dev/null)"
  warning="$(jq -r '.warning // empty' "$file" 2>/dev/null)"
  stage_status="$(jq -r '.stage_status // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' "$file" 2>/dev/null)"
  baseline_avg="$(jq -r '.baseline.avg_latency_ms // "unavailable"' "$file" 2>/dev/null)"
  sustained_avg="$(jq -r '.sustained_test.avg_latency_ms // "unavailable"' "$file" 2>/dev/null)"
  high_jitter="$(jq -r '.indicators.high_jitter // false' "$file" 2>/dev/null)"
  latency_under_load="$(jq -r '.indicators.latency_under_load // false' "$file" 2>/dev/null)"
  packet_loss="$(jq -r '.indicators.packet_loss // false' "$file" 2>/dev/null)"
  slow_recovery="$(jq -r '.indicators.slow_recovery // false' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Target IP: ${target_ip}"
    echo "Hostname: ${hostname}"
    echo "Interface: ${iface}"
    echo "Completed With Warnings: ${completed_with_warnings}"
    if [[ -n "$warning" ]]; then
      echo "Warning: ${warning}"
    fi
    if [[ -n "$stage_status" ]]; then
      echo "Stage Status: ${stage_status}"
    fi
    echo "Baseline Avg Latency: ${baseline_avg} ms"
    echo "Sustained Avg Latency: ${sustained_avg} ms"
    echo "High Jitter: ${high_jitter}"
    echo "Latency Under Load: ${latency_under_load}"
    echo "Packet Loss Detected: ${packet_loss}"
    echo "Slow Recovery: ${slow_recovery}"
  } >> "$report_file"
}

render_custom_target_identity_report() {
  local file="$1"
  local report_file="$2"
  local target_ip hostname mac_address vendor vendor_source lookup_method
  local host_state device_type_hint confidence identity_summary
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  target_ip="$(jq -r '.target_ip // "unknown"' "$file" 2>/dev/null)"
  hostname="$(jq -r '.hostname // "unknown"' "$file" 2>/dev/null)"
  mac_address="$(jq -r '.mac_address // "unknown"' "$file" 2>/dev/null)"
  vendor="$(jq -r '.vendor // "unknown"' "$file" 2>/dev/null)"
  vendor_source="$(jq -r '.vendor_source // "unknown"' "$file" 2>/dev/null)"
  lookup_method="$(jq -r '.lookup_method // "unknown"' "$file" 2>/dev/null)"
  host_state="$(jq -r '.host_state // "unknown"' "$file" 2>/dev/null)"
  device_type_hint="$(jq -r '.device_type_hint // "unknown"' "$file" 2>/dev/null)"
  confidence="$(jq -r '.confidence // "low"' "$file" 2>/dev/null)"
  identity_summary="$(jq -r '.identity_summary // "Unknown device identity"' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Target IP: ${target_ip}"
    echo "Hostname: ${hostname}"
    echo "MAC Address: ${mac_address}"
    echo "Vendor: ${vendor}"
    echo "Vendor Source: ${vendor_source}"
    echo "Lookup Method: ${lookup_method}"
    echo "Host State: ${host_state}"
    echo "Device Type Hint: ${device_type_hint}"
    echo "Confidence: ${confidence}"
    echo "Identity Summary: ${identity_summary}"
  } >> "$report_file"

  jq -r 'if (.services // []) | length == 0 then "Discovered Services: none found" else "Discovered Services:" end' "$file" >> "$report_file"
  jq -r '.services[]? | "- \(.port) | \(.state) | \(.service) | \((.version // "") | if . == "" then "no version banner" else . end)"' "$file" >> "$report_file"
}

render_custom_target_dns_assessment_report() {
  local file="$1"
  local report_file="$2"
  local target_ip hostname query_tool dns_service_working recursion_available
  local udp_status tcp_status ptr_status software_hint upstream_inference upstream_note
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  target_ip="$(jq -r '.target_ip // "unknown"' "$file" 2>/dev/null)"
  hostname="$(jq -r '.hostname // "unknown"' "$file" 2>/dev/null)"
  query_tool="$(jq -r '.query_tool // "unknown"' "$file" 2>/dev/null)"
  dns_service_working="$(jq -r '.dns_service_working // false' "$file" 2>/dev/null)"
  recursion_available="$(jq -r '.recursion_available // false' "$file" 2>/dev/null)"
  udp_status="$(jq -r '.udp_query.status // "unknown"' "$file" 2>/dev/null)"
  tcp_status="$(jq -r '.tcp_query.status // "unknown"' "$file" 2>/dev/null)"
  ptr_status="$(jq -r '.reverse_ptr_query.status // "unknown"' "$file" 2>/dev/null)"
  software_hint="$(jq -r '.software_hint // "unknown"' "$file" 2>/dev/null)"
  upstream_inference="$(jq -r '.upstream_destination_inference // "unknown"' "$file" 2>/dev/null)"
  upstream_note="$(jq -r '.upstream_visibility_note // empty' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Target IP: ${target_ip}"
    echo "Hostname: ${hostname}"
    echo "Query Tool: ${query_tool}"
    echo "DNS Service Working: ${dns_service_working}"
    echo "Recursion Available: ${recursion_available}"
    echo "UDP Query Status: ${udp_status}"
    echo "TCP Query Status: ${tcp_status}"
    echo "PTR Query Status: ${ptr_status}"
    echo "Software Hint: ${software_hint}"
    echo "Upstream Destination Inference: ${upstream_inference}"
    if [[ -n "$upstream_note" ]]; then
      echo "Note: ${upstream_note}"
    fi
  } >> "$report_file"

  jq -r '"UDP Answers: " + ((.udp_query.answers // []) | if length > 0 then join(", ") else "none found" end)' "$file" >> "$report_file"
  jq -r '"TCP Answers: " + ((.tcp_query.answers // []) | if length > 0 then join(", ") else "none found" end)' "$file" >> "$report_file"
  jq -r '"PTR Answers: " + ((.reverse_ptr_query.answers // []) | if length > 0 then join(", ") else "none found" end)' "$file" >> "$report_file"
}

render_vlan_trunk_report() {
  local file="$1"
  local report_file="$2"
  local status success error_code error_message warning_count
  local iface tagged_frames_observed observed_vlan_ids
  local cdp_count lldp_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  tagged_frames_observed="$(jq -r '.tagged_frames_observed // false' "$file" 2>/dev/null)"
  observed_vlan_ids="$(jq -r '(.observed_vlan_ids // []) | if length > 0 then map(tostring) | join(", ") else "none" end' "$file" 2>/dev/null)"
  cdp_count="$(jq -r '(.cdp_neighbours // []) | length' "$file" 2>/dev/null)"
  lldp_count="$(jq -r '(.lldp_neighbours // []) | length' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
      jq -r '(.warnings // [])[] | "  - " + .' "$file" 2>/dev/null || true
    fi
    echo "Interface: ${iface}"
    echo "802.1Q Tagged Frames Observed: ${tagged_frames_observed}"
    echo "Observed VLAN IDs: ${observed_vlan_ids}"
    echo "Trunk Port Suspected: $(jq -r '.indicators.trunk_port_suspected // false' "$file" 2>/dev/null)"
    echo "Multiple VLANs Visible: $(jq -r '.indicators.multiple_vlans_visible // false' "$file" 2>/dev/null)"
    echo "CDP/LLDP Neighbour Frames Received: $(jq -r '.indicators.cdp_exposed // false' "$file" 2>/dev/null)"
    echo ""
    if [[ "$cdp_count" -gt 0 ]]; then
      echo "CDP Neighbours (${cdp_count}):"
      jq -r '.cdp_neighbours[]? |
        "  Device ID:    " + .device_id,
        "  Platform:     " + .platform,
        "  Port ID:      " + .port_id,
        "  Native VLAN:  " + (if .native_vlan != null then (.native_vlan | tostring) else "unknown" end),
        "  VTP Domain:   " + (if .vtp_domain != "" then .vtp_domain else "none" end),
        "  Duplex:       " + (if .duplex != "" then .duplex else "unknown" end),
        ""' "$file" 2>/dev/null || true
    else
      echo "CDP Neighbours: none detected"
    fi
    if [[ "$lldp_count" -gt 0 ]]; then
      echo "LLDP Neighbours (${lldp_count}):"
      jq -r '.lldp_neighbours[]? |
        "  System Name:  " + .system_name,
        "  Chassis ID:   " + .chassis_id,
        "  Port ID:      " + .port_id,
        "  Description:  " + (if .system_description != "" then .system_description else "none" end),
        ""' "$file" 2>/dev/null || true
    else
      echo "LLDP Neighbours: none detected"
    fi
    echo "Double-Tag Probe: not attempted"
  } >> "$report_file"
}

render_dhcp_report() {
  local file="$1"
  local report_file="$2"
  local found
  local attempts
  local offers_observed
  local raw_offers_observed
  local rogue_suspected
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  found="$(jq -r '.dhcp_responders_observed // .dhcp_servers_found // 0' "$file" 2>/dev/null)"
  attempts="$(jq -r '.discovery_attempts // 1' "$file" 2>/dev/null)"
  offers_observed="$(jq -r '.offers_observed // 0' "$file" 2>/dev/null)"
  raw_offers_observed="$(jq -r '.raw_offers_observed // .offers_observed // 0' "$file" 2>/dev/null)"
  rogue_suspected="$(jq -r '.rogue_dhcp_suspected // false' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "DHCP Responders Observed: ${found:-0}"
    echo "Discovery Attempts: ${attempts:-1}"
    echo "Unique Offers Observed: ${offers_observed:-0}"
    echo "Raw Offers Captured: ${raw_offers_observed:-0}"
    echo "Possible Rogue DHCP Present: ${rogue_suspected}"
  } >> "$report_file"

  jq -r 'if (.relay_sources_seen // []) | length > 0 then "Relay or Proxy Sources Seen: \((.relay_sources_seen // []) | join(", "))" else empty end' "$file" >> "$report_file"

  jq -r '
    (.relay_sources_seen // []) as $relays |
    ((.servers // []) | map(.ip)) as $responders |
    ($relays - $responders) as $relay_only |
    if ($relay_only | length) > 0 then
      "  (Relay/proxy only \u2014 no DHCP offers issued: " + ($relay_only | join(", ")) + ")"
    else empty end
  ' "$file" >> "$report_file"

  jq -r '.servers[]? | "- DHCP Responder \(.ip) | Unique Offers: \(.offers_observed // 0) | Raw Offers: \(.raw_offers_observed // .offers_observed // 0) | Classification: \(.classification // "unknown") | Suspected Rogue: \(.suspected_rogue // false) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end)"' "$file" >> "$report_file"

  jq -r 'if (.suspected_rogue_servers // []) | length > 0 then "Suspected Rogue Responders: \((.suspected_rogue_servers // []) | join(", "))" else empty end' "$file" >> "$report_file"
}

render_dhcp_response_time_report() {
  local file="$1"
  local report_file="$2"
  local status error_code error_message warning_count
  local iface probe_count responded_count avg_ms min_ms max_ms loss server_ip

  status="$(        jq -r '.status // "success"'            "$file" 2>/dev/null)"
  error_code="$(    jq -r '.error.code // empty'            "$file" 2>/dev/null)"
  error_message="$( jq -r '.error.message // empty'         "$file" 2>/dev/null)"
  warning_count="$( jq -r '(.warnings // []) | length'     "$file" 2>/dev/null)"
  iface="$(         jq -r '.interface // "unknown"'         "$file" 2>/dev/null)"
  probe_count="$(   jq -r '.probe_count // 0'               "$file" 2>/dev/null)"
  responded_count="$(jq -r '.responded_count // 0'          "$file" 2>/dev/null)"
  avg_ms="$(        jq -r '.avg_ms // "N/A"'                "$file" 2>/dev/null)"
  min_ms="$(        jq -r '.min_ms // "N/A"'                "$file" 2>/dev/null)"
  max_ms="$(        jq -r '.max_ms // "N/A"'                "$file" 2>/dev/null)"
  loss="$(          jq -r '.packet_loss_percent // 0'       "$file" 2>/dev/null)"
  server_ip="$(     jq -r '.server_ip // "unknown"'         "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
      jq -r '(.warnings // [])[] | "  - " + .' "$file" 2>/dev/null || true
    fi
    echo "Interface:        $iface"
    echo "DHCP Server:      $server_ip"
    echo "Probes Sent:      $probe_count"
    echo "Offers Received:  $responded_count"
    echo "Packet Loss:      ${loss}%"
    echo "Min Latency:      ${min_ms} ms"
    echo "Avg Latency:      ${avg_ms} ms"
    echo "Max Latency:      ${max_ms} ms"
    echo ""
    echo "Per-Probe Results:"
    jq -r '.response_times_ms | to_entries[] | "  Probe \(.key + 1): " + (if .value == null then "no response" else (.value | tostring) + " ms" end)' "$file" 2>/dev/null || true
  } >> "$report_file"
}

render_generic_network_scan_report() {
  local file="$1"
  local report_file="$2"
  local label="$3"
  local network ports server_count
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  network="$(jq -r '.network // "unknown"' "$file" 2>/dev/null)"
  ports="$(jq -r '.scan_ports // "unknown"' "$file" 2>/dev/null)"
  server_count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Network Range: ${network:-unknown}"
    echo "Scanned Ports: ${ports:-unknown}"
    echo "Servers Found: $server_count"
  } >> "$report_file"

  if [[ "$label" == "DNS" ]]; then
    jq -r '.servers[]? |
      "- DNS Host \(.ip) | Ports: \((.open_ports // []) | map(tostring) | join(", ")) | google.com: \(
        if .resolution_test then
          (if .resolution_test.resolved then "OK (" + ((.resolution_test.response_ms // "?") | tostring) + " ms)" else "FAILED" end)
        else "not tested" end)"' "$file" >> "$report_file"
  else
    jq -r --arg lbl "$label" '.servers[]? | "- \($lbl) Host \(.ip) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end) | Services: \((.detected_services // []) | if length > 0 then join(", ") else "unknown" end)"' "$file" >> "$report_file"
  fi
}


render_duplicate_ip_report() {
  local file="$1"
  local report_file="$2"
  local status error_code error_message warning_count
  local total_hosts duplicate_count iface network

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  network="$(jq -r '.network // "unknown"' "$file" 2>/dev/null)"
  total_hosts="$(jq -r '.total_hosts_seen // 0' "$file" 2>/dev/null)"
  duplicate_count="$(jq -r '.duplicate_count // 0' "$file" 2>/dev/null)"

  {
    echo "Status: ${status:-unknown}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
      jq -r '(.warnings // [])[] | "  - " + .' "$file" 2>/dev/null || true
    fi
    echo "Interface:        ${iface}"
    echo "Network Range:    ${network}"
    echo "Total Hosts Seen: ${total_hosts}"
    echo "Duplicate IPs:    ${duplicate_count}"
    echo ""
    if [[ "$duplicate_count" -gt 0 ]]; then
      echo "Conflicting Hosts:"
      jq -r '.duplicates[]? | "  IP: " + .ip + "  MACs: " + (.macs | join(", "))' "$file" 2>/dev/null || true
    else
      echo "No duplicate IPs detected."
    fi
  } >> "$report_file"
}


unifi_device_scan() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  json_file="$(task_output_path 18)"

  local tmp_live_ouis=""
  local broadcast_addr="" local_ip="" subnet=""
  if [[ "$OS" == "macos" ]]; then
    broadcast_addr="$(ifconfig "$iface" 2>/dev/null | awk '/inet .*broadcast/{for(i=1;i<=NF;i++) if($i=="broadcast"){print $(i+1); exit}}')"
    local_ip="$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
  else
    broadcast_addr="$(ip addr show "$iface" 2>/dev/null | awk '/inet .*brd/{for(i=1;i<=NF;i++) if($i=="brd"){print $(i+1); exit}}')"
    local_ip="$(ip addr show "$iface" 2>/dev/null | awk '/inet /{sub(/\/.*$/,"",$2); print $2}' | head -1)"
  fi
  [[ -z "$broadcast_addr" ]] && broadcast_addr="255.255.255.255"
  subnet="$(get_interface_network_cidr "$iface" 2>/dev/null || true)"

  echo "Interface:   $iface"
  echo "Local IP:    ${local_ip:-unknown}"
  echo "Subnet:      ${subnet:-unknown}"
  echo "Protocol:    UDP 10001 + TCP 22 (UniFi fingerprint) + ARP"
  echo
  # ── OUI database (monthly cache) ─────────────────────────────────────────
  # The IEEE MA-L registry is fetched at most once per 30 days and cached at
  # /usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt. New Ubiquiti
  # OUI blocks are picked up automatically without a software update.
  local _builtin_oui_count=45
  local _oui_cache="/usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt"
  local _cache_fresh=false
  tmp_live_ouis="$(mktemp /tmp/lss-ubiquiti-ouis-XXXXXX)"

  # Use cached file if it exists and is less than 30 days old
  if [[ -f "$_oui_cache" ]] && find "$_oui_cache" -mtime -30 -print 2>/dev/null | grep -q .; then
    _cache_fresh=true
    cp "$_oui_cache" "$tmp_live_ouis" 2>/dev/null || true
  fi

  if [[ "$_cache_fresh" == "true" ]] && [[ -s "$tmp_live_ouis" ]]; then
    local _cached_count
    _cached_count="$(wc -l < "$tmp_live_ouis" | tr -d ' ')"
    if [[ "$_cached_count" -gt "$_builtin_oui_count" ]]; then
      local _new_count=$(( _cached_count - _builtin_oui_count ))
      echo "OUI database:  ${_new_count} new block(s) vs built-in — live list active ($_cached_count blocks, cached)."
    fi
    # Cache is current and count matches built-in — no output needed
  else
    # Cache is stale or missing — fetch from IEEE
    printf "OUI database:  updating from IEEE registry... "
    if curl -fsSL --max-time 15 "https://standards-oui.ieee.org/oui/oui.csv" 2>/dev/null \
        | grep -i "ubiquiti" \
        | awk -F',' '{print $2}' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/' \
        > "$tmp_live_ouis" 2>/dev/null && [[ -s "$tmp_live_ouis" ]]; then
      local _live_count
      _live_count="$(wc -l < "$tmp_live_ouis" | tr -d ' ')"
      # Save to cache for next 30 days
      cp "$tmp_live_ouis" "$_oui_cache" 2>/dev/null || true
      if [[ "$_live_count" -gt "$_builtin_oui_count" ]]; then
        local _new_count=$(( _live_count - _builtin_oui_count ))
        echo "${_new_count} new block(s) found — live list active ($_live_count total)."
      else
        echo "done ($_live_count blocks)."
      fi
    else
      rm -f "$tmp_live_ouis"
      tmp_live_ouis=""
      echo "offline — using built-in list (${_builtin_oui_count} blocks)."
    fi
  fi
  echo

  local device_list="[]"
  local devices_found=0
  local entries=""

  if [[ -z "$subnet" ]]; then
    jq -n --arg iface "$iface" \
      '{status:"failed",success:false,error:{code:"no_subnet",message:"Could not determine subnet for interface"},warnings:[],interface:$iface,subnet:"",devices_found:0,devices:[]}' \
      > "$json_file"
    validate_json_file "$json_file" || true
    echo "Could not determine subnet for $iface."
    return 1
  fi

  if ! command -v nmap &>/dev/null; then
    jq -n --arg iface "$iface" \
      '{status:"failed",success:false,error:{code:"missing_dependency",message:"nmap is required for UniFi discovery but was not found"},warnings:[],interface:$iface,subnet:"",devices_found:0,devices:[]}' \
      > "$json_file"
    validate_json_file "$json_file" || true
    echo "nmap is required but was not found."
    return 1
  fi

  # ── Helper: MAC from ARP table ────────────────────────────────────────────
  arp_mac_for_ip() {
    local target_ip="$1"
    local mac=""
    if [[ "$OS" == "macos" ]]; then
      mac="$(arp -n "$target_ip" 2>/dev/null | awk '/ether/{print $4}' | head -1)"
    else
      # /proc/net/arp is instant; fall back to arp command
      mac="$(awk -v ip="$target_ip" '$1==ip{print $4; exit}' /proc/net/arp 2>/dev/null || true)"
      [[ -z "$mac" || "$mac" == "00:00:00:00:00:00" ]] && \
        mac="$(arp -n "$target_ip" 2>/dev/null | awk 'NR==2{print $3}' | head -1)"
    fi
    [[ "$mac" == "00:00:00:00:00:00" ]] && mac=""
    printf '%s' "$mac"
  }

  # ── LLDP passive listener (background) ───────────────────────────────────
  # Started immediately so it captures the full duration of Steps 1–4.
  # UniFi switches broadcast LLDP every 30s — any online switch will appear
  # here without being actively probed. Source MAC from each LLDP frame is
  # written to a temp file and reconciled in Step 5.
  local tmp_lldp_macs tmp_lldp_py lldp_pid
  tmp_lldp_macs="$(mktemp /tmp/lss-unifi-lldp-XXXXXX)"
  tmp_lldp_py=""
  lldp_pid=""
  if python3 -c "import scapy" 2>/dev/null; then
    tmp_lldp_py="$(mktemp /tmp/lss-unifi-lldp-XXXXXX)"
    cat > "$tmp_lldp_py" << 'PYEOF'
import sys, signal
try:
    from scapy.all import sniff, Ether, conf
    conf.verb = 0
except ImportError:
    sys.exit(0)
iface   = sys.argv[1]
outfile = sys.argv[2]
seen    = set()
def handle(pkt):
    try:
        mac = pkt[Ether].src.lower()
        if mac not in seen:
            seen.add(mac)
            with open(outfile, 'a') as f:
                f.write(mac + '\n')
    except Exception:
        pass
def _stop(sig, frame):
    sys.exit(0)
signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT,  _stop)
sniff(iface=iface, filter='ether proto 0x88cc', prn=handle, store=0, timeout=600)
PYEOF
    python3 "$tmp_lldp_py" "$iface" "$tmp_lldp_macs" 2>/dev/null &
    lldp_pid=$!
    echo "LLDP:          passive listener active."
    echo
  fi

  # ── Step 1: ARP host discovery ────────────────────────────────────────────
  # ARP operates at layer 2 — every live device on the subnet MUST respond.
  # It cannot be filtered or rate-limited the way UDP probes can, making it
  # the most reliable way to discover all hosts. We then fingerprint each
  # host with TLV + OUI rather than relying on UDP port detection.
  # tmp_nmap_ips:  all live IPs found by ARP scan
  # tmp_tlv_macs:  ip<tab>mac pairs confirmed by TLV
  # tmp_tlv_ips:   IPs confirmed by TLV
  local tmp_nmap_ips tmp_tlv_macs tmp_tlv_ips
  tmp_nmap_ips="$(mktemp /tmp/lss-unifi-ips-XXXXXX)"
  tmp_tlv_macs="$(mktemp /tmp/lss-unifi-tlv-XXXXXX)"
  tmp_tlv_ips="$(mktemp /tmp/lss-unifi-tlvips-XXXXXX)"
  local tmp_arp_macs
  tmp_arp_macs="$(mktemp /tmp/lss-unifi-arpmacs-XXXXXX)"

  echo "Step 1: ARP host discovery on $subnet (5 passes)..."
  # Parse IP+MAC pairs directly from nmap normal output — bypasses the kernel
  # ARP cache which nmap (raw sockets) does not populate on Linux.
  local _tmp_arp_raw
  _tmp_arp_raw="$(mktemp /tmp/lss-unifi-arpraw-XXXXXX)"
  for _arp_pass in 1 2 3 4 5; do
    start_spinner_line "  ARP pass ${_arp_pass}/5"
    nmap -n -sn "$subnet" 2>/dev/null | awk '
      /^Nmap scan report for /{
        if (ip!="" && mac!="") print ip"\t"mac
        ip=$NF; mac=""
      }
      /^MAC Address:/{mac=tolower($3)}
      END{if (ip!="" && mac!="") print ip"\t"mac}
    ' >> "$_tmp_arp_raw"
    stop_spinner_line
  done
  # Deduplicate by IP, preferring entries that include a MAC
  local _tmp_dedup_py
  _tmp_dedup_py="$(mktemp /tmp/lss-unifi-dedup-XXXXXX)"
  cat > "$_tmp_dedup_py" << 'PYEOF'
import sys, socket, struct
pairs = {}
for line in sys.stdin:
    parts = line.strip().split('\t')
    ip  = parts[0] if parts else ''
    mac = parts[1] if len(parts) > 1 else ''
    if ip and (ip not in pairs or mac):
        pairs[ip] = mac
def ip_key(ip):
    try: return struct.unpack('!I', socket.inet_aton(ip))[0]
    except: return 0
for ip in sorted(pairs, key=ip_key):
    print(ip + '\t' + pairs[ip])
PYEOF
  python3 "$_tmp_dedup_py" < "$_tmp_arp_raw" > "$tmp_arp_macs"
  rm -f "$_tmp_dedup_py"
  rm -f "$_tmp_arp_raw"
  awk -F'\t' '{print $1}' "$tmp_arp_macs" > "$tmp_nmap_ips"
  local arp_count
  arp_count="$(wc -l < "$tmp_nmap_ips" | tr -d ' ')"
  echo "  $arp_count live host(s) found via ARP."

  # ── Step 1b: UDP 10001 sweep (complement to ARP) ─────────────────────────
  # Managed switches and devices on different VLANs may not respond to ARP
  # from the scanning machine but are reachable via IP routing. A UDP 10001
  # sweep finds these — any host responding is likely a UniFi device. Results
  # are merged with the ARP list so TLV/OUI can confirm them.
  echo "  Running UDP 10001 sweep for IP-routed devices (10 passes)..."
  local _tmp_udp_raw _tmp_udp_confirmed
  _tmp_udp_raw="$(mktemp /tmp/lss-unifi-udp-XXXXXX)"
  _tmp_udp_confirmed="$(mktemp /tmp/lss-unifi-udp-confirmed-XXXXXX)"
  for _udp_pass in 1 2 3 4 5 6 7 8 9 10; do
    start_spinner_line "  UDP pass ${_udp_pass}/10"
    # Build exclusion list: ARP hosts + already confirmed UDP responders
    local _excl
    _excl="$(cat "$tmp_nmap_ips" "$_tmp_udp_confirmed" 2>/dev/null | sort -u)"
    local _targets="$subnet"
    if [[ -n "$_excl" ]]; then
      # Pass confirmed IPs as excludes so nmap skips them
      local _excl_args
      _excl_args="$(printf '%s\n' "$_excl" | paste -sd, -)"
      _targets="$subnet --exclude $_excl_args"
    fi
    # shellcheck disable=SC2086
    nmap -n -sU -p 10001 --max-rate 200 --host-timeout 20s $_targets -oG - 2>/dev/null \
      | awk '/10001\/open/{print $2}' | tee -a "$_tmp_udp_raw" >> "$_tmp_udp_confirmed"
    stop_spinner_line
    [[ "$_udp_pass" -lt 10 ]] && sleep 1
  done
  local udp_new=0
  while IFS= read -r udp_ip; do
    [[ -z "$udp_ip" ]] && continue
    if ! grep -qFx "$udp_ip" "$tmp_nmap_ips" 2>/dev/null; then
      echo "$udp_ip" >> "$tmp_nmap_ips"
      udp_new=$(( udp_new + 1 ))
    fi
  done < <(sort -u "$_tmp_udp_raw")
  rm -f "$_tmp_udp_raw" "$_tmp_udp_confirmed"
  if [[ "$udp_new" -gt 0 ]]; then
    echo "  $udp_new additional host(s) found via UDP sweep."
  fi

  local discovered_count
  discovered_count="$(wc -l < "$tmp_nmap_ips" | tr -d ' ')"
  echo "  $discovered_count total host(s) to fingerprint."
  echo

  # ── Step 2: TLV fingerprinting ───────────────────────────────────────────
  # Send UniFi discovery probes to every live host. Devices that respond with
  # a valid TLV payload are confirmed UniFi devices — they self-report their
  # MAC. Non-UniFi devices simply don't respond and are filtered out by OUI.
  local tmp_tlv_py
  tmp_tlv_py="$(mktemp /tmp/lss-unifi-tlv-XXXXXX)"
  cat > "$tmp_tlv_py" << 'PYEOF'
import sys, socket, time, json

PROBE_V1 = b'\x01\x00\x00\x00'
PROBE_V2 = b'\x02\x0a\x00\x04\x01\x00\x00\x01'

def parse_tlv(data):
    if len(data) < 4:
        return None, None
    mac = None
    model = None
    offset = 4  # skip 4-byte header
    while offset + 3 <= len(data):
        tlv_type = data[offset]
        tlv_len  = data[offset+1] * 256 + data[offset+2]
        if offset + 3 + tlv_len > len(data):
            break
        v = data[offset+3:offset+3+tlv_len]
        offset += 3 + tlv_len
        if tlv_type == 0x01 and len(v) == 6:
            mac = '%02x:%02x:%02x:%02x:%02x:%02x' % tuple(v)
        elif tlv_type == 0x02 and len(v) >= 10:
            mac = '%02x:%02x:%02x:%02x:%02x:%02x' % tuple(v[:6])
        elif tlv_type in (0x0b, 0x13):
            # 0x0b = hostname/model on older firmware; 0x13 = short model name (e.g. "U7Pro")
            try:
                candidate = v.decode('utf-8', errors='replace').rstrip('\x00').strip()
                if candidate and (model is None or tlv_type == 0x13):
                    model = candidate
            except Exception:
                pass
    return mac, model

# argv: [bcast_addr, ip1, ip2, ...]
args     = sys.argv[1:]
bcast    = args[0] if args else '255.255.255.255'
ips      = args[1:] if len(args) > 1 else []

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    sock.bind(('', 10001))
except OSError as e:
    sys.stderr.write(f'TLV bind failed: {e}\n')
    sys.exit(1)

def send_probes(targets):
    # Unicast only to targets not yet confirmed
    for ip in targets:
        try:
            sock.sendto(PROBE_V1, (ip, 10001))
            sock.sendto(PROBE_V2, (ip, 10001))
        except Exception:
            pass
    # Subnet broadcast + global broadcast every round
    for b in (bcast, '255.255.255.255'):
        try:
            sock.sendto(PROBE_V1, (b, 10001))
            sock.sendto(PROBE_V2, (b, 10001))
        except Exception:
            pass

# 5 rounds — skip already-confirmed IPs in each subsequent round
confirmed = {}
for round_n in range(5):
    remaining = [ip for ip in ips if ip not in confirmed]
    send_probes(remaining)
    if round_n < 4:
        time.sleep(0.5)

# 15 second listen window
deadline  = time.time() + 15
sock.settimeout(0.3)
while time.time() < deadline:
    try:
        data, addr = sock.recvfrom(2048)
        src_ip = addr[0]
        if src_ip not in confirmed:
            mac, model = parse_tlv(data)
            if mac:
                confirmed[src_ip] = {'mac': mac, 'model': model or ''}
    except socket.timeout:
        continue
    except Exception:
        continue

sock.close()

for ip, info in confirmed.items():
    print(f'UNIFI_CONFIRMED|{ip}|{info["mac"]}|{info.get("model","")}')
PYEOF

  echo "Step 2: TLV fingerprinting — probing $discovered_count host(s) (5 rounds, 15s window)..."
  local tlv_out tlv_confirmed=0
  start_spinner_line "  Sending probes and waiting for responses..."
  tlv_out="$(python3 "$tmp_tlv_py" "$broadcast_addr" $(sort -u "$tmp_nmap_ips" | tr '\n' ' ') 2>/dev/null || true)"
  stop_spinner_line
  rm -f "$tmp_tlv_py"

  while IFS='|' read -r _pfx nip nmac nmodel; do
    if [[ -n "$nip" && -n "$nmac" ]]; then
      echo "  Confirmed: $nip  mac=$nmac${nmodel:+  model=$nmodel}"
      printf '%s\t%s\t%s\n' "$nip" "$nmac" "$nmodel" >> "$tmp_tlv_macs"
      printf '%s\n' "$nip" >> "$tmp_tlv_ips"
      tlv_confirmed=$(( tlv_confirmed + 1 ))
    fi
  done < <(printf '%s\n' "$tlv_out" | grep '^UNIFI_CONFIRMED|' || true)
  echo "  TLV complete — $tlv_confirmed confirmed UniFi device(s)."
  echo

  # ── Helper: Ubiquiti OUI fallback ────────────────────────────────────────
  # TLV is the primary confirmation method. OUI is the fallback for devices
  # that have UDP 10001 open but don't respond to probes (e.g. USG/UDM
  # firewalls and some switches). If either confirms it, it's a UniFi device.
  is_ubiquiti_oui() {
    # Built-in list: 45 MA-L OUI blocks registered to Ubiquiti Inc (IEEE,
    # verified 2026-04-03). Supplemented at runtime by the live IEEE CSV fetch
    # so newly registered blocks are recognised without a software update.
    local mac
    mac="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local oui="${mac:0:8}"
    # Check live IEEE list first if the fetch succeeded
    if [[ -n "$tmp_live_ouis" ]] && grep -qFx "$oui" "$tmp_live_ouis" 2>/dev/null; then
      return 0
    fi
    case "$oui" in
      00:15:6d|00:27:22|04:18:d6|0c:ea:14|18:e8:29|1c:0b:8b|1c:6a:1b) return 0 ;;
      24:5a:4c|24:a4:3c|28:70:4e|44:d9:e7|58:d6:1f|60:22:32) return 0 ;;
      68:72:51|68:d7:9a|6c:63:f8|70:a7:41|74:83:c2|74:ac:b9) return 0 ;;
      74:f9:2c|74:fa:29|78:45:58|78:8a:20|80:2a:a8|84:78:48) return 0 ;;
      8c:30:66|8c:ed:e1|90:41:b2|94:2a:6f|9c:05:d6|a4:f8:ff) return 0 ;;
      a8:9c:6c|ac:8b:a9|b4:fb:e4|cc:35:d9|d0:21:f9|d4:89:c1) return 0 ;;
      d8:b3:70|dc:9f:db|e0:63:da|e4:38:83|f0:9f:c2|f4:92:bf) return 0 ;;
      f4:e2:c6|fc:ec:da) return 0 ;;
    esac
    return 1
  }

  # ── Step 3: OUI classification ────────────────────────────────────────────
  # For each live host: TLV confirmed = definite UniFi. TLV not confirmed but
  # Ubiquiti OUI = likely UniFi. Everything else goes to the flagged list for
  # SSH banner rescue (Step 4) or reported as a possible false positive.
  local flagged_entries=""
  local tmp_all_ips
  tmp_all_ips="$(mktemp /tmp/lss-unifi-all-XXXXXX)"
  cat "$tmp_nmap_ips" "$tmp_tlv_ips" > "$tmp_all_ips"

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    local mac="" model=""
    mac="$(awk -v ip="$ip" -F'\t' '$1==ip{print $2; exit}' "$tmp_tlv_macs" 2>/dev/null || true)"
    model="$(awk -v ip="$ip" -F'\t' '$1==ip{print $3; exit}' "$tmp_tlv_macs" 2>/dev/null || true)"
    if [[ -z "$mac" ]]; then
      # Use nmap-parsed MACs first (not subject to kernel ARP cache expiry)
      mac="$(awk -v ip="$ip" 'NF>=2 && $1==ip{print $2; exit}' "$tmp_arp_macs" 2>/dev/null || true)"
    fi
    if [[ -z "$mac" ]]; then
      mac="$(arp_mac_for_ip "$ip")"
      [[ -z "$mac" ]] && mac="unknown"
    fi
    local tlv_confirmed=false
    grep -qFx "$ip" "$tmp_tlv_ips" 2>/dev/null && tlv_confirmed=true
    local oui_match=false
    [[ "$mac" != "unknown" ]] && is_ubiquiti_oui "$mac" && oui_match=true

    if [[ "$tlv_confirmed" == "true" ]] || [[ "$oui_match" == "true" ]]; then
      entries="${entries:+$entries,}{\"mac\":\"$mac\",\"ip\":\"$ip\"${model:+,\"model\":\"$model\"}}"
    else
      flagged_entries="${flagged_entries:+$flagged_entries,}{\"mac\":\"$mac\",\"ip\":\"$ip\"}"
    fi
  done < <(sort -u "$tmp_all_ips")

  rm -f "$tmp_nmap_ips" "$tmp_tlv_macs" "$tmp_tlv_ips" "$tmp_all_ips" "$tmp_live_ouis"

  # ── Step 3b: Targeted TLV retry for OUI-confirmed devices without a model ──
  # Adopted devices sometimes don't respond in the broad 15s window but will
  # respond to a focused unicast probe once the subnet broadcast noise settles.
  local _oui_no_model_ips=()
  if [[ -n "$entries" ]]; then
    while IFS=$'\t' read -r _ip _model; do
      [[ -z "$_model" ]] && _oui_no_model_ips+=("$_ip")
    done < <(printf '[%s]' "$entries" | jq -r '.[] | [.ip, (.model // "")] | @tsv' 2>/dev/null)
  fi

  if [[ "${#_oui_no_model_ips[@]}" -gt 0 ]]; then
    local tmp_tlv_retry_py
    tmp_tlv_retry_py="$(mktemp /tmp/lss-unifi-tlv-XXXXXX)"
    cat > "$tmp_tlv_retry_py" << 'PYEOF'
import sys, socket, time

PROBE_V1 = b'\x01\x00\x00\x00'
PROBE_V2 = b'\x02\x0a\x00\x04\x01\x00\x00\x01'

def parse_tlv(data):
    if len(data) < 4:
        return None, None
    mac = None
    model = None
    offset = 4
    while offset + 3 <= len(data):
        tlv_type = data[offset]
        tlv_len  = data[offset+1] * 256 + data[offset+2]
        if offset + 3 + tlv_len > len(data):
            break
        v = data[offset+3:offset+3+tlv_len]
        offset += 3 + tlv_len
        if tlv_type == 0x01 and len(v) == 6:
            mac = '%02x:%02x:%02x:%02x:%02x:%02x' % tuple(v)
        elif tlv_type == 0x02 and len(v) >= 10:
            mac = '%02x:%02x:%02x:%02x:%02x:%02x' % tuple(v[:6])
        elif tlv_type in (0x0b, 0x13):
            try:
                candidate = v.decode('utf-8', errors='replace').rstrip('\x00').strip()
                if candidate and (model is None or tlv_type == 0x13):
                    model = candidate
            except Exception:
                pass
    return mac, model

ips = sys.argv[1:]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(('', 10001))
except OSError:
    sys.exit(0)

confirmed = {}
for _ in range(3):
    remaining = [ip for ip in ips if ip not in confirmed]
    for ip in remaining:
        try:
            sock.sendto(PROBE_V1, (ip, 10001))
            sock.sendto(PROBE_V2, (ip, 10001))
        except Exception:
            pass
    time.sleep(0.5)

sock.settimeout(0.3)
deadline = time.time() + 8
while time.time() < deadline:
    try:
        data, addr = sock.recvfrom(2048)
        src_ip = addr[0]
        if src_ip in ips and src_ip not in confirmed:
            mac, model = parse_tlv(data)
            if mac and model:
                confirmed[src_ip] = {'mac': mac, 'model': model}
    except socket.timeout:
        continue
    except Exception:
        continue

sock.close()
for ip, info in confirmed.items():
    print(f'UNIFI_CONFIRMED|{ip}|{info["mac"]}|{info["model"]}')
PYEOF
    start_spinner_line "  Model lookup — probing ${#_oui_no_model_ips[@]} device(s)..."
    local _tlv_retry_out
    _tlv_retry_out="$(python3 "$tmp_tlv_retry_py" "${_oui_no_model_ips[@]}" 2>/dev/null || true)"
    stop_spinner_line
    rm -f "$tmp_tlv_retry_py"

    while IFS='|' read -r _pfx _rip _rmac _rmodel; do
      [[ -z "$_rip" || -z "$_rmodel" ]] && continue
      entries="$(printf '[%s]' "$entries" | jq -c \
        --arg ip "$_rip" --arg model "$_rmodel" \
        '[.[] | if .ip == $ip then . + {model: $model} else . end]' 2>/dev/null \
        | jq -r '.[] | tojson' | paste -sd, - || printf '%s' "$entries")"
    done < <(printf '%s\n' "$_tlv_retry_out" | grep '^UNIFI_CONFIRMED|' || true)
  fi

  # ── Step 4: SSH banner rescue for flagged devices ─────────────────────────
  # Devices that weren't confirmed by TLV and have an unknown OUI get an SSH
  # banner check. A Dropbear banner is a strong secondary indicator of a
  # Ubiquiti device (APs, switches, airMAX all run stock Dropbear on port 22).
  if [[ -n "$flagged_entries" ]]; then
    echo "Checking SSH banners on flagged devices..."
    local rescued_entries=""
    local remaining_flagged=""
    while IFS=$'\t' read -r mac ip; do
      [[ -z "$ip" ]] && continue
      start_spinner_line "  Checking $ip"
      local banner
      banner="$(python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('$ip', 22))
    data = s.recv(256)
    print(data.decode('utf-8', errors='replace').strip())
except Exception:
    pass
finally:
    s.close()
" 2>/dev/null | head -1 | tr -d '\r\n')"
      stop_spinner_line
      if printf '%s' "$banner" | grep -qi 'dropbear'; then
        echo "  $ip — Ubiquiti SSH banner confirmed: $banner"
        rescued_entries="${rescued_entries:+$rescued_entries,}{\"mac\":\"$mac\",\"ip\":\"$ip\"}"
      else
        remaining_flagged="${remaining_flagged:+$remaining_flagged,}{\"mac\":\"$mac\",\"ip\":\"$ip\"}"
      fi
    done < <(printf '[%s]' "$flagged_entries" | jq -r '.[] | [.mac, .ip] | @tsv' 2>/dev/null)
    if [[ -n "$rescued_entries" ]]; then
      entries="${entries:+$entries,}${rescued_entries}"
    fi
    flagged_entries="$remaining_flagged"
    echo
  fi

  # ── Step 5: LLDP reconciliation ───────────────────────────────────────────
  # Stop the passive listener and cross-reference any Ubiquiti MACs it heard
  # against the ARP-discovered IP table. Adds devices missed by TLV and OUI.
  if [[ -n "$lldp_pid" ]]; then
    kill "$lldp_pid" 2>/dev/null || true
    wait "$lldp_pid" 2>/dev/null || true
    rm -f "$tmp_lldp_py"
    local lldp_new=0
    if [[ -s "$tmp_lldp_macs" ]]; then
      while IFS= read -r lldp_mac; do
        [[ -z "$lldp_mac" ]] && continue
        is_ubiquiti_oui "$lldp_mac" || continue
        local lldp_ip
        lldp_ip="$(awk -v m="$lldp_mac" 'NF>=2 && $2==m{print $1; exit}' "$tmp_arp_macs" 2>/dev/null || true)"
        [[ -z "$lldp_ip" ]] && continue
        # Already confirmed — skip
        printf '%s' "$entries" | grep -q "\"ip\":\"$lldp_ip\"" && continue
        # Remove from flagged if it landed there
        if printf '%s' "$flagged_entries" | grep -q "\"ip\":\"$lldp_ip\""; then
          flagged_entries="$(printf '[%s]' "$flagged_entries" | \
            jq -c --arg ip "$lldp_ip" '[.[] | select(.ip != $ip)] | .[]' 2>/dev/null \
            | paste -sd, - || printf '%s' "$flagged_entries")"
        fi
        echo "  LLDP: $lldp_ip  mac=$lldp_mac"
        entries="${entries:+$entries,}{\"mac\":\"$lldp_mac\",\"ip\":\"$lldp_ip\"}"
        lldp_new=$(( lldp_new + 1 ))
      done < "$tmp_lldp_macs"
      if [[ "$lldp_new" -gt 0 ]]; then
        echo "  LLDP complete — $lldp_new additional device(s) confirmed."
        echo
      fi
    fi
  fi
  rm -f "$tmp_lldp_macs" "$tmp_arp_macs"

  local unifi_count
  unifi_count="$(printf '%s' "$entries" | grep -o '"mac"' | wc -l | tr -d ' ')"
  local flagged_count
  flagged_count="$(printf '%s' "$flagged_entries" | grep -o '"mac"' | wc -l | tr -d ' ')"
  devices_found=$(( unifi_count + flagged_count ))

  local all_entries="${entries}${entries:+${flagged_entries:+,}}${flagged_entries}"
  [[ -n "$all_entries" ]] && device_list="[$all_entries]"

  jq -n \
    --arg iface "$iface" \
    --arg bcast "$broadcast_addr" \
    --arg subnet "${subnet:-}" \
    --argjson found "$devices_found" \
    --argjson devs "$device_list" \
    '{status:"success",success:true,error:null,warnings:[],interface:$iface,broadcast:$bcast,subnet:$subnet,devices_found:$found,devices:$devs}' \
    > "$json_file"
  validate_json_file "$json_file" || true

  if [[ "$devices_found" -eq 0 ]]; then
    echo "No UniFi devices found."
  else
    if [[ "$unifi_count" -gt 0 ]]; then
      echo "Found $unifi_count UniFi device(s):"
      echo
      printf "%-20s  %-15s  %s\n" "MAC Address" "IP Address" "Model"
      printf "%-20s  %-15s  %s\n" "--------------------" "---------------" "----------------"
      printf '[%s]' "$entries" | jq -r '.[] | [.mac, .ip, (.model // "")] | @tsv' 2>/dev/null | \
        python3 -c "
import sys, socket, struct
lines = sys.stdin.readlines()
def ip_key(l):
    try: return struct.unpack('!I', socket.inet_aton(l.split('\t')[1].strip()))[0]
    except: return 0
lines.sort(key=ip_key)
sys.stdout.writelines(lines)
" | \
        while IFS=$'\t' read -r mac ip model; do
          printf "%-20s  %-15s  %s\n" "$mac" "$ip" "${model:---}"
        done
    fi
    if [[ "$flagged_count" -gt 0 ]]; then
      echo
      echo "Possible false positive(s) — non-Ubiquiti MAC ($flagged_count):"
      printf "%-20s  %s\n" "MAC Address" "IP Address"
      printf "%-20s  %s\n" "--------------------" "---------------"
      printf '[%s]' "$flagged_entries" | jq -r '.[] | [.mac, .ip] | @tsv' 2>/dev/null | \
        python3 -c "
import sys, socket, struct
lines = sys.stdin.readlines()
def ip_key(l):
    try: return struct.unpack('!I', socket.inet_aton(l.split('\t')[1].strip()))[0]
    except: return 0
lines.sort(key=ip_key)
sys.stdout.writelines(lines)
" | \
        while IFS=$'\t' read -r mac ip; do
          printf "%-20s  %s\n" "$mac" "$ip"
        done
    fi
  fi
}

render_unifi_discovery_report() {
  local file="$1"
  local report_file="$2"
  local status error_code error_message iface subnet devices_found

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  subnet="$(jq -r '.subnet // "unknown"' "$file" 2>/dev/null)"
  devices_found="$(jq -r '.devices_found // 0' "$file" 2>/dev/null)"

  {
    echo "Status:         ${status:-unknown}"
    [[ -n "$error_code" ]]    && echo "Error Code:     $error_code"
    [[ -n "$error_message" ]] && echo "Error Message:  $error_message"
    echo "Interface:      ${iface}"
    echo "Subnet:         ${subnet}"
    echo "Devices Found:  ${devices_found}"
    echo
    if [[ "$devices_found" -gt 0 ]]; then
      printf "%-20s  %-15s  %s\n" "MAC Address" "IP Address" "Model"
      printf "%-20s  %-15s  %s\n" "--------------------" "---------------" "----------------"
      jq -r '.devices[]? | [.mac, .ip, (.model // "")] | @tsv' "$file" 2>/dev/null | \
        while IFS=$'\t' read -r mac ip model; do
          printf "%-20s  %-15s  %s\n" "$mac" "$ip" "${model:---}"
        done
    else
      echo "No UniFi devices found."
    fi
  } >> "$report_file"
}

render_wireless_site_survey_report() {
  local file="$1"
  local report_file="$2"
  local status rooms_scanned iface

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  rooms_scanned="$(jq -r '.rooms_scanned // 0' "$file" 2>/dev/null)"

  {
    echo "Status:        ${status:-unknown}"
    echo "Interface:     ${iface}"
    echo "Rooms Scanned: ${rooms_scanned}"
    echo ""

    local room_count
    room_count="$(jq '.survey | length' "$file" 2>/dev/null || echo 0)"
    if [[ "$room_count" -eq 0 ]]; then
      echo "No room data recorded."
    else
      echo "SURVEY SUMMARY"
      echo "--------------"
      printf "%-3s  %-20s  %-8s  %-16s  %-3s  %-12s  %-5s  %s\n" \
        "#" "Building" "Floor" "Room / Area" "AP" "AP Label" "Nets" "Strongest Signal"
      jq -r '.survey | to_entries[] |
        (.key + 1 | tostring) as $n |
        .value as $r |
        ($r.networks // [] | sort_by(.rssi_dbm // -999) | reverse | .[0]) as $top |
        (if $top then ($top.ssid + " (" + (if $top.rssi_dbm != null then ($top.rssi_dbm | tostring) + " dBm" else "--" end) + ", ch " + ($top.channel | tostring) + ", " + $top.security + ")") else "--" end) as $sig |
        [$n,
         ($r.building // "--"),
         ($r.floor // "--"),
         ($r.room // "--"),
         (if $r.ap_present then "Yes" else "No" end),
         ($r.ap_label // "--"),
         (($r.networks // []) | length | tostring),
         $sig] |
        @tsv' "$file" 2>/dev/null | awk -F'\t' '{printf "%-3s  %-20s  %-8s  %-16s  %-3s  %-12s  %-5s  %s\n", $1,$2,$3,$4,$5,$6,$7,$8}' || true
      echo ""

      echo "ROOM DETAIL  (top 5 networks by signal strength)"
      echo "------------------------------------------------"
      jq -r '.survey[] |
        "Building: " + (.building // "--") + " | Floor: " + (.floor // "--") + " | Room: " + (.room // "--"),
        "AP Present: " + (if .ap_present then "Yes" else "No" end),
        (if .ap_label then "AP Label:   " + .ap_label else empty end),
        "Timestamp:  " + (.timestamp // "--"),
        "",
        (if ((.networks // []) | length) == 0 then
          "  No networks detected."
        else
          "  " + (["SSID","Signal","Ch","Band","Width","PHY Mode","Security"] | join("  |  ")),
          (.networks // [] | sort_by(.rssi_dbm // -999) | reverse | .[0:5][] |
            "  " + ([
              (.ssid // "(hidden)"),
              (if .rssi_dbm != null then ((.rssi_dbm | tostring) + " dBm") else "--" end),
              ("ch " + (.channel | tostring)),
              (.band // "--"),
              (.channel_width // "--"),
              (.phy_mode // "--"),
              (.security // "--")
            ] | join("  |  ")))
        end),
        ""' "$file" 2>/dev/null || true
    fi
  } >> "$report_file"
}

unifi_adoption() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  json_file="$(task_output_path 19)"

  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local red='\033[0;31m'
  local reset='\033[0m'

  # ── Dependency: sshpass ───────────────────────────────────────────────────
  if ! command -v sshpass &>/dev/null; then
    echo "sshpass not found — installing..."
    if [[ "$OS" == "macos" ]]; then
      local _brew_user="${SUDO_USER:-}"
      if [[ -n "$_brew_user" ]]; then
        sudo -u "$_brew_user" brew install hudochenkov/sshpass/sshpass 2>/dev/null || true
      fi
    else
      apt-get install -y sshpass 2>/dev/null || true
    fi
    if ! command -v sshpass &>/dev/null; then
      printf "${red}[FAILED]${reset} Could not install sshpass automatically.\n"
      if [[ "$OS" == "macos" ]]; then
        echo "  Run: brew install hudochenkov/sshpass/sshpass"
      else
        echo "  Run: sudo apt install sshpass"
      fi
      jq -n --arg iface "$iface" \
        '{status:"failed",success:false,error:{code:"missing_dependency",message:"sshpass is required for UniFi adoption"},interface:$iface,devices_found:0,devices_adopted:0,devices:[]}' \
        > "$json_file"
      return 1
    fi
    echo "  sshpass installed."
    echo
  fi

  # ── Load devices from Task 18 ─────────────────────────────────────────────
  local task18_json
  task18_json="$(task_output_path 18)"
  if [[ ! -f "$task18_json" ]]; then
    echo "No Task 18 scan found for this run."
    echo "Please run Task 18 (Scan For UniFi Devices) first, then re-run Task 19."
    return 0
  fi
  local found_count
  found_count="$(jq -r '.devices_found // 0' "$task18_json" 2>/dev/null || echo 0)"
  if [[ "$found_count" -eq 0 ]]; then
    echo "Task 18 scan found no devices. Run Task 18 first."
    return 0
  fi
  echo "Loaded $found_count device(s) from Task 18 scan."
  echo

  # ── Step 1: Ask for controller domain and credentials ─────────────────────
  local controller_domain controller_port use_https inform_url ssh_user ssh_pass
  read -r -p "Controller domain or IP: " controller_domain
  read -r -p "Controller port (Enter = 8080): " controller_port
  controller_port="${controller_port:-8080}"
  if [[ "$controller_port" == "443" ]]; then
    inform_url="https://${controller_domain}:${controller_port}/inform"
  else
    read -r -p "Use HTTPS? (Enter = HTTP, y = HTTPS): " use_https
    if [[ "$use_https" =~ ^[Yy]$ ]]; then
      inform_url="https://${controller_domain}:${controller_port}/inform"
    else
      inform_url="http://${controller_domain}:${controller_port}/inform"
    fi
  fi
  echo
  read -r -p "SSH Username: " ssh_user
  read -r -s -p "SSH Password: " ssh_pass
  echo
  ssh_user="$(printf '%s' "$ssh_user" | tr -d '\r\n\t ')"
  ssh_pass="$(printf '%s' "$ssh_pass" | tr -d '\r\n')"
  echo
  echo "Inform URL:  $inform_url"
  echo

  # ── Step 2: SSH into each device and send set-inform ─────────────────────
  echo "Attempting adoption..."
  local devices_json="[" first=true adopted=0 failed=0

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    local result="failed"
    if sshpass -p "$ssh_pass" ssh -n \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${ssh_user}@${ip}" \
        "mca-cli-op set-inform $inform_url" 2>/dev/null; then
      result="adopted"
      adopted=$(( adopted + 1 ))
      printf "  ${green}[OK]${reset} %-18s  set-inform sent\n" "$ip"
    else
      failed=$(( failed + 1 ))
      printf "  ${yellow}[--]${reset} %-18s  could not connect\n" "$ip"
    fi
    [[ "$first" == "true" ]] || devices_json+=","
    devices_json+="{\"ip\":\"$ip\",\"result\":\"$result\"}"
    first=false
  done < <(jq -r '.devices[].ip // empty' "$task18_json" 2>/dev/null)
  devices_json+="]"

  echo
  echo "=============================="
  echo "  Devices attempted: $found_count"
  echo "  set-inform sent:   $adopted"
  echo "  Could not reach:   $failed"

  jq -n \
    --arg controller "$controller_domain" \
    --arg inform_url "$inform_url" \
    --arg iface "$iface" \
    --argjson devices_found "$found_count" \
    --argjson devices_adopted "$adopted" \
    --argjson devices "$devices_json" \
    '{
      status: "success",
      success: true,
      controller: $controller,
      inform_url: $inform_url,
      interface: $iface,
      devices_found: $devices_found,
      devices_adopted: $devices_adopted,
      devices: $devices
    }' > "$json_file"
}

render_unifi_adoption_report() {
  local file="$1"
  local report_file="$2"

  local status controller inform_url iface devices_found devices_adopted
  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  controller="$(jq -r '.controller // "unknown"' "$file" 2>/dev/null)"
  inform_url="$(jq -r '.inform_url // "unknown"' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  devices_found="$(jq -r '.devices_found // 0' "$file" 2>/dev/null)"
  devices_adopted="$(jq -r '.devices_adopted // 0' "$file" 2>/dev/null)"

  {
    echo "Status:           ${status:-unknown}"
    echo "Interface:        ${iface}"
    echo "Controller:       ${controller}"
    echo "Inform URL:       ${inform_url}"
    echo "Devices Attempted: ${devices_found}"
    echo "set-inform Sent:  ${devices_adopted}"
    echo

    local dev_count
    dev_count="$(jq '.devices | length' "$file" 2>/dev/null || echo 0)"
    if [[ "$dev_count" -gt 0 ]]; then
      printf "%-18s  %s\n" "IP Address" "Result"
      printf "%-18s  %s\n" "------------------" "--------------------"
      jq -r '.devices[]? | [.ip, .result] | @tsv' "$file" 2>/dev/null | \
        while IFS=$'\t' read -r ip result; do
          local label
          case "$result" in
            adopted) label="set-inform sent" ;;
            failed)  label="could not connect" ;;
            *)       label="$result" ;;
          esac
          printf "%-18s  %s\n" "$ip" "$label"
        done
    else
      echo "No devices attempted."
    fi
  } >> "$report_file"
}

find_device_by_mac() {
  local iface="$SELECTED_INTERFACE"
  local json_file
  json_file="$(task_output_path 20)"

  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local red='\033[0;31m'
  local reset='\033[0m'

  # ── Subnet ────────────────────────────────────────────────────────────────
  local subnet local_ip
  subnet="$(get_interface_network_cidr "$iface" 2>/dev/null || true)"
  if [[ "$OS" == "macos" ]]; then
    local_ip="$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
  else
    local_ip="$(ip addr show "$iface" 2>/dev/null | awk '/inet /{sub(/\/.*$/,"",$2); print $2}' | head -1)"
  fi

  # ── Prompt for MAC ────────────────────────────────────────────────────────
  local raw_mac norm_mac
  read -r -p "Enter MAC address (any format): " raw_mac
  # Normalise: strip all separators, lowercase, re-add colons
  norm_mac="$(printf '%s' "$raw_mac" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ':-. ' \
    | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')"
  if [[ ! "$norm_mac" =~ ^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$ ]]; then
    printf "${red}[ERROR]${reset} Invalid MAC address: %s\n" "$raw_mac"
    return 0
  fi
  echo
  echo "MAC:     $norm_mac"
  echo "Subnet:  ${subnet:-unknown}"
  echo

  if [[ -z "$subnet" ]]; then
    echo "Could not determine subnet for $iface."
    jq -n --arg iface "$iface" --arg mac "$norm_mac" \
      '{status:"failed",success:false,error:{code:"no_subnet",message:"Could not determine subnet"},mac_queried:$mac,ip_found:null,interface:$iface,subnet:"",is_unifi:false,unifi_confirmed_by:[]}' \
      > "$json_file"
    return 0
  fi

  # ── OUI check helper (built-in list + cache) ──────────────────────────────
  local _oui_cache="/usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt"
  local _tmp_ouis=""
  if [[ -f "$_oui_cache" ]] && find "$_oui_cache" -mtime -30 -print 2>/dev/null | grep -q .; then
    _tmp_ouis="$_oui_cache"
  fi
  is_ubiquiti_oui_local() {
    local _mac
    _mac="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local _oui="${_mac:0:8}"
    if [[ -n "$_tmp_ouis" ]] && grep -qFx "$_oui" "$_tmp_ouis" 2>/dev/null; then
      return 0
    fi
    case "$_oui" in
      00:15:6d|00:27:22|04:18:d6|0c:ea:14|18:e8:29|1c:0b:8b|1c:6a:1b) return 0 ;;
      24:5a:4c|24:a4:3c|28:70:4e|44:d9:e7|58:d6:1f|60:22:32) return 0 ;;
      68:72:51|68:d7:9a|6c:63:f8|70:a7:41|74:83:c2|74:ac:b9) return 0 ;;
      74:f9:2c|74:fa:29|78:45:58|78:8a:20|80:2a:a8|84:78:48) return 0 ;;
      8c:30:66|8c:ed:e1|90:41:b2|94:2a:6f|9c:05:d6|a4:f8:ff) return 0 ;;
      a8:9c:6c|ac:8b:a9|b4:fb:e4|cc:35:d9|d0:21:f9|d4:89:c1) return 0 ;;
      d8:b3:70|dc:9f:db|e0:63:da|e4:38:83|f0:9f:c2|f4:92:bf) return 0 ;;
      f4:e2:c6|fc:ec:da) return 0 ;;
    esac
    return 1
  }

  # ── Step 1: ARP scan — find IP for this MAC ───────────────────────────────
  echo "Scanning $subnet for $norm_mac (3 passes)..."
  local _tmp_arp_raw _found_ip=""
  _tmp_arp_raw="$(mktemp /tmp/lss-findmac-XXXXXX)"
  local _pass
  for _pass in 1 2 3; do
    nmap -n -sn "$subnet" 2>/dev/null | awk '
      /^Nmap scan report for /{
        if (ip!="" && mac!="") print ip"\t"mac
        ip=$NF; mac=""
      }
      /^MAC Address:/{mac=tolower($3)}
      END{if (ip!="" && mac!="") print ip"\t"mac}
    ' >> "$_tmp_arp_raw"
    _found_ip="$(awk -v m="$norm_mac" -F'\t' 'tolower($2)==m{print $1; exit}' "$_tmp_arp_raw")"
    [[ -n "$_found_ip" ]] && break
  done
  rm -f "$_tmp_arp_raw"

  if [[ -z "$_found_ip" ]]; then
    printf "${yellow}[NOT FOUND]${reset} No device with MAC %s seen on %s.\n" "$norm_mac" "$subnet"
    echo "  The device may be offline or on a different subnet/VLAN."
    jq -n --arg iface "$iface" --arg mac "$norm_mac" --arg subnet "$subnet" \
      '{status:"success",success:true,mac_queried:$mac,ip_found:null,interface:$iface,subnet:$subnet,is_unifi:false,unifi_confirmed_by:[]}' \
      > "$json_file"
    return 0
  fi

  printf "${green}[FOUND]${reset} %s → %s\n" "$norm_mac" "$_found_ip"
  echo

  # ── Step 2: UniFi verification (silent — only print if confirmed) ─────────
  local _is_unifi=false
  local -a _confirmed_by=()

  # Check 1: OUI
  if is_ubiquiti_oui_local "$norm_mac"; then
    _confirmed_by+=("oui")
  fi

  # Check 2: TLV probe on UDP 10001
  local _tmp_tlv_py
  _tmp_tlv_py="$(mktemp /tmp/lss-findmac-tlv-XXXXXX)"
  cat > "$_tmp_tlv_py" << 'PYEOF'
import sys, socket, time

PROBE_V1 = b'\x01\x00\x00\x00'
PROBE_V2 = b'\x02\x0a\x00\x04\x01\x00\x00\x01'

ip = sys.argv[1] if len(sys.argv) > 1 else ''
if not ip:
    sys.exit(1)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(('', 10001))
except OSError:
    sys.exit(1)

for _ in range(3):
    try:
        sock.sendto(PROBE_V1, (ip, 10001))
        sock.sendto(PROBE_V2, (ip, 10001))
    except Exception:
        pass
    time.sleep(0.3)

sock.settimeout(5)
deadline = time.time() + 5
while time.time() < deadline:
    try:
        data, addr = sock.recvfrom(2048)
        if addr[0] == ip and len(data) >= 4:
            print('UNIFI_CONFIRMED')
            sys.exit(0)
    except socket.timeout:
        break
    except Exception:
        continue

sock.close()
PYEOF
  local _tlv_result
  _tlv_result="$(python3 "$_tmp_tlv_py" "$_found_ip" 2>/dev/null || true)"
  rm -f "$_tmp_tlv_py"
  if [[ "$_tlv_result" == "UNIFI_CONFIRMED" ]]; then
    _confirmed_by+=("tlv")
  fi

  # Check 3: SSH banner — Dropbear = Ubiquiti
  local _banner=""
  _banner="$(python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('$_found_ip', 22))
    data = s.recv(256)
    print(data.decode('utf-8', errors='replace').strip())
except Exception:
    pass
finally:
    s.close()
" 2>/dev/null | head -1 | tr -d '\r\n')"
  if printf '%s' "$_banner" | grep -qi 'dropbear'; then
    _confirmed_by+=("ssh_banner")
  fi

  if [[ "${#_confirmed_by[@]}" -gt 0 ]]; then
    _is_unifi=true
    printf "  ${green}[CONFIRMED]${reset} UniFi device (confirmed via: %s)\n" "$(printf '%s ' "${_confirmed_by[@]}")"
    echo
  fi

  # ── Build JSON ────────────────────────────────────────────────────────────
  local _cb_json="["
  local _cb_first=true
  local _cb
  for _cb in "${_confirmed_by[@]+"${_confirmed_by[@]}"}"; do
    [[ "$_cb_first" == "true" ]] || _cb_json+=","
    _cb_json+="\"$_cb\""
    _cb_first=false
  done
  _cb_json+="]"

  jq -n \
    --arg iface "$iface" \
    --arg mac "$norm_mac" \
    --arg ip "$_found_ip" \
    --arg subnet "$subnet" \
    --argjson is_unifi "$_is_unifi" \
    --argjson confirmed_by "$_cb_json" \
    '{status:"success",success:true,mac_queried:$mac,ip_found:$ip,interface:$iface,subnet:$subnet,is_unifi:$is_unifi,unifi_confirmed_by:$confirmed_by}' \
    > "$json_file"

  # ── Offer adoption if confirmed UniFi ────────────────────────────────────
  if [[ "$_is_unifi" == "true" ]]; then
    local _adopt_answer
    read -r -p "Adopt this device now? [y/N]: " _adopt_answer
    if [[ "$_adopt_answer" =~ ^[Yy]$ ]]; then
      echo
      if ! command -v sshpass &>/dev/null; then
        echo "sshpass not found — installing..."
        if [[ "$OS" == "macos" ]]; then
          local _brew_user="${SUDO_USER:-}"
          [[ -n "$_brew_user" ]] && sudo -u "$_brew_user" brew install hudochenkov/sshpass/sshpass 2>/dev/null || true
        else
          apt-get install -y sshpass 2>/dev/null || true
        fi
        if ! command -v sshpass &>/dev/null; then
          printf "${red}[FAILED]${reset} Could not install sshpass. Install it manually then use Task 19.\n"
          return 0
        fi
      fi
      local _ctrl_domain _ctrl_port _use_https _inform_url _ssh_user _ssh_pass
      read -r -p "Controller domain or IP: " _ctrl_domain
      read -r -p "Controller port [8080]: " _ctrl_port
      _ctrl_port="${_ctrl_port:-8080}"
      if [[ "$_ctrl_port" == "443" ]]; then
        _inform_url="https://${_ctrl_domain}:${_ctrl_port}/inform"
      else
        read -r -p "Use HTTPS? [y/N]: " _use_https
        if [[ "$_use_https" =~ ^[Yy]$ ]]; then
          _inform_url="https://${_ctrl_domain}:${_ctrl_port}/inform"
        else
          _inform_url="http://${_ctrl_domain}:${_ctrl_port}/inform"
        fi
      fi
      echo
      read -r -p "SSH Username: " _ssh_user
      read -r -s -p "SSH Password: " _ssh_pass
      echo
      _ssh_user="$(printf '%s' "$_ssh_user" | tr -d '\r\n\t ')"
      _ssh_pass="$(printf '%s' "$_ssh_pass" | tr -d '\r\n')"
      echo
      echo "Inform URL:  $_inform_url"
      echo
      if sshpass -p "$_ssh_pass" ssh -n \
          -o StrictHostKeyChecking=no \
          -o ConnectTimeout=5 \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          "${_ssh_user}@${_found_ip}" \
          "mca-cli-op set-inform $_inform_url" 2>/dev/null; then
        printf "${green}[OK]${reset} set-inform sent to %s\n" "$_found_ip"
      else
        printf "${red}[FAILED]${reset} Could not SSH into %s — check credentials or try Task 19.\n" "$_found_ip"
      fi
    fi
  fi
}

render_find_device_by_mac_report() {
  local file="$1"
  local report_file="$2"

  local status mac ip is_unifi confirmed_by iface subnet
  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  mac="$(jq -r '.mac_queried // "unknown"' "$file" 2>/dev/null)"
  ip="$(jq -r 'if .ip_found and .ip_found != null then .ip_found else "not found" end' "$file" 2>/dev/null)"
  is_unifi="$(jq -r 'if .is_unifi then "Yes" else "No" end' "$file" 2>/dev/null)"
  confirmed_by="$(jq -r '(.unifi_confirmed_by // []) | map(
    if . == "oui" then "Ubiquiti OUI"
    elif . == "tlv" then "TLV probe (UDP 10001)"
    elif . == "ssh_banner" then "Dropbear SSH banner"
    else . end
  ) | join(", ")' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  subnet="$(jq -r '.subnet // "unknown"' "$file" 2>/dev/null)"

  {
    echo "Status:        ${status:-unknown}"
    echo "Interface:     ${iface}"
    echo "Subnet:        ${subnet}"
    echo "MAC Queried:   ${mac}"
    if [[ "$ip" == "not found" ]]; then
      echo "IP Found:      not found (device offline or on a different VLAN)"
      echo "UniFi Device:  N/A"
    else
      echo "IP Found:      ${ip}"
      echo "UniFi Device:  ${is_unifi}"
      [[ -n "$confirmed_by" ]] && echo "Confirmed By:  ${confirmed_by}"
    fi
  } >> "$report_file"
}

get_task_ids() {
  awk -F'|' 'NF {print $1}' <<< "$TASKS_DATA" | paste -sd' ' -
}

get_audit_task_ids() {
  echo "1 2 3 4 5 6 7 8 9 10 11 12"
}

task_title() {
  local task_id="$1"

  if [[ "$task_id" == "000" ]]; then
    echo "Complete Network Audit"
    return
  fi

  task_field "$task_id" 2
}

task_output_file() {
  local task_id="$1"
  task_field "$task_id" 3
}

task_description() {
  case "$1" in
    1) echo "Collects IPv4 interface details, subnet, gateway, and MAC address for the selected interface." ;;
    2) echo "Runs an internet speed test and records public IP, test server, latency, and throughput." ;;
    3) echo "Detects the default gateway for the selected interface and scans it for open TCP ports." ;;
    4) echo "Performs repeated DHCP discovery attempts and inspects observed responders for ports and role hints." ;;
    5) echo "Sends 5 DHCP Discover probes and measures the time from broadcast to first Offer response. Reports min/avg/max latency and packet loss." ;;
    6) echo "Scans the local subnet for hosts exposing DNS-related ports." ;;
    7) echo "Scans the local subnet for LDAP and Active Directory related services." ;;
    8) echo "Scans the local subnet for SMB, NFS, and related file-sharing services." ;;
    9) echo "Scans the local subnet for printer and print-server related ports." ;;
    10) echo "Runs a high-impact latency and packet-loss stress profile against the detected local gateway." ;;
    11) echo "Captures 802.1Q tagged frames and CDP/LLDP neighbour advertisements to detect VLAN trunking and switch identity." ;;
    12) echo "Sends ARP requests across the local subnet and flags any IP address that responds with more than one MAC address, indicating an IP conflict or ARP spoofing." ;;
    13) echo "Runs a full TCP port scan against a manually specified target IP." ;;
    14) echo "Runs a high-impact latency and packet-loss stress profile against a manually specified target IP." ;;
    15) echo "Combines MAC, vendor, hostname, and service fingerprint data to infer the identity of a target host." ;;
    16) echo "Tests whether a target IP is operating as a DNS resolver and records its query behavior." ;;
    17) echo "Walks room-by-room through a building scanning for nearby Wi-Fi networks, recording signal strength, channel, security mode, and AP presence per room." ;;
    18) echo "Sends a UniFi discovery packet to the local broadcast address on UDP port 10001 and lists all responding Ubiquiti devices with their MAC address and IP." ;;
    19) echo "SSHes into discovered UniFi devices and sends a set-inform command to adopt them into a controller. Handles the multi-round adoption flow required for switches." ;;
    20) echo "Scans the local subnet for a device matching a given MAC address, confirms whether it is a UniFi device via OUI, TLV probe, and SSH banner, then optionally adopts it into a controller." ;;
    000) echo "Runs the full core audit across functions 1 to 12." ;;
    *) echo "No description available." ;;
  esac
}

run_task_exists() {
  local func_id="$1"
  for listed_id in $(get_task_ids); do
    if [[ "$listed_id" == "$func_id" ]]; then
      return 0
    fi
  done
  return 1
}

run_task_by_id() {
  case "$1" in
    1) interface_info "$SELECTED_INTERFACE" ;;
    2) internet_speed_test ;;
    3) gateway_details "$SELECTED_INTERFACE" ;;
    4) dhcp_network_scan ;;
    5) dhcp_response_time ;;
    6) detect_dns_servers ;;
    7) detect_ldap_servers ;;
    8) detect_smb_nfs_servers ;;
    9) detect_print_servers ;;
    10) gateway_stress_test ;;
    11) vlan_trunk_scan ;;
    12) duplicate_ip_detection ;;
    13) custom_target_port_scan ;;
    14) custom_target_stress_test ;;
    15) custom_target_identity_scan ;;
    16) custom_target_dns_assessment ;;
    17) wireless_site_survey ;;
    18) unifi_device_scan ;;
    19) unifi_adoption ;;
    20) find_device_by_mac ;;
    *) return 1 ;;
  esac
}

run_task_with_progress_output() {
  local func_id="$1"
  local func_name="$2"
  local green='\033[0;32m'
  local red='\033[0;31m'
  local bold='\033[1m'
  local reset='\033[0m'
  local debug_target="/dev/null"

  if [[ -n "$SESSION_DEBUG_LOG" ]]; then
    debug_target="$SESSION_DEBUG_LOG"
  fi

  printf "  ${bold}%3s)${reset}  %s..." "$func_id" "$func_name"
  if run_task_by_id "$func_id" >>"$debug_target" 2>&1; then
    printf "  ${green}Done${reset}\n"
  else
    printf "  ${red}Failed${reset}\n"
    return 1
  fi
}

run_task_with_results_output() {
  local func_id="$1"
  local func_name="$2"
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'
  local description
  description="$(task_description "$func_id")"

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}Task %s — %s${reset}\n" "$func_id" "$func_name"
  [[ -n "$description" ]] && printf "  ${cyan}%s${reset}\n" "$description"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  SHOW_FUNCTION_HEADER=0
  TASK_OUTPUT_INDENT="  "
  if ! run_task_by_id "$func_id" | sed 's/^/  /'; then
    SHOW_FUNCTION_HEADER=1
    TASK_OUTPUT_INDENT=""
    return 1
  fi
  SHOW_FUNCTION_HEADER=1
  TASK_OUTPUT_INDENT=""
  echo
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
}

run_all_tasks() {
  local task_ids=()
  local func_id
  local func_name

  if ! confirm_gateway_stress_operation "000 Complete Network Audit"; then
    return 1
  fi

  read -r -a task_ids <<< "$(get_audit_task_ids)"

  for func_id in "${task_ids[@]}"; do
    func_name="$(task_title "$func_id")"

    if [[ -z "$func_name" ]]; then
      func_name="Function $func_id"
    fi

    if ! run_task_with_progress_output "$func_id" "$func_name"; then
      echo "Function $func_id ($func_name) failed — continuing with remaining tasks."
    fi
  done
}

main_menu() {
  local choice
  local task_ids=()
  local func_id
  local title
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  read -r -a task_ids <<< "$(get_task_ids)"

  while true; do
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Selected Interface:${reset}  ${yellow}%s${reset}\n" "$SELECTED_INTERFACE"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    for func_id in "${task_ids[@]}"; do
      title="$(task_title "$func_id")"
      if [[ -n "$title" ]]; then
        printf "  ${bold}%3s)${reset}  %s\n" "$func_id" "$title"
      fi
    done
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}000)${reset}  %s\n" "$(task_title "000")"
    printf "  ${bold}  0)${reset}  Back\n"
    echo
    read -r -p "  Enter selection: " choice

    case "$choice" in
      000)
        clear_screen_if_supported
        echo
        printf "  ${yellow}${bold}%s${reset}\n" "$(task_title "000")"
        printf "  ${cyan}%s${reset}\n" "$(task_description "000")"
        printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
        echo
        run_all_tasks
        echo
        printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
        echo
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      0) return 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && run_task_exists "$choice"; then
          title="$(task_title "$choice")"
          if [[ -z "$title" ]]; then
            title="Function $choice"
          fi
          run_task_with_results_output "$choice" "$title"
          [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        else
          echo "Invalid selection. Try again."
        fi
        ;;
    esac
  done
}

detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux) OS="linux" ;;
    *)
      echo "Unsupported platform: $(uname -s)"
      echo "Supported platforms: macOS and Linux"
      exit 1
      ;;
  esac
}

parse_args "$@"
if [[ "$VERSION_MODE" -eq 1 ]]; then
  echo "${APP_NAME} ${APP_VERSION}"
  exit 0
fi
if [[ "$BUILD_WIFI_HELPER_MODE" -eq 1 ]]; then
  detect_os
  configure_runtime_paths
  build_wifi_scan_helper_macos
  exit $?
fi
if [[ "$WRITE_COMPLETIONS_MODE" -eq 1 ]]; then
  detect_os
  write_completion_files
  exit 0
fi
if [[ "$INSTALL_DEPS_MODE" -eq 1 ]]; then
  detect_os
  if [[ "$OS" == "macos" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "Installing sshpass..."
      _brew_user="${SUDO_USER:-}"
      if [[ -n "$_brew_user" ]]; then
        sudo -u "$_brew_user" brew install hudochenkov/sshpass/sshpass 2>/dev/null \
          || echo "  Could not install sshpass — run: brew install hudochenkov/sshpass/sshpass"
      else
        echo "  Could not install sshpass — run: brew install hudochenkov/sshpass/sshpass"
      fi
    fi
  else
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "Installing sshpass..."
      apt-get install -y sshpass 2>/dev/null \
        || echo "  Could not install sshpass — run: sudo apt install sshpass"
    fi
  fi
  exit 0
fi
detect_os
ensure_standard_path
configure_runtime_paths
ensure_runtime_directories
if [[ "$UNINSTALL_MODE" -eq 1 ]]; then
  uninstall_installed_application
  exit $?
fi
if [[ "$UPDATE_MODE" -eq 1 ]]; then
  check_for_updates
  exit $?
fi
clear_screen_if_supported
check_tools
warn_if_not_root
initialize_debug_logging
trap finalize_run EXIT
trap handle_err_exit ERR

# Quick synchronous update check (3s timeout) — result stored in variable
# and displayed as a banner in startup_menu if a newer version is available.
_LSS_UPDATE_BANNER=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  _latest_tag="$(curl --max-time 2 -fsSL \
    "https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=10" 2>/dev/null \
    | jq -r '.[].name' 2>/dev/null | sort -V | tail -n 1)" || true
  if [[ -n "$_latest_tag" ]] && [[ "$_latest_tag" != "$APP_VERSION" ]]; then
    _LSS_UPDATE_BANNER="$_latest_tag"
  fi
fi

while true; do
  startup_menu
  if ! select_interface; then
    continue
  fi
  initialize_run_context
  main_menu
  if [[ -n "$RUN_OUTPUT_DIR" ]] && [[ -n "$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]]; then
    echo
    read -r -p "Save report? [y/N]: " _save_choice
    if [[ "$_save_choice" == "y" || "$_save_choice" == "Y" ]]; then
      finalize_run
    else
      rm -rf "$RUN_OUTPUT_DIR" 2>/dev/null || true
      RUN_OUTPUT_DIR=""
    fi
  else
    if [[ -n "$RUN_OUTPUT_DIR" ]]; then
      rm -rf "$RUN_OUTPUT_DIR" 2>/dev/null || true
    fi
    RUN_OUTPUT_DIR=""
  fi
done
