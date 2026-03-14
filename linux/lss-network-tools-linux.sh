#!/usr/bin/env bash
set -e
set -o pipefail

VERSION="1.0.0"
REPO="korshakov/lss-network-tools"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$REPO_ROOT/analyzer-data"
ANALYZER_OUTPUT_FILES=(
  "interface-info.txt"
  "gateway-scan.txt"
  "dhcp-scan.txt"
  "web-interfaces.txt"
  "speed-test.txt"
  "dns-servers.txt"
  "file-servers.txt"
  "printers.txt"
  "network-dataset.json"
)

SESSION_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
SESSION_SCANS_EXECUTED=()

DATASET_INTERFACE_INFO=""
DATASET_GATEWAYS=""
DATASET_DNS_SERVERS=""
DATASET_DHCP_SERVERS=""
DATASET_FILE_SERVERS=""
DATASET_PRINTERS=""
DATASET_WEB_INTERFACES=""
DATASET_SPEED_TEST=""

reset_analyzer_data_dir() {
  mkdir -p "$DATA_DIR"
  rm -f "$DATA_DIR"/*
}

initialize_analyzer_output_files() {
  local output_file
  for output_file in "${ANALYZER_OUTPUT_FILES[@]}"; do
    : > "$DATA_DIR/$output_file"
  done
}

reset_analyzer_data_dir
initialize_analyzer_output_files

LOGFILE="$DATA_DIR/lss-netinfo-session.log"

: > "$LOGFILE"

start_new_audit_session() {
  reset_analyzer_data_dir
  initialize_analyzer_output_files
  : > "$LOGFILE"

  SESSION_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
  SESSION_SCANS_EXECUTED=()

  DATASET_INTERFACE_INFO=""
  DATASET_GATEWAYS=""
  DATASET_DNS_SERVERS=""
  DATASET_DHCP_SERVERS=""
  DATASET_FILE_SERVERS=""
  DATASET_PRINTERS=""
  DATASET_WEB_INTERFACES=""
  DATASET_SPEED_TEST=""
}

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

IF=""
CURRENT_GATEWAY=""

if [[ "$(uname)" != "Linux" ]]; then
  echo "This script is intended for Linux."
  exit 1
fi

if [[ "${1:-}" == "--version" ]]; then
  echo "LSS Network Tools v${VERSION}"
  exit 0
fi

print_info() {
  echo -e "${BLUE}$*${NC}"
}

print_ok() {
  echo -e "${GREEN}$*${NC}"
}

print_warn() {
  echo -e "${YELLOW}$*${NC}"
}

print_alert() {
  echo -e "${RED}$*${NC}"
}

log_echo() {
  echo "$*" | tee -a "$LOGFILE"
}

strip_colors() {
  sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

normalize_verification_content() {
  awk '
    {
      sub(/\r$/, "", $0)
      if ($0 ~ /^IP:[[:space:]]/) {
        if (seen_ip) print ""
        seen_ip=1
        print
        next
      }
      if ($0 ~ /^[[:space:]]*$/) next
      print
    }
  '
}

json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS="" } {
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    gsub(/\r/, "")
    if (NR > 1) printf "\\n"
    printf "%s", $0
  }'
}

write_scan_output() {
  local scan_name="$1"
  local output_file="$2"
  local discovery_count="$3"
  local raw_data="$4"
  local verification_data="$5"

  {
    echo "========================================"
    echo "SCAN: $scan_name"
    echo "========================================"
    echo ""
    echo "## SUMMARY"
    echo ""
    echo "Discovery entries: $discovery_count"
    echo ""
    echo "## RAW_DISCOVERY"
    echo ""

    if [ -z "$raw_data" ]; then
      echo "None"
    else
      echo "$raw_data"
    fi

    echo ""
    echo "## VERIFICATION"
    echo ""

    if [ -z "$verification_data" ]; then
      echo "None"
    else
      echo "$verification_data"
    fi

    echo ""
    echo "END_SECTION"
  } | strip_colors > "$output_file"
}

json_number_or_string() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '"%s"' "$(json_escape "$value")"
  fi
}

write_session_log_summary() {
  local end_time
  end_time="$(date '+%Y-%m-%d %H:%M:%S')"

  {
    echo "========================================"
    echo "LSS Network Tools Session Log"
    echo "========================================"
    echo
    echo "Start time: $SESSION_START_TIME"
    echo
    echo "Scans executed:"
    if [[ ${#SESSION_SCANS_EXECUTED[@]} -eq 0 ]]; then
      echo
      echo "* None"
    else
      local scan_name
      for scan_name in "${SESSION_SCANS_EXECUTED[@]}"; do
        echo
        echo "* $scan_name"
      done
    fi
    echo
    echo "End time: $end_time"
  } > "$LOGFILE"
}

generate_network_dataset() {
  local dataset_file interface_info gateways dns_servers dhcp_servers file_servers printers web_interfaces speed_test
  dataset_file="$DATA_DIR/network-dataset.json"

  interface_info="[]"
  if [[ -n "$DATASET_INTERFACE_INFO" && "$DATASET_INTERFACE_INFO" != "None" ]]; then
    IFS='|' read -r if_name if_ip if_subnet if_gateway <<< "$DATASET_INTERFACE_INFO"
    interface_info="[{\"interface\":\"$(json_escape "$if_name")\",\"ip\":\"$(json_escape "$if_ip")\",\"subnet\":\"$(json_escape "$if_subnet")\",\"gateway\":\"$(json_escape "$if_gateway")\"}]"
  fi

  gateways="[]"
  if [[ -n "$DATASET_GATEWAYS" && "$DATASET_GATEWAYS" != "None" ]]; then
    local first=1 line ip port service entry
    while IFS='|' read -r ip port; do
      [[ -z "$ip" || -z "$port" ]] && continue
      case "$port" in
        22) service="SSH" ;;
        53) service="DOMAIN" ;;
        80) service="HTTP" ;;
        443) service="HTTPS" ;;
        *) service="OPEN_PORT" ;;
      esac
      entry="{\"ip\":\"$(json_escape "$ip")\",\"port\":$(json_number_or_string "$port"),\"service\":\"$(json_escape "$service")\"}"
      if [[ $first -eq 1 ]]; then gateways="[$entry"; first=0; else gateways+=",$entry"; fi
    done <<< "$DATASET_GATEWAYS"
    [[ "$gateways" != "[]" && $first -eq 0 ]] && gateways+="]"
  fi

  dns_servers="[]"
  if [[ -n "$DATASET_DNS_SERVERS" && "$DATASET_DNS_SERVERS" != "None" ]]; then
    local first=1 line ip port status entry
    while IFS='|' read -r ip port status; do
      [[ -z "$ip" || -z "$port" ]] && continue
      status="${status:-Unknown}"
      entry="{\"ip\":\"$(json_escape "$ip")\",\"port\":$(json_number_or_string "$port"),\"status\":\"$(json_escape "$status")\"}"
      if [[ $first -eq 1 ]]; then dns_servers="[$entry"; first=0; else dns_servers+=",$entry"; fi
    done <<< "$DATASET_DNS_SERVERS"
    [[ "$dns_servers" != "[]" && $first -eq 0 ]] && dns_servers+="]"
  fi

  dhcp_servers="[]"
  if [[ -n "$DATASET_DHCP_SERVERS" && "$DATASET_DHCP_SERVERS" != "None" ]]; then
    local first=1 ip port entry
    while IFS='|' read -r ip port; do
      [[ -z "$ip" || -z "$port" ]] && continue
      entry="{\"ip\":\"$(json_escape "$ip")\",\"port\":$(json_number_or_string "$port"),\"status\":\"Offer detected\"}"
      if [[ $first -eq 1 ]]; then dhcp_servers="[$entry"; first=0; else dhcp_servers+=",$entry"; fi
    done <<< "$DATASET_DHCP_SERVERS"
    [[ "$dhcp_servers" != "[]" && $first -eq 0 ]] && dhcp_servers+="]"
  fi

  file_servers="[]"
  if [[ -n "$DATASET_FILE_SERVERS" && "$DATASET_FILE_SERVERS" != "None" ]]; then
    local first=1 ip port service entry
    while IFS='|' read -r ip port; do
      [[ -z "$ip" || -z "$port" ]] && continue
      case "$port" in
        21) service="FTP Server" ;;
        22) service="SSH / SFTP File Access" ;;
        139) service="SMB (NetBIOS)" ;;
        445) service="SMB File Share" ;;
        2049) service="NFS Server" ;;
        548) service="AFP (Apple File Server)" ;;
        *) service="Unknown File Service" ;;
      esac
      entry="{\"ip\":\"$(json_escape "$ip")\",\"port\":$(json_number_or_string "$port"),\"service\":\"$(json_escape "$service")\"}"
      if [[ $first -eq 1 ]]; then file_servers="[$entry"; first=0; else file_servers+=",$entry"; fi
    done <<< "$DATASET_FILE_SERVERS"
    [[ "$file_servers" != "[]" && $first -eq 0 ]] && file_servers+="]"
  fi

  printers="[]"
  if [[ -n "$DATASET_PRINTERS" && "$DATASET_PRINTERS" != "None" ]]; then
    local first=1 ip port service entry
    while IFS='|' read -r ip port; do
      [[ -z "$ip" || -z "$port" ]] && continue
      case "$port" in
        515) service="LPD Printer Service" ;;
        631) service="IPP Printer Service" ;;
        9100) service="JetDirect Printer Port" ;;
        *) service="Unknown Printer Service" ;;
      esac
      entry="{\"ip\":\"$(json_escape "$ip")\",\"port\":$(json_number_or_string "$port"),\"service\":\"$(json_escape "$service")\"}"
      if [[ $first -eq 1 ]]; then printers="[$entry"; first=0; else printers+=",$entry"; fi
    done <<< "$DATASET_PRINTERS"
    [[ "$printers" != "[]" && $first -eq 0 ]] && printers+="]"
  fi

  web_interfaces="[]"
  if [[ -n "$DATASET_WEB_INTERFACES" && "$DATASET_WEB_INTERFACES" != "None" ]]; then
    local first=1 ip port url scheme entry
    while IFS='|' read -r ip port; do
      [[ -z "$ip" || -z "$port" ]] && continue
      if [[ "$port" == "443" || "$port" == "8443" ]]; then scheme="https"; else scheme="http"; fi
      if [[ "$port" == "80" || "$port" == "443" ]]; then
        url="$scheme://$ip"
      else
        url="$scheme://$ip:$port"
      fi
      entry="{\"ip\":\"$(json_escape "$ip")\",\"port\":$(json_number_or_string "$port"),\"url\":\"$(json_escape "$url")\",\"status\":\"OK\"}"
      if [[ $first -eq 1 ]]; then web_interfaces="[$entry"; first=0; else web_interfaces+=",$entry"; fi
    done <<< "$DATASET_WEB_INTERFACES"
    [[ "$web_interfaces" != "[]" && $first -eq 0 ]] && web_interfaces+="]"
  fi

  speed_test='{}'
  if [[ -n "$DATASET_SPEED_TEST" && "$DATASET_SPEED_TEST" != "None" ]]; then
    local download upload key value
    while IFS='|' read -r key value; do
      case "$key" in
        DOWNLOAD) download="$value" ;;
        UPLOAD) upload="$value" ;;
      esac
    done <<< "$DATASET_SPEED_TEST"
    speed_test="{\"download\":\"$(json_escape "${download:-N/A}")\",\"upload\":\"$(json_escape "${upload:-N/A}")\"}"
  fi

  if command -v jq >/dev/null 2>&1; then
    printf '{"interface_info":%s,"gateways":%s,"dns_servers":%s,"dhcp_servers":%s,"file_servers":%s,"printers":%s,"web_interfaces":%s,"speed_test":%s}\n' \
      "$interface_info" "$gateways" "$dns_servers" "$dhcp_servers" "$file_servers" "$printers" "$web_interfaces" "$speed_test" \
      | jq '.' > "$dataset_file"
  else
    printf '{\n  "interface_info": %s,\n  "gateways": %s,\n  "dns_servers": %s,\n  "dhcp_servers": %s,\n  "file_servers": %s,\n  "printers": %s,\n  "web_interfaces": %s,\n  "speed_test": %s\n}\n' \
      "$interface_info" "$gateways" "$dns_servers" "$dhcp_servers" "$file_servers" "$printers" "$web_interfaces" "$speed_test" > "$dataset_file"
  fi
}

extract_dns_status_for_dataset() {
  local ip="$1"
  local port="$2"
  local verification="$3"

  awk -v target_ip="$ip" -v target_port="$port" '
    function normalize_status(raw, result) {
      result = raw
      if (raw == "Responding" || raw == "DNS over TLS detected" || raw == "DNS over HTTPS detected") result = "Responding"
      else if (raw == "HTTPS DNS endpoint not confirmed") result = "Not Confirmed"
      else if (raw == "TLS check failed") result = "TLS Failed"
      return result
    }
    /^IP:[[:space:]]*/ { ip=$0; sub(/^IP:[[:space:]]*/, "", ip); next }
    /^Port:[[:space:]]*/ { port=$0; sub(/^Port:[[:space:]]*/, "", port); next }
    /^Status:[[:space:]]*/ {
      status=$0
      sub(/^Status:[[:space:]]*/, "", status)
      if (ip == target_ip && port == target_port) {
        print normalize_status(status)
        found=1
        exit
      }
      next
    }
    END {
      if (!found) print "Unknown"
    }
  ' <<< "$verification"
}

build_dns_dataset_rows() {
  local raw_data="$1"
  local verification_data="$2"
  local dns_rows=""
  local ip port status

  while IFS='|' read -r ip port; do
    [[ -z "$ip" || -z "$port" ]] && continue
    status="$(extract_dns_status_for_dataset "$ip" "$port" "$verification_data")"
    dns_rows+="${ip}|${port}|${status}"$'\n'
  done <<< "$raw_data"

  printf '%s' "$dns_rows" | sed '/^[[:space:]]*$/d'
}

record_scan_for_dataset() {
  local output_file="$1"
  local cleaned_raw
  cleaned_raw="$(printf '%s' "$SCAN_RAW_DISCOVERY" | strip_colors | sed '/^[[:space:]]*$/d')"
  case "$output_file" in
    interface-info.txt) DATASET_INTERFACE_INFO="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("Interface Info") ;;
    gateway-scan.txt) DATASET_GATEWAYS="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("Gateway Scan") ;;
    dns-servers.txt)
      DATASET_DNS_SERVERS="$(build_dns_dataset_rows "$cleaned_raw" "$SCAN_VERIFICATION")"
      SESSION_SCANS_EXECUTED+=("DNS Scan")
      ;;
    dhcp-scan.txt) DATASET_DHCP_SERVERS="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("DHCP Scan") ;;
    file-servers.txt) DATASET_FILE_SERVERS="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("File Servers") ;;
    printers.txt) DATASET_PRINTERS="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("Printers") ;;
    web-interfaces.txt) DATASET_WEB_INTERFACES="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("Web Interfaces") ;;
    speed-test.txt) DATASET_SPEED_TEST="$cleaned_raw"; SESSION_SCANS_EXECUTED+=("Speed Test") ;;
  esac
}

load_scan_raw_from_output() {
  local output_file="$1"
  local section
  section="$(awk '
    /^## RAW_DISCOVERY$/ { in_raw=1; next }
    /^## VERIFICATION$/ { in_raw=0 }
    in_raw { print }
  ' "$DATA_DIR/$output_file" | sed '/^[[:space:]]*$/d')"

  if [[ "$section" == "None" ]]; then
    printf ''
  else
    printf '%s' "$section"
  fi
}

init_scan_export_data() {
  SCAN_NAME="$1"
  SCAN_SUMMARY_COUNT="0"
  SCAN_RAW_DISCOVERY=""
  SCAN_VERIFICATION=""
}

run_scan_and_export() {
  local scan_function="$1"
  local output_file="$2"
  local raw_content verification_content

  "$scan_function"
  raw_content="$(printf "%s" "$SCAN_RAW_DISCOVERY" | strip_colors | sed '/^[[:space:]]*$/d')"
  verification_content="$(printf "%s" "$SCAN_VERIFICATION" | strip_colors | normalize_verification_content)"
  write_scan_output \
    "$SCAN_NAME" \
    "$DATA_DIR/$output_file" \
    "$SCAN_SUMMARY_COUNT" \
    "$raw_content" \
    "$verification_content"
  record_scan_for_dataset "$output_file"
  generate_network_dataset
  write_session_log_summary
}

print_none_if_empty() {
  local value="$1"

  if [ -z "$value" ]; then
    log_echo "None discovered on the network."
  else
    log_echo "$value"
  fi
}

spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\\'

  while ps -p $pid > /dev/null 2>&1; do
    local temp=${spinstr#?}
    printf " [%c] Scanning for active hosts..." "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\r"
  done

  printf "                                  \r"
}

check_dependency() {
  local dep="$1"
  if command -v "$dep" >/dev/null 2>&1; then
    printf "%-18s ${GREEN}PASS${NC}\n" "${dep}:"
    return 0
  fi

  printf "%-18s ${RED}FAIL${NC}\n" "${dep}:"
  return 1
}

install_missing_dependencies() {
  local dep
  for dep in "$@"; do
    sudo apt-get update
    sudo apt-get install -y "$dep"
  done
}

run_dependency_check() {
  local missing=()
  local dep

  echo
  echo "Dependency Check"
  echo "----------------"

  for dep in nmap dig arp-scan speedtest-cli curl; do
    if ! check_dependency "$dep"; then
      missing+=("$dep")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  echo
  read -r -p "Install missing dependencies? (y/n) " response
  if [[ "$response" != "y" && "$response" != "Y" ]]; then
    print_alert "Missing dependencies were not installed. Exiting."
    exit 1
  fi

  install_missing_dependencies "${missing[@]}"
}

version_gt() {
  local IFS=.
  local i
  local -a v1=($1) v2=($2)

  for ((i=${#v1[@]}; i<${#v2[@]}; i++)); do
    v1[i]=0
  done
  for ((i=${#v2[@]}; i<${#v1[@]}; i++)); do
    v2[i]=0
  done

  for ((i=0; i<${#v1[@]}; i++)); do
    if ((10#${v1[i]} > 10#${v2[i]})); then
      return 0
    fi
    if ((10#${v1[i]} < 10#${v2[i]})); then
      return 1
    fi
  done

  return 1
}

check_for_updates() {
  local api_url latest_json latest_tag latest_version tarball_url
  api_url="https://api.github.com/repos/${REPO}/releases/latest"

  latest_json="$(curl -fsSL "$api_url" 2>/dev/null || true)"
  [[ -z "$latest_json" ]] && return 0

  latest_tag="$(echo "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  tarball_url="$(echo "$latest_json" | sed -n 's/.*"tarball_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -z "$latest_tag" || -z "$tarball_url" ]] && return 0

  latest_version="${latest_tag#v}"

  if version_gt "$latest_version" "$VERSION"; then
    echo
    print_warn "Update available: ${latest_tag}"
    print_warn "Current version: v${VERSION}"
    echo
    read -r -p "Install update now? (y/n) " answer

    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
      install_update "$tarball_url"
    fi
  fi
}

install_update() {
  local tarball_url="$1"
  local tmp_dir archive script_source target_path

  tmp_dir="$(mktemp -d /tmp/lss-update.XXXXXX)"
  archive="$tmp_dir/release.tar.gz"

  print_info "Downloading latest release..."
  curl -fsSL "$tarball_url" -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"

  script_source="$(find "$tmp_dir" -type f -name 'lss-network-tools-linux.sh' | head -n1)"
  if [[ -z "$script_source" ]]; then
    print_alert "Update failed: script not found in release archive."
    rm -rf "$tmp_dir"
    return 1
  fi

  if [[ "$(basename "$0")" == "lss" && -w "$(command -v lss 2>/dev/null || true)" ]]; then
    target_path="$(command -v lss)"
  elif [[ "$(basename "$0")" == "lss" ]]; then
    target_path="$(command -v lss)"
    sudo cp "$script_source" "$target_path"
    sudo chmod +x "$target_path"
    rm -rf "$tmp_dir"
    print_ok "Update installed successfully. Restarting..."
    exec "$0"
  else
    target_path="$0"
  fi

  cp "$script_source" "$target_path"
  chmod +x "$target_path"
  rm -rf "$tmp_dir"

  print_ok "Update installed successfully. Restarting..."
  exec "$0"
}

get_interfaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -v lo
}

select_interface() {
  local choice
  while true; do
    echo
    echo "================================="
    echo " Select Network Interface"
    echo "================================="

    interfaces=()
    while IFS= read -r line; do
      interfaces+=("$line")
    done < <(get_interfaces)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
      print_alert "No usable network interfaces found."
      exit 1
    fi

    local i=1
    local iface port dev
    for iface in "${interfaces[@]}"; do
      echo "$i) $iface"
      ((i++))
    done

    echo
    echo "0) Exit"
    echo
    read -r -p "Select interface: " choice

    if [[ "$choice" == "0" ]]; then
      exit 0
    fi

    IF="${interfaces[$((choice - 1))]:-}"

    if [[ -n "$IF" ]]; then
      print_ok "Selected interface: $IF"
      break
    fi

    print_warn "Invalid option."
  done
}

get_gateway() {
  ip route | grep default | awk '{print $3}' | head -n1
}

get_network() {
  ip -4 addr show "$IF" | grep inet | awk '{print $2; exit}'
}

colorize_scan_output() {
  awk -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v nc="$NC" '
    /Nmap done|Host is up|open|ports/ { print green $0 nc; next }
    /80\/tcp|443\/tcp|8080\/tcp|8443\/tcp|http|https|VNC|RDP|SSH/ { print yellow $0 nc; next }
    /DHCP Message Type|DHCPOFFER|rogue|unexpected|WARNING|CRITICAL/ { print red $0 nc; next }
    { print }
  '
}

run_scan() {
  local title="$1"
  local cmd="$2"
  local scan_output_file="/tmp/lss-scan-output"

  echo | tee -a "$LOGFILE"
  echo "$title" | tee -a "$LOGFILE"
  echo "----------------" | tee -a "$LOGFILE"

  echo "----------------------------------------" | tee -a "$LOGFILE"
  echo "$title" | tee -a "$LOGFILE"
  echo "----------------------------------------" | tee -a "$LOGFILE"

  eval "$cmd" > "$scan_output_file" 2>&1

  cat "$scan_output_file" | tee -a "$LOGFILE" | colorize_scan_output

  echo | tee -a "$LOGFILE"
  echo "----------------------------------------" | tee -a "$LOGFILE"
  echo "$title complete" | tee -a "$LOGFILE"
  echo "----------------------------------------" | tee -a "$LOGFILE"
}

extract_discovered_hosts() {
  local discovery_file="$1"
  awk '
    /^Nmap scan report for / {
      ip=$NF
      vendor="Unknown"
      while (getline > 0) {
        if ($0 ~ /^Nmap scan report for / || $0 ~ /^Nmap done/ || $0 ~ /^$/) {
          break
        }
        if ($0 ~ /MAC Address:/) {
          split($0, a, "(")
          vendor=a[2]
          gsub(/\)/, "", vendor)
          break
        }
      }
      print ip "|" vendor
    }
  ' "$discovery_file"
}

port_in_list() {
  local needle="$1"
  local list=",$2,"
  [[ "$list" == *",$needle,"* ]]
}

classify_device_type() {
  local vendor="$1"
  local ports="$2"
  local services="$3"
  local os_name="$4"

  local has22=0 has80=0 has443=0 has445=0 has554=0 has515=0 has631=0 has9100=0
  local has3306=0 has5432=0 has5000=0 has5001=0 has8443=0
  local server_score=0

  port_in_list 22 "$ports" && has22=1
  port_in_list 80 "$ports" && has80=1
  port_in_list 443 "$ports" && has443=1
  port_in_list 445 "$ports" && has445=1
  port_in_list 554 "$ports" && has554=1
  port_in_list 515 "$ports" && has515=1
  port_in_list 631 "$ports" && has631=1
  port_in_list 9100 "$ports" && has9100=1
  port_in_list 3306 "$ports" && has3306=1
  port_in_list 5432 "$ports" && has5432=1
  port_in_list 5000 "$ports" && has5000=1
  port_in_list 5001 "$ports" && has5001=1
  port_in_list 8443 "$ports" && has8443=1

  if [[ "$vendor" =~ (HP|Brother|Canon|Epson|Lexmark|Xerox) ]] && [[ $has9100 -eq 1 || $has631 -eq 1 || $has515 -eq 1 ]]; then
    echo "Printer"
    return
  fi

  if [[ "$vendor" =~ (Synology|QNAP|Asustor|Western[[:space:]]Digital) ]] && [[ $has5000 -eq 1 || $has5001 -eq 1 || $has445 -eq 1 ]]; then
    echo "NAS"
    return
  fi

  if [[ "$vendor" =~ (Ubiquiti|Cisco|MikroTik|Juniper|Fortinet|Netgear|TP-Link|ASUS|Protectli) ]] && [[ $has80 -eq 1 || $has443 -eq 1 ]] && [[ $has22 -eq 1 || $has8443 -eq 1 ]]; then
    echo "Router"
    return
  fi

  if [[ "$vendor" =~ (Ubiquiti|Aruba|Ruckus|TP-Link) ]] && [[ $has80 -eq 1 || $has443 -eq 1 ]]; then
    echo "Access Point"
    return
  fi

  if [[ "$vendor" =~ (Tuya|Espressif|Xiaomi|Sonoff) ]] && [[ $has80 -eq 1 || $has443 -eq 1 || $has554 -eq 1 ]]; then
    echo "IoT Device"
    return
  fi

  [[ $has22 -eq 1 ]] && ((server_score++))
  [[ $has80 -eq 1 ]] && ((server_score++))
  [[ $has443 -eq 1 ]] && ((server_score++))
  [[ $has445 -eq 1 ]] && ((server_score++))
  [[ $has3306 -eq 1 ]] && ((server_score++))
  [[ $has5432 -eq 1 ]] && ((server_score++))

  if [[ $server_score -ge 2 ]]; then
    echo "Server"
    return
  fi

  if [[ "$vendor" =~ (Apple|Dell|Lenovo|HP) ]] && [[ $server_score -le 1 ]]; then
    echo "Workstation"
    return
  fi

  if [[ "$os_name" =~ (Windows|Darwin|macOS) ]] && [[ $server_score -le 1 ]]; then
    echo "Workstation"
    return
  fi

  if [[ "$services" =~ (ipp|printer|jetdirect) ]]; then
    echo "Printer"
    return
  fi

  echo "Unknown"
}

scan_device_profile() {
  local ip="$1"
  local vendor="$2"
  local output ports services os_name device_type

  output="$(sudo nmap -Pn -O -sV --version-light -p 22,80,443,445,554,515,631,9100,3306,5432,5000,5001,8443 "$ip" 2>/dev/null || true)"

  ports="$(echo "$output" | awk '/^[0-9]+\/tcp[[:space:]]+open/ {split($1,a,"/"); printf "%s%s", (count++ ? "," : ""), a[1]} END {print ""}')"
  services="$(echo "$output" | awk '/^[0-9]+\/tcp[[:space:]]+open/ {printf "%s%s", (count++ ? "," : ""), $3} END {print ""}')"
  os_name="$(echo "$output" | awk -F': ' '/^Running: / {print $2; exit} /^OS details: / {print $2; exit}')"

  device_type="$(classify_device_type "$vendor" "$ports" "$services" "$os_name")"

  printf "%s|%s|%s|%s|%s|%s\n" "$ip" "$vendor" "$ports" "$services" "$os_name" "$device_type"
}

build_device_profiles() {
  local discovery_file="$1"
  local output_file="$2"
  local hosts_tmp ip vendor

  hosts_tmp="$(mktemp /tmp/lss-hosts.XXXXXX)"
  extract_discovered_hosts "$discovery_file" > "$hosts_tmp"
  : > "$output_file"

  while IFS='|' read -r ip vendor; do
    [[ -z "$ip" ]] && continue
    scan_device_profile "$ip" "$vendor" >> "$output_file"
  done < "$hosts_tmp"
  rm -f "$hosts_tmp"
}

print_classification_table() {
  local profile_file="$1"

  echo "## IP Address        Vendor                 Device Type" | tee -a "$LOGFILE"
  awk -F'|' '{ printf "%-17s %-22s %s\n", $1, $2, $6 }' "$profile_file" | tee -a "$LOGFILE"
}

run_dhcp_discover_scan() {
  local tmp_scan raw_discovery total_offers first_offer_ip

  init_scan_export_data "DHCP_SCAN"

  log_echo ""
  log_echo "========================================"
  log_echo "Rogue DHCP Detection"
  log_echo "========================================"

  echo "---" | tee -a "$LOGFILE"
  print_info "## Running scan..." | tee -a "$LOGFILE"
  print_info "Running DHCP detection..." | tee -a "$LOGFILE"

  tmp_scan="$(mktemp)"

  sudo nmap --script broadcast-dhcp-discover -e "$IF" 2>/dev/null > "$tmp_scan" || true

  raw_discovery="$(awk '/DHCPOFFER/ { if (match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) print substr($0, RSTART, RLENGTH) "|67" }' "$tmp_scan" | sort -u)"
  total_offers="$(printf '%s\n' "$raw_discovery" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  first_offer_ip="$(printf '%s\n' "$raw_discovery" | awk -F'|' 'NF >= 2 { print $1; exit }')"

  SCAN_SUMMARY_COUNT="${total_offers:-0}"
  SCAN_RAW_DISCOVERY="$raw_discovery"

  if [[ -n "$first_offer_ip" ]]; then
    SCAN_VERIFICATION="IP: ${first_offer_ip}
Port: 67
Service: DHCP Server
Status: Offer detected

Offers observed: ${total_offers:-0}"
  else
    SCAN_VERIFICATION="None"
  fi

  rm -f "$tmp_scan"

  echo "---" | tee -a "$LOGFILE"
  print_info "## Scan complete" | tee -a "$LOGFILE"
}
dhcp_server_count() {
  local output
  output="$(sudo nmap --script broadcast-dhcp-discover -e "$IF" 2>/dev/null || true)"
  echo "$output" | grep -c "Server Identifier" || true
}
interface_info() {
  local ip_addr subnet dns
  init_scan_export_data "INTERFACE_INFO" "Interface entries"

  CURRENT_GATEWAY="$(get_gateway)"
  ip_addr="$(ip -4 addr show "$IF" | grep -oP '(?<=inet\s)\d+(.\d+){3}' | head -n1 || echo "N/A")"
  subnet="$(ip -4 addr show "$IF" | awk '/inet / {print $2; exit}' || echo "N/A")"
  dns="$(grep nameserver /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)"
  SCAN_SUMMARY_COUNT="1"
  SCAN_RAW_DISCOVERY="$IF|$ip_addr|$subnet|${CURRENT_GATEWAY:-N/A}"
  SCAN_VERIFICATION="Interface: $IF
IP: $ip_addr
Subnet: $subnet
Gateway: ${CURRENT_GATEWAY:-N/A}
DNS: ${dns:-N/A}
DHCP: N/A"

  {
    echo
    echo "Interface: $IF"
    echo "IP: $(ip -4 addr show "$IF" | grep -oP '(?<=inet\s)\d+(.\d+){3}' | head -n1 || echo "N/A")"
    echo "Subnet: $(ip -4 addr show "$IF" | awk '/inet / {print $2; exit}' || echo "N/A")"
    echo "Gateway: ${CURRENT_GATEWAY:-N/A}"
    echo "DNS: $(grep nameserver /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)"
    echo "DHCP: N/A"
    echo
  } | tee -a "$LOGFILE"
}

gateway_scan() {
  local gw output formatted unique_formatted discovery_count scan_output_file
  init_scan_export_data "GATEWAY_SCAN"
  gw="$(get_gateway)"

  scan_output_file="$(mktemp)"

  sudo nmap -Pn -T4 --open "$gw" > "$scan_output_file" 2>/dev/null

  output="$(cat "$scan_output_file")"
  rm -f "$scan_output_file"

  formatted="$(echo "$output" | awk '
    /^[0-9]+\/(tcp|udp)[[:space:]]+open[[:space:]]+/ {
      split($1, port_proto, "/")
      service=toupper($3)
      printf "%-8s %s\n", port_proto[1] "/" port_proto[2], service
    }
  ')"

  unique_formatted="$(printf "%s\n" "$formatted" | sed '/^[[:space:]]*$/d' | sort -u)"
  if [[ -n "$unique_formatted" ]]; then
    discovery_count="$(printf "%s\n" "$unique_formatted" | wc -l | tr -d ' ')"
  else
    discovery_count=0
  fi

  SCAN_SUMMARY_COUNT="$discovery_count"
  SCAN_RAW_DISCOVERY="$(echo "$output" | awk '
    /^Nmap scan report for / { ip=$NF; gsub(/[()]/, "", ip); next }
    /^[0-9]+\/(tcp|udp)[[:space:]]+open[[:space:]]+/ { split($1,p,"/"); print ip "|" p[1] }
  ' | sort -u)"
  if [[ -n "$SCAN_RAW_DISCOVERY" ]]; then
    SCAN_VERIFICATION=""
    while IFS='|' read -r ip port; do
      [[ -z "$ip" || -z "$port" ]] && continue
      case "$port" in
        22) service_name="SSH" ;;
        53) service_name="DOMAIN" ;;
        80) service_name="HTTP" ;;
        443) service_name="HTTPS" ;;
        *) service_name="OPEN_PORT" ;;
      esac
      SCAN_VERIFICATION+="IP: $ip\nPort: $port\nService: $service_name\n\n"
    done <<< "$SCAN_RAW_DISCOVERY"
    SCAN_VERIFICATION="$(printf "%b" "$SCAN_VERIFICATION")"
  else
    SCAN_VERIFICATION="None"
  fi
}

rogue_dhcp() {
  run_dhcp_discover_scan
  print_alert "Review DHCP offers above. Unexpected DHCP responders should be treated as rogue."
}

find_web_interfaces() {
  local net tmp live_hosts tmp_discovery current_ip line port url status found raw_discovery unique_raw_discovery discovery_count
  net="$(get_network)"
  tmp="$(mktemp)"
  live_hosts="$(mktemp)"
  raw_discovery="$(mktemp)"
  local verification_output
  found=0
  init_scan_export_data "WEB_INTERFACES"

  log_echo ""
  log_echo "Scanning network for web management interfaces..."
  log_echo "This may take a moment."
  log_echo ""

  log_echo ""
  log_echo "Discovering active hosts..."
  log_echo ""

  tmp_discovery="$(mktemp)"

  nmap -sn "$net" > "$tmp_discovery"

  grep "Nmap scan report for" "$tmp_discovery" | awk '{print $NF}' > "$live_hosts"

  rm -f "$tmp_discovery"

  log_echo ""
  log_echo "## Web Management Interfaces"
  log_echo ""

  if [ ! -s "$live_hosts" ]; then
    SCAN_SUMMARY_COUNT="0"
    SCAN_RAW_DISCOVERY="None"
    SCAN_VERIFICATION="No active hosts discovered."
    rm -f "$live_hosts" "$tmp" "$raw_discovery"
    return
  fi

  verification_output=""

  nmap -p 80,443,8080,8443 --open -iL "$live_hosts" > "$tmp" 2>/dev/null || true

  current_ip=""
  while read -r line; do
    if echo "$line" | grep -q "Nmap scan report for"; then
      current_ip="$(echo "$line" | awk '{print $NF}' | tr -d '()')"
      log_echo "Checking $current_ip..."
    fi

    if echo "$line" | grep -q "open"; then
      port="$(echo "$line" | awk '{print $1}' | cut -d/ -f1)"

      case "$port" in
        80) url="http://$current_ip" ;;
        443) url="https://$current_ip" ;;
        8080) url="http://$current_ip:8080" ;;
        8443) url="https://$current_ip:8443" ;;
        *) continue ;;
      esac

      printf "%s|%s\n" "$current_ip" "$port" >> "$raw_discovery"
      log_echo "Testing $url"

      if curl -k --connect-timeout 2 -s -I "$url" >/dev/null; then
        status="OK"
      else
        status="URL not reachable"
      fi

      verification_output+="IP: $current_ip\nPort: $port\nURL: $url\nStatus: $status\n\n"

      found=1
    fi
  done < "$tmp"

  unique_raw_discovery="$(sort -u "$raw_discovery" 2>/dev/null || true)"
  if [[ -n "$unique_raw_discovery" ]]; then
    discovery_count="$(printf "%s\n" "$unique_raw_discovery" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  else
    discovery_count=0
  fi

  SCAN_SUMMARY_COUNT="$discovery_count"
  SCAN_RAW_DISCOVERY="$unique_raw_discovery"
  if [[ "$found" -eq 0 ]]; then
    SCAN_VERIFICATION="No web management interfaces found."
  else
    SCAN_VERIFICATION="$(printf "%b" "$verification_output")"
  fi

  rm -f "$live_hosts" "$tmp" "$raw_discovery"
}

speed_test() {
  local speed_output ping download upload
  init_scan_export_data "SPEED_TEST"
  speed_output="$(speedtest-cli 2>/dev/null || true)"
  ping="$(echo "$speed_output" | awk -F': ' '/Ping:/ {print $2; exit}')"
  download="$(echo "$speed_output" | awk -F': ' '/Download:/ {print $2; exit}')"
  upload="$(echo "$speed_output" | awk -F': ' '/Upload:/ {print $2; exit}')"

  SCAN_SUMMARY_COUNT="3"
  SCAN_RAW_DISCOVERY="PING|${ping:-N/A}
DOWNLOAD|${download:-N/A}
UPLOAD|${upload:-N/A}"
  SCAN_VERIFICATION="Ping: ${ping:-N/A}
Download: ${download:-N/A}
Upload: ${upload:-N/A}"
}

scan_dns_servers() {
  local net gw scan_output discovered_services unique_discovered_services discovery_count ip port service_name dns_short dns_stats latency recursion rogue status scan_output_file
  net="$(get_network)"
  gw="$(get_gateway)"
  init_scan_export_data "DNS_SERVERS"

  if ! command -v dig >/dev/null 2>&1; then
    print_alert "dig command is required for DNS verification but was not found."
    SCAN_SUMMARY_COUNT="0"
    SCAN_RAW_DISCOVERY="None"
    SCAN_VERIFICATION="dig command not found."
    return
  fi

  log_echo ""
  log_echo "Scanning network for DNS servers..."

  scan_output_file="$(mktemp)"

  nmap -sU -sT -p53,853,443 --open --max-retries 1 "$net" > "$scan_output_file" 2>/dev/null || true

  scan_output="$(cat "$scan_output_file")"
  rm -f "$scan_output_file"

  discovered_services="$(echo "$scan_output" | awk '
    /^Nmap scan report for / { ip=$NF; gsub(/[()]/, "", ip); next }
    /^[0-9]+\/(tcp|udp)[[:space:]]+open/ {
      split($1, p, "/")
      key=ip"|"p[1]
      if (!seen[key]++) {
        print key
      }
    }
  ')"

  unique_discovered_services="$(printf "%s\n" "$discovered_services" | sed '/^[[:space:]]*$/d' | sort -u)"
  if [[ -n "$unique_discovered_services" ]]; then
    discovery_count="$(printf "%s\n" "$unique_discovered_services" | wc -l | tr -d ' ')"
  else
    discovery_count=0
  fi

  SCAN_SUMMARY_COUNT="$discovery_count"
  SCAN_RAW_DISCOVERY="$unique_discovered_services"
  SCAN_VERIFICATION=""

  [[ -z "$unique_discovered_services" ]] && {
    SCAN_VERIFICATION="None"
    return
  }

  while IFS='|' read -r ip port; do
    [[ -z "$ip" || -z "$port" ]] && continue

    case "$port" in
      53) service_name="DNS Server" ;;
      853) service_name="DNS over TLS (DoT)" ;;
      443) service_name="Possible DNS over HTTPS (DoH)" ;;
      *) service_name="Unknown DNS Service" ;;
    esac

    SCAN_VERIFICATION+="IP: $ip\nPort: $port\nService: $service_name\n"

    case "$port" in
      53)
        dns_short="$(dig @"$ip" google.com +short +time=2 +tries=1 2>/dev/null || true)"
        dns_stats="$(dig @"$ip" google.com +stats +time=2 +tries=1 2>/dev/null || true)"
        latency="$(echo "$dns_stats" | awk -F': ' '/^;; Query time:/ {print $2}' | awk '{print $1; exit}')"

        if [[ -n "$dns_short" ]]; then
          status="Responding"
          recursion="Enabled"
        else
          status="No DNS response"
          recursion="Disabled"
        fi

        if [[ "$ip" != "$gw" ]]; then
          rogue="Yes"
        else
          rogue="No"
        fi

        SCAN_VERIFICATION+="Status: $status\n"
        if [[ -n "$latency" ]]; then
          SCAN_VERIFICATION+="Latency: $latency ms\n"
        else
          SCAN_VERIFICATION+="Latency: N/A\n"
        fi
        SCAN_VERIFICATION+="Recursion: $recursion\nPotential Rogue DNS: $rogue\n"
        ;;
      853)
        if command -v timeout >/dev/null 2>&1 && timeout 2 bash -c "echo | openssl s_client -connect $ip:853" >/dev/null 2>&1; then
          SCAN_VERIFICATION+="Status: DNS over TLS detected\n"
        elif command -v perl >/dev/null 2>&1 && perl -e 'alarm shift; exec @ARGV' 2 bash -c "echo | openssl s_client -connect $ip:853" >/dev/null 2>&1; then
          SCAN_VERIFICATION+="Status: DNS over TLS detected\n"
        else
          SCAN_VERIFICATION+="Status: TLS check failed\n"
        fi
        ;;
      443)
        if curl -s --connect-timeout 2 "https://$ip/dns-query" >/dev/null 2>&1; then
          SCAN_VERIFICATION+="Status: DNS over HTTPS detected\n"
        else
          SCAN_VERIFICATION+="Status: HTTPS DNS endpoint not confirmed\n"
        fi
        ;;
    esac
    SCAN_VERIFICATION+="\n"
  done <<< "$unique_discovered_services"
  SCAN_VERIFICATION="$(printf "%b" "$SCAN_VERIFICATION")"
}

scan_file_servers() {
  local net scan_output parsed_results unique_parsed_results discovery_count scan_output_file
  net="$(get_network)"
  init_scan_export_data "FILE_SERVERS"

  log_echo ""
  log_echo "Scanning network for file servers..."

  scan_output_file="$(mktemp)"

  nmap -p 21,22,139,445,2049,548 --open "$net" > "$scan_output_file" 2>/dev/null

  scan_output="$(cat "$scan_output_file")"
  rm -f "$scan_output_file"

  parsed_results="$(echo "$scan_output" | awk '
    /^Nmap scan report for / { ip=$NF; gsub(/[()]/, "", ip); next }
    /^[0-9]+\/tcp[[:space:]]+open/ {
      split($1, p, "/")
      print ip "|" p[1]
    }
  ')"

  unique_parsed_results="$(printf "%s\n" "$parsed_results" | sed '/^[[:space:]]*$/d' | sort -u)"
  if [[ -n "$unique_parsed_results" ]]; then
    discovery_count="$(printf "%s\n" "$unique_parsed_results" | wc -l | tr -d ' ')"
  else
    discovery_count=0
  fi

  SCAN_SUMMARY_COUNT="$discovery_count"
  SCAN_RAW_DISCOVERY="$unique_parsed_results"
  SCAN_VERIFICATION=""

  [[ -z "$unique_parsed_results" ]] && {
    SCAN_VERIFICATION="None"
    return
  }

  while IFS='|' read -r ip port; do
    local service_name
    [[ -z "$ip" || -z "$port" ]] && continue

    case "$port" in
      21) service_name="FTP Server" ;;
      22) service_name="SSH / SFTP File Access" ;;
      139) service_name="SMB (NetBIOS)" ;;
      445) service_name="SMB File Share" ;;
      2049) service_name="NFS Server" ;;
      548) service_name="AFP (Apple File Server)" ;;
      *) service_name="Unknown File Service" ;;
    esac

    SCAN_VERIFICATION+="IP: $ip\nPort: $port\nService: $service_name\n\n"
  done <<< "$unique_parsed_results"
  SCAN_VERIFICATION="$(printf "%b" "$SCAN_VERIFICATION")"
}

scan_printers() {
  local net scan_output parsed_results unique_parsed_results discovery_count scan_output_file printed_ips has_631_ips
  net="$(get_network)"
  init_scan_export_data "PRINTERS"
  printed_ips=""
  has_631_ips=""

  log_echo ""
  log_echo "Scanning network for printers..."

  scan_output_file="$(mktemp)"

  nmap -p 515,631,9100 --open --max-retries 1 "$net" > "$scan_output_file" 2>/dev/null

  scan_output="$(cat "$scan_output_file")"
  rm -f "$scan_output_file"

  parsed_results="$(echo "$scan_output" | awk '
    /^Nmap scan report for / { ip=$NF; gsub(/[()]/, "", ip); next }
    /^[0-9]+\/tcp[[:space:]]+open/ {
      split($1, p, "/")
      print ip "|" p[1]
    }
  ')"

  unique_parsed_results="$(printf "%s\n" "$parsed_results" | sed '/^[[:space:]]*$/d' | sort -u)"
  if [[ -n "$unique_parsed_results" ]]; then
    discovery_count="$(printf "%s\n" "$unique_parsed_results" | wc -l | tr -d ' ')"
  else
    discovery_count=0
  fi

  SCAN_SUMMARY_COUNT="$discovery_count"
  SCAN_RAW_DISCOVERY="$unique_parsed_results"
  SCAN_VERIFICATION=""

  if [[ -z "$unique_parsed_results" ]]; then
    SCAN_VERIFICATION="None"
    return
  fi

  while IFS='|' read -r ip port; do
    [[ -z "$ip" || -z "$port" ]] && continue
    if [[ "$port" == "631" ]]; then
      if [[ " $has_631_ips " != *" $ip "* ]]; then
        has_631_ips="$has_631_ips $ip"
      fi
    fi
  done <<< "$unique_parsed_results"

  while IFS='|' read -r ip port; do
    local service_name model page
    [[ -z "$ip" || -z "$port" ]] && continue
    if [[ " $printed_ips " == *" $ip "* ]]; then
      continue
    fi

    case "$port" in
      515) service_name="LPD Printer Service" ;;
      631) service_name="IPP Printer Service" ;;
      9100) service_name="JetDirect Printer Port" ;;
      *) service_name="Unknown Printer Service" ;;
    esac

    model="Unknown"

    if command -v snmpwalk >/dev/null 2>&1; then
      model="$(snmpwalk -v1 -c public -Oqv "$ip" 1.3.6.1.2.1.25.3.2.1.3 2>/dev/null | head -n1 || true)"
      [[ -z "$model" ]] && model="Unknown"
    fi

    if [[ "$model" == "Unknown" && " $has_631_ips " == *" $ip "* ]]; then
      page="$(curl -s --connect-timeout 2 "http://$ip" || true)"
      model="$(echo "$page" | grep -i -E 'hp|brother|canon|epson|xerox|printer' | head -n1 | sed 's/<[^>]*>//g')"
      [[ -z "$model" ]] && model="Unknown"
    fi

    SCAN_VERIFICATION+="IP: $ip\nPort: $port\nService: $service_name\nModel: $model\nStatus: Detected\n\n"

    printed_ips="$printed_ips $ip"
  done <<< "$unique_parsed_results"

  SCAN_VERIFICATION="$(printf "%b" "$SCAN_VERIFICATION")"
}

exit_script() {
  exit 0
}

export_report() {
  local date_stamp generated gateway ip_addr dest clean_log export_dir
  date_stamp="$(date '+%Y-%m-%d_%H-%M-%S')"
  generated="$(date '+%Y-%m-%d %H:%M:%S')"
  gateway="$(get_gateway)"
  ip_addr="$(ip -4 addr show "$IF" | grep -oP '(?<=inet\s)\d+(.\d+){3}' | head -n1 || echo "N/A")"
  read -rp "Enter directory to save report [~/lss-reports]: " export_dir
  export_dir=${export_dir:-~/lss-reports}

  export_dir=$(eval echo "$export_dir")
  mkdir -p "$export_dir"

  dest="$export_dir/LSS-NetInfo-Export-$date_stamp.txt"
  clean_log="$(mktemp)"

  strip_colors < "$LOGFILE" | sed -E '/^## Running scan\.\.\.$/d; /^## Scan complete$/d; /^Running .*\.\.\.$/d; /^Running Internet speed test$/d; /^Running Internet speed test complete$/d; /^Starting Nmap/d; /^Nmap done:/d; /^Pre-scan script results:/d; /^Scanning network/d; /^Discovering active hosts\.\.\.$/d; /^Checking [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.\.\.$/d; /^Testing https?:\/\//d; /^---$/d; /^-+$/d' > "$clean_log"

  {
    echo "========================================"
    echo "LSS Network Diagnostic Report"
    echo "========================================"
    echo "Generated: $generated"
    echo "Interface: $IF"
    echo "IP address: $ip_addr"
    echo "Gateway: ${gateway:-N/A}"
    echo ""

    awk '
      function print_section(title) {
        if (current_section != title) {
          if (printed_any) print ""
          print "========================================"
          print title
          print "========================================"
          current_section = title
          printed_any = 1
          seen_device = 0
        }
      }

      function emit(line) {
        if (line == "" || line == prev_line) return
        print line
        prev_line = line
      }

      {
        gsub(/\r/, "", $0)
        if ($0 ~ /^[[:space:]]*$/) next

        if ($0 ~ /^## Gateway Scan Results/) { print_section("Gateway"); next }
        if ($0 ~ /^## Web Management Interfaces/) { print_section("Web Management Interfaces"); next }
        if ($0 ~ /^## DNS Servers Discovered/) { print_section("DNS Servers"); next }
        if ($0 ~ /^## File Servers Discovered/) { print_section("File Servers"); next }
        if ($0 ~ /^## Printers Discovered/) { print_section("Printers"); next }

        if (($0 ~ /Speedtest by Ookla/ || $0 ~ /^Server:/ || $0 ~ /^ISP:/ || $0 ~ /^Download:/ || $0 ~ /^Upload:/) && current_section != "DNS Servers") {
          print_section("Speed Test")
        }

        if (current_section == "") next

        if ($0 ~ /^Open Services:$/ || $0 ~ /^No open services found\.$/ || $0 ~ /^[A-Za-z ].* discovery entries: / || $0 ~ /^--- RAW DISCOVERY ---$/ || $0 ~ /^--- VERIFICATION ---$/ || $0 ~ /^--- END .* SECTION ---$/ || $0 ~ /^None discovered on the network\.$/) { emit($0); next }
        if ($0 ~ /^Gateway: /) { emit($0); next }

        if ($0 ~ /^IP: /) {
          ip = $0
          sub(/^IP:[[:space:]]*/, "", ip)
          if (seen_device) emit("----------------------------------------")
          emit(ip)
          seen_device = 1
          next
        }

        if ($0 ~ /^https?:\/\//) { emit("  URL: " $0); next }

        if ($0 ~ /^(Port|Status|Service|Model|Latency|Recursion|Potential Rogue DNS): /) {
          emit("  " $0)
          next
        }

        emit($0)
      }
    ' "$clean_log"
  } > "$dest"

  rm -f "$clean_log"

  print_ok "Export saved to: $dest"
}

show_menu() {

echo
echo "================================="
echo "    LSS Network Tools (Linux)"
echo "================================="

echo "1) Interface Network Info"
echo "2) Gateway Scan"
echo "3) Rogue DHCP Detection"
echo "4) Find Web Admin Interfaces"
echo "5) Internet Speed Test"
echo "6) Scan for DNS servers"
echo "7) Scan for File Servers"
echo "8) Scan for Printers"
echo "9) Run Complete Network Audit"

echo
echo "0) Exit"
echo

}

run_complete_audit() {
  start_new_audit_session

  run_scan_and_export interface_info "interface-info.txt"
  run_scan_and_export gateway_scan "gateway-scan.txt"
  run_scan_and_export rogue_dhcp "dhcp-scan.txt"
  run_scan_and_export scan_dns_servers "dns-servers.txt"
  run_scan_and_export scan_file_servers "file-servers.txt"
  run_scan_and_export scan_printers "printers.txt"
  run_scan_and_export find_web_interfaces "web-interfaces.txt"
  run_scan_and_export speed_test "speed-test.txt"
}

main() {
  run_dependency_check
  check_for_updates
  sudo -v
  select_interface

  while true; do
    local opt
    show_menu
    read -r -p "Select option: " opt

    case "$opt" in
      1) run_scan_and_export interface_info "interface-info.txt" ;;
      2) run_scan_and_export gateway_scan "gateway-scan.txt" ;;
      3) run_scan_and_export rogue_dhcp "dhcp-scan.txt" ;;
      4) run_scan_and_export find_web_interfaces "web-interfaces.txt" ;;
      5) run_scan_and_export speed_test "speed-test.txt" ;;
      6) run_scan_and_export scan_dns_servers "dns-servers.txt" ;;
      7) run_scan_and_export scan_file_servers "file-servers.txt" ;;
      8) run_scan_and_export scan_printers "printers.txt" ;;
      9) run_complete_audit ;;
      0) exit_script ;;
      *) print_warn "Invalid option." ;;
    esac
  done
}

main "$@"
