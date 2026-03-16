#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
RUN_OUTPUT_DIR=""
RUN_DATE_STAMP=""
RUN_REPORT_TIME_STAMP=""
RUN_CLIENT_NAME=""
RUN_LOCATION=""
RUN_CLIENT_SLUG=""
RUN_LOCATION_SLUG=""
RUN_REPORT_FILE=""
HIGH_IMPACT_STRESS_CONFIRMED=0
SESSION_DEBUG_LOG=""
RUN_DEBUG_LOG=""
OUTPUT_IS_TTY=0
DEBUG_MODE=0

mkdir -p "$OUTPUT_DIR"

OS=""
SHOW_FUNCTION_HEADER=1
SPINNER_PID=""
TASKS_DATA=$(cat <<'TASKS'
1|Interface Network Info|interface-network-info.json
2|Internet Speed Test|internet-speed-test.json
3|Gateway Details|gateway-scan.json
4|DHCP Network Scan|dhcp-scan.json
5|DNS Network Scan|dns-scan.json
6|LDAP/AD Network Scan|ldap-ad-scan.json
7|SMB/NFS Network Scan|smb-nfs-scan.json
8|Printer/Print Server Network Scan|print-server-scan.json
9|Gateway Stress Test|gateway-stress-test.json
TASKS
)

print_alert() {
  echo "ALERT: $1"
}

validate_json_file() {
  local file="$1"
  if ! jq . "$file" >/dev/null 2>&1; then
    print_alert "JSON validation failed for $file"
    return 1
  fi
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
  local confirmation=""

  if [[ "$HIGH_IMPACT_STRESS_CONFIRMED" -eq 1 ]]; then
    return 0
  fi

  echo
  echo "WARNING: $context_label includes Gateway Stress Test."
  echo "This test only targets the detected local gateway/firewall with ICMP."
  echo "It does not target remote internet hosts, but it can disrupt local routing, VPNs, WAN access, or unstable firewalls."
  echo "Run this only when you accept possible service impact."
  echo "Consider disconnecting the local gateway from internet or performing this after-hours if disruption would be unacceptable."
  read -r -p "Type PROCEED to continue: " confirmation

  if [[ "$confirmation" != "PROCEED" ]]; then
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

initialize_debug_logging() {
  if [[ -n "$SESSION_DEBUG_LOG" ]]; then
    return
  fi

  if [[ -t 1 ]]; then
    OUTPUT_IS_TTY=1
  fi

  SESSION_DEBUG_LOG="$OUTPUT_DIR/.debug-session-$$.txt"
  : > "$SESSION_DEBUG_LOG"
  exec > >(tee -a "$SESSION_DEBUG_LOG") 2>&1
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --debug)
        DEBUG_MODE=1
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ./lss-network-tools.sh [--debug]"
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

initialize_run_context() {
  read -r -p "Location: " RUN_LOCATION
  read -r -p "Client Name: " RUN_CLIENT_NAME

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
  RUN_OUTPUT_DIR="$OUTPUT_DIR/${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}"
  RUN_REPORT_FILE="$RUN_OUTPUT_DIR/lss-network-tools-report-${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}-${RUN_REPORT_TIME_STAMP}.txt"
  RUN_DEBUG_LOG="$RUN_OUTPUT_DIR/debug.txt"

  mkdir -p "$RUN_OUTPUT_DIR"

  echo
  echo "Run output directory: $RUN_OUTPUT_DIR"
}

build_report_for_current_run() {
  local json_count
  local report_file
  local timestamp
  local ran_summary=""
  local missing_summary=""
  local func_id title file_name file_path
  local report_interface
  local interface_info_file
  local detected_iface

  if [[ -z "$RUN_OUTPUT_DIR" ]]; then
    echo "Run output directory is not initialized."
    return 1
  fi

  json_count="$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | awk '{print $1}')"
  if [[ "$json_count" -eq 0 ]]; then
    echo "No JSON scan files found in $RUN_OUTPUT_DIR"
    return 1
  fi

  RUN_REPORT_TIME_STAMP="$(date '+%H-%M')"
  RUN_REPORT_FILE="$RUN_OUTPUT_DIR/lss-network-tools-report-${RUN_CLIENT_SLUG}-${RUN_LOCATION_SLUG}-${RUN_DATE_STAMP}-${RUN_REPORT_TIME_STAMP}.txt"
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
    echo "Generated: $timestamp"
    echo "Selected Interface: $report_interface"
    echo
  } > "$report_file"

  for func_id in $(get_task_ids); do
    title="$(task_title "$func_id")"
    file_name="$(task_output_file "$func_id")"
    [[ -z "$file_name" ]] && continue
    file_path="$RUN_OUTPUT_DIR/$file_name"

    if [[ -f "$file_path" ]]; then
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
    file_name="$(task_output_file "$func_id")"
    [[ -z "$file_name" ]] && continue
    file_path="$RUN_OUTPUT_DIR/$file_name"

    [[ ! -f "$file_path" ]] && continue

    {
      echo "================================================"
      echo "Function $func_id) $title"
      echo "================================================"
    } >> "$report_file"

    case "$func_id" in
      1) render_interface_info_report "$file_path" "$report_file" ;;
      2) render_speed_test_report "$file_path" "$report_file" ;;
      3) render_gateway_report "$file_path" "$report_file" ;;
      4) render_dhcp_report "$file_path" "$report_file" ;;
      5) render_generic_network_scan_report "$file_path" "$report_file" "DNS" ;;
      6) render_generic_network_scan_report "$file_path" "$report_file" "LDAP/AD" ;;
      7) render_generic_network_scan_report "$file_path" "$report_file" "SMB/NFS" ;;
      8) render_generic_network_scan_report "$file_path" "$report_file" "Printer" ;;
      9) render_gateway_stress_report "$file_path" "$report_file" ;;
    esac

    echo >> "$report_file"
  done

  echo "Report built successfully: $report_file"
}

finalize_run() {
  if [[ -n "$RUN_OUTPUT_DIR" ]] && [[ -n "$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]]; then
    build_report_for_current_run || true
  fi

  if [[ -n "$RUN_OUTPUT_DIR" && -n "$SESSION_DEBUG_LOG" && -f "$SESSION_DEBUG_LOG" ]]; then
    cp "$SESSION_DEBUG_LOG" "$RUN_DEBUG_LOG" 2>/dev/null || true
  fi
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
    echo "Missing required tool: $tool"
    echo "Install with: brew install $tool"
  else
    echo "Missing required tool: $tool"
    case "$tool" in
      iproute2|iputils-ping|tcpdump)
        echo "Install with: apt-get install $tool"
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
  local reset='[0m'
  local base_tools=(nmap awk sed grep find mktemp jq speedtest-cli)
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
  echo "Dependency checklist"

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

  if [[ "$OS" == "linux" ]] && ! command -v ifconfig >/dev/null 2>&1; then
    echo "Optional fallback missing: ifconfig"
    echo "Install with: apt install net-tools"
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
      case "${choice,,}" in
        y|yes)
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
        n|no)
          echo "Everything is required to run this program correctly. Exiting."
          exit 1
          ;;
        *)
          echo "Invalid selection. Enter y or n."
          ;;
      esac
    done
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
  local idx=1
  local choice
  local display_label
  local status_suffix
  local green='\033[0;32m'
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
    echo
    echo "Select Network Interface"
    for iface in "${interfaces[@]}"; do
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
        has_ipv4=true
      else
        status_suffix=" (no IPv4 address detected)"
      fi

      if [[ "$iface" == "lo0" ]]; then
        status_suffix=" (loopback)"
      fi

      if [[ "$has_ipv4" == "true" && "$OUTPUT_IS_TTY" -eq 1 ]]; then
        printf "%s) ${green}%s%s${reset}\n" "$idx" "$display_label" "$status_suffix"
      else
        echo "$idx) $display_label$status_suffix"
      fi
      idx=$((idx + 1))
    done
    echo "0) Exit"

    read -r -p "Enter selection: " choice

    if [[ "$choice" == "0" ]]; then
      exit 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
      SELECTED_INTERFACE="${interfaces[$((choice - 1))]}"
      clear_screen_if_supported
      if ! interface_has_ipv4 "$SELECTED_INTERFACE"; then
        echo "Warning: $SELECTED_INTERFACE does not currently have an IPv4 address."
        echo "Interface info and network-range scans may fail on bridge/physical-only interfaces."
        echo "On Proxmox or Debian bridge hosts, you may want a bridge interface such as vmbr0 instead."
        echo
      fi
      return
    fi

    echo "Invalid selection. Try again."
    idx=1
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
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    mask="$(ipconfig getoption "$iface" subnet_mask 2>/dev/null || true)"
    if [[ -z "$mask" ]]; then
      local hexmask
      hexmask="$(ifconfig "$iface" | awk '/inet /{for(i=1;i<=NF;i++) if($i=="netmask") {print $(i+1); exit}}')"
      if [[ "$hexmask" =~ ^0x ]]; then
        mask="$(printf "%d.%d.%d.%d" "$((16#${hexmask:2:2}))" "$((16#${hexmask:4:2}))" "$((16#${hexmask:6:2}))" "$((16#${hexmask:8:2}))")"
      fi
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

  details="$(get_interface_details "$iface")"
  IFS='|' read -r ip mask prefix mac gateway <<< "$details"

  if [[ -z "$ip" || -z "$mask" ]]; then
    if [[ "$silent_mode" != "silent" ]]; then
      echo "Unable to determine IP or subnet for interface $iface"
    fi
    return 1
  fi

  if [[ -z "$prefix" ]]; then
    prefix="$(mask_to_prefix "$mask")"
  fi
  network="$(calculate_network "$ip" "$prefix")"

  if [[ -z "$gateway" ]]; then
    gateway=""
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
    echo "Gateway: $gateway"
    echo "MAC Address: $mac"
  fi

  mkdir -p "$(current_output_dir)"

  jq -n \
    --arg interface "$iface" \
    --arg ip_address "$ip" \
    --arg subnet "$mask" \
    --arg network "$network" \
    --arg gateway "$gateway" \
    --arg mac_address "$mac" \
    '{
      interface: $interface,
      ip_address: $ip_address,
      subnet: $subnet,
      network: $network,
      gateway: $gateway,
      mac_address: $mac_address
    }' > "$(task_output_path 1)"

  validate_json_file "$(task_output_path 1)"

  if [[ "$silent_mode" != "silent" ]]; then
    echo "Saved JSON: $(task_output_path 1)"
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
  local result_count=0

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "$title"
  fi
  echo "Stage 1: Getting network range for interface $SELECTED_INTERFACE..."

  network="$(get_interface_network_cidr "$SELECTED_INTERFACE")"
  if [[ -z "$network" ]]; then
    echo "Unable to determine network range for $SELECTED_INTERFACE"
    return 1
  fi

  echo "Done."
  echo "Network Range: $network"
  echo
  echo "Stage 2: Scanning $description ports ($port_list)..."

  scan_file="$(mktemp)"
  nmap -n -p "$port_list" --open "$network" -oG - > "$scan_file" 2>/dev/null &
  local scan_pid=$!
  spinner
  wait_for_pid "$scan_pid" "Port scan failed for network $network." || {
    rm -f "$scan_file"
    return 1
  }

  json_file="$(current_output_dir)/$output_file"
  jq -n \
    --arg network "$network" \
    --arg scan_ports "$port_list" \
    '{network: $network, scan_ports: $scan_ports, servers: []}' > "$json_file"

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

  echo "$title results found: $result_count"
  echo "Saved JSON: $json_file"
  validate_json_file "$json_file"
  return 0
}


detect_dns_servers() {
  scan_servers_by_ports \
    "DNS Network Scan" \
    "DNS" \
    "53" \
    "dns-scan.json"
}

detect_ldap_servers() {
  scan_servers_by_ports \
    "LDAP/AD Network Scan" \
    "LDAP/AD" \
    "88,389,636,3268,3269" \
    "ldap-ad-scan.json"
}

detect_smb_nfs_servers() {
  scan_servers_by_ports \
    "SMB/NFS Network Scan" \
    "SMB/NFS" \
    "111,139,445,2049" \
    "smb-nfs-scan.json"
}

detect_print_servers() {
  scan_servers_by_ports \
    "Printer/Print Server Network Scan" \
    "Printer/Print Server" \
    "515,631,9100" \
    "print-server-scan.json"
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

spinner() {
  local pid=$!
  local message="${1:-Scanning...}"
  local i=0
  local -a spin_frames

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
    printf "\r[%s] %s" "${spin_frames[$i]}" "$message"
    i=$(( (i + 1) % ${#spin_frames[@]} ))
    sleep 0.2
  done
  printf "\rDone.           \n"
}

start_spinner_line() {
  local label="$1"
  local i=0
  local -a spin_frames

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
      printf "\r%s %s" "$label" "${spin_frames[$i]}"
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

  printf "\r\033[K"
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

render_speed_test_report() {
  local file="$1"
  local report_file="$2"
  local server location download upload public_ip ping

  if jq -e '.servers and (.servers | type == "array") and (.servers | length > 0)' "$file" >/dev/null 2>&1; then
    public_ip="$(jq -r '.servers[0].public_ip // "unknown"' "$file" 2>/dev/null)"
    server="$(jq -r '.servers[0].test_server // "unknown"' "$file" 2>/dev/null)"
    location="$(jq -r '.servers[0].location // empty' "$file" 2>/dev/null)"
    ping="$(jq -r '(.servers[0].ping_ms // "unavailable")' "$file" 2>/dev/null)"
    download="$(jq -r 'if .servers[0].download_mbps then .servers[0].download_mbps else empty end' "$file" 2>/dev/null | awk '{printf "%.2f Mbps", $1}')"
    upload="$(jq -r 'if .servers[0].upload_mbps then .servers[0].upload_mbps else empty end' "$file" 2>/dev/null | awk '{printf "%.2f Mbps", $1}')"
  else
    public_ip="$(jq -r '.client.ip // "unknown"' "$file" 2>/dev/null)"
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
    echo "Public IP: ${public_ip:-unknown}"
    echo "Connected to server: ${server:-unknown}"
    echo "Ping: ${ping:-unavailable} ms"
    echo "Download Speed: ${download:-unavailable}"
    echo "Upload Speed: ${upload:-unavailable}"
  } >> "$report_file"
}

internet_speed_test() {
  local result
  local timeout_seconds=90
  local result_file
  local pid
  local exit_code
  local public_ip server_name server_location ping_latency download_speed upload_speed
  local raw_server_name raw_server_location
  local download_display upload_display

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
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for parsing speedtest JSON output."
    return 1
  fi

  result_file="$(mktemp)"
  speedtest-cli --secure --json > "$result_file" 2>&1 &
  pid=$!
  run_with_stage_spinner "$pid" "$timeout_seconds"
  exit_code=$?
  result="$(cat "$result_file")"
  rm -f "$result_file"

  if [[ "$exit_code" -ne 0 ]]; then
    echo "Speedtest failed. Raw output:"
    echo "$result"
    return 1
  fi

  if ! echo "$result" | jq . >/dev/null 2>&1; then
    echo "Speedtest failed. Raw output:"
    echo "$result"
    return 1
  fi

  public_ip="$(echo "$result" | jq -r '.client.ip // "unknown"')"
  raw_server_name="$(echo "$result" | jq -r '.server.name // "unknown"')"
  raw_server_location="$(echo "$result" | jq -r '.server.location // .server.country // ""')"
  ping_latency="$(echo "$result" | jq -r '.ping // "unavailable"' | awk '{if ($1=="unavailable") print $1; else printf "%.2f", $1}')"
  download_speed="$(echo "$result" | jq -r 'if .download then (.download / 1000000) else empty end' | awk '{printf "%.2f", $1}')"
  upload_speed="$(echo "$result" | jq -r 'if .upload then (.upload / 1000000) else empty end' | awk '{printf "%.2f", $1}')"

  [[ -z "$download_speed" ]] && download_speed="unavailable"
  [[ -z "$upload_speed" ]] && upload_speed="unavailable"

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
  echo "Public IP: $public_ip"
  echo "Connected to server: $server_name"
  echo "Ping: $ping_latency ms"
  echo "Download Speed: $download_display"
  echo "Upload Speed: $upload_display"
  echo

  echo "$result" | jq '{
      speed_tests_found: 1,
      servers: [
        {
          public_ip: (.client.ip // "unknown"),
          test_server: (.server.name // "unknown"),
          location: (.server.location // .server.country // ""),
          ping_ms: (.ping // null),
          download_mbps: (if .download then (.download / 1000000) else null end),
          upload_mbps: (if .upload then (.upload / 1000000) else null end),
          timestamp: (.timestamp // "")
        }
      ]
    }' > "$(task_output_path 2)"
  validate_json_file "$(task_output_path 2)"
  echo "Saved JSON:"
  echo "$(task_output_path 2)"
  echo

  return 0
}

gateway_details() {
  local iface="$1"
  local gateway_ip
  local ports=()
  local port

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Gateway Details"
  fi
  echo "Stage 1: Determining gateway for interface $iface..."

  gateway_ip="$(get_gateway_ip "$iface")"
  if [[ -z "$gateway_ip" ]]; then
    echo "Unable to determine default gateway."
    return
  fi

  echo "Done."
  echo
  echo "Gateway IP: $gateway_ip"
  echo
  echo "Stage 2: Scanning gateway ports (this may take up to 1 minute)..."

  local gateway_scan_file
  gateway_scan_file="$(mktemp)"

  nmap -p- --open -T4 "$gateway_ip" -oG - 2>/dev/null | awk '
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
  ' > "$gateway_scan_file" &
  local gateway_scan_pid=$!
  spinner
  wait_for_pid "$gateway_scan_pid" "Gateway port scan failed for $gateway_ip." || {
    rm -f "$gateway_scan_file"
    return 1
  }
  echo

  while IFS= read -r port; do
    [[ -n "$port" ]] && ports+=("$port")
  done < "$gateway_scan_file"
  rm -f "$gateway_scan_file"

  echo "Open Ports:"
  if [[ "${#ports[@]}" -eq 0 ]]; then
    echo "none found"
  else
    printf '%s\n' "${ports[@]}"
  fi

  jq -n \
    --arg gateway_ip "$gateway_ip" \
    --argjson open_ports "$(ports_to_json_array "${ports[@]}")" \
    '{gateway_ip: $gateway_ip, open_ports: $open_ports}' > "$(task_output_path 3)"

  validate_json_file "$(task_output_path 3)"
  echo "Saved JSON: $(task_output_path 3)"
}

extract_ping_summary_line() {
  local file="$1"
  awk '/(round-trip|rtt|min\/avg\/max)/ && /(stddev|mdev|min\/avg\/max)/ { line=$0 } END { print line }' "$file"
}

extract_ping_loss_percent() {
  local file="$1"
  awk -F',' '/packet loss/ {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
    gsub(/% packet loss/, "", $3)
    print $3
    exit
  }' "$file"
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
  local stage_warning=""
  local stage_failure=false
  local warning_json="null"
  local baseline_status="ok"
  local jitter_status="ok"
  local large_status="ok"
  local sustained_status="ok"
  local recovery_status="ok"
  local ramping_status="ok"

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "Gateway Stress Test"
  fi

  if ! confirm_gateway_stress_operation "Function 9"; then
    return 1
  fi

  if ! command -v ping >/dev/null 2>&1; then
    echo "ping is required for Gateway Stress Test."
    if [[ "$OS" == "macos" ]]; then
      echo "ping should be available as a macOS system command."
    else
      echo "Install with: apt-get install iputils-ping"
      echo "or"
      echo "dnf install iputils"
    fi
    return 1
  fi

  echo "Stage 1: Running Interface Network Info..."
  interface_info "$SELECTED_INTERFACE" silent

  interface_info_file="$(task_output_path 1)"

  if [[ ! -f "$interface_info_file" ]]; then
    echo "Gateway could not be detected."
    return 1
  fi

  gateway="$(jq -r '.gateway // empty' "$interface_info_file")"
  iface="$(jq -r '.interface // empty' "$interface_info_file")"

  if [[ -z "$gateway" && -n "$iface" ]]; then
    gateway="$(get_gateway_ip "$iface")"
  fi

  if [[ -z "$gateway" || "$gateway" == "null" ]]; then
    echo "Gateway could not be detected."
    return 1
  fi

  [[ -z "$iface" || "$iface" == "null" ]] && iface="$SELECTED_INTERFACE"

  echo "Done."
  echo "Gateway: $gateway"
  echo "Interface: $iface"
  echo

  baseline_file="$(mktemp)"
  jitter_file="$(mktemp)"
  large_file="$(mktemp)"
  ramp_sizes=(64 256 512 1024 1400)
  sustained_file="$(mktemp)"
  recovery_file="$(mktemp)"

  echo "Stage 2: Baseline latency test (20 pings)..."
  if ! run_ping_stage "$baseline_file" ping -c 20 "$gateway"; then
    baseline_status="failed"
    stage_failure=true
    echo "Warning: baseline latency test failed. Continuing with remaining stages."
  fi

  echo "Stage 3: Jitter test (200 pings @ 0.05s interval)..."
  if ! run_ping_stage "$jitter_file" ping -i 0.05 -c 200 "$gateway"; then
    jitter_status="failed"
    stage_failure=true
    echo "Warning: jitter test failed. Continuing with remaining stages."
  fi

  echo "Stage 4: Large packet test (100 pings @ 1400 bytes)..."
  if ! run_ping_stage "$large_file" ping -s 1400 -c 100 "$gateway"; then
    large_status="failed"
    stage_failure=true
    echo "Warning: large packet test failed. Continuing with remaining stages."
  fi

  echo "Stage 5: Ramping test (20 pings per packet size)..."
  for size in "${ramp_sizes[@]}"; do
    ramp_file="$(mktemp)"
    ramping_files+=("$ramp_file")
  done

  for idx in "${!ramp_sizes[@]}"; do
    if ! run_ping_stage "${ramping_files[$idx]}" ping -s "${ramp_sizes[$idx]}" -c 20 "$gateway"; then
      ramping_status="partial"
      stage_failure=true
      echo "Warning: ramping test failed for packet size ${ramp_sizes[$idx]}. Continuing with remaining stages."
    fi
  done

  echo "Stage 6: Sustained load test (300 pings @ 0.02s interval)..."
  if ! run_ping_stage "$sustained_file" ping -i 0.02 -c 300 "$gateway"; then
    sustained_status="failed"
    stage_failure=true
    echo "Warning: sustained load test failed. Continuing with remaining stages."
  fi

  echo "Stage 7: Recovery test (30 pings)..."
  if ! run_ping_stage "$recovery_file" ping -c 30 "$gateway"; then
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
    stage_warning="One or more gateway stress sub-tests failed on this host or gateway. Results may be partial."
  fi
  if [[ -n "$stage_warning" ]]; then
    warning_json="$(printf '%s' "$stage_warning" | jq -R .)"
  fi

  json_file="$(task_output_path 9)"
  {
    echo "{"
    echo "  \"function\": \"gateway_stress_test\"," 
    echo "  \"gateway\": \"$gateway\"," 
    echo "  \"interface\": \"$iface\"," 
    echo "  \"completed_with_warnings\": $stage_failure,"
    echo "  \"warning\": $warning_json,"
    echo "  \"stage_status\": {"
    echo "    \"baseline\": \"$baseline_status\","
    echo "    \"jitter\": \"$jitter_status\","
    echo "    \"large_packet\": \"$large_status\","
    echo "    \"ramping\": \"$ramping_status\","
    echo "    \"sustained\": \"$sustained_status\","
    echo "    \"recovery\": \"$recovery_status\""
    echo "  },"
    echo "  \"baseline\": {"
    echo "    \"avg_latency_ms\": $baseline_avg,"
    echo "    \"max_latency_ms\": $baseline_max,"
    echo "    \"stddev_ms\": $baseline_stddev"
    echo "  },"
    echo "  \"jitter_test\": {"
    echo "    \"stddev_ms\": $jitter_stddev,"
    echo "    \"max_latency_ms\": $jitter_max,"
    echo "    \"packet_loss_percent\": $jitter_loss"
    echo "  },"
    echo "  \"large_packet_test\": {"
    echo "    \"avg_latency_ms\": $large_avg,"
    echo "    \"max_latency_ms\": $large_max,"
    echo "    \"packet_loss_percent\": $large_loss"
    echo "  },"
    echo "  \"ramping_test\": ["
    for idx in "${!ramp_sizes[@]}"; do
      echo "    { \"packet_size\": ${ramp_sizes[$idx]}, \"avg_latency_ms\": ${ramping_avgs[$idx]}, \"max_latency_ms\": ${ramping_maxes[$idx]}, \"packet_loss_percent\": ${ramping_losses[$idx]} }$( [[ $idx -lt $(( ${#ramp_sizes[@]} - 1 )) ]] && echo "," )"
    done
    echo "  ],"
    echo "  \"sustained_test\": {"
    echo "    \"avg_latency_ms\": $sustained_avg,"
    echo "    \"max_latency_ms\": $sustained_max,"
    echo "    \"packet_loss_percent\": $sustained_loss"
    echo "  },"
    echo "  \"recovery\": {"
    echo "    \"avg_latency_ms\": $recovery_avg,"
    echo "    \"returned_to_baseline\": $returned_to_baseline"
    echo "  },"
    echo "  \"indicators\": {"
    echo "    \"high_jitter\": $high_jitter,"
    echo "    \"latency_under_load\": $latency_under_load,"
    echo "    \"packet_loss\": $packet_loss,"
    echo "    \"slow_recovery\": $slow_recovery"
    echo "  }"
    echo "}"
  } > "$json_file"

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
    echo "Gateway returned to baseline: YES"
  else
    echo "Gateway returned to baseline: NO"
  fi
  echo
  echo "Saved JSON: $json_file"
  validate_json_file "$json_file"
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

  if [[ "$SHOW_FUNCTION_HEADER" -eq 1 ]]; then
    echo
    echo "DHCP Network Scan"
  fi
  echo "Stage 1: Discovering DHCP servers on interface $SELECTED_INTERFACE..."

  dhcp_output_file="$(mktemp)"
  if [[ "$EUID" -eq 0 ]]; then
    dhcp_cmd=(nmap --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE")
  elif command -v sudo >/dev/null 2>&1; then
    dhcp_cmd=(sudo nmap --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE")
  else
    echo "DHCP discovery usually requires root privileges. Re-run as root or install sudo."
    return 1
  fi

  gateway_ip="$(get_gateway_ip "$SELECTED_INTERFACE")"

  for ((attempt = 1; attempt <= discovery_attempts; attempt++)); do
    echo "DHCP discovery attempt $attempt of $discovery_attempts..."
    tcpdump_output_file="$(mktemp)"
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
    --argjson dhcp_responders_observed "${#unique_servers[@]}" \
    --argjson discovery_attempts "$discovery_attempts" \
    --argjson offers_observed "$unique_offers_observed" \
    --argjson raw_offers_observed "$raw_offers_observed" \
    --argjson relay_sources_seen "$(json_string_array_from_array relay_sources_seen)" \
    --argjson tcpdump_capture_used "$tcpdump_enabled" \
    --arg discovery_note "$discovery_note" \
    '{
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
    echo "Saved JSON: $json_file"
    validate_json_file "$json_file"
    return
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
    echo "Scanning all ports on Server $((idx + 1)) (this may take up to 1 minute)..."

    dhcp_scan_file="$(mktemp)"
    nmap -p- --open "$server" -oG - > "$dhcp_scan_file" 2>/dev/null &
    local dhcp_scan_pid=$!
    spinner
    wait_for_pid "$dhcp_scan_pid" "DHCP server port scan failed for $server." || {
      rm -f "$dhcp_scan_file"
      return 1
    }
    echo

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

    echo "Open Ports Of Server $((idx + 1)) ($server):"
    if [[ "${#open_ports[@]}" -eq 0 ]]; then
      echo "none found"
    else
      printf '%s\n' "${open_ports[@]}"
    fi

    offer_count="$(printf '%s\n' "${raw_server_ids[@]}" | awk -v target="$server" '$0 == target {count++} END {print count+0}')"
    classification="$(classify_dhcp_server "$server" "$gateway_ip" "${open_ports[@]}")"
    if [[ "$classification" == "unknown" ]]; then
      suspected_rogue=true
      rogue_detected=true
      suspected_rogue_servers+=("$server")
    fi

    echo "Unique Offers Observed: $(count_unique_offer_keys_for_server "$server" "${unique_offer_keys[@]:-}")"
    echo "Raw Offers Captured: $offer_count"
    echo "Classification: $classification"
    if [[ "$suspected_rogue" == "true" ]]; then
      echo "Suspected Rogue DHCP Responder: YES"
    else
      echo "Suspected Rogue DHCP Responder: NO"
    fi

    jq \
      --arg ip "$server" \
      --argjson open_ports "$(ports_to_json_array "${open_ports[@]}")" \
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

  echo "Saved JSON: $json_file"
  validate_json_file "$json_file"
}


render_interface_info_report() {
  local file="$1"
  local report_file="$2"
  local iface ip subnet network mac

  iface="$(jq -r '.interface // "unknown"' "$file" 2>/dev/null)"
  ip="$(jq -r '.ip_address // "unknown"' "$file" 2>/dev/null)"
  subnet="$(jq -r '.subnet // "unknown"' "$file" 2>/dev/null)"
  network="$(jq -r '.network // "unknown"' "$file" 2>/dev/null)"
  mac="$(jq -r '.mac_address // "unknown"' "$file" 2>/dev/null)"

  {
    echo "Interface: ${iface:-unknown}"
    echo "IP Address: ${ip:-unknown}"
    echo "Subnet Mask: ${subnet:-unknown}"
    echo "Network Range: ${network:-unknown}"
    echo "MAC Address: ${mac:-unknown}"
  } >> "$report_file"
}

render_gateway_report() {
  local file="$1"
  local report_file="$2"
  local gateway ports

  gateway="$(jq -r '.gateway_ip // "unknown"' "$file" 2>/dev/null)"
  ports="$(jq -r '(.open_ports // []) | map(tostring) | join(", ")' "$file" 2>/dev/null)"

  {
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

  gateway="$(jq -r '.gateway // "unknown"' "$file" 2>/dev/null)"
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

render_dhcp_report() {
  local file="$1"
  local report_file="$2"
  local found
  local attempts
  local offers_observed
  local raw_offers_observed
  local rogue_suspected

  found="$(jq -r '.dhcp_responders_observed // .dhcp_servers_found // 0' "$file" 2>/dev/null)"
  attempts="$(jq -r '.discovery_attempts // 1' "$file" 2>/dev/null)"
  offers_observed="$(jq -r '.offers_observed // 0' "$file" 2>/dev/null)"
  raw_offers_observed="$(jq -r '.raw_offers_observed // .offers_observed // 0' "$file" 2>/dev/null)"
  rogue_suspected="$(jq -r '.rogue_dhcp_suspected // false' "$file" 2>/dev/null)"

  {
    echo "DHCP Responders Observed: ${found:-0}"
    echo "Discovery Attempts: ${attempts:-1}"
    echo "Unique Offers Observed: ${offers_observed:-0}"
    echo "Raw Offers Captured: ${raw_offers_observed:-0}"
    echo "Possible Rogue DHCP Present: ${rogue_suspected}"
  } >> "$report_file"

  jq -r 'if (.relay_sources_seen // []) | length > 0 then "Relay or Proxy Sources Seen: \((.relay_sources_seen // []) | join(", "))" else empty end' "$file" >> "$report_file"

  jq -r '.servers[]? | "- DHCP Responder \(.ip) | Unique Offers: \(.offers_observed // 0) | Raw Offers: \(.raw_offers_observed // .offers_observed // 0) | Classification: \(.classification // "unknown") | Suspected Rogue: \(.suspected_rogue // false) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end)"' "$file" >> "$report_file"

  jq -r 'if (.suspected_rogue_servers // []) | length > 0 then "Suspected Rogue Responders: \((.suspected_rogue_servers // []) | join(", "))" else empty end' "$file" >> "$report_file"
}

render_generic_network_scan_report() {
  local file="$1"
  local report_file="$2"
  local label="$3"
  local network ports server_count

  network="$(jq -r '.network // "unknown"' "$file" 2>/dev/null)"
  ports="$(jq -r '.scan_ports // "unknown"' "$file" 2>/dev/null)"
  server_count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"

  {
    echo "Network Range: ${network:-unknown}"
    echo "Scanned Ports: ${ports:-unknown}"
    echo "Servers Found: $server_count"
  } >> "$report_file"

  jq -r --arg lbl "$label" '.servers[]? | "- \($lbl) Host \(.ip) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end) | Services: \((.detected_services // []) | if length > 0 then join(", ") else "unknown" end)"' "$file" >> "$report_file"
}


get_task_ids() {
  awk -F'|' 'NF {print $1}' <<< "$TASKS_DATA" | paste -sd' ' -
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
    5) detect_dns_servers ;;
    6) detect_ldap_servers ;;
    7) detect_smb_nfs_servers ;;
    8) detect_print_servers ;;
    9) gateway_stress_test ;;
    *) return 1 ;;
  esac
}

run_task_with_progress_output() {
  local func_id="$1"
  local func_name="$2"
  local green='\033[0;32m'
  local red='\033[0;31m'
  local reset='\033[0m'
  local debug_target="/dev/null"

  if [[ -n "$SESSION_DEBUG_LOG" ]]; then
    debug_target="$SESSION_DEBUG_LOG"
  fi

  echo "Running Function $func_id ($func_name)"
  if run_task_by_id "$func_id" >>"$debug_target" 2>&1; then
    printf "Running Function %s (%s): ${green}Done${reset}\n" "$func_id" "$func_name"
  else
    printf "Running Function %s (%s): ${red}Failed${reset}\n" "$func_id" "$func_name"
    return 1
  fi
}

run_task_with_results_output() {
  local func_id="$1"
  local func_name="$2"

  clear_screen_if_supported
  echo "Running Function: $func_name"
  echo "=============================="
  echo
  SHOW_FUNCTION_HEADER=0
  if ! run_task_by_id "$func_id"; then
    SHOW_FUNCTION_HEADER=1
    return 1
  fi
  SHOW_FUNCTION_HEADER=1
  echo
  echo "=============================="
  echo
}

run_all_tasks() {
  local task_ids=()
  local func_id
  local func_name

  if ! confirm_gateway_stress_operation "000 Complete Network Audit"; then
    return 1
  fi

  read -r -a task_ids <<< "$(get_task_ids)"

  for func_id in "${task_ids[@]}"; do
    func_name="$(task_title "$func_id")"

    if [[ -z "$func_name" ]]; then
      func_name="Function $func_id"
    fi

    if ! run_task_with_progress_output "$func_id" "$func_name"; then
      echo "Run all tasks stopped because Function $func_id failed."
      return 1
    fi
  done
}

main_menu() {
  local choice
  local task_ids=()
  local func_id
  local title
  local yellow='\033[1;33m'
  local reset='\033[0m'

  read -r -a task_ids <<< "$(get_task_ids)"

  while true; do
    echo
    printf "${yellow}Selected Interface: %s${reset}\n" "$SELECTED_INTERFACE"
    printf "${yellow}================================================${reset}\n"

    for func_id in "${task_ids[@]}"; do
      title="$(task_title "$func_id")"
      if [[ -n "$title" ]]; then
        printf "${yellow}%s) %s${reset}\n" "$func_id" "$title"
      fi
    done

    printf "${yellow}================================================${reset}\n"
    printf "${yellow}000) %s (This may take a long time.)${reset}\n" "$(task_title "000")"
    printf "${yellow}0) Exit${reset}\n"
    printf "${yellow}----------------${reset}\n"

    read -r -p "Enter selection: " choice

    case "$choice" in
      000)
        clear_screen_if_supported
        echo "Running Function: $(task_title "000")"
        echo "=============================="
        echo
        run_all_tasks
        echo
        echo "=============================="
        echo
        ;;
      0) exit 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && run_task_exists "$choice"; then
          title="$(task_title "$choice")"
          if [[ -z "$title" ]]; then
            title="Function $choice"
          fi
          run_task_with_results_output "$choice" "$title"
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
detect_os
initialize_debug_logging
check_tools
mkdir -p "$OUTPUT_DIR"
warn_if_not_root
select_interface
initialize_run_context
trap finalize_run EXIT
main_menu
