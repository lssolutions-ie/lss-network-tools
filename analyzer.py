#!/usr/bin/env python3
"""LSS Network Tools analyzer.

Reads the latest scanner logfile from /tmp/lss-netinfo-session.log and writes:
- devices.json
- network-summary.txt
- security-findings.txt
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

LOGFILE = Path("/tmp/lss-netinfo-session.log")
END_SECTION_RE = re.compile(r"^--- END (.+?) SECTION ---$")
DISCOVERY_RE = re.compile(r"^((?:\d{1,3}\.){3}\d{1,3})\|(\d{1,5})$")
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

PORT_SERVICE_MAP = {
    22: "ssh",
    53: "dns",
    80: "web",
    443: "web",
    445: "file",
    631: "printer",
    2049: "file",
    8443: "web",
    9100: "printer",
}


@dataclass
class Device:
    ip: str
    ports: set[int] = field(default_factory=set)
    services: set[str] = field(default_factory=set)
    sections: set[str] = field(default_factory=set)

    def add_port(self, port: int) -> None:
        self.ports.add(port)
        service = PORT_SERVICE_MAP.get(port)
        if service:
            self.services.add(service)


def is_valid_ip(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(p) <= 255 for p in parts)
    except ValueError:
        return False


def split_sections(log_text: str) -> dict[str, list[str]]:
    """Split logfile using --- END ... SECTION --- markers."""
    sections: dict[str, list[str]] = {}
    bucket: list[str] = []

    for raw_line in log_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        match = END_SECTION_RE.match(line)
        if match:
            section_name = match.group(1).strip().upper()
            sections[section_name] = list(bucket)
            bucket.clear()
            continue

        bucket.append(line)

    return sections


def parse_devices(sections: dict[str, list[str]]) -> tuple[dict[str, Device], str | None, set[str]]:
    devices: dict[str, Device] = {}
    gateway_ip: str | None = None
    dhcp_servers: set[str] = set()

    for section, lines in sections.items():
        for line in lines:
            discovery_match = DISCOVERY_RE.match(line)
            if discovery_match:
                ip, port_text = discovery_match.groups()
                if not is_valid_ip(ip):
                    continue
                try:
                    port = int(port_text)
                except ValueError:
                    continue
                if not (0 <= port <= 65535):
                    continue

                device = devices.setdefault(ip, Device(ip=ip))
                device.add_port(port)
                device.sections.add(section)
                continue

            if section == "GATEWAY":
                if line.lower().startswith("gateway:"):
                    found = IP_RE.search(line)
                    if found and is_valid_ip(found.group(0)):
                        gateway_ip = found.group(0)

            if section == "DHCP":
                lower = line.lower()
                if "dhcp offer detected from" in lower or "server identifier" in lower:
                    found = IP_RE.search(line)
                    if found and is_valid_ip(found.group(0)):
                        dhcp_servers.add(found.group(0))

    if gateway_ip and gateway_ip not in devices:
        devices[gateway_ip] = Device(ip=gateway_ip)

    return devices, gateway_ip, dhcp_servers


def classify_device(device: Device, gateway_ip: str | None) -> str:
    ports = device.ports

    if gateway_ip and device.ip == gateway_ip:
        return "gateway"
    if 9100 in ports or 631 in ports:
        return "printer"
    if 445 in ports or 2049 in ports:
        return "file server"
    if 53 in ports:
        return "dns server"
    if 80 in ports or 443 in ports or 8443 in ports:
        return "web management interface"
    if 22 in ports:
        return "ssh access"
    return "unknown"


def build_devices_json(devices: dict[str, Device], gateway_ip: str | None) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for ip in sorted(devices):
        device = devices[ip]
        classification = classify_device(device, gateway_ip)
        services = set(device.services)

        if classification == "printer":
            services.add("printer")
        elif classification == "file server":
            services.add("file")
        elif classification == "dns server":
            services.add("dns")
        elif classification == "web management interface":
            services.add("web")
        elif classification == "ssh access":
            services.add("ssh")

        result.append(
            {
                "ip": ip,
                "ports": sorted(device.ports),
                "services": sorted(services),
                "classification": classification,
            }
        )
    return result


def write_network_summary(devices_json: list[dict[str, object]], gateway_ip: str | None) -> None:
    dns_servers = [d["ip"] for d in devices_json if d["classification"] == "dns server"]
    file_servers = [d["ip"] for d in devices_json if d["classification"] == "file server"]
    printers = [d["ip"] for d in devices_json if d["classification"] == "printer"]
    web_interfaces = [d["ip"] for d in devices_json if d["classification"] == "web management interface"]

    lines = [
        "LSS Network Summary",
        "===================",
        f"Gateway IP: {gateway_ip or 'Not detected'}",
        f"DNS servers: {', '.join(dns_servers) if dns_servers else 'None'}",
        f"File servers: {', '.join(file_servers) if file_servers else 'None'}",
        f"Printers: {', '.join(printers) if printers else 'None'}",
        f"Web management interfaces: {', '.join(web_interfaces) if web_interfaces else 'None'}",
        f"Total discovered devices: {len(devices_json)}",
    ]
    Path("network-summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_security_findings(
    devices_json: list[dict[str, object]],
    dhcp_servers: set[str],
    gateway_ip: str | None,
) -> None:
    web_exposed = [d["ip"] for d in devices_json if d["classification"] == "web management interface"]
    unknown = [d["ip"] for d in devices_json if d["classification"] == "unknown"]
    dns_servers = [d["ip"] for d in devices_json if d["classification"] == "dns server"]

    rogue_dns = [ip for ip in dns_servers if ip != gateway_ip] if gateway_ip else dns_servers

    lines = [
        "LSS Security Findings",
        "====================",
        "",
        "Multiple DHCP servers:",
    ]

    if len(dhcp_servers) > 1:
        lines.extend([f"- Detected: {', '.join(sorted(dhcp_servers))}", "- Status: WARNING"])
    elif len(dhcp_servers) == 1:
        lines.extend([f"- Detected: {next(iter(dhcp_servers))}", "- Status: OK"])
    else:
        lines.extend(["- Detected: none", "- Status: inconclusive"])

    lines.extend(["", "Potential rogue DNS servers:"])
    if rogue_dns:
        lines.extend([f"- {ip}" for ip in sorted(rogue_dns)])
    else:
        lines.append("- None")

    lines.extend(["", "Exposed web management interfaces:"])
    if web_exposed:
        lines.extend([f"- {ip}" for ip in sorted(web_exposed)])
    else:
        lines.append("- None")

    lines.extend(["", "Unknown devices:"])
    if unknown:
        lines.extend([f"- {ip}" for ip in sorted(unknown)])
    else:
        lines.append("- None")

    Path("security-findings.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    if not LOGFILE.exists():
        print("Error: scanner logfile not found at /tmp/lss-netinfo-session.log. Please run the scanner first.")
        return 1

    log_text = LOGFILE.read_text(encoding="utf-8", errors="ignore")
    sections = split_sections(log_text)
    devices, gateway_ip, dhcp_servers = parse_devices(sections)
    devices_json = build_devices_json(devices, gateway_ip)

    Path("devices.json").write_text(json.dumps(devices_json, indent=2) + "\n", encoding="utf-8")
    write_network_summary(devices_json, gateway_ip)
    write_security_findings(devices_json, dhcp_servers, gateway_ip)

    print("LSS Network Analyzer completed successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
