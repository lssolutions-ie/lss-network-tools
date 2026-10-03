# Synthetic task fixtures

Hand-written JSON files for the task shapes that no real anonymised run contains
(Tasks 13–20, plus the Task 10 `skipped` and Task 14 failure shapes). Each file
mirrors a specific `jq -n` writer in `lss-network-tools.sh` (v1.2.248) key for
key, in the order jq emits them. Addresses are private (`10.x`, `192.168.x`) or
RFC 5737 documentation ranges (`203.0.113.x`, used where the script would record a
*public* address: the skipped public gateway and the `example.com` answers);
MACs use real OUIs (Ubiquiti blocks from the script's built-in list for UniFi
devices) with arbitrary device parts; hostnames are `*.lan` PTR names or the
script's `"unknown"` sentinel.

File names are `task-NN-<case>.json`; `SpecialistPayloadTests` derives the task
from `NN` and decodes every file in this directory.

## Task 10 / 14 — stress tests (`run_stress_test_for_target`, `gateway_stress_test`)

| File | Writer | Notes |
|---|---|---|
| `task-10-skipped.json` | `gateway_stress_test()` — `is_rfc1918_ip` false branch | `status: "skipped"`, `success: false`, `skip_reason`/`skip_message`, `error: null`, `function`, `gateway`, `hostname: "unknown"`, `interface`. Current code writes this to `gateway-stress-test-device-N.json` (`next_multi_entry_output_path 10`), no longer to the non-indexed name research 03 §10 describes. |
| `task-14-target-unreachable.json` | `run_stress_test_for_target()` — baseline never answered | Minimal failure shape: envelope + `function`, `target_ip`, `hostname`, `interface`. Task 14 uses the `target_ip` key where Task 10 uses `gateway`. |

## Task 13 — Custom Target Port Scan (`custom_target_port_scan`)

| File | Writer branch | Notes |
|---|---|---|
| `task-13-success.json` | final `jq -n` | `open_ports` as numbers, `scan_type: "custom_target_port_scan"`. |
| `task-13-no-open-ports.json` | final `jq -n`, `ports` empty | `completed_with_warnings`; warnings from `collect_custom_target_warnings` (outside-subnet) plus the "no open TCP ports" warning, `open_ports: []`. |
| `task-13-failed.json` | `monitor_nmap_progress` failure | `custom_target_port_scan_failed`; every key kept, `open_ports: []`. |

## Task 15 — Custom Target Identity Scan (`custom_target_identity_scan`)

| File | Writer branch | Notes |
|---|---|---|
| `task-15-success.json` | final `jq -n` | Printer: uppercase `mac_address`, `vendor_source: "nmap"`, `lookup_method: "nmap"`, `device_type_hint: "printer"` (whole-word `ipp` token), `confidence: "medium"`, `identity_summary` from `build_identity_summary`, `services[].port` as `"80/tcp"` strings, `version: ""` where nmap printed none. |
| `task-15-gateway-warning.json` | final `jq -n` | Gateway target: `lookup_method: "arp-cache"`, `vendor_source: "macvendors-api"`, `firewall-or-router` / `high` / "Likely OPNsense firewall"; `completed_with_warnings` from the gateway warning. |
| `task-15-host-down.json` | final `jq -n` | `mac_address: null`, `vendor: "unknown"`, `host_state: "down"`, `services: []`, all three content warnings. |
| `task-15-discovery-failed.json` | `wait_for_pid` failure after `nmap -sn` | `custom_identity_discovery_failed`; envelope + `target_ip` + `hostname` only. |

## Task 16 — Custom Target DNS Assessment (`custom_target_dns_assessment`)

| File | Writer branch | Notes |
|---|---|---|
| `task-16-success.json` | final `jq -n`, `query_tool: "dig"` | All three queries `NOERROR` with answers, `version_bind_response` and `software_hint` set. |
| `task-16-not-recursive.json` | final `jq -n` | Gateway refusing recursion: `REFUSED`, empty answers, both booleans false, `version_bind_response: null`, `software_hint: "unknown"`, `completed_with_warnings`. |
| `task-16-nslookup.json` | final `jq -n`, `query_tool: "nslookup"` | `tcp_query.status: "unknown"`, every `answers` empty (the nslookup path parses none), limited-assessment warning. |
| `task-16-tool-missing.json` | early exit, neither dig nor nslookup | `dns_query_tool_missing`; envelope + `target_ip` + `hostname` only. |

Note: Task 16 only sets `completed_with_warnings` for the "not a working resolver"
and nslookup cases; a success file can carry `collect_custom_target_warnings`
entries while still reporting `status: "success"` (research 03, hazard 6).

## Task 17 — Wireless Site Survey (`wireless_site_survey`, `run_wireless_scan`)

| File | Scanner shape | Notes |
|---|---|---|
| `task-17-corewlan.json` | `LSS-WiFiScan.app` (CoreWLAN) | Three rooms. Networks carry all nine keys, `phy_mode`/`security` = `"--"`, one `(hidden)` SSID, one network with `rssi_dbm`/`noise_floor_dbm` = `null` (CoreWLAN reports 0 → `NSNull`). `ap_label: null` when no AP. |
| `task-17-airport-legacy.json` | legacy `airport -s` | Five keys only (`ssid`, `bssid`, `rssi_dbm`, `channel`, `security`); airport-style channels `"36,+1"`, `"149,80"` and security `WPA2(PSK/AES/AES)` / `NONE`. |
| `task-17-ended-early.json` | `system_profiler SPAirPortDataType` | `bssid: "--"`, real `phy_mode`/`security`; survey ended with `00` → `completed_with_warnings`. |
| `task-17-linux-iw.json` | Linux `iw dev … scan` | `interface: "wlan0"`, `rssi_dbm: 0` default when no signal line, `ssid: ""` when no SSID line, `channel_width` as `"1 (80 MHz)"`, `noise_floor_dbm: null`, `band`/`phy_mode` empty. |
| `task-17-no-wireless-interface.json` | no wireless interface | `NO_WIRELESS_INTERFACE`, `interface: null`, `rooms_scanned: 0`, `survey: []`. |

## Task 18 — Scan For UniFi Devices (`unifi_device_scan`, `unifi_device_entry`)

| File | Writer branch | Notes |
|---|---|---|
| `task-18-success.json` | final `jq -n` | `devices_found` counts confirmed **and** probable devices; `model` only when a TLV reply named it; `confidence: "probable"` only for the Dropbear-banner host (never adopted by Task 19); `false_positives[]` rows have only `mac`/`ip`, `mac` may be `"unknown"`. |
| `task-18-none-found.json` | final `jq -n` | Empty `devices` and `false_positives`, `devices_found: 0`. |
| `task-18-insufficient-privileges.json` | `EUID -ne 0` exit | Includes `false_positives: []`. |
| `task-18-no-subnet.json` | subnet empty | `subnet: ""`, **no** `false_positives` key, no `broadcast`. The `missing_dependency` (nmap) file has the same shape. |

## Task 19 — UniFi Adoption (`unifi_adoption`)

| File | Writer branch | Notes |
|---|---|---|
| `task-19-success.json` | final `jq -n` | No `warnings`/`error` keys. `result` is `"adopted"` or `"failed: <reason>"` (sshpass exit 5 → authentication, ssh 255 → could not connect). |
| `task-19-all-failed.json` | final `jq -n` | `status: "success"` although `devices_adopted: 0` (research 03 §19). Port 443 → `https` inform URL. |
| `task-19-missing-dependency.json` | sshpass install failed | `error.code: "missing_dependency"`, no `warnings` key, `controller`/`inform_url` absent. |

## Task 20 — Find Device by MAC (`find_device_by_mac`)

| File | Writer branch | Notes |
|---|---|---|
| `task-20-found.json` | match in the ARP table | `mac_queried` lowercase, `ip_found` set. No `warnings`/`error` keys. |
| `task-20-not-found.json` | five passes, no match | `status: "success"`, `ip_found: null`. |
| `task-20-insufficient-privileges.json` | `EUID -ne 0` exit | `error.code: "insufficient_privileges"`, `ip_found: null`, subnet still recorded. |
| `task-20-no-subnet.json` | subnet empty | `error.code: "no_subnet"`, `subnet: ""`. |
