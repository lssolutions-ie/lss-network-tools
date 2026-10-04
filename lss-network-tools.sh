#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="lss-network-tools"
APP_VERSION="v1.2.252"
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
HIGH_IMPACT_STRESS_CONFIRMED_TARGET=""
DHCP_CAPTURE_PID=""
PROGRAM_DEFAULTS_FILE=""
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
RUN_TASK_MODE=0
BUILD_REPORT_MODE=0
DELETE_RUN_MODE=0
# Non-interactive mode (--run-task / --build-report / --delete-run, used by the
# macOS app and by scripts). Everything defaults to empty/0 so the interactive
# code paths are untouched unless one of the flags was given.
_LSS_NONINTERACTIVE=""
_LSS_NI_FLAGS_SEEN=0
_LSS_NI_RUN_TASK=""
_LSS_NI_TASK_IDS=""
_LSS_NI_BUILD_REPORT_DIR=""
_LSS_NI_DELETE_RUN_DIR=""
_LSS_NI_INTERFACE=""
_LSS_NI_CLIENT=""
_LSS_NI_LOCATION=""
_LSS_NI_NOTE=""
_LSS_NI_NEW_RUN_FLAGS=0
_LSS_NI_RUN_DIR=""
_LSS_NI_STRESS_CONSENT=0
_LSS_NI_TARGET=""
_LSS_NI_MAC=""
_LSS_NI_WIFI_INTERFACE=""
_LSS_NI_BUILDING=""
_LSS_NI_FLOOR=""
_LSS_NI_ROOM=""
_LSS_NI_AP_PRESENT=""
_LSS_NI_AP_LABEL=""
_LSS_NI_WIFI_SCAN_JSON=""
_LSS_NI_CONTROLLER=""
_LSS_NI_CONTROLLER_PORT=""
_LSS_NI_HTTPS=""
_LSS_NI_SSH_USER=""
_LSS_NI_SSH_PASSWORD=""
_LSS_NI_PROGRESS_TOKEN=""
_LSS_NI_PREPARED_BY=""
_LSS_NI_OUTPUT_DIR=""
_LSS_NI_NO_PDF=0
_LSS_NI_BYE_SENT=0
_LSS_PDF_LAST_ERROR=""

OS=""
SELECTED_INTERFACE=""
SHOW_FUNCTION_HEADER=1
TASK_OUTPUT_INDENT=""
SPINNER_PID=""
NETWORK_INTERRUPTED=false
# Task 5 sends this many DHCP Discover probes (1 s apart, 5 s wait each).
DHCP_RT_PROBE_COUNT=10
CAFFEINATE_PID=""
_GOTO_MAIN_MENU=false
_LSS_STATUS_MSG=""
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
    PROGRAM_DEFAULTS_FILE="$DATA_ROOT/program-defaults.json"
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
  PROGRAM_DEFAULTS_FILE="$DATA_ROOT/program-defaults.json"
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

get_program_default() {
  local key="$1"
  local fallback="${2:-}"
  if [[ -f "$PROGRAM_DEFAULTS_FILE" ]]; then
    local val
    val="$(jq -r --arg k "$key" '.[$k] // empty' "$PROGRAM_DEFAULTS_FILE" 2>/dev/null || true)"
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s' "$val"
      return
    fi
  fi
  printf '%s' "$fallback"
}

set_program_default() {
  local key="$1"
  local value="$2"
  local current="{}"
  local tmp_file

  # Read and validate first; a corrupt or empty file falls back to {} instead
  # of being truncated by the output redirection before jq ever parses it.
  if [[ -f "$PROGRAM_DEFAULTS_FILE" ]]; then
    current="$(jq -c 'if type == "object" then . else {} end' "$PROGRAM_DEFAULTS_FILE" 2>/dev/null || echo '{}')"
    [[ -z "$current" ]] && current="{}"
  fi

  mkdir -p "$(dirname "$PROGRAM_DEFAULTS_FILE")" 2>/dev/null || true
  tmp_file="$(mktemp "${PROGRAM_DEFAULTS_FILE}.XXXXXX")" || return 1
  if printf '%s' "$current" | jq --arg k "$key" --arg v "$value" '.[$k] = $v' > "$tmp_file" 2>/dev/null \
    && [[ -s "$tmp_file" ]]; then
    mv -f "$tmp_file" "$PROGRAM_DEFAULTS_FILE"
  else
    rm -f "$tmp_file"
    return 1
  fi
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

# ── Progress protocol for non-interactive mode ─────────────────────────────
# One `@@LSS {compact json}` line per event on fd 9, which noninteractive_setup
# dups from the ORIGINAL stderr before initialize_debug_logging merges fd 1/2
# into the tee — so the lines never enter debug.txt. Every helper is a no-op
# unless _LSS_NONINTERACTIVE=1, and JSON is built with printf (jq may be the
# very dependency check_tools is reporting as missing).

# Escape a string for use inside a JSON string literal (no surrounding quotes).
json_escape() {
  # Byte-oriented on purpose: only 0x00–0x1F/0x7F are escaped; multibyte UTF-8
  # passes through unchanged, which JSON permits. Under a UTF-8 locale bash
  # 3.2 would index code points instead, and ${#s}/${s:i:1}/[[:cntrl:]]
  # disagree on C1 controls and invalid bytes (garbled "￿…" output).
  local LC_ALL=C
  local s="$1"
  if [[ "$s" != *[\\\"[:cntrl:]]* ]]; then
    printf '%s' "$s"
    return 0
  fi
  local out="" i ch
  for (( i = 0; i < ${#s}; i++ )); do
    ch="${s:$i:1}"
    case "$ch" in
      \\) out+='\\' ;;
      \") out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      [[:cntrl:]]) out+="$(printf '\\u%04x' "'$ch")" ;;
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}

# "key":"escaped string"
json_str_field() {
  printf '"%s":"%s"' "$1" "$(json_escape "$2")"
}

# "key":<raw json> — numbers, true/false, null or a pre-rendered value.
json_raw_field() {
  printf '"%s":%s' "$1" "$2"
}

# "key":["a","b",…] from the remaining arguments (none → []).
json_str_array() {
  local key="$1" out="" v
  shift
  for v in "$@"; do
    out="$out,\"$(json_escape "$v")\""
  done
  printf '"%s":[%s]' "$key" "${out#,}"
}

# emit_progress <event> [<pre-rendered "key":value fragment> ...]
emit_progress() {
  [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]] || return 0
  local event="$1" ts body frag
  shift
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body="\"v\":1,\"ts\":\"$ts\",\"event\":\"$(json_escape "$event")\""
  for frag in "$@"; do
    body="$body,$frag"
  done
  # stderr is redirected first so a closed fd 9 cannot print "Bad file
  # descriptor"; || true keeps set -e out of it. With LSS_PROGRESS_TOKEN the
  # line is `@@LSS <token> {json}` (see noninteractive_setup).
  printf '@@LSS %s{%s}\n' "${_LSS_NI_PROGRESS_TOKEN:+$_LSS_NI_PROGRESS_TOKEN }" "$body" 2>/dev/null >&9 || true
}

# emit_stage <task id> <stage key> <human label> — placed next to the existing
# human "Stage N:" / "Step N:" lines in the tasks that have them.
emit_stage() {
  [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]] || return 0
  emit_progress task_stage "$(json_raw_field task "$1")" "$(json_str_field stage "$2")" "$(json_str_field label "$3")"
}

# The bye event is the last line, exactly once (also from the EXIT trap).
emit_bye() {
  [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]] || return 0
  [[ "$_LSS_NI_BYE_SENT" -eq 1 ]] && return 0
  _LSS_NI_BYE_SENT=1
  emit_progress bye "$(json_raw_field exit_code "${1:-0}")"
}

# Spinners print their label once as a plain line (the existing --debug
# behaviour) when LSS_QUIET_SPINNER=1 — set by non-interactive mode so the
# GUI/log never sees \r redraws.
spinner_is_quiet() {
  [[ "${DEBUG_MODE:-0}" -eq 1 || "${LSS_QUIET_SPINNER:-0}" == "1" ]]
}

confirm_gateway_stress_operation() {
  local context_label="${1:-Function 10}"
  local target_description="${2:-the detected local gateway/firewall}"
  local confirmation=""

  # Consent is per target, not per session: accepting the warning for the
  # gateway must not silence it for an arbitrary custom IP later on.
  if [[ "$HIGH_IMPACT_STRESS_CONFIRMED_TARGET" == "$target_description" ]]; then
    return 0
  fi

  # Non-interactive mode: consent comes from --yes (validated at startup);
  # never prompt.
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    if [[ "$_LSS_NI_STRESS_CONSENT" -eq 1 ]]; then
      printf "  Stress test consent given with --yes (%s).\n" "$target_description"
      HIGH_IMPACT_STRESS_CONFIRMED=1
      HIGH_IMPACT_STRESS_CONFIRMED_TARGET="$target_description"
      return 0
    fi
    printf "  Gateway Stress Test cancelled.\n"
    return 1
  fi

  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  echo
  printf "  ${yellow}${bold}Gateway Stress Test Warning${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  printf "  %s includes a Gateway Stress Test.\n" "$context_label"
  printf "  This test only targets %s with ICMP.\n" "$target_description"
  printf "  It does not perform exploits or service attacks, but it can\n"
  printf "  disrupt routing, VPNs, WAN access, or unstable devices.\n"
  echo
  printf "  Run this only when you accept possible service impact.\n"
  printf "  If the target is a gateway or firewall, consider disconnecting\n"
  printf "  it from internet or performing this after-hours.\n"
  echo
  read -r -p "  Proceed? [y/N]: " confirmation

  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    printf "  Gateway Stress Test cancelled.\n"
    return 1
  fi

  HIGH_IMPACT_STRESS_CONFIRMED=1
  HIGH_IMPACT_STRESS_CONFIRMED_TARGET="$target_description"
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

detect_output_tty() {
  # Check stdin (fd 0) rather than stdout (fd 1) — stdout may already be
  # piped through tee when relaunched after an update via exec sudo.
  if [[ -t 0 ]]; then
    OUTPUT_IS_TTY=1
  fi
}

# Home directory of the user who invoked sudo (falls back to $HOME). Under
# sudo, $HOME is /var/root or /root, which is not where reports belong.
invoking_user_home() {
  local user="${SUDO_USER:-}"
  local home=""
  if [[ -n "$user" && "$user" != "root" ]]; then
    if [[ "$OS" == "macos" ]]; then
      home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}')"
    else
      home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    fi
  fi
  if [[ -z "$home" || ! -d "$home" ]]; then
    home="${HOME:-/tmp}"
  fi
  printf '%s' "$home"
}

# Expand a leading ~ or ~/ in a user-typed path (read -r does not do this).
expand_user_path() {
  local p="$1"
  # shellcheck disable=SC2088  # literal "~" patterns are intentional here
  case "$p" in
    "~") printf '%s' "$(invoking_user_home)" ;;
    "~/"*) printf '%s/%s' "$(invoking_user_home)" "${p#\~/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Background-process registry so Ctrl-C / exit can clean up tcpdump, nmap,
# spinners, etc. Async children ignore SIGINT, so without this they outlive
# the script.
_LSS_BG_PIDS=""
register_bg_pid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && _LSS_BG_PIDS="$_LSS_BG_PIDS $pid"
  return 0
}
unregister_bg_pid() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0
  _LSS_BG_PIDS="$(printf '%s\n' "$_LSS_BG_PIDS" | tr ' ' '\n' | grep -vx "$pid" | tr '\n' ' ')"
  return 0
}
kill_registered_bg_pids() {
  local pid
  for pid in $_LSS_BG_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  _LSS_BG_PIDS=""
}

initialize_debug_logging() {
  if [[ -n "$SESSION_DEBUG_LOG" ]]; then
    return
  fi

  # Remove stale session logs, but only those whose owning process is gone —
  # another live session may still be writing to its own file.
  local stale pid
  while IFS= read -r stale; do
    [[ -z "$stale" ]] && continue
    pid="${stale##*.debug-session-}"
    pid="${pid%.txt}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    rm -f "$stale" 2>/dev/null || true
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '.debug-session-*.txt' 2>/dev/null)

  detect_output_tty

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
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'
  local issues=0

  # Terminal width — same detection as compare view
  local term_width col_w
  term_width="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  [[ -z "$term_width" || "$term_width" -lt 40 ]] && term_width="${COLUMNS:-0}"
  [[ "$term_width" -lt 40 ]] && term_width="$(tput cols 2>/dev/null || echo 120)"
  [[ "$term_width" -lt 40 ]] && term_width=120
  col_w=$(( (term_width - 5) / 2 ))

  # ── Gather data ───────────────────────────────────────────────────────────
  local audit_count custom_count total_count python_version wrapper_path
  audit_count="$(echo "$(get_audit_task_ids)" | wc -w | tr -d ' ')"
  total_count="$(get_task_ids | wc -w | tr -d ' ')"
  custom_count=$(( total_count - audit_count ))
  python_version="$(python3 --version 2>/dev/null || echo "not found")"
  wrapper_path="$(installed_wrapper_path)"

  # ── Left column: System Info + Software Versions ──────────────────────────
  local left_tmp
  left_tmp="$(mktemp /tmp/lss-about-left-XXXXXX)"
  {
    printf "${yellow}${bold}About / System Info${reset}\n"
    printf "${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "\n"
    printf "%-14s  %s\n"            "Application:"  "$APP_NAME"
    printf "%-14s  ${bold}%s${reset}\n" "Version:"  "$APP_VERSION"
    printf "%-14s  %s\n"            "OS:"           "$OS"
    printf "%-14s  %s\n"            "Install Mode:" "$INSTALL_MODE"
    printf "%-14s  %s\n"            "Script Path:"  "$SCRIPT_DIR"
    printf "%-14s  %s\n"            "App Root:"     "$APP_ROOT"
    printf "%-14s  %s\n"            "Data Root:"    "$DATA_ROOT"
    printf "%-14s  %s\n"            "Wrapper:"      "$wrapper_path"
    printf "%-14s  %s\n"            "Output Root:"  "$OUTPUT_DIR"
    printf "%-14s  %s\n"            "User:"         "$(id -un 2>/dev/null || echo unknown) (EUID $EUID)"
    printf "%-14s  %s\n"            "Python:"       "$python_version"
    printf "%-14s  %s\n"            "Tasks:"        "$total_count total ($audit_count core audit, $custom_count custom)"
    printf "\n"
    printf "${yellow}${bold}Software Versions${reset}\n"
    printf "${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "\n"
    printf "%-20s %s\n" "lss-network-tools" "$APP_VERSION"
    if command -v nmap >/dev/null 2>&1; then
      printf "%-20s %s\n" "nmap" "$(nmap --version 2>/dev/null | head -1 | awk '{print $3}')"
    fi
    if command -v jq >/dev/null 2>&1; then
      printf "%-20s %s\n" "jq" "$(jq --version 2>/dev/null)"
    fi
    if command -v python3 >/dev/null 2>&1; then
      printf "%-20s %s\n" "python3" "$(python3 --version 2>/dev/null)"
      printf "%-20s %s\n" "fpdf2"   "$(python3 -c 'import fpdf; print(fpdf.__version__)' 2>/dev/null || echo 'not installed')"
      printf "%-20s %s\n" "scapy"   "$(python3 -c 'import scapy; print(scapy.__version__)' 2>/dev/null || echo 'not installed')"
    fi
    if command -v speedtest-cli >/dev/null 2>&1; then
      printf "%-20s %s\n" "speedtest-cli" "$(speedtest-cli --version 2>/dev/null | head -1)"
    fi
  } > "$left_tmp"

  # ── Right column: Install Health + Dependencies ───────────────────────────
  local right_tmp
  right_tmp="$(mktemp /tmp/lss-about-right-XXXXXX)"
  {
    printf "${yellow}${bold}Install Health${reset}\n"
    printf "${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "\n"
    if is_installed_mode; then
      printf "${green}[OK]${reset}      Installed mode detected\n"
    else
      printf "${yellow}[WARN]${reset}    Installed mode not detected; running portable/source path\n"
      issues=$((issues + 1))
    fi
    local path
    for path in "$APP_ROOT" "$OUTPUT_DIR" "$TMP_ROOT"; do
      if [[ -e "$path" ]]; then
        printf "${green}[OK]${reset}      %s\n" "$path"
      else
        printf "${red}[MISSING]${reset} %s\n" "$path"
        issues=$((issues + 1))
      fi
    done
    if [[ "$OS" == "linux" ]]; then
      for path in "$DATA_ROOT" "$DATA_ROOT/raw" "$DATA_ROOT/install-audit.log"; do
        if [[ -e "$path" ]]; then
          printf "${green}[OK]${reset}      %s\n" "$path"
        else
          if [[ "$path" == "$DATA_ROOT/install-audit.log" ]]; then
            printf "${yellow}[WARN]${reset}    %s\n" "$path"
          else
            printf "${red}[MISSING]${reset} %s\n" "$path"
            issues=$((issues + 1))
          fi
        fi
      done
    else
      for path in "$DATA_ROOT/raw" "$DATA_ROOT/install-audit.log"; do
        if [[ -e "$path" ]]; then
          printf "${green}[OK]${reset}      %s\n" "$path"
        else
          if [[ "$path" == "$DATA_ROOT/install-audit.log" ]]; then
            printf "${yellow}[WARN]${reset}    %s\n" "$path"
          else
            printf "${red}[MISSING]${reset} %s\n" "$path"
            issues=$((issues + 1))
          fi
        fi
      done
    fi
    if [[ -x "$wrapper_path" ]]; then
      printf "${green}[OK]${reset}      %s\n" "$wrapper_path"
    else
      printf "${red}[MISSING]${reset} %s\n" "$wrapper_path"
      issues=$((issues + 1))
    fi
    printf "\n"
    printf "${yellow}${bold}Dependencies${reset}\n"
    printf "${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "\n"
    local tool tools_to_check=()
    tools_to_check=(nmap jq speedtest-cli tcpdump awk sed grep find mktemp python3)
    if [[ "$OS" == "macos" ]]; then
      tools_to_check+=(ipconfig ifconfig route networksetup ping)
    else
      tools_to_check+=(ip ping iw)
    fi
    for tool in "${tools_to_check[@]}"; do
      if command -v "$tool" >/dev/null 2>&1; then
        printf "${green}[OK]${reset}      %s\n" "$tool"
      else
        printf "${red}[MISSING]${reset} %s\n" "$tool"
        issues=$((issues + 1))
      fi
    done
    # Optional tools: warn, but do not count as an install issue.
    if command -v sshpass >/dev/null 2>&1; then
      printf "${green}[OK]${reset}      sshpass\n"
    else
      printf "${yellow}[WARN]${reset}    sshpass not found — Task 19 (UniFi Adoption) unavailable\n"
    fi
    if command -v arp-scan >/dev/null 2>&1; then
      printf "${green}[OK]${reset}      arp-scan\n"
    else
      printf "${yellow}[WARN]${reset}    arp-scan not found — Task 12 (Duplicate IP Detection) unavailable\n"
    fi
    if [[ "$OS" == "macos" ]]; then
      if xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then
        printf "${green}[OK]${reset}      swiftc (Xcode Command Line Tools)\n"
      else
        printf "${yellow}[WARN]${reset}    Xcode Command Line Tools not found — Wi-Fi helper cannot be built (xcode-select --install)\n"
      fi
    fi
    if command -v python3 >/dev/null 2>&1; then
      if python3 -c "import scapy" 2>/dev/null; then
        printf "${green}[OK]${reset}      python3-scapy\n"
      else
        printf "${red}[MISSING]${reset} python3-scapy\n"
        issues=$((issues + 1))
      fi
      if python3 -c "import fpdf" 2>/dev/null; then
        printf "${green}[OK]${reset}      python3-fpdf2\n"
      else
        printf "${red}[MISSING]${reset} python3-fpdf2\n"
        issues=$((issues + 1))
      fi
    fi
    if [[ "$OS" == "macos" ]]; then
      local helper_ver
      helper_ver="$(cat "${_LSS_WIFI_HELPER}.version" 2>/dev/null || true)"
      if [[ -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
        if [[ "$helper_ver" == "$APP_VERSION" ]]; then
          printf "${green}[OK]${reset}      LSS-WiFiScan.app (%s)\n" "$helper_ver"
        else
          printf "${yellow}[WARN]${reset}    LSS-WiFiScan.app outdated (%s) — run: sudo lss-network-tools --build-wifi-helper\n" "${helper_ver:-unknown}"
          issues=$((issues + 1))
        fi
      else
        printf "${red}[MISSING]${reset} LSS-WiFiScan.app — run: sudo lss-network-tools --build-wifi-helper\n"
        issues=$((issues + 1))
      fi
    fi
  } > "$right_tmp"

  # ── Merge and print side by side (ANSI-aware) ─────────────────────────────
  echo
  python3 - "$left_tmp" "$right_tmp" "$col_w" << 'PYEOF'
import sys, re

def strip_ansi(s):
    return re.sub(r'\033\[[0-9;]*m', '', s)

def pad_line(s, width):
    return s + ' ' * max(0, width - len(strip_ansi(s)))

fa, fb, col_w = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(fa) as f:
    left  = [l.rstrip('\n') for l in f]
with open(fb) as f:
    right = [l.rstrip('\n') for l in f]

n = max(len(left), len(right))
for i in range(n):
    l = '  ' + (left[i]  if i < len(left)  else '')
    r =         right[i] if i < len(right) else ''
    print(pad_line(l, col_w + 2) + '   ' + r)
PYEOF

  rm -f "$left_tmp" "$right_tmp"

  echo
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  if [[ "$issues" -eq 0 ]]; then
    printf "  ${green}${bold}Install health looks good.${reset}\n"
  else
    printf "  ${yellow}${bold}Install health found %d issue(s).${reset}\n" "$issues"
  fi
  echo
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
    # Under sudo, read the invoking user's gh login rather than root's.
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      token="$(sudo -u "$SUDO_USER" gh auth token 2>/dev/null || true)"
    else
      token="$(gh auth token 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$token" ]]; then
    printf 'Authorization: Bearer %s\n' "$token"
  fi
  printf 'Accept: application/vnd.github+json\n'
  printf 'User-Agent: %s\n' "$APP_NAME"
}

latest_remote_tag_from_github() {
  local api_url="https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=100"
  local response="" curl_err="" tmp_err
  tmp_err="$(mktemp /tmp/lss-curl-err-XXXXXX)"

  # Headers go through a 0600 temp file (-H @file) so a GitHub token is never
  # visible on the curl command line in `ps`.
  local hdr_file
  hdr_file="$(mktemp /tmp/lss-curl-hdr-XXXXXX)" || { rm -f "$tmp_err"; return 1; }
  github_api_headers > "$hdr_file"

  if ! response="$(curl -fsSL --connect-timeout 10 --max-time 15 -H @"$hdr_file" "$api_url" 2>"$tmp_err")"; then
    curl_err="$(cat "$tmp_err" 2>/dev/null || true)"
    rm -f "$tmp_err" "$hdr_file"
    [[ -n "$curl_err" ]] && echo "curl error: $curl_err" >&2
    return 1
  fi
  rm -f "$tmp_err" "$hdr_file"

  # Only accept well-formed release tags: the tag is later interpolated into
  # a root-executed helper script, so anything else must be rejected here.
  jq -r '.[].name' <<< "$response" 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n 1
}

download_tag_zipball() {
  local tag="$1"
  local destination="$2"
  local zip_url="https://api.github.com/repos/${APP_GITHUB_REPO}/zipball/refs/tags/${tag}"
  local hdr_file rc

  hdr_file="$(mktemp /tmp/lss-curl-hdr-XXXXXX)" || return 1
  github_api_headers > "$hdr_file"

  printf "  Downloading %s...\n" "$tag"
  curl -fsL --connect-timeout 10 --max-time 300 -H @"$hdr_file" -o "$destination" "$zip_url"
  rc=$?
  rm -f "$hdr_file"
  return "$rc"
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
    printf "  Updates are only supported from an installed deployment.\n"
    return 1
  fi

  echo
  read -r -p "  Install update ${remote_tag}? [y/N]: " confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    printf "  Update cancelled.\n"
    return 0
  fi

  # BSD mktemp only randomises a trailing XXXXXX — no suffix after it.
  archive_file="$(mktemp "/tmp/${APP_NAME}-update-zip-XXXXXX")" || return 1
  extract_dir="$(mktemp -d "/tmp/${APP_NAME}-update-XXXXXX")" || return 1

  if ! download_tag_zipball "$remote_tag" "$archive_file"; then
    printf "  Failed to download update archive for %s.\n" "${remote_tag}"
    printf "  Check that this machine has internet access and that api.github.com is reachable.\n"
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
    printf "  Failed to locate the extracted update payload.\n"
    rm -f "$archive_file"
    rm -rf "$extract_dir"
    return 1
  fi

  helper_script="$(mktemp "/tmp/${APP_NAME}-apply-update-XXXXXX")" || return 1
  script_path="$APP_ROOT/$(basename "${BASH_SOURCE[0]}")"

  # Files/dirs in APP_ROOT that must survive the wipe. On macOS APP_ROOT is
  # also DATA_ROOT, so user data, caches and the compiled Wi-Fi helper live
  # here too.
  if [[ "$OS" == "macos" ]]; then
    preserve_find_args=(
      ! -name output
      ! -name raw
      ! -name tmp
      ! -name install.env
      ! -name assets
      ! -name program-defaults.json
      ! -name install-audit.log
      ! -name ubiquiti-oui-cache.txt
      ! -name LSS-WiFiScan.app
      ! -name LSS-WiFiScan.app.version
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
DATA_DIR="$DATA_ROOT"
ARCHIVE_FILE="$archive_file"
EXTRACT_DIR="$extract_dir"
HELPER_SCRIPT="$helper_script"
SCRIPT_PATH="$script_path"
AUDIT_LOG_PATH="$(current_audit_log_path)"

cleanup_payload() {
  rm -f "\$ARCHIVE_FILE"
  rm -rf "\$EXTRACT_DIR"
  rm -f "\$HELPER_SCRIPT"
}

# Verify the payload BEFORE touching the installed copy: a bad download must
# never leave a half-wiped install behind.
if [[ ! -f "\$SOURCE_ROOT/lss-network-tools.sh" || ! -f "\$DEST_DIR/install.env" ]]; then
  echo
  echo "  Update aborted: payload or installation directory is not what was expected."
  echo "  Payload: \$SOURCE_ROOT"
  echo "  Install: \$DEST_DIR"
  cleanup_payload
  exit 1
fi
NEW_VERSION="\$(bash "\$SOURCE_ROOT/lss-network-tools.sh" --version 2>/dev/null || true)"
if [[ "\$NEW_VERSION" != "${APP_NAME} $remote_tag" ]]; then
  echo
  echo "  Update aborted: downloaded payload reports '\$NEW_VERSION', expected '${APP_NAME} $remote_tag'."
  cleanup_payload
  exit 1
fi

find "\$DEST_DIR" -mindepth 1 -maxdepth 1 ${preserve_find_args[*]} -exec rm -rf {} +
# Copy everything except assets/ (merged below so user-placed logos survive)
# and repo-only files that have no business in an installed copy.
find "\$SOURCE_ROOT" -mindepth 1 -maxdepth 1 \\
  ! -name assets ! -name legacy ! -name .github ! -name .gitignore \\
  ! -name CLAUDE.md ! -name ROADMAP.md ! -name __pycache__ ! -name macos \\
  -exec cp -R {} "\$DEST_DIR"/ \\;
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
  echo "  Update verification failed."
  echo "  Expected version: ${APP_NAME} $remote_tag"
  echo "  Reported version: \$REPORTED_VERSION"
  cleanup_payload
  exit 1
fi
printf '%s | %s | %s | %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "update" "success" "Installed version ${remote_tag}" >> "\$AUDIT_LOG_PATH"
cleanup_payload
# Post-update marker lives in the data dir, not world-writable /tmp.
mkdir -p "\$DATA_DIR" 2>/dev/null || true
echo "$remote_tag" > "\$DATA_DIR/.lss-last-update"
echo
echo "  Update applied successfully. Installed Version: $remote_tag"
echo "  Relaunching ${APP_NAME}..."
sleep 1
if [[ "\$(id -u)" -eq 0 ]]; then
  exec "$INSTALL_WRAPPER_PATH"
else
  exec sudo "$INSTALL_WRAPPER_PATH"
fi
EOF
  chmod +x "$helper_script"

  echo
  printf "  Applying update and exiting current session...\n"
  exec bash "$helper_script"
}

check_for_updates() {
  local remote_tag=""
  local yellow='\033[1;33m'
  local green='\033[0;32m'
  local red='\033[0;31m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  echo
  printf "  ${yellow}${bold}Check For Updates${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo

  if ! is_installed_mode; then
    _LSS_STATUS_MSG="Updates are only supported from an installed deployment."
    [[ "$UPDATE_MODE" -eq 1 ]] && printf "  %s\n" "$_LSS_STATUS_MSG"
    return 1
  fi

  printf "  Current Version:  ${bold}%s${reset}\n" "$APP_VERSION"
  echo
  printf "  Checking remote tags...\n"

  local curl_err_out="" tmp_err
  tmp_err="$(mktemp /tmp/lss-update-err-XXXXXX)" || tmp_err=/dev/null
  remote_tag="$(latest_remote_tag_from_github 2>"$tmp_err" || true)"
  curl_err_out="$(cat "$tmp_err" 2>/dev/null || true)"
  [[ "$tmp_err" != /dev/null ]] && rm -f "$tmp_err"
  if [[ -z "$remote_tag" ]]; then
    _LSS_STATUS_MSG="Update check failed — check internet connection."
    if [[ "$UPDATE_MODE" -eq 1 ]]; then
      printf "  %s\n" "$_LSS_STATUS_MSG"
      [[ -n "$curl_err_out" ]] && printf "  %s\n" "$curl_err_out"
    fi
    return 1
  fi

  printf "  Latest Available:  ${bold}%s${reset}\n" "$remote_tag"

  # Only offer an update when the remote is strictly newer; a local build
  # ahead of the latest tag is not "out of date".
  local newest
  newest="$(printf '%s\n%s\n' "$APP_VERSION" "$remote_tag" | sort -V | tail -n 1)"
  if [[ "$remote_tag" == "$APP_VERSION" || "$newest" == "$APP_VERSION" ]]; then
    _LSS_STATUS_MSG="Software is up to date  (${APP_VERSION})"
    [[ "$UPDATE_MODE" -eq 1 ]] && printf "  %s\n" "$_LSS_STATUS_MSG"
    return 0
  fi

  echo
  printf "  ${green}An update is available: %s${reset}\n" "$remote_tag"
  echo
  perform_installed_update "$remote_tag"
}

write_completion_files() {
  local zsh_system_dir="/usr/local/share/zsh/site-functions"
  local zsh_dir=""
  local bash_dir
  local real_home

  # When running under sudo, write zshrc edits to the invoking user's home
  real_home="$(invoking_user_home)"
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
    '--run-task:Run task(s) non-interactively (id, list, 000 or 1,3,5-7)'
    '--build-report:Rebuild the TXT/PDF report for a run directory'
    '--delete-run:Delete a run directory non-interactively'
    '--interface:Interface for a non-interactive run'
    '--client:Client name for a new non-interactive run'
    '--location:Location for a new non-interactive run'
    '--note:Optional note for a new non-interactive run'
    '--run-dir:Continue an existing run directory'
    '--yes:Confirm the stress-test warning (tasks 10, 14, 000)'
    '--target:Target IPv4 address for tasks 13-16'
    '--mac:MAC address for task 20'
    '--wifi-interface:Wireless interface for task 17'
    '--building:Building name for task 17'
    '--floor:Floor for task 17'
    '--room:Room or area for task 17'
    '--ap-present:Access point physically present in the room (y|n)'
    '--ap-label:Access point label for task 17'
    '--wifi-scan-json:Use a pre-captured Wi-Fi scan JSON array for task 17'
    '--controller:UniFi controller host for task 19'
    '--controller-port:UniFi controller port for task 19'
    '--https:Use HTTPS for the inform URL (y|n)'
    '--ssh-user:SSH username for task 19 (password via LSS_SSH_PASSWORD)'
    '--prepared-by:Name printed on the report cover'
    '--output:Directory for a rebuilt report'
    '--no-pdf:Skip PDF generation'
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
  COMPREPLY=($(compgen -W "--version --update --uninstall --build-wifi-helper --debug --run-task --build-report --delete-run --interface --client --location --note --run-dir --yes --target --mac --wifi-interface --building --floor --room --ap-present --ap-label --wifi-scan-json --controller --controller-port --https --ssh-user --prepared-by --output --no-pdf" -- "$cur"))
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
      backup_dir="$(expand_user_path "$backup_dir")"
      # Canonicalise so "." or a relative path cannot slip past the check below.
      mkdir -p "$backup_dir" 2>/dev/null || true
      backup_dir="$(cd "$backup_dir" 2>/dev/null && pwd -P)" || {
        echo "Backup destination is not accessible."
        return 1
      }
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
      # ── Non-interactive mode (macOS app / scripting). Valued flags consume
      #    the next argument; a missing value is a usage error (exit 2). ──────
      --run-task)
        # Mode first so a missing value still reports through the protocol.
        RUN_TASK_MODE=1
        _LSS_NI_FLAGS_SEEN=1
        parse_args_require_value "$@"
        _LSS_NI_RUN_TASK="$2"
        shift
        ;;
      --build-report)
        BUILD_REPORT_MODE=1
        _LSS_NI_FLAGS_SEEN=1
        parse_args_require_value "$@"
        _LSS_NI_BUILD_REPORT_DIR="$2"
        shift
        ;;
      --delete-run)
        DELETE_RUN_MODE=1
        _LSS_NI_FLAGS_SEEN=1
        parse_args_require_value "$@"
        _LSS_NI_DELETE_RUN_DIR="$2"
        shift
        ;;
      --interface)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_INTERFACE="$2"
        shift
        ;;
      --client)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_NEW_RUN_FLAGS=1
        _LSS_NI_CLIENT="$2"
        shift
        ;;
      --location)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_NEW_RUN_FLAGS=1
        _LSS_NI_LOCATION="$2"
        shift
        ;;
      --note)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_NEW_RUN_FLAGS=1
        _LSS_NI_NOTE="$2"
        shift
        ;;
      --run-dir)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_RUN_DIR="$2"
        shift
        ;;
      --yes)
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_STRESS_CONSENT=1
        ;;
      --target)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_TARGET="$2"
        shift
        ;;
      --mac)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_MAC="$2"
        shift
        ;;
      --wifi-interface)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_WIFI_INTERFACE="$2"
        shift
        ;;
      --building)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_BUILDING="$2"
        shift
        ;;
      --floor)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_FLOOR="$2"
        shift
        ;;
      --room)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_ROOM="$2"
        shift
        ;;
      --ap-present)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_AP_PRESENT="$2"
        shift
        ;;
      --ap-label)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_AP_LABEL="$2"
        shift
        ;;
      --wifi-scan-json)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_WIFI_SCAN_JSON="$2"
        shift
        ;;
      --controller)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_CONTROLLER="$2"
        shift
        ;;
      --controller-port)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_CONTROLLER_PORT="$2"
        shift
        ;;
      --https)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_HTTPS="$2"
        shift
        ;;
      --ssh-user)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_SSH_USER="$2"
        shift
        ;;
      --prepared-by)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_PREPARED_BY="$2"
        shift
        ;;
      --output)
        parse_args_require_value "$@"
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_OUTPUT_DIR="$2"
        shift
        ;;
      --no-pdf)
        _LSS_NI_FLAGS_SEEN=1
        _LSS_NI_NO_PDF=1
        ;;
      *)
        if [[ "$RUN_TASK_MODE" -eq 1 || "$BUILD_REPORT_MODE" -eq 1 || "$DELETE_RUN_MODE" -eq 1 ]]; then
          noninteractive_usage_error "Unknown option: $1"
        fi
        echo "Unknown option: $1"
        print_usage
        exit 1
        ;;
    esac
    shift
  done

  # The non-interactive flags only mean something with --run-task/--build-report
  # (--delete-run accepts none of them; ni_delete_args_only enforces that).
  if [[ "$_LSS_NI_FLAGS_SEEN" -eq 1 && "$RUN_TASK_MODE" -eq 0 && "$BUILD_REPORT_MODE" -eq 0 && "$DELETE_RUN_MODE" -eq 0 ]]; then
    noninteractive_usage_error "--interface/--client/--location/--note/--run-dir/--yes/--target/--mac/--building/--floor/--room/--ap-present/--ap-label/--wifi-interface/--wifi-scan-json/--controller/--controller-port/--https/--ssh-user/--prepared-by/--output/--no-pdf require --run-task or --build-report"
  fi
}

print_usage() {
  cat <<'USAGE'
Usage: lss-network-tools [--debug] [--uninstall] [--update] [--version] [--build-wifi-helper] [--write-completions]
       lss-network-tools --run-task list
       lss-network-tools --run-task <id|000|1,3,5-7> --interface <if> (--client <c> --location <l> [--note <n>] | --run-dir <dir>)
                         [--yes] [--target <ip>] [--mac <mac>] [--prepared-by <name>] [--no-pdf] [--debug]
                         [--building <b> --floor <f> --room <r> [--ap-present y|n] [--ap-label <l>] [--wifi-interface <if>] [--wifi-scan-json <file>]]
                         [--controller <host>] [--controller-port <n>] [--https y|n] [--ssh-user <u>]   (SSH password: LSS_SSH_PASSWORD env)
       lss-network-tools --build-report <run-dir> [--prepared-by <name>] [--output <dir>] [--no-pdf]
       lss-network-tools --delete-run <run-dir> [--debug]
USAGE
}

# $1 = flag, $2 = its value (possibly missing). Usage error (exit 2) when absent.
parse_args_require_value() {
  if [[ "$#" -lt 2 ]]; then
    noninteractive_usage_error "$1 requires a value"
  fi
}

# Usage problem involving the non-interactive flags: human text on stdout,
# plus hello/error/bye progress lines when a non-interactive mode was
# requested, exit 2. (A plain unknown option without --run-task keeps the old
# exit 1 path in parse_args.)
noninteractive_usage_error() {
  local message="$1"
  echo "$message"
  print_usage
  if [[ "$RUN_TASK_MODE" -eq 1 || "$BUILD_REPORT_MODE" -eq 1 || "$DELETE_RUN_MODE" -eq 1 ]]; then
    if [[ "${_LSS_NONINTERACTIVE:-}" != "1" ]]; then
      noninteractive_setup
    fi
    emit_progress hello "$(json_str_field version "$APP_VERSION")" "$(json_raw_field pid "$$")" '"tasks":[]'
    emit_progress error "$(json_str_field code usage)" "$(json_str_field message "$message")"
    emit_bye 2
  fi
  exit 2
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
    # Natural sort on the device index so device-2 precedes device-10.
    find "$(current_output_dir)" -maxdepth 1 -type f -name "$file_glob" \
      | awk -F'-device-' '{ n = $NF; sub(/\.json$/, "", n); print n "\t" $0 }' \
      | sort -n | cut -f2- | while IFS= read -r file_path; do
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
  # Highest existing index + 1, so a gap left by a deleted entry never causes
  # a surviving file to be overwritten (count + 1 would).
  count="$(find "$(current_output_dir)" -maxdepth 1 -type f -name "${prefix}-device-*.json" \
    | awk -F'-device-' '{ n = $NF; sub(/\.json$/, "", n); if (n ~ /^[0-9]+$/ && n + 0 > max) max = n + 0 } END { print max + 0 }')"
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

  # Non-interactive mode: --target was validated at startup (tasks 13-16).
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    if [[ -n "$_LSS_NI_TARGET" ]]; then
      echo "$_LSS_NI_TARGET"
      return 0
    fi
    printf "  No --target was given.\n" >&2
    return 1
  fi

  while true; do
    # Callers capture stdout with $(...), so every prompt/error must go to
    # stderr or it ends up inside the returned IP.
    read -r -p "$prompt_text" target_ip || return 1
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

    printf "  Invalid IPv4 address. Try again.\n" >&2
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

  # A new run means a fresh stress-test consent.
  HIGH_IMPACT_STRESS_CONFIRMED=0
  HIGH_IMPACT_STRESS_CONFIRMED_TARGET=""

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}New Run Setup${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  read -r -p "  Location: " RUN_LOCATION
  read -r -p "  Client Name: " RUN_CLIENT_NAME
  read -r -p "  Note (optional — e.g. VLAN 10, Server Room, Guest WiFi): " RUN_NOTE

  initialize_run_context_from_values "$RUN_CLIENT_NAME" "$RUN_LOCATION" "$RUN_NOTE"
}

# Everything after the New Run prompts: defaults, slugs, dated directory with
# the uniqueness suffix, report/debug/manifest paths and the mkdir. Shared by
# the interactive prompts above and the non-interactive --client/--location/
# --note flags (run_noninteractive).
initialize_run_context_from_values() {
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local reset='\033[0m'

  RUN_CLIENT_NAME="$1"
  RUN_LOCATION="$2"
  RUN_NOTE="$3"

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

  # Never reuse an existing run directory: a second same-day run for the same
  # client/location would otherwise merge into (or, on "don't save", delete)
  # the earlier run. Suffix with the start time, then a counter if needed.
  if [[ -e "$RUN_OUTPUT_DIR" ]]; then
    local base_dir="$RUN_OUTPUT_DIR" n=2
    RUN_OUTPUT_DIR="${base_dir}-${RUN_REPORT_TIME_STAMP}"
    while [[ -e "$RUN_OUTPUT_DIR" ]]; do
      RUN_OUTPUT_DIR="${base_dir}-${RUN_REPORT_TIME_STAMP}-${n}"
      n=$((n + 1))
    done
    printf "  ${yellow}A run for this client/location already exists today; using a new directory.${reset}\n"
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
  read -r -p "  Prepared by (full name): " name
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

  # Pick a report name once per run. Regenerate only when none is set, or when
  # the current name points into a *different* run directory (stale from a
  # previous run in this session). An export path outside OUTPUT_DIR (Build A
  # Report → Desktop or a chosen directory) must be left alone.
  if [[ -z "$RUN_REPORT_FILE" ]] \
     || { [[ "$RUN_REPORT_FILE" == "$OUTPUT_DIR/"* ]] && [[ "$RUN_REPORT_FILE" != "$RUN_OUTPUT_DIR/"* ]]; }; then
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
        if task_result_edited "$file_path" "$func_id"; then
          echo "(edited after the run)"
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

  printf "  Report built successfully: %s\n" "$report_file"
}

default_report_export_dir() {
  local home
  home="$(invoking_user_home)"
  if [[ -d "$home/Desktop" ]]; then
    echo "$home/Desktop"
  else
    echo "$home"
  fi
}

load_run_metadata_from_dir() {
  local run_dir="$1"
  local manifest_file="$run_dir/manifest.json"

  if json_file_usable "$manifest_file"; then
    RUN_LOCATION="$(jq -r '.location // "Unknown"' "$manifest_file" 2>/dev/null)"
    RUN_CLIENT_NAME="$(jq -r '.client // "Unknown"' "$manifest_file" 2>/dev/null)"
    RUN_NOTE="$(jq -r '.note // ""' "$manifest_file" 2>/dev/null)"
    # Empty rather than the literal "unknown": callers must not run tasks
    # against an interface called "unknown".
    SELECTED_INTERFACE="$(jq -r '.selected_interface // empty' "$manifest_file" 2>/dev/null)"
    [[ "$SELECTED_INTERFACE" == "unknown" || "$SELECTED_INTERFACE" == "null" ]] && SELECTED_INTERFACE=""
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

  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  while true; do
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Build A Report${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    printf "  Report will be saved to:\n"
    printf "  %s/%s\n" "$export_dir" "$report_name"
    echo
    printf "  Save to a different directory?\n"
    echo
    printf "  ${bold}1)${reset}  Yes — choose directory\n"
    printf "  ${bold}2)${reset}  No — save to default\n"
    printf "  ${bold}3)${reset}  Cancel\n"
    printf "  ${bold}00)${reset}  Back to Main Menu\n"
    echo
    read -r -p "  Choose option: " export_choice

    case "$export_choice" in
      1)
        read -r -p "  New directory: " export_dir
        export_dir="$(expand_user_path "$export_dir")"
        if [[ -z "$export_dir" ]]; then
          printf "  No directory provided.\n"
          sleep 1
          continue
        fi
        mkdir -p "$export_dir" 2>/dev/null || {
          printf "  Unable to create or access directory: %s\n" "$export_dir"
          sleep 1
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
      *) printf "  Invalid selection. Enter 1, 2, 3 or 00.\n"; sleep 1 ;;
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

  printf "  TXT report:    %s\n" "$RUN_REPORT_FILE"
  # The PDF generator renders from the manifest, so it must reflect the files
  # present now (tasks added or deleted via Manage Results, newer task IDs).
  write_manifest_for_current_run || true
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
  read -r -p "  Press Enter to continue..." _
}

list_all_run_dirs() {
  find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
    # GNU stat first: on Linux `stat -f` means filesystem status and
    # succeeds with the wrong value, so it must not be tried first.
    printf '%s\t%s\n' "$(stat -c '%Y' "$dir" 2>/dev/null || stat -f '%m' "$dir" 2>/dev/null || echo 0)" "$dir"
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
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  # Derive current gateway + network from the active default interface
  _derive_current_net() {
    local cur_iface
    if [[ "$OS" == "macos" ]]; then
      cur_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    else
      cur_iface="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    fi
    # Prefer the interface this run was recorded on; only fall back to the
    # default-route interface when none is known. Otherwise a Mac with Wi-Fi
    # up and a USB dongle selected always reports a false mismatch.
    _cur_iface="${SELECTED_INTERFACE:-$cur_iface}"
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
      printf "  ${green}Network matches the original run. Proceeding.${reset}\n"
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
    printf "  ${yellow}Warning: Current network does not match this run's original network.${reset}\n"
    echo
    printf "  %-12s %-28s %s\n" "" "Original Run" "Current (${_cur_iface})"
    printf "  %-12s %-28s %s\n" "Gateway:" "${stored_gateway:-unknown}" "${_current_gateway:-unknown}"
    printf "  %-12s %-28s %s\n" "Network:" "${stored_network:-unknown}" "${_current_network:-unknown}"
    echo
    if [[ "${#iface_names[@]}" -gt 0 ]]; then
      printf "  Active interfaces:\n"
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

    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}1)${reset}  Start a fresh new run on this network\n"
    printf "  ${bold}2)${reset}  Continue this run as-is\n"
    [[ "${#iface_names[@]}" -gt 0 ]] && printf "  ${bold}3)${reset}  Switch to a different interface\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold} 00)${reset}  Back to Main Menu\n"
    printf "  ${bold}  0)${reset}  Cancel\n"
    echo
    local choice
    read -r -p "  Choose option: " choice
    case "$choice" in
      1)
        # Unwind every menu back to the startup loop, which then proceeds
        # straight into select_interface → initialize_run_context.
        _START_FRESH_RUN=true
        _GOTO_MAIN_MENU=true
        return 2
        ;;
      2) return 0 ;;
      3)
        if [[ "${#iface_names[@]}" -eq 0 ]]; then
          printf "  No active interfaces available.\n"
          sleep 1
          continue
        fi
        local iface_choice
        read -r -p "  Interface number (0 to go back): " iface_choice
        if [[ "$iface_choice" == "0" ]]; then continue; fi
        if [[ "$iface_choice" =~ ^[0-9]+$ ]] && (( iface_choice >= 1 && iface_choice <= ${#iface_names[@]} )); then
          SELECTED_INTERFACE="${iface_names[$((iface_choice - 1))]}"
        else
          printf "  Invalid selection.\n"
          sleep 1
        fi
        ;;
      00) _GOTO_MAIN_MENU=true; return 1 ;;
      0) return 1 ;;
      *) printf "  Invalid selection.\n"; sleep 1 ;;
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
  # Do NOT point SESSION_DEBUG_LOG at the run's debug.txt: tee is already
  # bound to the session file, and finalize_run would cp a file onto itself
  # and then delete it.
  load_run_metadata_from_dir "$run_dir"
  if [[ -z "$SELECTED_INTERFACE" ]]; then
    SELECTED_INTERFACE="$previous_selected_interface"
  fi
  if [[ -z "$SELECTED_INTERFACE" ]]; then
    printf "  This run has no recorded interface. Choose one to continue.\n"
    if ! select_interface; then
      _restore_continue_state
      return 0
    fi
  fi

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
    read -r -p "  Tasks to run (e.g. 1,3,4 — 0 or Enter = back): " run_input
    if [[ "$run_input" == "0" ]] || [[ -z "$run_input" ]]; then
      _restore_continue_state
      return 0
    fi
    IFS=', ' read -r -a run_filter <<< "$run_input"

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
        printf "  Task %s (%s) failed — continuing with remaining tasks.\n" "$task_id" "$title"
      fi
    done
    write_manifest_for_current_run || true

    echo
    local _post_choice
    local cyan='\033[0;36m'
    local bold='\033[1m'
    local reset='\033[0m'
    while true; do
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      printf "  ${bold}1)${reset}  Continue with another task\n"
      printf "  ${bold}2)${reset}  Save Run and Go Back\n"
      echo
      read -r -p "  Choose: " _post_choice
      case "$_post_choice" in
        1) echo; break ;;
        2)
          _restore_continue_state
          return 0
          ;;
        *) printf "  Choose 1 or 2.\n" ;;
      esac
    done
  done

  _restore_continue_state
}

manage_results_for_run_dir() {
  local run_dir="$1"
  local previous_output_dir="${RUN_OUTPUT_DIR:-}"
  local available_ids=()
  local task_id title choice_str
  local tmp_out entry_index file_path description
  local cyan='\033[0;36m'
  local yellow='\033[1;33m'
  local bold='\033[1m'
  local green='\033[0;32m'
  local red='\033[0;31m'
  local reset='\033[0m'
  local -a all_ids all_titles all_avail
  local half tl_tmp tr_tmp term_width col_w i

  RUN_OUTPUT_DIR="$run_dir"
  # Restore RUN_OUTPUT_DIR on any exit from this function, including crashes
  trap 'RUN_OUTPUT_DIR="$previous_output_dir"; trap - RETURN' RETURN

  while true; do
    # Rebuild available list each iteration
    available_ids=()
    all_ids=() all_titles=() all_avail=()
    clear_screen_if_supported

    # Collect all task data
    for task_id in $(get_task_ids); do
      title="$(task_title "$task_id")"
      all_ids+=("$task_id")
      all_titles+=("$title")
      if [[ -n "$(task_json_files "$task_id")" ]]; then
        available_ids+=("$task_id")
        all_avail+=("1")
      else
        all_avail+=("0")
      fi
    done

    # Terminal width for two-column layout
    term_width="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
    [[ -z "$term_width" || "$term_width" -lt 60 ]] && term_width="${COLUMNS:-80}"
    [[ "$term_width" -lt 60 ]] && term_width=80
    col_w=$(( (term_width - 5) / 2 ))

    echo
    printf "  ${yellow}${bold}Manage Results${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    half=$(( (${#all_ids[@]} + 1) / 2 ))
    tl_tmp="$(mktemp /tmp/lss-tl-XXXXXX)"
    tr_tmp="$(mktemp /tmp/lss-tr-XXXXXX)"
    {
      for (( i=0; i<half; i++ )); do
        if [[ "${all_avail[$i]}" == "1" ]]; then
          printf "${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "${all_ids[$i]}" "${all_titles[$i]}"
        else
          printf "[ ]  %2s)  %s\n" "${all_ids[$i]}" "${all_titles[$i]}"
        fi
      done
    } > "$tl_tmp"
    {
      for (( i=half; i<${#all_ids[@]}; i++ )); do
        if [[ "${all_avail[$i]}" == "1" ]]; then
          printf "${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "${all_ids[$i]}" "${all_titles[$i]}"
        else
          printf "[ ]  %2s)  %s\n" "${all_ids[$i]}" "${all_titles[$i]}"
        fi
      done
    } > "$tr_tmp"
    python3 - "$tl_tmp" "$tr_tmp" "$col_w" << 'PYEOF'
import sys, re
def strip_ansi(s):
    return re.sub(r'\033\[[0-9;]*m', '', s)
def pad_line(s, width):
    return s + ' ' * max(0, width - len(strip_ansi(s)))
fa, fb, col_w = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(fa) as f:
    left = [l.rstrip('\n') for l in f]
with open(fb) as f:
    right = [l.rstrip('\n') for l in f]
n = max(len(left), len(right))
for i in range(n):
    l = '  ' + (left[i] if i < len(left) else '')
    r = right[i] if i < len(right) else ''
    print(pad_line(l, col_w + 2) + '   ' + r)
PYEOF
    rm -f "$tl_tmp" "$tr_tmp"

    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    if [[ "${#available_ids[@]}" -eq 0 ]]; then
      printf "  No task results available for this run.\n"
      echo
      read -r -p "  Press Enter to continue..." _
      return
    fi

    read -r -p "  Enter task numbers to manage (e.g. 1,3 or 1-12), 0 to go back, 00 for main menu: " choice_str

    [[ "$choice_str" == "00" ]] && { _GOTO_MAIN_MENU=true; return; }
    [[ "$choice_str" == "0" ]] && return
    [[ -z "${choice_str// /}" ]] && continue

    local -a choice_arr=()
    IFS=',' read -ra choice_arr <<< "$choice_str"

    # Expand any N-M ranges into individual IDs
    local -a expanded_arr=()
    local c
    for c in "${choice_arr[@]+"${choice_arr[@]}"}"; do
      c="${c// /}"
      [[ -z "$c" ]] && continue
      if [[ "$c" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local rstart="${BASH_REMATCH[1]}" rend="${BASH_REMATCH[2]}"
        local n max_id
        # Clamp to the highest task ID so "1-999999999" cannot build a
        # billion-element array before validation.
        max_id="$(get_task_ids | sort -n | tail -n 1)"
        [[ "$rend" -gt "$max_id" ]] && rend="$max_id"
        for (( n=rstart; n<=rend; n++ )); do
          expanded_arr+=("$n")
        done
      else
        expanded_arr+=("$c")
      fi
    done

    local selected_ids=()
    local valid=true
    for c in "${expanded_arr[@]+"${expanded_arr[@]}"}"; do
      [[ -z "$c" ]] && continue
      if [[ "$c" =~ ^[0-9]+$ ]] && run_task_exists "$c"; then
        if [[ -n "$(task_json_files "$c")" ]]; then
          selected_ids+=("$c")
        else
          # Task hasn't been run — offer to run it now
          local _t_title
          _t_title="$(task_title "$c")"
          echo ""
          printf "  Task %s — %s has not been run yet.\n" "$c" "$_t_title"
          local _run_ans
          read -r -p "  Run it now? [y/N]: " _run_ans
          if [[ "$_run_ans" =~ ^[Yy]$ ]]; then
            # Load run metadata (sets SELECTED_INTERFACE from manifest)
            local _prev_iface="${SELECTED_INTERFACE:-}"
            load_run_metadata_from_dir "$run_dir"
            # Check we're on the same network as the original run
            local _net_check=0
            check_continue_run_network "$run_dir" || _net_check=$?
            if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then
              SELECTED_INTERFACE="$_prev_iface"
              return
            fi
            if [[ "$_net_check" -ne 0 ]]; then
              echo ""
              printf "  \033[0;31m\033[1mWARNING:\033[0m Network mismatch — returning to task list.\n"
              sleep 5
              SELECTED_INTERFACE="$_prev_iface"
              valid=false
              break
            fi
            if [[ -z "${SELECTED_INTERFACE:-}" ]]; then
              echo "  Could not determine interface from this run."
              sleep 1
            else
              run_task_with_results_output "$c" "$_t_title" || true
              if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then
                SELECTED_INTERFACE="$_prev_iface"
                return
              fi
            fi
            SELECTED_INTERFACE="$_prev_iface"
          fi
          valid=false
          break
        fi
      else
        printf "  Invalid selection: %s\n" "$c"
        valid=false
        break
      fi
    done
    [[ "$valid" == "false" ]] && continue
    [[ "${#selected_ids[@]}" -eq 0 ]] && continue

    # Sub-menu: View / Edit / Delete selected tasks
    while true; do
      clear_screen_if_supported
      echo
      printf "  ${yellow}${bold}Manage Results${reset}\n"
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      echo
      for sid in "${selected_ids[@]}"; do
        printf "  Task %s — %s\n" "$sid" "$(task_title "$sid")"
      done
      echo
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      printf "  ${bold}1)${reset}  View Results\n"
      printf "  ${bold}2)${reset}  Edit Results\n"
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      if [[ "${#selected_ids[@]}" -eq 1 ]]; then
        printf "  ${red}${bold}000)${reset}  ${red}Delete This Task${reset}\n"
      else
        printf "  ${red}${bold}000)${reset}  ${red}Delete These Tasks${reset}\n"
      fi
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      printf "  ${bold}  0)${reset}  Back\n"
      echo
      local _mgmt_choice
      read -r -p "  Choose: " _mgmt_choice

      case "$_mgmt_choice" in
        1)
          # View results
          tmp_out="$(mktemp)"
          for task_id in "${selected_ids[@]}"; do
            title="$(task_title "$task_id")"
            description="$(task_description "$task_id")"
            entry_index=0
            while IFS= read -r file_path; do
              [[ -z "$file_path" ]] && continue
              entry_index=$((entry_index + 1))
              {
                echo
                if task_supports_multiple_entries "$task_id"; then
                  printf "  ${yellow}${bold}Task %s — %s  (Device %s)${reset}\n" "$task_id" "$title" "$entry_index"
                else
                  printf "  ${yellow}${bold}Task %s — %s${reset}\n" "$task_id" "$title"
                fi
                if task_result_edited "$file_path" "$task_id"; then
                  printf "  ${yellow}(edited after the run)${reset}\n"
                fi
                [[ -n "$description" ]] && printf "  ${cyan}%s${reset}\n" "$description"
                printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
                echo
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
                17) render_wireless_site_survey_report "$file_path" "$tmp_out" "color" ;;
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
          read -r -p "  Press Enter to continue..." _
          ;;
        2)
          # Edit results — show numbered field list, user picks which to edit
          local _edit_py _update_py
          _edit_py="$(mktemp /tmp/lss-edit-fields-XXXXXX)"
          _update_py="$(mktemp /tmp/lss-edit-update-XXXXXX)"
          cat > "$_edit_py" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for k, v in data.items():
    if isinstance(v, (str, int, float, bool, type(None))):
        if v is None:
            shown = ""
        elif isinstance(v, bool):
            shown = "true" if v else "false"
        else:
            shown = v
        print(f"{k}\t{shown}")
PYEOF
          cat > "$_update_py" << 'PYEOF'
import json, sys
# Coerce the typed value to the ORIGINAL field's type so a string field like
# hostname "1234" stays a string and a boolean stays a boolean.
file_path, key, new_val_str = sys.argv[1], sys.argv[2], sys.argv[3]
with open(file_path) as f:
    data = json.load(f)
old = data.get(key)
s = new_val_str.strip()
if isinstance(old, bool):
    new_val = s.lower() in ("true", "yes", "y", "1")
elif isinstance(old, int) and not isinstance(old, bool):
    try:
        new_val = int(s)
    except ValueError:
        try:
            new_val = float(s)
        except ValueError:
            new_val = s
elif isinstance(old, float):
    try:
        new_val = float(s)
    except ValueError:
        new_val = s
elif old is None:
    if s == "" or s.lower() in ("null", "none"):
        new_val = None
    else:
        try:
            new_val = json.loads(s)
        except Exception:
            new_val = s
else:
    new_val = new_val_str
data[key] = new_val
with open(file_path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
          for task_id in "${selected_ids[@]}"; do
            title="$(task_title "$task_id")"
            entry_index=0
            while IFS= read -r file_path; do
              [[ -z "$file_path" ]] && continue
              entry_index=$((entry_index + 1))
              local _tmp_copy
              _tmp_copy="$(mktemp /tmp/lss-edit-copy-XXXXXX)"
              cp "$file_path" "$_tmp_copy"
              local _edit_done=false
              while [[ "$_edit_done" == "false" ]]; do
                clear_screen_if_supported
                echo
                if task_supports_multiple_entries "$task_id"; then
                  printf "  ${yellow}${bold}Edit Task %s — %s  (Device %s)${reset}\n" "$task_id" "$title" "$entry_index"
                else
                  printf "  ${yellow}${bold}Edit Task %s — %s${reset}\n" "$task_id" "$title"
                fi
                printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
                echo
                # Build indexed field list from the working copy
                local -a _fkeys=() _fvals=()
                while IFS=$'\t' read -r _k _v; do
                  _fkeys+=("$_k")
                  _fvals+=("$_v")
                done < <(python3 "$_edit_py" "$_tmp_copy" 2>/dev/null)
                local _fi
                for (( _fi=0; _fi<${#_fkeys[@]}; _fi++ )); do
                  printf "  ${bold}%2s)${reset}  %-28s  %s\n" \
                    "$(( _fi + 1 ))" "${_fkeys[$_fi]}:" "${_fvals[$_fi]}"
                done
                echo
                printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
                printf "  ${bold}s)${reset}  Save changes\n"
                printf "  ${bold}0)${reset}  Cancel (discard changes)\n"
                echo
                local _pick _new_val
                read -r -p "  Choose field to edit: " _pick </dev/tty
                case "$_pick" in
                  0)
                    rm -f "$_tmp_copy"
                    printf "  ${yellow}Cancelled — no changes saved.${reset}\n"
                    sleep 1
                    _edit_done=true
                    ;;
                  s|S)
                    # Compare canonical JSON: the copy was rewritten by Python
                    # (json.dump) while the engine wrote the file with jq, so
                    # re-entering the same value is byte-different but no edit.
                    if cmp -s <(jq -S . "$_tmp_copy" 2>/dev/null) <(jq -S . "$file_path" 2>/dev/null); then
                      printf "  ${yellow}No changes to save.${reset}\n"
                    else
                      # Stamp the edit so reports, findings and the app can tell
                      # an edited result from a measured one.
                      if jq --arg t "$(iso8601_utc_now)" '.edited_at = $t' "$_tmp_copy" > "$_tmp_copy.stamped" 2>/dev/null; then
                        mv -f "$_tmp_copy.stamped" "$_tmp_copy"
                      else
                        rm -f "$_tmp_copy.stamped"
                      fi
                      cp "$_tmp_copy" "$file_path"
                      chmod 644 "$file_path" 2>/dev/null || true
                      printf "  ${green}Saved (marked as edited after the run).${reset}\n"
                    fi
                    rm -f "$_tmp_copy"
                    sleep 1
                    _edit_done=true
                    ;;
                  *)
                    if [[ "$_pick" =~ ^[0-9]+$ ]] && \
                       [[ "$_pick" -ge 1 ]] && \
                       [[ "$_pick" -le "${#_fkeys[@]}" ]]; then
                      local _fidx=$(( _pick - 1 ))
                      local _cur_key="${_fkeys[$_fidx]}"
                      local _cur_val="${_fvals[$_fidx]}"
                      echo
                      printf "  ${bold}%s${reset}  (current: %s)\n" "$_cur_key:" "$_cur_val"
                      read -r -p "  New value (Enter to keep current): " _new_val </dev/tty
                      if [[ -n "$_new_val" ]]; then
                        python3 "$_update_py" "$_tmp_copy" "$_cur_key" "$_new_val" 2>/dev/null \
                          || printf "  ${red}Failed to update '%s'${reset}\n" "$_cur_key"
                      fi
                    else
                      printf "  Invalid selection.\n"
                      sleep 1
                    fi
                    ;;
                esac
              done
            done < <(task_json_files "$task_id")
          done
          rm -f "$_edit_py" "$_update_py"
          ;;
        000)
          # Delete — confirm first
          echo
          if [[ "${#selected_ids[@]}" -eq 1 ]]; then
            printf "  ${red}Delete results for Task %s — %s?${reset}\n" \
              "${selected_ids[0]}" "$(task_title "${selected_ids[0]}")"
          else
            printf "  ${red}Delete results for tasks: %s?${reset}\n" "${selected_ids[*]}"
          fi
          local _del_confirm
          read -r -p "  Type YES/yes to confirm: " _del_confirm
          if [[ "$_del_confirm" == "YES" || "$_del_confirm" == "yes" ]]; then
            for task_id in "${selected_ids[@]}"; do
              while IFS= read -r file_path; do
                [[ -z "$file_path" ]] && continue
                rm -f "$file_path"
              done < <(task_json_files "$task_id")
            done
            printf "  Deleted.\n"
            sleep 1
            break
          else
            printf "  Cancelled.\n"
            sleep 1
          fi
          ;;
        0)
          break
          ;;
      esac
    done
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

  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  if [[ "${#run_dirs[@]}" -eq 0 ]]; then
    printf "  No other runs available to compare with.\n"
    return 0
  fi

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}Compare This Run${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  local idx
  for idx in "${!run_dirs[@]}"; do
    printf "  ${bold}%2d)${reset}  %s\n" "$(( idx + 1 ))" "$(run_dir_label "${run_dirs[$idx]}")"
  done
  echo
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  printf "  ${bold}  0)${reset}  Cancel\n"
  echo
  local choice
  read -r -p "  Choose run: " choice
  [[ "$choice" == "0" || -z "$choice" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "${#run_dirs[@]}" ]]; then
    printf "  Invalid selection.\n"
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
  read -r -p "  Press Enter to continue..." _
}

build_compare_report_for_run_dir() {
  local run_dir_a="$1"

  local run_dirs=()
  while IFS= read -r dir; do
    [[ "$dir" == "$run_dir_a" ]] && continue
    [[ -n "$dir" ]] && run_dirs+=("$dir")
  done < <(list_all_run_dirs)

  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  if [[ "${#run_dirs[@]}" -eq 0 ]]; then
    printf "  No other runs available to compare with.\n"
    return 0
  fi

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}Build Compared Report${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  local idx
  for idx in "${!run_dirs[@]}"; do
    printf "  ${bold}%2d)${reset}  %s\n" "$(( idx + 1 ))" "$(run_dir_label "${run_dirs[$idx]}")"
  done
  echo
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  printf "  ${bold}  0)${reset}  Cancel\n"
  echo
  local choice
  read -r -p "  Choose run: " choice
  [[ "$choice" == "0" || -z "$choice" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "${#run_dirs[@]}" ]]; then
    printf "  Invalid selection.\n"
    return 0
  fi

  local run_dir_b="${run_dirs[$(( choice - 1 ))]}"

  local export_dir
  export_dir="$(default_report_export_dir)"
  local pdf_name="lss-compare-$(date '+%d-%m-%Y-%H-%M').pdf"

  while true; do
    echo
    printf "  PDF will be saved to %s/%s\n" "$export_dir" "$pdf_name"
    printf "  Would you like to save it somewhere else?\n"
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}1)${reset}  Yes — choose a different directory\n"
    printf "  ${bold}2)${reset}  No — use the default location\n"
    printf "  ${bold}3)${reset}  Cancel\n"
    echo
    local export_choice
    read -r -p "  Choose option: " export_choice
    case "$export_choice" in
      1)
        read -r -p "  New directory: " export_dir
        export_dir="$(expand_user_path "$export_dir")"
        if [[ -z "$export_dir" ]]; then
          printf "  No directory provided.\n"
          continue
        fi
        mkdir -p "$export_dir" 2>/dev/null || { printf "  Unable to create directory: %s\n" "$export_dir"; continue; }
        break
        ;;
      2) mkdir -p "$export_dir" 2>/dev/null || true; break ;;
      3) return 0 ;;
      *) printf "  Invalid selection.\n" ;;
    esac
  done

  local pdf_path="$export_dir/$pdf_name"
  local py_script="$APP_ROOT/generate_pdf_compare_report.py"

  if [[ ! -f "$py_script" ]]; then
    printf "  Compare PDF generator not found: %s\n" "$py_script"
    return 0
  fi
  if ! python3 -c "import fpdf" 2>/dev/null; then
    printf "  PDF generation skipped: fpdf2 not installed (pip3 install fpdf2)\n"
    return 0
  fi

  printf "  Generating comparison PDF...\n"
  local pdf_err
  pdf_err="$(python3 "$py_script" "$run_dir_a" "$run_dir_b" "$pdf_path" "$APP_ROOT" 2>&1 >/dev/null || true)"
  if [[ -f "$pdf_path" ]]; then
    printf "  PDF saved: %s\n" "$pdf_path"
  else
    printf "  PDF generation failed%s\n" "${pdf_err:+: $pdf_err}"
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
    printf "  ${bold}2)${reset}  Manage Results\n"
    printf "  ${bold}3)${reset}  Continue This Run\n"
    printf "  ${bold}4)${reset}  Compare This Run\n"
    printf "  ${bold}5)${reset}  Build Compared Report\n"
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${red}${bold}000)${reset}  Delete This Run\n"
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
        manage_results_for_run_dir "$run_dir" || true
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      3)
        continue_run_from_dir "$run_dir" || true
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      4)
        compare_runs_cli "$run_dir" || true
        ;;
      5)
        build_compare_report_for_run_dir "$run_dir" || true
        ;;
      000)
        echo
        read -r -p "  Delete '$(basename "$run_dir")'? [y/N]: " confirmation
        if [[ "$confirmation" =~ ^[Yy]$ ]]; then
          delete_run_directory "$run_dir"
          printf "  Run deleted.\n"
          return 0
        else
          printf "  Deletion cancelled.\n"
        fi
        ;;
      *) printf "  Invalid selection. Try again.\n"; sleep 1 ;;
    esac
  done
}

# The one place a run directory is removed: the interactive "000) Delete This
# Run" (after its y/N confirmation) and --delete-run (after
# noninteractive_validate) both end here. Returns rm's status; the callers
# decide what to print.
delete_run_directory() {
  rm -rf "$1"
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
          printf "  Invalid selection. Try again.\n"
          sleep 1
        fi
        ;;
    esac
  done
}

_setup_program_defaults() {
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local green='\033[0;32m'
  local bold='\033[1m'
  local reset='\033[0m'

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}Setup Program Defaults${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  printf "  Configure default values used across all tasks.\n"
  printf "  Press Enter to accept the value shown in brackets.\n"
  echo

  local _val

  printf "  ${bold}UniFi Adoption${reset}\n"
  echo
  read -r -p "  Controller domain or IP: " _val
  set_program_default "unifi_domain" "${_val:-unifi.lssolutions.ie}"

  read -r -p "  Controller port [8080]: " _val
  set_program_default "unifi_port" "${_val:-8080}"

  read -r -p "  Use HTTPS by default? [y/N]: " _val
  if [[ "$_val" =~ ^[Yy]$ ]]; then
    set_program_default "unifi_https" "y"
  else
    set_program_default "unifi_https" "n"
  fi

  echo
  printf "  ${green}Program defaults saved.${reset}\n"
  sleep 1
}

_view_program_defaults() {
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  clear_screen_if_supported
  echo
  printf "  ${yellow}${bold}Program Defaults${reset}\n"
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo

  if [[ ! -f "$PROGRAM_DEFAULTS_FILE" ]]; then
    printf "  No program defaults configured yet.\n"
    echo
    read -r -p "  Press Enter to continue..." _
    return 0
  fi

  local _https_val _https_label
  _https_val="$(get_program_default "unifi_https" "n")"
  [[ "$_https_val" == "y" ]] && _https_label="Yes" || _https_label="No"

  printf "  ${bold}%-30s${reset}  %s\n" "Setting" "Value"
  printf "  %-30s  %s\n" "------------------------------" "------------------------------"
  printf "  %-30s  %s\n" "UniFi Domain:"    "$(get_program_default "unifi_domain" "(not set)")"
  printf "  %-30s  %s\n" "UniFi Port:"      "$(get_program_default "unifi_port"   "(not set)")"
  printf "  %-30s  %s\n" "UniFi Use HTTPS:" "$_https_label"

  echo
  read -r -p "  Press Enter to continue..." _
}

_edit_program_defaults() {
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local green='\033[0;32m'
  local bold='\033[1m'
  local reset='\033[0m'

  while true; do
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Edit Program Defaults${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    local _https_val _https_label
    _https_val="$(get_program_default "unifi_https" "n")"
    [[ "$_https_val" == "y" ]] && _https_label="Yes" || _https_label="No"

    printf "  ${bold}%-4s${reset}  %-30s  %s\n" "#" "Setting" "Current Value"
    printf "  %-4s  %-30s  %s\n" "----" "------------------------------" "------------------------------"
    printf "  ${bold}%-4s${reset}  %-30s  %s\n" "1)" "UniFi Domain:"    "$(get_program_default "unifi_domain" "(not set)")"
    printf "  ${bold}%-4s${reset}  %-30s  %s\n" "2)" "UniFi Port:"      "$(get_program_default "unifi_port"   "(not set)")"
    printf "  ${bold}%-4s${reset}  %-30s  %s\n" "3)" "UniFi Use HTTPS:" "$_https_label"
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}0)${reset}  Back\n"
    echo

    local _choice _val
    read -r -p "  Choose setting to edit: " _choice
    case "$_choice" in
      1)
        local _cur; _cur="$(get_program_default "unifi_domain" "unifi.lssolutions.ie")"
        read -r -p "  UniFi Domain [$_cur]: " _val
        set_program_default "unifi_domain" "${_val:-$_cur}"
        printf "  ${green}Saved.${reset}\n"; sleep 1
        ;;
      2)
        local _cur; _cur="$(get_program_default "unifi_port" "8080")"
        read -r -p "  UniFi Port [$_cur]: " _val
        set_program_default "unifi_port" "${_val:-$_cur}"
        printf "  ${green}Saved.${reset}\n"; sleep 1
        ;;
      3)
        local _cur; _cur="$(get_program_default "unifi_https" "n")"
        if [[ "$_cur" == "y" ]]; then
          read -r -p "  Use HTTPS? [Y/n]: " _val
          if [[ "$_val" =~ ^[Nn]$ ]]; then
            set_program_default "unifi_https" "n"
          else
            set_program_default "unifi_https" "y"
          fi
        else
          read -r -p "  Use HTTPS? [y/N]: " _val
          if [[ "$_val" =~ ^[Yy]$ ]]; then
            set_program_default "unifi_https" "y"
          else
            set_program_default "unifi_https" "n"
          fi
        fi
        printf "  ${green}Saved.${reset}\n"; sleep 1
        ;;
      0) return 0 ;;
      *) printf "  Invalid selection.\n"; sleep 1 ;;
    esac
  done
}

program_defaults_menu() {
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  while true; do
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Program Defaults${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo

    local _has_defaults=false
    [[ -f "$PROGRAM_DEFAULTS_FILE" ]] && _has_defaults=true

    if [[ "$_has_defaults" == "false" ]]; then
      printf "  ${bold}1)${reset}  Setup Program Defaults\n"
      printf "  ${bold}2)${reset}  View Program Defaults\n"
      printf "  ${bold}3)${reset}  Edit Program Defaults\n"
    else
      printf "  ${bold}1)${reset}  View Program Defaults\n"
      printf "  ${bold}2)${reset}  Edit Program Defaults\n"
    fi
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}0)${reset}  Back\n"
    echo

    local _choice
    read -r -p "  Choose option: " _choice
    if [[ "$_has_defaults" == "false" ]]; then
      case "$_choice" in
        1) _setup_program_defaults ;;
        2) _view_program_defaults ;;
        3) _edit_program_defaults ;;
        0) return 0 ;;
        *) printf "  Invalid selection.\n"; sleep 1 ;;
      esac
    else
      case "$_choice" in
        1) _view_program_defaults ;;
        2) _edit_program_defaults ;;
        0) return 0 ;;
        *) printf "  Invalid selection.\n"; sleep 1 ;;
      esac
    fi
  done
}

# Path of the installed macOS app, or nothing (return 1). /Applications first, then
# the invoking user's ~/Applications; `make install` in macos/ puts it in /Applications.
gui_app_path() {
  local candidate
  for candidate in "/Applications/LSS Network Tools.app" "$(invoking_user_home)/Applications/LSS Network Tools.app"; do
    if [[ -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Startup-menu option (macOS): open the graphical interface. The CLI normally runs
# under sudo, so the app is opened as the invoking user — started as root it would use
# root's settings and privacy grants and could not talk to the privileged helper.
launch_graphical_interface() {
  local yellow='\033[1;33m'
  local green='\033[0;32m'
  local reset='\033[0m'
  local app_path=""
  app_path="$(gui_app_path || true)"
  if [[ -z "$app_path" ]]; then
    printf "  ${yellow}The graphical interface is not installed on this Mac.${reset}\n"
    printf "  Install it from the repository checkout: cd macos && make install\n"
    return 1
  fi
  printf "  Opening %s...\n" "$app_path"
  if [[ "$(id -u)" == "0" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if ! sudo -u "$SUDO_USER" -H /usr/bin/open "$app_path"; then
      printf "  ${yellow}The app could not be opened as %s.${reset}\n" "$SUDO_USER"
      return 1
    fi
  elif ! /usr/bin/open "$app_path"; then
    printf "  ${yellow}The app could not be opened.${reset}\n"
    return 1
  fi
  printf "  ${green}The graphical interface is opening. This menu stays available.${reset}\n"
  return 0
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
    # Pick up "just updated" flag written by the update helper before relaunch
    if [[ -f "$DATA_ROOT/.lss-last-update" ]]; then
      local _upd_ver
      _upd_ver="$(head -n 1 "$DATA_ROOT/.lss-last-update" 2>/dev/null || true)"
      rm -f "$DATA_ROOT/.lss-last-update"
      [[ "$_upd_ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && _LSS_STATUS_MSG="Updated successfully to ${_upd_ver}"
    fi
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
    # Show one-shot status message from last action (update check result, post-update)
    if [[ -n "${_LSS_STATUS_MSG:-}" ]]; then
      printf "  ${green}%s${reset}\n" "${_LSS_STATUS_MSG}"
      echo
      _LSS_STATUS_MSG=""
    fi
    printf "  ${bold}1)${reset}  Run LSS Network Tools\n"
    printf "  ${bold}2)${reset}  Manage Previous Runs\n"
    printf "  ${bold}3)${reset}  Check For Updates\n"
    printf "  ${bold}4)${reset}  About & Install Health\n"
    printf "  ${bold}5)${reset}  Program Defaults\n"
    if [[ "$OS" == "macos" ]]; then
      printf "  ${bold}6)${reset}  Launch Graphical Interface\n"
      printf "  ${bold}7)${reset}  Exit\n"
    else
      printf "  ${bold}6)${reset}  Exit\n"
    fi
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    read -r -p "  Choose option: " choice

    case "$choice" in
      1) return 0 ;;
      2)
        clear_screen_if_supported
        manage_previous_runs || true
        # "Start a fresh new run" chosen inside a network-mismatch prompt:
        # return to the startup loop, which proceeds to interface selection.
        if [[ "${_START_FRESH_RUN:-false}" == "true" ]]; then
          _GOTO_MAIN_MENU=false
          return 0
        fi
        ;;
      3)
        clear_screen_if_supported
        check_for_updates || true
        ;;
      4)
        clear_screen_if_supported
        about_and_health || true
        read -r -p "  Press Enter to return to the startup menu..." _
        ;;
      5)
        program_defaults_menu || true
        ;;
      6)
        if [[ "$OS" == "macos" ]]; then
          clear_screen_if_supported
          launch_graphical_interface || true
          read -r -p "  Press Enter to return to the startup menu..." _
        else
          exit 0
        fi
        ;;
      7)
        if [[ "$OS" == "macos" ]]; then
          exit 0
        fi
        printf "  Invalid selection. Try again.\n"
        sleep 1
        ;;
      *)
        printf "  Invalid selection. Try again.\n"
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
      severity="warning"
      if [[ "$task_id" == "5" ]]; then
        # A probe that could not run is not a DHCP outage: informational,
        # naming the error code, and no loss is derived from it.
        severity="info"
        title="DHCP response-time probe could not run ($(jq -r '.error.code // "PROBE_FAILED"' "$file" 2>/dev/null))"
        detail="${detail} No loss or latency was measured, so this is not evidence of a DHCP fault."
      fi
      findings_json="$(append_finding_record_checked "$findings_json" "$severity" "$title" "$detail" "$(basename "$file")" "$file" "$task_id")"
    elif [[ "$status" == "completed_with_warnings" ]]; then
      title="${label} completed with warnings"
      detail="$(jq -r '(.warnings // []) | if length > 0 then join(" ") else "The scan completed with warnings." end' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record_checked "$findings_json" "info" "$title" "$detail" "$(basename "$file")" "$file" "$task_id")"
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
      detail="$(jq -r --arg lease "$(jq -r '.system_lease.server // empty' "$file" 2>/dev/null)" '
        [.servers[]? | select(.suspected_rogue == true)
          | .ip + (if ((.rogue_reasons // []) | length) > 0 then " (" + ((.rogue_reasons // []) | map(
              if . == "multiple_server_identifiers" then "more than one DHCP server identifier on this network"
              elif . == "differs_from_system_lease" then "differs from the server that leased this interface its address" + (if $lease != "" then " (" + $lease + ")" else "" end)
              elif . == "offered_router_not_on_subnet" then "offered router is not on this subnet"
              elif . == "server_outside_subnet_without_relay" then "server outside this subnet with no relay agent seen"
              else . end) | join("; ")) + ")" else "" end)] as $with_reasons
        | if ($with_reasons | length) > 0 then "Suspected rogue DHCP responders: " + ($with_reasons | join(", ")) + "."
          elif (.suspected_rogue_servers // []) | length > 0 then "Suspected rogue DHCP responders: " + ((.suspected_rogue_servers // []) | join(", ")) + "."
          else "A possible rogue DHCP responder was observed." end' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record_checked "$findings_json" "high" "Possible rogue DHCP responder observed" "$detail" "dhcp-scan.json" "$file" 4)"
    fi
    if [[ "$(jq -r '.dhcp_responders_observed // 0' "$file" 2>/dev/null)" == "0" ]]; then
      if [[ "$(jq -r '.evidence // "none"' "$file" 2>/dev/null)" == "system_lease" ]]; then
        detail="$(jq -r '"No DHCP offer reached the discovery probes, but this interface holds a lease from " + (.system_lease.server // "unknown") + (if .system_lease.obtained_at then " obtained " + .system_lease.obtained_at else "" end) + ". A DHCP server exists on this network but did not answer broadcast discovery from this port (DHCP snooping, Wi-Fi client isolation or a relay that ignores unknown clients)."' "$file" 2>/dev/null)"
        findings_json="$(append_finding_record_checked "$findings_json" "warning" "DHCP discovery received no offer, but the interface holds a lease" "$detail" "dhcp-scan.json" "$file" 4)"
      else
        findings_json="$(append_finding_record_checked "$findings_json" "warning" "No DHCP responders were observed" "DHCP discovery completed without observing any responder. This may still be normal in some environments, but it should be verified." "dhcp-scan.json" "$file" 4)"
      fi
    fi
  fi

  file="$(task_output_path 5 2>/dev/null || true)"
  if json_file_usable "$file" && [[ "$(jq -r '.status // "success"' "$file" 2>/dev/null)" != "failed" ]]; then
    local dhcp_avg_ms dhcp_loss dhcp_wifi dhcp_inconsistent dhcp_mismatch dhcp_medium
    local dhcp_loss_severity="" dhcp_slow_high dhcp_slow_warn
    dhcp_avg_ms="$(jq -r '.avg_ms // empty' "$file" 2>/dev/null)"
    dhcp_loss="$(jq -r '.packet_loss_percent // 0' "$file" 2>/dev/null)"
    dhcp_wifi="$(jq -r '.is_wifi // false' "$file" 2>/dev/null)"
    dhcp_inconsistent="$(jq -r '.indicators.probe_inconsistent // false' "$file" 2>/dev/null)"
    dhcp_mismatch="$(jq -r '.indicators.server_mismatch // false' "$file" 2>/dev/null)"
    # Loss is graded by medium: a lost broadcast or two is normal radio
    # behaviour on Wi-Fi and never a HIGH finding for the client.
    if [[ "$dhcp_loss" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($dhcp_loss > 0)}"; then
      if [[ "$dhcp_wifi" == "true" ]]; then
        dhcp_medium="Wi-Fi"
        if awk "BEGIN{exit !($dhcp_loss >= 30)}"; then dhcp_loss_severity="high"
        elif awk "BEGIN{exit !($dhcp_loss > 10)}"; then dhcp_loss_severity="warning"; fi
      else
        dhcp_medium="wired"
        if awk "BEGIN{exit !($dhcp_loss >= 20)}"; then dhcp_loss_severity="high"; else dhcp_loss_severity="warning"; fi
      fi
    fi
    if [[ "$dhcp_inconsistent" == "true" ]]; then
      # Discovery saw the server answer a moment ago: the probe path, not
      # the DHCP service, is in question. Never graded high.
      local t4_count
      t4_count="$(jq -r '.dhcp_responders_observed // 0' "$(task_output_path 4 2>/dev/null || true)" 2>/dev/null || echo 0)"
      [[ "$t4_count" =~ ^[0-9]+$ ]] || t4_count="one or more"
      detail="$(jq -r '"The response-time probe (receive path: " + (.receive_method // "unknown") + ", send path: " + (.send_method // "unknown") + ") received no Offer for any of its " + ((.probe_count // 0) | tostring) + " Discover probes, while DHCP discovery observed offers on the same interface moments earlier. Treat this as a probe or receive-path limitation (DHCP snooping, client isolation, a controller that unicasts offers), not as a DHCP outage."' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record_checked "$findings_json" "warning" "Response-time probe received no offer although discovery saw ${t4_count} responder(s)" "$detail" "dhcp-response-time.json" "$file" 5)"
    elif [[ -n "$dhcp_loss_severity" ]]; then
      findings_json="$(append_finding_record_checked "$findings_json" "$dhcp_loss_severity" "DHCP server did not respond to all probes" "Packet loss observed during the DHCP response time test (${dhcp_medium}): ${dhcp_loss}% of Discover packets received no Offer." "dhcp-response-time.json" "$file" 5)"
    fi
    if [[ "$dhcp_mismatch" == "true" ]]; then
      detail="$(jq -r '"Responder(s) " + ((.unexpected_servers // []) | join(", ")) + " answered the response-time probe but were not seen by DHCP discovery (Task 4). A second DHCP server may be active on this network."' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record_checked "$findings_json" "high" "DHCP responder mismatch between discovery and response-time probe" "$detail" "dhcp-response-time.json" "$file" 5)"
    fi
    # Latency thresholds follow the task's own medium-aware grading.
    dhcp_slow_high=500; dhcp_slow_warn=200
    if [[ "$dhcp_wifi" == "true" ]]; then dhcp_slow_high=2000; dhcp_slow_warn=500; fi
    if [[ -n "$dhcp_avg_ms" ]] && awk "BEGIN{exit !($dhcp_avg_ms > $dhcp_slow_high)}"; then
      findings_json="$(append_finding_record_checked "$findings_json" "high" "DHCP response time is critically slow" "Average DHCP Offer latency was ${dhcp_avg_ms} ms. This will cause delays or failures during device boot and network reconnection." "dhcp-response-time.json" "$file" 5)"
    elif [[ -n "$dhcp_avg_ms" ]] && awk "BEGIN{exit !($dhcp_avg_ms > $dhcp_slow_warn)}"; then
      findings_json="$(append_finding_record_checked "$findings_json" "warning" "DHCP response time is elevated" "Average DHCP Offer latency was ${dhcp_avg_ms} ms. Healthy DHCP servers typically respond within 50 ms$(if [[ "$dhcp_wifi" == "true" ]]; then echo "; this was measured over Wi-Fi, which adds latency"; fi)." "dhcp-response-time.json" "$file" 5)"
    fi
  fi

  # Task 10 is multi-entry (gateway-stress-test-device-N.json); older runs may
  # also hold a non-indexed gateway-stress-test.json. Check every file so the
  # stress indicators actually produce findings.
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    json_file_usable "$file" || continue
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
  done < <({ task_output_path 10 2>/dev/null || true; task_json_files 10 2>/dev/null || true; })

  file="$(task_output_path 6 2>/dev/null || true)"
  if json_file_usable "$file"; then
    count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      detail="$(jq -r '"The DNS scan identified " + ((.servers // []) | length | tostring) + " DNS server(s): " + ([.servers[]? | .ip + (if ((.sources // []) | length) > 0 then " [" + ((.sources // []) | join(", ")) + "]" else "" end)] | join(", ")) + "."' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record_checked "$findings_json" "info" "DNS services were detected" "$detail" "dns-scan.json" "$file" 6)"
    fi
    # A resolver the network itself advertises (DHCP offer / system lease)
    # that cannot resolve the advertised domain, or does not answer at all.
    local dns_bad_internal dns_silent
    dns_bad_internal="$(jq -r '[.servers[]? | select(((.sources // []) | any(. == "dhcp-offer" or . == "system-lease")) and .resolution_test.internal_test != null and .resolution_test.internal_test.resolved == false) | .ip + " (" + .resolution_test.internal_test.domain + ")"] | join(", ")' "$file" 2>/dev/null)"
    if [[ -n "$dns_bad_internal" ]]; then
      findings_json="$(append_finding_record_checked "$findings_json" "warning" "DHCP-advertised DNS server cannot resolve the site domain" "The following DHCP-advertised resolver(s) did not resolve the domain the DHCP server advertised: ${dns_bad_internal}. Clients on this network will fail domain joins and internal name lookups." "dns-scan.json" "$file" 6)"
    fi
    dns_silent="$(jq -r '[.servers[]? | select(((.sources // []) | any(. == "dhcp-offer" or . == "system-lease")) and .resolution_test != null and (.resolution_test.any_reply // false) == false) | .ip] | join(", ")' "$file" 2>/dev/null)"
    if [[ -n "$dns_silent" ]]; then
      findings_json="$(append_finding_record_checked "$findings_json" "warning" "DHCP-advertised DNS server did not answer" "DNS server(s) ${dns_silent} are handed out by DHCP but answered none of the test queries from this network. Clients that receive them will have no working name resolution." "dns-scan.json" "$file" 6)"
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

  if jq -e '.findings[]? | select(.source == "dhcp-scan.json" and (.title | test("rogue DHCP|No DHCP responders|holds a lease|responder mismatch|received no offer"; "i")))' "$findings_file" >/dev/null 2>&1; then
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
  local file_details_json path file_name file_sha file_written file_edited

  if [[ -z "$RUN_OUTPUT_DIR" ]]; then
    return 1
  fi

  timestamp="$(date '+%d-%m-%Y %H:%M')"

  # task_result_edited reads the previous manifest (still on disk until the
  # write below) so an "edited" marker, once recorded, is carried forward
  # even though the hashes are refreshed on every write — except for a task
  # the engine re-ran in this session, whose fresh file is measured again.

  for task_id in $(get_task_ids); do
    title="$(task_title "$task_id")"
    json_name="$(task_output_file "$task_id")"
    [[ -z "$json_name" ]] && continue
    raw_prefix="$(task_raw_prefix "$task_id" 2>/dev/null || true)"
    task_files_json="$(task_json_files "$task_id" | while IFS= read -r path; do
      [[ -n "$path" ]] && basename "$path"
    done | jq -R . | jq -s .)"
    [[ -z "$task_files_json" ]] && task_files_json="[]"

    # Per-file integrity record: sha256, mtime, and whether the result was
    # edited after the run (Edit Results stamp, carried-forward marker, or a
    # hash that drifted since the last finalize without the task re-running).
    file_details_json="[]"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      file_name="$(basename "$path")"
      file_sha="$(file_sha256 "$path")"
      file_written="$(file_mtime_iso8601_utc "$path")"
      if task_result_edited "$path" "$task_id"; then
        file_edited=true
      else
        file_edited=false
      fi
      file_details_json="$(jq -cn \
        --argjson existing "$file_details_json" \
        --arg file "$file_name" \
        --arg sha "$file_sha" \
        --arg written "$file_written" \
        --argjson edited "$file_edited" \
        --arg edited_at "$(jq -r '.edited_at? // empty' "$path" 2>/dev/null || true)" \
        '$existing + [{
          file: $file,
          sha256: (if $sha == "" then null else $sha end),
          written_at: (if $written == "" then null else $written end),
          edited: $edited,
          edited_at: (if $edited_at == "" then null else $edited_at end)
        }]')"
    done < <(task_json_files "$task_id")

    task_entries="$(jq -cn \
      --argjson existing "$task_entries" \
      --arg task_id "$task_id" \
      --arg title "$title" \
      --arg json_file "$json_name" \
      --argjson json_present "$(if [[ "$task_files_json" != "[]" ]]; then echo true; else echo false; fi)" \
      --argjson json_files "$task_files_json" \
      --argjson details "$file_details_json" \
      --arg raw_prefix "$(basename "$raw_prefix")" \
      '($details | if length == 1 then .[0] else null end) as $single
       | $existing + [{
        task_id: ($task_id | tonumber),
        title: $title,
        json_file: $json_file,
        json_present: $json_present,
        sha256: ($single.sha256 // null),
        written_at: ($single.written_at // null),
        edited: ($details | any(.edited == true)),
        json_files: $json_files,
        json_file_details: $details,
        raw_prefix: $raw_prefix
      }]' )"
  done

  while IFS= read -r artifact_path; do
    [[ -z "$artifact_path" ]] && continue
    relative_path="${artifact_path#"$RUN_OUTPUT_DIR"/}"

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
    --arg engine_version "$APP_VERSION" \
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
      engine_version: $engine_version,
      tasks: $tasks,
      artifacts: $artifacts
    }' > "$manifest_file"

  validate_json_file "$manifest_file"
}

generate_pdf_report() {
  local py_script="$APP_ROOT/generate_pdf_report.py"
  local pdf_path="${RUN_REPORT_FILE%.txt}.pdf"
  local pdf_out

  # _LSS_PDF_LAST_ERROR lets non-interactive mode report why no PDF appeared;
  # the printed output is unchanged.
  _LSS_PDF_LAST_ERROR=""
  if [[ -z "$RUN_OUTPUT_DIR" ]]; then
    _LSS_PDF_LAST_ERROR="no active run directory"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _LSS_PDF_LAST_ERROR="python3 not found"
    return 0
  fi
  if ! python3 -c "import fpdf" 2>/dev/null; then
    _LSS_PDF_LAST_ERROR="fpdf2 not installed (pip3 install fpdf2)"
    echo "PDF generation skipped: fpdf2 not installed (pip3 install fpdf2)"
    return 0
  fi
  if [[ ! -f "$py_script" ]]; then
    _LSS_PDF_LAST_ERROR="generate_pdf_report.py not found in $APP_ROOT"
    return 0
  fi
  if [[ ! -f "$RUN_MANIFEST_FILE" ]]; then
    _LSS_PDF_LAST_ERROR="manifest.json not found"
    return 0
  fi

  printf "  Generating PDF report...\n"
  local pdf_err
  pdf_err="$(python3 "$py_script" "$RUN_OUTPUT_DIR" "$APP_ROOT" "$pdf_path" "${RUN_PREPARED_BY:-}" 2>&1 >/dev/null || true)"
  if [[ -f "$pdf_path" ]]; then
    printf "  PDF report:    %s\n" "$pdf_path"
  else
    _LSS_PDF_LAST_ERROR="${pdf_err:-PDF generation failed}"
    printf "  PDF generation failed%s\n" "${pdf_err:+: $pdf_err}"
  fi
}

# Set by on_exit_trap so finalize_run can tell a real process exit from an
# explicit mid-session "save this run" call.
_LSS_EXITING=0

finalize_run() {
  if [[ "$NETWORK_INTERRUPTED" != "true" ]]; then
    if [[ -n "$RUN_OUTPUT_DIR" ]] && [[ -d "$RUN_OUTPUT_DIR" ]] && [[ -n "$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]]; then
      build_report_for_current_run || true
    fi
  fi

  if [[ -n "$RUN_OUTPUT_DIR" && -d "$RUN_OUTPUT_DIR" && -n "$SESSION_DEBUG_LOG" && -f "$SESSION_DEBUG_LOG" \
        && "$SESSION_DEBUG_LOG" != "$RUN_DEBUG_LOG" ]]; then
    cp "$SESSION_DEBUG_LOG" "$RUN_DEBUG_LOG" 2>/dev/null || true
  fi

  if [[ -n "$RUN_OUTPUT_DIR" && -d "$RUN_OUTPUT_DIR" ]]; then
    write_manifest_for_current_run || true
  fi

  if [[ "$_LSS_EXITING" -eq 1 ]]; then
    # Real exit: remove the session log and stop anything we started.
    if [[ -n "$SESSION_DEBUG_LOG" && -f "$SESSION_DEBUG_LOG" ]]; then
      rm -f "$SESSION_DEBUG_LOG" 2>/dev/null || true
    fi
    stop_spinner_line 2>/dev/null || true
    kill_registered_bg_pids
    if [[ -n "$CAFFEINATE_PID" ]]; then
      kill "$CAFFEINATE_PID" 2>/dev/null || true
    fi
  elif [[ -n "$SESSION_DEBUG_LOG" && -f "$SESSION_DEBUG_LOG" ]]; then
    # Mid-session save: tee still has this file open, so truncate rather
    # than delete, otherwise later runs in this session get no debug log.
    : > "$SESSION_DEBUG_LOG" 2>/dev/null || true
  fi
}

on_exit_trap() {
  # Capture the exit status first: in non-interactive mode the bye event
  # carries it whenever a code path exited without emitting one itself.
  _lss_exit_rc=$?
  _LSS_EXITING=1
  finalize_run
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    emit_bye "$_lss_exit_rc"
  fi
}

# Ctrl-C / kill: exit through the EXIT trap so cleanup runs. Without this,
# background tcpdump/nmap/spinner processes outlive the script.
on_interrupt() {
  trap - INT TERM
  echo
  exit 130
}

handle_err_exit() {
  # Only act if we're mid-run with a known interface
  if [[ -z "$SELECTED_INTERFACE" ]] || [[ -z "$RUN_OUTPUT_DIR" ]]; then
    return
  fi
  # Check whether the interface has disappeared OR lost its IP address
  # (covers both physical unplug and WiFi/network drop where interface stays up)
  local iface_up=true
  if ! interface_has_valid_ip "$SELECTED_INTERFACE"; then
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
  local ip=""
  [[ -z "$iface" ]] && return 1
  # ifconfig is optional on modern Linux (no net-tools by default), so use
  # iproute2 there; relying on ifconfig made every stress test abort with
  # "interface lost its IP" on Debian/Ubuntu.
  if [[ "$OS" == "linux" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
    ip="${ip%%/*}"
  elif command -v ifconfig >/dev/null 2>&1; then
    if ! ifconfig "$iface" >/dev/null 2>&1; then
      return 1
    fi
    ip="$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
  else
    return 1
  fi
  [[ -z "$ip" ]] && return 1
  [[ "$ip" == 169.254.* ]] && return 1
  return 0
}

warn_if_not_root() {
  if [[ "$EUID" -ne 0 ]]; then
    printf "  Some scans may not work correctly without root privileges.\n"
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
        echo "Missing optional tool: sshpass (Task 19 — UniFi Adoption)"
        echo "Install with: brew install hudochenkov/sshpass/sshpass"
        ;;
      arp-scan)
        echo "Missing optional tool: arp-scan (Task 12 — Duplicate IP Detection)"
        echo "Install with: brew install arp-scan"
        ;;
      *)
        echo "Missing required tool: $tool"
        echo "Install with: brew install $tool"
        ;;
    esac
  else
    echo "Missing required tool: $tool"
    case "$tool" in
      iproute2|iputils-ping|tcpdump|sshpass|arp-scan)
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
  printf "  ${yellow}Startup Check${reset}\n"
  printf "  ${yellow}════════════════════════${reset}\n"
  echo
  printf "  Dependency Checklist:\n"

  for tool in "${base_tools[@]}" "${os_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf "  ${green}[OK]${reset}      %s\n" "$tool"
    else
      printf "  ${red}[MISSING]${reset} %s\n" "$tool"
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
      printf "  ${green}[OK]${reset}      python3-scapy\n"
    else
      printf "  ${red}[MISSING]${reset} python3-scapy\n"
      missing=1
      missing_tools+=("python3-scapy")
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import fpdf" 2>/dev/null; then
      printf "  ${green}[OK]${reset}      python3-fpdf2\n"
    else
      printf "  ${red}[MISSING]${reset} python3-fpdf2\n"
      missing=1
      missing_tools+=("python3-fpdf2")
    fi
  fi

  if [[ "$OS" == "linux" ]] && ! command -v ifconfig >/dev/null 2>&1; then
    printf "  ${yellow}[WARN]${reset}    ifconfig not found (optional fallback — install with: apt install net-tools)\n"
  fi

  if command -v sshpass >/dev/null 2>&1; then
    printf "  ${green}[OK]${reset}      sshpass\n"
  else
    if [[ "$OS" == "macos" ]]; then
      printf "  ${yellow}[WARN]${reset}    sshpass not found — Task 19 unavailable (install with: brew install hudochenkov/sshpass/sshpass)\n"
    else
      printf "  ${yellow}[WARN]${reset}    sshpass not found — Task 19 unavailable (install with: apt install sshpass)\n"
    fi
  fi

  if command -v arp-scan >/dev/null 2>&1; then
    printf "  ${green}[OK]${reset}      arp-scan\n"
  else
    if [[ "$OS" == "macos" ]]; then
      printf "  ${yellow}[WARN]${reset}    arp-scan not found — Task 12 unavailable (install with: brew install arp-scan)\n"
    else
      printf "  ${yellow}[WARN]${reset}    arp-scan not found — Task 12 unavailable (install with: apt install arp-scan)\n"
    fi
  fi

  if [[ "$OS" == "macos" ]]; then
    local airport_bin="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    if [[ -x "$airport_bin" ]]; then
      printf "  ${green}[OK]${reset}      airport (wireless scan)\n"
    elif command -v system_profiler >/dev/null 2>&1; then
      printf "  ${green}[OK]${reset}      system_profiler (wireless scan fallback)\n"
    else
      printf "  ${yellow}[WARN]${reset}    No wireless scan tool available — Task 17 unavailable on this Mac\n"
    fi
  else
    if command -v iw >/dev/null 2>&1; then
      printf "  ${green}[OK]${reset}      iw (wireless scan)\n"
    else
      printf "  ${yellow}[WARN]${reset}    iw not found — Task 17 wireless scan unavailable (install with: apt install iw)\n"
    fi
  fi

  if [[ "$missing" -eq 1 ]]; then
    echo
    printf "  Missing required dependencies:\n"
    for tool in "${missing_tools[@]}"; do
      print_install_hint "$tool"
    done

    # Non-interactive mode: never prompt, never run install.sh.
    if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
      echo
      printf "  Non-interactive mode cannot install dependencies; run install.sh first.\n"
      ni_fail 3 missing_dependencies "Missing required dependencies: ${missing_tools[*]}" \
        "$(json_str_array tools ${missing_tools[@]+"${missing_tools[@]}"})"
    fi

    while true; do
      echo
      read -r -p "  Do you want to install missing dependencies now using install.sh? (y/n): " choice
      case "$choice" in
        y|Y|yes|YES|Yes)
          printf "  Running install.sh to install all required dependencies...\n"
          if ! bash "$SCRIPT_DIR/install.sh"; then
            printf "  install.sh failed. Cannot continue without required dependencies.\n"
            exit 1
          fi

          printf "  Rechecking dependencies after install...\n"
          missing=0
          missing_tools=()
          for tool in "${base_tools[@]}" "${os_tools[@]}"; do
            if command -v "$tool" >/dev/null 2>&1; then
              printf "  ${green}[OK]${reset}      %s\n" "$tool"
            else
              printf "  ${red}[MISSING]${reset} %s\n" "$tool"
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
          # The Python libraries are required too; they were the most likely
          # thing to have failed inside install.sh (pip), so recheck them.
          if command -v python3 >/dev/null 2>&1; then
            if python3 -c "import scapy" 2>/dev/null; then
              printf "  ${green}[OK]${reset}      python3-scapy\n"
            else
              printf "  ${red}[MISSING]${reset} python3-scapy\n"
              missing=1
              missing_tools+=("python3-scapy")
            fi
            if python3 -c "import fpdf" 2>/dev/null; then
              printf "  ${green}[OK]${reset}      python3-fpdf2\n"
            else
              printf "  ${red}[MISSING]${reset} python3-fpdf2\n"
              missing=1
              missing_tools+=("python3-fpdf2")
            fi
          fi

          if [[ "$missing" -eq 0 ]]; then
            printf "  All required dependencies are installed. Continuing...\n"
            return
          fi

          printf "  Dependencies are still missing after install.sh: %s\n" "${missing_tools[*]}"
          printf "  Everything is required to run this program correctly. Exiting.\n"
          exit 1
          ;;
        n|N|no|NO|No)
          printf "  Everything is required to run this program correctly. Exiting.\n"
          exit 1
          ;;
        *)
          printf "  Invalid selection. Enter y or n.\n"
          ;;
      esac
    done
  fi

  if [[ "$missing" -eq 0 ]]; then
    echo
    printf "  ${green}All required dependencies are available.${reset}\n"
  fi
}


list_interfaces() {
  # Loopback is never a valid audit interface (selecting lo0 would make
  # Tasks 6-9 nmap 127.0.0.0/8).
  if [[ "$OS" == "macos" ]]; then
    ifconfig -l | tr ' ' '\n' | sed '/^$/d' | grep -vE '^lo[0-9]*$' || true
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
    # bash 3.2: expanding an empty array under set -u is fatal — guard both.
    ordered_interfaces=(${ipv4_interfaces[@]+"${ipv4_interfaces[@]}"} ${other_interfaces[@]+"${other_interfaces[@]}"})

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
        echo
        if interface_has_ipv4 "$SELECTED_INTERFACE"; then
          printf "  Warning: %s has a self-assigned address (169.254.x.x) — no DHCP lease.\n" "$SELECTED_INTERFACE"
          printf "  The interface is up but has no routable IP. Check your cable or DHCP server.\n"
        else
          printf "  Warning: %s does not currently have an IPv4 address.\n" "$SELECTED_INTERFACE"
          printf "  Interface info and network-range scans may fail on bridge/physical-only interfaces.\n"
          printf "  On Proxmox or Debian bridge hosts, you may want a bridge interface such as vmbr0 instead.\n"
        fi
        echo
      fi
      return
    fi

    printf "  Invalid selection. Try again.\n"
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
      if [[ "$ip_cidr" == */* ]]; then
        prefix="${ip_cidr#*/}"
      else
        # Point-to-point links (WireGuard/PPP) print "inet A peer B/NN" — the
        # prefix belongs to the peer token; treat the local address as /32.
        prefix="32"
      fi
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
    local joined="" e
    for e in "${entries[@]}"; do
      joined="${joined:+$joined, }$e"
    done
    printf '%s' "$joined"
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
  local gw=""
  if [[ "$OS" == "macos" ]]; then
    # Scope the lookup to the interface: on a multi-homed Mac (Wi-Fi up, USB
    # dongle selected) the unscoped default route belongs to another NIC and
    # every gateway-based task would target the wrong device.
    if [[ -n "$iface" ]]; then
      gw="$(route -n get -ifscope "$iface" default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
    fi
    if [[ -z "$gw" ]]; then
      # Fall back to the global default only if it actually uses this interface.
      local def_iface
      def_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
      if [[ -z "$iface" || "$def_iface" == "$iface" ]]; then
        gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
      fi
    fi
  else
    if [[ -n "$iface" ]]; then
      gw="$(ip route show default dev "$iface" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
    else
      gw="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
    fi
  fi
  # Only ever return a dotted IPv4 address (route can print "link#N").
  [[ "$gw" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || gw=""
  echo "$gw"
}

# "Private" for our purposes = not publicly routable: RFC 1918, CGNAT
# (100.64/10, common behind 4G/Starlink modems) and link-local.
is_rfc1918_ip() {
  local ip="$1"
  local a b c
  # route(8) can print "link#20" for some VPN/PPP default routes; a non-dotted
  # value must not reach the arithmetic tests below.
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c _ <<< "$ip"
  [[ "$a" -eq 10 ]] && return 0
  [[ "$a" -eq 172 && "$b" -ge 16 && "$b" -le 31 ]] && return 0
  [[ "$a" -eq 192 && "$b" -eq 168 ]] && return 0
  [[ "$a" -eq 100 && "$b" -ge 64 && "$b" -le 127 ]] && return 0
  [[ "$a" -eq 169 && "$b" -eq 254 ]] && return 0
  return 1
}

# Lower-case a MAC and zero-pad each octet. macOS `arp` prints 8:bf:b8:47:f:e0
# for 08:bf:b8:47:0f:e0, which breaks OUI matching and regexes expecting two
# hex digits per octet. Accepts ":" or "-" separators; prints "" if not a MAC.
normalize_mac() {
  local raw="$1"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '-' ':' | awk -F: '
    NF == 6 {
      ok = 1
      for (i = 1; i <= 6; i++) if ($i !~ /^[0-9a-f][0-9a-f]?$/) ok = 0
      if (!ok) exit
      for (i = 1; i <= 6; i++) printf "%s%s", (length($i) == 1 ? "0" $i : $i), (i < 6 ? ":" : "")
    }'
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

# ── Shared DHCP/DNS helpers (v1.2.252) ─────────────────────────────────────

# Lower-case, zero-padded MAC of an interface ("" when unknown). Used as the
# chaddr/frame source of every DHCP probe: switches with DHCP snooping
# (verify mac-address) and Wi-Fi controllers drop a DISCOVER whose chaddr is
# not the sender's MAC, and nmap's default DE:AD:C0:DE:CA:FE is on IPS lists.
interface_mac() {
  local iface="$1"
  local details="" mac=""
  [[ -z "$iface" ]] && return 0
  details="$(get_interface_details "$iface" 2>/dev/null || true)"
  IFS='|' read -r _ _ _ mac _ <<< "$details"
  printf '%s\n' "$(normalize_mac "$mac")"
}

iso8601_utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# File modification time as ISO-8601 UTC ("" when the file is missing).
file_mtime_iso8601_utc() {
  local file="$1" epoch=""
  [[ -f "$file" ]] || return 0
  # GNU stat first: on Linux `stat -f` means filesystem status.
  epoch="$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 0
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || true
}

# SHA-256 of a file ("" when no tool or no file). shasum ships with macOS,
# sha256sum with coreutils.
file_sha256() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1; exit}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1; exit}'
  fi
}

# Print only the dotted IPv4 tokens of a string, one per line, in order.
_extract_ipv4_tokens() {
  printf '%s\n' "$1" | tr ',{}' '   ' | tr -s ' ' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
}

# The lease the operating system itself obtained on <iface>. Prints one JSON
# object {server, assigned_ip, router, dns, domain, lease_time_seconds,
# obtained_at, source} or "null" (static address, no lease, unknown OS tool).
# This is the one DHCP evidence that survives probe filtering: the server
# that answered the audit laptop a few minutes ago.
system_dhcp_lease() {
  local iface="$1"
  local server="" assigned="" router="" domain="" lease_seconds="" obtained_at="" source=""
  local dns_list=()
  local packet="" line="" value="" ip

  [[ -z "$iface" ]] && { echo null; return 0; }

  if [[ "$OS" == "macos" ]]; then
    packet="$(ipconfig getpacket "$iface" 2>/dev/null || true)"
    if [[ -n "$packet" ]]; then
      source="ipconfig"
      server="$(printf '%s\n' "$packet" | awk -F': ' '/^server_identifier \(ip\):/{print $2; exit}')"
      assigned="$(printf '%s\n' "$packet" | awk -F' = ' '/^yiaddr = /{print $2; exit}')"
      value="$(printf '%s\n' "$packet" | awk -F': ' '/^router \(ip_mult\):/{print $2; exit}')"
      router="$(_extract_ipv4_tokens "$value" | head -1)"
      value="$(printf '%s\n' "$packet" | awk -F': ' '/^domain_name_server \(ip_mult\):/{print $2; exit}')"
      while IFS= read -r ip; do
        [[ -n "$ip" ]] && dns_list+=("$ip")
      done < <(_extract_ipv4_tokens "$value")
      domain="$(printf '%s\n' "$packet" | awk -F': ' '/^domain_name \(string\):/{print $2; exit}')"
      value="$(printf '%s\n' "$packet" | awk -F': ' '/^lease_time \(uint32\):/{print $2; exit}')"
      if [[ "$value" =~ ^0x[0-9a-fA-F]+$ ]]; then
        lease_seconds="$((16#${value#0x}))"
      elif [[ "$value" =~ ^[0-9]+$ ]]; then
        lease_seconds="$value"
      fi
      value="$(ipconfig getsummary "$iface" 2>/dev/null | awk -F' : ' '/LeaseStartTime/{print $2; exit}' || true)"
      if [[ -n "$value" ]]; then
        obtained_at="$(date -j -f '%m/%d/%Y %H:%M:%S' "$value" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)"
        [[ -z "$obtained_at" ]] && obtained_at="$value"
      fi
    fi
  else
    # 1. NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
      packet="$(nmcli -g DHCP4.OPTION device show "$iface" 2>/dev/null | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
      if printf '%s\n' "$packet" | grep -q 'dhcp_server_identifier'; then
        source="nmcli"
        server="$(printf '%s\n' "$packet" | awk -F' = ' '/dhcp_server_identifier = /{gsub(/^[[:space:]]+/, "", $2); print $2; exit}')"
        assigned="$(printf '%s\n' "$packet" | awk -F' = ' '/^[[:space:]]*ip_address = /{print $2; exit}')"
        value="$(printf '%s\n' "$packet" | awk -F' = ' '/^[[:space:]]*routers = /{print $2; exit}')"
        router="$(_extract_ipv4_tokens "$value" | head -1)"
        value="$(printf '%s\n' "$packet" | awk -F' = ' '/^[[:space:]]*domain_name_servers = /{print $2; exit}')"
        while IFS= read -r ip; do
          [[ -n "$ip" ]] && dns_list+=("$ip")
        done < <(_extract_ipv4_tokens "$value")
        domain="$(printf '%s\n' "$packet" | awk -F' = ' '/^[[:space:]]*domain_name = /{print $2; exit}')"
        value="$(printf '%s\n' "$packet" | awk -F' = ' '/^[[:space:]]*dhcp_lease_time = /{print $2; exit}')"
        [[ "$value" =~ ^[0-9]+$ ]] && lease_seconds="$value"
      fi
    fi
    # 2. systemd-networkd
    if [[ -z "$server" && -r "/sys/class/net/$iface/ifindex" ]]; then
      value="$(cat "/sys/class/net/$iface/ifindex" 2>/dev/null || true)"
      if [[ "$value" =~ ^[0-9]+$ && -r "/run/systemd/netif/leases/$value" ]]; then
        packet="$(cat "/run/systemd/netif/leases/$value" 2>/dev/null || true)"
        server="$(printf '%s\n' "$packet" | awk -F= '/^SERVER_ADDRESS=/{print $2; exit}')"
        if [[ -n "$server" ]]; then
          source="systemd-networkd"
          assigned="$(printf '%s\n' "$packet" | awk -F= '/^ADDRESS=/{print $2; exit}')"
          router="$(_extract_ipv4_tokens "$(printf '%s\n' "$packet" | awk -F= '/^ROUTER=/{print $2; exit}')" | head -1)"
          while IFS= read -r ip; do
            [[ -n "$ip" ]] && dns_list+=("$ip")
          done < <(_extract_ipv4_tokens "$(printf '%s\n' "$packet" | awk -F= '/^DNS=/{print $2; exit}')")
          domain="$(printf '%s\n' "$packet" | awk -F= '/^DOMAINNAME=/{print $2; exit}')"
          value="$(printf '%s\n' "$packet" | awk -F= '/^LIFETIME=/{print $2; exit}')"
          [[ "$value" =~ ^[0-9]+$ ]] && lease_seconds="$value"
        fi
      fi
    fi
    # 3. dhclient lease files: newest "lease { interface "<iface>" ... }" block.
    if [[ -z "$server" ]]; then
      local lease_file
      for lease_file in /var/lib/dhcp/dhclient*.leases /var/lib/dhclient/*.leases /var/lib/NetworkManager/*.lease; do
        [[ -r "$lease_file" ]] || continue
        packet="$(awk -v iface="$iface" '
          /^lease[[:space:]]*\{/ { block = ""; inblock = 1; keep = 0; next }
          inblock && /^[[:space:]]*interface[[:space:]]+"/ { if (index($0, "\"" iface "\"")) keep = 1 }
          inblock && /^\}/ { if (keep) last = block; inblock = 0; next }
          inblock { block = block $0 "\n" }
          END { printf "%s", last }
        ' "$lease_file" 2>/dev/null || true)"
        [[ -z "$packet" ]] && continue
        server="$(printf '%s\n' "$packet" | awk '/option dhcp-server-identifier/{v=$NF; sub(/;$/, "", v); print v; exit}')"
        [[ -z "$server" ]] && continue
        source="dhclient"
        assigned="$(printf '%s\n' "$packet" | awk '/fixed-address/{v=$NF; sub(/;$/, "", v); print v; exit}')"
        router="$(_extract_ipv4_tokens "$(printf '%s\n' "$packet" | awk '/option routers/{sub(/^[[:space:]]*option routers[[:space:]]*/, ""); sub(/;$/, ""); print; exit}')" | head -1)"
        while IFS= read -r ip; do
          [[ -n "$ip" ]] && dns_list+=("$ip")
        done < <(_extract_ipv4_tokens "$(printf '%s\n' "$packet" | awk '/option domain-name-servers/{sub(/^[[:space:]]*option domain-name-servers[[:space:]]*/, ""); sub(/;$/, ""); print; exit}')")
        domain="$(printf '%s\n' "$packet" | awk '/option domain-name /{sub(/^[[:space:]]*option domain-name[[:space:]]*/, ""); sub(/;$/, ""); gsub(/"/, ""); print; exit}')"
        value="$(printf '%s\n' "$packet" | awk '/option dhcp-lease-time/{v=$NF; sub(/;$/, "", v); print v; exit}')"
        [[ "$value" =~ ^[0-9]+$ ]] && lease_seconds="$value"
        break
      done
    fi
  fi

  if [[ ! "$server" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo null
    return 0
  fi
  [[ "$assigned" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || assigned=""
  [[ "$router" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || router=""
  domain="$(printf '%s' "$domain" | tr -d '"\\' | sed 's/\\x00//g; s/[^A-Za-z0-9.-]//g; s/\.$//')"

  jq -n \
    --arg server "$server" \
    --arg assigned "$assigned" \
    --arg router "$router" \
    --argjson dns "$(json_string_array_from_array dns_list)" \
    --arg domain "$domain" \
    --arg lease "$lease_seconds" \
    --arg obtained "$obtained_at" \
    --arg source "$source" \
    '{
      server: $server,
      assigned_ip: (if $assigned == "" then null else $assigned end),
      router: (if $router == "" then null else $router end),
      dns: $dns,
      domain: (if $domain == "" then null else $domain end),
      lease_time_seconds: (if $lease == "" then null else ($lease | tonumber) end),
      obtained_at: (if $obtained == "" then null else $obtained end),
      source: $source
    }' 2>/dev/null || echo null
}

# The DNS servers the OS has configured for <iface>: dotted IPv4, one per
# line, deduplicated. macOS: the DHCP-supplied option plus the scoped
# resolver of that interface in `scutil --dns` (mDNS and *.local entries are
# skipped). Linux: resolvectl → nmcli → /etc/resolv.conf (stub resolvers
# 127.0.0.53 / 127.0.0.1 skipped).
configured_dns_servers() {
  local iface="$1"
  local raw=""
  [[ -z "$iface" ]] && return 0

  if [[ "$OS" == "macos" ]]; then
    raw="$(ipconfig getoption "$iface" domain_name_server 2>/dev/null || true)"$'\n'
    raw+="$(scutil --dns 2>/dev/null | awk -v iface="$iface" '
      /^resolver #/ { if (match_iface && !mdns && !local_domain) print servers; servers = ""; match_iface = 0; mdns = 0; local_domain = 0; next }
      /nameserver\[[0-9]+\] :/ { servers = servers " " $NF }
      /options[[:space:]]*:.*mdns/ { mdns = 1 }
      /domain[[:space:]]*:[[:space:]]*local$/ { local_domain = 1 }
      /if_index[[:space:]]*:/ { if (index($0, "(" iface ")")) match_iface = 1 }
      END { if (match_iface && !mdns && !local_domain) print servers }
    ' || true)"
  else
    if command -v resolvectl >/dev/null 2>&1; then
      raw="$(resolvectl dns "$iface" 2>/dev/null | sed 's/^[^:]*://' || true)"
    fi
    if [[ -z "$(_extract_ipv4_tokens "$raw")" ]] && command -v nmcli >/dev/null 2>&1; then
      raw="$(nmcli -g IP4.DNS device show "$iface" 2>/dev/null | tr '|' ' ' || true)"
    fi
    if [[ -z "$(_extract_ipv4_tokens "$raw")" && -r /etc/resolv.conf ]]; then
      raw="$(awk '/^nameserver[[:space:]]/{print $2}' /etc/resolv.conf 2>/dev/null || true)"
    fi
  fi

  _extract_ipv4_tokens "$raw" | grep -vE '^(127\.|0\.0\.0\.0$)' | awk '!seen[$0]++' || true
}

# Parse the verbose (-v -e) or plain tcpdump text of a DHCP capture. Prints
# "|"-separated records (a TAB would be collapsed by a whitespace IFS when
# the MAC is empty):
#   reply_source <ip> <mac>      — a sender from UDP/67 (mac "" in plain captures)
#   relay_agent <ip>             — non-zero Gateway-IP (giaddr), or a UDP/67
#                                  sender that is not a Server-ID (only when
#                                  the capture carried Server-IDs at all)
#   passive_server <ip>          — Server-ID of any Offer/ACK
#   msgtype <Discover|Offer|Request|ACK|NAK|other> <count>
extract_dhcp_capture_summary() {
  local file="$1"
  [[ -s "$file" ]] || return 0

  awk '
    function flush() {
      if (src != "" && sport == "67") {
        key = src "\t" mac
        if (!(key in reply_seen)) { reply_seen[key] = 1; reply_order[++nr] = key }
        reply_ips[src] = 1
      }
      if (giaddr != "" && giaddr != "0.0.0.0" && !(giaddr in relay)) { relay[giaddr] = 1; relay_order[++nrelay] = giaddr }
      if (sid != "" && (mtype == "Offer" || mtype == "ACK") && !(sid in passive)) { passive[sid] = 1; passive_order[++np] = sid }
      if (sid != "") sids[sid] = 1
      if (mtype != "") counts[mtype]++
      src = ""; sport = ""; mac = ""; giaddr = ""; sid = ""; mtype = ""
    }
    function take_flow(line,   tok, n, parts, i, ipaddr) {
      if (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ > /)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/ > $/, "", tok)
        n = split(tok, parts, ".")
        if (n == 5) {
          src = parts[1] "." parts[2] "." parts[3] "." parts[4]
          sport = parts[5]
        }
      }
    }
    /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
      flush()
      if ($2 ~ /^[0-9a-fA-F][0-9a-fA-F]?(:[0-9a-fA-F][0-9a-fA-F]?)+$/ && $3 == ">") mac = tolower($2)
      take_flow($0)
      next
    }
    /^[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ > / { take_flow($0); next }
    /Gateway-IP [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
      if (match($0, /Gateway-IP [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) giaddr = substr($0, RSTART + 11, RLENGTH - 11)
      next
    }
    /Server-ID \(54\), length 4: / {
      if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) sid = substr($0, RSTART, RLENGTH)
      next
    }
    /DHCP-Message \(53\), length 1: / {
      t = $0; sub(/^.*length 1: /, "", t); gsub(/[[:space:]]/, "", t)
      if (t == "NACK") t = "NAK"
      if (t != "Discover" && t != "Offer" && t != "Request" && t != "ACK" && t != "NAK") t = "other"
      mtype = t
      next
    }
    END {
      flush()
      for (i = 1; i <= nr; i++) { split(reply_order[i], kv, "\t"); printf "reply_source|%s|%s\n", kv[1], kv[2] }
      for (i = 1; i <= nrelay; i++) printf "relay_agent|%s\n", relay_order[i]
      # A UDP/67 sender that never appeared as a Server-ID forwarded someone
      # else'"'"'s offer. Only meaningful when the capture carried Server-IDs
      # (verbose mode); a plain capture would call every server a relay.
      has_sid = 0; for (s in sids) has_sid = 1
      if (has_sid) for (i = 1; i <= nr; i++) {
        split(reply_order[i], kv, "\t")
        if (!(kv[1] in sids) && !(kv[1] in relay)) { relay[kv[1]] = 1; printf "relay_agent|%s\n", kv[1] }
      }
      for (i = 1; i <= np; i++) printf "passive_server|%s\n", passive_order[i]
      for (t in counts) printf "msgtype|%s|%d\n", t, counts[t]
    }
  ' "$file"
}

# ── Result integrity marker ───────────────────────────────────────────────
# run_task_by_id records "|<run dir>/<task id>|" here so a result rewritten
# by the engine in this session is never mistaken for a hand edit.
_LSS_TASKS_RUN_IN_SESSION=""

# task_result_edited <json file> <task id> → 0 when the result was changed
# after the run: .edited_at stamped by Edit Results, the manifest already
# says so, or the file's SHA-256 differs from the one recorded at the last
# finalize and the task was not re-run in this session.
task_result_edited() {
  local file="$1"
  local task_id="${2:-}"
  local manifest_file run_dir name recorded current

  [[ -f "$file" ]] || return 1
  if jq -e '.edited_at? | strings' "$file" >/dev/null 2>&1; then
    return 0
  fi
  run_dir="$(dirname "$file")"
  # A task the engine re-ran in this session wrote a fresh, measured file:
  # neither a marker carried in the previous manifest nor a hash drift
  # applies to it (only its own edited_at stamp would).
  if [[ -n "$task_id" && "$_LSS_TASKS_RUN_IN_SESSION" == *"|$run_dir/$task_id|"* ]]; then
    return 1
  fi
  # Always the manifest next to the file: RUN_MANIFEST_FILE can still point
  # at another run (Manage Previous Runs after a run in the same session),
  # whose records share the same file names.
  manifest_file="$run_dir/manifest.json"
  json_file_usable "$manifest_file" || return 1
  name="$(basename "$file")"
  if jq -e --arg f "$name" '[.tasks[]? | (.json_file_details // [])[] | select(.file == $f and .edited == true)] | length > 0' "$manifest_file" >/dev/null 2>&1; then
    return 0
  fi
  recorded="$(jq -r --arg f "$name" '[.tasks[]? | (.json_file_details // [])[] | select(.file == $f) | .sha256 // empty] | first // empty' "$manifest_file" 2>/dev/null || true)"
  [[ -z "$recorded" ]] && return 1
  current="$(file_sha256 "$file")"
  [[ -n "$current" && "$current" != "$recorded" ]]
}

# Severity cap for findings derived from an edited result: never above
# "warning", and the detail says so.
append_finding_record_checked() {
  local current_json="$1" severity="$2" title="$3" detail="$4" source="$5"
  local file="${6:-}" task_id="${7:-}"
  if [[ -n "$file" ]] && task_result_edited "$file" "$task_id"; then
    [[ "$severity" == "high" ]] && severity="warning"
    detail="${detail} (result was edited after the run)"
  fi
  append_finding_record "$current_json" "$severity" "$title" "$detail" "$source"
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

# One "|"-separated record per "Response N of M:" block (a TAB would be
# collapsed by a whitespace IFS when a field is empty) of nmap's
# broadcast-dhcp-discover output:
#   server_id  offered_ip  message_type  router  subnet_mask  dns(comma list)  domain  lease_time_seconds
# Field spellings follow nselib/dhcp.lua ("Server Identifier", "IP Offered",
# "DHCP Message Type", "Router", "Subnet Mask", "Domain Name Server",
# "Domain Name", "IP Address Lease Time"); the lease time is printed by
# datetime.format_time as e.g. "1d00h00m00s" / "8h00m00s" / "45s".
extract_dhcp_offer_records() {
  local file="$1"

  awk '
    function flush() {
      if (inblock) printf "%s|%s|%s|%s|%s|%s|%s|%s\n", sid, yip, mtype, router, mask, dns, domain, lease
      sid = ""; yip = ""; mtype = ""; router = ""; mask = ""; dns = ""; domain = ""; lease = ""
      inblock = 0
    }
    function value_after(line, key,   i, v) {
      i = index(line, key)
      if (i == 0) return ""
      v = substr(line, i + length(key))
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      return v
    }
    function first_ip(s,   n, a, i) {
      n = split(s, a, /[ ,]+/)
      for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+(\.[0-9]+){3}$/) return a[i]
      return ""
    }
    function all_ips(s,   n, a, i, out) {
      n = split(s, a, /[ ,]+/)
      out = ""
      for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+(\.[0-9]+){3}$/) out = out (out == "" ? "" : ",") a[i]
      return out
    }
    function duration_seconds(s,   total, tok, unit, num, t) {
      if (s ~ /^[0-9]+$/) return s + 0
      total = 0
      if (s ~ /^([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+(\.[0-9]+)?s)?$/ && s != "") {
        while (match(s, /^[0-9]+(\.[0-9]+)?[dhms]/)) {
          tok = substr(s, 1, RLENGTH)
          s = substr(s, RLENGTH + 1)
          unit = substr(tok, length(tok))
          num = substr(tok, 1, length(tok) - 1) + 0
          if (unit == "d") total += num * 86400
          else if (unit == "h") total += num * 3600
          else if (unit == "m") total += num * 60
          else total += num
        }
        return int(total)
      }
      # Older nmap: "1 day, 2:03:04" or "2:03:04"
      if (match(s, /[0-9]+ days?/)) { tok = substr(s, RSTART, RLENGTH); sub(/ .*/, "", tok); total += tok * 86400 }
      if (match(s, /[0-9]+:[0-9]+:[0-9]+/)) { split(substr(s, RSTART, RLENGTH), t, ":"); total += t[1] * 3600 + t[2] * 60 + t[3] }
      if (total > 0) return int(total)
      return ""
    }
    /Response [0-9]+ of [0-9]+:/ { flush(); inblock = 1; next }
    !inblock { next }
    /Server Identifier:/        { sid = first_ip(value_after($0, "Server Identifier:")); next }
    /IP Offered:/               { yip = first_ip(value_after($0, "IP Offered:")); next }
    /DHCP Message Type:/        { mtype = value_after($0, "DHCP Message Type:"); gsub(/[^A-Za-z]/, "", mtype); next }
    /Router:/                   { router = first_ip(value_after($0, "Router:")); next }
    /Subnet Mask:/              { mask = first_ip(value_after($0, "Subnet Mask:")); next }
    /Domain Name Server:/       { dns = all_ips(value_after($0, "Domain Name Server:")); next }
    /Domain Name:/              { domain = value_after($0, "Domain Name:"); gsub(/\\x00/, "", domain); gsub(/[^A-Za-z0-9.-]/, "", domain); sub(/\.$/, "", domain); next }
    /IP Address Lease Time:/    { lease = duration_seconds(value_after($0, "IP Address Lease Time:")); next }
    END { flush() }
  ' "$file"
}

capture_dhcp_traffic() {
  local iface="$1"
  local output_file="$2"

  DHCP_CAPTURE_PID=""
  if ! command -v tcpdump >/dev/null 2>&1 || [[ "$EUID" -ne 0 ]]; then
    return 1
  fi

  # Started directly in the caller's shell (not inside $(...)) so the PID is a
  # real child that can be waited on and killed. -Z root keeps Debian/Ubuntu
  # tcpdump from dropping privileges before it opens the root-owned file.
  # -v -e: the verbose decode carries Gateway-IP (giaddr), Server-ID and the
  # message type, and -e the sender MAC — what tells a relay agent from a
  # server and names the responder for Task 20.
  tcpdump -ni "$iface" -l -v -e -Z root 'udp and (port 67 or port 68)' > "$output_file" 2>/dev/null &
  DHCP_CAPTURE_PID=$!
  register_bg_pid "$DHCP_CAPTURE_PID"
  # Give it a moment and confirm it is still alive; a BPF/permission failure
  # exits immediately and must not be reported as "capture used".
  sleep 1
  if ! kill -0 "$DHCP_CAPTURE_PID" 2>/dev/null; then
    unregister_bg_pid "$DHCP_CAPTURE_PID"
    DHCP_CAPTURE_PID=""
    return 1
  fi
  return 0
}

stop_dhcp_capture() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  unregister_bg_pid "$pid"
  return 0
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

  # With -v nmap prints ~5 NSE header lines and each response block is ~13
  # lines: start at the script results so a third responder's offer still
  # fits, cap at 80 lines; without results keep the first 40 lines.
  awk '
    !started && (/^Pre-scan script results:/ || /^\| ?broadcast-dhcp-discover/) {
      started = 1
    }
    started {
      if (printed < 80) {
        print
        printed++
      }
      next
    }
    buffered < 40 {
      buf[++buffered] = $0
    }
    END {
      if (!started) {
        for (i = 1; i <= buffered; i++) print buf[i]
      }
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

  # No open ports at all (hardened appliance, firewalled host, or port scan
  # failed/timed out). Expanding an empty array below would be fatal on
  # bash 3.2, and "unknown" is the honest classification anyway.
  if [[ "${#ports[@]}" -eq 0 ]]; then
    echo "unknown"
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
  # Optional (defaults keep Tasks 7/8/9 byte-identical): host-discovery
  # flags, UDP ports to scan alongside the TCP list, and the widest prefix
  # swept before the range is capped to the /<max_prefix> around the
  # interface address.
  local discovery_flags="${5:-}"
  local udp_ports="${6:-}"
  local max_prefix="${7:-}"
  local network
  local scan_network
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
  local scan_ports_label="$port_list"
  local range_truncated=false
  local scan_rc=0
  local -a nmap_cmd
  local want_udp=0
  # The DNS caller (udp_ports set) gets sources/on_subnet/transport on every
  # entry, also when UDP could not be scanned (udp "unknown" then).
  local dns_shape=0
  [[ -n "$udp_ports" ]] && dns_shape=1

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

  scan_network="$network"
  if [[ -n "$max_prefix" && "${network##*/}" =~ ^[0-9]+$ && "${network##*/}" -lt "$max_prefix" ]]; then
    local iface_ip=""
    IFS='|' read -r iface_ip _ _ _ _ <<< "$(get_interface_details "$SELECTED_INTERFACE")"
    if [[ -n "$iface_ip" ]]; then
      scan_network="$(calculate_network "$iface_ip" "$max_prefix")"
      range_truncated=true
      warnings+=("The interface network $network is wider than /$max_prefix; only $scan_network (around the interface address) was scanned.")
    fi
  fi

  echo "Done."
  echo "Network Range: $network"
  if [[ "$range_truncated" == "true" ]]; then
    echo "Scanned Range: $scan_network (capped to /$max_prefix)"
  fi
  echo
  echo "Stage 2: Scanning $description ports ($port_list)..."
  # Stage events only for the DNS caller: Tasks 7/8/9 stay byte-identical.
  [[ -n "$udp_ports" ]] && emit_stage 6 subnet_scan "Scanning $description ports on $scan_network"

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

  if [[ -n "$udp_ports" ]]; then
    if [[ "$EUID" -eq 0 ]]; then
      # shellcheck disable=SC2206
      nmap_cmd=(nmap -n $discovery_flags -sS -sU -p "T:${port_list},U:${udp_ports}" --open "$scan_network" -oG -)
      scan_ports_label="T:${port_list},U:${udp_ports}"
      want_udp=1
    else
      nmap_cmd=(nmap -n -p "$port_list" --open "$scan_network" -oG -)
      warnings+=("UDP/${udp_ports} and ICMP host discovery need root; only TCP ${port_list} was scanned.")
    fi
  else
    nmap_cmd=(nmap -n -p "$port_list" --open "$scan_network" -oG -)
  fi
  "${nmap_cmd[@]}" > "$scan_file" 2>/dev/null &
  local scan_pid=$!
  monitor_nmap_progress "$scan_pid" "$scan_file" 300 "host_ports" "Matches Found:" "Port scan failed for network $scan_network." && scan_rc=0 || scan_rc=$?
  if [[ "$scan_rc" -eq 124 ]]; then
    # Timed out: keep what nmap streamed so far instead of discarding it.
    warnings+=("The ${description} scan timed out after 300 s; results are partial.")
    status="completed_with_warnings"
    echo "Warning: the scan timed out after 300 s; results below are partial."
  elif [[ "$scan_rc" -ne 0 ]]; then
    jq -n \
      --arg status "failed" \
      --argjson success false \
      --arg error_code "network_port_scan_failed" \
      --arg error_message "The network port scan did not complete successfully." \
      --arg network "$network" \
      --arg scan_ports "$scan_ports_label" \
      --argjson warnings '[]' \
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, network: $network, scan_ports: $scan_ports, servers: []}' > "$(current_output_dir)/$output_file"
    validate_json_file "$(current_output_dir)/$output_file"
    rm -f "$scan_file"
    return 1
  fi

  copy_raw_artifact "$scan_file" "$raw_file"

  json_file="$(current_output_dir)/$output_file"
  warnings_json='[]'
  jq -n \
    --arg status "$status" \
    --argjson success true \
    --argjson warnings "$warnings_json" \
    --arg network "$network" \
    --arg scan_ports "$scan_ports_label" \
    '{status: $status, success: $success, error: null, warnings: $warnings, network: $network, scan_ports: $scan_ports, servers: []}' > "$json_file"
  if [[ -n "$udp_ports" ]]; then
    jq --arg scanned "$scan_network" --argjson truncated "$range_truncated" \
      '. + {scanned_range: $scanned, range_truncated: $truncated}' "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
  fi

  while IFS='|' read -r host_ip open_ports udp_states; do
    local ports_array=()
    local service_names=()
    local port
    local i
    local udp_state="closed"
    local tcp_state="closed"
    [[ "$dns_shape" -eq 1 && "$want_udp" -eq 0 ]] && udp_state="unknown"

    if [[ -n "$open_ports" ]]; then
      while IFS= read -r port; do
        [[ -n "$port" ]] && ports_array+=("$port")
      done < <(echo "$open_ports" | tr ',' '\n' | sed '/^$/d')
    fi
    if [[ "$want_udp" -eq 1 && -n "${udp_states:-}" ]]; then
      # "53:open" or "53:open|filtered" — the first UDP port's state.
      udp_state="${udp_states#*:}"
      udp_state="${udp_state%%,*}"
    fi

    if [[ "${#ports_array[@]}" -eq 0 && ( "$want_udp" -eq 0 || "$udp_state" == "closed" ) ]]; then
      continue
    fi
    [[ "${#ports_array[@]}" -gt 0 ]] && tcp_state="open"

    for i in ${ports_array[@]+"${!ports_array[@]}"}; do
      service_names+=("$(label_port_service "${ports_array[$i]}")")
    done

    if [[ "$dns_shape" -eq 1 ]]; then
      jq \
        --arg ip "$host_ip" \
        --argjson open_ports "$(ports_to_json_array ${ports_array[@]+"${ports_array[@]}"})" \
        --argjson detected_services "$(json_string_array_from_array service_names)" \
        --arg tcp "$tcp_state" \
        --arg udp "$udp_state" \
        '.servers += [{ip: $ip, open_ports: $open_ports, detected_services: $detected_services, sources: ["subnet-scan"], on_subnet: true, transport: {tcp: $tcp, udp: $udp}}]' \
        "$json_file" > "$json_file.tmp"
    else
      jq \
        --arg ip "$host_ip" \
        --argjson open_ports "$(ports_to_json_array "${ports_array[@]}")" \
        --argjson detected_services "$(printf '%s\n' "${service_names[@]}" | jq -R . | jq -s .)" \
        '.servers += [{ip: $ip, open_ports: $open_ports, detected_services: $detected_services}]' \
        "$json_file" > "$json_file.tmp"
    fi
    mv "$json_file.tmp" "$json_file"

    echo "Server: $host_ip"
    if [[ "$dns_shape" -eq 1 ]]; then
      echo "Open Ports: ${ports_array[*]:-none (TCP)}"
      echo "Transport: tcp=${tcp_state} udp=${udp_state}"
      echo "Detected Services: ${service_names[*]:-none confirmed}"
    else
      echo "Open Ports: ${ports_array[*]}"
      echo "Detected Services: ${service_names[*]}"
    fi
    echo

    result_count=$((result_count + 1))
  done < <(awk -v want_udp="$want_udp" '
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
      udp = ""
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", p[i])
        split(p[i], f, "/")
        if (f[1] !~ /^[0-9]+$/) {
          continue
        }
        if (want_udp && f[3] == "udp") {
          if (f[2] == "open" || f[2] == "open|filtered") {
            if (udp != "") {
              udp = udp ","
            }
            udp = udp f[1] ":" f[2]
          }
          continue
        }
        if (f[2] == "open") {
          if (open != "") {
            open = open ","
          }
          open = open f[1]
        }
      }

      if (open != "" || udp != "") {
        print ip "|" open "|" udp
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
  local site_domain="${2:-}"
  local dns_ips=()
  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && dns_ips+=("$ip")
  done < <(jq -r '.servers[]?.ip // empty' "$json_file" 2>/dev/null)

  [[ "${#dns_ips[@]}" -eq 0 ]] && return 0

  local bold='\033[1m'
  local green='\033[0;32m'
  local red='\033[0;31m'
  local yellow='\033[1;33m'
  local reset='\033[0m'

  # Get gateway IP for PTR test
  local gateway_ip
  gateway_ip="$(get_gateway_ip "$SELECTED_INTERFACE" 2>/dev/null || true)"

  # Subnet-scan hosts whose only evidence is UDP/53 "open|filtered" (every
  # live host that silently drops UDP looks like that) are "quick" candidates:
  # one 1.5 s query first, the full test only when they answered. Without
  # this a flat /22 with ~100 silent hosts spent minutes in pure timeouts.
  local -a probe_tokens=()
  local quick_list quick_count=0
  quick_list=" $(jq -r '.servers[]? | select((.sources // []) == ["subnet-scan"] and (.transport.tcp // "unknown") != "open" and (.transport.udp // "") == "open|filtered") | .ip' "$json_file" 2>/dev/null | tr '\n' ' ') "
  for ip in "${dns_ips[@]}"; do
    if [[ "$quick_list" == *" $ip "* ]]; then
      probe_tokens+=("$ip:quick")
      quick_count=$((quick_count + 1))
    else
      probe_tokens+=("$ip")
    fi
  done

  echo "Stage 3: Testing resolution on ${#dns_ips[@]} DNS server(s)..."
  if [[ "$quick_count" -gt 0 ]]; then
    echo "($quick_count UDP-only candidate(s) get one short query first; the full test runs only for those that answer)"
  fi
  emit_stage 6 resolution_test "Testing resolution on ${#dns_ips[@]} DNS server(s)"

  local tmp_py tmp_err
  tmp_py="$(mktemp /tmp/lss-dns-test-XXXXXX)"
  tmp_err="$(mktemp /tmp/lss-dns-test-err-XXXXXX)"
  cat > "$tmp_py" << 'PYEOF'
import sys, socket, time, struct, random, json, ipaddress, re
from concurrent.futures import ThreadPoolExecutor

# argv: gateway_ip_or_dash  site_domain_or_dash  dns_server_ip...
gateway_ip  = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] not in ('', '-') else None
site_domain = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] not in ('', '-') else None
dns_servers = sys.argv[3:]

# argv tokens are "ip" or "ip:quick"; a quick candidate (subnet-scan host whose
# only evidence is UDP/53 "open|filtered", which is how every live host that
# silently drops UDP looks) gets one short query first and the full test only
# when it answered.
EXTERNAL_DOMAINS = ('google.com', 'microsoft.com')
RETRY_TIMEOUTS   = (2.0, 3.0, 5.0)
QUICK_TIMEOUTS   = (1.5,)
RCODE_NAMES      = {0: 'NOERROR', 2: 'SERVFAIL', 3: 'NXDOMAIN', 5: 'REFUSED'}

PRIVATE_RANGES = [
    ipaddress.ip_network('10.0.0.0/8'),
    ipaddress.ip_network('172.16.0.0/12'),
    ipaddress.ip_network('192.168.0.0/16'),
    ipaddress.ip_network('127.0.0.0/8'),
    ipaddress.ip_network('169.254.0.0/16'),
    ipaddress.ip_network('100.64.0.0/10'),
    ipaddress.ip_network('0.0.0.0/8'),
]

if site_domain is not None:
    site_domain = site_domain.strip().rstrip('.').lower()
    if not re.match(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$', site_domain):
        site_domain = None

def is_private(ip_str):
    try:
        addr = ipaddress.ip_address(ip_str)
        return any(addr in net for net in PRIVATE_RANGES)
    except Exception:
        return False

def build_query(domain, qtype=1):
    txid = random.randint(0, 65535)
    header = struct.pack('!HHHHHH', txid, 0x0100, 1, 0, 0, 0)
    question = b''
    for label in domain.split('.'):
        e = label.encode('idna') if label else b''
        question += bytes([len(e)]) + e
    question += b'\x00' + struct.pack('!HH', qtype, 1)
    return txid, header + question

def query(server_ip, domain, qtype, timeouts=RETRY_TIMEOUTS):
    """Retry with fresh transaction ids; only a reply carrying the current id counts.
    Returns (data|None, response_ms|None, attempts)."""
    attempts = 0
    for to in timeouts:
        attempts += 1
        txid, pkt = build_query(domain, qtype)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            start = time.monotonic()
            deadline = start + to
            sock.sendto(pkt, (server_ip, 53))
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                sock.settimeout(remaining)
                try:
                    data, _addr = sock.recvfrom(4096)
                except socket.timeout:
                    break
                if len(data) >= 12 and struct.unpack('!H', data[:2])[0] == txid and (data[2] & 0x80):
                    return data, round((time.monotonic() - start) * 1000, 1), attempts
        except OSError:
            pass
        finally:
            sock.close()
    return None, None, attempts

def skip_name(data, pos):
    while pos < len(data):
        l = data[pos]
        if l == 0:
            return pos + 1
        if l & 0xc0 == 0xc0:
            return pos + 2
        pos += l + 1
    return pos

def read_name(data, pos, depth=0):
    labels = []
    while pos < len(data) and depth < 16:
        l = data[pos]
        if l == 0:
            break
        if l & 0xc0 == 0xc0:
            ptr = struct.unpack('!H', data[pos:pos + 2])[0] & 0x3fff
            labels.append(read_name(data, ptr, depth + 1))
            break
        labels.append(data[pos + 1:pos + 1 + l].decode('ascii', errors='replace'))
        pos += l + 1
    return '.'.join(x for x in labels if x)

def answers(data):
    """List of (rtype, rdata_bytes, rdata_pos) from the answer section."""
    out = []
    try:
        qdcount, ancount = struct.unpack('!HH', data[4:8])
        pos = 12
        for _ in range(qdcount):
            pos = skip_name(data, pos) + 4
        for _ in range(ancount):
            pos = skip_name(data, pos)
            if pos + 10 > len(data):
                break
            rtype, _rclass, _ttl, rdlen = struct.unpack('!HHIH', data[pos:pos + 10])
            pos += 10
            out.append((rtype, data[pos:pos + rdlen], pos))
            pos += rdlen
    except Exception:
        pass
    return out

def rcode_of(data):
    return RCODE_NAMES.get(data[3] & 0x0f, 'other')

def a_records(data):
    return [socket.inet_ntoa(rd) for rtype, rd, _p in answers(data) if rtype == 1 and len(rd) == 4]

def ptr_record(data):
    for rtype, _rd, p in answers(data):
        if rtype == 12:
            name = read_name(data, p)
            return name or None
    return None

def ptr_name(ip):
    return '.'.join(reversed(ip.split('.'))) + '.in-addr.arpa'

def test_server(token):
    quick = token.endswith(':quick')
    server_ip = token[:-len(':quick')] if quick else token
    res = {
        'ip': server_ip,
        'resolution_test': None,
        'ptr_hostname': None,
        'gateway_ptr': None,
    }
    try:
        any_reply = False
        resolved = False
        resolved_ips = []
        response_ms = None
        attempts_total = 0
        rcode = 'timeout'
        ra = None
        first_timed_out = False
        pre = None
        if quick:
            # Pre-qualification: one 1.5 s A query. Silence ends the test here
            # (the caller discards the candidate) instead of ~16 s of timeouts.
            pre = query(server_ip, EXTERNAL_DOMAINS[0], 1, QUICK_TIMEOUTS)
            attempts_total += pre[2]
            if pre[0] is None:
                res['resolution_test'] = {
                    'domain':                  EXTERNAL_DOMAINS[0],
                    'domains':                 list(EXTERNAL_DOMAINS),
                    'resolved':                False,
                    'response_ms':             None,
                    'resolved_ips':            [],
                    'attempts':                attempts_total,
                    'rcode':                   'timeout',
                    'ra':                      None,
                    'recursion':               'unknown',
                    'open_resolver':           False,
                    'rebinding_risk':          False,
                    'external_private_answer': False,
                    'any_reply':               False,
                    'internal_test':           None,
                    'quick_probe':             True,
                }
                return res
        for idx, domain in enumerate(EXTERNAL_DOMAINS):
            if idx == 0 and pre is not None:
                data, ms, attempts = pre
            else:
                # A server that never answered the first name gets one short
                # try for the second instead of another 10 s of retries.
                timeouts = RETRY_TIMEOUTS if not (idx > 0 and first_timed_out) else (2.0,)
                data, ms, attempts = query(server_ip, domain, 1, timeouts)
                attempts_total += attempts
            if data is None:
                if idx == 0:
                    first_timed_out = True
                continue
            any_reply = True
            this_rcode = rcode_of(data)
            this_ra = bool(data[3] & 0x80)
            ips = a_records(data)
            if rcode == 'timeout' or this_rcode == 'NOERROR':
                rcode = this_rcode
            ra = this_ra if ra is None else (ra or this_ra)
            if this_rcode == 'NOERROR' and ips:
                if not resolved:
                    response_ms = ms
                resolved = True
                resolved_ips.extend(ip for ip in ips if ip not in resolved_ips)
        if resolved or ra:
            recursion = 'enabled'
        elif any_reply and ra is False:
            recursion = 'disabled'
        else:
            recursion = 'unknown'
        external_private = any(is_private(ip) for ip in resolved_ips)

        internal = None
        if site_domain:
            timeouts = RETRY_TIMEOUTS if any_reply else (3.0,)
            data_a, _ms, _n = query(server_ip, site_domain, 1, timeouts)
            srv_name = '_ldap._tcp.dc._msdcs.' + site_domain
            data_srv, _ms2, _n2 = query(server_ip, srv_name, 33, timeouts if data_a is not None else (2.0,))
            int_resolved = bool(data_a is not None and rcode_of(data_a) == 'NOERROR' and a_records(data_a))
            srv_found = bool(data_srv is not None and rcode_of(data_srv) == 'NOERROR'
                             and any(rt == 33 for rt, _r, _p in answers(data_srv)))
            if data_a is not None or data_srv is not None:
                any_reply = True
            internal = {
                'domain': site_domain,
                'resolved': int_resolved,
                'srv_found': srv_found,
                'rcode': rcode_of(data_a) if data_a is not None else 'timeout',
            }

        ptr_timeouts = (2.0,) if not any_reply else (2.0, 3.0)
        data_p, _m, _n = query(server_ip, ptr_name(server_ip), 12, ptr_timeouts)
        if data_p is not None:
            any_reply = True
            res['ptr_hostname'] = ptr_record(data_p)
        if gateway_ip:
            data_g, _m, _n = query(server_ip, ptr_name(gateway_ip), 12, ptr_timeouts)
            if data_g is not None:
                any_reply = True
                res['gateway_ptr'] = ptr_record(data_g)

        res['resolution_test'] = {
            'domain':                  EXTERNAL_DOMAINS[0],
            'domains':                 list(EXTERNAL_DOMAINS),
            'resolved':                resolved,
            'response_ms':             response_ms,
            'resolved_ips':            resolved_ips,
            'attempts':                attempts_total,
            'rcode':                   rcode,
            'ra':                      ra,
            'recursion':               recursion,
            'open_resolver':           recursion == 'enabled',
            'rebinding_risk':          external_private,
            'external_private_answer': external_private,
            'any_reply':               any_reply,
            'internal_test':           internal,
            'quick_probe':             quick,
        }
    except Exception as exc:
        print('dns probe %s: %s' % (server_ip, exc), file=sys.stderr)
    return res

results = []
if dns_servers:
    with ThreadPoolExecutor(max_workers=min(6, len(dns_servers))) as pool:
        results = list(pool.map(test_server, dns_servers))
print(json.dumps(results))
PYEOF

  local result_json probe_failed=false first_err=""
  result_json="$(python3 "$tmp_py" "${gateway_ip:--}" "${site_domain:--}" "${probe_tokens[@]}" 2>"$tmp_err" || true)"
  rm -f "$tmp_py"
  if [[ -z "$result_json" ]] || ! jq -e 'type == "array"' <<< "$result_json" >/dev/null 2>&1; then
    probe_failed=true
    result_json='[]'
  fi
  if [[ -s "$tmp_err" ]]; then
    first_err="$(head -1 "$tmp_err" 2>/dev/null | tr -d '\r')"
    copy_raw_artifact "$tmp_err" "$(task_raw_prefix 6)-resolution-stderr.txt" 2>/dev/null || true
  fi
  rm -f "$tmp_err"

  # Merge by ip (never by index): servers the probe did not report keep
  # resolution_test = null rather than another server's numbers.
  jq --argjson results "$result_json" '
    .servers |= map(
      . as $s
      | ($results | map(select(.ip == $s.ip)) | first) as $r
      | if $r then
          $s + {
            resolution_test: $r.resolution_test,
            ptr_hostname: ($r.ptr_hostname // null),
            gateway_ptr: ($r.gateway_ptr // null)
          }
        else
          $s + {resolution_test: null}
        end)' \
    "$json_file" > "$json_file.tmp" 2>/dev/null && mv "$json_file.tmp" "$json_file" || true

  if [[ "$probe_failed" == "true" ]]; then
    jq --arg w "DNS resolution test did not run: ${first_err:-no output from the probe}" \
      '.warnings += [$w] | .status = (if .status == "failed" then .status else "completed_with_warnings" end)' \
      "$json_file" > "$json_file.tmp" 2>/dev/null && mv "$json_file.tmp" "$json_file" || true
    printf "${red}DNS resolution test did not run:${reset} %s\n" "${first_err:-no output from the probe}"
    return 0
  fi

  printf "${bold}DNS Server Tests:${reset}\n"
  echo

  local silent_quick=0
  for ip in "${dns_ips[@]}"; do
    local entry resolved ms recursion rcode rebinding ptr gateway_ptr attempts sources int_domain int_resolved int_srv
    entry="$(jq -c --arg ip "$ip" '.servers[] | select(.ip == $ip)' "$json_file" 2>/dev/null | head -1)"
    [[ -z "$entry" ]] && continue
    # A quick candidate that never answered is discarded by the caller; no
    # per-server block for it.
    if [[ "$(jq -r '(.resolution_test.quick_probe // false) and ((.resolution_test.any_reply // false) | not)' <<< "$entry")" == "true" ]]; then
      silent_quick=$((silent_quick + 1))
      continue
    fi
    sources="$(    jq -r '(.sources // []) | join(", ")'                    <<< "$entry")"
    resolved="$(   jq -r '.resolution_test.resolved // false'               <<< "$entry")"
    ms="$(         jq -r '.resolution_test.response_ms // "null"'           <<< "$entry")"
    attempts="$(   jq -r '.resolution_test.attempts // "?"'                 <<< "$entry")"
    rcode="$(      jq -r '.resolution_test.rcode // "not tested"'           <<< "$entry")"
    recursion="$(  jq -r '.resolution_test.recursion // "unknown"'          <<< "$entry")"
    rebinding="$(  jq -r '.resolution_test.external_private_answer // false' <<< "$entry")"
    ptr="$(        jq -r '.ptr_hostname // ""'                               <<< "$entry")"
    gateway_ptr="$(jq -r '.gateway_ptr // ""'                                <<< "$entry")"
    int_domain="$( jq -r '.resolution_test.internal_test.domain // ""'       <<< "$entry")"
    int_resolved="$(jq -r '.resolution_test.internal_test.resolved // false' <<< "$entry")"
    int_srv="$(    jq -r '.resolution_test.internal_test.srv_found // false' <<< "$entry")"

    printf "  ${bold}%-16s${reset} %s\n" "$ip" "${sources:+[$sources]}"
    [[ -n "$ptr" ]] && printf "    Hostname:       %s\n" "$ptr"
    if [[ "$(jq -r '.resolution_test == null' <<< "$entry")" == "true" ]]; then
      printf "    External DNS:   not tested\n"
      echo
      continue
    elif [[ "$resolved" == "true" ]]; then
      printf "    External DNS:   ${green}OK${reset} (%s ms, attempt %s)\n" "$ms" "$attempts"
    else
      printf "    External DNS:   ${red}FAILED${reset} (%s after %s attempt(s))\n" "$rcode" "$attempts"
    fi
    # This probe only shows whether the server recurses for LAN clients; it is
    # not an internet-facing open-resolver test.
    case "$recursion" in
      enabled)  printf "    Recursion:      ${yellow}Enabled${reset} — answers external lookups for LAN clients\n" ;;
      disabled) printf "    Recursion:      Disabled\n" ;;
      *)        printf "    Recursion:      Unknown (no response)\n" ;;
    esac
    if [[ "$rebinding" == "true" ]]; then
      printf "    Private answer: ${red}WARNING${reset} — external name resolved to a private address (DNS filtering or rebinding)\n"
    fi
    if [[ -n "$int_domain" ]]; then
      printf "    Site domain:    %s — A %s, AD SRV %s\n" "$int_domain" "$([[ "$int_resolved" == "true" ]] && echo resolved || echo "not resolved")" "$([[ "$int_srv" == "true" ]] && echo found || echo "not found")"
    fi
    [[ -n "$gateway_ptr" ]] && printf "    Gateway PTR:    %s\n" "$gateway_ptr"
    echo
  done
  if [[ "$silent_quick" -gt 0 ]]; then
    echo "$silent_quick UDP-only candidate(s) gave no DNS reply within 1.5 s and were discarded."
    echo
  fi
}

detect_dns_servers() {
  local json_file t4_file t5_file
  local ip src
  local subnet_count=0 candidate_count=0
  local network=""
  local site_domain=""
  local -a extra_ips=() extra_sources=()

  scan_servers_by_ports \
    "DNS Network Scan" \
    "DNS" \
    "53" \
    "dns-scan.json" \
    "-PE -PS53,80,443 -PU53" \
    "53" \
    "22"
  json_file="$(task_output_path 6 2>/dev/null || true)"
  json_file_usable "$json_file" || return 0
  if [[ "$(jq -r '.status // ""' "$json_file")" == "failed" ]]; then
    return 0
  fi

  network="$(jq -r '.network // empty' "$json_file" 2>/dev/null || true)"
  subnet_count="$(jq -r '(.servers // []) | length' "$json_file")"

  # _add_candidate <ip> <source>: collect every resolver the network itself
  # points at, whatever subnet it lives on.
  _add_candidate() {
    local cip="$1" csrc="$2" i
    [[ "$cip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
    [[ "$cip" =~ ^(0\.|127\.) ]] && return 0
    for i in ${extra_ips[@]+"${!extra_ips[@]}"}; do
      if [[ "${extra_ips[$i]}" == "$cip" ]]; then
        [[ "${extra_sources[$i]}" == *"|$csrc|"* ]] || extra_sources[$i]="${extra_sources[$i]}$csrc|"
        return 0
      fi
    done
    extra_ips+=("$cip")
    extra_sources+=("|$csrc|")
  }

  while IFS= read -r ip; do
    _add_candidate "$ip" "configured"
  done < <(configured_dns_servers "$SELECTED_INTERFACE" 2>/dev/null || true)

  t4_file="$(task_output_path 4 2>/dev/null || true)"
  if [[ -n "$t4_file" ]] && json_file_usable "$t4_file"; then
    while IFS= read -r ip; do
      _add_candidate "$ip" "dhcp-offer"
    done < <(jq -r '(.dns_servers_offered // [])[]' "$t4_file" 2>/dev/null)
    while IFS= read -r ip; do
      _add_candidate "$ip" "system-lease"
    done < <(jq -r '(.system_lease.dns // [])[]' "$t4_file" 2>/dev/null)
    site_domain="$(jq -r '([.servers[]?.offered_domain // empty] + [.system_lease.domain // empty]) | map(select(. != "")) | first // empty' "$t4_file" 2>/dev/null || true)"
  fi
  t5_file="$(task_output_path 5 2>/dev/null || true)"
  if [[ -n "$t5_file" ]] && json_file_usable "$t5_file"; then
    while IFS= read -r ip; do
      _add_candidate "$ip" "dhcp-offer"
    done < <(jq -r '(.offered_dns // [])[]' "$t5_file" 2>/dev/null)
    if [[ -z "$site_domain" ]]; then
      site_domain="$(jq -r '.offered_domain // empty' "$t5_file" 2>/dev/null || true)"
    fi
  fi
  site_domain="$(printf '%s' "$site_domain" | tr -cd 'A-Za-z0-9.-')"

  local i on_subnet sources_json
  for i in ${extra_ips[@]+"${!extra_ips[@]}"}; do
    ip="${extra_ips[$i]}"
    sources_json="$(printf '%s\n' "${extra_sources[$i]}" | tr '|' '\n' | sed '/^$/d' | jq -R . | jq -s .)"
    on_subnet=false
    if [[ -n "$network" ]] && ip_in_cidr "$ip" "$network"; then
      on_subnet=true
    fi
    if jq -e --arg ip "$ip" '.servers[]? | select(.ip == $ip)' "$json_file" >/dev/null 2>&1; then
      jq --arg ip "$ip" --argjson src "$sources_json" \
        '(.servers[] | select(.ip == $ip)) |= (. + {sources: (((.sources // ["subnet-scan"]) + $src) | unique)})' \
        "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
    else
      candidate_count=$((candidate_count + 1))
      jq --arg ip "$ip" --argjson src "$sources_json" --argjson on_subnet "$on_subnet" \
        '.servers += [{ip: $ip, open_ports: [], detected_services: [], sources: $src, on_subnet: $on_subnet, transport: {tcp: "unknown", udp: "unknown"}}]' \
        "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
      echo "Candidate: $ip ($(printf '%s' "${extra_sources[$i]}" | tr '|' ' ' | sed 's/^ *//; s/ *$//; s/  */, /g'), $([[ "$on_subnet" == "true" ]] && echo on-subnet || echo off-subnet))"
    fi
  done
  [[ "$candidate_count" -gt 0 ]] && echo

  enrich_dns_resolution "$json_file" "$site_domain"

  # Subnet-scan hosts whose only evidence was UDP "open|filtered" are kept
  # only when the resolution test got any DNS reply from them. A probe that
  # did not run (resolution_test == null) keeps them: absence is not proven.
  jq '.servers |= map(select(
        ((.sources // []) == ["subnet-scan"]
         and (.transport.tcp // "unknown") != "open"
         and (.transport.udp // "") == "open|filtered"
         and .resolution_test != null
         and (.resolution_test.any_reply // false) == false) | not))' \
    "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"

  # Status: "no matching hosts" only when every source is empty; resolvers
  # found only outside the subnet are a success with an explanatory warning.
  local total_count off_subnet_ips
  total_count="$(jq -r '(.servers // []) | length' "$json_file")"
  off_subnet_ips="$(jq -r '[.servers[]? | select(.on_subnet == false) | .ip] | join(", ")' "$json_file")"
  if [[ "$total_count" -gt 0 ]]; then
    jq --arg off "$off_subnet_ips" --argjson subnet_count "$subnet_count" '
      .warnings |= map(select(startswith("The scan completed, but no matching hosts") | not))
      | (if $subnet_count == 0 and $off != "" then .warnings += ["The DNS servers in use are outside this subnet (" + $off + "); the local sweep found no DNS host."] else . end)
      | .status = (if (.warnings | any(test("timed out|wider than|did not run|only TCP"))) then "completed_with_warnings" else "success" end)' \
      "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
  fi
  jq -r '"DNS servers (all sources): " + ((.servers // []) | length | tostring) + " — " + ([.servers[]? | .ip + " [" + ((.sources // []) | join(", ")) + "]"] | join(", "))' "$json_file" 2>/dev/null || true
  validate_json_file "$json_file"
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
  # -n: without it nmap prints "report for host.example (10.0.0.5)" for hosts
  # with PTR records and the IP regex below never matches.
  nmap_out="$(nmap -n -p 445 --script smb2-security-mode --open "${smb_hosts[@]}" 2>/dev/null || true)"

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

  # No suffix after XXXXXX: BSD mktemp would otherwise return a fixed,
  # non-random path and fail with "File exists" once a stale file is left.
  tmp_pcap_tagged="$(mktemp /tmp/lss-vlan-tagged-XXXXXX)"
  tmp_pcap_cdp_lldp="$(mktemp /tmp/lss-vlan-cdp-XXXXXX)"
  tmp_py="$(mktemp /tmp/lss-vlan-py-XXXXXX)"
  tmp_raw_tagged="$(mktemp /tmp/lss-vlan-raw-tagged-XXXXXX)"
  tmp_raw_cdp_lldp="$(mktemp /tmp/lss-vlan-raw-cdp-XXXXXX)"

  # Step 1: Passive 802.1Q frame capture (10 seconds)
  emit_stage 11 dot1q_capture "Step 1/2: Capturing 802.1Q tagged frames on ${iface} (10s)"
  echo "Step 1/2: Capturing 802.1Q tagged frames on ${iface} (10s)..."
  # `vlan` (not `ether proto 0x8100`) also matches tags the NIC has already
  # stripped and handed to libpcap as ancillary data (Linux rx-vlan-offload).
  # -Z root: Debian/Ubuntu tcpdump drops privileges before opening -w and
  # cannot write a root-owned 0600 mktemp file otherwise.
  tcpdump -i "$iface" -Z root -w "$tmp_pcap_tagged" -q vlan 2>/dev/null &
  tagged_pid=$!
  register_bg_pid "$tagged_pid"
  sleep 10
  kill "$tagged_pid" 2>/dev/null || true
  wait "$tagged_pid" 2>/dev/null || true
  unregister_bg_pid "$tagged_pid"

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
  emit_stage 11 cdp_lldp_capture "Step 2/2: Capturing CDP and LLDP neighbour frames on ${iface} (65s)"
  echo "Step 2/2: Capturing CDP and LLDP neighbour frames on ${iface} (65s)..."
  echo "  (CDP advertises every 60s — this window ensures at least one full cycle is observed.)"
  tcpdump -i "$iface" -Z root -w "$tmp_pcap_cdp_lldp" -q \
    '(ether host 01:00:0c:cc:cc:cc) or (ether proto 0x88cc)' 2>/dev/null &
  cdp_pid=$!
  register_bg_pid "$cdp_pid"
  sleep 65
  kill "$cdp_pid" 2>/dev/null || true
  wait "$cdp_pid" 2>/dev/null || true
  unregister_bg_pid "$cdp_pid"

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
    # The contrib dissectors MUST be imported before rdpcap(): otherwise the
    # frames are already dissected as Raw and haslayer() is always False.
    try:
        from scapy.contrib.cdp import CDPv2_HDR
    except Exception:
        CDPv2_HDR = None
    try:
        from scapy.contrib.lldp import LLDPDU
    except Exception:
        LLDPDU = None
    pkts = rdpcap(sys.argv[1])
    result["raw_frame_count"] = len(pkts)

    seen_cdp = set()
    seen_lldp = set()

    for pkt in pkts:
        # CDP
        try:
            if CDPv2_HDR is not None and pkt.haslayer(CDPv2_HDR):
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
                            # scapy's CDPMsgPortID stores the name in `iface`, not `val`
                            neighbour["port_id"] = safe_decode(getattr(layer, "iface", None) or getattr(layer, "val", ""))
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
            if LLDPDU is not None and pkt.haslayer(LLDPDU):
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
  for w in ${warnings[@]+"${warnings[@]}"}; do
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
  local arp_scan_err
  arp_scan_err="$(mktemp /tmp/lss-arpscan-err-XXXXXX)"
  scan_output="$(arp-scan --interface="$iface" --localnet 2>"$arp_scan_err" || true)"
  echo "$scan_output" > "$raw_file"
  # arp-scan failures (not root, unsupported interface, BPF denied) used to be
  # swallowed and reported as "0 hosts, no duplicates, success". On any real
  # LAN at least the gateway answers ARP, so an empty result is a failure.
  if ! printf '%s\n' "$scan_output" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]'; then
    local arp_err_msg
    arp_err_msg="$(head -n 3 "$arp_scan_err" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    rm -f "$arp_scan_err"
    echo "Error: arp-scan returned no hosts${arp_err_msg:+ ($arp_err_msg)}."
    jq -n \
      --arg iface "$iface" \
      --arg network "$network" \
      --arg msg "arp-scan returned no hosts${arp_err_msg:+: $arp_err_msg}. Run as root and check the interface supports ARP." \
      '{status:"failed",success:false,error:{code:"ARP_SCAN_NO_RESULTS",message:$msg},warnings:[],network:$network,interface:$iface,total_hosts_seen:0,duplicate_count:0,duplicates:[]}' > "$json_file"
    validate_json_file "$json_file"
    return 1
  fi
  rm -f "$arp_scan_err"

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

  if ! spinner_is_quiet; then
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
  # Note: `if ! wait; then rc=$?` always captures 0 because `!` inverts the
  # status before $? is read. This form keeps the real exit code.
  wait "$pid" && process_exit_code=0 || process_exit_code=$?

  stop_spinner_line

  if [[ "$mode" == "host_ports" ]]; then
    final_display="$(extract_grepable_host_port_matches_csv "$output_file")"
  else
    final_display="$(extract_grepable_open_ports_csv "$output_file")"
  fi

  if [[ -n "$final_display" ]]; then
    echo "$label $final_display"
  elif spinner_is_quiet; then
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

  if spinner_is_quiet; then
    echo "$message"
    # Do not reap here: callers wait on the same pid afterwards, and on
    # bash >= 4 a second wait on a reaped pid returns 127 ("not a child").
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.2
    done
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

  if spinner_is_quiet; then
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
  if spinner_is_quiet; then
    return
  fi

  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi

  printf "\r\033[K" >&2
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
      if ! spinner_is_quiet; then
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
      if ! spinner_is_quiet; then
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
  # Note: `if ! wait; then rc=$?` always captures 0 because `!` inverts the
  # status before $? is read. This form keeps the real exit code.
  wait "$pid" && process_exit_code=0 || process_exit_code=$?

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

  # Always show the measured speeds once the run is over: the spinner flags
  # are only set after the "Hosted by" line parsed, and when that regex
  # missed the user never saw the speeds even though the JSON had them.
  if [[ -n "$download_speed" ]]; then
    echo "Download Speed: ${download_speed} Mbps"
  fi

  if [[ -n "$upload_speed" ]]; then
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
    local w=22
    printf "  %-${w}s %s\n" "Status:"               "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
    printf "  %-${w}s %s\n" "Public IP:"             "${public_ip:-unknown}"
    [[ -n "$isp_name" ]] && printf "  %-${w}s %s\n" "ISP:" "$isp_name"
    printf "  %-${w}s %s\n" "Connected to server:"   "${server:-unknown}"
    printf "  %-${w}s %s\n" "Ping:"                  "${ping:-unavailable} ms"
    printf "  %-${w}s %s\n" "Download Speed:"        "${download:-unavailable}"
    printf "  %-${w}s %s\n" "Upload Speed:"          "${upload:-unavailable}"
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
  local attempts_failed="${4:-0}"
  local warnings_json='[]'

  jq -n \
    --arg status "failed" \
    --argjson success false \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --argjson discovery_attempts "$discovery_attempts" \
    --argjson attempts_failed "$attempts_failed" \
    --argjson warnings "$warnings_json" \
    '{
      status: $status,
      success: $success,
      error: {code: $error_code, message: $error_message},
      warnings: $warnings,
      dhcp_responders_observed: 0,
      discovery_attempts: $discovery_attempts,
      attempts_failed: $attempts_failed,
      offers_observed: 0,
      raw_offers_observed: 0,
      non_offer_replies: 0,
      probe_mac: null,
      probe_mac_source: null,
      system_lease: null,
      evidence: "none",
      dns_servers_offered: [],
      relay_sources_seen: [],
      relay_agents_seen: [],
      reply_sources_seen: [],
      passive_servers_seen: [],
      capture_message_types: {Discover: 0, Offer: 0, Request: 0, ACK: 0, NAK: 0},
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
  echo "Stage 2: Scanning gateway ports (this may take up to 5 minutes)..."

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
  monitor_nmap_progress "$gateway_scan_pid" "$gateway_scan_file" 300 "ports" "Open Ports:" "Gateway port scan failed for $gateway_ip." || {
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

  # Short service tokens (ipp, rdp, nfs, cups) must match as whole words:
  # "philipp-pc" is not a printer and "shipping-desk" is not running IPP.
  local -a short_tokens=(ipp cups rdp nfs)
  local tok
  for tok in "${short_tokens[@]}"; do
    if [[ "$lowered" =~ (^|[^a-z0-9])${tok}([^a-z0-9]|$) ]]; then
      case "$tok" in
        ipp|cups) echo "printer"; return ;;
        rdp)      echo "windows-host"; return ;;
        nfs)      echo "nas-or-file-server"; return ;;
      esac
    fi
  done

  case "$lowered" in
    *opnsense*|*pfsense*|*unbound*|*firewall*|*routeros*|*mikrotik*|*fortinet*|*sonicwall*)
      echo "firewall-or-router"
      ;;
    *netgear*|*gs110tp*|*gs*switch*|*switch*)
      echo "network-switch"
      ;;
    *asus*|*mesh*|*access\ point*|*wireless\ router*|*wifi*)
      echo "access-point-or-router"
      ;;
    *printer*|*jetdirect*)
      echo "printer"
      ;;
    *samba*|*microsoft-ds*|*netbios*|*synology*|*qnap*)
      echo "nas-or-file-server"
      ;;
    *microsoft*|*windows*|*winrm*)
      echo "windows-host"
      ;;
    *openssh*|*ubuntu*|*debian*|*apache*|*nginx*|*tomcat*|*linux*)
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

    # TXT answers can be multi-word ("unbound 1.19.3", "PowerDNS Recursor
    # 4.8.4 (...)"): join everything after the record type, not just $NF.
    version_response="$(awk '
      BEGIN { in_answer=0 }
      /^;; ANSWER SECTION:/ { in_answer=1; next }
      /^;; / && in_answer { in_answer=0 }
      in_answer && NF >= 5 {
        out = ""
        for (i = 5; i <= NF; i++) out = out (i > 5 ? " " : "") $i
        print out
        exit
      }
    ' "$version_file" | tr -d '"')"
  else
    # nslookup prints a "Server:/Address:" header on every query, so
    # "Address:" alone proves nothing; require an answer and no error text.
    if grep -qi 'Name:' "$udp_file" && ! grep -qiE "can't find|NXDOMAIN|SERVFAIL|REFUSED|no servers could be reached" "$udp_file"; then
      udp_status="NOERROR"
      recursion_available=true
      dns_service_working=true
    fi
    if grep -qi 'name =' "$ptr_file" && ! grep -qiE "can't find|NXDOMAIN|SERVFAIL|REFUSED" "$ptr_file"; then
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
      # macOS arp omits leading zeros (8:bf:b8:47:f:e0), so accept 1-2 hex
      # digits per octet and normalise afterwards.
      mac_address="$(printf '%s\n' "$arp_output" | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^([0-9A-Fa-f]{1,2}:){5}[0-9A-Fa-f]{1,2}$/) {
              print $i
              exit
            }
          }
        }
      ')"
      mac_address="$(normalize_mac "$mac_address" | tr '[:lower:]' '[:upper:]')"
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
  # --host-timeout bounds a -sV against a host that drops SYNs; without it
  # this stage could run 10+ minutes with no way out but Ctrl-C.
  nmap -Pn -sV --version-light --host-timeout 300s "$target_ip" > "$services_file" 2>/dev/null &
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
      ls -d /sys/class/net/*/wireless 2>/dev/null | awk -F/ '{print $5}'
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

  # Stock macOS ships /usr/bin/swiftc as an xcode-select shim even with no
  # developer tools installed, so `command -v swiftc` is always true. Check
  # for a real toolchain instead, otherwise the shim pops a GUI dialog.
  local swiftc_bin=""
  if xcode-select -p >/dev/null 2>&1; then
    swiftc_bin="$(xcrun --find swiftc 2>/dev/null || true)"
  fi
  if [[ -z "$swiftc_bin" || ! -x "$swiftc_bin" ]]; then
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
    local iconset_parent iconset_dir
    # iconutil needs a *.iconset directory name, but BSD mktemp cannot
    # randomise a template with a suffix, so create it inside a temp dir.
    iconset_parent="$(mktemp -d /tmp/lss-AppIcon-XXXXXX)"
    iconset_dir="$iconset_parent/AppIcon.iconset"
    mkdir -p "$iconset_dir"
    local ok=1
    for size in 16 32 64 128 256 512; do
      sips -z $size $size "$icon_src" --out "$iconset_dir/icon_${size}x${size}.png"      >/dev/null 2>&1 || ok=0
      sips -z $((size*2)) $((size*2)) "$icon_src" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || ok=0
    done
    if [[ "$ok" -eq 1 ]]; then
      iconutil -c icns "$iconset_dir" -o "$icon_dst" 2>/dev/null && \
        echo "  App icon built from assets/wifi-scan-icon.png."
    fi
    rm -rf "$iconset_parent"
  fi

  local tmp_src_dir tmp_src
  # swiftc requires a .swift extension; BSD mktemp cannot randomise a
  # template with a suffix, so use a temp directory with a fixed file name.
  tmp_src_dir="$(mktemp -d /tmp/lss-wifiscan-XXXXXX)"
  tmp_src="$tmp_src_dir/LSS-WiFiScan.swift"
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
        // First launch: CoreLocation delivers an initial .notDetermined callback
        // while the permission dialog is still open. Keep waiting for the answer.
        case .notDetermined: return
        default: writeResult("[]"); NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT_EOF

  local swift_err rc=0
  swift_err="$(mktemp /tmp/lss-swiftc-err-XXXXXX)"
  # `if` form: this function also runs under errexit in --build-wifi-helper
  # mode, where a bare failing command would exit before the message below.
  if ! "$swiftc_bin" "$tmp_src" \
    -o "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" \
    -framework Foundation -framework AppKit \
    -framework CoreLocation -framework CoreWLAN \
    2>"$swift_err"; then
    rc=1
  fi
  rm -rf "$tmp_src_dir"

  if [[ $rc -ne 0 ]]; then
    echo "  Wi-Fi helper build failed. Compiler output:"
    sed 's/^/    /' "$swift_err" | head -n 20
    rm -f "$swift_err"
    return 1
  fi
  rm -f "$swift_err"

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
  tmp_result="$(mktemp /tmp/lss-wifi-result-XXXXXX)"
  # The app runs as the logged-in user (via open), not root.
  # Make the result file world-writable so the app can write its output.
  chmod 666 "$tmp_result" 2>/dev/null || true

  local run_as=""
  [[ "$(id -u)" == "0" ]] && [[ -n "${SUDO_USER:-}" ]] && run_as="$SUDO_USER"

  # Bounded wait: if Location Services is disabled or the permission dialog
  # is left unanswered, `open -W` would otherwise block forever.
  local open_pid waited=0 max_wait=90
  if [[ -n "$run_as" ]]; then
    sudo -u "$run_as" open -n -W "$_LSS_WIFI_HELPER" --args "$iface" "$tmp_result" 2>/dev/null &
  else
    open -n -W "$_LSS_WIFI_HELPER" --args "$iface" "$tmp_result" 2>/dev/null &
  fi
  open_pid=$!
  register_bg_pid "$open_pid"
  while kill -0 "$open_pid" 2>/dev/null && [[ "$waited" -lt "$max_wait" ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$open_pid" 2>/dev/null; then
    echo "  [WiFi scan helper did not finish within ${max_wait}s — check Location Services permission]" >&2
    pkill -f "LSS-WiFiScan.app/Contents/MacOS/LSS-WiFiScan" 2>/dev/null || true
    kill "$open_pid" 2>/dev/null || true
  fi
  wait "$open_pid" 2>/dev/null || true
  unregister_bg_pid "$open_pid"

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

# Non-interactive Task 17: scan exactly one room (--building/--floor/--room,
# --ap-present, --ap-label) and append it to this run's wireless-survey.json,
# creating the file when it does not exist yet. The macOS app walks a survey as
# repeated invocations with --run-dir. With --wifi-scan-json the given JSON
# array (helper `Network` shape) is used instead of run_wireless_scan.
wireless_site_survey_noninteractive() {
  local iface="$SELECTED_INTERFACE"
  local json_file tmp_json
  local building="$_LSS_NI_BUILDING" floor="$_LSS_NI_FLOOR" room="$_LSS_NI_ROOM"
  local ap_present_bool=false ap_label=""
  local scan_result entry_json timestamp net_count strongest_info
  local total_rooms written=0

  json_file="$(task_output_path 17)"

  # Interface: --wifi-interface, else the selected interface when it is
  # wireless, else the first wireless interface on this system.
  if [[ -n "$_LSS_NI_WIFI_INTERFACE" ]]; then
    iface="$_LSS_NI_WIFI_INTERFACE"
  elif ! is_wireless_interface "$iface"; then
    iface="$(list_wireless_interfaces 2>/dev/null | awk 'NF { print $1; exit }')"
  fi
  if [[ -z "$iface" ]] || ! is_wireless_interface "$iface"; then
    echo "No wireless interface available (selected: ${SELECTED_INTERFACE:-none}${_LSS_NI_WIFI_INTERFACE:+, requested: $_LSS_NI_WIFI_INTERFACE})."
    if json_file_usable "$json_file"; then
      echo "Existing survey file left untouched."
      return 1
    fi
    jq -n --arg iface "${iface:-}" \
      '{status:"failed",success:false,error:{code:"NO_WIRELESS_INTERFACE",message:"No wireless interface available on this system."},warnings:[],scan_type:"wireless_site_survey",interface:(if $iface == "" then null else $iface end),rooms_scanned:0,survey:[]}' > "$json_file"
    validate_json_file "$json_file" || true
    return 1
  fi
  printf "Using interface: %s\n" "$iface"

  # Build the Wi-Fi helper if it was not built at install/update time.
  if [[ "$(uname)" == "Darwin" ]] && [[ -z "$_LSS_NI_WIFI_SCAN_JSON" ]] \
     && [[ ! -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
    build_wifi_scan_helper_macos || true
    if [[ ! -x "$_LSS_WIFI_HELPER/Contents/MacOS/LSS-WiFiScan" ]]; then
      emit_progress warning "$(json_str_field code task_17_helper_fallback)" \
        "$(json_str_field message "LSS-WiFiScan helper unavailable; falling back to airport/system_profiler (SSIDs may be hidden)")"
    fi
  fi

  case "$_LSS_NI_AP_PRESENT" in
    [Yy])
      ap_present_bool=true
      ap_label="$_LSS_NI_AP_LABEL"
      ;;
    *)
      ap_present_bool=false
      ap_label=""
      ;;
  esac

  echo
  echo "--- $building | Floor: $floor | Room/Area: $room ---"
  echo
  if [[ -n "$_LSS_NI_WIFI_SCAN_JSON" ]]; then
    echo "Using pre-captured scan: $_LSS_NI_WIFI_SCAN_JSON"
    scan_result="$(jq -c 'if type == "array" then . else [] end' "$_LSS_NI_WIFI_SCAN_JSON" 2>/dev/null || true)"
  else
    echo "Scanning... (this takes a few seconds)"
    scan_result="$(run_wireless_scan "$iface")"
  fi
  if [[ -z "$scan_result" ]] || [[ "$scan_result" == "null" ]]; then
    scan_result="[]"
  fi
  if ! jq -e 'type == "array"' <<< "$scan_result" >/dev/null 2>&1; then
    echo "Scan output was not a JSON array; recording an empty scan."
    scan_result="[]"
  fi

  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  net_count="$(jq 'length' <<< "$scan_result" 2>/dev/null || echo 0)"

  if (( net_count > 0 )); then
    strongest_info="$(jq -r '[.[] | select(.rssi_dbm != null)] | if length == 0 then "unknown (no RSSI reported)" else (sort_by(.rssi_dbm) | reverse | .[0] | "\(.ssid // "<hidden>") (\(.rssi_dbm) dBm, ch \(.channel // "?"), \(.security // "--"))") end' <<< "$scan_result" 2>/dev/null || echo "unknown")"
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
    '{building:$building,floor:$floor,room:$room,ap_present:$ap_present,ap_label:(if $ap_label == "" then null else $ap_label end),timestamp:$timestamp,networks:$networks}' 2>/dev/null || true)"
  if [[ -z "$entry_json" ]]; then
    echo "Failed to build the survey entry."
    return 1
  fi

  # XXXXXX must stay last: BSD mktemp does not randomise it when a suffix follows.
  if ! tmp_json="$(mktemp "${json_file}.XXXXXX" 2>/dev/null)"; then
    echo "Unable to create a temporary file in $(dirname "$json_file")."
    return 1
  fi

  if json_file_usable "$json_file" && jq -e '(.survey | type) == "array"' "$json_file" >/dev/null 2>&1; then
    # Append to the survey recorded so far in this run.
    if jq --argjson e "$entry_json" --arg iface "$iface" '
        .survey = ((.survey // []) + [$e])
        | .rooms_scanned = (.survey | length)
        | .interface = $iface
        | .scan_type = "wireless_site_survey"
        | .status = (if (.status // "success") == "completed_with_warnings" then "completed_with_warnings" else "success" end)
        | .success = true
        | .error = null
        | .warnings = (.warnings // [])
      ' "$json_file" > "$tmp_json" 2>/dev/null && [[ -s "$tmp_json" ]]; then
      written=1
    fi
  else
    if jq -n \
      --arg interface "$iface" \
      --argjson e "$entry_json" \
      '{
        status: "success",
        success: true,
        error: null,
        warnings: [],
        scan_type: "wireless_site_survey",
        interface: $interface,
        rooms_scanned: 1,
        survey: [$e]
      }' > "$tmp_json" 2>/dev/null && [[ -s "$tmp_json" ]]; then
      written=1
    fi
  fi

  if [[ "$written" -ne 1 ]]; then
    rm -f "$tmp_json"
    echo "Failed to write the survey file."
    return 1
  fi
  if ! mv -f "$tmp_json" "$json_file"; then
    rm -f "$tmp_json"
    echo "Failed to write $json_file."
    return 1
  fi
  chmod 644 "$json_file" 2>/dev/null || true
  validate_json_file "$json_file" || return 1

  total_rooms="$(jq -r '.rooms_scanned // 0' "$json_file" 2>/dev/null || echo 1)"
  echo
  echo "Room recorded. $total_rooms room(s) in this survey."
  return 0
}

wireless_site_survey() {
  # Non-interactive mode: one room per invocation, appended to this run's
  # survey file (wireless_site_survey_noninteractive).
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    wireless_site_survey_noninteractive
    return
  fi

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
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

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

    printf "  Wireless interfaces available:\n"
    for i in "${!wifi_ifaces[@]}"; do
      printf "  %s) %s\n" "$((i + 1))" "${wifi_ifaces[$i]}"
    done
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold} 00)${reset}  Back to Main Menu\n"
    printf "  ${bold}  0)${reset}  Cancel\n"
    echo

    while true; do
      read -r -p "  Select wireless interface: " sel
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
      printf "  Invalid selection. Try again.\n"
    done
    echo
    printf "  Using interface: %s\n" "$iface"
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
      strongest_info="$(jq -r '[.[] | select(.rssi_dbm != null)] | if length == 0 then "unknown (no RSSI reported)" else (sort_by(.rssi_dbm) | reverse | .[0] | "\(.ssid // "<hidden>") (\(.rssi_dbm) dBm, ch \(.channel // "?"), \(.security // "--"))") end' <<< "$scan_result" 2>/dev/null || echo "unknown")"
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

  # "00 Back to Main Menu" used to discard every room already scanned. Keep
  # whatever was recorded and flag the survey as partial instead.
  local survey_status="success" survey_warnings='[]'
  if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then
    if [[ "${rooms_scanned:-0}" -eq 0 ]]; then
      return 0
    fi
    survey_status="completed_with_warnings"
    survey_warnings='["Survey ended early from the menu; results cover only the rooms scanned so far."]'
  fi

  json_file="$(task_output_path 17)"
  jq -n \
    --arg status "$survey_status" \
    --argjson success true \
    --arg interface "$iface" \
    --argjson rooms_scanned "$rooms_scanned" \
    --argjson survey "$survey_json" \
    --argjson warnings "$survey_warnings" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
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

  emit_stage "$task_id" baseline "Stage 2: Baseline latency test (20 pings)"
  echo "Stage 2: Baseline latency test (20 pings)..."
  if ! run_ping_stage "$baseline_file" ping -c 20 "$target_ip"; then
    baseline_status="failed"
    stage_failure=true
    echo "Warning: baseline latency test failed."
  fi

  # A target that never answers the baseline is unreachable: the remaining
  # stages would only produce all-zero metrics reported as a healthy
  # "returned to baseline" result.
  if [[ "$baseline_status" == "failed" ]] \
     && ! grep -qE 'bytes from|time=[0-9]' "$baseline_file" 2>/dev/null; then
    echo ""
    echo "Target $target_ip did not answer any baseline ping — stress test aborted."
    jq -n --arg ec "target_unreachable" \
      --arg em "Target $target_ip did not respond to any baseline ICMP echo request, so the stress stages were not run." \
      --arg fn "$json_function_name" --arg tk "$report_target_key" --arg tip "$target_ip" --arg hn "$hostname" --arg if_ "$iface" \
      '{status:"failed",success:false,error:{code:$ec,message:$em},warnings:[],function:$fn,($tk):$tip,hostname:$hn,interface:$if_}' > "$json_file"
    validate_json_file "$json_file" || true
    rm -f "$baseline_file" "$jitter_file" "$large_file" "$sustained_file" "$recovery_file"
    return 1
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

  emit_stage "$task_id" jitter "Stage 3: Jitter test (200 pings @ 0.05s interval)"
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

  emit_stage "$task_id" large_packet "Stage 4: Large packet test (100 pings @ 1400 bytes)"
  echo "Stage 4: Large packet test (100 pings @ 1400 bytes)..."
  if ! run_ping_stage "$large_file" ping -s 1400 -c 100 "$target_ip"; then
    large_status="failed"
    stage_failure=true
    echo "Warning: large packet test failed. Continuing with remaining stages."
  fi

  emit_stage "$task_id" ramping "Stage 5: Ramping test (20 pings per packet size)"
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

  emit_stage "$task_id" sustained "Stage 6: Sustained load test (300 pings @ 0.02s interval)"
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

  emit_stage "$task_id" recovery "Stage 7: Recovery test (30 pings)"
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

  # "Returned to baseline" is only meaningful when a baseline was measured.
  if [[ "$slow_recovery" == "false" ]] \
     && awk -v b="$baseline_avg" 'BEGIN { exit !(b > 0) }'; then
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
  # mktemp creates 0600 files; every other task JSON is 0644 and readers
  # (reports built as another user, the GUI) must be able to open this one.
  chmod 644 "$json_file" 2>/dev/null || true

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
  emit_stage 14 preparing "Stage 1: Preparing custom target stress test"
  echo "Stage 1: Preparing custom target stress test..."
  run_stress_test_for_target \
    "$target_ip" \
    "$SELECTED_INTERFACE" \
    "14" \
    "Function 14" \
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
  # Linux iputils may append ", pipe N" after the mdev value; keep only the
  # first token before stripping units.
  value="$(echo "$value" | awk '{print $1}' | sed 's/[^0-9.]*//g')"

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

  # Early exits below used to write the NON-indexed gateway-stress-test.json,
  # which the report, manifest and task_json_files never look at. Use the
  # same -device-N name as a full result.
  local early_json
  early_json="$(next_multi_entry_output_path 10)"

  emit_stage 10 interface_info "Stage 1: Running Interface Network Info"
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
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: "gateway_stress_test", gateway: null, hostname: "unknown", interface: null}' > "$early_json"
    validate_json_file "$early_json"
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
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: "gateway_stress_test", gateway: null, hostname: "unknown", interface: $interface}' > "$early_json"
    validate_json_file "$early_json"
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
      }' > "$early_json"
    validate_json_file "$early_json"
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
  local relay_agents_seen=()
  local reply_source_records=()
  local passive_servers_seen=()
  local dns_servers_offered=()
  local non_offer_server_ids=()
  local raw_attempt_excerpts=()
  local detail_servers=() detail_router=() detail_mask=() detail_dns=() detail_domain=() detail_lease=()
  local capture_kind capture_a capture_b
  local server
  local idx didx
  local dhcp_output_file
  local dhcp_stderr_file
  local tcpdump_output_file
  local json_file
  local -a dhcp_cmd
  local discovery_attempts=5
  local attempt
  local attempt_rc=0
  local attempt_error=""
  local attempts_failed=0
  local first_error_line=""
  local gateway_ip=""
  local network_cidr=""
  local raw_prefix
  local raw_offers_observed=0
  local unique_offers_observed=0
  local rogue_detected=false
  local discovery_note="DHCP detection uses repeated broadcast discovery attempts sent with this interface's MAC address. Only responders that replied to at least one attempt are listed. Offer counts are deduplicated by Server Identifier and IP Offered to reduce relay noise. The operating system's own lease is recorded as independent evidence."
  local offer_record
  local server_id offered_ip message_type offered_router offered_mask offered_dns offered_domain offered_lease
  local dns_ip
  local -a unique_offer_keys=()
  local attempt_excerpt
  local tcpdump_pid=""
  local tcpdump_enabled=false
  local status="success"
  local success="true"
  local error_code=""
  local error_message=""
  local warnings=()
  local probe_mac=""
  local probe_mac_source="nmap-default"
  local system_lease_json="null"
  local system_lease_server=""
  local system_lease_obtained=""
  local evidence="none"
  local msg_discover=0 msg_offer=0 msg_request=0 msg_ack=0 msg_nak=0

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

  # Probe with the interface's own MAC: DHCP snooping (verify mac-address)
  # and Wi-Fi controllers drop a DISCOVER whose chaddr is not the sender, and
  # nmap's default DE:AD:C0:DE:CA:FE is on IPS signature lists. Side effect:
  # the server offers this Mac's existing lease, so no pool address is used.
  probe_mac="$(interface_mac "$SELECTED_INTERFACE")"
  [[ -n "$probe_mac" ]] && probe_mac_source="interface"

  if [[ "$EUID" -eq 0 ]]; then
    dhcp_cmd=(nmap -v --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE")
  elif command -v sudo >/dev/null 2>&1; then
    dhcp_cmd=(sudo nmap -v --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE")
  else
    echo "DHCP discovery usually requires root privileges. Re-run as root or install sudo."
    rm -f "$dhcp_output_file"
    write_dhcp_failure_json "dhcp_privilege_required" "DHCP discovery usually requires root privileges. Re-run as root or install sudo." "$discovery_attempts"
    return 1
  fi
  if [[ -n "$probe_mac" ]]; then
    dhcp_cmd+=(--script-args "broadcast-dhcp-discover.mac=$probe_mac")
  fi

  gateway_ip="$(get_gateway_ip "$SELECTED_INTERFACE")"
  network_cidr="$(get_interface_network_cidr "$SELECTED_INTERFACE" 2>/dev/null || true)"

  # The lease the OS itself holds on this interface: the one piece of DHCP
  # evidence that survives any probe filtering.
  system_lease_json="$(system_dhcp_lease "$SELECTED_INTERFACE" 2>/dev/null || true)"
  [[ -z "$system_lease_json" ]] && system_lease_json="null"
  system_lease_server="$(jq -r '.server // empty' <<< "$system_lease_json" 2>/dev/null || true)"
  system_lease_obtained="$(jq -r '.obtained_at // empty' <<< "$system_lease_json" 2>/dev/null || true)"

  echo "Probe MAC: ${probe_mac:-nmap default (DE:AD:C0:DE:CA:FE)}"
  if [[ -n "$system_lease_server" ]]; then
    echo "System lease: $(jq -r '"server " + .server + (if .assigned_ip then ", assigned " + .assigned_ip else "" end) + (if .router then ", router " + .router else "" end) + (if (.dns | length) > 0 then ", DNS " + (.dns | join(" ")) else "" end) + (if .domain then ", domain " + .domain else "" end) + (if .lease_time_seconds then ", lease " + (.lease_time_seconds | tostring) + " s" else "" end) + (if .obtained_at then ", obtained " + .obtained_at else "" end) + " (" + .source + ")"' <<< "$system_lease_json" 2>/dev/null || echo "$system_lease_server")"
  else
    echo "System lease: none (static address or no lease found on this interface)"
  fi

  if ! command -v tcpdump >/dev/null 2>&1; then
    warnings+=("tcpdump is not available, so relay agents and reply sources cannot be captured.")
  elif [[ "$EUID" -ne 0 ]]; then
    warnings+=("tcpdump capture was skipped because the script is not running as root.")
  fi

  for ((attempt = 1; attempt <= discovery_attempts; attempt++)); do
    echo "DHCP discovery attempt $attempt of $discovery_attempts..."
    emit_stage 4 "attempt_$attempt" "DHCP discovery attempt $attempt of $discovery_attempts"
    tcpdump_output_file="$(mktemp)"
    dhcp_stderr_file="$(mktemp)"
    if [[ -z "$tcpdump_output_file" || ! -f "$tcpdump_output_file" || -z "$dhcp_stderr_file" || ! -f "$dhcp_stderr_file" ]]; then
      echo "Error: Unable to create a temporary file for DHCP packet capture."
      rm -f "$dhcp_output_file" "$tcpdump_output_file" "$dhcp_stderr_file"
      write_dhcp_failure_json "tempfile_creation_failed" "Unable to create a temporary file for DHCP packet capture." "$discovery_attempts"
      return 1
    fi
    tcpdump_pid=""
    if capture_dhcp_traffic "$SELECTED_INTERFACE" "$tcpdump_output_file"; then
      tcpdump_pid="$DHCP_CAPTURE_PID"
      tcpdump_enabled=true
    fi

    : > "$dhcp_output_file"
    "${dhcp_cmd[@]}" > "$dhcp_output_file" 2>"$dhcp_stderr_file" &
    local dhcp_discovery_pid=$!
    register_bg_pid "$dhcp_discovery_pid"
    spinner
    wait "$dhcp_discovery_pid" && attempt_rc=0 || attempt_rc=$?
    unregister_bg_pid "$dhcp_discovery_pid"

    stop_dhcp_capture "$tcpdump_pid"
    tcpdump_pid=""

    # nmap exits 0 even when the NSE script failed; the failure is text on
    # stdout or stderr. A failed attempt is a warning and the loop continues.
    attempt_error="$(grep -h -E 'ERROR:|lack of privileges|Failed to retrieve interfaces|Failed to send frame|Failed to open device|QUITTING!' "$dhcp_output_file" "$dhcp_stderr_file" 2>/dev/null | head -1 | sed 's/^[|_ ]*//' || true)"
    if [[ -z "$attempt_error" && "$attempt_rc" -ne 0 ]]; then
      attempt_error="nmap exited with status $attempt_rc"
    fi
    if [[ -n "$attempt_error" ]]; then
      attempts_failed=$((attempts_failed + 1))
      [[ -z "$first_error_line" ]] && first_error_line="$attempt_error"
      echo "Warning: attempt $attempt of $discovery_attempts failed: $attempt_error"
      warnings+=("Attempt $attempt of $discovery_attempts failed: $attempt_error")
    fi

    while IFS='|' read -r server_id offered_ip message_type offered_router offered_mask offered_dns offered_domain offered_lease; do
      [[ -z "$server_id" && -z "$offered_ip" ]] && continue
      if [[ -n "$message_type" && "$message_type" != "DHCPOFFER" ]]; then
        [[ -n "$server_id" ]] && non_offer_server_ids+=("$server_id")
        continue
      fi
      raw_offers_observed=$((raw_offers_observed + 1))

      if [[ -n "$server_id" ]]; then
        raw_server_ids+=("$server_id")
        # First non-empty offer details per server.
        didx=""
        for idx in ${detail_servers[@]+"${!detail_servers[@]}"}; do
          [[ "${detail_servers[$idx]}" == "$server_id" ]] && { didx="$idx"; break; }
        done
        if [[ -z "$didx" ]]; then
          detail_servers+=("$server_id"); detail_router+=(""); detail_mask+=(""); detail_dns+=(""); detail_domain+=(""); detail_lease+=("")
          didx=$(( ${#detail_servers[@]} - 1 ))
        fi
        [[ -z "${detail_router[$didx]}" ]] && detail_router[$didx]="$offered_router"
        [[ -z "${detail_mask[$didx]}" ]] && detail_mask[$didx]="$offered_mask"
        [[ -z "${detail_dns[$didx]}" ]] && detail_dns[$didx]="$offered_dns"
        [[ -z "${detail_domain[$didx]}" ]] && detail_domain[$didx]="$offered_domain"
        [[ -z "${detail_lease[$didx]}" ]] && detail_lease[$didx]="$offered_lease"
      fi
      if [[ -n "$offered_dns" ]]; then
        while IFS= read -r dns_ip; do
          [[ -z "$dns_ip" ]] && continue
          if [[ "${#dns_servers_offered[@]}" -eq 0 ]] || ! array_contains "$dns_ip" "${dns_servers_offered[@]}"; then
            dns_servers_offered+=("$dns_ip")
          fi
        done < <(printf '%s\n' "$offered_dns" | tr ',' '\n')
      fi

      local offer_key="${server_id}|${offered_ip}"
      if [[ "${#unique_offer_keys[@]}" -eq 0 ]] || ! array_contains "$offer_key" "${unique_offer_keys[@]}"; then
        unique_offer_keys+=("$offer_key")
        unique_offers_observed=$((unique_offers_observed + 1))
      fi
    done < <(extract_dhcp_offer_records "$dhcp_output_file")

    while IFS='|' read -r capture_kind capture_a capture_b; do
      [[ -z "$capture_kind" ]] && continue
      case "$capture_kind" in
        reply_source)
          [[ -z "$capture_a" ]] && continue
          if [[ "${#reply_source_records[@]}" -eq 0 ]] || ! array_contains "${capture_a}|${capture_b}" "${reply_source_records[@]}"; then
            reply_source_records+=("${capture_a}|${capture_b}")
          fi
          ;;
        relay_agent)
          [[ -z "$capture_a" ]] && continue
          if [[ "${#relay_agents_seen[@]}" -eq 0 ]] || ! array_contains "$capture_a" "${relay_agents_seen[@]}"; then
            relay_agents_seen+=("$capture_a")
          fi
          ;;
        passive_server)
          [[ -z "$capture_a" ]] && continue
          if [[ "${#passive_servers_seen[@]}" -eq 0 ]] || ! array_contains "$capture_a" "${passive_servers_seen[@]}"; then
            passive_servers_seen+=("$capture_a")
          fi
          ;;
        msgtype)
          [[ "$capture_b" =~ ^[0-9]+$ ]] || continue
          case "$capture_a" in
            Discover) msg_discover=$((msg_discover + capture_b)) ;;
            Offer) msg_offer=$((msg_offer + capture_b)) ;;
            Request) msg_request=$((msg_request + capture_b)) ;;
            ACK) msg_ack=$((msg_ack + capture_b)) ;;
            NAK) msg_nak=$((msg_nak + capture_b)) ;;
          esac
          ;;
      esac
    done < <(extract_dhcp_capture_summary "$tcpdump_output_file")

    attempt_excerpt="$(extract_dhcp_attempt_excerpt "$dhcp_output_file")"
    raw_attempt_excerpts+=("$attempt_excerpt")

    copy_raw_artifact "$dhcp_output_file" "$(printf '%s-attempt-%02d.txt' "$raw_prefix" "$attempt")"
    # nmap always warns "No targets were specified, so 0 hosts scanned." for a
    # broadcast-script-only run; keep the stderr artefact only when it says more.
    if grep -v 'No targets were specified' "$dhcp_stderr_file" 2>/dev/null | grep -q .; then
      copy_raw_artifact "$dhcp_stderr_file" "$(printf '%s-attempt-%02d-stderr.txt' "$raw_prefix" "$attempt")"
    fi
    if [[ -s "$tcpdump_output_file" ]]; then
      copy_raw_artifact "$tcpdump_output_file" "$(printf '%s-tcpdump-%02d.txt' "$raw_prefix" "$attempt")"
    fi

    rm -f "$tcpdump_output_file" "$dhcp_stderr_file"
  done

  rm -f "$dhcp_output_file"

  if [[ "$attempts_failed" -ge "$discovery_attempts" ]]; then
    echo "Error: every DHCP discovery attempt failed: $first_error_line"
    write_dhcp_failure_json "dhcp_discovery_attempt_failed" "$first_error_line" "$discovery_attempts" "$attempts_failed"
    return 1
  fi

  if [[ "${#raw_server_ids[@]}" -gt 0 ]]; then
    while IFS= read -r server; do
      [[ -n "$server" ]] && unique_servers+=("$server")
    done < <(printf "%s\n" "${raw_server_ids[@]}" | awk '!seen[$0]++')
  fi

  echo "DHCP responders observed: ${#unique_servers[@]}"
  echo "Unique DHCP offers observed across attempts: $unique_offers_observed"
  echo "Raw DHCP offers captured across attempts: $raw_offers_observed"
  if [[ "${#non_offer_server_ids[@]}" -gt 0 ]]; then
    echo "Non-offer replies (NAK/ACK) captured: ${#non_offer_server_ids[@]}"
  fi
  if [[ "${#dns_servers_offered[@]}" -gt 0 ]]; then
    echo "DNS servers offered: ${dns_servers_offered[*]}"
  fi
  if [[ "${#relay_agents_seen[@]}" -gt 0 ]]; then
    echo "Relay agents seen: ${relay_agents_seen[*]}"
  fi

  if [[ "${#unique_servers[@]}" -gt 0 ]]; then
    for idx in "${!unique_servers[@]}"; do
      echo "DHCP IP Address: ${unique_servers[$idx]}"
    done
  fi

  echo

  local reply_sources_json='[]'
  if [[ "${#reply_source_records[@]}" -gt 0 ]]; then
    reply_sources_json="$(printf '%s\n' "${reply_source_records[@]}" | jq -R 'split("|") | {ip: .[0], mac: (if (.[1] // "") == "" then null else .[1] end)}' | jq -s .)"
  fi
  local relay_agents_json
  relay_agents_json="$(json_string_array_from_array relay_agents_seen)"

  json_file="$(task_output_path 4)"
  jq -n \
    --arg status "success" \
    --argjson success true \
    --argjson warnings '[]' \
    --argjson dhcp_responders_observed "${#unique_servers[@]}" \
    --argjson discovery_attempts "$discovery_attempts" \
    --argjson attempts_failed "$attempts_failed" \
    --argjson offers_observed "$unique_offers_observed" \
    --argjson raw_offers_observed "$raw_offers_observed" \
    --argjson non_offer_replies "${#non_offer_server_ids[@]}" \
    --arg probe_mac "$probe_mac" \
    --arg probe_mac_source "$probe_mac_source" \
    --argjson system_lease "$system_lease_json" \
    --argjson dns_servers_offered "$(json_string_array_from_array dns_servers_offered)" \
    --argjson relay_agents_seen "$relay_agents_json" \
    --argjson reply_sources_seen "$reply_sources_json" \
    --argjson passive_servers_seen "$(json_string_array_from_array passive_servers_seen)" \
    --argjson msg_discover "$msg_discover" \
    --argjson msg_offer "$msg_offer" \
    --argjson msg_request "$msg_request" \
    --argjson msg_ack "$msg_ack" \
    --argjson msg_nak "$msg_nak" \
    --argjson tcpdump_capture_used "$tcpdump_enabled" \
    --arg discovery_note "$discovery_note" \
    '{
      status: $status,
      success: $success,
      error: null,
      warnings: $warnings,
      dhcp_responders_observed: $dhcp_responders_observed,
      discovery_attempts: $discovery_attempts,
      attempts_failed: $attempts_failed,
      offers_observed: $offers_observed,
      raw_offers_observed: $raw_offers_observed,
      non_offer_replies: $non_offer_replies,
      probe_mac: (if $probe_mac == "" then null else $probe_mac end),
      probe_mac_source: $probe_mac_source,
      system_lease: $system_lease,
      evidence: "none",
      dns_servers_offered: $dns_servers_offered,
      relay_sources_seen: $relay_agents_seen,
      relay_agents_seen: $relay_agents_seen,
      reply_sources_seen: $reply_sources_seen,
      passive_servers_seen: $passive_servers_seen,
      capture_message_types: {Discover: $msg_discover, Offer: $msg_offer, Request: $msg_request, ACK: $msg_ack, NAK: $msg_nak},
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
    if [[ -n "$system_lease_server" ]]; then
      evidence="system_lease"
      warnings+=("No DHCP offer was received by the discovery probes, but this interface holds a lease from ${system_lease_server}${system_lease_obtained:+ (obtained ${system_lease_obtained})}. A DHCP server exists on this network but did not answer broadcast discovery from this port — check DHCP snooping, Wi-Fi client isolation, or a relay that ignores unknown clients.")
      echo "Warning: no offers were received, but the system lease names DHCP server $system_lease_server."
    else
      warnings+=("No DHCP responders were observed during the discovery attempts. This does not necessarily mean that no DHCP server exists on the network.")
    fi
    status="completed_with_warnings"
    jq --arg evidence "$evidence" '.evidence = $evidence' "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"
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

  jq '.evidence = "offers"' "$json_file" > "$json_file.tmp" && mv "$json_file.tmp" "$json_file"

  echo "Stage 2: Scanning for ports on DHCP server(s)..."
  emit_stage 4 port_scan "Scanning ports on ${#unique_servers[@]} DHCP server(s)"

  # Rogue rule "multiple_server_identifiers": with more than one Server
  # Identifier, every server that is neither the system-lease server nor the
  # gateway is suspect; when none can be exonerated, all are.
  local exonerable_count=0
  if [[ "${#unique_servers[@]}" -gt 1 ]]; then
    for idx in "${!unique_servers[@]}"; do
      server="${unique_servers[$idx]}"
      if [[ ( -n "$system_lease_server" && "$server" == "$system_lease_server" ) || ( -n "$gateway_ip" && "$server" == "$gateway_ip" ) ]]; then
        exonerable_count=$((exonerable_count + 1))
      fi
    done
  fi

  for idx in "${!unique_servers[@]}"; do
    local open_ports=()
    local rogue_reasons=()
    local dhcp_scan_file
    local port
    local classification
    local suspected_rogue=false
    local offer_count=0
    local non_offer_count=0
    local responder_mac=""
    local s_router="" s_mask="" s_dns="" s_domain="" s_lease=""
    local record
    server="${unique_servers[$idx]}"

    echo
    echo "Scanning common ports on Server $((idx + 1))..."

    dhcp_scan_file="$(mktemp)"
    local port_scan_ok=true
    if [[ -z "$dhcp_scan_file" || ! -f "$dhcp_scan_file" ]]; then
      warnings+=("Could not create temp file for port scan of DHCP server $server. Port data will be absent.")
      port_scan_ok=false
    else
      # -Pn: the host just answered DHCP, so it is up; a server that blocks
      # ICMP/TCP discovery used to come back as "0 ports" and be flagged rogue.
      nmap -n -Pn --top-ports 1000 --open "$server" -oG - > "$dhcp_scan_file" 2>/dev/null &
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
    if [[ "${#non_offer_server_ids[@]}" -gt 0 ]]; then
      non_offer_count="$(printf '%s\n' "${non_offer_server_ids[@]}" | awk -v target="$server" '$0 == target {count++} END {print count+0}')"
    fi
    for didx in ${detail_servers[@]+"${!detail_servers[@]}"}; do
      if [[ "${detail_servers[$didx]}" == "$server" ]]; then
        s_router="${detail_router[$didx]}"
        s_mask="${detail_mask[$didx]}"
        s_dns="${detail_dns[$didx]}"
        s_domain="${detail_domain[$didx]}"
        s_lease="${detail_lease[$didx]}"
        break
      fi
    done
    for record in ${reply_source_records[@]+"${reply_source_records[@]}"}; do
      if [[ "${record%%|*}" == "$server" && -n "${record#*|}" ]]; then
        responder_mac="${record#*|}"
        break
      fi
    done

    classification="$(classify_dhcp_server "$server" "$gateway_ip" ${open_ports[@]+"${open_ports[@]}"})"

    # Evidence-based rogue rule. Open TCP ports are informational only: a
    # hardened legitimate server has none, a consumer router has plenty.
    if [[ "${#unique_servers[@]}" -gt 1 ]]; then
      if [[ "$exonerable_count" -eq 0 ]]; then
        rogue_reasons+=("multiple_server_identifiers")
      elif [[ ! ( ( -n "$system_lease_server" && "$server" == "$system_lease_server" ) || ( -n "$gateway_ip" && "$server" == "$gateway_ip" ) ) ]]; then
        rogue_reasons+=("multiple_server_identifiers")
      fi
    fi
    if [[ -n "$system_lease_server" && "$server" != "$system_lease_server" ]]; then
      rogue_reasons+=("differs_from_system_lease")
    fi
    if [[ -n "$s_router" && -n "$network_cidr" ]] && ! ip_in_cidr "$s_router" "$network_cidr"; then
      rogue_reasons+=("offered_router_not_on_subnet")
    fi
    if [[ -n "$network_cidr" ]] && ! ip_in_cidr "$server" "$network_cidr"; then
      # Absence of relay evidence only counts when a capture was taken; an
      # empty relay list from a capture that never ran proves nothing.
      if [[ "$tcpdump_enabled" == "true" && "${#relay_agents_seen[@]}" -eq 0 ]]; then
        rogue_reasons+=("server_outside_subnet_without_relay")
      elif [[ "$tcpdump_enabled" != "true" ]]; then
        warnings+=("DHCP server $server is outside the interface network $network_cidr; no packet capture was available to confirm a relay agent, so this was not treated as a rogue indicator.")
      fi
    fi
    if [[ "${#rogue_reasons[@]}" -gt 0 ]]; then
      suspected_rogue=true
      rogue_detected=true
      suspected_rogue_servers+=("$server")
    fi

    echo "Unique Offers Observed: $(count_unique_offer_keys_for_server "$server" "${unique_offer_keys[@]:-}")"
    echo "Raw Offers Captured: $offer_count"
    [[ "$non_offer_count" -gt 0 ]] && echo "Non-offer Replies: $non_offer_count"
    if [[ -n "$s_lease" ]]; then
      echo "Offered router / DNS / domain / lease: ${s_router:-n/a} / ${s_dns:-n/a} / ${s_domain:-n/a} / ${s_lease} s"
    else
      echo "Offered router / DNS / domain / lease: ${s_router:-n/a} / ${s_dns:-n/a} / ${s_domain:-n/a} / n/a"
    fi
    [[ -n "$s_mask" ]] && echo "Offered Subnet Mask: $s_mask"
    echo "Responder MAC: ${responder_mac:-not captured}"
    echo "Classification: $classification"
    if [[ "$port_scan_ok" == "true" && "${#open_ports[@]}" -eq 0 ]]; then
      echo "Warning: No open TCP ports were detected on this DHCP responder."
      warnings+=("No open TCP ports were detected on DHCP responder $server.")
    fi
    if [[ "$suspected_rogue" == "true" ]]; then
      echo "Suspected Rogue DHCP Responder: YES"
      echo "Rogue reasons: ${rogue_reasons[*]}"
    else
      echo "Suspected Rogue DHCP Responder: NO"
      echo "Rogue reasons: none"
    fi

    local s_dns_json
    if [[ -n "$s_dns" ]]; then
      s_dns_json="$(printf '%s\n' "$s_dns" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)"
    else
      s_dns_json='[]'
    fi

    jq \
      --arg ip "$server" \
      --argjson open_ports "$(ports_to_json_array ${open_ports[@]+"${open_ports[@]}"})" \
      --argjson offers_observed "$(count_unique_offer_keys_for_server "$server" "${unique_offer_keys[@]:-}")" \
      --argjson raw_offers_observed "$offer_count" \
      --argjson non_offer_replies "$non_offer_count" \
      --arg classification "$classification" \
      --argjson suspected_rogue "$suspected_rogue" \
      --argjson rogue_reasons "$(json_string_array_from_array rogue_reasons)" \
      --arg offered_router "$s_router" \
      --arg offered_subnet_mask "$s_mask" \
      --argjson offered_dns "$s_dns_json" \
      --arg offered_domain "$s_domain" \
      --arg lease_time_seconds "$s_lease" \
      --arg responder_mac "$responder_mac" \
      '.servers += [{
        ip: $ip,
        open_ports: $open_ports,
        offers_observed: $offers_observed,
        raw_offers_observed: $raw_offers_observed,
        non_offer_replies: $non_offer_replies,
        classification: $classification,
        suspected_rogue: $suspected_rogue,
        rogue_reasons: $rogue_reasons,
        offered_router: (if $offered_router == "" then null else $offered_router end),
        offered_subnet_mask: (if $offered_subnet_mask == "" then null else $offered_subnet_mask end),
        offered_dns: $offered_dns,
        offered_domain: (if $offered_domain == "" then null else $offered_domain end),
        lease_time_seconds: (if $lease_time_seconds == "" then null else ($lease_time_seconds | tonumber) end),
        responder_mac: (if $responder_mac == "" then null else $responder_mac end)
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
  local probe_count="${DHCP_RT_PROBE_COUNT:-10}"
  local status="success"
  local success=true
  local warnings=()
  local warnings_json="[]"
  local probe_mac=""

  json_file="$(task_output_path 5)"

  echo
  echo "DHCP Response Time"
  echo "=================="

  if [[ -z "$iface" ]]; then
    jq -n --argjson probe_count "$probe_count" '{status:"failed",success:false,error:{code:"NO_INTERFACE",message:"No network interface selected."},warnings:[],interface:null,probe_count:$probe_count,responded_count:0,response_times_ms:[],min_ms:null,avg_ms:null,max_ms:null,packet_loss_percent:null,server_ip:null,servers_seen:{},multiple_responders:false,receive_method:null,send_method:null,probe_mac:null,indicators:{slow_response:false,high_loss:false,probe_inconsistent:false,server_mismatch:false}}' > "$json_file"
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

  probe_mac="$(interface_mac "$iface")"

  echo "Interface:   $iface"
  $is_wifi && echo "Type:        Wi-Fi (wireless)"
  echo "Probes:      $probe_count (1 s apart, 5 s wait each)"
  echo "Probe MAC:   ${probe_mac:-random locally administered}"
  echo "Sending DHCP Discover broadcasts and timing Offer responses..."
  emit_stage 5 probe "Sending $probe_count DHCP Discover probes on $iface"

  tmp_py="$(mktemp /tmp/lss-dhcp-rt-XXXXXX)"
  cat > "$tmp_py" <<'PYEOF'
import sys, json, time, random, socket, struct, threading

# argv: iface probe_count mac is_wifi
iface       = sys.argv[1]
probe_count = int(sys.argv[2])
mac_arg     = sys.argv[3] if len(sys.argv) > 3 else ""
is_wifi     = (len(sys.argv) > 4 and sys.argv[4] == "true")

DHCP_MAGIC     = b'\x63\x82\x53\x63'
PROBE_TIMEOUT  = 5.0    # seconds to wait for the first OFFER
GRACE_WINDOW   = 0.3    # keep listening this long after the first OFFER (more responders)
PROBE_INTERVAL = 1.0    # pause between probes
PROBE_OPTIONS  = "53,55,57,61,12"
notes          = []

def parse_mac(s):
    s = (s or "").strip().lower().replace('-', ':')
    parts = s.split(':')
    if len(parts) != 6:
        return None
    try:
        vals = [int(p, 16) for p in parts]
    except ValueError:
        return None
    if any(v < 0 or v > 255 for v in vals):
        return None
    return bytes(vals)

mac_bytes = parse_mac(mac_arg)
probe_mac_source = "interface"
if mac_bytes is None:
    # Locally administered, unicast; one MAC for the whole run so a nearly
    # full pool is not tipped into exhaustion by ten different clients.
    mac_bytes = bytes([0x02, 0x4c, 0x53] + [random.randint(0, 255) for _ in range(3)])
    probe_mac_source = "random"
mac_str = ':'.join('%02x' % b for b in mac_bytes)

# The interface must exist before any socket is opened: a socket that cannot
# be pinned to it would broadcast on the default route instead, and a probe
# on the wrong network is worse than no probe.
try:
    iface_index = socket.if_nametoindex(iface)
except (OSError, ValueError) as exc:
    print(json.dumps({"error": "probe_error: interface %s not found (%s)" % (iface, exc), "notes": notes}))
    sys.exit(0)

def make_dhcp_discover(xid, secs=0):
    chaddr = mac_bytes + b'\x00' * 10
    bootp = struct.pack('!BBBBIHH4s4s4s4s16s64s128s',
        1, 1, 6, 0, xid, secs, 0x8000,
        b'\x00' * 4, b'\x00' * 4, b'\x00' * 4, b'\x00' * 4,
        chaddr, b'\x00' * 64, b'\x00' * 128)
    options = (
        DHCP_MAGIC
        + b'\x35\x01\x01'                              # 53 message type: Discover
        + b'\x37\x06\x01\x03\x06\x0f\x33\x36'          # 55 parameter request list 1,3,6,15,51,54
        + b'\x39\x02' + struct.pack('!H', 1500)        # 57 maximum DHCP message size
        + b'\x3d\x07\x01' + mac_bytes                  # 61 client identifier (type 1 + MAC)
        + b'\x0c\x09' + b'lss-audit'                   # 12 host name
        + b'\xff')
    return bootp + options

def parse_options(bootp):
    opts = {}
    if len(bootp) < 240 or bootp[236:240] != DHCP_MAGIC:
        return opts
    i = 240
    while i < len(bootp):
        opt = bootp[i]
        if opt == 255:
            break
        if opt == 0:
            i += 1
            continue
        if i + 1 >= len(bootp):
            break
        length = bootp[i + 1]
        val = bootp[i + 2:i + 2 + length]
        if opt not in opts:
            opts[opt] = val
        i += 2 + length
    return opts

def ip_list(raw):
    return [socket.inet_ntoa(raw[j:j + 4]) for j in range(0, len(raw) - len(raw) % 4, 4)]

def parse_reply(bootp, sender_ip):
    """(xid, info) for a BOOTREPLY carrying a DHCP message type, else (None, None)."""
    if len(bootp) < 244 or bootp[0] != 2 or bootp[236:240] != DHCP_MAGIC:
        return None, None
    xid = struct.unpack('!I', bootp[4:8])[0]
    opts = parse_options(bootp)
    if 53 not in opts or len(opts[53]) != 1:
        return None, None
    server_id = None
    if 54 in opts and len(opts[54]) == 4:
        server_id = socket.inet_ntoa(opts[54])
    if not server_id:
        siaddr = socket.inet_ntoa(bootp[20:24])
        server_id = siaddr if siaddr != '0.0.0.0' else sender_ip
    domain = None
    if 15 in opts:
        domain = opts[15].rstrip(b'\x00').decode('ascii', errors='replace')
        domain = ''.join(c for c in domain if c.isalnum() or c in '.-') or None
    info = {
        'message_type': opts[53][0],
        'server_id':    server_id,
        'yiaddr':       socket.inet_ntoa(bootp[16:20]),
        'router':       (ip_list(opts[3])[0] if 3 in opts and len(opts[3]) >= 4 else None),
        'dns':          (ip_list(opts[6]) if 6 in opts else []),
        'domain':       domain,
        'lease_time':   (struct.unpack('!I', opts[51])[0] if 51 in opts and len(opts[51]) == 4 else None),
    }
    return xid, info

def extract_bootp_from_raw(raw):
    # SOCK_RAW delivers IP header + UDP header + payload.
    if len(raw) < 28:
        return None, None
    ip_hdr_len = (raw[0] & 0x0f) * 4
    if len(raw) < ip_hdr_len + 8:
        return None, None
    dst_port = struct.unpack('!H', raw[ip_hdr_len + 2:ip_hdr_len + 4])[0]
    if dst_port != 68:
        return None, None
    return raw[ip_hdr_len + 8:], socket.inet_ntoa(raw[12:16])

def pin_sock_to_iface(sock):
    # Linux: SO_BINDTODEVICE (CAP_NET_RAW before 5.7); macOS: IP_BOUND_IF
    # (IPPROTO_IP option 25, interface index). On Linux IPPROTO_IP 25 is
    # IP_RECVFRAGSIZE, which accepts the int and pins nothing, so the fallback
    # is macOS-only. A socket that cannot be pinned must not be used: it would
    # talk to the default route's network instead of the audited one.
    bind_error = None
    try:
        sock.setsockopt(socket.SOL_SOCKET, 25, iface.encode() + b'\x00')
        return
    except (AttributeError, OSError) as exc:
        bind_error = exc
    if sys.platform == 'darwin':
        sock.setsockopt(socket.IPPROTO_IP, 25, struct.pack('I', iface_index))
        return
    raise OSError('cannot bind the probe socket to %s (%s)' % (iface, bind_error))

# ── Shared reply state (sniffer callback / socket loop) ──────────────────
lock    = threading.Lock()
got_any = threading.Event()
current = {'xid': None, 't0': None, 'replies': []}

def record_reply(bootp, sender_ip):
    xid, info = parse_reply(bootp, sender_ip)
    if xid is None:
        return
    now = time.monotonic()
    with lock:
        if current['xid'] != xid or current['t0'] is None:
            return
        info['elapsed_ms'] = round((now - current['t0']) * 1000, 1)
        current['replies'].append(info)
        if info['message_type'] == 2:
            got_any.set()

# ── Receive path 1: scapy BPF sniffer + layer-2 send ─────────────────────
receive_method = "socket"
send_method    = "socket"
sniffer        = None
l2sock         = None
scapy_mods     = None
try:
    from scapy.all import Ether, IP, UDP, BOOTP, DHCP, AsyncSniffer, conf  # noqa: F401
    conf.verb = 0
    scapy_mods = (Ether, IP, UDP, BOOTP, DHCP, AsyncSniffer, conf)
except Exception as exc:  # scapy missing or broken: socket implementation below
    notes.append("scapy unavailable (%s); using the socket probe" % exc.__class__.__name__)

if scapy_mods is not None:
    Ether, IP, UDP, BOOTP, DHCP, AsyncSniffer, conf = scapy_mods

    def on_packet(pkt):
        try:
            if BOOTP in pkt and IP in pkt:
                record_reply(bytes(pkt[BOOTP]), pkt[IP].src)
        except Exception:
            pass

    try:
        started = threading.Event()
        sniffer = AsyncSniffer(iface=iface,
                               filter="udp and src port 67 and dst port 68",
                               store=False, prn=on_packet, promisc=False,
                               started_callback=started.set)
        sniffer.start()
        if not started.wait(3.0):
            exc = getattr(sniffer, 'exception', None)
            raise RuntimeError(str(exc) if exc else "sniffer did not start")
        time.sleep(0.2)
        if not sniffer.running:
            exc = getattr(sniffer, 'exception', None)
            raise RuntimeError(str(exc) if exc else "sniffer stopped immediately")
        receive_method = "bpf"
    except Exception as exc:
        notes.append("packet sniffer unavailable on %s (%s); using the socket receiver" % (iface, exc))
        try:
            if sniffer is not None:
                sniffer.stop()
        except Exception:
            pass
        sniffer = None

    if sniffer is not None:
        try:
            l2sock = conf.L2socket(iface=iface)
            send_method = "layer2"
        except Exception as exc:
            notes.append("layer-2 send unavailable on %s (%s); sending through a UDP socket" % (iface, exc))
            l2sock = None

# ── Receive path 2 / send fallback: UDP sockets ──────────────────────────
recv_sock = None
send_sock = None
use_raw   = False

def open_send_socket():
    """DGRAM socket bound to port 68 when possible (RFC source port), else unbound."""
    global send_sock
    if send_sock is not None:
        return send_sock
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, 'SO_REUSEPORT'):
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        s.bind(('', 68))
    except OSError:
        notes.append("UDP port 68 is held by another process; probes sent from an ephemeral port")
    pin_sock_to_iface(s)
    send_sock = s
    return s

if sniffer is None:
    # 1. SOCK_DGRAM bound to 68 (macOS: the system client uses BPF, so 68 is free).
    # 2. SOCK_RAW(IPPROTO_UDP) when 68 is held (Linux dhclient/networkd).
    recv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    recv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, 'SO_REUSEPORT'):
        try:
            recv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
    recv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        recv_sock.bind(('', 68))
        send_sock = recv_sock          # same socket: source port 68
    except OSError:
        recv_sock.close()
        try:
            recv_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_UDP)
            use_raw = True
            notes.append("UDP port 68 is held by another process; receiving through a raw socket")
        except PermissionError:
            print(json.dumps({"error": "probe_error: cannot bind port 68 and raw socket requires root",
                              "notes": notes}))
            sys.exit(0)
    try:
        pin_sock_to_iface(recv_sock)
        if send_sock is None:
            open_send_socket()
    except OSError as exc:
        print(json.dumps({"error": "probe_error: %s" % exc, "notes": notes}))
        sys.exit(0)

def send_discover(pkt_bytes, xid, secs):
    """Send one DISCOVER; returns the send method actually used."""
    global l2sock, send_method
    if l2sock is not None:
        try:
            frame = (Ether(src=mac_str, dst="ff:ff:ff:ff:ff:ff")
                     / IP(src="0.0.0.0", dst="255.255.255.255")
                     / UDP(sport=68, dport=67)
                     / BOOTP(op=1, htype=1, hlen=6, xid=xid, secs=secs, flags=0x8000,
                             chaddr=mac_bytes + b"\x00" * 10)
                     / DHCP(options=[("message-type", "discover"),
                                     ("client_id", b"\x01" + mac_bytes),
                                     ("param_req_list", [1, 3, 6, 15, 51, 54]),
                                     ("max_dhcp_size", 1500),
                                     ("hostname", b"lss-audit"),
                                     "end"]))
            l2sock.send(frame)
            return "layer2"
        except Exception as exc:
            notes.append("layer-2 send failed on %s (%s); remaining probes use a UDP socket" % (iface, exc))
            try:
                l2sock.close()
            except Exception:
                pass
            l2sock = None
            send_method = "socket"
    s = open_send_socket()
    s.sendto(pkt_bytes, ('255.255.255.255', 67))
    return "socket"

def wait_for_replies(deadline):
    """Block until the first OFFER (+ grace window) or the deadline."""
    if sniffer is not None:
        if got_any.wait(max(0.0, deadline - time.monotonic())):
            time.sleep(GRACE_WINDOW)
        return
    grace_until = None
    while True:
        now = time.monotonic()
        limit = deadline if grace_until is None else min(deadline, grace_until)
        remaining = limit - now
        if remaining <= 0:
            return
        recv_sock.settimeout(remaining)
        try:
            raw, addr = recv_sock.recvfrom(2048)
        except socket.timeout:
            return
        if use_raw:
            bootp, src_ip = extract_bootp_from_raw(raw)
        else:
            bootp, src_ip = raw, addr[0]
        if bootp is None:
            continue
        record_reply(bootp, src_ip)
        if grace_until is None and got_any.is_set():
            grace_until = time.monotonic() + GRACE_WINDOW

# ── Probe loop ───────────────────────────────────────────────────────────
per_probe = []     # list of reply lists (one per probe)
first_ms  = []     # first OFFER latency per probe (None when none)
try:
    for i in range(probe_count):
        xid = random.randint(1, 0xffffffff)
        pkt = make_dhcp_discover(xid, secs=i)
        with lock:
            current['xid'] = xid
            current['t0'] = None
            current['replies'] = []
        got_any.clear()
        t0 = time.monotonic()
        with lock:
            current['t0'] = t0
        send_discover(pkt, xid, i)
        wait_for_replies(t0 + PROBE_TIMEOUT)
        with lock:
            replies = list(current['replies'])
            current['xid'] = None
        per_probe.append(replies)
        offers = [r for r in replies if r['message_type'] == 2]
        first_ms.append(min(r['elapsed_ms'] for r in offers) if offers else None)
        if i < probe_count - 1:
            time.sleep(PROBE_INTERVAL)
except Exception as exc:
    print(json.dumps({"error": "probe_error: %s" % exc, "notes": notes,
                      "receive_method": receive_method, "send_method": send_method}))
    sys.exit(0)
finally:
    try:
        if sniffer is not None:
            sniffer.stop()
    except Exception:
        pass
    for s in (l2sock, recv_sock, send_sock):
        try:
            if s is not None:
                s.close()
        except Exception:
            pass

# ── Aggregate ────────────────────────────────────────────────────────────
servers = {}            # ip -> list of elapsed_ms for OFFERs
first_seen_order = []
offered = {'router': None, 'dns': [], 'domain': None, 'lease_time': None}
for replies in per_probe:
    for r in replies:
        if r['message_type'] != 2:
            continue
        ip = r['server_id']
        if ip not in servers:
            servers[ip] = []
            first_seen_order.append(ip)
        servers[ip].append(r['elapsed_ms'])
        if offered['router'] is None and r.get('router'):
            offered['router'] = r['router']
        if not offered['dns'] and r.get('dns'):
            offered['dns'] = r['dns']
        if offered['domain'] is None and r.get('domain'):
            offered['domain'] = r['domain']
        if offered['lease_time'] is None and r.get('lease_time') is not None:
            offered['lease_time'] = r['lease_time']

responded = [m for m in first_ms if m is not None]
loss_pct  = round((probe_count - len(responded)) / probe_count * 100, 1) if probe_count else None
avg_ms    = round(sum(responded) / len(responded), 1) if responded else None
min_ms    = min(responded) if responded else None
max_ms    = max(responded) if responded else None

server_ip = None
if first_seen_order:
    best = max(len(servers[ip]) for ip in first_seen_order)
    server_ip = next(ip for ip in first_seen_order if len(servers[ip]) == best)

servers_seen = {}
for ip in first_seen_order:
    ms = servers[ip]
    servers_seen[ip] = {
        'offers': len(ms),
        'min_ms': min(ms),
        'avg_ms': round(sum(ms) / len(ms), 1),
        'max_ms': max(ms),
    }

print(json.dumps({
    "probe_count":         probe_count,
    "responded_count":     len(responded),
    "response_times_ms":   first_ms,
    "min_ms":              min_ms,
    "avg_ms":              avg_ms,
    "max_ms":              max_ms,
    "packet_loss_percent": loss_pct,
    "server_ip":           server_ip,
    "servers_seen":        servers_seen,
    "multiple_responders": len(servers_seen) > 1,
    "offered_router":      offered['router'],
    "offered_dns":         offered['dns'],
    "offered_domain":      offered['domain'],
    "lease_time_seconds":  offered['lease_time'],
    "receive_method":      receive_method,
    "send_method":         send_method,
    "probe_mac":           mac_str,
    "probe_mac_source":    probe_mac_source,
    "probe_options":       PROBE_OPTIONS,
    "interval_seconds":    int(PROBE_INTERVAL),
    "notes":               notes,
}))
PYEOF

  local py_result
  local py_stderr_log
  py_stderr_log="$(mktemp /tmp/lss-dhcp-rt-stderr-XXXXXX)"
  py_result="$(python3 "$tmp_py" "$iface" "$probe_count" "$probe_mac" "$is_wifi" 2>"$py_stderr_log" || echo '{"error":"python_failed"}')"
  rm -f "$tmp_py"

  # Surface stderr into the JSON error if the script itself crashed
  if [[ "$(jq -r '.error // empty' <<< "$py_result" 2>/dev/null)" == "python_failed" ]]; then
    local stderr_content
    stderr_content="$(cat "$py_stderr_log" 2>/dev/null | head -3 | tr '\n' ' ')" || true
    py_result="$(jq -n --arg e "python_failed: ${stderr_content}" '{error: $e}')"
  fi
  if [[ -s "$py_stderr_log" ]]; then
    copy_raw_artifact "$py_stderr_log" "$(task_raw_prefix 5)-probe-stderr.txt" 2>/dev/null || true
  fi
  rm -f "$py_stderr_log"

  if [[ -z "$py_result" ]] || ! jq -e 'type == "object"' <<< "$py_result" >/dev/null 2>&1; then
    py_result='{"error":"probe_error: the probe produced no result"}'
  fi

  local receive_method send_method
  receive_method="$(jq -r '.receive_method // empty' <<< "$py_result")"
  send_method="$(jq -r '.send_method // empty' <<< "$py_result")"

  if [[ "$(jq -r '.error // empty' <<< "$py_result")" != "" ]]; then
    local err_msg
    err_msg="$(jq -r '.error' <<< "$py_result")"
    echo "Error: $err_msg"
    # A probe that could not run is not a DHCP outage: loss is unknown (null).
    jq -n \
      --arg iface "$iface" \
      --arg err "$err_msg" \
      --argjson probe_count "$probe_count" \
      --argjson is_wifi "$is_wifi" \
      --arg probe_mac "$probe_mac" \
      --arg receive_method "$receive_method" \
      --arg send_method "$send_method" \
      --argjson notes "$(jq -c '.notes // []' <<< "$py_result")" \
      '{status:"failed",success:false,error:{code:"PROBE_FAILED",message:$err},warnings:$notes,interface:$iface,is_wifi:$is_wifi,probe_count:$probe_count,responded_count:0,response_times_ms:[],min_ms:null,avg_ms:null,max_ms:null,packet_loss_percent:null,server_ip:null,servers_seen:{},multiple_responders:false,receive_method:(if $receive_method == "" then null else $receive_method end),send_method:(if $send_method == "" then null else $send_method end),probe_mac:(if $probe_mac == "" then null else $probe_mac end),indicators:{slow_response:false,high_loss:false,probe_inconsistent:false,server_mismatch:false}}' > "$json_file"
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

  local probe_note
  while IFS= read -r probe_note; do
    [[ -n "$probe_note" ]] && warnings+=("Probe note: $probe_note")
  done < <(jq -r '(.notes // [])[]' <<< "$py_result" 2>/dev/null)

  echo "Method:      receive=${receive_method:-unknown} send=${send_method:-unknown}"
  echo "Responded:   $responded_count / $probe_count"
  echo "Loss:        ${packet_loss}%"
  if [[ "$avg_ms" != "null" && -n "$avg_ms" ]]; then
    echo "Min/Avg/Max: ${min_ms} / ${avg_ms} / ${max_ms} ms"
  fi
  [[ -n "$server_ip_val" ]] && echo "DHCP Server: $server_ip_val"
  jq -r '(.servers_seen // {}) | to_entries[] | "Responder:   \(.key)  offers \(.value.offers)  min/avg/max \(.value.min_ms)/\(.value.avg_ms)/\(.value.max_ms) ms"' <<< "$py_result" 2>/dev/null || true
  jq -r 'if (.offered_router // .offered_domain // .lease_time_seconds // ((.offered_dns // []) | length > 0)) then "Offered:     router \(.offered_router // "n/a"), DNS \((.offered_dns // []) | if length > 0 then join(" ") else "n/a" end), domain \(.offered_domain // "n/a"), lease \(if .lease_time_seconds then (.lease_time_seconds | tostring) + " s" else "n/a" end)" else empty end' <<< "$py_result" 2>/dev/null || true

  # --- Cross-check with Task 4 (discovery) from the same run ---
  local ind_inconsistent=false ind_mismatch=false
  local unexpected_servers=()
  local t4_file t4_responders=0 t4_servers_json='[]' t4_lease_server="" seen_ip
  t4_file="$(task_output_path 4 2>/dev/null || true)"
  if [[ -n "$t4_file" ]] && json_file_usable "$t4_file"; then
    t4_responders="$(jq -r '.dhcp_responders_observed // 0' "$t4_file" 2>/dev/null)"
    [[ "$t4_responders" =~ ^[0-9]+$ ]] || t4_responders=0
    t4_servers_json="$(jq -c '[.servers[]?.ip // empty]' "$t4_file" 2>/dev/null || echo '[]')"
    t4_lease_server="$(jq -r '.system_lease.server // empty' "$t4_file" 2>/dev/null || true)"
    if [[ "$t4_responders" -gt 0 && "$responded_count" -eq 0 ]]; then
      ind_inconsistent=true
      local t4_ips
      t4_ips="$(jq -r 'join(", ")' <<< "$t4_servers_json")"
      warnings+=("Task 4 observed ${t4_responders} DHCP offer(s) from ${t4_ips:-unknown} on this interface a moment ago; this probe received none — treat it as a probe or receive-path problem, not a DHCP outage.")
      echo "Warning: discovery (Task 4) saw $t4_responders responder(s) but this probe received no offer."
    fi
    while IFS= read -r seen_ip; do
      [[ -z "$seen_ip" ]] && continue
      # The server that leased this interface its address is expected, even
      # when discovery (nmap's probe) never received its offer.
      [[ -n "$t4_lease_server" && "$seen_ip" == "$t4_lease_server" ]] && continue
      if ! jq -e --arg ip "$seen_ip" 'index($ip) != null' <<< "$t4_servers_json" >/dev/null 2>&1; then
        if [[ "$t4_responders" -eq 0 ]]; then
          # Discovery saw no offer at all (DHCP snooping dropping nmap's probe
          # is the usual cause; Task 4's own evidence field explains the gap):
          # name the responder, but it is not evidence of a second server.
          warnings+=("Responder ${seen_ip} answered the probe although discovery (Task 4) received no offer at all; the discovery probe was most likely dropped — this is not evidence of a second DHCP server.")
          echo "Note: responder $seen_ip answered although discovery (Task 4) received no offer."
          continue
        fi
        ind_mismatch=true
        unexpected_servers+=("$seen_ip")
        warnings+=("Responder ${seen_ip} answered the probe but was not seen by discovery — possible second DHCP server.")
        echo "Warning: responder $seen_ip was not seen by discovery (Task 4)."
      fi
    done < <(jq -r '(.servers_seen // {}) | keys[]' <<< "$py_result" 2>/dev/null)
    if [[ -n "$t4_lease_server" && -n "$server_ip_val" && "$t4_lease_server" != "$server_ip_val" ]]; then
      warnings+=("The responder (${server_ip_val}) differs from the server that leased this interface its address (${t4_lease_server}).")
    fi
  fi

  # --- Subnet utilization estimate ---
  local network prefix_len usable_hosts live_hosts util_pct util_json
  local ind_util=false
  network="$(get_interface_network_cidr "$iface" 2>/dev/null || true)"
  usable_hosts="null"
  live_hosts="null"
  util_pct="null"
  util_json='{"usable_hosts":null,"live_hosts":null,"utilization_percent":null,"high_utilization":false,"note":"subnet too large to scan quickly"}'

  if [[ -n "$network" ]]; then
    prefix_len="${network##*/}"
    # /22 (1022 hosts) is the largest sweep that finishes in reasonable time;
    # a /16 ping scan could freeze the UI for many minutes with no progress.
    if [[ "$prefix_len" -ge 22 && "$prefix_len" -le 32 ]]; then
      usable_hosts=$(( (1 << (32 - prefix_len)) - 2 ))
      [[ "$usable_hosts" -lt 0 ]] && usable_hosts=0
      echo "Subnet utilization: scanning $network for live hosts..."
      emit_stage 5 utilization "Sweeping $network for live hosts"
      local util_scan_file util_pid
      util_scan_file="$(mktemp /tmp/lss-dhcp-util-XXXXXX)"
      nmap -sn -n --host-timeout 5s "$network" > "$util_scan_file" 2>/dev/null &
      util_pid=$!
      register_bg_pid "$util_pid"
      spinner "Sweeping $network for live hosts..."
      wait "$util_pid" 2>/dev/null || true
      unregister_bg_pid "$util_pid"
      live_hosts="$(grep -c "Host is up" "$util_scan_file" 2>/dev/null || true)"
      rm -f "$util_scan_file"
      live_hosts="${live_hosts:-0}"
      if [[ "$usable_hosts" -gt 0 ]]; then
        util_pct="$(awk "BEGIN{printf \"%.1f\", $live_hosts / $usable_hosts * 100}")"
        echo "Live Hosts:  $live_hosts / $usable_hosts usable (${util_pct}%)"
        if awk "BEGIN{exit !($util_pct >= 80)}"; then
          warnings+=("DHCP pool utilization is high: ${util_pct}% of usable addresses have live hosts (${live_hosts}/${usable_hosts}). Pool exhaustion risk — consider expanding the subnet or reclaiming stale leases.")
          ind_util=true
        elif awk "BEGIN{exit !($util_pct >= 60)}"; then
          warnings+=("DHCP pool utilization is moderate: ${util_pct}% of usable addresses have live hosts (${live_hosts}/${usable_hosts}). Monitor for growth.")
          ind_util=true
        fi
        util_json="$(jq -n \
          --argjson usable "$usable_hosts" \
          --argjson live "$live_hosts" \
          --arg pct "$util_pct" \
          --argjson high "$ind_util" \
          '{usable_hosts:$usable,live_hosts:$live,utilization_percent:($pct|tonumber),high_utilization:$high,note:"estimated from nmap ping scan; reflects responding hosts, not actual DHCP lease count"}')"
      else
        util_json='{"usable_hosts":0,"live_hosts":null,"utilization_percent":null,"high_utilization":false,"note":"subnet too small to estimate"}'
      fi
    else
      echo "Subnet utilization: skipped (subnet /$prefix_len is too large to scan quickly)"
    fi
  fi

  local ind_slow=false ind_loss=false

  if [[ "$responded_count" -eq 0 ]]; then
    if [[ "$ind_inconsistent" == "true" ]]; then
      warnings+=("No DHCP Offer was received for any of the $probe_count Discover probes, although discovery saw the server answer. Check the receive path (receive=${receive_method:-unknown}, send=${send_method:-unknown}) before suspecting the DHCP service.")
    else
      warnings+=("No DHCP Offer was received for any of the $probe_count Discover probes. Verify DHCP service is active and reachable on this interface.")
    fi
    ind_loss=true
    status="completed_with_warnings"
  else
    if awk "BEGIN{exit !($packet_loss > 0)}"; then
      if $is_wifi && awk "BEGIN{exit !($packet_loss <= 10)}"; then
        warnings+=("Packet loss observed: ${packet_loss}% of DHCP Discover probes received no Offer. A single lost broadcast is normal radio behaviour on Wi-Fi.")
      else
        warnings+=("Packet loss observed: ${packet_loss}% of DHCP Discover probes received no Offer.")
        ind_loss=true
      fi
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
  if [[ "$ind_inconsistent" == "true" || "$ind_mismatch" == "true" ]]; then
    status="completed_with_warnings"
  fi
  if [[ "$(jq -r '.multiple_responders // false' <<< "$py_result")" == "true" ]]; then
    warnings+=("More than one DHCP server answered the probes: $(jq -r '(.servers_seen // {}) | keys | join(", ")' <<< "$py_result").")
    status="completed_with_warnings"
  fi

  warnings_json="$(printf '%s\n' "${warnings[@]+"${warnings[@]}"}" | jq -Rs '[split("\n")[] | select(length > 0)]')"

  local times_json
  times_json="$(jq -c '.response_times_ms' <<< "$py_result")"

  local avg_arg min_arg max_arg
  avg_arg="$(jq -c '.avg_ms' <<< "$py_result")"
  min_arg="$(jq -c '.min_ms' <<< "$py_result")"
  max_arg="$(jq -c '.max_ms' <<< "$py_result")"

  local methodology
  case "${receive_method}/${send_method}" in
    bpf/layer2)
      methodology="DHCP Discover-to-Offer latency measured with scapy: each Discover is sent as a raw Ethernet frame (source 0.0.0.0:68, broadcast flag, chaddr = interface MAC, options 53/55/57/61/12) and every Offer is captured with a BPF packet sniffer started before the first probe, so unicast and broadcast replies are both seen. Probes are 1 s apart with a 5 s wait each; the first Offer per probe is timed with a monotonic clock. Results reflect point-in-time conditions."
      ;;
    bpf/*)
      methodology="DHCP Discover-to-Offer latency measured with a BPF packet sniffer for the replies and a UDP socket (source port 68 when available) for the Discover packets, which carry chaddr = interface MAC and options 53/55/57/61/12. Probes are 1 s apart with a 5 s wait each; the first Offer per probe is timed with a monotonic clock. Results reflect point-in-time conditions."
      ;;
    *)
      methodology="DHCP Discover-to-Offer latency measured using UDP broadcast probes from a socket bound to port 68 (chaddr = interface MAC, options 53/55/57/61/12); Offers are received on the same socket (or a raw socket when port 68 is held by the system client). Probes are 1 s apart with a 5 s wait each. Offers unicast to another MAC cannot be seen on this path; compare with Task 4 before concluding a server is slow or absent."
      ;;
  esac

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
    --argjson ind_util "$ind_util" \
    --argjson ind_inconsistent "$ind_inconsistent" \
    --argjson ind_mismatch "$ind_mismatch" \
    --argjson unexpected_servers "$(json_string_array_from_array unexpected_servers)" \
    --argjson is_wifi "$is_wifi" \
    --argjson warnings "$warnings_json" \
    --argjson util "$util_json" \
    --argjson probe "$py_result" \
    --arg methodology "$methodology" \
    '{
      status:               $status,
      success:              $success,
      error:                null,
      warnings:             $warnings,
      methodology:          $methodology,
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
      servers_seen:         ($probe.servers_seen // {}),
      multiple_responders:  ($probe.multiple_responders // false),
      unexpected_servers:   $unexpected_servers,
      offered_router:       ($probe.offered_router // null),
      offered_dns:          ($probe.offered_dns // []),
      offered_domain:       ($probe.offered_domain // null),
      lease_time_seconds:   ($probe.lease_time_seconds // null),
      receive_method:       ($probe.receive_method // null),
      send_method:          ($probe.send_method // null),
      probe_mac:            ($probe.probe_mac // null),
      probe_mac_source:     ($probe.probe_mac_source // null),
      probe_options:        ($probe.probe_options // "53,55,57,61,12"),
      interval_seconds:     ($probe.interval_seconds // 1),
      subnet_utilization:   $util,
      indicators: {
        slow_response:      $ind_slow,
        high_loss:          $ind_loss,
        high_utilization:   $ind_util,
        probe_inconsistent: $ind_inconsistent,
        server_mismatch:    $ind_mismatch
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
    local w=16
    printf "  %-${w}s %s\n" "Status:"        "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
    printf "  %-${w}s %s\n" "Interface:"     "${iface:-unknown}"
    printf "  %-${w}s %s\n" "IP Address:"    "${ip:-unknown}"
    printf "  %-${w}s %s\n" "Subnet Mask:"   "${subnet:-unknown}"
    printf "  %-${w}s %s\n" "Network Range:" "${network:-unknown}"
    printf "  %-${w}s %s\n" "Gateway:"       "${gateway:-unknown}"
    printf "  %-${w}s %s\n" "MAC Address:"   "${mac:-unknown}"
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

  local w=16
  if [[ "$status" == "skipped" ]]; then
    local skip_message
    skip_message="$(jq -r '.skip_message // "Scan was skipped."' "$file" 2>/dev/null)"
    {
      printf "  %-${w}s %s\n" "Status:"     "skipped"
      printf "  %-${w}s %s\n" "Gateway IP:" "${gateway:-unknown}"
      printf "  %-${w}s %s\n" "Reason:"     "$skip_message"
    } >> "$report_file"
    return 0
  fi

  {
    printf "  %-${w}s %s\n" "Status:"        "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
    printf "  %-${w}s %s\n" "Gateway IP:"    "${gateway:-unknown}"
    printf "  %-${w}s %s\n" "Open Ports:"    "${ports:-none found}"
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
    local w=26
    printf "  %-${w}s %s\n" "Status:"                   "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
    printf "  %-${w}s %s\n" "Gateway IP:"                "${gateway}"
    printf "  %-${w}s %s\n" "Interface:"                 "${iface}"
    printf "  %-${w}s %s\n" "Completed With Warnings:"   "${completed_with_warnings}"
    [[ -n "$warning" ]]      && printf "  %-${w}s %s\n" "Warning:"       "$warning"
    [[ -n "$stage_status" ]] && printf "  %-${w}s %s\n" "Stage Status:"  "$stage_status"
    printf "  %-${w}s %s\n" "Baseline Avg Latency:"      "${baseline_avg} ms"
    printf "  %-${w}s %s\n" "Sustained Avg Latency:"     "${sustained_avg} ms"
    printf "  %-${w}s %s\n" "High Jitter:"               "${high_jitter}"
    printf "  %-${w}s %s\n" "Latency Under Load:"        "${latency_under_load}"
    printf "  %-${w}s %s\n" "Packet Loss Detected:"      "${packet_loss}"
    printf "  %-${w}s %s\n" "Slow Recovery:"             "${slow_recovery}"
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
    local w=26
    printf "  %-${w}s %s\n" "Status:"                  "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
      jq -r '(.warnings // [])[] | "    - " + .' "$file" 2>/dev/null || true
    fi
    printf "  %-${w}s %s\n" "Interface:"               "${iface}"
    printf "  %-${w}s %s\n" "Tagged Frames (802.1Q):"  "${tagged_frames_observed}"
    printf "  %-${w}s %s\n" "Observed VLAN IDs:"       "${observed_vlan_ids}"
    printf "  %-${w}s %s\n" "Trunk Port Suspected:"    "$(jq -r '.indicators.trunk_port_suspected // false' "$file" 2>/dev/null)"
    printf "  %-${w}s %s\n" "Multiple VLANs Visible:"  "$(jq -r '.indicators.multiple_vlans_visible // false' "$file" 2>/dev/null)"
    printf "  %-${w}s %s\n" "CDP/LLDP Frames Seen:"    "$(jq -r '.indicators.cdp_exposed // false' "$file" 2>/dev/null)"
    echo ""
    if [[ "$cdp_count" -gt 0 ]]; then
      echo "  CDP Neighbours (${cdp_count}):"
      jq -r '.cdp_neighbours[]? |
        "    Device ID:    " + .device_id,
        "    Platform:     " + .platform,
        "    Port ID:      " + .port_id,
        "    Native VLAN:  " + (if .native_vlan != null then (.native_vlan | tostring) else "unknown" end),
        "    VTP Domain:   " + (if .vtp_domain != "" then .vtp_domain else "none" end),
        "    Duplex:       " + (if .duplex != "" then .duplex else "unknown" end),
        ""' "$file" 2>/dev/null || true
    else
      echo "  CDP Neighbours:  none detected"
    fi
    if [[ "$lldp_count" -gt 0 ]]; then
      echo "  LLDP Neighbours (${lldp_count}):"
      jq -r '.lldp_neighbours[]? |
        "    System Name:  " + .system_name,
        "    Chassis ID:   " + .chassis_id,
        "    Port ID:      " + .port_id,
        "    Description:  " + (if .system_description != "" then .system_description else "none" end),
        ""' "$file" 2>/dev/null || true
    else
      echo "  LLDP Neighbours: none detected"
    fi
    echo "  Double-Tag Probe: not attempted"
  } >> "$report_file"
}

render_dhcp_report() {
  local file="$1"
  local report_file="$2"
  local found
  local attempts
  local attempts_failed
  local offers_observed
  local raw_offers_observed
  local rogue_suspected
  local probe_mac evidence
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"
  found="$(jq -r '.dhcp_responders_observed // .dhcp_servers_found // 0' "$file" 2>/dev/null)"
  attempts="$(jq -r '.discovery_attempts // 1' "$file" 2>/dev/null)"
  attempts_failed="$(jq -r '.attempts_failed // empty' "$file" 2>/dev/null)"
  offers_observed="$(jq -r '.offers_observed // 0' "$file" 2>/dev/null)"
  raw_offers_observed="$(jq -r '.raw_offers_observed // .offers_observed // 0' "$file" 2>/dev/null)"
  rogue_suspected="$(jq -r '.rogue_dhcp_suspected // false' "$file" 2>/dev/null)"
  probe_mac="$(jq -r '.probe_mac // empty' "$file" 2>/dev/null)"
  evidence="$(jq -r '.evidence // empty' "$file" 2>/dev/null)"

  {
    local w=28
    printf "  %-${w}s %s\n" "Status:"                     "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
    printf "  %-${w}s %s\n" "DHCP Responders Observed:"   "${found:-0}"
    printf "  %-${w}s %s\n" "Discovery Attempts:"         "${attempts:-1}"
    [[ -n "$attempts_failed" && "$attempts_failed" != "0" ]] && printf "  %-${w}s %s\n" "Attempts Failed:" "$attempts_failed"
    printf "  %-${w}s %s\n" "Unique Offers Observed:"     "${offers_observed:-0}"
    printf "  %-${w}s %s\n" "Raw Offers Captured:"        "${raw_offers_observed:-0}"
    [[ -n "$probe_mac" ]] && printf "  %-${w}s %s\n" "Probe MAC:" "$probe_mac$(jq -r 'if .probe_mac_source then " (" + .probe_mac_source + ")" else "" end' "$file" 2>/dev/null)"
    [[ -n "$evidence" ]] && printf "  %-${w}s %s\n" "Evidence:" "$evidence"
    printf "  %-${w}s %s\n" "Possible Rogue DHCP Present:" "${rogue_suspected}"
  } >> "$report_file"

  # The lease the operating system itself holds on the audited interface.
  jq -r '
    if .system_lease and .system_lease.server then
      "  System Lease:                server " + .system_lease.server
      + (if .system_lease.assigned_ip then ", assigned " + .system_lease.assigned_ip else "" end)
      + (if .system_lease.router then ", router " + .system_lease.router else "" end)
      + (if ((.system_lease.dns // []) | length) > 0 then ", DNS " + ((.system_lease.dns // []) | join(" ")) else "" end)
      + (if .system_lease.domain then ", domain " + .system_lease.domain else "" end)
      + (if .system_lease.lease_time_seconds then ", lease " + (.system_lease.lease_time_seconds | tostring) + " s" else "" end)
      + (if .system_lease.obtained_at then ", obtained " + .system_lease.obtained_at else "" end)
      + (if .system_lease.source then " (" + .system_lease.source + ")" else "" end)
    elif has("system_lease") then "  System Lease:                none (static address or no lease found)"
    else empty end' "$file" >> "$report_file" 2>/dev/null || true

  jq -r 'if ((.dns_servers_offered // []) | length) > 0 then "  DNS Servers Offered:         " + ((.dns_servers_offered // []) | join(", ")) else empty end' "$file" >> "$report_file" 2>/dev/null || true

  # Warning texts are the most useful part of this task's output; the count
  # alone told the reader nothing.
  jq -r '(.warnings // [])[] | "    - " + .' "$file" >> "$report_file" 2>/dev/null || true

  # Capture evidence: real relay agents (giaddr / forwarders), every UDP/67
  # sender with its MAC, and servers only seen passively.
  jq -r '
    ((.relay_agents_seen // .relay_sources_seen) // []) as $relays |
    ((.servers // []) | map(.ip)) as $responders |
    (if has("relay_agents_seen") then $relays else ($relays - $responders) end) as $relay_only |
    if ($relay_only | length) > 0 then
      "  Relay Agents:                " + ($relay_only | join(", "))
    else empty end
  ' "$file" >> "$report_file"
  jq -r '
    if ((.reply_sources_seen // []) | length) > 0 then
      "  Reply Sources (UDP/67):      " + ((.reply_sources_seen // []) | map(.ip + (if .mac then " (" + .mac + ")" else "" end)) | join(", "))
    else empty end' "$file" >> "$report_file" 2>/dev/null || true
  jq -r '
    if ((.passive_servers_seen // []) | length) > 0 then
      "  Servers Seen Passively:      " + ((.passive_servers_seen // []) | join(", "))
    else empty end' "$file" >> "$report_file" 2>/dev/null || true
  jq -r '
    if .capture_message_types then
      "  Captured Message Types:      " + (.capture_message_types | to_entries | map(.key + " " + (.value | tostring)) | join(", "))
    else empty end' "$file" >> "$report_file" 2>/dev/null || true

  jq -r '.servers[]? | "  - DHCP Responder \(.ip) | Unique Offers: \(.offers_observed // 0) | Raw Offers: \(.raw_offers_observed // .offers_observed // 0) | Classification: \(.classification // "unknown") | Suspected Rogue: \(.suspected_rogue // false)" + (if ((.rogue_reasons // []) | length) > 0 then " (" + ((.rogue_reasons // []) | join(", ")) + ")" else "" end) + " | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end)"' "$file" >> "$report_file"
  jq -r '.servers[]? | select(.offered_router or .offered_subnet_mask or .offered_domain or .lease_time_seconds or .responder_mac or (((.offered_dns // []) | length) > 0)) |
    "      " + .ip + ": offered router \(.offered_router // "n/a"), subnet mask \(.offered_subnet_mask // "n/a"), DNS \((.offered_dns // []) | if length > 0 then join(" ") else "n/a" end), domain \(.offered_domain // "n/a"), lease \(if .lease_time_seconds then (.lease_time_seconds | tostring) + " s" else "n/a" end), responder MAC \(.responder_mac // "not captured")"' "$file" >> "$report_file" 2>/dev/null || true

  jq -r 'if (.suspected_rogue_servers // []) | length > 0 then "  Suspected Rogue Responders: \((.suspected_rogue_servers // []) | join(", "))" else empty end' "$file" >> "$report_file"
}

render_dhcp_response_time_report() {
  local file="$1"
  local report_file="$2"
  local status error_code error_message warning_count
  local iface probe_count responded_count avg_ms min_ms max_ms loss server_ip
  local receive_method send_method probe_mac

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
  loss="$(          jq -r 'if .packet_loss_percent == null then "not measured" else (.packet_loss_percent | tostring) + "%" end' "$file" 2>/dev/null)"
  server_ip="$(     jq -r '.server_ip // "unknown"'         "$file" 2>/dev/null)"
  receive_method="$(jq -r '.receive_method // empty'        "$file" 2>/dev/null)"
  send_method="$(   jq -r '.send_method // empty'           "$file" 2>/dev/null)"
  probe_mac="$(     jq -r '.probe_mac // empty'             "$file" 2>/dev/null)"

  {
    local w=18
    printf "  %-${w}s %s\n" "Status:"          "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
      jq -r '(.warnings // [])[] | "    - " + .' "$file" 2>/dev/null || true
    fi
    printf "  %-${w}s %s\n" "Interface:"       "$iface"
    [[ -n "$receive_method" || -n "$send_method" ]] && printf "  %-${w}s %s\n" "Probe Method:" "receive=${receive_method:-unknown} send=${send_method:-unknown}"
    [[ -n "$probe_mac" ]] && printf "  %-${w}s %s\n" "Probe MAC:" "$probe_mac"
    printf "  %-${w}s %s\n" "DHCP Server:"     "$server_ip"
    printf "  %-${w}s %s\n" "Probes Sent:"     "$probe_count"
    printf "  %-${w}s %s\n" "Offers Received:" "$responded_count"
    printf "  %-${w}s %s\n" "Packet Loss:"     "${loss}"
    printf "  %-${w}s %s\n" "Min Latency:"     "${min_ms} ms"
    printf "  %-${w}s %s\n" "Avg Latency:"     "${avg_ms} ms"
    printf "  %-${w}s %s\n" "Max Latency:"     "${max_ms} ms"
    jq -r '(.servers_seen // {}) | to_entries[] | "  Responder:         \(.key)  offers \(.value.offers // 0)  min/avg/max \(.value.min_ms // "?")/\(.value.avg_ms // "?")/\(.value.max_ms // "?") ms"' "$file" 2>/dev/null || true
    jq -r 'if (.offered_router or .offered_domain or .lease_time_seconds or (((.offered_dns // []) | length) > 0)) then "  Offered Options:   router \(.offered_router // "n/a"), DNS \((.offered_dns // []) | if length > 0 then join(" ") else "n/a" end), domain \(.offered_domain // "n/a"), lease \(if .lease_time_seconds then (.lease_time_seconds | tostring) + " s" else "n/a" end)" else empty end' "$file" 2>/dev/null || true
    jq -r 'if .indicators.probe_inconsistent == true then "  Cross-check:       discovery (Task 4) saw offers but this probe received none — probe/receive-path problem, not a DHCP outage" else empty end' "$file" 2>/dev/null || true
    jq -r 'if .indicators.server_mismatch == true then "  Cross-check:       responder(s) not seen by discovery: " + ((.unexpected_servers // []) | join(", ")) else empty end' "$file" 2>/dev/null || true
    local util_live util_usable util_pct
    util_live="$(  jq -r '.subnet_utilization.live_hosts // "N/A"'          "$file" 2>/dev/null)"
    util_usable="$(jq -r '.subnet_utilization.usable_hosts // "N/A"'        "$file" 2>/dev/null)"
    util_pct="$(   jq -r '.subnet_utilization.utilization_percent // "N/A"' "$file" 2>/dev/null)"
    if [[ "$util_live" != "N/A" && "$util_live" != "null" ]]; then
      printf "  %-${w}s %s\n" "Pool Utilization:" "${util_pct}%  (${util_live} of ${util_usable} usable addresses have live hosts)"
    fi
    echo ""
    echo "  Per-Probe Results:"
    jq -r '.response_times_ms | to_entries[] | "    Probe \(.key + 1): " + (if .value == null then "no response" else (.value | tostring) + " ms" end)' "$file" 2>/dev/null || true
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
    local w=16
    printf "  %-${w}s %s\n" "Status:"        "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    [[ -n "$warning_count" && "$warning_count" != "0" ]] && printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
    printf "  %-${w}s %s\n" "Network Range:" "${network:-unknown}"
    printf "  %-${w}s %s\n" "Scanned Ports:" "${ports:-unknown}"
    printf "  %-${w}s %s\n" "Servers Found:" "$server_count"
  } >> "$report_file"

  if [[ "$label" == "DNS" ]]; then
    jq -r 'if .range_truncated == true then "  Scanned Range:   " + (.scanned_range // "unknown") + " (capped)" else empty end' "$file" >> "$report_file" 2>/dev/null || true
    jq -r '.servers[]? |
      "  - DNS Host \(.ip)" +
      (if .ptr_hostname then " (\(.ptr_hostname))" else "" end) +
      (if ((.sources // []) | length) > 0 then " [" + ((.sources // []) | join(", ")) + (if .on_subnet == false then ", off-subnet" else "" end) + "]" else "" end) +
      " | Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none confirmed" end)" +
      (if .transport then " | Transport: tcp " + (.transport.tcp // "unknown") + ", udp " + (.transport.udp // "unknown") else "" end) +
      " | External DNS: \(if .resolution_test then (if .resolution_test.resolved then "OK (" + ((.resolution_test.response_ms // "?") | tostring) + " ms" + (if .resolution_test.attempts then ", attempt " + (.resolution_test.attempts | tostring) else "" end) + ")" else "FAILED" + (if .resolution_test.rcode then " (" + .resolution_test.rcode + ")" else "" end) end) else "not tested" end)" +
      (if .resolution_test.recursion then " | Recursion: " + .resolution_test.recursion elif .resolution_test.open_resolver then " | Recursion: enabled" else "" end) +
      (if (.resolution_test.external_private_answer // .resolution_test.rebinding_risk) then " | External name resolved to a private address (DNS filtering or rebinding)" else "" end) +
      (if .resolution_test.internal_test then " | Site domain " + .resolution_test.internal_test.domain + ": " + (if .resolution_test.internal_test.resolved then "resolved" else "not resolved" end) + ", AD SRV " + (if .resolution_test.internal_test.srv_found then "found" else "not found" end) else "" end) +
      (if .gateway_ptr then " | Gateway PTR: \(.gateway_ptr)" else "" end)' "$file" >> "$report_file"
  else
    jq -r --arg lbl "$label" '.servers[]? | "  - \($lbl) Host \(.ip) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end) | Services: \((.detected_services // []) | if length > 0 then join(", ") else "unknown" end)"' "$file" >> "$report_file"
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
    local w=19
    printf "  %-${w}s %s\n" "Status:"          "${status:-unknown}"
    [[ -n "$error_code" ]]    && printf "  %-${w}s %s\n" "Error Code:"    "$error_code"
    [[ -n "$error_message" ]] && printf "  %-${w}s %s\n" "Error Message:" "$error_message"
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      printf "  %-${w}s %s\n" "Warnings:" "$warning_count"
      jq -r '(.warnings // [])[] | "    - " + .' "$file" 2>/dev/null || true
    fi
    printf "  %-${w}s %s\n" "Interface:"       "${iface}"
    printf "  %-${w}s %s\n" "Network Range:"   "${network}"
    printf "  %-${w}s %s\n" "Total Hosts Seen:" "${total_hosts}"
    printf "  %-${w}s %s\n" "Duplicate IPs:"   "${duplicate_count}"
    echo ""
    if [[ "$duplicate_count" -gt 0 ]]; then
      echo "  Conflicting Hosts:"
      jq -r '.duplicates[]? | "    IP: " + .ip + "  MACs: " + (.macs | join(", "))' "$file" 2>/dev/null || true
    else
      echo "  No duplicate IPs detected."
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

  # Without raw-socket privileges nmap prints no MAC addresses and the scan
  # silently degrades to "0 devices"; fail loudly instead.
  if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this scan needs root (ARP discovery and raw UDP). Run with sudo."
    jq -n --arg iface "$iface" --arg subnet "${subnet:-}" \
      '{status:"failed",success:false,error:{code:"insufficient_privileges",message:"UniFi discovery requires root for ARP/MAC discovery. Re-run with sudo."},warnings:[],interface:$iface,subnet:$subnet,devices_found:0,devices:[],false_positives:[]}' \
      > "$json_file"
    validate_json_file "$json_file" || true
    return 1
  fi
  # ── OUI database (monthly cache) ─────────────────────────────────────────
  # The IEEE MA-L registry is fetched at most once per 30 days and cached at
  # /usr/local/share/lss-network-tools/ubiquiti-oui-cache.txt. New Ubiquiti
  # OUI blocks are picked up automatically without a software update.
  local _builtin_oui_count=45
  # Lives in DATA_ROOT so it works on Linux (/var/lib/...) and in portable
  # mode; on macOS this is still /usr/local/share/lss-network-tools.
  local _oui_cache="$DATA_ROOT/ubiquiti-oui-cache.txt"
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

  # ── Helper: one device entry as compact JSON ──────────────────────────────
  # Built with jq so a device-supplied model/hostname containing quotes or
  # backslashes cannot corrupt the output file. Optional 4th arg marks the
  # confidence level ("confirmed" by default, "probable" for banner-only).
  unifi_device_entry() {
    local mac="$1" ip="$2" model="${3:-}" confidence="${4:-confirmed}"
    jq -cn --arg mac "$mac" --arg ip "$ip" --arg model "$model" --arg conf "$confidence" \
      '{mac:$mac, ip:$ip} + (if $model != "" then {model:$model} else {} end)
         + (if $conf != "confirmed" then {confidence:$conf} else {} end)'
  }

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
    # macOS arp strips leading zeros (8:bf:b8:47:f:e0); normalise so the OUI
    # prefix match below works and the JSON carries a well-formed MAC.
    printf '%s' "$(normalize_mac "$mac")"
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
# No timeout: the bash side kills this listener when the scan finishes. A
# fixed 600s cap expired before Step 5 on larger subnets and silently lost
# every LLDP neighbour.
sniff(iface=iface, filter='ether proto 0x88cc', prn=handle, store=0)
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

  emit_stage 18 arp_discovery "Step 1: ARP host discovery on $subnet (5 passes)"
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
  emit_stage 18 udp_sweep "Step 1b: UDP 10001 sweep for IP-routed devices (10 passes)"
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
      | awk '/10001\/open\/udp/{print $2}' | tee -a "$_tmp_udp_raw" >> "$_tmp_udp_confirmed"
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

  emit_stage 18 tlv_fingerprinting "Step 2: TLV fingerprinting — probing $discovered_count host(s) (5 rounds, 15s window)"
  echo "Step 2: TLV fingerprinting — probing $discovered_count host(s) (5 rounds, 15s window)..."
  local tlv_out tlv_confirmed=0
  start_spinner_line "  Sending probes and waiting for responses..."
  local tlv_err
  tlv_err="$(mktemp /tmp/lss-tlv-err-XXXXXX)"
  # shellcheck disable=SC2046
  tlv_out="$(python3 "$tmp_tlv_py" "$broadcast_addr" $(sort -u "$tmp_nmap_ips" | tr '\n' ' ') 2>"$tlv_err" || true)"
  stop_spinner_line
  rm -f "$tmp_tlv_py"
  # A bind failure (something else holding UDP 10001, e.g. the UniFi app on
  # this Mac) used to be swallowed and look like "0 devices confirmed".
  if grep -q 'TLV bind failed' "$tlv_err" 2>/dev/null; then
    echo "  WARNING: $(grep 'TLV bind failed' "$tlv_err" | head -n 1)"
    echo "  Another program is listening on UDP 10001 — close it and re-run for TLV fingerprinting."
  fi
  rm -f "$tlv_err"

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
  emit_stage 18 oui_classification "Step 3: OUI classification"
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
      entries="${entries:+$entries,}$(unifi_device_entry "$mac" "$ip" "$model")"
    else
      flagged_entries="${flagged_entries:+$flagged_entries,}$(unifi_device_entry "$mac" "$ip")"
    fi
  done < <(sort -u "$tmp_all_ips")

  # $tmp_live_ouis is still needed by is_ubiquiti_oui in Step 5 (LLDP).
  rm -f "$tmp_nmap_ips" "$tmp_tlv_macs" "$tmp_tlv_ips" "$tmp_all_ips"

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
    emit_stage 18 ssh_banner_rescue "Step 4: SSH banner rescue for flagged devices"
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
      # Dropbear is also stock on OpenWrt, many NAS units and IP cameras, so a
      # banner match is only *probable*. Mark it so Task 19 never SSHes into
      # a non-Ubiquiti host with the user's credentials.
      if printf '%s' "$banner" | grep -qi 'dropbear'; then
        echo "  $ip — Dropbear SSH banner (probable UniFi, unverified): $banner"
        rescued_entries="${rescued_entries:+$rescued_entries,}$(unifi_device_entry "$mac" "$ip" "" "probable")"
      else
        remaining_flagged="${remaining_flagged:+$remaining_flagged,}$(unifi_device_entry "$mac" "$ip")"
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
    emit_stage 18 lldp_reconciliation "Step 5: LLDP reconciliation"
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
        entries="${entries:+$entries,}$(unifi_device_entry "$lldp_mac" "$lldp_ip")"
        lldp_new=$(( lldp_new + 1 ))
      done < "$tmp_lldp_macs"
      if [[ "$lldp_new" -gt 0 ]]; then
        echo "  LLDP complete — $lldp_new additional device(s) confirmed."
        echo
      fi
    fi
  fi
  rm -f "$tmp_lldp_macs" "$tmp_arp_macs"
  [[ -n "$tmp_live_ouis" ]] && rm -f "$tmp_live_ouis"

  local unifi_count
  unifi_count="$(printf '%s' "$entries" | grep -o '"mac"' | wc -l | tr -d ' ')"
  local flagged_count
  flagged_count="$(printf '%s' "$flagged_entries" | grep -o '"mac"' | wc -l | tr -d ' ')"
  devices_found="$unifi_count"

  [[ -n "$entries" ]] && device_list="[$entries]"
  local fp_list="[]"
  [[ -n "$flagged_entries" ]] && fp_list="[$flagged_entries]"

  jq -n \
    --arg iface "$iface" \
    --arg bcast "$broadcast_addr" \
    --arg subnet "${subnet:-}" \
    --argjson found "$devices_found" \
    --argjson devs "$device_list" \
    --argjson fps "$fp_list" \
    '{status:"success",success:true,error:null,warnings:[],interface:$iface,broadcast:$bcast,subnet:$subnet,devices_found:$found,devices:$devs,false_positives:$fps}' \
    > "$json_file"
  validate_json_file "$json_file" || true

  if [[ "$unifi_count" -eq 0 ]] && [[ "$flagged_count" -eq 0 ]]; then
    echo "No UniFi devices found."
  else
    if [[ "$unifi_count" -gt 0 ]]; then
      echo "Found $unifi_count confirmed UniFi device(s):"
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

  local fp_count
  fp_count="$(jq '.false_positives | length' "$file" 2>/dev/null || echo 0)"

  {
    echo "Status:             ${status:-unknown}"
    [[ -n "$error_code" ]]    && echo "Error Code:         $error_code"
    [[ -n "$error_message" ]] && echo "Error Message:      $error_message"
    echo "Interface:          ${iface}"
    echo "Subnet:             ${subnet}"
    echo "Confirmed Devices:  ${devices_found}"
    echo
    if [[ "$devices_found" -gt 0 ]]; then
      printf "%-20s  %-15s  %s\n" "MAC Address" "IP Address" "Model"
      printf "%-20s  %-15s  %s\n" "--------------------" "---------------" "----------------"
      jq -r '.devices[]? | [.mac, .ip, (.model // "")] | @tsv' "$file" 2>/dev/null | \
        while IFS=$'\t' read -r mac ip model; do
          printf "%-20s  %-15s  %s\n" "$mac" "$ip" "${model:---}"
        done
    else
      echo "No confirmed UniFi devices found."
    fi
    if [[ "$fp_count" -gt 0 ]]; then
      echo
      echo "Possible false positives — non-Ubiquiti MAC ($fp_count):"
      printf "%-20s  %s\n" "MAC Address" "IP Address"
      printf "%-20s  %s\n" "--------------------" "---------------"
      jq -r '.false_positives[]? | [.mac, .ip] | @tsv' "$file" 2>/dev/null | \
        while IFS=$'\t' read -r mac ip; do
          printf "%-20s  %s\n" "$mac" "$ip"
        done
    fi
  } >> "$report_file"
}

render_wireless_site_survey_report() {
  local file="$1"
  local report_file="$2"
  local use_color="${3:-}"
  local cyan="" bold="" reset=""
  if [[ "$use_color" == "color" ]]; then
    cyan='\033[0;36m'
    bold='\033[1m'
    reset='\033[0m'
  fi
  local status rooms_scanned iface

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  rooms_scanned="$(jq -r '.rooms_scanned // 0' "$file" 2>/dev/null)"

  {
    local w=16
    printf "  %-${w}s %s\n" "Status:"        "${status:-unknown}"
    printf "  %-${w}s %s\n" "Interface:"     "${iface}"
    printf "  %-${w}s %s\n" "Rooms Scanned:" "${rooms_scanned}"
    echo ""

    local room_count
    room_count="$(jq '.survey | length' "$file" 2>/dev/null || echo 0)"
    if [[ "$room_count" -eq 0 ]]; then
      echo "  No room data recorded."
    else
      printf "  ${bold}${cyan}Survey Summary${reset}\n"
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      printf "  %-4s  %-20s  %-8s  %-16s  %-4s  %-12s  %-5s  %s\n" \
        "#" "Building" "Floor" "Room / Area" "AP" "AP Label" "Nets" "Strongest Signal"
      printf "  %-4s  %-20s  %-8s  %-16s  %-4s  %-12s  %-5s  %s\n" \
        "----" "--------------------" "--------" "----------------" "----" "------------" "-----" "----------------"
      jq -r '.survey | to_entries[] |
        (.key + 1 | tostring) as $n |
        .value as $r |
        ($r.networks // [] | sort_by(.rssi_dbm // -999) | reverse | .[0]) as $top |
        (if $top then ($top.ssid + " (" + (if $top.rssi_dbm != null then ($top.rssi_dbm | tostring) + " dBm" else "--" end) + ", ch " + ($top.channel | tostring) + ", " + ($top.security // "--") + ")") else "--" end) as $sig |
        [$n,
         ($r.building // "--"),
         ($r.floor // "--"),
         ($r.room // "--"),
         (if $r.ap_present then "Yes" else "No" end),
         ($r.ap_label // "--"),
         (($r.networks // []) | length | tostring),
         $sig] |
        @tsv' "$file" 2>/dev/null \
        | awk -F'\t' '{printf "  %-4s  %-20s  %-8s  %-16s  %-4s  %-12s  %-5s  %s\n", $1,$2,$3,$4,$5,$6,$7,$8}' || true
      echo ""

      printf "  ${bold}${cyan}Room Details${reset}${cyan}  (top 5 networks by signal strength)${reset}\n"
      printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
      local room_idx=0
      jq -c '.survey[]' "$file" 2>/dev/null | while IFS= read -r room_json; do
        room_idx=$(( room_idx + 1 ))
        local building floor room ap_present ap_label timestamp net_count
        building="$(jq -r '.building // "--"' <<< "$room_json")"
        floor="$(jq -r '.floor // "--"' <<< "$room_json")"
        room="$(jq -r '.room // "--"' <<< "$room_json")"
        ap_present="$(jq -r 'if .ap_present then "Yes" else "No" end' <<< "$room_json")"
        ap_label="$(jq -r '.ap_label // ""' <<< "$room_json")"
        timestamp="$(jq -r '.timestamp // "--"' <<< "$room_json")"
        net_count="$(jq '.networks | length' <<< "$room_json" 2>/dev/null || echo 0)"
        echo ""
        printf "  Room %s: %s | Floor: %s | Area: %s\n" "$room_idx" "$building" "$floor" "$room"
        printf "  AP Present: %s%s\n" "$ap_present" "$([ -n "$ap_label" ] && printf "  (Label: %s)" "$ap_label")"
        printf "  Timestamp:  %s\n" "$timestamp"
        printf "  Networks:   %s found\n" "$net_count"
        if [[ "$net_count" -eq 0 ]]; then
          printf "  No networks detected.\n"
        else
          echo ""
          printf "  %-28s  %-9s  %-6s  %-7s  %-7s  %-10s  %s\n" \
            "SSID" "Signal" "Ch" "Band" "Width" "PHY Mode" "Security"
          printf "  %-28s  %-9s  %-6s  %-7s  %-7s  %-10s  %s\n" \
            "----------------------------" "---------" "------" "-------" "-------" "----------" "--------"
          jq -r '.networks // [] | sort_by(.rssi_dbm // -999) | reverse | .[0:5][] |
            [(.ssid // "(hidden)"),
             (if .rssi_dbm != null then ((.rssi_dbm | tostring) + " dBm") else "--" end),
             ("ch " + (.channel | tostring)),
             (.band // "--"),
             (.channel_width // "--"),
             (.phy_mode // "--"),
             (.security // "--")] | @tsv' <<< "$room_json" 2>/dev/null \
            | awk -F'\t' '{printf "  %-28s  %-9s  %-6s  %-7s  %-7s  %-10s  %s\n", $1,$2,$3,$4,$5,$6,$7}' || true
        fi
      done || true
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
  # Only devices positively fingerprinted (TLV/LLDP/OUI) are adopted. Hosts
  # that Task 18 marked "probable" from an SSH banner alone are skipped so we
  # never send the user's credentials to a non-Ubiquiti device.
  local found_count probable_count
  found_count="$(jq -r '[(.devices // [])[] | select((.confidence // "confirmed") != "probable")] | length' "$task18_json" 2>/dev/null || echo 0)"
  probable_count="$(jq -r '[(.devices // [])[] | select((.confidence // "confirmed") == "probable")] | length' "$task18_json" 2>/dev/null || echo 0)"
  [[ "$found_count" =~ ^[0-9]+$ ]] || found_count=0
  [[ "$probable_count" =~ ^[0-9]+$ ]] || probable_count=0
  if [[ "$probable_count" -gt 0 ]]; then
    printf "${yellow}Skipping %s device(s) identified only by an SSH banner (not confirmed UniFi).${reset}\n" "$probable_count"
  fi
  if [[ "$found_count" -eq 0 ]]; then
    echo "Task 18 scan found no confirmed devices. Run Task 18 first."
    return 0
  fi
  echo "Loaded $found_count confirmed device(s) from Task 18 scan."
  echo

  # ── Step 1: Ask for controller domain and credentials ─────────────────────
  local controller_domain controller_port use_https inform_url ssh_user ssh_pass
  local _def_domain _def_port _def_https
  _def_domain="$(get_program_default "unifi_domain" "unifi.lssolutions.ie")"
  _def_port="$(get_program_default "unifi_port" "8080")"
  _def_https="$(get_program_default "unifi_https" "n")"

  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    controller_domain="${_LSS_NI_CONTROLLER:-$_def_domain}"
    echo "Controller domain or IP: $controller_domain"
  else
    read -r -p "Controller domain or IP [$_def_domain]: " controller_domain
    controller_domain="${controller_domain:-$_def_domain}"
  fi
  # Tolerate a pasted URL: strip scheme and any path, then validate so the
  # value cannot carry shell metacharacters into the remote command.
  controller_domain="${controller_domain#http://}"
  controller_domain="${controller_domain#https://}"
  controller_domain="${controller_domain%%/*}"
  controller_domain="${controller_domain%%:*}"
  if [[ ! "$controller_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf "${red}[ERROR]${reset} Invalid controller host: %s\n" "$controller_domain"
    return 0
  fi
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    controller_port="${_LSS_NI_CONTROLLER_PORT:-$_def_port}"
    echo "Controller port: $controller_port"
  else
    read -r -p "Controller port [$_def_port]: " controller_port
    controller_port="${controller_port:-$_def_port}"
  fi
  if [[ ! "$controller_port" =~ ^[0-9]{1,5}$ ]] || [[ "$controller_port" -lt 1 || "$controller_port" -gt 65535 ]]; then
    printf "${red}[ERROR]${reset} Invalid controller port: %s\n" "$controller_port"
    return 0
  fi
  if [[ "$controller_port" == "443" ]]; then
    inform_url="https://${controller_domain}:${controller_port}/inform"
  elif [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    # --https y|n, else the Program Defaults value.
    use_https="${_LSS_NI_HTTPS:-$_def_https}"
    if [[ "$use_https" =~ ^[Yy]$ ]]; then
      inform_url="https://${controller_domain}:${controller_port}/inform"
    else
      inform_url="http://${controller_domain}:${controller_port}/inform"
    fi
  else
    if [[ "$_def_https" == "y" ]]; then
      read -r -p "Use HTTPS? [Y/n]: " use_https
      if [[ "$use_https" =~ ^[Nn]$ ]]; then
        inform_url="http://${controller_domain}:${controller_port}/inform"
      else
        inform_url="https://${controller_domain}:${controller_port}/inform"
      fi
    else
      read -r -p "Use HTTPS? [y/N]: " use_https
      if [[ "$use_https" =~ ^[Yy]$ ]]; then
        inform_url="https://${controller_domain}:${controller_port}/inform"
      else
        inform_url="http://${controller_domain}:${controller_port}/inform"
      fi
    fi
  fi
  echo
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    # --ssh-user; the password comes from the LSS_SSH_PASSWORD environment
    # variable (captured by noninteractive_setup), never from argv.
    ssh_user="$_LSS_NI_SSH_USER"
    ssh_pass="$_LSS_NI_SSH_PASSWORD"
    echo "SSH Username: $ssh_user"
  else
    read -r -p "SSH Username: " ssh_user
    read -r -s -p "SSH Password: " ssh_pass
    echo
  fi
  ssh_user="$(printf '%s' "$ssh_user" | tr -d '\r\n\t ')"
  ssh_pass="$(printf '%s' "$ssh_pass" | tr -d '\r\n')"
  echo
  echo "Inform URL:  $inform_url"
  echo

  # ── Step 2: SSH into each device and send set-inform ─────────────────────
  echo "Attempting adoption..."
  local devices_json="[" first=true adopted=0 failed=0

  # Password goes via the SSHPASS environment variable (-e), never on the
  # command line where `ps` could show it.
  export SSHPASS="$ssh_pass"
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    local result="failed" rc=0 reason
    if sshpass -e ssh -n \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${ssh_user}@${ip}" \
        "mca-cli-op set-inform '$inform_url'" 2>/dev/null; then
      result="adopted"
      adopted=$(( adopted + 1 ))
      printf "  ${green}[OK]${reset} %-18s  set-inform sent\n" "$ip"
    else
      rc=$?
      failed=$(( failed + 1 ))
      # sshpass: 5 = wrong password, 6 = host key problem; ssh: 255 = connection failed
      case "$rc" in
        5)   reason="authentication failed (wrong password?)" ;;
        6)   reason="host key problem" ;;
        255) reason="could not connect" ;;
        *)   reason="set-inform command failed (exit $rc)" ;;
      esac
      result="failed: $reason"
      printf "  ${yellow}[--]${reset} %-18s  %s\n" "$ip" "$reason"
    fi
    [[ "$first" == "true" ]] || devices_json+=","
    devices_json+="$(jq -cn --arg ip "$ip" --arg result "$result" '{ip:$ip, result:$result}')"
    first=false
  done < <(jq -r '(.devices // [])[] | select((.confidence // "confirmed") != "probable") | .ip // empty' "$task18_json" 2>/dev/null)
  unset SSHPASS
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

  local subnet
  subnet="$(get_interface_network_cidr "$iface" 2>/dev/null || true)"

  local raw_mac norm_mac
  if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
    raw_mac="$_LSS_NI_MAC"
    echo "MAC address (from --mac): $raw_mac"
  else
    read -r -p "Enter MAC address (any format): " raw_mac
  fi
  # Dash last: GNU tr reads ".- " as a reversed (invalid) range.
  norm_mac="$(printf '%s' "$raw_mac" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ' :.-' \
    | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')"
  if [[ ! "$norm_mac" =~ ^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$ ]]; then
    printf "${red}[ERROR]${reset} Invalid MAC address: %s\n" "$raw_mac"
    return 0
  fi
  echo
  echo "MAC:     $norm_mac"
  echo "Subnet:  ${subnet:-unknown}"
  echo

  # nmap prints no MAC addresses without raw-socket privileges, which would
  # make every lookup a confident "[NOT FOUND]".
  if [[ "$EUID" -ne 0 ]]; then
    printf "${red}[ERROR]${reset} This lookup needs root for ARP discovery. Run with sudo.\n"
    jq -n --arg iface "$iface" --arg mac "$norm_mac" --arg subnet "${subnet:-}" \
      '{status:"failed",success:false,error:{code:"insufficient_privileges",message:"ARP-based MAC lookup requires root. Re-run with sudo."},mac_queried:$mac,ip_found:null,interface:$iface,subnet:$subnet}' \
      > "$json_file"
    return 1
  fi

  if [[ -z "$subnet" ]]; then
    echo "Could not determine subnet for $iface."
    jq -n --arg iface "$iface" --arg mac "$norm_mac" \
      '{status:"failed",success:false,error:{code:"no_subnet",message:"Could not determine subnet"},mac_queried:$mac,ip_found:null,interface:$iface,subnet:""}' \
      > "$json_file"
    return 0
  fi

  echo "Scanning $subnet for $norm_mac (5 passes)..."
  local _tmp_arp_raw _found_ip=""
  _tmp_arp_raw="$(mktemp /tmp/lss-findmac-XXXXXX)"
  local _pass
  for _pass in 1 2 3 4 5; do
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
      '{status:"success",success:true,mac_queried:$mac,ip_found:null,interface:$iface,subnet:$subnet}' \
      > "$json_file"
    return 0
  fi

  printf "${green}[FOUND]${reset} %s → %s\n" "$norm_mac" "$_found_ip"
  echo

  jq -n \
    --arg iface "$iface" \
    --arg mac "$norm_mac" \
    --arg ip "$_found_ip" \
    --arg subnet "$subnet" \
    '{status:"success",success:true,mac_queried:$mac,ip_found:$ip,interface:$iface,subnet:$subnet}' \
    > "$json_file"
}

render_find_device_by_mac_report() {
  local file="$1"
  local report_file="$2"

  local status mac ip iface subnet
  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  mac="$(jq -r '.mac_queried // "unknown"' "$file" 2>/dev/null)"
  ip="$(jq -r 'if .ip_found and .ip_found != null then .ip_found else "not found" end' "$file" 2>/dev/null)"
  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  subnet="$(jq -r '.subnet // "unknown"' "$file" 2>/dev/null)"

  {
    echo "Status:        ${status:-unknown}"
    echo "Interface:     ${iface}"
    echo "Subnet:        ${subnet}"
    echo "MAC Queried:   ${mac}"
    if [[ "$ip" == "not found" ]]; then
      echo "IP Found:      not found (device offline or on a different VLAN)"
    else
      echo "IP Found:      ${ip}"
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
    4) echo "Performs repeated DHCP discovery attempts with the interface MAC, records the offered options, the system lease and the capture evidence, and flags rogue responders on evidence (server identifiers, system lease, offered router, relay)." ;;
    5) echo "Sends ${DHCP_RT_PROBE_COUNT:-10} DHCP Discover probes (interface MAC, 1 s apart) and measures the time from broadcast to first Offer response. Reports min/avg/max latency, packet loss, every responder, and cross-checks the result against Task 4." ;;
    6) echo "Finds the DNS servers this network uses (subnet sweep over TCP and UDP 53, configured resolvers, DHCP-advertised servers) and tests each for external resolution, recursion and the site domain." ;;
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
    19) echo "SSHes into the UniFi devices confirmed by Task 18 and sends a set-inform command pointing them at your controller. Devices only identified by an SSH banner are skipped." ;;
    20) echo "Scans the local subnet via ARP (5 passes) for a device matching a given MAC address and returns its IP." ;;
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

# Parse a multi-task selection string like "1,3-5,7" into an ordered list of
# valid unique task IDs. Prints the IDs space-separated on stdout.
# Returns 1 if any part of the input is invalid.
# Uses a plain string for seen-tracking (bash 3.2 compatible — no associative arrays).
expand_task_selection() {
  local input="$1"
  local result="" seen="" part start end id
  local -a parts=()

  # Empty input would expand an empty array under set -u (fatal on bash 3.2).
  [[ -z "${input//[[:space:],]/}" ]] && return 1
  IFS=',' read -ra parts <<< "$input"
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part// /}"  # strip spaces
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if [[ "$start" -gt "$end" ]]; then
        printf "  Invalid range: %s-%s\n" "$start" "$end" >&2
        return 1
      fi
      for (( id=start; id<=end; id++ )); do
        if ! run_task_exists "$id"; then
          printf "  Unknown task: %s\n" "$id" >&2
          return 1
        fi
        if [[ ! " $seen " =~ " $id " ]]; then
          result="$result $id"
          seen="$seen $id"
        fi
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      if ! run_task_exists "$part"; then
        printf "  Unknown task: %s\n" "$part" >&2
        return 1
      fi
      if [[ ! " $seen " =~ " $part " ]]; then
        result="$result $part"
        seen="$seen $part"
      fi
    else
      printf "  Invalid input: %s\n" "$part" >&2
      return 1
    fi
  done

  echo "${result# }"
}

run_task_by_id() {
  # Remembered so a result the engine rewrote in this session is never
  # mistaken for a hand edit by task_result_edited.
  _LSS_TASKS_RUN_IN_SESSION="${_LSS_TASKS_RUN_IN_SESSION}|$(current_output_dir)/$1|"
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

_draw_multi_task_summary_list() {
  local task_ids_str="$1"
  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local red='\033[0;31m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'
  local id title json_file status warn_count indicator

  for id in $task_ids_str; do
    title="$(task_title "$id")"
    json_file="$(task_output_path "$id" 2>/dev/null || true)"
    if [[ -f "$json_file" ]] && json_file_usable "$json_file"; then
      status="$(    jq -r '.status   // "unknown"' "$json_file" 2>/dev/null)"
      warn_count="$(jq -r '(.warnings // []) | length' "$json_file" 2>/dev/null)"
      case "$status" in
        success)              indicator="${green}✓${reset}" ;;
        completed_with_warnings) indicator="${yellow}⚠${reset}" ;;
        failed)               indicator="${red}✗${reset}" ;;
        *)                    indicator="${cyan}?${reset}" ;;
      esac
      printf "  %b  ${bold}%-3s${reset}  %-38s  %s\n" "$indicator" "$id" "$title" "$status"
      if [[ "$warn_count" -gt 0 ]]; then
        jq -r '(.warnings // [])[] | "         ⚠  " + .' "$json_file" 2>/dev/null || true
      fi
    else
      printf "  ${cyan}?${reset}  ${bold}%-3s${reset}  %-38s  no output\n" "$id" "$title"
    fi
  done
}

show_multi_task_summary() {
  local task_ids_str="$1"   # space-separated list of task IDs
  local green='\033[0;32m'
  local yellow='\033[1;33m'
  local red='\033[0;31m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'
  local choice id title

  while true; do
    clear_screen_if_supported
    echo
    printf "  ${yellow}${bold}Multi-Task Run — Results Summary${reset}\n"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    _draw_multi_task_summary_list "$task_ids_str"
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}1)${reset}  Save Run & Exit\n"
    printf "  ${bold}2)${reset}  View Result Data\n"
    printf "  ${bold}3)${reset}  Continue With Another Task\n"
    printf "  ${red}${bold}4)${reset}  Exit Without Saving\n"
    echo
    read -r -p "  Choose option: " choice

    case "$choice" in
      1)
        echo
        printf "  Building report...\n"
        finalize_run || true
        generate_pdf_report || true
        RUN_OUTPUT_DIR=""
        printf "  Report saved.\n"
        sleep 1
        _GOTO_MAIN_MENU=true
        return 0
        ;;
      2)
        # Render all tasks in this run without prompting
        local _view_tmp _entry_idx _fp _desc
        _view_tmp="$(mktemp)"
        for id in $task_ids_str; do
          title="$(task_title "$id")"
          _desc="$(task_description "$id")"
          _entry_idx=0
          while IFS= read -r _fp; do
            [[ -z "$_fp" ]] && continue
            _entry_idx=$(( _entry_idx + 1 ))
            {
              echo
              if task_supports_multiple_entries "$id"; then
                printf "  ${yellow}${bold}Task %s — %s  (Device %s)${reset}\n" "$id" "$title" "$_entry_idx"
              else
                printf "  ${yellow}${bold}Task %s — %s${reset}\n" "$id" "$title"
              fi
              if task_result_edited "$_fp" "$id"; then
                printf "  ${yellow}(edited after the run)${reset}\n"
              fi
              [[ -n "$_desc" ]] && printf "  ${cyan}%s${reset}\n" "$_desc"
              printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
              echo
            } >> "$_view_tmp"
            case "$id" in
              1)  render_interface_info_report "$_fp" "$_view_tmp" ;;
              2)  render_speed_test_report "$_fp" "$_view_tmp" ;;
              3)  render_gateway_report "$_fp" "$_view_tmp" ;;
              4)  render_dhcp_report "$_fp" "$_view_tmp" ;;
              5)  render_dhcp_response_time_report "$_fp" "$_view_tmp" ;;
              6)  render_generic_network_scan_report "$_fp" "$_view_tmp" "DNS" ;;
              7)  render_generic_network_scan_report "$_fp" "$_view_tmp" "LDAP/AD" ;;
              8)  render_generic_network_scan_report "$_fp" "$_view_tmp" "SMB/NFS" ;;
              9)  render_generic_network_scan_report "$_fp" "$_view_tmp" "Printer" ;;
              10) render_gateway_stress_report "$_fp" "$_view_tmp" ;;
              11) render_vlan_trunk_report "$_fp" "$_view_tmp" ;;
              12) render_duplicate_ip_report "$_fp" "$_view_tmp" ;;
              13) render_custom_target_port_scan_report "$_fp" "$_view_tmp" ;;
              14) render_custom_target_stress_report "$_fp" "$_view_tmp" ;;
              15) render_custom_target_identity_report "$_fp" "$_view_tmp" ;;
              16) render_custom_target_dns_assessment_report "$_fp" "$_view_tmp" ;;
              17) render_wireless_site_survey_report "$_fp" "$_view_tmp" "color" ;;
              18) render_unifi_discovery_report "$_fp" "$_view_tmp" ;;
              19) render_unifi_adoption_report "$_fp" "$_view_tmp" ;;
              20) render_find_device_by_mac_report "$_fp" "$_view_tmp" ;;
            esac
            echo >> "$_view_tmp"
          done < <(task_json_files "$id")
        done
        clear_screen_if_supported
        echo
        cat "$_view_tmp"
        rm -f "$_view_tmp"
        echo
        read -r -p "  Press Enter to continue..." _
        ;;
      3)
        # Show full two-column task list with [x]/[ ] markers so user can see
        # what has already been run before picking the next task(s).
        while true; do
          clear_screen_if_supported
          echo
          printf "  ${yellow}${bold}Continue With Another Task${reset}\n"
          printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
          echo

          local -a _all_ids=() _all_titles=() _all_avail=()
          local _task_id _half _tl_tmp _tr_tmp _term_w _col_w _i
          for _task_id in $(get_task_ids); do
            _all_ids+=("$_task_id")
            _all_titles+=("$(task_title "$_task_id")")
            if [[ -n "$(task_json_files "$_task_id")" ]]; then
              _all_avail+=("1")
            else
              _all_avail+=("0")
            fi
          done

          _term_w="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
          [[ -z "$_term_w" || "$_term_w" -lt 60 ]] && _term_w="${COLUMNS:-80}"
          [[ "$_term_w" -lt 60 ]] && _term_w=80
          _col_w=$(( (_term_w - 5) / 2 ))
          _half=$(( (${#_all_ids[@]} + 1) / 2 ))

          _tl_tmp="$(mktemp /tmp/lss-tl-XXXXXX)"
          _tr_tmp="$(mktemp /tmp/lss-tr-XXXXXX)"
          {
            for (( _i=0; _i<_half; _i++ )); do
              if [[ "${_all_avail[$_i]}" == "1" ]]; then
                printf "${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
              else
                printf "[ ]  %2s)  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
              fi
            done
          } > "$_tl_tmp"
          {
            for (( _i=_half; _i<${#_all_ids[@]}; _i++ )); do
              if [[ "${_all_avail[$_i]}" == "1" ]]; then
                printf "${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
              else
                printf "[ ]  %2s)  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
              fi
            done
          } > "$_tr_tmp"
          python3 - "$_tl_tmp" "$_tr_tmp" "$_col_w" << 'PYEOF'
import sys, re
def strip_ansi(s):
    return re.sub(r'\033\[[0-9;]*m', '', s)
def pad_line(s, width):
    return s + ' ' * max(0, width - len(strip_ansi(s)))
fa, fb, col_w = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(fa) as f:
    left = [l.rstrip('\n') for l in f]
with open(fb) as f:
    right = [l.rstrip('\n') for l in f]
n = max(len(left), len(right))
for i in range(n):
    l = '  ' + (left[i] if i < len(left) else '')
    r = right[i] if i < len(right) else ''
    print(pad_line(l, col_w + 2) + '   ' + r)
PYEOF
          rm -f "$_tl_tmp" "$_tr_tmp"

          echo
          printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
          printf "  ${bold}000)${reset}  Complete Network Audit\n"
          printf "    ${bold}0)${reset}  Save / Exit Options\n"
          echo
          local _cont_choice
          read -r -p "  Enter task number(s) to run (e.g. 5 or 1,3 or 1-5): " _cont_choice
          [[ "$_cont_choice" == "0" ]] && break
          if [[ "$_cont_choice" == "000" ]]; then
            run_all_tasks || true
            if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then return 0; fi
            # Add all audit task IDs to summary list
            local _audit_id
            for _audit_id in $(get_audit_task_ids); do
              if [[ ! " $task_ids_str " =~ " $_audit_id " ]]; then
                task_ids_str="$task_ids_str $_audit_id"
              fi
            done
            break
          fi

          local _new_ids
          if ! _new_ids="$(expand_task_selection "$_cont_choice")"; then
            printf "  Invalid selection.\n"
            sleep 1
            continue
          fi

          local _new_id _new_title
          for _new_id in $_new_ids; do
            _new_title="$(task_title "$_new_id")"
            run_task_with_results_output "$_new_id" "$_new_title" "--no-pause" || true
            if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then return 0; fi
            # Add to summary list if not already tracked
            if [[ ! " $task_ids_str " =~ " $_new_id " ]]; then
              task_ids_str="$task_ids_str $_new_id"
            fi
          done
          break
        done
        ;;
      4)
        # Delete all run data — nothing is kept
        if [[ -n "$RUN_OUTPUT_DIR" && -d "$RUN_OUTPUT_DIR" ]]; then
          rm -rf "$RUN_OUTPUT_DIR" 2>/dev/null || true
          RUN_OUTPUT_DIR=""
        fi
        _GOTO_MAIN_MENU=true
        return 0
        ;;
      *)
        printf "  Invalid selection.\n"
        sleep 1
        ;;
    esac
  done
}

run_task_with_results_output() {
  local func_id="$1"
  local func_name="$2"
  local no_pause="${3:-}"
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
  TASK_OUTPUT_INDENT=""

  # Redirect task stdout through a 2-space indenter so all task output aligns
  # with the header. awk fflush() ensures line-buffered output so interactive
  # prompts in tasks still appear in the correct order.
  # Uses fd 8 (fixed number for bash 3.x compatibility).
  exec 8>&1
  exec 1> >(awk '{print "  " $0; fflush()}' >&8)

  if ! run_task_by_id "$func_id"; then
    exec 1>&8 8>&-
    # Give the awk indenter a moment to flush the task's last lines before
    # the footer (or a following `clear`) overtakes them.
    sleep 0.2
    SHOW_FUNCTION_HEADER=1
    TASK_OUTPUT_INDENT=""
    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    [[ "$no_pause" != "--no-pause" ]] && read -r -p "  Press Enter to continue..." _
    return 1
  fi

  exec 1>&8 8>&-
  sleep 0.2
  SHOW_FUNCTION_HEADER=1
  TASK_OUTPUT_INDENT=""
  echo
  printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
  echo
  [[ "$no_pause" != "--no-pause" ]] && read -r -p "  Press Enter to continue..." _
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
  local green='\033[0;32m'
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

    # Two-column task list with [x]/[ ] completion indicators
    local -a _all_ids=() _all_titles=() _all_avail=()
    local _tl_tmp _tr_tmp _term_w _col_w _half _i
    _all_ids=() _all_titles=() _all_avail=()
    for func_id in "${task_ids[@]}"; do
      title="$(task_title "$func_id")"
      [[ -z "$title" ]] && continue
      _all_ids+=("$func_id")
      _all_titles+=("$title")
      if [[ -n "$(task_json_files "$func_id")" ]]; then
        _all_avail+=("1")
      else
        _all_avail+=("0")
      fi
    done

    _term_w="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
    [[ -z "$_term_w" || "$_term_w" -lt 60 ]] && _term_w="${COLUMNS:-80}"
    [[ "$_term_w" -lt 60 ]] && _term_w=80
    _col_w=$(( (_term_w - 5) / 2 ))
    _half=$(( (${#_all_ids[@]} + 1) / 2 ))

    _tl_tmp="$(mktemp /tmp/lss-tl-XXXXXX)"
    _tr_tmp="$(mktemp /tmp/lss-tr-XXXXXX)"
    {
      for (( _i=0; _i<_half; _i++ )); do
        if [[ "${_all_avail[$_i]}" == "1" ]]; then
          printf "${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
        else
          printf "[ ]  %2s)  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
        fi
      done
    } > "$_tl_tmp"
    {
      for (( _i=_half; _i<${#_all_ids[@]}; _i++ )); do
        if [[ "${_all_avail[$_i]}" == "1" ]]; then
          printf "${green}[x]${reset}  ${bold}%2s)${reset}  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
        else
          printf "[ ]  %2s)  %s\n" "${_all_ids[$_i]}" "${_all_titles[$_i]}"
        fi
      done
    } > "$_tr_tmp"
    python3 - "$_tl_tmp" "$_tr_tmp" "$_col_w" << 'PYEOF'
import sys, re
def strip_ansi(s):
    return re.sub(r'\033\[[0-9;]*m', '', s)
def pad_line(s, width):
    return s + ' ' * max(0, width - len(strip_ansi(s)))
fa, fb, col_w = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(fa) as f:
    left = [l.rstrip('\n') for l in f]
with open(fb) as f:
    right = [l.rstrip('\n') for l in f]
n = max(len(left), len(right))
for i in range(n):
    l = '  ' + (left[i] if i < len(left) else '')
    r = right[i] if i < len(right) else ''
    print(pad_line(l, col_w + 2) + '   ' + r)
PYEOF
    rm -f "$_tl_tmp" "$_tr_tmp"

    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  ${bold}000)${reset}  %s\n" "$(task_title "000")"
    printf "    ${bold}0)${reset}  Save / Exit Options\n"
    echo
    printf "  ${cyan}Tip: select multiple tasks using commas or ranges, e.g. 1,3 or 1-5 or 1-3,5,8-10${reset}\n"
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
        # Declining the stress-test confirmation returns 1; under set -e a
        # bare call here would exit the whole program.
        run_all_tasks || true
        echo
        printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
        echo
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      0)
        # Build list of tasks completed so far in this session
        local _ran_ids="" _tid
        for _tid in "${task_ids[@]}"; do
          if [[ -n "$(task_json_files "$_tid")" ]]; then
            _ran_ids="$_ran_ids $_tid"
          fi
        done
        _ran_ids="${_ran_ids# }"
        if [[ -z "$_ran_ids" ]]; then
          return 0
        fi
        show_multi_task_summary "$_ran_ids"
        [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && run_task_exists "$choice"; then
          # Single task
          title="$(task_title "$choice")"
          [[ -z "$title" ]] && title="Function $choice"
          run_task_with_results_output "$choice" "$title" || true
          [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
        elif [[ "$choice" =~ [,\-] ]]; then
          # Multi-task selection: "1,3,5" or "1-5" or "1,3-5,7"
          local _multi_ids _id _multi_title
          if ! _multi_ids="$(expand_task_selection "$choice")"; then
            printf "%s\n" "$_multi_ids"
            printf "  Invalid selection. Try again.\n"
            sleep 1
          else
            read -r -a _multi_id_arr <<< "$_multi_ids"
            for _id in "${_multi_id_arr[@]}"; do
              _multi_title="$(task_title "$_id")"
              [[ -z "$_multi_title" ]] && _multi_title="Function $_id"
              run_task_with_results_output "$_id" "$_multi_title" "--no-pause" || true
              if [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]]; then return 0; fi
            done
            show_multi_task_summary "$_multi_ids"
            [[ "${_GOTO_MAIN_MENU:-false}" == "true" ]] && return 0
          fi
        else
          printf "  Invalid selection. Try again.\n"
          sleep 1
        fi
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Non-interactive mode (--run-task / --build-report / --delete-run)
#
# Used by the macOS app and by scripts. Nothing here is reached unless
# RUN_TASK_MODE, BUILD_REPORT_MODE or DELETE_RUN_MODE was set by parse_args;
# the interactive flow never calls these functions. Progress goes out as
# `@@LSS {json}` lines (emit_progress, fd 9 = original stderr). Exit codes:
#   0   every task success / completed_with_warnings / skipped (or the report
#       was built / the run directory was deleted)
#   1   at least one task failed or wrote no JSON (or the report failed, or
#       the run directory could not be removed)
#   2   usage / validation        3   missing required dependency
#   4   stress task without --yes 5   not root        130 interrupted
# ═══════════════════════════════════════════════════════════════════════════

noninteractive_setup() {
  _LSS_NONINTERACTIVE=1
  # Dup the original stderr before initialize_debug_logging merges fd 1/2 into
  # the tee: progress lines survive the redirect and never enter debug.txt.
  # When the caller closed stderr (2>&-) the dup fails and, under set -e, a
  # bare `exec 9>&2` would end the shell before hello; the || list keeps
  # errexit out of it and parks the progress channel on /dev/null instead,
  # so the run proceeds exactly as with stderr open (fd 2 itself is never
  # redirected here).
  exec 9>&2 || exec 9>/dev/null
  export LSS_QUIET_SPINNER=1
  # The SSH password travels in the environment, never argv. Keep a private
  # copy and drop the variable so child processes (nmap, python…) do not
  # inherit it.
  if [[ -n "${LSS_SSH_PASSWORD:-}" ]]; then
    _LSS_NI_SSH_PASSWORD="$LSS_SSH_PASSWORD"
  fi
  unset LSS_SSH_PASSWORD
  # Optional per-run secret that authenticates the progress lines: with it
  # every event is written as `@@LSS <token> {json}`, so device-supplied text
  # echoed on stdout (an SSID or hostname containing "@@LSS {…}") cannot forge
  # an event for a consumer that reads them in-band from a pty. Same handling
  # as the password: private copy, then removed from every child's
  # environment. A value that does not match the grammar is ignored.
  if [[ "${LSS_PROGRESS_TOKEN:-}" =~ ^[A-Za-z0-9_-]{8,64}$ ]]; then
    _LSS_NI_PROGRESS_TOKEN="$LSS_PROGRESS_TOKEN"
  fi
  unset LSS_PROGRESS_TOKEN
}

# `--run-task list`: {"version":…,"tasks":[{id,title,file,multi,group}]} on
# stdout. Built from TASKS_DATA with printf — no jq, no OS detection, no root.
print_task_listing_json() {
  local id title file multi group out="" sep=""
  while IFS='|' read -r id title file; do
    [[ -z "$id" ]] && continue
    if task_supports_multiple_entries "$id"; then
      multi=true
    else
      multi=false
    fi
    if [[ "$id" -le 12 ]]; then
      group="core"
    elif [[ "$id" -le 16 ]]; then
      group="custom"
    else
      group="specialist"
    fi
    out="$out$sep{\"id\":$id,\"title\":\"$(json_escape "$title")\",\"file\":\"$(json_escape "$file")\",\"multi\":$multi,\"group\":\"$group\"}"
    sep=","
  done <<< "$TASKS_DATA"
  printf '{"version":"%s","tasks":[%s]}\n' "$(json_escape "$APP_VERSION")" "$out"
}

# `--run-task list` stands alone: every argument must be --run-task, list or
# --debug. Checked on the original argv so an empty-valued flag (--client "")
# is caught as well.
ni_list_args_only() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --run-task|list|--debug) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# `--delete-run <dir>` accepts --debug and nothing else: no other mode, none
# of the run flags. Checked on the original argv like ni_list_args_only, so a
# flag given before --delete-run is caught as well.
ni_delete_args_only() {
  local arg skip_value=0
  for arg in "$@"; do
    if [[ "$skip_value" -eq 1 ]]; then
      skip_value=0
      continue
    fi
    case "$arg" in
      --delete-run) skip_value=1 ;;
      --debug) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Does the directory hold what a run directory holds? manifest.json, a task
# JSON file from TASKS_DATA (single or -device-N), or a TXT report. Anything
# else under output/ (a stray folder, the OUI cache dir…) is not a run and
# --delete-run refuses it.
ni_dir_looks_like_run() {
  local dir="$1" id title file stem
  if [[ -f "$dir/manifest.json" ]]; then
    return 0
  fi
  if [[ -n "$(find "$dir" -maxdepth 1 -type f -name 'lss-network-tools-report-*.txt' -print -quit 2>/dev/null)" ]]; then
    return 0
  fi
  while IFS='|' read -r id title file; do
    [[ -z "$id" || -z "$file" ]] && continue
    if [[ -f "$dir/$file" ]]; then
      return 0
    fi
    stem="${file%.json}"
    if [[ -n "$(find "$dir" -maxdepth 1 -type f -name "$stem-device-*.json" -print -quit 2>/dev/null)" ]]; then
      return 0
    fi
  done <<< "$TASKS_DATA"
  return 1
}

# Human line + error event + bye, then exit. Extra arguments are additional
# pre-rendered JSON fragments for the error event (e.g. the tools array).
ni_fail() {
  local exit_code="$1" code="$2" message="$3"
  shift 3
  printf "  Error: %s\n" "$message"
  emit_progress error "$(json_str_field code "$code")" "$(json_str_field message "$message")" "$@"
  emit_bye "$exit_code"
  exit "$exit_code"
}

# Resolve the task selection and emit hello (always the first event).
noninteractive_hello() {
  local ids="" ok=1 has_space=0 frag="" id

  if [[ "$RUN_TASK_MODE" -eq 1 ]]; then
    if [[ "$_LSS_NI_RUN_TASK" == *[[:space:]]* ]]; then
      # expand_task_selection strips blanks, so "1 2" would silently turn
      # into task 12; refuse whitespace here and leave the shared helper alone.
      ok=0
      has_space=1
    elif [[ "$_LSS_NI_RUN_TASK" == "000" ]]; then
      ids="$(get_audit_task_ids)"
    elif ! ids="$(expand_task_selection "$_LSS_NI_RUN_TASK" 2>/dev/null)"; then
      ok=0
      ids=""
    fi
  fi
  _LSS_NI_TASK_IDS="$ids"
  for id in $ids; do
    frag="$frag,$id"
  done
  emit_progress hello "$(json_str_field version "$APP_VERSION")" "$(json_raw_field pid "$$")" "\"tasks\":[${frag#,}]"

  if [[ "$RUN_TASK_MODE" -eq 1 && "$BUILD_REPORT_MODE" -eq 1 ]]; then
    ni_fail 2 usage "--run-task and --build-report are mutually exclusive"
  fi
  if [[ "$RUN_TASK_MODE" -eq 1 && "$has_space" -eq 1 ]]; then
    ni_fail 2 usage "--run-task must not contain whitespace: '$_LSS_NI_RUN_TASK' (separate task ids with commas only, e.g. 1,3,5-7)"
  fi
  if [[ "$RUN_TASK_MODE" -eq 1 ]] && [[ "$ok" -eq 0 || -z "$ids" ]]; then
    ni_fail 2 usage "Invalid task selection: $_LSS_NI_RUN_TASK (use a task id, a list such as 1,3,5-7, 000 or list)"
  fi
}

# Strip leading and trailing blanks (spaces, tabs, CR/LF) — what `read` does
# to the interactive answers.
ni_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Strip trailing slashes (but keep "/").
ni_normalize_dir() {
  local d="$1"
  while [[ "$d" == */ && "$d" != "/" ]]; do
    d="${d%/}"
  done
  printf '%s' "$d"
}

# A run directory must be absolute, free of . / .. components, directly
# inside OUTPUT_DIR and exist. Exits 2 (invalid_run_dir) otherwise.
ni_validate_run_dir() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" != /* ]]; then
    ni_fail 2 invalid_run_dir "Run directory must be an absolute path: ${dir:-<empty>}"
  fi
  if [[ "$dir" == *"/../"* || "$dir" == *"/.." || "$dir" == *"/./"* || "$dir" == *"/." ]]; then
    ni_fail 2 invalid_run_dir "Run directory must not contain . or .. components: $dir"
  fi
  if [[ "$(dirname "$dir")" != "$OUTPUT_DIR" ]]; then
    ni_fail 2 invalid_run_dir "Run directory must be directly inside $OUTPUT_DIR: $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    if [[ -e "$dir" || -L "$dir" ]]; then
      ni_fail 2 invalid_run_dir "Run directory is not a directory: $dir"
    fi
    ni_fail 2 invalid_run_dir "Run directory does not exist: $dir"
  fi
}

# Same rule as prompt_for_target_ip: dotted quad, each octet 0-255.
ni_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  awk -F'.' '
    NF == 4 {
      for (i = 1; i <= 4; i++) {
        if ($i < 0 || $i > 255) {
          exit 1
        }
      }
      exit 0
    }
    { exit 1 }
  ' <<< "$ip"
}

# Same normalisation as find_device_by_mac: any separators, lower-case
# aa:bb:cc:dd:ee:ff on stdout; returns 1 when the result is not a MAC.
ni_normalize_mac() {
  local norm
  norm="$(printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ' :.-' \
    | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')"
  if [[ "$norm" =~ ^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$ ]]; then
    printf '%s' "$norm"
    return 0
  fi
  return 1
}

ni_interface_exists() {
  local wanted="$1" line
  while IFS= read -r line; do
    if [[ "$line" == "$wanted" ]]; then
      return 0
    fi
  done < <(list_interfaces 2>/dev/null)
  return 1
}

# Validate every flag before check_tools and before anything needs root, so a
# request can be pre-flighted as an unprivileged user. Exits 2 or 4.
noninteractive_validate() {
  local id has_target_task=0 has_mac_task=0 has_wifi_task=0 has_unifi_task=0 needs_consent=0
  local dir iface norm_mac host ssh_user_clean port_num

  if [[ "$DELETE_RUN_MODE" -eq 1 ]]; then
    # rm -rf as root on a caller-supplied path: the directory must be a real
    # run directory directly inside OUTPUT_DIR — never OUTPUT_DIR itself, never
    # a symlink (which could point anywhere), never something that merely
    # lives under output/.
    dir="$(ni_normalize_dir "$_LSS_NI_DELETE_RUN_DIR")"
    if [[ -n "$dir" && "$dir" == "$(ni_normalize_dir "$OUTPUT_DIR")" ]]; then
      ni_fail 2 invalid_run_dir "Refusing to delete the output directory itself: $dir"
    fi
    if [[ -L "$dir" ]]; then
      ni_fail 2 invalid_run_dir "Run directory must not be a symbolic link: $dir"
    fi
    ni_validate_run_dir "$dir"
    if ! ni_dir_looks_like_run "$dir"; then
      ni_fail 2 invalid_run_dir "Not a run directory (no manifest.json, task JSON or report): $dir"
    fi
    _LSS_NI_DELETE_RUN_DIR="$dir"
    return 0
  fi

  if [[ "$BUILD_REPORT_MODE" -eq 1 ]]; then
    dir="$(ni_normalize_dir "$_LSS_NI_BUILD_REPORT_DIR")"
    ni_validate_run_dir "$dir"
    _LSS_NI_BUILD_REPORT_DIR="$dir"
    if [[ -n "$_LSS_NI_OUTPUT_DIR" ]]; then
      _LSS_NI_OUTPUT_DIR="$(expand_user_path "$_LSS_NI_OUTPUT_DIR")"
      if [[ "$_LSS_NI_OUTPUT_DIR" != /* ]]; then
        _LSS_NI_OUTPUT_DIR="$PWD/$_LSS_NI_OUTPUT_DIR"
      fi
      _LSS_NI_OUTPUT_DIR="$(ni_normalize_dir "$_LSS_NI_OUTPUT_DIR")"
    fi
    return 0
  fi

  # ── Run context ──────────────────────────────────────────────────────────
  if [[ -n "$_LSS_NI_OUTPUT_DIR" ]]; then
    ni_fail 2 usage "--output is only valid with --build-report"
  fi
  if [[ -n "$_LSS_NI_RUN_DIR" && "$_LSS_NI_NEW_RUN_FLAGS" -eq 1 ]]; then
    ni_fail 2 usage "--run-dir cannot be combined with --client, --location or --note"
  fi
  if [[ -n "$_LSS_NI_RUN_DIR" ]]; then
    dir="$(ni_normalize_dir "$_LSS_NI_RUN_DIR")"
    ni_validate_run_dir "$dir"
    _LSS_NI_RUN_DIR="$dir"
  else
    # A new run needs a real client and location; the engine would otherwise
    # create unknown-unknown-<date> without complaint.
    _LSS_NI_CLIENT="$(ni_trim "$_LSS_NI_CLIENT")"
    _LSS_NI_LOCATION="$(ni_trim "$_LSS_NI_LOCATION")"
    if [[ -z "$_LSS_NI_CLIENT" ]]; then
      ni_fail 2 usage "--client is required for a new run and must not be blank (use --run-dir to continue an existing run)"
    fi
    if [[ -z "$_LSS_NI_LOCATION" ]]; then
      ni_fail 2 usage "--location is required for a new run and must not be blank"
    fi
  fi

  # ── Interface ────────────────────────────────────────────────────────────
  if [[ -z "$_LSS_NI_INTERFACE" && -n "$_LSS_NI_RUN_DIR" ]]; then
    # Continue-run without --interface: the run's recorded interface.
    iface="$(jq -r '.selected_interface // empty' "$_LSS_NI_RUN_DIR/manifest.json" 2>/dev/null || true)"
    if [[ "$iface" == "unknown" || "$iface" == "null" ]]; then
      iface=""
    fi
    _LSS_NI_INTERFACE="$iface"
  fi
  if [[ -z "$_LSS_NI_INTERFACE" ]]; then
    ni_fail 2 invalid_interface "--interface is required (the run has no recorded interface)"
  fi
  if ! ni_interface_exists "$_LSS_NI_INTERFACE"; then
    ni_fail 2 invalid_interface "Interface not found: $_LSS_NI_INTERFACE"
  fi

  # ── Task-specific flags ──────────────────────────────────────────────────
  for id in $_LSS_NI_TASK_IDS; do
    case "$id" in
      10|14) needs_consent=1 ;;
    esac
    case "$id" in
      13|14|15|16) has_target_task=1 ;;
      17) has_wifi_task=1 ;;
      19) has_unifi_task=1 ;;
      20) has_mac_task=1 ;;
    esac
  done
  if [[ "$_LSS_NI_RUN_TASK" == "000" ]]; then
    needs_consent=1
  fi

  if [[ "$has_target_task" -eq 1 ]]; then
    if [[ -z "$_LSS_NI_TARGET" ]]; then
      ni_fail 2 invalid_target "--target <IPv4> is required for tasks 13-16"
    fi
    if ! ni_valid_ipv4 "$_LSS_NI_TARGET"; then
      ni_fail 2 invalid_target "Invalid IPv4 address: $_LSS_NI_TARGET"
    fi
  fi

  if [[ "$has_mac_task" -eq 1 ]]; then
    if [[ -z "$_LSS_NI_MAC" ]]; then
      ni_fail 2 invalid_mac "--mac <address> is required for task 20"
    fi
    if ! norm_mac="$(ni_normalize_mac "$_LSS_NI_MAC")"; then
      ni_fail 2 invalid_mac "Invalid MAC address: $_LSS_NI_MAC"
    fi
  fi

  if [[ "$has_wifi_task" -eq 1 ]]; then
    if [[ -z "$_LSS_NI_BUILDING" || -z "$_LSS_NI_FLOOR" || -z "$_LSS_NI_ROOM" ]]; then
      ni_fail 2 usage "--building, --floor and --room are required for task 17"
    fi
    if [[ -n "$_LSS_NI_AP_PRESENT" && ! "$_LSS_NI_AP_PRESENT" =~ ^[YyNn]$ ]]; then
      ni_fail 2 usage "--ap-present must be y or n"
    fi
    if [[ -n "$_LSS_NI_WIFI_SCAN_JSON" ]]; then
      if [[ ! -f "$_LSS_NI_WIFI_SCAN_JSON" ]]; then
        ni_fail 2 usage "--wifi-scan-json must be a regular file: $_LSS_NI_WIFI_SCAN_JSON"
      fi
      if [[ ! -r "$_LSS_NI_WIFI_SCAN_JSON" ]]; then
        ni_fail 2 usage "--wifi-scan-json file is not readable: $_LSS_NI_WIFI_SCAN_JSON"
      fi
      # jq may be the very dependency check_tools is about to report missing.
      if command -v jq >/dev/null 2>&1 \
         && ! jq -e 'type == "array"' "$_LSS_NI_WIFI_SCAN_JSON" >/dev/null 2>&1; then
        ni_fail 2 usage "--wifi-scan-json must contain a JSON array: $_LSS_NI_WIFI_SCAN_JSON"
      fi
    elif [[ "$OS" == "macos" && -z "${SUDO_USER:-}" ]]; then
      # launchd/privileged-helper case: no logged-in user context, so the
      # LSS-WiFiScan.app helper cannot be opened and the room would be
      # recorded as an empty "success". Under sudo SUDO_USER is set.
      ni_fail 2 usage "Task 17 without --wifi-scan-json needs a logged-in user session (sudo); under the privileged helper attach a CoreWLAN scan from the app"
    fi
    if [[ -n "$_LSS_NI_WIFI_INTERFACE" ]] && ! ni_interface_exists "$_LSS_NI_WIFI_INTERFACE"; then
      ni_fail 2 invalid_interface "Wireless interface not found: $_LSS_NI_WIFI_INTERFACE"
    fi
  fi

  if [[ "$has_unifi_task" -eq 1 ]]; then
    ssh_user_clean="$(printf '%s' "$_LSS_NI_SSH_USER" | tr -d '\r\n\t ')"
    if [[ -z "$ssh_user_clean" ]]; then
      ni_fail 2 usage "--ssh-user is required for task 19"
    fi
    # The value becomes `ssh user@host` run as root: a leading "-" would be
    # taken as an ssh option, so only a plain account name is accepted.
    if [[ ! "$ssh_user_clean" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      ni_fail 2 usage "--ssh-user may only contain letters, digits, '.', '_' and '-' and must not start with '-': $_LSS_NI_SSH_USER"
    fi
    _LSS_NI_SSH_USER="$ssh_user_clean"
    if [[ -z "$_LSS_NI_SSH_PASSWORD" ]]; then
      ni_fail 2 usage "LSS_SSH_PASSWORD must be set in the environment for task 19 (the password is never accepted on the command line)"
    fi
    if [[ -n "$_LSS_NI_CONTROLLER_PORT" ]]; then
      # Canonical decimal only: `[[ 08 -lt 1 ]]` is an octal arithmetic error
      # that used to wave 08/09 through, and 010 is 8 to bash but 10 to a
      # human. Regex without a leading zero, then a forced base-10 range check.
      port_num=0
      if [[ "$_LSS_NI_CONTROLLER_PORT" =~ ^[1-9][0-9]{0,4}$ ]]; then
        port_num=$((10#$_LSS_NI_CONTROLLER_PORT))
      fi
      if [[ "$port_num" -lt 1 || "$port_num" -gt 65535 ]]; then
        ni_fail 2 usage "--controller-port must be a decimal number from 1 to 65535 with no leading zeros: $_LSS_NI_CONTROLLER_PORT"
      fi
      _LSS_NI_CONTROLLER_PORT="$port_num"
    fi
    if [[ -n "$_LSS_NI_HTTPS" && ! "$_LSS_NI_HTTPS" =~ ^[YyNn]$ ]]; then
      ni_fail 2 usage "--https must be y or n"
    fi
    if [[ -n "$_LSS_NI_CONTROLLER" ]]; then
      host="$_LSS_NI_CONTROLLER"
      host="${host#http://}"
      host="${host#https://}"
      host="${host%%/*}"
      host="${host%%:*}"
      if [[ ! "$host" =~ ^[A-Za-z0-9.-]+$ ]]; then
        ni_fail 2 usage "Invalid --controller host: $_LSS_NI_CONTROLLER"
      fi
    fi
  fi

  # ── Stress consent (exit 4) ──────────────────────────────────────────────
  if [[ "$needs_consent" -eq 1 && "$_LSS_NI_STRESS_CONSENT" -ne 1 ]]; then
    ni_fail 4 consent_required "The selection includes a stress test (task 10, 14 or 000); pass --yes to accept possible service impact"
  fi
  return 0
}

# "mtime:size" of a file, empty when absent — used to tell whether a task
# rewrote its single JSON file.
ni_file_signature() {
  local f="$1"
  if [[ -z "$f" || ! -f "$f" ]]; then
    printf ''
    return 0
  fi
  # GNU stat first: on Linux `stat -f` means filesystem status.
  stat -c '%Y:%s' "$f" 2>/dev/null || stat -f '%m:%z' "$f" 2>/dev/null || printf 'exists'
}

# Lines of $2 that are not in $1 (set difference, order of $2 preserved).
ni_new_lines() {
  local before="$1" after="$2" line b found
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found=0
    while IFS= read -r b; do
      if [[ "$b" == "$line" ]]; then
        found=1
      fi
    done <<< "$before"
    if [[ "$found" -eq 0 ]]; then
      printf '%s\n' "$line"
    fi
  done <<< "$after"
  return 0
}

# Report name recorded in a run's manifest (basename, *.txt) or empty.
ni_manifest_report_name() {
  local manifest="$1" name
  name="$(jq -r '.report_file // empty' "$manifest" 2>/dev/null || true)"
  if [[ -n "$name" && "$name" != "null" && "$name" != */* && "$name" == *.txt ]]; then
    printf '%s' "$name"
  fi
  return 0
}

# True when at least one task has usable JSON in the current run directory
# (earlier invocations of a continued run included). This is the report gate
# of run_noninteractive: finalize_run's own "*.json exists" test would be
# satisfied by the manifest the dispatcher rewrites after every task.
ni_run_has_task_output() {
  local id
  for id in $(get_task_ids); do
    if [[ -n "$(task_json_files "$id" 2>/dev/null)" ]]; then
      return 0
    fi
  done
  return 1
}

# Dispatcher for --run-task. Called with set -e ignored (`run_noninteractive
# && … || …` at top level), so every failure is handled explicitly here.
run_noninteractive() {
  local -a ids=()
  local id idx=0 total title rc status created
  local before_sig after_sig before_list after_list new_files single_path last_file f
  local overall_rc=0 report_name manifest_prepared_by pdf_path pdf_before pdf_after
  local yellow='\033[1;33m'
  local cyan='\033[0;36m'
  local bold='\033[1m'
  local reset='\033[0m'

  read -r -a ids <<< "$_LSS_NI_TASK_IDS"
  total="${#ids[@]}"

  SELECTED_INTERFACE="$_LSS_NI_INTERFACE"

  # ── Run context ──────────────────────────────────────────────────────────
  if [[ -n "$_LSS_NI_RUN_DIR" ]]; then
    # Same assignments continue_run_from_dir makes; SESSION_DEBUG_LOG is left
    # alone (tee is bound to it and finalize_run copies it to debug.txt).
    RUN_OUTPUT_DIR="$_LSS_NI_RUN_DIR"
    RUN_DEBUG_LOG="$RUN_OUTPUT_DIR/debug.txt"
    RUN_MANIFEST_FILE="$RUN_OUTPUT_DIR/manifest.json"
    load_run_metadata_from_dir "$RUN_OUTPUT_DIR"
    SELECTED_INTERFACE="$_LSS_NI_INTERFACE"
    report_name="$(ni_manifest_report_name "$RUN_MANIFEST_FILE")"
    if [[ -n "$report_name" ]]; then
      RUN_REPORT_FILE="$RUN_OUTPUT_DIR/$report_name"
    else
      RUN_REPORT_FILE=""
    fi
    manifest_prepared_by="$(jq -r '.prepared_by // empty' "$RUN_MANIFEST_FILE" 2>/dev/null || true)"
    if [[ -n "$manifest_prepared_by" && "$manifest_prepared_by" != "null" ]]; then
      RUN_PREPARED_BY="$manifest_prepared_by"
    fi
    mkdir -p "$(current_raw_output_dir)" 2>/dev/null || true
    created=false
    echo
    printf "  ${cyan}Continuing run:${reset} %s\n" "$RUN_OUTPUT_DIR"
    echo
  else
    initialize_run_context_from_values "$_LSS_NI_CLIENT" "$_LSS_NI_LOCATION" "$_LSS_NI_NOTE"
    created=true
  fi
  if [[ -n "$_LSS_NI_PREPARED_BY" ]]; then
    RUN_PREPARED_BY="$_LSS_NI_PREPARED_BY"
  fi
  if [[ -z "$RUN_OUTPUT_DIR" || ! -d "$RUN_OUTPUT_DIR" ]]; then
    RUN_OUTPUT_DIR=""
    ni_fail 1 run_dir_unavailable "The run directory could not be created under $OUTPUT_DIR"
  fi
  emit_progress run_dir "$(json_str_field path "$RUN_OUTPUT_DIR")" "$(json_raw_field created "$created")"

  # ── Interface warning (same text as select_interface; never fatal) ──────
  if ! interface_has_valid_ip "$SELECTED_INTERFACE"; then
    echo
    if interface_has_ipv4 "$SELECTED_INTERFACE"; then
      printf "  Warning: %s has a self-assigned address (169.254.x.x) — no DHCP lease.\n" "$SELECTED_INTERFACE"
      printf "  The interface is up but has no routable IP. Check your cable or DHCP server.\n"
      emit_progress warning "$(json_str_field code interface_no_ip)" \
        "$(json_str_field message "Interface $SELECTED_INTERFACE has a self-assigned address (169.254.x.x) — no DHCP lease")"
    else
      printf "  Warning: %s does not currently have an IPv4 address.\n" "$SELECTED_INTERFACE"
      printf "  Interface info and network-range scans may fail on bridge/physical-only interfaces.\n"
      emit_progress warning "$(json_str_field code interface_no_ip)" \
        "$(json_str_field message "Interface $SELECTED_INTERFACE does not currently have an IPv4 address")"
    fi
    echo
  fi

  # ── Tasks ────────────────────────────────────────────────────────────────
  SHOW_FUNCTION_HEADER=0
  TASK_OUTPUT_INDENT=""

  for id in ${ids[@]+"${ids[@]}"}; do
    idx=$((idx + 1))
    title="$(task_title "$id")"
    echo
    printf "  ${yellow}${bold}Task %s — %s${reset}\n" "$id" "$title"
    printf "  ${cyan}%s${reset}\n" "$(task_description "$id")"
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    echo
    emit_progress task_start "$(json_raw_field task "$id")" "$(json_str_field title "$title")" \
      "$(json_raw_field index "$idx")" "$(json_raw_field total "$total")"

    if task_supports_multiple_entries "$id"; then
      before_list="$(task_json_files "$id" 2>/dev/null || true)"
      before_sig=""
    else
      single_path="$(task_output_path "$id" 2>/dev/null || true)"
      before_sig="$(ni_file_signature "$single_path")"
      before_list=""
    fi

    # Same `if` form as the interactive wrappers: errexit and the ERR trap
    # are inert inside the task, exactly as they are today.
    if run_task_by_id "$id"; then
      rc=0
    else
      rc=$?
    fi

    new_files=""
    if task_supports_multiple_entries "$id"; then
      after_list="$(task_json_files "$id" 2>/dev/null || true)"
      new_files="$(ni_new_lines "$before_list" "$after_list")"
    else
      after_sig="$(ni_file_signature "$single_path")"
      if [[ -n "$after_sig" && "$after_sig" != "$before_sig" ]] && json_file_usable "$single_path"; then
        new_files="$single_path"
      fi
    fi

    status="no_output"
    if [[ -n "$new_files" ]]; then
      last_file="$(printf '%s\n' "$new_files" | tail -n 1)"
      status="$(jq -r '.status // "unknown"' "$last_file" 2>/dev/null || true)"
      if [[ -z "$status" || "$status" == "null" ]]; then
        status="unknown"
      fi
    fi
    case "$status" in
      success|completed_with_warnings|skipped) ;;
      *) overall_rc=1 ;;
    esac

    local -a new_basenames=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && new_basenames+=("$(basename "$f")")
    done <<< "$new_files"
    emit_progress task_done "$(json_raw_field task "$id")" "$(json_str_field status "$status")" \
      "$(json_raw_field rc "$rc")" "$(json_str_array json_files ${new_basenames[@]+"${new_basenames[@]}"})"

    echo
    printf "  ${cyan}──────────────────────────────────────────────────${reset}\n"
    printf "  Task %s finished: %s (exit %s)\n" "$id" "$status" "$rc"

    # Keep the manifest current so a browser refreshing on task_done sees it.
    write_manifest_for_current_run >/dev/null 2>&1 || true
  done

  # ── Report, PDF, bye ─────────────────────────────────────────────────────
  echo
  if ! ni_run_has_task_output; then
    # No task JSON anywhere in the run (finalize_run's own gate is already
    # satisfied by the manifest rewritten above): no report, no PDF, and —
    # as in the interactive main loop — a run directory this invocation
    # created is removed again. The exit code is unchanged: every requested
    # task was failed/no_output, so overall_rc is already 1.
    printf "  No task wrote a result; no report was built.\n"
    emit_progress warning "$(json_str_field code no_report)" \
      "$(json_str_field message "No task wrote a result; no report was built")"
    if [[ "$created" == "true" ]]; then
      rm -rf "$RUN_OUTPUT_DIR" 2>/dev/null || true
      printf "  Run directory removed: %s\n" "$RUN_OUTPUT_DIR"
    fi
  else
    finalize_run || true
    if [[ -n "$RUN_REPORT_FILE" && -f "$RUN_REPORT_FILE" ]]; then
      emit_progress report_built "$(json_str_field txt "$(basename "$RUN_REPORT_FILE")")" \
        "$(json_str_field path "$RUN_REPORT_FILE")"
      if [[ "$_LSS_NI_NO_PDF" -ne 1 ]]; then
        pdf_path="${RUN_REPORT_FILE%.txt}.pdf"
        pdf_before="$(ni_file_signature "$pdf_path")"
        generate_pdf_report || true
        pdf_after="$(ni_file_signature "$pdf_path")"
        if [[ -f "$pdf_path" && "$pdf_after" != "$pdf_before" ]]; then
          emit_progress pdf_built "$(json_str_field pdf "$(basename "$pdf_path")")" \
            "$(json_str_field path "$pdf_path")"
        else
          emit_progress pdf_failed "$(json_str_field message "${_LSS_PDF_LAST_ERROR:-PDF was not generated}")"
        fi
      fi
    else
      emit_progress warning "$(json_str_field code report_failed)" \
        "$(json_str_field message "The report could not be built for $RUN_OUTPUT_DIR")"
    fi
  fi

  # Clear so the EXIT trap does not build the report a second time.
  RUN_OUTPUT_DIR=""
  emit_bye "$overall_rc"
  return "$overall_rc"
}

# Dispatcher for --build-report <run-dir>: the interactive "Build A Report"
# flow (build_report_for_run_dir) without its prompts.
run_build_report() {
  local run_dir="$_LSS_NI_BUILD_REPORT_DIR"
  local export_dir="$_LSS_NI_OUTPUT_DIR"
  local report_name manifest_prepared_by pdf_path pdf_before pdf_after

  RUN_OUTPUT_DIR="$run_dir"
  RUN_DEBUG_LOG="$run_dir/debug.txt"
  RUN_MANIFEST_FILE="$run_dir/manifest.json"
  load_run_metadata_from_dir "$run_dir"

  if [[ -n "$_LSS_NI_PREPARED_BY" ]]; then
    RUN_PREPARED_BY="$_LSS_NI_PREPARED_BY"
  else
    manifest_prepared_by="$(jq -r '.prepared_by // empty' "$RUN_MANIFEST_FILE" 2>/dev/null || true)"
    if [[ -n "$manifest_prepared_by" && "$manifest_prepared_by" != "null" ]]; then
      RUN_PREPARED_BY="$manifest_prepared_by"
    fi
  fi

  if [[ -n "$export_dir" ]]; then
    if ! mkdir -p "$export_dir" 2>/dev/null; then
      RUN_OUTPUT_DIR=""
      ni_fail 1 output_dir_unavailable "Unable to create or access directory: $export_dir"
    fi
    RUN_REPORT_FILE="$export_dir/lss-network-tools-report-$(basename "$run_dir")-$(date '+%H-%M').txt"
  else
    report_name="$(ni_manifest_report_name "$RUN_MANIFEST_FILE")"
    if [[ -n "$report_name" ]]; then
      RUN_REPORT_FILE="$run_dir/$report_name"
    else
      RUN_REPORT_FILE=""
    fi
  fi
  emit_progress run_dir "$(json_str_field path "$run_dir")" "$(json_raw_field created false)"

  if ! build_report_for_current_run; then
    RUN_OUTPUT_DIR=""
    ni_fail 1 report_failed "The report could not be built for $run_dir"
  fi
  printf "  TXT report:    %s\n" "$RUN_REPORT_FILE"
  emit_progress report_built "$(json_str_field txt "$(basename "$RUN_REPORT_FILE")")" \
    "$(json_str_field path "$RUN_REPORT_FILE")"

  # The PDF renders from the manifest, so it must reflect the files present now.
  write_manifest_for_current_run || true

  if [[ "$_LSS_NI_NO_PDF" -ne 1 ]]; then
    pdf_path="${RUN_REPORT_FILE%.txt}.pdf"
    pdf_before="$(ni_file_signature "$pdf_path")"
    generate_pdf_report || true
    pdf_after="$(ni_file_signature "$pdf_path")"
    if [[ -f "$pdf_path" && "$pdf_after" != "$pdf_before" ]]; then
      emit_progress pdf_built "$(json_str_field pdf "$(basename "$pdf_path")")" \
        "$(json_str_field path "$pdf_path")"
    else
      emit_progress pdf_failed "$(json_str_field message "${_LSS_PDF_LAST_ERROR:-PDF was not generated}")"
    fi
  fi

  RUN_OUTPUT_DIR=""
  emit_bye 0
  return 0
}

# Dispatcher for --delete-run <run-dir>: the interactive "000) Delete This
# Run" without its prompt. The directory was validated by
# noninteractive_validate; hello was emitted by noninteractive_hello.
run_delete_run() {
  local run_dir="$_LSS_NI_DELETE_RUN_DIR"

  printf "  Deleting run directory: %s\n" "$run_dir"
  if ! delete_run_directory "$run_dir" || [[ -e "$run_dir" || -L "$run_dir" ]]; then
    # A partial rm -rf may have left a remnant without manifest/JSON/report that
    # --delete-run will refuse next time as "not a run"; tell the user how to finish.
    ni_fail 1 delete_failed "The run directory could not be removed (remove what is left by hand with: sudo rm -rf '$run_dir'): $run_dir"
  fi
  printf "  Run deleted.\n"
  emit_progress run_deleted "$(json_str_field path "$run_dir")"
  emit_bye 0
  return 0
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
  # Under set -e a bare failing call would exit before `exit $?` runs.
  if build_wifi_scan_helper_macos; then
    exit 0
  fi
  exit 1
fi
if [[ "$WRITE_COMPLETIONS_MODE" -eq 1 ]]; then
  detect_os
  write_completion_files
  exit 0
fi
if [[ "$INSTALL_DEPS_MODE" -eq 1 ]]; then
  detect_os
  # Optional tools added after the initial release. Failures are non-fatal.
  # Format: "command|brew formula|apt package|used by"
  for _dep in "sshpass|hudochenkov/sshpass/sshpass|sshpass|Task 19" "arp-scan|arp-scan|arp-scan|Task 12"; do
    IFS='|' read -r _dep_cmd _dep_brew _dep_apt _dep_use <<< "$_dep"
    command -v "$_dep_cmd" >/dev/null 2>&1 && continue
    echo "Installing $_dep_cmd ($_dep_use)..."
    if [[ "$OS" == "macos" ]]; then
      _brew_user="${SUDO_USER:-}"
      if [[ -n "$_brew_user" && "$_brew_user" != "root" ]]; then
        sudo -u "$_brew_user" brew install "$_dep_brew" >/dev/null 2>&1 \
          || echo "  Could not install $_dep_cmd — run: brew install $_dep_brew"
      else
        echo "  Could not install $_dep_cmd — run: brew install $_dep_brew"
      fi
    else
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y "$_dep_apt" >/dev/null 2>&1 \
          || echo "  Could not install $_dep_cmd — run: sudo apt install $_dep_apt"
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$_dep_apt" >/dev/null 2>&1 \
          || echo "  Could not install $_dep_cmd — run: sudo dnf install $_dep_apt"
      else
        echo "  Could not install $_dep_cmd — install package: $_dep_apt"
      fi
    fi
  done
  exit 0
fi
# ── Non-interactive mode (--run-task / --build-report / --delete-run) ───────
# Open the progress channel before anything else can write to stderr and
# before initialize_debug_logging merges fd 1/2 into the tee. `--run-task
# list` needs neither OS detection nor root.
if [[ "$RUN_TASK_MODE" -eq 1 || "$BUILD_REPORT_MODE" -eq 1 || "$DELETE_RUN_MODE" -eq 1 ]]; then
  noninteractive_setup
  if [[ "$RUN_TASK_MODE" -eq 1 && "$_LSS_NI_RUN_TASK" == "list" ]]; then
    if ! ni_list_args_only "$@"; then
      noninteractive_usage_error "--run-task list cannot be combined with other options"
    fi
    print_task_listing_json
    exit 0
  fi
  if [[ "$DELETE_RUN_MODE" -eq 1 ]] && ! ni_delete_args_only "$@"; then
    noninteractive_usage_error "--delete-run accepts only --debug (it cannot be combined with --run-task, --build-report or the run flags)"
  fi
  noninteractive_hello
fi
detect_os
ensure_standard_path
configure_runtime_paths
if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
  # Validate before anything that needs root so a request can be pre-flighted
  # as an unprivileged user (exit 2/4). Directory creation is non-fatal here:
  # as non-root in installed mode it may fail, and the root check exits 5.
  noninteractive_validate
  ensure_runtime_directories 2>/dev/null || true
else
  ensure_runtime_directories
fi
if [[ "$UNINSTALL_MODE" -eq 1 ]]; then
  uninstall_installed_application
  exit $?
fi
if [[ "$UPDATE_MODE" -eq 1 ]]; then
  check_for_updates
  exit $?
fi
detect_output_tty
if [[ "${_LSS_NONINTERACTIVE:-}" != "1" ]]; then
  clear_screen_if_supported
fi
check_tools
if [[ "${_LSS_NONINTERACTIVE:-}" == "1" ]]; then
  # The tasks need root; warn_if_not_root is interactive-only.
  if [[ "$EUID" -ne 0 ]]; then
    ni_fail 5 not_root "This program must be run with elevated privileges (sudo lss-network-tools ...)"
  fi
else
  warn_if_not_root
fi
initialize_debug_logging
trap on_exit_trap EXIT
trap on_interrupt INT TERM
trap handle_err_exit ERR

# Prevent macOS display/idle sleep while the tool is running.
# -d: display sleep, -i: idle sleep, -w $$: auto-exit when this process exits.
# -s (system sleep on AC) is intentionally omitted — it is silently ignored or
# actively terminated by macOS when the machine is on battery, which causes a
# "Terminated: 15" message to bleed into the UI.
if [[ "$OS" == "macos" ]] && command -v caffeinate >/dev/null 2>&1; then
  caffeinate -d -i -w $$ &
  CAFFEINATE_PID=$!
  disown "$CAFFEINATE_PID" 2>/dev/null || true
fi

# Non-interactive dispatch: no banner, no update check, no menus. The `&& ||`
# form keeps set -e out of the dispatcher (see run_noninteractive).
if [[ "$RUN_TASK_MODE" -eq 1 ]]; then
  run_noninteractive && _lss_ni_rc=0 || _lss_ni_rc=$?
  exit "$_lss_ni_rc"
fi
if [[ "$BUILD_REPORT_MODE" -eq 1 ]]; then
  run_build_report && _lss_ni_rc=0 || _lss_ni_rc=$?
  exit "$_lss_ni_rc"
fi
if [[ "$DELETE_RUN_MODE" -eq 1 ]]; then
  run_delete_run && _lss_ni_rc=0 || _lss_ni_rc=$?
  exit "$_lss_ni_rc"
fi

# Quick synchronous update check (3s timeout) — result stored in variable
# and displayed as a banner in startup_menu if a newer version is available.
_LSS_UPDATE_BANNER=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  _latest_tag="$(curl --max-time 2 -fsSL \
    "https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=10" 2>/dev/null \
    | jq -r '.[].name' 2>/dev/null | sort -V | tail -n 1)" || true
  # Banner only when the remote is strictly newer (a local build ahead of the
  # latest tag is not "out of date").
  if [[ "$_latest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$_latest_tag" != "$APP_VERSION" ]] \
     && [[ "$(printf '%s\n%s\n' "$APP_VERSION" "$_latest_tag" | sort -V | tail -n 1)" == "$_latest_tag" ]]; then
    _LSS_UPDATE_BANNER="$_latest_tag"
  fi
fi

_START_FRESH_RUN=false
while true; do
  startup_menu
  _START_FRESH_RUN=false
  if ! select_interface; then
    continue
  fi
  initialize_run_context
  main_menu
  if [[ -n "$RUN_OUTPUT_DIR" ]] && [[ -n "$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]]; then
    echo
    read -r -p "  Save report? [y/N]: " _save_choice
    if [[ "$_save_choice" == "y" || "$_save_choice" == "Y" ]]; then
      finalize_run || true
      generate_pdf_report || true
      # Clear so the EXIT trap does not build the report a second time.
      RUN_OUTPUT_DIR=""
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
