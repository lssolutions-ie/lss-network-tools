#!/usr/bin/env python3
"""
make-synthetic-run.py -- assemble one complete, fictional run directory for the GUI and tests.

Real runs only ever contain tasks 1-12 (and their stress files were unreadable), so a run that
exercises every task view has to be built. This script combines:

  * the task 1-12 JSON of an anonymised real fixture run (shapes exactly as the engine writes them),
  * the synthetic success files for tasks 13-20 (renamed to the engine's file names),
  * two hand-written successful stress-test results (Task 10 device-1 and Task 14 device-1),
  * a manifest listing all 20 tasks, findings.json and remediation.json.

Output: macos/Tests/Fixtures/synthetic-run/client-synthetic-site-lab-01-10-2026/
Re-run any time; the directory is replaced. Python 3 standard library only.
"""
import json
import os
import shutil
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "..", "Tests", "Fixtures")
SYNTHETIC = os.path.join(FIXTURES, "synthetic")


def generation_key(path):
    """Newest engine generation first: the manifest's task count (20 > 18 > 17), then the
    manifest's generated_at (dd-mm-yyyy HH:mm), then the name — so the assembled run carries
    the newest shapes (isp_name, subnet_utilization, indicators.high_utilization)."""
    manifest = {}
    try:
        with open(os.path.join(path, "manifest.json"), encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError):
        pass
    tasks = manifest.get("tasks") or []
    stamp = str(manifest.get("generated_at") or "")
    try:
        when = datetime.strptime(stamp, "%d-%m-%Y %H:%M")
    except ValueError:
        when = datetime.min
    return (len(tasks), when, os.path.basename(path))


def ranked_runs():
    """All anonymised run directories, newest generation first."""
    runs_root = os.path.join(FIXTURES, "runs")
    paths = [os.path.join(runs_root, d) for d in os.listdir(runs_root)
             if os.path.isdir(os.path.join(runs_root, d)) and os.path.isfile(os.path.join(runs_root, d, "manifest.json"))]
    if not paths:
        sys.exit("no anonymised runs under %s" % runs_root)
    return sorted(paths, key=generation_key, reverse=True)


RANKED_RUNS = ranked_runs()
SOURCE_RUN = RANKED_RUNS[0]
DEST_ROOT = os.path.join(FIXTURES, "synthetic-run")
RUN_NAME = "client-synthetic-site-lab-01-10-2026"
DEST = os.path.join(DEST_ROOT, RUN_NAME)

TASKS = [
    (1, "Interface Network Info", "interface-network-info.json"),
    (2, "Internet Speed Test", "internet-speed-test.json"),
    (3, "Gateway Details", "gateway-scan.json"),
    (4, "DHCP Network Scan", "dhcp-scan.json"),
    (5, "DHCP Response Time", "dhcp-response-time.json"),
    (6, "DNS Network Scan", "dns-scan.json"),
    (7, "LDAP/AD Network Scan", "ldap-ad-scan.json"),
    (8, "SMB/NFS Network Scan", "smb-nfs-scan.json"),
    (9, "Printer/Print Server Network Scan", "print-server-scan.json"),
    (10, "Gateway Stress Test", "gateway-stress-test.json"),
    (11, "VLAN/Trunk Detection", "vlan-trunk-scan.json"),
    (12, "Duplicate IP Detection", "duplicate-ip-scan.json"),
    (13, "Custom Target Port Scan", "custom-target-port-scan.json"),
    (14, "Custom Target Stress Test", "custom-target-stress-test.json"),
    (15, "Custom Target Identity Scan", "custom-target-identity-scan.json"),
    (16, "Custom Target DNS Assessment", "custom-target-dns-assessment.json"),
    (17, "Wireless Site Survey", "wireless-survey.json"),
    (18, "Scan For UniFi Devices", "unifi-discovery.json"),
    (19, "UniFi Adoption", "unifi-adoption.json"),
    (20, "Find Device by MAC", "find-device-by-mac.json"),
]
MULTI = {10, 13, 14, 15, 16}

# synthetic success file per specialist task -> engine file name
SPECIALIST = {
    13: ("task-13-success.json", "custom-target-port-scan-device-1.json"),
    15: ("task-15-success.json", "custom-target-identity-scan-device-1.json"),
    16: ("task-16-success.json", "custom-target-dns-assessment-device-1.json"),
    17: ("task-17-corewlan.json", "wireless-survey.json"),
    18: ("task-18-success.json", "unifi-discovery.json"),
    19: ("task-19-success.json", "unifi-adoption.json"),
    20: ("task-20-found.json", "find-device-by-mac.json"),
}


def stress_result(function, target_key, target, hostname):
    """A successful stress-test result in the shape run_stress_test_for_target writes."""
    return {
        "status": "completed_with_warnings",
        "success": True,
        "error": None,
        "warnings": ["Packet loss was observed during the sustained stage (0.5%)."],
        "function": function,
        target_key: target,
        "hostname": hostname,
        "interface": "en0",
        "completed_with_warnings": True,
        "warning": "Packet loss was observed during the sustained stage (0.5%).",
        "stage_status": {
            "baseline": "ok", "jitter": "ok", "large_packet": "ok",
            "ramping": "ok", "sustained": "ok", "recovery": "ok",
        },
        "baseline": {"avg_latency_ms": 1.84, "max_latency_ms": 4.12, "stddev_ms": 0.61},
        "jitter_test": {"stddev_ms": 1.92, "max_latency_ms": 11.7, "packet_loss_percent": 0.0},
        "large_packet_test": {"avg_latency_ms": 2.95, "max_latency_ms": 8.4, "packet_loss_percent": 0.0},
        "ramping_test": [
            {"packet_size": 64, "avg_latency_ms": 1.9, "max_latency_ms": 4.3, "packet_loss_percent": 0.0},
            {"packet_size": 256, "avg_latency_ms": 2.1, "max_latency_ms": 5.0, "packet_loss_percent": 0.0},
            {"packet_size": 512, "avg_latency_ms": 2.6, "max_latency_ms": 6.8, "packet_loss_percent": 0.0},
            {"packet_size": 1024, "avg_latency_ms": 3.4, "max_latency_ms": 9.9, "packet_loss_percent": 0.0},
            {"packet_size": 1400, "avg_latency_ms": 4.2, "max_latency_ms": 14.6, "packet_loss_percent": 0.5},
        ],
        "sustained_test": {"avg_latency_ms": 5.7, "max_latency_ms": 38.2, "packet_loss_percent": 0.5},
        "recovery": {"avg_latency_ms": 1.97, "returned_to_baseline": True},
        "indicators": {"high_jitter": False, "latency_under_load": False, "packet_loss": True, "slow_recovery": False},
        "methodology": "ICMP echo stages: baseline (20), jitter (200 @ 0.05s), large packet (1400 B), ramping 64-1400 B, sustained (10 s flood), recovery (20).",
    }


def main():
    if not os.path.isdir(SOURCE_RUN):
        sys.exit("source fixture run missing: %s" % SOURCE_RUN)
    if os.path.isdir(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST)

    written = []
    # tasks 1-12 from the real fixtures: the primary run first, any other anonymised run as a
    # fallback (not every real run executed every task); 10 is replaced by the synthetic success.
    fallback_runs = RANKED_RUNS[1:]          # newest generation first
    for task_id, _title, name in TASKS[:12]:
        if task_id == 10:
            continue
        for candidate_run in [SOURCE_RUN] + fallback_runs:
            src = os.path.join(candidate_run, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(DEST, name))
                written.append(name)
                break
        else:
            sys.exit("no fixture run provides %s" % name)
    # stress tests
    for name, payload in (
        ("gateway-stress-test-device-1.json", stress_result("gateway_stress_test", "gateway", "10.42.0.1", "gw.lab.local")),
        ("custom-target-stress-test-device-1.json", stress_result("custom_target_stress_test", "target_ip", "10.42.0.20", "nas-01.lab.local")),
    ):
        with open(os.path.join(DEST, name), "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
        written.append(name)
    # specialist tasks
    for task_id, (synthetic_name, dest_name) in SPECIALIST.items():
        src = os.path.join(SYNTHETIC, synthetic_name)
        if not os.path.isfile(src):
            sys.exit("synthetic fixture missing: %s" % src)
        shutil.copy2(src, os.path.join(DEST, dest_name))
        written.append(dest_name)

    # findings / remediation from the real fixture
    for name in ("findings.json", "remediation.json"):
        src = os.path.join(SOURCE_RUN, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(DEST, name))
            written.append(name)

    report = "lss-network-tools-report-client-synthetic-site-lab-01-10-2026-10-30.txt"
    tasks = []
    for task_id, title, name in TASKS:
        stem = name[:-5]
        if task_id in MULTI:
            files = sorted(n for n in written if n.startswith(stem + "-device-") and n.endswith(".json"))
        else:
            files = [name] if name in written else []
        tasks.append({
            "task_id": task_id, "title": title, "json_file": name,
            "json_present": bool(files), "json_files": files, "raw_prefix": stem,
        })
    manifest = {
        "generated_at": "01-10-2026 10:30",
        "client": "Client Synthetic",
        "location": "Site Lab",
        "note": "all twenty tasks",
        "prepared_by": "Test Engineer",
        "run_directory": RUN_NAME,
        "selected_interface": "en0",
        "report_file": report,
        "debug_file": "debug.txt",
        "tasks": tasks,
        "artifacts": [{"path": n, "type": "json"} for n in written],
    }
    with open(os.path.join(DEST, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")
    with open(os.path.join(DEST, "provenance.json"), "w", encoding="utf-8") as fh:
        json.dump({
            "generator": "make-synthetic-run.py",
            "source_fixture": os.path.basename(SOURCE_RUN),
            "note": "Fictional run: real anonymised task 1-12 files + synthetic 13-20 + hand-written stress results.",
        }, fh, indent=2)
        fh.write("\n")
    print("wrote %s (%d task files)" % (DEST, len(written)))


if __name__ == "__main__":
    main()
