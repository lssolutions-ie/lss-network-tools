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
  local red='[0;31m'
  local green='[0;32m'
  local reset='[0m'
  local base_tools=(nmap awk sed grep find mktemp sudo)
  local os_tools=()
  local tool

  if [[ "$OS" == "macos" ]]; then
    os_tools=(ipconfig ifconfig route networksetup)
  else
    os_tools=(ip)
  fi

  echo
  echo "Dependency checklist"

  for tool in "${base_tools[@]}" "${os_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf "${green}[OK]${reset} %s\n" "$tool"
    else
      printf "${red}[MISSING]${reset} %s\n" "$tool"
      missing=1
    fi
  done

  if [[ "$OS" == "linux" ]] && ! command -v ifconfig >/dev/null 2>&1; then
    echo "Optional fallback missing: ifconfig"
    echo "Install with: apt install net-tools"
  fi

  if [[ "$missing" -eq 1 ]]; then
    echo
    echo "Missing required dependencies:"
    for tool in "${base_tools[@]}" "${os_tools[@]}"; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ "$tool" == "ip" ]]; then
          print_install_hint "iproute2"
        else
          print_install_hint "$tool"
        fi
      fi
    done
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

get_interface_network_cidr() {
  local iface="$1"
  local ip=""
  local mask=""
  local prefix=""

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
  fi

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

scan_servers_by_ports() {
  local title="$1"
  local description="$2"
  local port_list="$3"
  local output_file="$4"
  local network
  local scan_file
  local json_file
  local result_count=0

  echo
  echo "$title"
  echo "Stage 1: Getting network range for interface $SELECTED_INTERFACE..."

  network="$(get_interface_network_cidr "$SELECTED_INTERFACE")"
  if [[ -z "$network" ]]; then
    echo "Unable to determine network range for $SELECTED_INTERFACE"
    return
  fi

  echo "Done."
  echo "Network Range: $network"
  echo
  echo "Stage 2: Scanning $description ports ($port_list)..."

  scan_file="$(mktemp)"
  nmap -n -p "$port_list" --open "$network" -oG - > "$scan_file" 2>/dev/null &
  spinner
  wait

  json_file="$OUTPUT_DIR/$output_file"
  {
    echo "{"
    echo "  \"network\": \"$network\"," 
    echo "  \"scan_ports\": \"$port_list\"," 
    echo "  \"servers\": ["
  } > "$json_file"

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

    if (( result_count > 0 )); then
      echo "    ," >> "$json_file"
    fi

    {
      echo "    {"
      echo "      \"ip\": \"$host_ip\"," 
      echo "      \"open_ports\": $(ports_to_json_array "${ports_array[@]}"),"
      printf "      \"detected_services\": ["
      for i in "${!service_names[@]}"; do
        if (( i > 0 )); then
          printf ", "
        fi
        printf '"%s"' "${service_names[$i]}"
      done
      echo "]"
      echo "    }"
    } >> "$json_file"

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

  {
    echo "  ]"
    echo "}"
  } >> "$json_file"

  echo "$title results found: $result_count"
  echo "Saved JSON: $json_file"
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
  local i=0
  local -a spin_frames

  if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"UTF-8"* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"utf8"* ]]; then
    spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  else
    spin_frames=("-" "\\" "|" "/")
  fi

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r[%s] Scanning..." "${spin_frames[$i]}"
    i=$(( (i + 1) % ${#spin_frames[@]} ))
    sleep 0.2
  done
  printf "\rDone.           \n"
}

gateway_details() {
  local iface="$1"
  local gateway_ip
  local ports=()
  local port

  echo
  echo "Gateway Details"
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
  spinner
  wait
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

  {
    echo "{"
    echo "  \"gateway_ip\": \"$gateway_ip\"," 
    echo "  \"open_ports\": $(ports_to_json_array "${ports[@]}")"
    echo "}"
  } > "$OUTPUT_DIR/gateway-scan.json"

  echo "Saved JSON: $OUTPUT_DIR/gateway-scan.json"
}

dhcp_network_scan() {
  local servers=()
  local unique_servers=()
  local server
  local idx
  local dhcp_output_file
  local json_file

  echo
  echo "DHCP Network Scan"
  echo "Stage 1: Discovering DHCP servers on interface $SELECTED_INTERFACE..."

  dhcp_output_file="$(mktemp)"
  sudo nmap --script broadcast-dhcp-discover -e "$SELECTED_INTERFACE" > "$dhcp_output_file" 2>/dev/null &
  spinner
  wait

  while IFS= read -r server; do
    [[ -n "$server" ]] && servers+=("$server")
  done < <(awk '/Server Identifier:/ {
    for(i=1;i<=NF;i++) {
      if($i ~ /^[0-9]+(\.[0-9]+){3}$/) {
        print $i
      }
    }
  }' "$dhcp_output_file")

  rm -f "$dhcp_output_file"

  if [[ "${#servers[@]}" -gt 0 ]]; then
    while IFS= read -r server; do
      [[ -n "$server" ]] && unique_servers+=("$server")
    done < <(printf "%s\n" "${servers[@]}" | awk '!seen[$0]++')
  fi

  echo "DHCP servers found: ${#unique_servers[@]}"

  if [[ "${#unique_servers[@]}" -gt 0 ]]; then
    for idx in "${!unique_servers[@]}"; do
      echo "DHCP IP Address: ${unique_servers[$idx]}"
    done
  fi

  echo

  json_file="$OUTPUT_DIR/dhcp-scan.json"
  {
    echo "{"
    echo "  \"dhcp_servers_found\": ${#unique_servers[@]},"
    echo "  \"servers\": ["
  } > "$json_file"

  if [[ "${#unique_servers[@]}" -eq 0 ]]; then
    {
      echo "  ]"
      echo "}"
    } >> "$json_file"
    echo "Saved JSON: $json_file"
    return
  fi

  echo "Stage 2: Scanning for ports on DHCP server(s)..."

  for idx in "${!unique_servers[@]}"; do
    local open_ports=()
    local dhcp_scan_file
    local port
    server="${unique_servers[$idx]}"

    echo
    echo "Scanning all ports on Server $((idx + 1)) (this may take up to 1 minute)..."

    dhcp_scan_file="$(mktemp)"
    nmap -p- --open "$server" -oG - > "$dhcp_scan_file" 2>/dev/null &
    spinner
    wait
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

    {
      echo "    {"
      echo "      \"ip\": \"$server\"," 
      echo "      \"open_ports\": $(ports_to_json_array "${open_ports[@]}")"
      if (( idx < ${#unique_servers[@]} - 1 )); then
        echo "    },"
      else
        echo "    }"
      fi
    } >> "$json_file"
  done

  {
    echo "  ]"
    echo "}"
  } >> "$json_file"

  echo "Saved JSON: $json_file"
}


json_get_string_value() {
  local key="$1"
  local file="$2"
  awk -F'"' -v k="$key" '$2 == k { print $4; exit }' "$file"
}

json_get_numeric_array() {
  local key="$1"
  local file="$2"
  awk -v k="$key" '
    index($0, "\"" k "\"") {
      line = $0
      sub(/^.*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$file"
}

render_interface_info_report() {
  local file="$1"
  local report_file="$2"
  local iface ip subnet network mac

  iface="$(json_get_string_value "interface" "$file")"
  ip="$(json_get_string_value "ip_address" "$file")"
  subnet="$(json_get_string_value "subnet" "$file")"
  network="$(json_get_string_value "network" "$file")"
  mac="$(json_get_string_value "mac_address" "$file")"

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

  gateway="$(json_get_string_value "gateway_ip" "$file")"
  ports="$(json_get_numeric_array "open_ports" "$file")"

  {
    echo "Gateway IP: ${gateway:-unknown}"
    if [[ -n "$ports" ]]; then
      echo "Open Ports: $ports"
    else
      echo "Open Ports: none found"
    fi
  } >> "$report_file"
}

render_dhcp_report() {
  local file="$1"
  local report_file="$2"
  local found

  found="$(awk -F': ' '/"dhcp_servers_found"/ {gsub(/,/, "", $2); print $2; exit}' "$file")"

  echo "DHCP Servers Found: ${found:-0}" >> "$report_file"

  awk -F'"' '
    /"ip":/ {
      ip = $4
      next
    }
    /"open_ports":/ {
      line = $0
      sub(/^.*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") {
        line = "none found"
      }
      printf("- DHCP Server %s | Open Ports: %s\n", ip, line)
    }
  ' "$file" >> "$report_file"
}

render_generic_network_scan_report() {
  local file="$1"
  local report_file="$2"
  local label="$3"
  local network ports server_count

  network="$(json_get_string_value "network" "$file")"
  ports="$(json_get_string_value "scan_ports" "$file")"
  server_count="$(awk -F'"' '/"ip":/ {count++} END {print count+0}' "$file")"

  {
    echo "Network Range: ${network:-unknown}"
    echo "Scanned Ports: ${ports:-unknown}"
    echo "Servers Found: $server_count"
  } >> "$report_file"

  awk -F'"' -v lbl="$label" '
    /"ip":/ {
      ip = $4
      next
    }
    /"open_ports":/ {
      ports_line = $0
      sub(/^.*\[/, "", ports_line)
      sub(/\].*$/, "", ports_line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ports_line)
      if (ports_line == "") {
        ports_line = "none found"
      }
      next
    }
    /"detected_services":/ {
      services_line = $0
      sub(/^.*\[/, "", services_line)
      sub(/\].*$/, "", services_line)
      gsub(/"/, "", services_line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", services_line)
      if (services_line == "") {
        services_line = "unknown"
      }
      printf("- %s Host %s | Open Ports: %s | Services: %s\n", lbl, ip, ports_line, services_line)
    }
  ' "$file" >> "$report_file"
}


get_task_ids() {
  echo "1 2 3 4 5 6 7"
}

task_title() {
  case "$1" in
    1) echo "Interface Network Info" ;;
    2) echo "Gateway Details" ;;
    3) echo "DHCP Network Scan" ;;
    4) echo "DNS Network Scan" ;;
    5) echo "LDAP/AD Network Scan" ;;
    6) echo "SMB/NFS Network Scan" ;;
    7) echo "Printer/Print Server Network Scan" ;;
    *) return 1 ;;
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
    2) gateway_details "$SELECTED_INTERFACE" ;;
    3) dhcp_network_scan ;;
    4) detect_dns_servers ;;
    5) detect_ldap_servers ;;
    6) detect_smb_nfs_servers ;;
    7) detect_print_servers ;;
    *) return 1 ;;
  esac
}

run_task_with_compact_output() {
  local func_id="$1"
  local func_name="$2"
  local green='\033[0;32m'
  local red='\033[0;31m'
  local reset='\033[0m'
  local i=0
  local pid
  local -a spin_frames

  if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"UTF-8"* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *"utf8"* ]]; then
    spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  else
    spin_frames=("-" "\\" "|" "/")
  fi

  printf "Running Function %s (%s): " "$func_id" "$func_name"

  run_task_by_id "$func_id" >/dev/null 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    printf "\rRunning Function %s (%s): %s" "$func_id" "$func_name" "${spin_frames[$i]}"
    i=$(( (i + 1) % ${#spin_frames[@]} ))
    sleep 0.2
  done

  wait "$pid"
  if [[ "$?" -eq 0 ]]; then
    printf "\rRunning Function %s (%s): ${green}Done${reset}\n" "$func_id" "$func_name"
  else
    printf "\rRunning Function %s (%s): ${red}Failed${reset}\n" "$func_id" "$func_name"
    return 1
  fi
}

run_all_tasks() {
  local task_ids=()
  local func_id
  local func_name

  read -r -a task_ids <<< "$(get_task_ids)"

  for func_id in "${task_ids[@]}"; do
    func_name="$(task_title "$func_id")"

    if [[ -z "$func_name" ]]; then
      func_name="Unknown Function"
    fi

    if ! run_task_with_compact_output "$func_id" "$func_name"; then
      echo "Run all tasks stopped because Function $func_id failed."
      return 1
    fi
  done
}

build_report() {
  local json_count
  local report_file
  local timestamp
  local ran_summary=""
  local missing_summary=""
  local func_id title file_path

  json_count="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | awk '{print $1}')"
  if [[ "$json_count" -eq 0 ]]; then
    echo "No JSON scan files found in $OUTPUT_DIR"
    echo "Run some scans first, then choose 00) Build Report again."
    return
  fi

  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  report_file="$OUTPUT_DIR/network-report-$(date '+%Y%m%d-%H%M%S').txt"

  {
    echo "==============================================="
    echo "     LSS NETWORK TOOLS - HUMAN READABLE REPORT"
    echo "==============================================="
    echo "Generated: $timestamp"
    echo "Selected Interface: ${SELECTED_INTERFACE:-unknown}"
    echo
  } > "$report_file"

  for func_id in $(get_task_ids); do
    title="$(task_title "$func_id")"
    case "$func_id" in
      1) file_path="$OUTPUT_DIR/interface-info.json" ;;
      2) file_path="$OUTPUT_DIR/gateway-scan.json" ;;
      3) file_path="$OUTPUT_DIR/dhcp-scan.json" ;;
      4) file_path="$OUTPUT_DIR/dns-scan.json" ;;
      5) file_path="$OUTPUT_DIR/ldap-ad-scan.json" ;;
      6) file_path="$OUTPUT_DIR/smb-nfs-scan.json" ;;
      7) file_path="$OUTPUT_DIR/print-server-scan.json" ;;
      *) continue ;;
    esac

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
    case "$func_id" in
      1) file_path="$OUTPUT_DIR/interface-info.json" ;;
      2) file_path="$OUTPUT_DIR/gateway-scan.json" ;;
      3) file_path="$OUTPUT_DIR/dhcp-scan.json" ;;
      4) file_path="$OUTPUT_DIR/dns-scan.json" ;;
      5) file_path="$OUTPUT_DIR/ldap-ad-scan.json" ;;
      6) file_path="$OUTPUT_DIR/smb-nfs-scan.json" ;;
      7) file_path="$OUTPUT_DIR/print-server-scan.json" ;;
      *) continue ;;
    esac

    {
      echo "================================================"
      echo "Function $func_id) $title"
      echo "================================================"
    } >> "$report_file"

    if [[ ! -f "$file_path" ]]; then
      echo "Not run (no $file_path found)." >> "$report_file"
      echo >> "$report_file"
      continue
    fi

    case "$func_id" in
      1) render_interface_info_report "$file_path" "$report_file" ;;
      2) render_gateway_report "$file_path" "$report_file" ;;
      3) render_dhcp_report "$file_path" "$report_file" ;;
      4) render_generic_network_scan_report "$file_path" "$report_file" "DNS" ;;
      5) render_generic_network_scan_report "$file_path" "$report_file" "LDAP/AD" ;;
      6) render_generic_network_scan_report "$file_path" "$report_file" "SMB/NFS" ;;
      7) render_generic_network_scan_report "$file_path" "$report_file" "Printer" ;;
    esac

    echo >> "$report_file"
  done

  echo "Report built successfully: $report_file"
}

main_menu() {
  local choice
  local task_ids=()
  local func_id
  local title

  read -r -a task_ids <<< "$(get_task_ids)"

  while true; do
    echo
    echo "Selected Interface: $SELECTED_INTERFACE"
    echo "================================================"

    for func_id in "${task_ids[@]}"; do
      title="$(task_title "$func_id")"
      if [[ -n "$title" ]]; then
        echo "$func_id) $title"
      fi
    done

    echo "================================================"
    echo "000) Run all tasks (This may take a long time.)"
    echo "00) Build Report"
    echo "0) Exit"
    echo "----------------"

    read -r -p "Enter selection: " choice

    case "$choice" in
      000) run_all_tasks ;;
      00) build_report ;;
      0) exit 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && run_task_exists "$choice"; then
          run_task_by_id "$choice"
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

check_existing_output_data() {
  local choice

  if [[ ! -d "$OUTPUT_DIR" ]]; then
    return
  fi

  if [[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    return
  fi

  echo
  echo "Existing output data found in: $OUTPUT_DIR"
  echo "1) Continue with new scan (delete all output files and continue)"
  echo "2) Exit script to backup data"

  while true; do
    read -r -p "Enter selection: " choice
    case "$choice" in
      1)
        find "$OUTPUT_DIR" -mindepth 1 -delete
        echo "Previous output deleted. Continuing..."
        return
        ;;
      2)
        echo "Exiting. Please backup your output data and run the script again."
        exit 0
        ;;
      *)
        echo "Invalid selection. Enter 1 or 2."
        ;;
    esac
  done
}

detect_os
check_tools
mkdir -p "$OUTPUT_DIR"
check_existing_output_data
warn_if_not_root
select_interface
main_menu
