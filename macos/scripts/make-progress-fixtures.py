#!/usr/bin/env python3
"""Generates the hand-written pty captures in Tests/Fixtures/progress/.

Everything follows docs/research/06-m3-execution-contract.md §1.2 and the
human output style of lss-network-tools.sh (2-space indented menu text,
flush-left task output, `[OK]      tool` checklist, braille spinners written
with bare \r, CRLF line endings as a pty produces them).
"""
import json
import sys
from datetime import datetime, timedelta, timezone

OUT_DIR = sys.argv[1]

ESC = "\x1b"
RESET = ESC + "[0m"
GREEN = ESC + "[0;32m"
RED = ESC + "[0;31m"
YELLOW = ESC + "[1;33m"
CYAN = ESC + "[0;36m"
CLEAR = "\r" + ESC + "[K"
BRAILLE = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

RUN_ROOT = "/usr/local/share/lss-network-tools/output"


class Stream:
    def __init__(self, start="2026-10-03T18:30:00Z", pid=4242):
        self.parts = []
        self.ts = datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        self.pid = pid

    def tick(self, seconds=1):
        self.ts += timedelta(seconds=seconds)

    def raw(self, text):
        self.parts.append(text)

    def line(self, text=""):
        self.parts.append(text + "\r\n")

    def event(self, name, **fields):
        obj = {"v": 1, "ts": self.ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "event": name}
        obj.update(fields)
        self.parts.append("@@LSS " + json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\r\n")
        self.tick()

    # spinner(): "\r[frame] message" frames, then "\r\e[K"
    def spinner(self, message, frames=3):
        self.parts.append("".join(f"\r[{BRAILLE[i]}] {message}" for i in range(frames)) + CLEAR)

    # start_spinner_line(): "\rlabel frame" frames, then "\r\e[K"
    def spinner_line(self, label, frames=3):
        self.parts.append("".join(f"\r{label} {BRAILLE[i]}" for i in range(frames)) + CLEAR)

    def text(self):
        return "".join(self.parts)


MACOS_TOOLS = ["nmap", "awk", "sed", "grep", "find", "mktemp", "jq", "speedtest-cli", "python3",
               "ipconfig", "ifconfig", "route", "networksetup", "ping", "tcpdump"]


def checklist(s, missing=()):
    s.line()
    s.line(f"  {YELLOW}Startup Check{RESET}")
    s.line(f"  {YELLOW}════════════════════════{RESET}")
    s.line()
    s.line("  Dependency Checklist:")
    for tool in MACOS_TOOLS + ["python3-scapy", "python3-fpdf2"]:
        if tool in missing:
            s.line(f"  {RED}[MISSING]{RESET} {tool}")
        else:
            s.line(f"  {GREEN}[OK]{RESET}      {tool}")
    s.line(f"  {GREEN}[OK]{RESET}      sshpass")
    s.line(f"  {GREEN}[OK]{RESET}      arp-scan")
    s.line(f"  {GREEN}[OK]{RESET}      airport (wireless scan)")
    s.line()


TITLES = {
    1: "Interface Network Info", 2: "Internet Speed Test", 3: "Gateway Details", 4: "DHCP Network Scan",
    5: "DHCP Response Time", 6: "DNS Network Scan", 7: "LDAP/AD Network Scan", 8: "SMB/NFS Network Scan",
    9: "Printer/Print Server Network Scan", 10: "Gateway Stress Test", 11: "VLAN/Trunk Detection",
    12: "Duplicate IP Detection", 17: "Wireless Site Survey",
}


def task_start(s, task, index, total):
    s.event("task_start", task=task, title=TITLES[task], index=index, total=total)


def pdf_block(s, run_dir, stem, fail=None):
    s.event("report_built", txt=stem + ".txt")
    s.line()
    s.line("  Generating PDF report...")
    if fail:
        s.line(f"  PDF generation failed: {fail}")
        s.event("pdf_failed", message=f"generate_pdf_report.py exited 1: {fail}")
    else:
        s.line(f"  PDF report:    {run_dir}/{stem}.pdf")
        s.event("pdf_built", pdf=stem + ".pdf")


def task_1(s):
    s.line("Interface: en0")
    s.line("IP Address: 10.0.0.23")
    s.line("Subnet Mask: 255.255.255.0")
    s.line("Network Range: 10.0.0.0/24")
    s.line("Gateway: 10.0.0.1")
    s.line("MAC Address: 00:00:5e:00:53:01")


def task_3(s):
    s.line("Stage 1: Determining gateway for interface en0...")
    s.line("Gateway: 10.0.0.1 (gateway.acme.local)")
    s.line("Stage 2: Scanning gateway ports (this may take up to 5 minutes)...")
    s.spinner("Scanning gateway ports...", 4)
    s.line("Open ports: 53/tcp(domain), 80/tcp(http), 443/tcp(https)")


def full_audit():
    s = Stream(pid=4242)
    run_dir = f"{RUN_ROOT}/acme-hq-03-10-2026"
    s.line("Password:")
    s.event("hello", version="v1.2.249", pid=s.pid, tasks=list(range(1, 13)))
    s.event("warning", code="interface_no_ip", message="Interface en0 has no IPv4 address yet; continuing.")
    checklist(s)
    s.event("run_dir", path=run_dir, created=True)

    # 1
    task_start(s, 1, 1, 12)
    task_1(s)
    s.event("task_done", task=1, status="success", rc=0, json_files=["interface-network-info.json"])

    # 2
    task_start(s, 2, 2, 12)
    s.line("Running speedtest-cli (this can take a minute)...")
    s.spinner_line("Download Speed:", 4)
    s.line("Download Speed: 512.34 Mbps")
    s.spinner_line("Upload Speed:", 3)
    s.line("Upload Speed: 498.10 Mbps")
    s.line("Ping: 8.12 ms")
    s.event("task_done", task=2, status="success", rc=0, json_files=["internet-speed-test.json"])

    # 3
    task_start(s, 3, 3, 12)
    task_3(s)
    s.event("task_done", task=3, status="success", rc=0, json_files=["gateway-scan.json"])

    # 4
    task_start(s, 4, 4, 12)
    s.line("Stage 1: Discovering DHCP servers on interface en0...")
    for attempt in (1, 2, 3):
        s.line(f"DHCP discovery attempt {attempt} of 3...")
        s.spinner("Scanning...", 3)
        s.line("DHCP server 10.0.0.1 offered 10.0.0.57 (lease 86400s)")
    s.line("Stage 2: Scanning for ports on DHCP server(s)...")
    s.spinner("Scanning...", 2)
    s.line("10.0.0.1: 53/tcp(domain), 67/udp(dhcps)")
    s.line("Warning: tcpdump capture saw no relay or proxy DHCP traffic.")
    s.event("task_done", task=4, status="completed_with_warnings", rc=0, json_files=["dhcp-scan.json"])

    # 5
    task_start(s, 5, 5, 12)
    s.line("Measuring DHCP response time on en0 (5 probes)...")
    s.spinner("Waiting for DHCP offers...", 3)
    s.line("Probe 1: 11.8 ms")
    s.line("Probe 2: 12.1 ms")
    s.line("Probe 3: 14.2 ms")
    s.line("Probe 4: timed out")
    s.line("Probe 5: 10.9 ms")
    s.line("Average: 12.3 ms (min 10.9, max 14.2)")
    s.line("Warning: probe 4 timed out.")
    s.event("task_done", task=5, status="completed_with_warnings", rc=0, json_files=["dhcp-response-time.json"])

    # 6
    task_start(s, 6, 6, 12)
    s.line("Stage 1: Discovering DNS servers on interface en0...")
    s.line("DNS servers: 10.0.0.1")
    s.line("Recursion enabled (answers LAN clients): yes")
    s.event("task_done", task=6, status="success", rc=0, json_files=["dns-scan.json"])

    # 7
    task_start(s, 7, 7, 12)
    s.line("Scanning 10.0.0.0/24 for LDAP/AD services (389, 636, 3268)...")
    s.spinner("Scanning...", 3)
    s.line("No LDAP/AD servers detected.")
    s.event("task_done", task=7, status="success", rc=0, json_files=["ldap-ad-scan.json"])

    # 8
    task_start(s, 8, 8, 12)
    s.line("Scanning 10.0.0.0/24 for SMB/NFS services...")
    s.spinner("Scanning...", 3)
    s.line("SMB: 10.0.0.40 (nas.acme.local)")
    s.line("NFS: none")
    s.event("task_done", task=8, status="success", rc=0, json_files=["smb-nfs-scan.json"])

    # 9
    task_start(s, 9, 9, 12)
    s.line("Scanning 10.0.0.0/24 for printers and print servers...")
    s.spinner("Scanning...", 3)
    s.line("Printer: 10.0.0.60 (HP LaserJet M404dn, 9100/tcp)")
    s.event("task_done", task=9, status="success", rc=0, json_files=["print-server-scan.json"])

    # 10 — stress stages (task_stage next to the human line)
    task_start(s, 10, 10, 12)
    s.line("Target: 10.0.0.1 (gateway on en0)")
    stages = [
        ("baseline", "Stage 2: Baseline latency test (20 pings)"),
        ("jitter", "Stage 3: Jitter test (200 pings @ 0.05s interval)"),
        ("large_packet", "Stage 4: Large packet test (100 pings @ 1400 bytes)"),
        ("ramping", "Stage 5: Ramping test (20 pings per packet size)"),
        ("sustained", "Stage 6: Sustained load test (300 pings @ 0.02s interval)"),
        ("recovery", "Stage 7: Recovery test (30 pings)"),
    ]
    for key, label in stages:
        if key == "sustained":
            # The previous stage's spinner is still writing frames when the main
            # process emits the next event: both land on one physical line.
            s.raw("".join(f"\r[{BRAILLE[i]}] Pinging 10.0.0.1..." for i in range(2)))
        s.event("task_stage", task=10, stage=key, label=label)
        s.line(label + "...")
        s.spinner("Pinging 10.0.0.1...", 3)
    s.line("Baseline avg: 1.21 ms   Sustained avg: 1.84 ms   Recovery avg: 1.19 ms")
    s.line("Result: the gateway returned to baseline after sustained load.")
    s.event("task_done", task=10, status="success", rc=0, json_files=["gateway-stress-test-device-1.json"])

    # 11
    task_start(s, 11, 11, 12)
    s.event("task_stage", task=11, stage="dot1q_capture", label="Step 1/2: Capturing 802.1Q tagged frames")
    s.line("Step 1/2: Capturing 802.1Q tagged frames on en0 (10s)...")
    s.line("  No 802.1Q tagged frames observed.")
    s.event("task_stage", task=11, stage="cdp_lldp_capture", label="Step 2/2: Capturing CDP and LLDP neighbour frames")
    s.line("Step 2/2: Capturing CDP and LLDP neighbour frames on en0 (65s)...")
    s.line("  (CDP advertises every 60s — this window ensures at least one full cycle is observed.)")
    s.line("  CDP neighbours found: 1")
    s.event("task_done", task=11, status="success", rc=0, json_files=["vlan-trunk-scan.json"])

    # 12
    task_start(s, 12, 12, 12)
    s.line("Scanning 10.0.0.0/24 for duplicate IP addresses (3 passes)...")
    for p in (1, 2, 3):
        s.spinner(f"Pass {p}/3", 2)
        s.line(f"Pass {p}/3: 23 hosts")
    s.line("No duplicate IP addresses detected.")
    s.event("task_done", task=12, status="success", rc=0, json_files=["duplicate-ip-scan.json"])

    pdf_block(s, run_dir, "lss-network-tools-report-acme-hq-03-10-2026-18-31")
    s.event("bye", exit_code=0)
    return s.text()


def single_task_17():
    s = Stream(start="2026-10-03T19:02:10Z", pid=5110)
    run_dir = f"{RUN_ROOT}/acme-hq-03-10-2026"
    s.event("hello", version="v1.2.249", pid=s.pid, tasks=[17])
    checklist(s)
    s.event("run_dir", path=run_dir, created=False)
    task_start(s, 17, 1, 1)
    s.line()
    s.line("--- HQ | Floor: 2 | Room/Area: Meeting Room B ---")
    s.line()
    s.event("warning", code="task_17_helper_fallback",
            message="LSS-WiFiScan.app is not installed; scanning with system_profiler (no RSSI).")
    s.line("Scanning... (this takes a few seconds)")
    s.line()
    s.line("Networks found: 14")
    s.line("Strongest:      LSS-Office (-41 dBm, ch 44, WPA2)")
    s.line("Survey complete. 3 room(s) recorded.")
    s.event("task_done", task=17, status="success", rc=0, json_files=["wireless-survey.json"])
    pdf_block(s, run_dir, "lss-network-tools-report-acme-hq-03-10-2026-18-31")
    s.event("bye", exit_code=0)
    return s.text()


def consent_required():
    s = Stream(start="2026-10-03T19:10:00Z", pid=5201)
    s.event("hello", version="v1.2.249", pid=s.pid, tasks=[10])
    s.line("  Task 10 (Gateway Stress Test) floods the gateway with ICMP and needs --yes.")
    s.event("error", code="consent_required",
            message="Task 10 (Gateway Stress Test) is a stress test; pass --yes to confirm.")
    s.event("bye", exit_code=4)
    return s.text()


def not_root():
    s = Stream(start="2026-10-03T19:12:00Z", pid=5333)
    s.event("hello", version="v1.2.249", pid=s.pid, tasks=[1, 3])
    checklist(s)
    s.line("  Error: lss-network-tools must run as root. Re-run with sudo.")
    s.event("error", code="not_root", message="This tool must run as root (use sudo).")
    s.event("bye", exit_code=5)
    return s.text()


def missing_deps():
    s = Stream(start="2026-10-03T19:15:00Z", pid=5410)
    s.event("hello", version="v1.2.249", pid=s.pid, tasks=list(range(1, 13)))
    checklist(s, missing=("nmap", "python3-fpdf2"))
    s.line("  Missing required dependencies: nmap, python3-fpdf2")
    s.line("  Install them with: sudo bash install.sh")
    s.event("error", code="missing_dependencies",
            message="Required dependencies are missing: nmap, python3-fpdf2", tools=["nmap", "python3-fpdf2"])
    s.event("bye", exit_code=3)
    return s.text()


def task_failed():
    s = Stream(start="2026-10-03T19:20:00Z", pid=5522)
    run_dir = f"{RUN_ROOT}/acme-warehouse-03-10-2026"
    s.line("Password:")
    s.event("hello", version="v1.2.249", pid=s.pid, tasks=[3, 6, 9])
    checklist(s)
    s.event("run_dir", path=run_dir, created=True)

    task_start(s, 3, 1, 3)
    task_3(s)
    s.event("task_done", task=3, status="success", rc=0, json_files=["gateway-scan.json"])

    task_start(s, 6, 2, 3)
    s.line("Stage 1: Discovering DNS servers on interface en0...")
    s.line("Error: No DNS server answered on en0 (resolv.conf is empty and DHCP offered none).")
    s.event("task_done", task=6, status="failed", rc=1, json_files=["dns-scan.json"])

    task_start(s, 9, 3, 3)
    s.line("Error: Unable to create a temporary file for the printer scan.")
    s.event("task_done", task=9, status="no_output", rc=1, json_files=[])

    pdf_block(s, run_dir, "lss-network-tools-report-acme-warehouse-03-10-2026-19-21", fail="assets/logo.png not found")
    s.event("bye", exit_code=1)
    return s.text()


FIXTURES = {
    "full-audit.log": full_audit,
    "single-task-17.log": single_task_17,
    "consent-required.log": consent_required,
    "not-root.log": not_root,
    "missing-deps.log": missing_deps,
    "task-failed.log": task_failed,
}

for name, make in FIXTURES.items():
    data = make().encode("utf-8")
    with open(f"{OUT_DIR}/{name}", "wb") as fh:
        fh.write(data)
    events = sum(1 for part in make().split("\r\n") if "@@LSS " in part)
    print(f"{name}: {len(data)} bytes, {events} event lines")
