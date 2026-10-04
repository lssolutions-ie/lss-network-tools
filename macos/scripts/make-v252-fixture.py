#!/usr/bin/env python3
"""Write the synthetic v1.2.252 run fixture (Tasks 4/5/6 with the new optional fields)."""
import hashlib, json, os
DEST = "/Users/ladislavstojanik/Documents/Github/lss-network-tools/.claude/worktrees/macos-gui/macos/Tests/Fixtures/synthetic-v252/client-synthetic-site-dhcp-04-10-2026"
os.makedirs(DEST, exist_ok=True)

def dump(name, obj):
    path = os.path.join(DEST, name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")
    return path

def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()

excerpt = ("Starting Nmap 7.98 ( https://nmap.org ) at 2026-10-04 13:58 +0100\n"
           "Pre-scan script results:\n| broadcast-dhcp-discover: \n|   Response 1 of 2: \n|     Interface: en0\n"
           "|     IP Offered: 10.20.0.143\n|     DHCP Message Type: DHCPOFFER\n|     Server Identifier: 10.20.0.1\n"
           "|     IP Address Lease Time: 1d00h00m00s\n|     Subnet Mask: 255.255.255.0\n|     Router: 10.20.0.1\n"
           "|     Domain Name Server: 10.20.0.10, 10.20.0.11\n|     Domain Name: lab.lan\n"
           "|   Response 2 of 2: \n|     Interface: en0\n|     IP Offered: 192.168.8.50\n|     DHCP Message Type: DHCPOFFER\n"
           "|     Server Identifier: 10.20.0.77\n|     IP Address Lease Time: 2h00m00s\n|     Subnet Mask: 255.255.255.0\n"
           "|_    Router: 192.168.8.1\nNmap done: 0 IP addresses (0 hosts up) scanned in 10.05 seconds")

dhcp = {
    "status": "completed_with_warnings", "success": True, "error": None,
    "warnings": [
        "Attempt 3 of 5 failed: ERROR: Failed to send frame on en0.",
        "Responder 10.20.0.77 is suspected rogue: more than one DHCP server identifier was seen; differs from the server that issued this interface's lease; offered router is not on the interface's subnet.",
    ],
    "dhcp_responders_observed": 2, "discovery_attempts": 5, "offers_observed": 2, "raw_offers_observed": 8,
    "attempts_failed": 1,
    "probe_mac": "02:11:22:33:44:55", "probe_mac_source": "interface",
    "system_lease": {"server": "10.20.0.1", "assigned_ip": "10.20.0.143", "router": "10.20.0.1",
                     "dns": ["10.20.0.10", "10.20.0.11"], "domain": "lab.lan", "lease_time_seconds": 86400,
                     "obtained_at": "2026-10-04T12:41:07Z", "source": "ipconfig"},
    "dns_servers_offered": ["10.20.0.10", "10.20.0.11"],
    "reply_sources_seen": [{"ip": "10.20.0.1", "mac": "f0:9f:c2:10:20:01"}, {"ip": "10.20.0.77", "mac": "02:42:ac:11:00:77"}],
    "relay_agents_seen": [], "relay_sources_seen": [],
    "passive_servers_seen": ["10.20.0.1"],
    "capture_message_types": {"Discover": 5, "Offer": 8, "Request": 1, "ACK": 1, "NAK": 0},
    "tcpdump_capture_used": True,
    "rogue_dhcp_suspected": True, "suspected_rogue_servers": ["10.20.0.77"],
    "discovery_note": "DHCP detection uses repeated broadcast discovery attempts. Only responders that replied to at least one attempt are listed. Offer counts are deduplicated by Server Identifier and IP Offered to reduce relay noise.",
    "raw_attempts": [{"attempt": 1, "output_excerpt": excerpt}, {"attempt": 2, "output_excerpt": excerpt}],
    "servers": [
        {"ip": "10.20.0.1", "open_ports": [22, 53, 80, 443], "offers_observed": 1, "raw_offers_observed": 4,
         "classification": "gateway", "suspected_rogue": False, "rogue_reasons": [],
         "offered_router": "10.20.0.1", "offered_subnet_mask": "255.255.255.0", "offered_dns": ["10.20.0.10", "10.20.0.11"],
         "offered_domain": "lab.lan", "lease_time_seconds": 86400, "responder_mac": "f0:9f:c2:10:20:01", "non_offer_replies": 0},
        {"ip": "10.20.0.77", "open_ports": [], "offers_observed": 1, "raw_offers_observed": 4,
         "classification": "unknown", "suspected_rogue": True,
         "rogue_reasons": ["multiple_server_identifiers", "differs_from_system_lease", "offered_router_not_on_subnet"],
         "offered_router": "192.168.8.1", "offered_subnet_mask": "255.255.255.0", "offered_dns": [],
         "offered_domain": None, "lease_time_seconds": 7200, "responder_mac": "02:42:ac:11:00:77", "non_offer_replies": 1},
    ],
}
p4 = dump("dhcp-scan.json", dhcp)

rt = {
    "status": "completed_with_warnings", "success": True, "error": None,
    "warnings": ["Responder 10.20.0.77 answered the probe but was not seen by discovery - possible second DHCP server"],
    "methodology": "DHCP Discover-to-Offer latency measured with layer-2 broadcast probes (scapy) received through a BPF sniffer; the interface MAC is used as the client hardware address. Results reflect point-in-time conditions.",
    "interface": "en0", "is_wifi": False,
    "probe_count": 10, "responded_count": 9,
    "response_times_ms": [3.1, 2.8, 3.4, None, 3.2, 2.7, 3.0, 3.3, 2.8, 3.1],
    "min_ms": 2.7, "avg_ms": 3.04, "max_ms": 3.4, "packet_loss_percent": 10.0,
    "server_ip": "10.20.0.1",
    "servers_seen": {"10.20.0.1": {"offers": 9, "min_ms": 2.7, "avg_ms": 3.04, "max_ms": 3.4},
                     "10.20.0.77": {"offers": 3, "min_ms": 11.2, "avg_ms": 14.6, "max_ms": 19.9}},
    "multiple_responders": True,
    "offered_router": "10.20.0.1", "offered_dns": ["10.20.0.10", "10.20.0.11"], "offered_domain": "lab.lan", "lease_time_seconds": 86400,
    "receive_method": "bpf", "send_method": "layer2", "probe_mac": "02:11:22:33:44:55", "probe_options": "53,55,57,61,12", "interval_seconds": 1,
    "unexpected_servers": ["10.20.0.77"],
    "subnet_utilization": {"usable_hosts": 254, "live_hosts": 41, "utilization_percent": 16.1, "high_utilization": False,
                           "note": "estimated from nmap ping scan; reflects responding hosts, not actual DHCP lease count"},
    "indicators": {"slow_response": False, "high_loss": False, "high_utilization": False, "probe_inconsistent": False, "server_mismatch": True},
    "edited_at": "2026-10-04T14:12:30Z",
}
p5 = dump("dhcp-response-time.json", rt)

dns = {
    "status": "completed_with_warnings", "success": True, "error": None,
    "warnings": ["The subnet sweep was capped to 10.20.0.0/22; the interface network 10.20.0.0/20 is larger.",
                 "The DNS servers in use are outside this subnet (10.99.0.53)."],
    "network": "10.20.0.0/20", "scan_ports": "53", "scanned_range": "10.20.0.0/22", "range_truncated": True,
    "servers": [
        {"ip": "10.20.0.10", "open_ports": [53], "detected_services": ["dns"],
         "sources": ["subnet-scan", "dhcp-offer", "system-lease"], "on_subnet": True,
         "transport": {"tcp": "open", "udp": "open"},
         "resolution_test": {"domain": "google.com", "resolved": True, "response_ms": 14.2, "resolved_ips": ["203.0.113.10"],
                             "attempts": 1, "rcode": "NOERROR", "ra": True, "recursion": "enabled", "open_resolver": True,
                             "rebinding_risk": False, "external_private_answer": False,
                             "internal_test": {"domain": "lab.lan", "resolved": True, "srv_found": True}},
         "ptr_hostname": "dc1.lab.lan", "gateway_ptr": None},
        {"ip": "10.20.0.11", "open_ports": [53], "detected_services": ["dns"],
         "sources": ["dhcp-offer", "system-lease"], "on_subnet": True,
         "transport": {"tcp": "closed", "udp": "open|filtered"},
         "resolution_test": {"domain": "google.com", "resolved": False, "response_ms": None, "resolved_ips": [],
                             "attempts": 3, "rcode": "timeout", "ra": None, "recursion": "unknown", "open_resolver": False,
                             "rebinding_risk": False, "external_private_answer": False,
                             "internal_test": {"domain": "lab.lan", "resolved": False, "srv_found": False}},
         "ptr_hostname": None, "gateway_ptr": None},
        {"ip": "10.99.0.53", "open_ports": [], "detected_services": [],
         "sources": ["configured"], "on_subnet": False,
         "transport": {"tcp": "unknown", "udp": "unknown"},
         "resolution_test": {"domain": "google.com", "resolved": True, "response_ms": 41.0, "resolved_ips": ["10.99.0.200"],
                             "attempts": 2, "rcode": "NOERROR", "ra": False, "recursion": "disabled", "open_resolver": False,
                             "rebinding_risk": True, "external_private_answer": True},
         "ptr_hostname": None, "gateway_ptr": None},
        {"ip": "10.20.1.5", "open_ports": [53], "detected_services": ["dns"],
         "sources": ["subnet-scan"], "on_subnet": True,
         "transport": {"tcp": "open", "udp": "closed"},
         "resolution_test": None, "ptr_hostname": None, "gateway_ptr": None},
    ],
}
p6 = dump("dns-scan.json", dns)

def task(tid, title, fn, path, written, sha_override=None):
    return {"task_id": tid, "title": title, "json_file": fn, "json_present": True, "json_files": [fn],
            "raw_prefix": fn[:-5], "sha256": sha_override or sha(path), "written_at": written}

manifest = {
    "generated_at": "04-10-2026 14:05", "client": "Client Synthetic", "location": "Site DHCP", "note": "",
    "prepared_by": "", "run_directory": "client-synthetic-site-dhcp-04-10-2026", "selected_interface": "en0",
    "report_file": "lss-network-tools-report-client-synthetic-site-dhcp-04-10-2026-14-05.txt", "debug_file": "debug.txt",
    "tasks": [
        task(4, "DHCP Network Scan", "dhcp-scan.json", p4, "2026-10-04T13:00:12Z"),
        task(5, "DHCP Response Time", "dhcp-response-time.json", p5, "2026-10-04T13:00:45Z"),
        # Task 6 was edited by hand without the engine: checksum no longer matches.
        task(6, "DNS Network Scan", "dns-scan.json", p6, "2026-10-04T13:01:30Z", sha_override="0" * 64),
    ],
    "artifacts": [{"path": "dhcp-scan.json", "type": "json"}, {"path": "dhcp-response-time.json", "type": "json"}, {"path": "dns-scan.json", "type": "json"}],
}
dump("manifest.json", manifest)
dump("findings.json", {"findings": [
    {"severity": "high", "title": "Possible rogue DHCP server", "detail": "10.20.0.77 offered router 192.168.8.1 (not on this subnet) and differs from the lease server 10.20.0.1.", "source": "dhcp-scan.json"},
    {"severity": "high", "title": "DHCP responder mismatch between discovery and response-time probe", "detail": "Responder 10.20.0.77 answered the probe but was not seen by discovery (result was edited after the run)", "source": "dhcp-response-time.json"},
    {"severity": "warning", "title": "DHCP-advertised resolver cannot resolve the advertised domain", "detail": "10.20.0.11 did not resolve lab.lan.", "source": "dns-scan.json"},
]})
dump("remediation.json", {"hints": []})
print("written", DEST)
