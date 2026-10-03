#!/usr/bin/env python3
"""LSS Network Tools -- PDF Comparison Report Generator"""

import sys, re, json, textwrap
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

# Tasks whose results are written as <stem>-device-N.json (one file per target).
MULTI_ENTRY_TASKS = (10, 13, 14, 15, 16)


# ── Text helpers ──────────────────────────────────────────────────────────────
# Code points every registered Inter face can render. Populated once the fonts
# are loaded; until then (or if introspection fails) safe() passes text through.
_FONT_COVERAGE = None

# Substitutions kept for readability / consistency with the TXT report.
_SUBSTITUTIONS = (
    ("—", "--"), ("–", "-"),        # em/en dash
    ("’", "'"),  ("‘", "'"),        # curly single quotes
    ("“", '"'),  ("”", '"'),        # curly double quotes
    ("σ", "stddev"), ("°", "deg"),  # sigma, degree
    ("•", "*"),  ("©", "(c)"),      # bullet, copyright
)


def _register_font_coverage(pdf, font_keys):
    """Record the intersection of code points supported by the given font faces."""
    global _FONT_COVERAGE
    try:
        cover = None
        for key in font_keys:
            cmap = getattr(pdf.fonts[key], "cmap", None)
            if not cmap:
                continue
            cps = set(cmap.keys())
            cover = cps if cover is None else (cover & cps)
        if cover:
            _FONT_COVERAGE = cover
    except Exception:
        _FONT_COVERAGE = None


def safe(text):
    """Normalise a value to a string the bundled Inter TTF can render.

    Keeps the full Unicode repertoire the font supports (Latin-Extended,
    Cyrillic, Greek, ...) and only replaces glyphs the font lacks with '?'.
    """
    if text is None:
        return "--"
    s = str(text)
    for a, b in _SUBSTITUTIONS:
        if a in s:
            s = s.replace(a, b)
    if _FONT_COVERAGE:
        s = "".join(ch if (ord(ch) in _FONT_COVERAGE or ch in "\n\r\t") else "?" for ch in s)
    return s


# ── Value helpers (user-editable JSON may hold None or strings) ───────────────
def to_int(value, default=None):
    """Best-effort int conversion; returns default for None / non-numeric."""
    if value is None or isinstance(value, bool):
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        pass
    try:
        return int(float(str(value).strip()))
    except (TypeError, ValueError):
        return default


def to_float(value, default=None):
    """Best-effort float conversion; returns default for None / non-numeric."""
    if value is None or isinstance(value, bool):
        return default
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return default


def is_truthy(value):
    """Interpret JSON booleans that may have been edited into strings."""
    if isinstance(value, str):
        return value.strip().lower() in ("true", "yes", "1", "y")
    return bool(value)


def yn(value):
    return "Yes" if is_truthy(value) else "No"


def num_str(value, suffix="", default="--"):
    """Format a numeric-ish value with a suffix, or return default.

    Floats are shown with at most 2 decimals so arithmetic artefacts such as
    1.9000000000000001 never reach the page; other values pass through as-is.
    """
    if value is None or value == "":
        return default
    if isinstance(value, float):
        value = round(value, 2)
        if value == int(value) and abs(value) < 1e15:
            value = f"{value:.1f}"
    return f"{value}{suffix}"


def device_index(path, fallback):
    """Numeric N from a <stem>-device-N.json filename, or fallback."""
    m = re.search(r"-device-(\d+)\.json$", Path(str(path)).name)
    return int(m.group(1)) if m else fallback


def join_list(values, default="none"):
    if not values:
        return default
    if not isinstance(values, (list, tuple)):
        return str(values)
    return ", ".join(str(v) for v in values) or default


# ── Data helpers ──────────────────────────────────────────────────────────────
def load_json(path):
    """Load a JSON object; anything unreadable or not a dict is treated as missing."""
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def natural_key(path):
    """Sort key so device-2 orders before device-10."""
    name = Path(str(path)).name
    return [int(tok) if tok.isdigit() else tok.lower() for tok in re.split(r"(\d+)", name)]


def _manifest_task(manifest, task_id):
    for t in manifest.get("tasks", []) or []:
        if isinstance(t, dict) and to_int(t.get("task_id"), -1) == task_id:
            return t
    return None


def all_task_json_paths(run_dir, manifest, task_id):
    """Return all existing JSON Paths for a task, naturally sorted.

    Uses the manifest's json_files list, falls back to its json_file, and as a
    last resort globs the run directory for <stem>-device-*.json so multi-entry
    results still render if the manifest is stale.
    """
    run_dir = Path(run_dir)
    t = _manifest_task(manifest, task_id) or {}
    found = []
    for f in (t.get("json_files") or []):
        p = run_dir / str(f)
        if p.exists() and p not in found:
            found.append(p)
    jf = t.get("json_file")
    if jf:
        p = run_dir / str(jf)
        if p.exists() and p not in found:
            found.append(p)
        if not found:
            for p in run_dir.glob(f"{Path(str(jf)).stem}-device-*.json"):
                if p not in found:
                    found.append(p)
    return sorted(found, key=natural_key)


def task_json_path(run_dir, manifest, task_id):
    paths = all_task_json_paths(run_dir, manifest, task_id)
    return paths[0] if paths else None


def entry_key(data, task_id):
    """Identifier used to pair a multi-entry result across the two runs."""
    if not isinstance(data, dict):
        return None
    if task_id == 10:
        return data.get("gateway") or data.get("target_ip") or None
    return data.get("target_ip") or data.get("gateway") or None


def pair_entries(entries_a, entries_b):
    """Pair two lists of (key, data, device_idx) by key, falling back to index.

    Returns a list of (data_a, data_b, label_key, device_idx) covering the union
    of both runs. Order: run A's entries in file order (with their match from B),
    then any B-only entries in file order.
    """
    used_b = set()
    matched = {}
    # Phase 1: match by key (target_ip / gateway)
    for i, (ka, _, _) in enumerate(entries_a):
        if not ka:
            continue
        for j, (kb, _, _) in enumerate(entries_b):
            if j in used_b or kb != ka:
                continue
            matched[i] = j
            used_b.add(j)
            break
    # Phase 2: index fallback for entries that could not be matched by key
    keys_a = {ka for ka, _, _ in entries_a if ka}
    for i, (ka, _, _) in enumerate(entries_a):
        if i in matched or i >= len(entries_b) or i in used_b:
            continue
        kb = entries_b[i][0]
        # Only pair by index when B's entry is not itself claimed by a key in A
        if kb is None or kb not in keys_a:
            matched[i] = i
            used_b.add(i)
    result = []
    for i, (ka, da, ia) in enumerate(entries_a):
        j = matched.get(i)
        kb, db, ib = entries_b[j] if j is not None else (None, None, None)
        result.append((da, db, ka or kb, ia if ia is not None else ib))
    for j, (kb, db, ib) in enumerate(entries_b):
        if j not in used_b:
            result.append((None, db, kb, ib))
    return result


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


def status_lines(data):
    """Common leading lines: status, plus error detail and warnings when present."""
    lines = [f"Status: {data.get('status', '--')}"]
    err = data.get("error")
    if isinstance(err, dict) and (err.get("code") or err.get("message")):
        code = err.get("code") or "error"
        msg  = err.get("message") or ""
        lines.append(f"Error: {code}" + (f" - {msg}" if msg else ""))
    elif err and not isinstance(err, dict):
        lines.append(f"Error: {err}")
    warnings = data.get("warnings") or []
    if isinstance(warnings, list) and warnings:
        lines.append(f"Warnings: {len(warnings)}")
        for w in warnings:
            lines.append(f"  - {w}")
    return lines


def fmt_interface_info(data):
    if not data:
        return fmt_not_run()
    lines = status_lines(data)
    lines.append(f"Interface: {data.get('interface', '--')}")
    lines.append(f"IP Address: {data.get('ip_address', '--')}")
    lines.append(f"Subnet Mask: {data.get('subnet', '--')}")
    lines.append(f"Network Range: {data.get('network', '--')}")
    lines.append(f"Gateway: {data.get('gateway', '--')}")
    lines.append(f"MAC Address: {data.get('mac_address', '--')}")
    if is_truthy(data.get("is_vm")):
        lines.append(f"VM Platform: {data.get('vm_platform') or 'unknown'}")
    return lines


def fmt_speed_test(data):
    if not data:
        return fmt_not_run()
    servers = data.get("servers") or []
    srv  = servers[0] if servers and isinstance(servers[0], dict) else {}
    ping = srv.get("ping_ms")
    dl   = srv.get("download_mbps")
    ul   = srv.get("upload_mbps")
    pub  = srv.get("public_ip") or data.get("public_ip") or "--"
    srvr = srv.get("test_server") or srv.get("server_name") or "--"
    lines = status_lines(data)
    lines.append(f"Public IP: {pub}")
    lines.append(f"Connected to server: {srvr}")
    lines.append(f"Ping: {num_str(ping, ' ms')}")
    lines.append(f"Download Speed: {num_str(dl, ' Mbps')}")
    lines.append(f"Upload Speed: {num_str(ul, ' Mbps')}")
    return lines


def fmt_gateway(data):
    if not data:
        return fmt_not_run()
    ports = data.get("open_ports") or []
    lines = status_lines(data)
    lines.append(f"Gateway IP: {data.get('gateway_ip') or '--'}")
    lines.append(f"Open Port Count: {len(ports) if isinstance(ports, list) else '--'}")
    lines.append(f"Open Ports: {join_list(ports)}")
    if data.get("scan_scope"):
        lines.append(f"Scan Scope: {data.get('scan_scope')}")
    return lines


def fmt_dhcp(data):
    if not data:
        return fmt_not_run()
    lines = status_lines(data)
    lines.append(f"DHCP Responders Observed: {data.get('dhcp_responders_observed', '--')}")
    lines.append(f"Discovery Attempts: {data.get('discovery_attempts', '--')}")
    lines.append(f"Unique Offers Observed: {data.get('offers_observed', '--')}")
    lines.append(f"Raw Offers Captured: {data.get('raw_offers_observed', '--')}")
    lines.append(f"Possible Rogue DHCP: {yn(data.get('rogue_dhcp_suspected'))}")
    relay = data.get("relay_sources_seen") or []
    if relay:
        lines.append(f"Relay/Proxy Sources: {join_list(relay)}")
    for srv in (data.get("servers") or []):
        if not isinstance(srv, dict):
            continue
        ip    = srv.get("ip", "?")
        cls   = srv.get("classification", "?")
        off   = srv.get("offers_observed", "?")
        rg    = yn(srv.get("suspected_rogue"))
        ports = join_list(srv.get("open_ports") or [])
        lines.append(f"- {ip} | Class: {cls} | Offers: {off} | Rogue: {rg} | Ports: {ports}")
    return lines


def fmt_dhcp_response_time(data):
    if not data:
        return fmt_not_run()
    lines = status_lines(data)
    iface = data.get("interface") or "--"
    if is_truthy(data.get("is_wifi")):
        iface = f"{iface} (Wi-Fi)"
    lines.append(f"Interface:        {iface}")
    lines.append(f"DHCP Server:      {data.get('server_ip') or '--'}")
    probes    = data.get("probe_count", 0)
    responded = data.get("responded_count", 0)
    loss      = data.get("packet_loss_percent")
    lines.append(f"Probes Sent:      {probes if probes is not None else '--'}")
    lines.append(f"Offers Received:  {responded if responded is not None else '--'}")
    lines.append(f"Packet Loss:      {num_str(loss, '%')}")
    lines.append(f"Min Latency:      {num_str(data.get('min_ms'), ' ms')}")
    lines.append(f"Avg Latency:      {num_str(data.get('avg_ms'), ' ms')}")
    lines.append(f"Max Latency:      {num_str(data.get('max_ms'), ' ms')}")
    ind = data.get("indicators") or {}
    if isinstance(ind, dict) and ind:
        lines.append(f"Slow Response:    {yn(ind.get('slow_response'))}")
        lines.append(f"High Loss:        {yn(ind.get('high_loss'))}")
    times = data.get("response_times_ms") or []
    if isinstance(times, list) and times:
        lines.append("")
        lines.append("Per-Probe Results:")
        # Lost probes are stored as null entries; pad to probe_count if shorter.
        n_probes = to_int(probes, 0) or 0
        total = max(len(times), n_probes)
        for i in range(total):
            t = times[i] if i < len(times) else None
            lines.append(f"  Probe {i + 1}: " + ("no response" if t is None else f"{t} ms"))
    return lines


def _dns_resolution_lines(srv):
    """Lines for the enrich_dns_resolution fields of a DNS server (Task 6)."""
    out = []
    res = srv.get("resolution_test")
    if isinstance(res, dict):
        resolved = res.get("resolved")
        ms       = res.get("response_ms")
        domain   = res.get("domain") or "google.com"
        if is_truthy(resolved):
            verdict = f"OK ({ms} ms)" if ms is not None else "OK"
        elif resolved is None:
            verdict = "not tested"
        else:
            verdict = "FAILED"
        out.append(f"    {domain}: {verdict}")
        ips = res.get("resolved_ips") or []
        if ips:
            out.append(f"    Resolved to: {join_list(ips)}")
        out.append(f"    Recursion enabled (answers LAN clients): {yn(res.get('open_resolver'))}")
        if "rebinding_risk" in res:
            out.append(f"    Rebinding risk: {yn(res.get('rebinding_risk'))}")
    ptr  = srv.get("ptr_hostname")
    gptr = srv.get("gateway_ptr")
    if ptr or gptr:
        out.append(f"    PTR: {ptr or '--'} | Gateway PTR: {gptr or '--'}")
    return out


def fmt_generic_scan(data, label):
    if not data:
        return fmt_not_run()
    lines = status_lines(data)
    lines.append(f"Network Range: {data.get('network') or '--'}")
    lines.append(f"Scanned Ports: {data.get('scan_ports') or '--'}")
    servers = data.get("servers") or []
    if not isinstance(servers, list):
        servers = []
    lines.append(f"Servers Found: {len(servers)}")
    for srv in servers:
        if not isinstance(srv, dict):
            continue
        ip       = srv.get("ip", "?")
        ports    = join_list(srv.get("open_ports") or [])
        services = join_list(srv.get("detected_services") or [], default="")
        row = f"- {label} Host {ip} | Ports: {ports}"
        if services:
            row += f" | Services: {services}"
        lines.append(row)
        if label == "DNS":
            lines.extend(_dns_resolution_lines(srv))
        if label == "SMB/NFS" and "smb_signing_required" in srv:
            signing = srv.get("smb_signing_required")
            if signing is None:
                sign_label = "unknown"
            elif is_truthy(signing):
                sign_label = "Required (secure)"
            else:
                sign_label = "Not required (vulnerable to relay attacks)"
            lines.append(f"    SMB Signing: {sign_label}")
    return lines


def fmt_stress_test(data):
    """Tasks 10 and 14 share run_stress_test_for_target(); only the target key differs."""
    if not data:
        return fmt_not_run()
    target    = data.get("gateway") or data.get("target_ip") or data.get("gateway_ip") or "--"
    ind       = data.get("indicators")        or {}
    ss        = data.get("stage_status")      or {}
    baseline  = data.get("baseline")          or {}
    jitter    = data.get("jitter_test")       or {}
    large     = data.get("large_packet_test") or {}
    sustained = data.get("sustained_test")    or {}
    recovery  = data.get("recovery")          or {}
    if not all(isinstance(part, dict) for part in (ind, ss, baseline, jitter, large, sustained, recovery)):
        return status_lines(data) + [f"Target: {target}", "(unexpected result shape)"]

    lines = status_lines(data)
    lines.append(f"Target: {target}")
    if data.get("hostname"):
        lines.append(f"Hostname: {data.get('hostname')}")
    if is_truthy(data.get("completed_with_warnings")) and data.get("warning"):
        lines.append(f"Note: {data.get('warning')}")
    lines.append(f"Baseline Avg:  {num_str(baseline.get('avg_latency_ms'), ' ms')}")
    lines.append(f"Sustained Avg: {num_str(sustained.get('avg_latency_ms'), ' ms')}")
    lines.append(f"High Jitter: {yn(ind.get('high_jitter'))} | Latency Under Load: {yn(ind.get('latency_under_load'))}")
    lines.append(f"Packet Loss: {yn(ind.get('packet_loss'))} | Slow Recovery: {yn(ind.get('slow_recovery'))}")
    lines.append("")
    lines.append("Stage          Status   Avg              Loss")
    stage_rows = [
        ("Baseline",     ss.get("baseline"),     baseline.get("avg_latency_ms"),  None,                                 False),
        ("Jitter",       ss.get("jitter"),       jitter.get("stddev_ms"),         jitter.get("packet_loss_percent"),    True),
        ("Large Packet", ss.get("large_packet"), large.get("avg_latency_ms"),     large.get("packet_loss_percent"),     False),
        ("Ramping",      ss.get("ramping"),      None,                            None,                                 False),
        ("Sustained",    ss.get("sustained"),    sustained.get("avg_latency_ms"), sustained.get("packet_loss_percent"), False),
        ("Recovery",     ss.get("recovery"),     recovery.get("avg_latency_ms"),  None,                                 False),
    ]
    for name, status, avg, loss, is_stddev in stage_rows:
        avg_s  = num_str(avg, " ms (stddev)" if is_stddev else " ms")
        loss_s = num_str(loss, "%")
        lines.append(f"  {name:<13}{str(status or '?'):<8} {avg_s:<16} {loss_s}")
    ramp = data.get("ramping_test") or []
    if isinstance(ramp, list) and ramp:
        lines.append("Ramping (packet size -> avg / max / loss):")
        for r in ramp:
            if not isinstance(r, dict):
                continue
            lines.append(
                f"  {r.get('packet_size', '?')} B: "
                f"{num_str(r.get('avg_latency_ms'), ' ms')} / "
                f"{num_str(r.get('max_latency_ms'), ' ms')} / "
                f"{num_str(r.get('packet_loss_percent'), '%')}"
            )
    if "returned_to_baseline" in recovery:
        lines.append(f"Returned To Baseline: {yn(recovery.get('returned_to_baseline'))}")
    return lines


def fmt_vlan_trunk(data):
    if not data:
        return fmt_not_run()
    lines = status_lines(data)
    ind = data.get("indicators") or {}
    if not isinstance(ind, dict):
        ind = {}
    lines.append(f"Interface: {data.get('interface') or '--'}")
    lines.append(f"Tagged Frames Observed: {yn(data.get('tagged_frames_observed'))}")
    vlan_ids = data.get("observed_vlan_ids") or []
    lines.append(f"Observed VLAN IDs: {join_list(vlan_ids)}")
    lines.append(f"Trunk Port Suspected: {yn(ind.get('trunk_port_suspected'))}")
    lines.append(f"CDP/LLDP Exposure: {yn(ind.get('cdp_exposed'))}")
    lines.append(f"Multiple VLANs Visible: {yn(ind.get('multiple_vlans_visible'))}")

    cdp = data.get("cdp_neighbours") or []
    if isinstance(cdp, list) and cdp:
        lines.append(f"CDP Neighbours ({len(cdp)}):")
        for n in cdp:
            if not isinstance(n, dict):
                lines.append(f"  {n}")
                continue
            vlan = n.get("native_vlan")
            lines.append(
                f"  {n.get('device_id', '?')} | {n.get('platform', '?')}"
                f" | Port: {n.get('port_id', '?')}"
                f" | Native VLAN: {vlan if vlan is not None else 'unknown'}"
                f" | Duplex: {n.get('duplex', '?')}"
            )
    else:
        lines.append("CDP Neighbours: none detected")

    lldp = data.get("lldp_neighbours") or []
    if isinstance(lldp, list) and lldp:
        lines.append(f"LLDP Neighbours ({len(lldp)}):")
        for n in lldp:
            if not isinstance(n, dict):
                lines.append(f"  {n}")
                continue
            lines.append(
                f"  {n.get('system_name', '?')} | Chassis: {n.get('chassis_id', '?')}"
                f" | Port: {n.get('port_id', '?')}"
            )
    else:
        lines.append("LLDP Neighbours: none detected")

    probe = data.get("double_tag_probe") or {}
    if isinstance(probe, dict):
        if not is_truthy(probe.get("attempted")):
            probe_str = "Not attempted"
        elif is_truthy(probe.get("vulnerable")):
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
    duplicates = data.get("duplicates") or []
    if not isinstance(duplicates, list):
        duplicates = []
    dup_count = to_int(data.get("duplicate_count"), None)
    if dup_count is None:
        dup_count = len(duplicates)
    lines = status_lines(data)
    lines.append(f"Interface:        {data.get('interface') or '--'}")
    lines.append(f"Network Range:    {data.get('network') or '--'}")
    lines.append(f"Total Hosts Seen: {data.get('total_hosts_seen', '--')}")
    lines.append(f"Duplicate IPs:    {dup_count}")
    lines.append("")
    if not dup_count and not duplicates:
        lines.append("No duplicate IPs detected.")
    else:
        for dup in duplicates:
            if not isinstance(dup, dict):
                continue
            lines.append(f"  {dup.get('ip', '?')}: {join_list(dup.get('macs') or [])}")
    return lines


def fmt_wireless_survey(data):
    if not data:
        return fmt_not_run()
    lines  = status_lines(data)
    survey = data.get("survey") or []
    if not isinstance(survey, list):
        survey = []
    lines.append(f"Interface: {data.get('interface') or '--'}")
    lines.append(f"Rooms Surveyed: {data.get('rooms_scanned', len(survey))}")
    for room in survey:
        if not isinstance(room, dict):
            continue
        bld  = room.get("building") or "?"
        flr  = room.get("floor")    or "?"
        rm   = room.get("room")     or "?"
        ap   = yn(room.get("ap_present"))
        lbl  = room.get("ap_label")
        nets = room.get("networks") or []
        nets = nets if isinstance(nets, list) else []
        row  = f"  {bld} / Floor {flr} / {rm}  AP={ap}"
        if lbl:
            row += f" ({lbl})"
        row += f"  Networks={len(nets)}"
        lines.append(row)
        best = None
        for n in nets:
            if not isinstance(n, dict):
                continue
            v = to_float(n.get("rssi_dbm"))
            if v is not None and (best is None or v > best[0]):
                best = (v, n)
        if best:
            n = best[1]
            lines.append(
                f"    Strongest: {n.get('ssid') or '(hidden)'} "
                f"{num_str(n.get('rssi_dbm'), ' dBm')} ch {n.get('channel') or '--'} "
                f"{n.get('band') or ''} {n.get('security') or ''}".rstrip()
            )
    return lines


def fmt_unifi_discovery(data):
    if not data:
        return fmt_not_run()
    devices = data.get("devices") or []
    if not isinstance(devices, list):
        devices = []
    lines = status_lines(data)
    lines.append(f"Interface: {data.get('interface') or '--'}")
    lines.append(f"Subnet: {data.get('subnet') or '--'}")
    lines.append(f"Devices Found: {data.get('devices_found', len(devices))}")
    for dev in devices:
        if not isinstance(dev, dict):
            continue
        model = dev.get("model", "")
        row   = f"  {dev.get('ip', '?')}  {dev.get('mac', '?')}"
        if model:
            row += f"  [{model}]"
        lines.append(row)
    fps = data.get("false_positives") or []
    if isinstance(fps, list) and fps:
        lines.append(f"False Positives (non-Ubiquiti MAC): {len(fps)}")
        for fp in fps:
            if isinstance(fp, dict):
                lines.append(f"  {fp.get('ip', '?')}  {fp.get('mac', '?')}")
    return lines


def fmt_unifi_adoption(data):
    if not data:
        return fmt_not_run()
    devices = data.get("devices") or []
    if not isinstance(devices, list):
        devices = []
    lines = status_lines(data)
    lines.append(f"Interface: {data.get('interface') or '--'}")
    lines.append(f"Controller: {data.get('controller') or '--'}")
    lines.append(f"Inform URL: {data.get('inform_url') or '--'}")
    lines.append(f"Devices Attempted: {data.get('devices_found', len(devices))}")
    lines.append(f"set-inform Sent: {data.get('devices_adopted', '--')}")
    _labels = {"adopted": "set-inform sent", "failed": "could not connect"}
    for dev in devices:
        if not isinstance(dev, dict):
            continue
        res = dev.get("result") or "--"
        lines.append(f"  {dev.get('ip', '?')}: {_labels.get(res, res)}")
    return lines


def fmt_find_device_by_mac(data):
    if not data:
        return fmt_not_run()
    ip = data.get("ip_found")
    lines = status_lines(data)
    lines.append(f"MAC Queried: {data.get('mac_queried') or '--'}")
    lines.append(f"Interface:   {data.get('interface') or '--'}")
    lines.append(f"Subnet:      {data.get('subnet') or '--'}")
    lines.append(f"Result:      {'Found' if ip else 'Not found'}")
    lines.append(f"IP Address:  {ip or '--'}")
    return lines


def fmt_custom_port_scan(data):
    if not data:
        return fmt_not_run()
    ports = data.get("open_ports") or []
    if not isinstance(ports, list):
        ports = []
    lines = status_lines(data)
    lines.append(f"Target IP: {data.get('target_ip') or '--'}")
    if data.get("hostname"):
        lines.append(f"Hostname: {data.get('hostname')}")
    lines.append(f"Open Port Count: {len(ports)}")
    lines.append(f"Open TCP Ports: {join_list(ports)}")
    return lines


def fmt_custom_identity(data):
    if not data:
        return fmt_not_run()
    lines = status_lines(data)
    lines.append(f"Target IP: {data.get('target_ip') or '--'}")
    lines.append(f"Hostname: {data.get('hostname') or '--'}")
    lines.append(f"MAC Address: {data.get('mac_address') or '--'}")
    vendor = data.get("vendor") or "--"
    if data.get("vendor_source"):
        vendor += f" (via {data.get('vendor_source')})"
    lines.append(f"Vendor: {vendor}")
    lines.append(f"Host State: {data.get('host_state') or '--'}")
    lines.append(f"Device Type Hint: {data.get('device_type_hint') or '--'}")
    lines.append(f"Confidence: {data.get('confidence') or '--'}")
    lines.append(f"Identity Summary: {data.get('identity_summary') or '--'}")
    services = data.get("services") or []
    if isinstance(services, list) and services:
        lines.append(f"Services ({len(services)}):")
        for s in services:
            if isinstance(s, dict):
                lines.append(
                    f"  {s.get('port', '?')} | {s.get('state') or '?'} | {s.get('service') or '?'}"
                    f" | {s.get('version') or 'no version banner'}"
                )
            else:
                lines.append(f"  {s}")
    return lines


def fmt_custom_dns_assessment(data):
    if not data:
        return fmt_not_run()
    udp = data.get("udp_query") or {}
    tcp = data.get("tcp_query") or {}
    ptr = data.get("reverse_ptr_query") or {}
    udp = udp if isinstance(udp, dict) else {}
    tcp = tcp if isinstance(tcp, dict) else {}
    ptr = ptr if isinstance(ptr, dict) else {}
    lines = status_lines(data)
    lines.append(f"Target IP: {data.get('target_ip') or '--'}")
    lines.append(f"Hostname: {data.get('hostname') or '--'}")
    lines.append(f"DNS Service Working: {yn(data.get('dns_service_working'))}")
    lines.append(f"Recursion Available: {yn(data.get('recursion_available'))}")
    lines.append(f"UDP Query Status: {udp.get('status') or '--'}")
    if udp.get("answers"):
        lines.append(f"  UDP Answers: {join_list(udp.get('answers'))}")
    lines.append(f"TCP Query Status: {tcp.get('status') or '--'}")
    if tcp.get("answers"):
        lines.append(f"  TCP Answers: {join_list(tcp.get('answers'))}")
    if ptr:
        lines.append(f"Reverse PTR Status: {ptr.get('status') or '--'}")
        if ptr.get("answers"):
            lines.append(f"  PTR Answers: {join_list(ptr.get('answers'))}")
    lines.append(f"Software Hint: {data.get('software_hint') or '--'}")
    if data.get("version_bind_response"):
        lines.append(f"version.bind: {data.get('version_bind_response')}")
    if data.get("query_tool"):
        lines.append(f"Query Tool: {data.get('query_tool')}")
    return lines


# Single-result tasks, rendered in task-id order (multi-entry tasks are
# interleaved from MULTI_DEFS below so the report keeps 1..20 ordering).
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
    (11, "VLAN/Trunk Detection",         fmt_vlan_trunk),
    (12, "Duplicate IP Detection",       fmt_duplicate_ip),
    (17, "Wireless Site Survey",         fmt_wireless_survey),
    (18, "Scan For UniFi Devices",       fmt_unifi_discovery),
    (19, "UniFi Adoption",               fmt_unifi_adoption),
    (20, "Find Device by MAC",           fmt_find_device_by_mac),
]

# Multi-entry tasks: one JSON per target device; paired across runs by entry_key().
MULTI_DEFS = [
    (10, "Gateway Stress Test",          fmt_stress_test),
    (13, "Custom Target Port Scan",      fmt_custom_port_scan),
    (14, "Custom Target Stress Test",    fmt_stress_test),
    (15, "Custom Target Identity Scan",  fmt_custom_identity),
    (16, "Custom Target DNS Assessment", fmt_custom_dns_assessment),
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
        _register_font_coverage(self, ("inter", "interB", "interI"))

    def fit_text(self, text, width, pad=1.0):
        """Return text truncated (with an ellipsis) so it fits in width mm at the current font."""
        s = safe(text)
        if self.get_string_width(s) <= width - pad:
            return s
        ell = "..."
        ell_w = self.get_string_width(ell)
        out = ""
        for ch in s:
            if self.get_string_width(out + ch) + ell_w > width - pad:
                break
            out += ch
        return out.rstrip() + ell

    def header(self):
        if not self._cover_done:
            return
        self.set_fill_color(*C_NAV)
        self.rect(0, 0, PAGE_W, TOP_BAR, "F")
        self.set_font("Inter", "B", 7)
        self.set_text_color(*C_WHT)
        mid = MARGIN + COL_W + GAP // 2
        self.set_xy(MARGIN, 3)
        self.cell(COL_W, 6, self.fit_text(f"{self.client_a} / {self.location_a}  [{self.date_a}]", COL_W), align="L")
        self.set_xy(mid, 3)
        self.cell(COL_W, 6, self.fit_text(f"{self.client_b} / {self.location_b}  [{self.date_b}]", COL_W), align="L")
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
            self.cell(card_w - 10, label_h, self.fit_text(f"{client} / {location}", card_w - 10))

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

    def _section_header_bar(self, task_id, title, y, continued=False):
        self.set_fill_color(*C_NAV)
        self.set_text_color(*C_WHT)
        self.set_font("Inter", "B", 9)
        self.set_xy(MARGIN, y)
        text = f"  Task {task_id}  --  {title}" + ("  (continued)" if continued else "")
        self.cell(EFF_W, HDR_H, self.fit_text(text, EFF_W), fill=True)

    def render_task_section(self, task_id, title, lines_a, lines_b):
        """Render one task comparison section. Prevents orphaned headers."""
        pairs       = pair_and_wrap(lines_a, lines_b, self.chars_per_col)
        min_h       = HDR_H + 2 + 3 * LINE_H   # header + at least 3 rows

        # Add page if the minimum content block doesn't fit
        if self.get_y() + min_h > SAFE_Y and self.get_y() > CONTENT_Y + 10:
            self.add_page()

        y       = self.get_y() + 2
        right_x = MARGIN + COL_W + GAP

        # Section header bar
        self._section_header_bar(task_id, title, y)
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
                self._section_header_bar(task_id, title, y, continued=True)
                y += HDR_H + 2
                self.set_font("Inter", "", FONT_SZ)
                self.set_text_color(*C_DGR)

            shade = row_idx % 2 == 0
            if shade:
                self.set_fill_color(*C_LGR)
                self.rect(MARGIN, y, EFF_W, LINE_H, "F")

            self.set_xy(MARGIN, y)
            self.cell(COL_W, LINE_H, self.fit_text(l, COL_W))
            self.set_xy(right_x, y)
            self.cell(COL_W, LINE_H, self.fit_text(r, COL_W))
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
        client_a   = manifest_a.get("client")       or "Unknown",
        location_a = manifest_a.get("location")     or str(run_dir_a.name),
        date_a     = manifest_a.get("generated_at") or "--",
        client_b   = manifest_b.get("client")       or "Unknown",
        location_b = manifest_b.get("location")     or str(run_dir_b.name),
        date_b     = manifest_b.get("generated_at") or "--",
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

    def render_single(task_id, title, formatter):
        da = get(run_dir_a, manifest_a, task_id)
        db = get(run_dir_b, manifest_b, task_id)
        if da is None and db is None:
            return
        pdf.render_task_section(task_id, title, formatter(da), formatter(db))

    def load_entries(run_dir, manifest, task_id):
        entries = []
        for pos, p in enumerate(all_task_json_paths(run_dir, manifest, task_id), 1):
            d = load_json(p)
            if d is not None:
                entries.append((entry_key(d, task_id), d, device_index(p, pos)))
        return entries

    def render_multi(task_id, label, formatter):
        paired = pair_entries(load_entries(run_dir_a, manifest_a, task_id),
                              load_entries(run_dir_b, manifest_b, task_id))
        total  = len(paired)
        for pos, (da, db, key, idx) in enumerate(paired, 1):
            if da is None and db is None:
                continue
            idx = idx if idx is not None else pos
            tgt = key or f"device {idx}"
            if total > 1 or task_id != 10:
                title = f"{label} - {tgt}  (device {idx})"
            else:
                title = f"{label} - {tgt}"
            pdf.render_task_section(task_id, title, formatter(da), formatter(db))

    singles = {tid: (title, fmt) for tid, title, fmt in TASK_DEFS}
    multis  = {tid: (title, fmt) for tid, title, fmt in MULTI_DEFS}
    for task_id in sorted(set(singles) | set(multis)):
        if task_id in multis:
            title, fmt = multis[task_id]
            render_multi(task_id, title, fmt)
        else:
            title, fmt = singles[task_id]
            render_single(task_id, title, fmt)

    pdf.output(str(pdf_path))
    print(str(pdf_path))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # report a one-line reason, never a traceback
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
