#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

OS=""

warn_if_not_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Some scans may not work correctly without root privileges."
  fi
}

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
    echo "Please install missing required tools and rerun."
    exit 1
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
      if [[ "$OS" == "macos" ]]; then
        local description
        description="$(get_interface_description "$iface")"
        if [[ -n "$description" ]]; then
          echo "$idx) $iface ($description)"
        else
          echo "$idx) $iface"
        fi
      else
        echo "$idx) $iface"
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

interface_info() {
  local iface="$1"
  local ip=""
  local mask=""
  local prefix=""
  local network=""
  local mac=""

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

  if [[ -z "$ip" || -z "$mask" ]]; then
    echo "Unable to determine IP or subnet for interface $iface"
    return
  fi

  if [[ -z "$prefix" ]]; then
    prefix="$(mask_to_prefix "$mask")"
  fi
  network="$(calculate_network "$ip" "$prefix")"

  echo
  echo "Interface Network Info"
  echo "Interface: $iface"
  echo "IP Address: $ip"
  echo "Subnet Mask: $mask"
  echo "Network Range: $network"
  echo "MAC Address: $mac"

  cat > "$OUTPUT_DIR/interface-info.json" <<JSON
{
  "interface": "$iface",
  "ip_address": "$ip",
  "subnet": "$mask",
  "network": "$network",
  "mac_address": "$mac"
}
JSON

  echo "Saved JSON: $OUTPUT_DIR/interface-info.json"
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

scan_open_ports() {
  local target_ip="$1"
  nmap -p- --open -T4 "$target_ip" -oG - 2>/dev/null | awk '
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
  '
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

gateway_details() {
  local iface="$1"
  local gateway_ip
  local ports=()
  local port

  gateway_ip="$(get_gateway_ip "$iface")"
  if [[ -z "$gateway_ip" ]]; then
    echo "Unable to determine default gateway."
    return
  fi

  while IFS= read -r port; do
    [[ -n "$port" ]] && ports+=("$port")
  done < <(scan_open_ports "$gateway_ip")

  echo
  echo "Gateway Details"
  echo "Gateway IP: $gateway_ip"
  if [[ "${#ports[@]}" -eq 0 ]]; then
    echo "Open Ports: none found"
  else
    echo "Open Ports: ${ports[*]}"
  fi

  {
    echo "{"
    echo "  \"gateway_ip\": \"$gateway_ip\"," 
    echo "  \"open_ports\": $(ports_to_json_array "${ports[@]}")"
    echo "}"
  } > "$OUTPUT_DIR/gateway-scan.json"

  echo "Saved JSON: $OUTPUT_DIR/gateway-scan.json"
}

dhcp_network_scan() {
  local raw_output
  local servers=()
  local unique_servers=()
  local server
  local idx

  raw_output="$(sudo nmap --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE" 2>/dev/null)"

  while IFS= read -r server; do
    [[ -n "$server" ]] && servers+=("$server")
  done < <(echo "$raw_output" | awk '/Server Identifier:/ {
    for(i=1;i<=NF;i++) {
      if($i ~ /^[0-9]+(\.[0-9]+){3}$/) {
        print $i
      }
    }
  }')

  if [[ "${#servers[@]}" -gt 0 ]]; then
    mapfile -t unique_servers < <(printf "%s\n" "${servers[@]}" | awk '!seen[$0]++')
  fi

  echo
  echo "DHCP Network Scan"
  echo "DHCP servers found: ${#unique_servers[@]}"

  {
    echo "{"
    echo "  \"dhcp_servers_found\": ${#unique_servers[@]},"
    echo "  \"servers\": ["

    for idx in "${!unique_servers[@]}"; do
      local open_ports=()
      server="${unique_servers[$idx]}"

      echo "  - Scanning DHCP server: $server"
      mapfile -t open_ports < <(scan_open_ports "$server")

      if [[ "${#open_ports[@]}" -eq 0 ]]; then
        echo "    Open ports: none found"
      else
        echo "    Open ports: ${open_ports[*]}"
      fi

      echo "    {"
      echo "      \"ip\": \"$server\"," 
      echo "      \"open_ports\": $(ports_to_json_array "${open_ports[@]}")"
      if (( idx < ${#unique_servers[@]} - 1 )); then
        echo "    },"
      else
        echo "    }"
      fi
    done

    echo "  ]"
    echo "}"
  } > "$OUTPUT_DIR/dhcp-scan.json"

  if [[ "${#unique_servers[@]}" -eq 0 ]]; then
    cat > "$OUTPUT_DIR/dhcp-scan.json" <<JSON
{
  "dhcp_servers_found": 0,
  "servers": []
}
JSON
  fi

  echo "Saved JSON: $OUTPUT_DIR/dhcp-scan.json"
}

main_menu() {
  local choice
  while true; do
    echo
    echo "Selected Interface: $SELECTED_INTERFACE"
    echo "1) Interface Network Info"
    echo "2) Gateway Details"
    echo "3) DHCP Network Scan"
    echo "0) Exit"

    read -r -p "Enter selection: " choice

    case "$choice" in
      1) interface_info "$SELECTED_INTERFACE" ;;
      2) gateway_details "$SELECTED_INTERFACE" ;;
      3) dhcp_network_scan ;;
      0) exit 0 ;;
      *) echo "Invalid selection. Try again." ;;
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

mkdir -p "$OUTPUT_DIR"
detect_os
warn_if_not_root
check_tools
select_interface
main_menu
