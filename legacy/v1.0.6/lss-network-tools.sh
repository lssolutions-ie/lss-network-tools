#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_VERSION="v1.0.6"
APP_GITHUB_REPO="lssolutions-ie/lss-network-tools"
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
RUN_MANIFEST_FILE=""
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
10|Custom Target Port Scan|custom-target-port-scan.json
11|Custom Target Stress Test|custom-target-stress-test.json
13|Custom Target Identity Scan|custom-target-identity-scan.json
14|Custom Target DNS Assessment|custom-target-dns-assessment.json
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

current_raw_output_dir() {
  printf '%s/raw\n' "$(current_output_dir)"
}

initialize_debug_logging() {
  if [[ -n "$SESSION_DEBUG_LOG" ]]; then
    return
  fi

  find "$OUTPUT_DIR" -maxdepth 1 -type f -name '.debug-session-*.txt' -delete 2>/dev/null || true

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

task_supports_multiple_entries() {
  case "$1" in
    10|11|13|14) return 0 ;;
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
    hostname="$(dig +short -x "$target_ip" 2>/dev/null | sed -n '1p' | sed 's/\.$//')"
  fi

  if [[ -z "$hostname" ]] && command -v host >/dev/null 2>&1; then
    hostname="$(host "$target_ip" 2>/dev/null | awk '/domain name pointer/ {print $NF; exit}' | sed 's/\.$//')"
  fi

  if [[ -z "$hostname" ]] && command -v nslookup >/dev/null 2>&1; then
    hostname="$(nslookup "$target_ip" 2>/dev/null | awk -F'= ' '/name =/ {print $2; exit}' | sed 's/\.$//')"
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
  RUN_MANIFEST_FILE="$RUN_OUTPUT_DIR/manifest.json"

  mkdir -p "$RUN_OUTPUT_DIR"
  mkdir -p "$(current_raw_output_dir)"

  echo
  echo "Run output directory: $RUN_OUTPUT_DIR"
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
    echo "Generated: $timestamp"
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
        5) render_generic_network_scan_report "$file_path" "$report_file" "DNS" ;;
        6) render_generic_network_scan_report "$file_path" "$report_file" "LDAP/AD" ;;
        7) render_generic_network_scan_report "$file_path" "$report_file" "SMB/NFS" ;;
        8) render_generic_network_scan_report "$file_path" "$report_file" "Printer" ;;
        9) render_gateway_stress_report "$file_path" "$report_file" ;;
        10) render_custom_target_port_scan_report "$file_path" "$report_file" ;;
        11) render_custom_target_stress_report "$file_path" "$report_file" ;;
        13) render_custom_target_identity_report "$file_path" "$report_file" ;;
        14) render_custom_target_dns_assessment_report "$file_path" "$report_file" ;;
      esac

      echo >> "$report_file"
    done
  done

  append_findings_summary "$report_file"
  append_remediation_hints "$report_file"

  echo "Report built successfully: $report_file"
}

list_reportable_run_dirs() {
  local dir

  find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
    if find "$dir" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
      echo "$dir"
    fi
  done | while IFS= read -r dir; do
    printf '%s\t%s\n' "$(stat -f '%m' "$dir" 2>/dev/null || stat -c '%Y' "$dir" 2>/dev/null || echo 0)" "$dir"
  done | sort -rn | awk -F'\t' '{print $2}'
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
    SELECTED_INTERFACE="$(jq -r '.selected_interface // "unknown"' "$manifest_file" 2>/dev/null)"
  else
    RUN_LOCATION="Unknown"
    RUN_CLIENT_NAME="Unknown"
  fi

  RUN_LOCATION_SLUG="$(sanitize_for_filename "$RUN_LOCATION")"
  RUN_CLIENT_SLUG="$(sanitize_for_filename "$RUN_CLIENT_NAME")"
  RUN_DATE_STAMP="$(date '+%d-%m-%Y')"
}

build_report_from_previous_run() {
  local run_dirs=()
  local run_dir=""
  local idx=1
  local choice=""
  local export_choice=""
  local export_dir=""
  local report_name=""
  local previous_output_dir="${RUN_OUTPUT_DIR:-}"
  local previous_report_file="${RUN_REPORT_FILE:-}"
  local previous_debug_log="${RUN_DEBUG_LOG:-}"
  local previous_manifest_file="${RUN_MANIFEST_FILE:-}"
  local previous_location="${RUN_LOCATION:-}"
  local previous_client="${RUN_CLIENT_NAME:-}"
  local previous_location_slug="${RUN_LOCATION_SLUG:-}"
  local previous_client_slug="${RUN_CLIENT_SLUG:-}"
  local previous_date_stamp="${RUN_DATE_STAMP:-}"
  local previous_selected_interface="${SELECTED_INTERFACE:-}"

  while IFS= read -r run_dir; do
    [[ -n "$run_dir" ]] && run_dirs+=("$run_dir")
  done < <(list_reportable_run_dirs)

  if [[ "${#run_dirs[@]}" -eq 0 ]]; then
    echo "No previous runs with usable JSON outputs were found in $OUTPUT_DIR."
    return 0
  fi

  echo
  echo "Build Report From Previous Run"
  echo "=============================="
  echo
  for run_dir in "${run_dirs[@]}"; do
    echo "$idx) $(basename "$run_dir")"
    idx=$((idx + 1))
  done
  echo "0) Exit"
  echo

  read -r -p "Choose previous run: " choice
  if [[ "$choice" == "0" ]]; then
    return 0
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#run_dirs[@]} )); then
    echo "Invalid selection. Returning to main menu."
    return 1
  fi

  run_dir="${run_dirs[$((choice - 1))]}"
  export_dir="$(default_report_export_dir)"
  report_name="lss-network-tools-report-$(basename "$run_dir")-$(date '+%H-%M').txt"

  echo
  echo "Report $report_name will be saved to $export_dir."
  echo "Would you like it somewhere else?"
  echo "1) Yes"
  echo "2) No"
  echo "3) Do nothing and exit"
  echo
  read -r -p "Choose option: " export_choice

  case "$export_choice" in
    1)
      read -r -p "New directory: " export_dir
      if [[ -z "$export_dir" ]]; then
        echo "No directory provided. Returning to main menu."
        return 1
      fi
      mkdir -p "$export_dir" 2>/dev/null || {
        echo "Unable to create or access directory: $export_dir"
        return 1
      }
      ;;
    2)
      mkdir -p "$export_dir" 2>/dev/null || true
      ;;
    3)
      return 0
      ;;
    *)
      echo "Invalid selection. Returning to main menu."
      return 1
      ;;
  esac

  RUN_OUTPUT_DIR="$run_dir"
  RUN_DEBUG_LOG="$run_dir/debug.txt"
  RUN_MANIFEST_FILE="$run_dir/manifest.json"
  load_run_metadata_from_dir "$run_dir"
  RUN_REPORT_FILE="$export_dir/$report_name"

  if ! build_report_for_current_run; then
    RUN_OUTPUT_DIR="$previous_output_dir"
    RUN_REPORT_FILE="$previous_report_file"
    RUN_DEBUG_LOG="$previous_debug_log"
    RUN_MANIFEST_FILE="$previous_manifest_file"
    RUN_LOCATION="$previous_location"
    RUN_CLIENT_NAME="$previous_client"
    RUN_LOCATION_SLUG="$previous_location_slug"
    RUN_CLIENT_SLUG="$previous_client_slug"
    RUN_DATE_STAMP="$previous_date_stamp"
    SELECTED_INTERFACE="$previous_selected_interface"
    return 1
  fi

  RUN_OUTPUT_DIR="$previous_output_dir"
  RUN_REPORT_FILE="$previous_report_file"
  RUN_DEBUG_LOG="$previous_debug_log"
  RUN_MANIFEST_FILE="$previous_manifest_file"
  RUN_LOCATION="$previous_location"
  RUN_CLIENT_NAME="$previous_client"
  RUN_LOCATION_SLUG="$previous_location_slug"
  RUN_CLIENT_SLUG="$previous_client_slug"
  RUN_DATE_STAMP="$previous_date_stamp"
  SELECTED_INTERFACE="$previous_selected_interface"
}

delete_all_previous_runs() {
  local confirmation=""
  local run_count=0

  run_count="$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | awk '{print $1}')"
  if [[ "$run_count" -eq 0 ]]; then
    echo "No previous runs were found in $OUTPUT_DIR."
    return 0
  fi

  echo
  echo "Delete All Previous Runs"
  echo "========================"
  echo "This will permanently remove all run folders under:"
  echo "$OUTPUT_DIR"
  echo
  read -r -p "Type DELETE to continue: " confirmation

  if [[ "$confirmation" != "DELETE" ]]; then
    echo "Deletion cancelled."
    return 0
  fi

  find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  find "$OUTPUT_DIR" -maxdepth 1 -type f -name '.debug-session-*.txt' -delete 2>/dev/null || true
  echo "All previous runs have been deleted."
}

latest_local_tag() {
  git for-each-ref --format '%(refname:strip=2)' refs/tags 2>/dev/null | sort -V | tail -n 1
}

latest_remote_tag() {
  git ls-remote --tags --refs origin 2>/dev/null | awk -F/ '{print $NF}' | sort -V | tail -n 1
}

remote_origin_url() {
  git remote get-url origin 2>/dev/null || true
}

github_api_headers() {
  local token="${GITHUB_TOKEN:-}"

  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi

  if [[ -n "$token" ]]; then
    printf 'Authorization: Bearer %s\n' "$token"
    printf 'Accept: application/vnd.github+json\n'
  fi
}

prompt_for_github_token() {
  local token=""
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

latest_remote_tag_from_github() {
  local api_url="https://api.github.com/repos/${APP_GITHUB_REPO}/tags?per_page=100"
  local response=""
  local -a curl_args=(curl -fsSL)
  local header

  while IFS= read -r header; do
    [[ -n "$header" ]] && curl_args+=(-H "$header")
  done < <(github_api_headers)

  if ! response="$("${curl_args[@]}" "$api_url" 2>/dev/null)"; then
    return 1
  fi

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
    return
  fi

  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$archive_file" -C "$destination_dir"
    return
  fi

  echo "ZIP extraction requires unzip or bsdtar."
  return 1
}

perform_archive_update() {
  local remote_tag="$1"
  local current_version="$2"
  local confirmation=""
  local archive_file=""
  local extract_dir=""
  local source_root=""
  local helper_script=""

  echo "Current Version: ${current_version}"
  echo "Latest Available Tag: ${remote_tag}"
  echo
  echo "An update is available for this ZIP/manual installation."
  read -r -p "Type UPDATE to download and install ${remote_tag}, or CANCEL to return to the startup menu: " confirmation

  if [[ "$confirmation" != "UPDATE" ]]; then
    echo "Update cancelled."
    return 0
  fi

  archive_file="$(mktemp "/tmp/lss-network-tools-update-XXXXXX.zip")"
  extract_dir="$(mktemp -d "/tmp/lss-network-tools-update-XXXXXX")"

  if ! download_tag_zipball "$remote_tag" "$archive_file"; then
    echo "Failed to download update archive for ${remote_tag}."
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
      print_private_repo_auth_hint "https://github.com/${APP_GITHUB_REPO}.git"
      if prompt_for_github_token && download_tag_zipball "$remote_tag" "$archive_file"; then
        :
      else
        rm -f "$archive_file"
        rm -rf "$extract_dir"
        return 1
      fi
    else
      rm -f "$archive_file"
      rm -rf "$extract_dir"
      return 1
    fi
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

  helper_script="$(mktemp "/tmp/lss-network-tools-apply-update-XXXXXX.sh")"
  cat > "$helper_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SOURCE_ROOT="$source_root"
DEST_DIR="$SCRIPT_DIR"
ARCHIVE_FILE="$archive_file"
EXTRACT_DIR="$extract_dir"
HELPER_SCRIPT="$helper_script"

cd "\$DEST_DIR"
find "\$DEST_DIR" -mindepth 1 -maxdepth 1 \\
  ! -name 'output' \\
  ! -name '.git' \\
  ! -name '.gitignore' \\
  -exec rm -rf {} +
cp -R "\$SOURCE_ROOT"/. "\$DEST_DIR"/
chmod +x "\$DEST_DIR"/*.sh 2>/dev/null || true
rm -f "\$ARCHIVE_FILE"
rm -rf "\$EXTRACT_DIR"
rm -f "\$HELPER_SCRIPT"
echo
echo "Update applied successfully."
echo "Installed Version: $remote_tag"
EOF
  chmod +x "$helper_script"

  echo
  echo "The current session will now hand over to the updater and replace this installation in place."
  exec bash "$helper_script"
}

print_private_repo_auth_hint() {
  local remote_url="$1"

  echo "Authentication may be required to access the remote repository."
  if [[ "$remote_url" == git@* || "$remote_url" == ssh://* ]]; then
    echo "This repository appears to use SSH."
    echo "Make sure the machine has an SSH key configured for your Git provider."
  else
    echo "This repository appears to use HTTPS."
    echo "For private repositories, use your normal Git credential flow or consider switching origin to SSH for smoother updates."
  fi
}

check_for_updates() {
  local current_branch=""
  local current_commit=""
  local local_tag=""
  local remote_tag=""
  local dirty_worktree=false
  local confirmation=""
  local run_installer=""
  local remote_url=""
  local archive_mode=false

  echo
  echo "Check For Updates"
  echo "================="
  echo

  if ! command -v git >/dev/null 2>&1; then
    archive_mode=true
  fi

  if [[ "$archive_mode" == "false" ]] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    archive_mode=true
  fi

  if [[ "$archive_mode" == "false" ]] && ! git remote get-url origin >/dev/null 2>&1; then
    archive_mode=true
  fi

  if [[ "$archive_mode" == "true" ]]; then
    echo "Installation Mode: ZIP/manual copy"
    echo "Current Version: $APP_VERSION"
    echo
    echo "Checking remote tags..."
    remote_tag="$(latest_remote_tag_from_github || true)"
    if [[ -z "$remote_tag" ]]; then
      echo "Unable to read remote tags for ${APP_GITHUB_REPO}."
      print_private_repo_auth_hint "https://github.com/${APP_GITHUB_REPO}.git"
      if prompt_for_github_token; then
        remote_tag="$(latest_remote_tag_from_github || true)"
      fi
    fi
    if [[ -z "$remote_tag" ]]; then
      return 1
    fi
    if [[ "$remote_tag" == "$APP_VERSION" ]]; then
      echo "This installation is already on the latest tagged version."
      return 0
    fi
    perform_archive_update "$remote_tag" "$APP_VERSION"
    return $?
  fi

  remote_url="$(remote_origin_url)"
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  current_commit="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  local_tag="$(latest_local_tag)"

  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    dirty_worktree=true
  fi

  echo "Current Branch: ${current_branch}"
  echo "Current Commit: ${current_commit}"
  if [[ -n "$local_tag" ]]; then
    echo "Current Version Tag: $local_tag"
  else
    echo "Current Version Tag: none"
  fi
  echo
  echo "Checking remote tags..."

  remote_tag="$(latest_remote_tag)"
  if [[ -z "$remote_tag" ]]; then
    if ! git ls-remote --tags --refs origin >/dev/null 2>&1; then
      echo "Unable to read remote tags from origin."
      print_private_repo_auth_hint "$remote_url"
      return 1
    fi
    echo "No remote tags were found on origin."
    echo "Publish your first tag after committing this feature, then this update check will become meaningful."
    return 0
  fi

  echo "Latest Available Tag: $remote_tag"

  if [[ "$dirty_worktree" == "true" ]]; then
    echo
    echo "Warning: Local uncommitted changes were detected."
    echo "Updating is not recommended until your working tree is clean."
    return 0
  fi

  if [[ -n "$local_tag" && "$local_tag" == "$remote_tag" ]]; then
    echo
    echo "This repository is already on the latest tagged version."
    return 0
  fi

  echo
  echo "An update is available."
  read -r -p "Type UPDATE to fetch tags and pull the latest changes from origin/$current_branch, or CANCEL to return to the startup menu: " confirmation

  if [[ "$confirmation" != "UPDATE" ]]; then
    echo "Update cancelled."
    return 0
  fi

  if ! git fetch --tags origin; then
    echo "Failed to fetch tags from origin."
    print_private_repo_auth_hint "$remote_url"
    return 1
  fi

  if ! git pull --ff-only origin "$current_branch"; then
    echo "Failed to pull the latest changes from origin/$current_branch."
    print_private_repo_auth_hint "$remote_url"
    return 1
  fi

  echo
  echo "Repository updated successfully."
  echo "Current Version Tag: $(latest_local_tag)"
  echo
  read -r -p "Would you like to run install.sh now to refresh dependencies if needed? (y/N): " run_installer
  if [[ "$run_installer" =~ ^[Yy]$ ]]; then
    if [[ -x "./install.sh" ]]; then
      ./install.sh
    else
      bash ./install.sh
    fi
  fi
}

startup_menu() {
  local choice=""
  local yellow='\033[1;33m'
  local reset='\033[0m'

  while true; do
    clear_screen_if_supported
    printf "${yellow}LSS Network Tools${reset}\n"
    printf "${yellow}=================${reset}\n"
    echo
    echo "1) Run LSS Network Tools"
    echo "2) Build LSS Network Tools Report From Previous Run"
    echo "3) Delete All Previous Runs"
    echo "4) Check For Updates"
    echo "5) Exit"
    echo

    read -r -p "Choose option: " choice

    case "$choice" in
      1) return 0 ;;
      2)
        clear_screen_if_supported
        build_report_from_previous_run
        echo
        read -r -p "Press Enter to return to the startup menu..." _
        ;;
      3)
        clear_screen_if_supported
        delete_all_previous_runs
        echo
        read -r -p "Press Enter to return to the startup menu..." _
        ;;
      4)
        clear_screen_if_supported
        check_for_updates
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

  for file in \
    "$(task_output_path 1 2>/dev/null || true)" \
    "$(task_output_path 2 2>/dev/null || true)" \
    "$(task_output_path 3 2>/dev/null || true)" \
    "$(task_output_path 4 2>/dev/null || true)" \
    "$(task_output_path 5 2>/dev/null || true)" \
    "$(task_output_path 6 2>/dev/null || true)" \
    "$(task_output_path 7 2>/dev/null || true)" \
    "$(task_output_path 8 2>/dev/null || true)" \
    "$(task_output_path 9 2>/dev/null || true)"; do
    [[ -z "$file" ]] && continue
    if ! json_file_usable "$file"; then
      continue
    fi
    status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
    if [[ "$status" == "failed" ]]; then
      title="$(basename "$file") failed"
      detail="$(jq -r '.error.message // "The scan reported a failure."' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "warning" "$title" "$detail" "$(basename "$file")")"
    elif [[ "$status" == "completed_with_warnings" ]]; then
      title="$(basename "$file") completed with warnings"
      detail="$(jq -r '(.warnings // []) | if length > 0 then join(" ") else "The scan completed with warnings." end' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "info" "$title" "$detail" "$(basename "$file")")"
    fi
  done

  file="$(task_output_path 3 2>/dev/null || true)"
  if json_file_usable "$file"; then
    open_port_count="$(jq -r '(.open_ports // []) | length' "$file" 2>/dev/null)"
    if [[ "$open_port_count" =~ ^[0-9]+$ ]] && (( open_port_count >= 8 )); then
      gateway="$(jq -r '.gateway_ip // "unknown"' "$file" 2>/dev/null)"
      open_ports_label="$(jq -r '(.open_ports // []) | map(tostring) | join(", ")' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "high" "Gateway exposes many open ports" "Gateway $gateway has $open_port_count open TCP ports: $open_ports_label." "gateway-scan.json")"
    elif [[ "$open_port_count" =~ ^[0-9]+$ ]] && (( open_port_count >= 5 )); then
      gateway="$(jq -r '.gateway_ip // "unknown"' "$file" 2>/dev/null)"
      open_ports_label="$(jq -r '(.open_ports // []) | map(tostring) | join(", ")' "$file" 2>/dev/null)"
      findings_json="$(append_finding_record "$findings_json" "warning" "Gateway exposes multiple open ports" "Gateway $gateway has $open_port_count open TCP ports: $open_ports_label." "gateway-scan.json")"
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

  file="$(task_output_path 9 2>/dev/null || true)"
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

  file="$(task_output_path 5 2>/dev/null || true)"
  if json_file_usable "$file"; then
    count="$(jq -r '(.servers // []) | length' "$file" 2>/dev/null)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      findings_json="$(append_finding_record "$findings_json" "info" "DNS services were detected on the local network" "The DNS scan identified $count host(s) with DNS-related ports open." "dns-scan.json")"
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
  done < <(task_json_files 14)

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

  if jq -e '.findings[]? | select(.source == "ldap-ad-scan.json")' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Validate directory expectations" "If Active Directory services are expected on this site, confirm the selected subnet and check whether LDAP, Kerberos, or Global Catalog ports are being filtered or hosted elsewhere." "ldap-ad-scan.json")"
  fi

  if jq -e '.findings[]? | select(.source == "print-server-scan.json")' "$findings_file" >/dev/null 2>&1; then
    remediation_json="$(append_finding_record "$remediation_json" "advice" "Validate print infrastructure expectations" "If printers or print servers are expected, verify that they are on the same subnet and that ports 515, 631, or 9100 are not filtered." "print-server-scan.json")"
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
      run_directory: $run_directory,
      selected_interface: $selected_interface,
      report_file: $report_file,
      debug_file: $debug_file,
      tasks: $tasks,
      artifacts: $artifacts
    }' > "$manifest_file"

  validate_json_file "$manifest_file"
}

finalize_run() {
  if [[ -n "$RUN_OUTPUT_DIR" ]] && [[ -n "$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null)" ]]; then
    build_report_for_current_run || true
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
  local yellow='[1;33m'
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

  if [[ "$OS" == "linux" ]] && ! command -v ifconfig >/dev/null 2>&1; then
    echo
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

    echo
    printf "${yellow}Select Network Interface${reset}\n"
    printf "${yellow}========================${reset}\n"
    echo
    if [[ "${#ipv4_interfaces[@]}" -gt 0 ]]; then
      echo "Active Interfaces:"
    else
      printf "${red}WARNING: No IPv4 address was detected on any interface.${reset}\n"
      echo "Possible causes include a disconnected cable, Wi-Fi not being connected, no DHCP offer being received, or an interface that is not configured."
      echo
      echo "Other Interfaces:"
    fi
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
        echo "Other Interfaces:"
      fi

      if [[ "$has_ipv4" == "true" && "$OUTPUT_IS_TTY" -eq 1 ]]; then
        printf "%s) ${green}%s%s${reset}\n" "$idx" "$display_label" "$status_suffix"
      else
        echo "$idx) $display_label$status_suffix"
      fi
      idx=$((idx + 1))
    done
    echo "0) Exit"
    echo

    read -r -p "Enter selection: " choice

    if [[ "$choice" == "0" ]]; then
      exit 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ordered_interfaces[@]} )); then
      SELECTED_INTERFACE="${ordered_interfaces[$((choice - 1))]}"
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
      mac_address: (if $mac_address == "" then null else $mac_address end)
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

monitor_speedtest_progress() {
  local pid="$1"
  local output_file="$2"
  local timeout_seconds="$3"
  local green='\033[0;32m'
  local reset='\033[0m'
  local start_time elapsed
  local public_ip=""
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
      printf "${green}Done.${reset}\n"
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
    [[ -n "$server_name" ]] && echo "Connected to server: $server_name"
    [[ -n "$ping_latency" ]] && echo "Ping: $ping_latency ms"
  fi

  if [[ "$download_spinner_active" -eq 1 && -n "$download_speed" ]]; then
    echo "Download Speed: ${download_speed} Mbps"
  fi

  if [[ "$upload_spinner_active" -eq 1 && -n "$upload_speed" ]]; then
    echo "Upload Speed: ${upload_speed} Mbps"
    printf "${green}Done.${reset}\n"
  fi

  return 0
}

render_speed_test_report() {
  local file="$1"
  local report_file="$2"
  local server location download upload public_ip ping
  local status success error_code error_message warning_count

  status="$(jq -r '.status // "success"' "$file" 2>/dev/null)"
  success="$(jq -r '.success // true' "$file" 2>/dev/null)"
  error_code="$(jq -r '.error.code // empty' "$file" 2>/dev/null)"
  error_message="$(jq -r '.error.message // empty' "$file" 2>/dev/null)"
  warning_count="$(jq -r '(.warnings // []) | length' "$file" 2>/dev/null)"

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
    echo "Status: ${status:-unknown}"
    echo "Success: ${success:-false}"
    if [[ -n "$error_code" ]]; then
      echo "Error Code: $error_code"
    fi
    if [[ -n "$error_message" ]]; then
      echo "Error Message: $error_message"
    fi
    if [[ -n "$warning_count" && "$warning_count" != "0" ]]; then
      echo "Warnings: $warning_count"
    fi
    echo "Public IP: ${public_ip:-unknown}"
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
  local server_name="$6"
  local server_location="$7"
  local ping_latency="$8"
  local download_speed="$9"
  local upload_speed="${10}"
  shift 10
  local warnings=("$@")
  local warnings_json

  warnings_json="$(json_string_array_from_array warnings)"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --arg public_ip "$public_ip" \
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
          test_server: $server_name,
          location: $location,
          ping_ms: (if $ping_latency == "" or $ping_latency == "unavailable" then null else ($ping_latency | tonumber) end),
          download_mbps: (if $download_speed == "" or $download_speed == "unavailable" then null else ($download_speed | tonumber) end),
          upload_mbps: (if $upload_speed == "" or $upload_speed == "unavailable" then null else ($upload_speed | tonumber) end),
          timestamp: ""
        }
      ]
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
    ports=("${rest[@]}")
  fi

  warnings_json="$(json_string_array_from_array warnings)"

  jq -n \
    --arg status "$status" \
    --argjson success "$success" \
    --arg error_code "$error_code" \
    --arg error_message "$error_message" \
    --arg gateway_ip "$gateway_ip" \
    --argjson open_ports "$(ports_to_json_array "${ports[@]}")" \
    --argjson warnings "$warnings_json" \
    '{
      status: $status,
      success: $success,
      error: (if $error_code == "" and $error_message == "" then null else {code: $error_code, message: $error_message} end),
      warnings: $warnings,
      gateway_ip: (if $gateway_ip == "" then null else $gateway_ip end),
      open_ports: $open_ports
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
  local public_ip server_name server_location ping_latency download_speed upload_speed
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
      write_speed_test_json "failed" "false" "dependency_missing_speedtest_cli" "speedtest-cli is not installed." "unknown" "unknown" "" "unavailable" "unavailable" "unavailable"
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
    write_speed_test_json "failed" "false" "tempfile_creation_failed" "Unable to create a temporary file for the speed test." "unknown" "unknown" "" "unavailable" "unavailable" "unavailable"
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
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "unknown" "unknown" "" "unavailable" "unavailable" "unavailable"
    echo "Speedtest failed. Raw output:"
    echo "$result"
    return 1
  fi

  if ! printf '%s\n' "$result" | grep -q '^Download:'; then
    status="failed"
    success="false"
    error_code="speedtest_output_incomplete"
    error_message="speedtest-cli finished, but the expected download result was not present in the output."
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "unknown" "unknown" "" "unavailable" "unavailable" "unavailable"
    echo "Speedtest failed. Raw output:"
    echo "$result"
    return 1
  fi

  public_ip="$(printf '%s\n' "$result" | sed -nE 's/^Testing from .* \(([0-9.]+)\)\.\.\./\1/p' | tail -n 1)"
  raw_server_name="$(printf '%s\n' "$result" | sed -nE 's/^Hosted by (.*): ([0-9]+([.][0-9]+)?) ms$/\1/p' | tail -n 1 | sed 's/ \[[^]]*\]$//')"
  raw_server_location=""
  ping_latency="$(printf '%s\n' "$result" | sed -nE 's/^Hosted by (.*): ([0-9]+([.][0-9]+)?) ms$/\2/p' | tail -n 1)"
  download_speed="$(printf '%s\n' "$result" | sed -nE 's/^Download:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' | tail -n 1)"
  upload_speed="$(printf '%s\n' "$result" | sed -nE 's/^Upload:[[:space:]]+([0-9]+([.][0-9]+)?) Mbit\/s$/\1/p' | tail -n 1)"

  [[ -z "$download_speed" ]] && download_speed="unavailable"
  [[ -z "$upload_speed" ]] && upload_speed="unavailable"
  [[ -z "$public_ip" ]] && public_ip="unknown"
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
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "$public_ip" "$raw_server_name" "$raw_server_location" "$ping_latency" "$download_speed" "$upload_speed" "${warnings[@]}"
  else
    write_speed_test_json "$status" "$success" "$error_code" "$error_message" "$public_ip" "$raw_server_name" "$raw_server_location" "$ping_latency" "$download_speed" "$upload_speed"
  fi
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
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" "$gateway_ip" "${ports[@]}" "__WARNINGS__" "${warnings[@]}"
  else
    write_gateway_scan_json "$status" "$success" "$error_code" "$error_message" "$gateway_ip" "${ports[@]}"
  fi
  echo "Saved JSON: $(task_output_path 3)"
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
  echo "Stage 1: Scanning all open ports on target (this may take up to 1 minute)..."

  scan_file="$(mktemp)"
  entry_index="$(next_multi_entry_index 10)"
  raw_file="$(multi_entry_raw_prefix_for_index 10 "$entry_index")-nmap.grep"
  json_file="$(multi_entry_output_path_for_index 10 "$entry_index")"
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
  nmap -p- --open -T4 "$target_ip" -oG - > "$scan_file" 2>/dev/null &
  local scan_pid=$!
  monitor_nmap_progress "$scan_pid" "$scan_file" 120 "ports" "Open Ports:" "Custom target port scan failed for $target_ip." || {
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
    --argjson open_ports "$(ports_to_json_array "${ports[@]}")" \
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
  echo "Saved JSON: $json_file"
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
    entry_index="$(next_multi_entry_index 14)"
    json_file="$(multi_entry_output_path_for_index 14 "$entry_index")"
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

  entry_index="$(next_multi_entry_index 14)"
  raw_prefix="$(multi_entry_raw_prefix_for_index 14 "$entry_index")"

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

  json_file="$(multi_entry_output_path_for_index 14 "$entry_index")"
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
  echo "Saved JSON: $json_file"

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

  entry_index="$(next_multi_entry_index 13)"
  raw_prefix="$(multi_entry_raw_prefix_for_index 13 "$entry_index")"
  discovery_file="$(mktemp)"
  json_file="$(multi_entry_output_path_for_index 13 "$entry_index")"
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
  echo "Saved JSON: $json_file"

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
  else
    raw_prefix="$(task_raw_prefix "$task_id")"
  fi

  baseline_file="$(mktemp)"
  jitter_file="$(mktemp)"
  large_file="$(mktemp)"
  ramp_sizes=(64 256 512 1024 1400)
  sustained_file="$(mktemp)"
  recovery_file="$(mktemp)"
  if [[ -z "$baseline_file" || -z "$jitter_file" || -z "$large_file" || -z "$sustained_file" || -z "$recovery_file" ]]; then
    echo "Error: Unable to create temporary files for the stress test."
    if task_supports_multiple_entries "$task_id"; then
      json_file="$(multi_entry_output_path_for_index "$task_id" "$(next_multi_entry_index "$task_id")")"
    else
      json_file="$(task_output_path "$task_id")"
    fi
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

  echo "Stage 3: Jitter test (200 pings @ 0.05s interval)..."
  if ! run_ping_stage "$jitter_file" ping -i 0.05 -c 200 "$target_ip"; then
    jitter_status="failed"
    stage_failure=true
    echo "Warning: jitter test failed. Continuing with remaining stages."
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

  for idx in "${!ramp_sizes[@]}"; do
    if ! run_ping_stage "${ramping_files[$idx]}" ping -s "${ramp_sizes[$idx]}" -c 20 "$target_ip"; then
      ramping_status="partial"
      stage_failure=true
      echo "Warning: ramping test failed for packet size ${ramp_sizes[$idx]}. Continuing with remaining stages."
    fi
  done

  echo "Stage 6: Sustained load test (300 pings @ 0.02s interval)..."
  if ! run_ping_stage "$sustained_file" ping -i 0.02 -c 300 "$target_ip"; then
    sustained_status="failed"
    stage_failure=true
    echo "Warning: sustained load test failed. Continuing with remaining stages."
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

  if task_supports_multiple_entries "$task_id"; then
    json_file="$(multi_entry_output_path_for_index "$task_id" "$entry_index")"
  else
    json_file="$(task_output_path "$task_id")"
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
        }
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
  echo "Saved JSON: $json_file"
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
    "11" \
    "Function 11" \
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
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: "gateway_stress_test", gateway: null, hostname: "unknown", interface: null}' > "$(task_output_path 9)"
    validate_json_file "$(task_output_path 9)"
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
      '{status: $status, success: $success, error: {code: $error_code, message: $error_message}, warnings: $warnings, function: "gateway_stress_test", gateway: null, hostname: "unknown", interface: $interface}' > "$(task_output_path 9)"
    validate_json_file "$(task_output_path 9)"
    return 1
  fi

  [[ -z "$iface" || "$iface" == "null" ]] && iface="$SELECTED_INTERFACE"

  run_stress_test_for_target \
    "$gateway" \
    "$iface" \
    "9" \
    "Function 9" \
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
    echo "Saved JSON: $json_file"
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
    echo "Scanning all ports on Server $((idx + 1)) (this may take up to 1 minute)..."

    dhcp_scan_file="$(mktemp)"
    if [[ -z "$dhcp_scan_file" || ! -f "$dhcp_scan_file" ]]; then
      write_dhcp_failure_json "tempfile_creation_failed" "Unable to create a temporary file for DHCP server port scanning." "$discovery_attempts"
      return 1
    fi
    nmap -p- --open "$server" -oG - > "$dhcp_scan_file" 2>/dev/null &
    local dhcp_scan_pid=$!
    monitor_nmap_progress "$dhcp_scan_pid" "$dhcp_scan_file" 120 "ports" "Open Ports:" "DHCP server port scan failed for $server." || {
      rm -f "$dhcp_scan_file"
      write_dhcp_failure_json "dhcp_server_port_scan_failed" "The port scan for a discovered DHCP responder did not complete successfully." "$discovery_attempts"
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
    if [[ "${#open_ports[@]}" -eq 0 ]]; then
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

  echo "Saved JSON: $json_file"
  validate_json_file "$json_file"
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
    echo "Success: ${success:-false}"
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

  {
    echo "Status: ${status:-unknown}"
    echo "Success: ${success:-false}"
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
    echo "Success: ${success:-false}"
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
    echo "Success: ${success:-false}"
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
    echo "Success: ${success:-false}"
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
    echo "Success: ${success:-false}"
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
    echo "Success: ${success:-false}"
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
    echo "Success: ${success:-false}"
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

  jq -r '.servers[]? | "- DHCP Responder \(.ip) | Unique Offers: \(.offers_observed // 0) | Raw Offers: \(.raw_offers_observed // .offers_observed // 0) | Classification: \(.classification // "unknown") | Suspected Rogue: \(.suspected_rogue // false) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end)"' "$file" >> "$report_file"

  jq -r 'if (.suspected_rogue_servers // []) | length > 0 then "Suspected Rogue Responders: \((.suspected_rogue_servers // []) | join(", "))" else empty end' "$file" >> "$report_file"
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
    echo "Success: ${success:-false}"
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

  jq -r --arg lbl "$label" '.servers[]? | "- \($lbl) Host \(.ip) | Open Ports: \((.open_ports // []) | if length > 0 then map(tostring) | join(", ") else "none found" end) | Services: \((.detected_services // []) | if length > 0 then join(", ") else "unknown" end)"' "$file" >> "$report_file"
}


get_task_ids() {
  awk -F'|' 'NF {print $1}' <<< "$TASKS_DATA" | paste -sd' ' -
}

get_audit_task_ids() {
  echo "1 2 3 4 5 6 7 8 9"
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
    5) echo "Scans the local subnet for hosts exposing DNS-related ports." ;;
    6) echo "Scans the local subnet for LDAP and Active Directory related services." ;;
    7) echo "Scans the local subnet for SMB, NFS, and related file-sharing services." ;;
    8) echo "Scans the local subnet for printer and print-server related ports." ;;
    9) echo "Runs a high-impact latency and packet-loss stress profile against the detected local gateway." ;;
    10) echo "Runs a full TCP port scan against a manually specified target IP." ;;
    11) echo "Runs a high-impact latency and packet-loss stress profile against a manually specified target IP." ;;
    13) echo "Combines MAC, vendor, hostname, and service fingerprint data to infer the identity of a target host." ;;
    14) echo "Tests whether a target IP is operating as a DNS resolver and records its query behavior." ;;
    000) echo "Runs the full core audit across functions 1 to 9." ;;
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
    5) detect_dns_servers ;;
    6) detect_ldap_servers ;;
    7) detect_smb_nfs_servers ;;
    8) detect_print_servers ;;
    9) gateway_stress_test ;;
    10) custom_target_port_scan ;;
    11) custom_target_stress_test ;;
    13) custom_target_identity_scan ;;
    14) custom_target_dns_assessment ;;
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

  read -r -a task_ids <<< "$(get_audit_task_ids)"

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
clear_screen_if_supported
check_tools
mkdir -p "$OUTPUT_DIR"
warn_if_not_root
startup_menu
initialize_debug_logging
select_interface
initialize_run_context
trap finalize_run EXIT
main_menu
