#!/usr/bin/env python3
"""LSS Network Tools -- PDF Comparison Report Generator"""

import sys, json, textwrap
from pathlib import Path

try:
    from fpdf import FPDF
except ImportError:
    print("fpdf2 not installed. pip3 install fpdf2", file=sys.stderr)
    sys.exit(1)

# ── Constants ─────────────────────────────────────────────────────────────────
C_NAV = (26,  42,  74)
C_WHT = (255, 255, 255)
C_DGR = (33,  33,  33)
C_MGR = (117, 117, 117)
C_LGR = (245, 245, 245)
C_ACC = (74,  144, 226)

FONT_SZ   = 8
LINE_H    = 4.5
HDR_H     = 8
MARGIN    = 15
GAP       = 7
PAGE_W    = 297   # A4 landscape
PAGE_H    = 210
TOP_BAR   = 12
BOT_BAR   = 10
COL_W     = (PAGE_W - MARGIN * 2 - GAP) // 2    # ~130mm
EFF_W     = COL_W * 2 + GAP
SAFE_Y    = PAGE_H - MARGIN - BOT_BAR            # ~183mm
CONTENT_Y = TOP_BAR + 6                          # y after header bar


# ── Helpers ───────────────────────────────────────────────────────────────────
def safe(text):
    if text is None:
        return "--"
    s = str(text)
    for a, b in [("\u2014", "--"), ("\u2013", "-"), ("\u2019", "'"),
                 ("\u2018", "'"), ("\u201c", '"'), ("\u201d", '"'),
                 ("\u2022", "*"), ("\u00a9", "(c)")]:
        s = s.replace(a, b)
    return s.encode("latin-1", errors="replace").decode("latin-1")


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def task_json_path(run_dir, manifest, task_id):
    for t in manifest.get("tasks", []):
        try:
            if int(t.get("task_id", -1)) == task_id:
                files = t.get("json_files") or []
                if files:
                    return run_dir / files[0]
                jf = t.get("json_file")
                if jf:
                    return run_dir / jf
        except (TypeError, ValueError):
            continue
    return None


def all_task_json_paths(run_dir, manifest, task_id):
    for t in manifest.get("tasks", []):
        try:
            if int(t.get("task_id", -1)) == task_id:
                return [
                    run_dir / f
                    for f in (t.get("json_files") or [])
                    if (run_dir / f).exists()
                ]
        except (TypeError, ValueError):
            continue
    return []


def pair_and_wrap(lines_a, lines_b, chars):
    """Pair original lines and wrap together so fields stay row-aligned."""
    def wrap_one(line):
        if not line:
            return [""]
        if len(line) <= chars:
            return [line]
        indent = " " * (len(line) - len(line.lstrip()))
        chunks = textwrap.wrap(line, chars, subsequent_indent=indent,
                               break_long_words=True, break_on_hyphens=False)
        return chunks if chunks else [line[:chars]]

    n = max(len(lines_a), len(lines_b), 1)
    result = []
    for i in range(n):
        la = lines_a[i] if i < len(lines_a) else ""
        lb = lines_b[i] if i < len(lines_b) else ""
        wa = wrap_one(la)
        wb = wrap_one(lb)
        for j in range(max(len(wa), len(wb))):
            result.append((
                wa[j] if j < len(wa) else "",
                wb[j] if j < len(wb) else "",
            ))
    return result


# ── Task text formatters ──────────────────────────────────────────────────────
def fmt_not_run():
    return ["(not run)"]


def fmt_interface_info(data):
    if not data:
        return fmt_not_run()
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Interface: {data.get('interface', '--')}")
    lines.append(f"IP Address: {data.get('ip_address', '--')}")
    lines.append(f"Subnet Mask: {data.get('subnet', '--')}")
    lines.append(f"Network Range: {data.get('network', '--')}")
    lines.append(f"Gateway: {data.get('gateway', '--')}")
    lines.append(f"MAC Address: {data.get('mac_address', '--')}")
    if data.get("is_vm"):
        lines.append(f"VM Platform: {data.get('vm_platform') or 'unknown'}")
    return lines


def fmt_speed_test(data):
    if not data:
        return fmt_not_run()
    srv  = (data.get("servers") or [{}])[0]
    ping = srv.get("ping_ms")
    dl   = srv.get("download_mbps")
    ul   = srv.get("upload_mbps")
    pub  = srv.get("public_ip") or data.get("public_ip") or "--"
    srvr = srv.get("test_server") or srv.get("server_name") or "--"
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Public IP: {pub}")
    lines.append(f"Connected to server: {srvr}")
    lines.append(f"Ping: {ping} ms" if ping is not None else "Ping: --")
    lines.append(f"Download Speed: {dl} Mbps" if dl is not None else "Download Speed: --")
    lines.append(f"Upload Speed: {ul} Mbps" if ul is not None else "Upload Speed: --")
    return lines


def fmt_gateway(data):
    if not data:
        return fmt_not_run()
    ports = data.get("open_ports") or []
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Gateway IP: {data.get('gateway_ip', '--')}")
    lines.append(f"Open Ports: {', '.join(str(p) for p in ports) or 'none'}")
    return lines


def fmt_dhcp(data):
    if not data:
        return fmt_not_run()
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"DHCP Responders Observed: {data.get('dhcp_responders_observed', '--')}")
    lines.append(f"Discovery Attempts: {data.get('discovery_attempts', '--')}")
    lines.append(f"Unique Offers Observed: {data.get('offers_observed', '--')}")
    lines.append(f"Raw Offers Captured: {data.get('raw_offers_observed', '--')}")
    rogue = data.get("rogue_dhcp_suspected", False)
    lines.append(f"Possible Rogue DHCP: {'Yes' if rogue else 'No'}")
    relay = data.get("relay_sources_seen") or []
    if relay:
        lines.append(f"Relay/Proxy Sources: {', '.join(relay)}")
    for srv in (data.get("servers") or []):
        ip    = srv.get("ip", "?")
        cls   = srv.get("classification", "?")
        off   = srv.get("offers_observed", "?")
        rg    = "Yes" if srv.get("suspected_rogue") else "No"
        ports = ", ".join(str(p) for p in (srv.get("open_ports") or []))
        lines.append(f"- {ip} | Class: {cls} | Offers: {off} | Rogue: {rg} | Ports: {ports}")
    return lines


def fmt_dhcp_response_time(data):
    if not data:
        return fmt_not_run()
    lines = [f"Status: {data.get('status', '--')}"]
    warnings = data.get("warnings") or []
    if warnings:
        lines.append(f"Warnings: {len(warnings)}")
        for w in warnings:
            lines.append(f"  - {w}")
    lines.append(f"Interface:        {data.get('interface', '--')}")
    lines.append(f"DHCP Server:      {data.get('server_ip', '--')}")
    probes    = data.get("probe_count", 0)
    responded = data.get("responded_count", 0)
    loss      = data.get("packet_loss_percent")
    lines.append(f"Probes Sent:      {probes}")
    lines.append(f"Offers Received:  {responded}")
    lines.append(f"Packet Loss:      {loss}%" if loss is not None else "Packet Loss:      --")
    lines.append(f"Min Latency:      {data.get('min_ms', '--')} ms")
    lines.append(f"Avg Latency:      {data.get('avg_ms', '--')} ms")
    lines.append(f"Max Latency:      {data.get('max_ms', '--')} ms")
    times = data.get("response_times_ms") or []
    if times:
        lines.append("")
        lines.append("Per-Probe Results:")
        rt_iter = iter(times)
        for i in range(1, int(probes) + 1):
            try:
                t = next(rt_iter)
                lines.append(f"  Probe {i}: {t} ms")
            except StopIteration:
                lines.append(f"  Probe {i}: no response")
    return lines


def fmt_generic_scan(data, label):
    if not data:
        return fmt_not_run()
    lines = [f"Status: {data.get('status', '--')}"]
    warnings = data.get("warnings") or []
    if warnings:
        lines.append(f"Warnings: {len(warnings)}")
    lines.append(f"Network Range: {data.get('network', '--')}")
    lines.append(f"Scanned Ports: {data.get('scanned_ports', '--')}")
    servers = data.get("servers") or []
    lines.append(f"Servers Found: {len(servers)}")
    for srv in servers:
        ip       = srv.get("ip", "?")
        ports    = ", ".join(str(p) for p in (srv.get("open_ports") or []))
        services = ", ".join(srv.get("services") or [])
        res      = srv.get("resolution_test") or {}
        if isinstance(res, dict):
            resolved = res.get("resolved")
            ms       = res.get("response_ms")
            google   = f"OK ({ms} ms)" if resolved else ("FAILED" if resolved is False else "not tested")
        else:
            google = "not tested"
        row = f"- {label} Host {ip} | Ports: {ports}"
        if services:
            row += f" | Services: {services}"
        row += f" | google.com: {google}"
        lines.append(row)
    return lines


def fmt_stress_test(data):
    if not data:
        return fmt_not_run()
    target = data.get("target_ip") or data.get("gateway_ip") or "--"
    lines  = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Target: {target}")
    for stage in (data.get("stages") or []):
        name = stage.get("label") or stage.get("stage", "?")
        sent = stage.get("packets_sent", "?")
        recv = stage.get("packets_received", "?")
        loss = stage.get("packet_loss_percent", "?")
        avg  = stage.get("avg_rtt_ms", "?")
        lines.append(f"  {name}: sent={sent} recv={recv} loss={loss}% avg={avg}ms")
    return lines


def fmt_vlan_trunk(data):
    if not data:
        return fmt_not_run()
    lines = [f"Status: {data.get('status', '--')}"]
    warnings = data.get("warnings") or []
    if warnings:
        lines.append(f"Warnings: {len(warnings)}")
        for w in warnings:
            lines.append(f"  - {w}")
    lines.append(f"Interface: {data.get('interface', '--')}")
    tagged = data.get("dot1q_tagged_frames_observed")
    lines.append(f"802.1Q Tagged Frames Observed: {str(tagged).lower() if tagged is not None else '--'}")
    vlan_ids = data.get("observed_vlan_ids") or []
    lines.append(f"Observed VLAN IDs: {', '.join(str(v) for v in vlan_ids) if vlan_ids else 'none'}")
    trunk = data.get("trunk_port_suspected")
    lines.append(f"Trunk Port Suspected: {str(trunk).lower() if trunk is not None else '--'}")
    multi = data.get("multiple_vlans_visible")
    lines.append(f"Multiple VLANs Visible: {str(multi).lower() if multi is not None else '--'}")
    cdp_recv = data.get("cdp_lldp_neighbour_frames_received")
    lines.append(f"CDP/LLDP Frames Received: {str(cdp_recv).lower() if cdp_recv is not None else '--'}")
    cdp_n  = data.get("cdp_neighbours")  or []
    lldp_n = data.get("lldp_neighbours") or []
    lines.append(f"CDP Neighbours:  {', '.join(str(n) for n in cdp_n)  if cdp_n  else 'none detected'}")
    lines.append(f"LLDP Neighbours: {', '.join(str(n) for n in lldp_n) if lldp_n else 'none detected'}")
    probe = data.get("double_tag_probe") or {}
    if isinstance(probe, dict):
        if not probe.get("attempted", False):
            probe_str = "Not attempted"
        elif probe.get("vulnerable"):
            probe_str = "Vulnerable"
        else:
            probe_str = "Attempted -- not vulnerable"
    else:
        probe_str = str(probe)
    lines.append(f"Double-Tag Probe: {probe_str}")
    return lines


def fmt_duplicate_ip(data):
    if not data:
        return fmt_not_run()
    dup_count = data.get("duplicate_count", 0)
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Interface:        {data.get('interface', '--')}")
    lines.append(f"Network Range:    {data.get('network', '--')}")
    lines.append(f"Total Hosts Seen: {data.get('total_hosts_seen', '--')}")
    lines.append(f"Duplicate IPs:    {dup_count}")
    lines.append("")
    if not dup_count:
        lines.append("No duplicate IPs detected.")
    else:
        for dup in (data.get("duplicates") or []):
            lines.append(f"  {dup.get('ip','?')}: {', '.join(dup.get('macs') or [])}")
    return lines


def fmt_wireless_survey(data):
    if not data:
        return fmt_not_run()
    lines  = [f"Status: {data.get('status', '--')}"]
    survey = data.get("survey") or []
    lines.append(f"Rooms Surveyed: {len(survey)}")
    for room in survey:
        bld  = room.get("building", "?")
        flr  = room.get("floor",    "?")
        rm   = room.get("room",     "?")
        ap   = "Yes" if room.get("ap_present") else "No"
        nets = len(room.get("networks") or [])
        lines.append(f"  {bld} / Floor {flr} / {rm}  AP={ap}  Networks={nets}")
    return lines


def fmt_unifi_discovery(data):
    if not data:
        return fmt_not_run()
    devices = data.get("devices") or []
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Interface: {data.get('interface', '--')}")
    lines.append(f"Subnet: {data.get('subnet', '--')}")
    lines.append(f"Devices Found: {len(devices)}")
    for dev in devices:
        model = dev.get("model", "")
        row   = f"  {dev.get('ip','?')}  {dev.get('mac','?')}"
        if model:
            row += f"  [{model}]"
        lines.append(row)
    fps = data.get("false_positives") or []
    if fps:
        lines.append(f"False Positives: {len(fps)}")
    return lines


def fmt_unifi_adoption(data):
    if not data:
        return fmt_not_run()
    results = data.get("results") or []
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Devices Attempted: {len(results)}")
    for r in results:
        ok = r.get("success", False)
        lines.append(f"  {r.get('ip','?')}: {'OK' if ok else 'FAILED'}")
    return lines


def fmt_custom_port_scan(data):
    if not data:
        return fmt_not_run()
    ports = data.get("open_ports") or []
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Target IP: {data.get('target_ip', '--')}")
    lines.append(f"Open Port Count: {len(ports)}")
    lines.append(f"Open TCP Ports: {', '.join(str(p) for p in ports) or 'none'}")
    return lines


def fmt_custom_identity(data):
    if not data:
        return fmt_not_run()
    lines = [f"Status: {data.get('status', '--')}"]
    lines.append(f"Target IP: {data.get('target_ip', '--')}")
    lines.append(f"Hostname: {data.get('hostname', '--')}")
    lines.append(f"OS Guess: {data.get('os_guess', '--')}")
    lines.append(f"Open Ports: {', '.join(str(p) for p in (data.get('open_ports') or [])) or 'none'}")
    return lines


TASK_DEFS = [
    (1,  "Interface Network Info",       fmt_interface_info),
    (2,  "Internet Speed Test",          fmt_speed_test),
    (3,  "Gateway Details",              fmt_gateway),
    (4,  "DHCP Network Scan",            fmt_dhcp),
    (5,  "DHCP Response Time",           fmt_dhcp_response_time),
    (6,  "DNS Network Scan",             lambda d: fmt_generic_scan(d, "DNS")),
    (7,  "LDAP/AD Network Scan",         lambda d: fmt_generic_scan(d, "LDAP/AD")),
    (8,  "SMB/NFS Network Scan",         lambda d: fmt_generic_scan(d, "SMB/NFS")),
    (9,  "Printer/Print Server Scan",    lambda d: fmt_generic_scan(d, "Printer")),
    (10, "Gateway Stress Test",          fmt_stress_test),
    (11, "VLAN/Trunk Detection",         fmt_vlan_trunk),
    (12, "Duplicate IP Detection",       fmt_duplicate_ip),
    (17, "Wireless Site Survey",         fmt_wireless_survey),
    (18, "Scan For UniFi Devices",       fmt_unifi_discovery),
    (19, "UniFi Adoption",               fmt_unifi_adoption),
]


# ── PDF class ─────────────────────────────────────────────────────────────────
class CompareReport(FPDF):
    def __init__(self, client_a, location_a, date_a, client_b, location_b, date_b, logo_path):
        super().__init__(orientation="L", unit="mm", format="A4")
        self.client_a   = client_a
        self.location_a = location_a
        self.date_a     = date_a
        self.client_b   = client_b
        self.location_b = location_b
        self.date_b     = date_b
        self.logo_path  = logo_path
        self._cover_done = False
        self.chars_per_col = 60  # updated after font is set
        self.set_auto_page_break(auto=False)
        self.set_margins(MARGIN, CONTENT_Y, MARGIN)
        self.alias_nb_pages()
        _fonts = Path(__file__).parent / "assets" / "fonts"
        self.add_font("Inter", "",  str(_fonts / "Inter-Regular.ttf"))
        self.add_font("Inter", "B", str(_fonts / "Inter-Bold.ttf"))
        self.add_font("Inter", "I", str(_fonts / "Inter-Italic.ttf"))

    def header(self):
        if not self._cover_done:
            return
        self.set_fill_color(*C_NAV)
        self.rect(0, 0, PAGE_W, TOP_BAR, "F")
        self.set_font("Inter", "B", 7)
        self.set_text_color(*C_WHT)
        mid = MARGIN + COL_W + GAP // 2
        self.set_xy(MARGIN, 3)
        self.cell(COL_W, 6, safe(f"{self.client_a} / {self.location_a}  [{self.date_a}]"), align="L")
        self.set_xy(mid, 3)
        self.cell(COL_W, 6, safe(f"{self.client_b} / {self.location_b}  [{self.date_b}]"), align="L")
        self.set_text_color(*C_DGR)
        self.set_y(CONTENT_Y)

    def footer(self):
        if not self._cover_done:
            return
        self.set_y(PAGE_H - BOT_BAR)
        self.set_font("Inter", "I", 7)
        self.set_text_color(*C_MGR)
        self.cell(
            0, 6,
            safe(f"Page {self.page_no()} of {{nb}}  --  LSS Network Tools Comparison Report  |  Generated by LS Solutions Software"),
            align="C",
        )

    def cover(self):
        NAVY_H = int(PAGE_H * 0.55)
        # Navy band
        self.set_fill_color(*C_NAV)
        self.rect(0, 0, PAGE_W, NAVY_H, "F")

        # Logo
        logo_rendered = False
        if self.logo_path and Path(self.logo_path).exists():
            try:
                lw = 44
                self.image(self.logo_path, x=(PAGE_W - lw) / 2, y=14, w=lw)
                logo_rendered = True
            except Exception:
                pass
        if not logo_rendered:
            self.set_font("Inter", "B", 28)
            self.set_text_color(*C_WHT)
            self.set_xy(0, 22)
            self.cell(PAGE_W, 14, "LSS", align="C")

        # Divider
        self.set_draw_color(*C_ACC)
        self.set_line_width(0.8)
        self.line(20, 60, PAGE_W - 20, 60)

        # Title
        self.set_font("Inter", "B", 22)
        self.set_text_color(*C_WHT)
        self.set_xy(0, 64)
        self.cell(PAGE_W, 11, "NETWORK AUDIT COMPARISON REPORT", align="C")

        self.set_font("Inter", "", 9)
        self.set_text_color(160, 190, 230)
        self.set_xy(0, 78)
        self.cell(PAGE_W, 5, "LS Solutions Software -- LSS Network Tools", align="C")

        # Two info cards (one per run)
        card_y    = NAVY_H + 6
        card_w    = (PAGE_W - MARGIN * 2 - GAP) // 2
        label_h   = 5.5

        for i, (client, location, date) in enumerate([
            (self.client_a, self.location_a, self.date_a),
            (self.client_b, self.location_b, self.date_b),
        ]):
            card_x = MARGIN + i * (card_w + GAP)
            self.set_fill_color(*C_NAV)
            self.set_draw_color(*C_NAV)
            self.set_line_width(0.4)
            self.rect(card_x, card_y, card_w, 28, "FD")
            # Left accent bar
            self.set_fill_color(*C_ACC)
            self.rect(card_x, card_y, 4, 28, "F")

            col_label = "Run A" if i == 0 else "Run B"
            self.set_font("Inter", "B", 7)
            self.set_text_color(*C_ACC)
            self.set_xy(card_x + 7, card_y + 3)
            self.cell(card_w - 10, label_h, col_label)

            self.set_font("Inter", "B", 9)
            self.set_text_color(*C_WHT)
            self.set_xy(card_x + 7, card_y + 9)
            self.multi_cell(card_w - 10, label_h, safe(f"{client} / {location}"),
                            new_x="LMARGIN", new_y="NEXT")

            self.set_font("Inter", "", 8)
            self.set_text_color(180, 200, 230)
            self.set_xy(card_x + 7, card_y + 20)
            self.cell(card_w - 10, label_h, safe(date))

        # Confidentiality strip
        self.set_fill_color(*C_NAV)
        self.rect(0, PAGE_H - 18, PAGE_W, 18, "F")
        self.set_draw_color(*C_ACC)
        self.set_line_width(0.6)
        self.line(0, PAGE_H - 18, PAGE_W, PAGE_H - 18)
        self.set_font("Inter", "B", 7.5)
        self.set_text_color(*C_WHT)
        self.set_xy(0, PAGE_H - 13)
        self.cell(PAGE_W, 5, safe(f"CONFIDENTIAL  --  Prepared for {self.client_a}"), align="C")
        self.set_font("Inter", "", 7)
        self.set_text_color(160, 190, 230)
        self.set_xy(0, PAGE_H - 7)
        self.cell(PAGE_W, 5, "Not for distribution beyond the named recipient", align="C")

        self._cover_done = True

    def _calibrate_chars(self):
        """Calculate chars per column based on actual font metrics."""
        self.set_font("Inter", "", FONT_SZ)
        sample    = "abcdefghijklmnopqrstuvwxyz0123456789 "
        char_w_mm = self.get_string_width(sample) / len(sample)
        self.chars_per_col = max(30, int(COL_W / char_w_mm) - 2)

    def render_task_section(self, task_id, title, lines_a, lines_b):
        """Render one task comparison section. Prevents orphaned headers."""
        pairs       = pair_and_wrap(lines_a, lines_b, self.chars_per_col)
        estimated_h = HDR_H + 2 + len(pairs) * LINE_H + 4
        min_h       = HDR_H + 2 + 3 * LINE_H   # header + at least 3 rows

        # Add page if the minimum content block doesn't fit
        if self.get_y() + min_h > SAFE_Y and self.get_y() > CONTENT_Y + 10:
            self.add_page()

        y       = self.get_y() + 2
        right_x = MARGIN + COL_W + GAP

        # Section header bar
        self.set_fill_color(*C_NAV)
        self.set_text_color(*C_WHT)
        self.set_font("Inter", "B", 9)
        self.set_xy(MARGIN, y)
        self.cell(EFF_W, HDR_H, safe(f"  Task {task_id}  --  {title}"), fill=True)
        y += HDR_H + 2

        # Column date sub-header
        self.set_font("Inter", "I", 7)
        self.set_text_color(*C_MGR)
        self.set_xy(MARGIN, y)
        self.cell(COL_W, LINE_H - 0.5, safe(f"  {self.date_a}"))
        self.set_xy(right_x, y)
        self.cell(COL_W, LINE_H - 0.5, safe(f"  {self.date_b}"))
        y += LINE_H + 1

        # Thin rule under date
        self.set_draw_color(*C_NAV)
        self.set_line_width(0.15)
        self.line(MARGIN, y, MARGIN + EFF_W, y)
        y += 1.5

        # Content rows
        self.set_font("Inter", "", FONT_SZ)
        self.set_text_color(*C_DGR)

        for row_idx, (l, r) in enumerate(pairs):
            if y + LINE_H > SAFE_Y:
                self.add_page()
                y = self.get_y()
                # Repeat section header on continuation page
                self.set_fill_color(*C_NAV)
                self.set_text_color(*C_WHT)
                self.set_font("Inter", "B", 9)
                self.set_xy(MARGIN, y)
                self.cell(EFF_W, HDR_H,
                          safe(f"  Task {task_id}  --  {title}  (continued)"), fill=True)
                y += HDR_H + 2
                self.set_font("Inter", "", FONT_SZ)
                self.set_text_color(*C_DGR)

            shade = row_idx % 2 == 0
            if shade:
                self.set_fill_color(*C_LGR)
                self.rect(MARGIN, y, EFF_W, LINE_H, "F")

            self.set_xy(MARGIN, y)
            self.cell(COL_W, LINE_H, safe(l))
            self.set_xy(right_x, y)
            self.cell(COL_W, LINE_H, safe(r))
            y += LINE_H

        # Separator
        self.set_y(y + 2)
        sep_y = self.get_y()
        if sep_y < SAFE_Y:
            self.set_draw_color(*C_NAV)
            self.set_line_width(0.2)
            self.line(MARGIN, sep_y, MARGIN + EFF_W, sep_y)
            self.set_y(sep_y + 2)


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 5:
        print(
            "Usage: generate_pdf_compare_report.py "
            "<run_dir_a> <run_dir_b> <pdf_path> <app_root>",
            file=sys.stderr,
        )
        sys.exit(1)

    run_dir_a = Path(sys.argv[1])
    run_dir_b = Path(sys.argv[2])
    pdf_path  = Path(sys.argv[3])
    app_root  = Path(sys.argv[4])

    manifest_a = load_json(run_dir_a / "manifest.json") or {}
    manifest_b = load_json(run_dir_b / "manifest.json") or {}

    logo = app_root / "assets" / "logo.png"

    pdf = CompareReport(
        client_a   = manifest_a.get("client",       "Unknown"),
        location_a = manifest_a.get("location",     str(run_dir_a.name)),
        date_a     = manifest_a.get("generated_at", "--"),
        client_b   = manifest_b.get("client",       "Unknown"),
        location_b = manifest_b.get("location",     str(run_dir_b.name)),
        date_b     = manifest_b.get("generated_at", "--"),
        logo_path  = str(logo) if logo.exists() else None,
    )

    # Cover
    pdf.add_page()
    pdf.cover()

    # Content pages
    pdf.add_page()
    pdf._calibrate_chars()

    def get(run_dir, manifest, task_id):
        p = task_json_path(run_dir, manifest, task_id)
        return load_json(p) if p and p.exists() else None

    # Core tasks
    for task_id, title, formatter in TASK_DEFS:
        da = get(run_dir_a, manifest_a, task_id)
        db = get(run_dir_b, manifest_b, task_id)
        if da is None and db is None:
            continue
        pdf.render_task_section(task_id, title, formatter(da), formatter(db))

    # Multi-entry tasks 13-16
    MULTI_TASKS = [
        (13, "Custom Target Port Scan",         fmt_custom_port_scan,  fmt_custom_port_scan),
        (14, "Custom Target Stress Test",        fmt_stress_test,       fmt_stress_test),
        (15, "Custom Target Identity Scan",      fmt_custom_identity,   fmt_custom_identity),
        (16, "Custom Target DNS Assessment",     fmt_generic_scan,      fmt_generic_scan),
    ]
    for task_id, label, fmt_fn_a, fmt_fn_b in MULTI_TASKS:
        paths_a = all_task_json_paths(run_dir_a, manifest_a, task_id)
        paths_b = all_task_json_paths(run_dir_b, manifest_b, task_id)
        n = max(len(paths_a), len(paths_b))
        for i in range(n):
            da = load_json(paths_a[i]) if i < len(paths_a) else None
            db = load_json(paths_b[i]) if i < len(paths_b) else None
            if da is None and db is None:
                continue
            tgt = (da or db or {}).get("target_ip", f"device {i+1}")
            t   = f"{label} - {tgt}  (device {i+1})"
            if task_id == 16:
                la = fmt_fn_a(da, "DNS") if da else fmt_not_run()
                lb = fmt_fn_b(db, "DNS") if db else fmt_not_run()
            else:
                la = fmt_fn_a(da) if da else fmt_not_run()
                lb = fmt_fn_b(db) if db else fmt_not_run()
            pdf.render_task_section(task_id, t, la, lb)

    pdf.output(str(pdf_path))
    print(str(pdf_path))


if __name__ == "__main__":
    main()
