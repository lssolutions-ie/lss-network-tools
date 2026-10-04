# Research: JSON output schemas (ground truth for Swift Codable)

Derived from the writers in `lss-network-tools.sh` v1.2.246 and checked against the six real runs in `/usr/local/share/lss-network-tools/output/` (tasks 1–12 only; no real files exist for tasks 13–20; the three `gateway-stress-test-device-1.json` files are mode 0600 root-only and could not be read as the user).

Real runs: `stephen-murphy-saint-kevins-nbs-finglas-27-03-2026` (oldest), `olive-crowe-james-street-cbs-23-03-2026-native-lan`, `colin-coffey-floor-design-ltd.-31-03-2026`, `stephen-murphy-saint-kevins-nbs-02-04-2026`, `paul-clarke-saint-mary-secondary-school-11-06-2026-staff-wi-fi`, `…-student-wi-fi` (newest, have PDFs).

Notation: `T?` = may be `null`; `[opt]` = key may be missing.

## 0. Common envelope

```ts
status:   "success" | "completed_with_warnings" | "failed" | "skipped"   // "skipped": tasks 3 and 10 only
success:  boolean        // true for success/completed_with_warnings; false for failed AND skipped
error:    { code: string, message: string } | null     // [opt] missing in tasks 19/20
warnings: string[]       // [opt] missing in tasks 19/20 and some failure shapes
```
`skipped` adds `skip_reason: "gateway_public_ip"`, `skip_message: string`. `status` and `warnings` do not always agree (see hazards). Multi-entry tasks 10, 13, 14, 15, 16 write `<base>-device-N.json` (N = max existing + 1); sort naturally.

## 1. interface-network-info.json (Task 1)
```ts
{ status, success, error, warnings, interface: string,
  ip_address: string?, subnet: string? /* dotted mask */, network: string? /* CIDR */,
  gateway: string?, mac_address: string?, is_vm: boolean, vm_platform: string? }
```
Errors: `loopback_interface_selected`, `no_ipv4_on_virtual_interface`, `no_ipv4_or_subnet_detected`, `ipv4_address_missing`, `subnet_mask_missing`, `network_range_calculation_failed`. All 6 runs: success, stable shape.

## 2. internet-speed-test.json (Task 2)
```ts
{ status, success, error, warnings, speed_tests_found: number /* 1 or 0 */,
  servers: [ { public_ip: string /* "unknown" sentinel */, isp_name?: string /* [opt] missing pre-June */,
               test_server: string, location: string /* "" */, ping_ms: number?, download_mbps: number?,
               upload_mbps: number?, timestamp: string /* "" */ } ],   // exactly 1 element
  methodology: string }
```
Errors: `dependency_missing_speedtest_cli`, `tempfile_creation_failed`, `speedtest_timeout`, `speedtest_backend_unreachable`, `speedtest_command_failed`, `speedtest_output_incomplete`. Legacy raw speedtest-cli shape (`{client:{ip}, server:{name,location|country}, ping, download, upload}` in bit/s) may exist in very old runs.

## 3. gateway-scan.json (Task 3)
```ts
{ status, success, error, warnings, skip_reason?: "gateway_public_ip", skip_message?: string,
  gateway_ip: string?, open_ports: number[], scan_scope: "All TCP ports (1-65535)" }
```
Skipped file: `success:false`, `error:null`. Errors: `gateway_not_detected`, `tempfile_creation_failed`, `gateway_port_scan_failed`.

## 4. dhcp-scan.json (Task 4)
```ts
{ status, success, error, warnings,
  dhcp_responders_observed: number, discovery_attempts: number /* 5 */, offers_observed: number,
  raw_offers_observed: number, relay_sources_seen: string[], tcpdump_capture_used: boolean,
  rogue_dhcp_suspected: boolean, suspected_rogue_servers: string[], discovery_note: string,
  raw_attempts: [ { attempt: number, output_excerpt: string } ],
  servers: [ { ip: string, open_ports: number[], offers_observed: number, raw_offers_observed: number,
               classification: "gateway"|"dhcp-service-host"|"directory-infrastructure"|"network-infrastructure"|"windows-infrastructure"|"unknown",
               suspected_rogue: boolean } ] }
```
Failure files contain every key with zero counts. Errors: `tempfile_creation_failed`, `dhcp_privilege_required`, `dhcp_discovery_attempt_failed`. Legacy: `dhcp_servers_found`.

## 5. dhcp-response-time.json (Task 5)
```ts
{ status, success, error, warnings, methodology?: string, interface: string?, is_wifi?: boolean,
  probe_count: number, responded_count: number, response_times_ms: (number|null)[],
  min_ms: number?, avg_ms: number?, max_ms: number?, packet_loss_percent: number /* float; int 100 on failure */,
  server_ip: string?,
  subnet_utilization?: { usable_hosts: number?, live_hosts: number?, utilization_percent: number?,
                         high_utilization: boolean, note: string },   // [opt] missing in March/April runs
  indicators: { slow_response: boolean, high_loss: boolean, high_utilization?: boolean } }
```
Errors (uppercase): `NO_INTERFACE`, `PROBE_FAILED`. Current code: `subnet_utilization` always present on success (all nulls + note for subnets larger than /22).

## 6–9. dns-scan.json, ldap-ad-scan.json, smb-nfs-scan.json, print-server-scan.json
```ts
{ status, success, error, warnings, network: string?, scan_ports: string /* CSV, e.g. "88,389,636,3268,3269" */,
  servers: [ { ip: string, open_ports: number[],
               detected_services: string[] /* dns, kerberos, ldap, ldaps, ldap-global-catalog, ldaps-global-catalog, rpcbind, smb-netbios, smb, nfs, printer-lpd, printer-ipp, printer-jetdirect, port-<n> */,
               smb_signing_required?: boolean,                     // Task 8, hosts with 445 only
               resolution_test?: { domain: "google.com", resolved: boolean, response_ms: number?,   // Task 6, current code only
                                   resolved_ips: string[], open_resolver: boolean, rebinding_risk: boolean },
               ptr_hostname?: string?, gateway_ptr?: string? } ] }
```
Errors: `network_range_not_detected`, `tempfile_creation_failed`, `network_port_scan_failed`. No real dns-scan has the enrichment keys; `smb_signing_required` missing entirely in finglas.

## 10 and 14. gateway-stress-test-device-N.json / custom-target-stress-test-device-N.json
```ts
// success | completed_with_warnings
{ status, success: true, error: null, warnings, function: "gateway_stress_test"|"custom_target_stress_test",
  gateway?: string /* Task 10 key */, target_ip?: string /* Task 14 key */,
  hostname: string /* "unknown" */, interface: string, completed_with_warnings: boolean, warning: string?,
  stage_status: { baseline: "ok"|"failed", jitter: "ok"|"failed", large_packet: "ok"|"failed",
                  ramping: "ok"|"partial", sustained: "ok"|"failed", recovery: "ok"|"failed" },
  baseline: { avg_latency_ms: number, max_latency_ms: number, stddev_ms: number },
  jitter_test: { stddev_ms: number, max_latency_ms: number, packet_loss_percent: number },
  large_packet_test: { avg_latency_ms: number, max_latency_ms: number, packet_loss_percent: number },
  ramping_test: [ { packet_size: number /* 64,256,512,1024,1400 */, avg_latency_ms: number, max_latency_ms: number, packet_loss_percent: number } ],
  sustained_test: { avg_latency_ms: number, max_latency_ms: number, packet_loss_percent: number },
  recovery: { avg_latency_ms: number, returned_to_baseline: boolean },
  indicators: { high_jitter: boolean, latency_under_load: boolean, packet_loss: boolean, slow_recovery: boolean },
  methodology: string }
// failed: ONLY {status, success:false, error, warnings:[], function, gateway|target_ip: string|null, hostname, interface: string|null}
// Task 10 skipped (written to NON-indexed gateway-stress-test.json): {status:"skipped", success:false, skip_reason, skip_message, error:null, warnings:[], function, gateway, hostname:"unknown", interface}
```
Errors: `ping_dependency_missing`, `tempfile_creation_failed`, `target_unreachable`, `interface_disconnected`; Task 10 also `interface_info_missing`, `gateway_not_detected` (non-indexed file, `gateway: null`). Unparsed metrics are `0`, never null.

## 11. vlan-trunk-scan.json
```ts
{ status, success, error, warnings, interface: string, tagged_frames_observed: boolean, observed_vlan_ids: number[],
  cdp_neighbours: [ { device_id, platform, port_id: string, native_vlan: number?, vtp_domain: string, duplex: ""|"full"|"half" } ],
  lldp_neighbours: [ { system_name, chassis_id, port_id, system_description: string } ],
  double_tag_probe: { attempted: false, vulnerable: null },
  indicators: { trunk_port_suspected: boolean, cdp_exposed: boolean, multiple_vlans_visible: boolean } }
// NO_INTERFACE failure has ONLY the envelope.
```

## 12. duplicate-ip-scan.json
```ts
{ status, success, error, warnings, interface: string?, network: string?, total_hosts_seen: number,
  duplicate_count: number, duplicates: [ { ip: string, macs: string[], vendors: string[] } ] }
```
Errors: `NO_INTERFACE`, `NO_ARP_SCAN`, `NO_NETWORK`, `ARP_SCAN_NO_RESULTS`. Old runs may show `total_hosts_seen: 0` with success.

## 13. custom-target-port-scan-device-N.json
```ts
{ status, success, error, warnings, target_ip: string, hostname: string, scan_type: "custom_target_port_scan", open_ports: number[] }
```
Errors: `tempfile_creation_failed`, `custom_target_port_scan_failed` (all keys kept, `open_ports: []`).

## 15. custom-target-identity-scan-device-N.json
```ts
{ status, success, error, warnings, target_ip, hostname, mac_address: string? /* uppercase */, vendor: string,
  vendor_source: "nmap"|"macvendors-api"|"unknown", lookup_method: "nmap"|"arp-cache", host_state: "up"|"down"|"unknown",
  device_type_hint: string /* iot-device-or-smart-relay|printer|windows-host|nas-or-file-server|firewall-or-router|network-switch|access-point-or-router|linux-host|camera-or-nvr|network-device|unknown */,
  confidence: "high"|"medium"|"low", identity_summary: string,
  services: [ { port: string /* "22/tcp" */, state: string, service: string, version: string } ] }
// failure: ONLY {status, success, error, warnings:[], target_ip, hostname}
```

## 16. custom-target-dns-assessment-device-N.json
```ts
{ status, success, error, warnings, target_ip, hostname, query_tool: "dig"|"nslookup",
  dns_service_working: boolean, recursion_available: boolean,
  udp_query: { status: string, answers: string[] }, tcp_query: {…}, reverse_ptr_query: {…},
  version_bind_response: string?, software_hint: string /* "unknown" */,
  upstream_destination_inference: "unknown", upstream_visibility_note: string }
// failure (dns_query_tool_missing): ONLY {status, success, error, warnings:[], target_ip, hostname}
```

## 17. wireless-survey.json
```ts
{ status, success, error, warnings, scan_type: "wireless_site_survey", interface: string?, rooms_scanned: number,
  survey: [ { building: string, floor: string, room: string, ap_present: boolean, ap_label: string?,
              timestamp: string /* ISO-8601 UTC */, networks: Network[] } ] }
type Network = { ssid: string /* "(hidden)" */, bssid: string /* "--" */, rssi_dbm: number?, channel: string, security: string,
                 noise_floor_dbm?: number?, band?: string, channel_width?: string, phy_mode?: string }
```
Status `failed` → `NO_WIRELESS_INTERFACE` with `interface: null`; `completed_with_warnings` when ended via `00`. Key sets differ by scanner (CoreWLAN helper: all 9 keys, `phy_mode`/`security` = "--"; system_profiler: `bssid` = "--"; Linux iw: `rssi_dbm` 0 default; legacy airport: 5 keys only).

## 18. unifi-discovery.json
```ts
{ status: "success"|"failed", success, error, warnings: [], interface: string, broadcast?: string, subnet: string,
  devices_found: number /* = devices.length incl. probable */,
  devices: [ { mac: string /* may be "unknown" */, ip: string, model?: string, confidence?: "probable" } ],
  false_positives?: [ { mac: string, ip: string } ] }
```
Errors: `insufficient_privileges`, `no_subnet`, `missing_dependency`. Missing `confidence` = confirmed.

## 19. unifi-adoption.json
```ts
{ status: "success"|"failed", success: boolean, error?: {code:"missing_dependency", message},
  controller?: string, inform_url?: string, interface: string, devices_found: number, devices_adopted: number,
  devices: [ { ip: string, result: "adopted" | string /* "failed: <reason>" */ } ] }
```
No `warnings` key; `status` is "success" even if every adoption failed; several early exits write no file.

## 20. find-device-by-mac.json
```ts
{ status: "success"|"failed", success: boolean, error?: {code,message}, mac_queried: string /* lowercase */,
  ip_found: string?, interface: string, subnet: string }
```
No `warnings`. Errors: `insufficient_privileges`, `no_subnet`. Invalid MAC writes no file.

## findings.json / remediation.json
```ts
{ findings: [ { severity: "info"|"warning"|"high", title: string, detail: string, source: string /* file basename */ } ] }
{ hints:    [ { severity: "advice", title: string, detail: string, source: string /* filename or literal "dns" */ } ] }
```

## manifest.json
```ts
{ generated_at: string /* "dd-mm-YYYY HH:MM" local, not ISO */, client: string, location: string, note: string,
  prepared_by: string, run_directory: string /* basename */, selected_interface: string /* may be "unknown" */,
  report_file: string /* TXT basename */, debug_file: "debug.txt",
  tasks: [ { task_id: number, title: string, json_file: string /* base name */, json_present: boolean,
             json_files: string[] /* actual basenames incl. -device-N */, raw_prefix: string } ],
  artifacts: [ { path: string /* relative */, type: "json"|"text"|"other" } ] }
```
`tasks` has 17 (finglas), 18 (colin) or 20 (current) entries. `artifacts` omits the PDF.

## Report naming
Run dir `{client-slug}-{location-slug}-{dd-mm-yyyy}[-{note-slug}][-{HH-MM}[-N]]` (slugs `[a-z0-9._-]`, dots survive — do not parse the name, use the manifest). TXT `lss-network-tools-report-{client}-{location}-{dd-mm-yyyy}-{HH-MM}.txt` (no note), PDF same base `.pdf`, in the run dir. Rebuilt reports: `lss-network-tools-report-{run-dir-basename}-{HH-MM}.{txt,pdf}` in the export dir (default Desktop) — and the rebuild rewrites `findings.json`/`remediation.json`. Compare: `lss-compare-{dd-mm-yyyy}-{HH-MM}.pdf`.

## Decoding hazards

1. **Stress-test JSONs are mode 0600 root** (mktemp + mv). A user-level GUI cannot read them. (To be fixed on `main`: chmod 644 after mv.)
2. **Task 10 file name is inconsistent**: skipped / `interface_info_missing` / `gateway_not_detected` write non-indexed `gateway-stress-test.json`, which the report, manifest and `task_json_files` never see; `append_findings_summary` reads only the non-indexed name, so stress findings never fire for real results. (To be fixed on `main`.) The GUI should glob both names.
3. Target key differs: `gateway` (10) vs `target_ip` (14).
4. Failure files are minimal (10, 11, 14, 15, 16): every task-specific field must be optional.
5. `error`/`warnings` sometimes missing rather than null (19, 20): `decodeIfPresent` everywhere.
6. `status` and `warnings` disagree (11, 5, 19); treat `status` as an open enum (never throw on unknown).
7. `success` is false when `status` is `skipped`.
8. Version-dependent fields: `isp_name`, `subnet_utilization`, `indicators.high_utilization`, `smb_signing_required`, DNS enrichment, `broadcast`/`false_positives`, legacy task 2/4 shapes.
9. Strings vs numbers: `scan_ports` CSV string; identity `services[].port` `"22/tcp"`; wireless `channel` string; `packet_loss_percent` float or int; decode metrics as `Double`.
10. Nullable numbers: task 5 min/avg/max and array elements; wireless rssi/noise; DNS `response_ms`.
11. Sentinels: `"unknown"`, `"--"`, `""`.
12. Two date formats: manifest local `dd-mm-YYYY HH:MM`; wireless ISO-8601 UTC.
13. Wireless network key sets differ per scanner; everything except `ssid` optional.
14. `findings.json`/`remediation.json` may be newer than task files or absent.
15. Manifest incomplete: 17–20 tasks, `json_file` is base name, PDF omitted, `selected_interface` may be "unknown"; some runs have no manifest → fall back to globbing.
16. A run dir can hold several TXT reports; use `manifest.report_file` or newest.
17. Task 18 `devices_found` includes probable devices.
