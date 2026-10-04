#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
anonymize-run.py -- turn a real lss-network-tools run directory into a committed test fixture.

Python 3 standard library only. Runs on /usr/bin/python3 (3.9) and Homebrew python3 (3.14);
no 3.10+ syntax is used.

Usage
-----
  anonymize-run.py --src <run-dir> [--src <run-dir> ...] --dest <fixtures-root>
                   --salt <hex> [--pdf <app-root>] [--check] [--skip-unreadable]
  anonymize-run.py --salt <hex> --source-id <run-dir> ...

The repository's fixtures are generated with a PRIVATE salt (the maintainer keeps it in
~/.config/lss-network-tools/fixture-salt.hex); see Tests/Fixtures/runs/README.md. The optional
``--leak-list`` / ``--verify-leak-list`` modes (a hashed n-gram list for offline re-scans) are kept
for local use but nothing in the repository relies on them any more: with a public salt such a
list is a guess-confirmation oracle for client names, so it must never be committed.

Design (macos/docs/PLAN.md section 6)
-------------------------------------
* Every identifier is replaced deterministically by ``<prefix>-<first 6 hex of
  HMAC-SHA256(salt, normalised value)>``. Use a PRIVATE ``--salt <hex>`` for anything that is
  committed: the slugs are only 24 bits, so with a known salt anyone could confirm a guessed
  client or site name against them. The built-in default salt exists only so the script runs
  without arguments for throw-away local experiments; the fixtures in this repository were NOT
  made with it.
* manifest.json: ``client`` -> ``Client <hex6>``, ``location`` -> ``Site <hex6>``,
  ``note`` -> ``note-<hex6>`` (empty stays empty), ``prepared_by`` -> ``Test Engineer``.
  The run directory name, ``run_directory``, ``report_file`` and the matching ``artifacts[].path``
  are rebuilt from the new slugs with the bash ``sanitize_for_filename`` rules, keeping the
  original date / time parts.
* Every string in every JSON file (any depth) gets, in this order:
    (a) case-insensitive replacement of the original client / location / note / prepared_by
        tokens and of their slug forms;
    (b) ``Domain Name: <x>`` values inside nmap DHCP excerpts -> ``domain-<hex6>.<tld>``
        (``localdomain`` and other generic values are kept), and every other host-name-looking
        token in free text (``TFTP Server Name:``, ``Hostname:``, ``Domain Search:`` ...) ->
        ``host-<hex6>.<tld>`` (tooling domains, version numbers, file names and path components
        are left alone);
    (c) MAC addresses keep their first three octets (OUI, so vendor strings stay truthful) and
        get the last three hashed;
    (d) every IPv4 literal that is NOT private / loopback / link-local / CGNAT / multicast /
        a netmask / 0.0.0.0 / 255.255.255.255 / a well-known anycast resolver is mapped into
        TEST-NET (203.0.113.0/24, then 198.51.100.0/24, then 192.0.2.0/24). The mapping keeps the
        original last octet whenever it is free, so network / gateway / host relationships of a
        public LAN survive (``87.36.171.0/25`` -> ``203.0.113.0/25``, ``.1`` -> ``.1`` ...).
  Hostname-like keys (``hostname``, ``ptr_hostname``, ``gateway_ptr``, ``device_id``,
  ``system_name``, ``system_description``, ``vtp_domain``, ``test_server``, ``controller``,
  speed-test ``location``, DNS ``answers[]``/``resolved_ips[]``) become ``host-<hex6>`` (a trailing
  ``.local`` is kept), ``isp_name`` -> ``isp-<hex6>``, ``ssid`` -> ``ssid-<hex6>`` except
  ``(hidden)``. Sentinels (``unknown``, ``--``, empty) are kept. ``vendor`` / ``vendors[]`` /
  ``model`` are left intact.
* Not copied: ``debug.txt``, ``raw/``, every ``*.txt`` report, the original ``*.pdf``. Copied
  (processed): ``manifest.json``, ``findings.json``, ``remediation.json`` and every task JSON.
* ``--pdf <app-root>`` regenerates a clean PDF for the anonymised run with
  ``generate_pdf_report.py`` (the generator reads the rewritten manifest).
* ``--check`` scans every file and path name under each destination run for every original token
  (names, slugs, distinctive words, public IPs, MACs, hostnames, domains, SSIDs; PDF text via
  ``pdftotext`` when available) and exits non-zero listing the leaks. It also applies the
  structural rule "no public IPv4 literal anywhere" and the hashed n-gram rule used by
  ``--verify-leak-list``.
* ``--leak-list <file>`` writes (merging with an existing file) the HMAC of every replaced name /
  word / hostname / domain / SSID so that a Swift test can re-scan the tree WITHOUT the plaintext
  being committed. IPs and MACs are deliberately not listed (their hashes are brute-forceable);
  they are covered by the structural IPv4 rule and by the plaintext ``--check`` at generation time.
* ``provenance.json`` is written into every fixture run (anonymiser version, date, HMAC of the
  source basename, skipped / dropped files). No directory it creates may be named ``output``
  (the repository .gitignore excludes ``output/``).
"""

import argparse
import binascii
import datetime
import hashlib
import hmac
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys

ANONYMIZER_NAME = "anonymize-run.py"
ANONYMIZER_VERSION = "1.0.0"

# Intentionally public (see module docstring). Hex of b"lss-network-tools-fixtures-2026".
DEFAULT_SALT_HEX = binascii.hexlify(b"lss-network-tools-fixtures-2026").decode("ascii")

PREPARED_BY = "Test Engineer"
PDF_GENERATOR = "generate_pdf_report.py"
PDF_PYTHON_CANDIDATES = ("/opt/homebrew/bin/python3", "/usr/local/bin/python3")

# RFC 5737 documentation ranges, in allocation order.
TEST_NET_POOLS = ("203.0.113.", "198.51.100.", "192.0.2.")

KEEP_NETWORKS = tuple(ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",      # RFC 1918
    "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10",     # loopback, link-local, CGNAT
    "224.0.0.0/4",                                         # multicast
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",  # TEST-NET (already anonymised)
))
# Not client-identifying; kept verbatim so DHCP "Domain Name Server" lines stay recognisable.
KEEP_ADDRESSES = frozenset((
    "0.0.0.0", "255.255.255.255",
    "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "149.112.112.112",
    "208.67.222.222", "208.67.220.220",
))

HOST_KEYS = frozenset(("hostname", "ptr_hostname", "gateway_ptr", "device_id", "system_name",
                       "system_description", "vtp_domain", "test_server", "controller"))
HOST_LIST_KEYS = frozenset(("answers", "resolved_ips"))
ISP_KEYS = frozenset(("isp_name",))
SSID_KEYS = frozenset(("ssid",))
FILE_HOST_KEYS = {"internet-speed-test.json": frozenset(("location",))}
SENTINELS = frozenset(("", "unknown", "--", "(hidden)", "n/a", "none", "null"))
GENERIC_DOMAINS = frozenset(("localdomain", "local", "lan", "home", "localhost", "home.arpa",
                             "internal", "localnet", "workgroup", "domain", "example.com"))
# Words of a client / location / note that are too generic to be treated as identifying tokens.
GENERIC_WORDS = frozenset((
    "saint", "street", "road", "avenue", "square", "park", "school", "secondary", "primary",
    "national", "college", "community", "campus", "university", "institute", "academy", "ltd",
    "limited", "inc", "llc", "plc", "company", "group", "office", "offices", "hotel", "house",
    "centre", "center", "church", "parish", "junior", "senior", "infant", "infants", "girls",
    "boys", "staff", "student", "students", "guest", "guests", "wi-fi", "wifi", "wireless",
    "native", "lan", "vlan", "network", "networks", "main", "building", "floor", "design",
    "room", "server", "hall", "north", "south", "east", "west", "upper", "lower", "new", "old",
    "the", "and", "for", "test", "run", "site", "client", "unknown", "engineer", "default",
))

OCTET = r"(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
IPV4_RE = re.compile(r"(?<![0-9A-Za-z.])(" + OCTET + r"(?:\." + OCTET + r"){3})(?![0-9A-Za-z]|\.[0-9])")
IP_ONLY_RE = re.compile(r"^" + OCTET + r"(?:\." + OCTET + r"){3}$")
MAC_RE = re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})(?![0-9A-Fa-f:])")
DOMAIN_LINE_RE = re.compile(r"(Domain Name:\s*)([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)")
# Any other host-name-looking token in free text (nmap DHCP excerpts carry hostnames in
# options such as "TFTP Server Name:", "Hostname:", "Domain Search:", "Boot File Name:"):
# two or more labels, an alphabetic top-level label, surrounded by non-name characters.
FQDN_RE = re.compile(r"(?<![A-Za-z0-9./-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{1,23})(?![A-Za-z0-9.-])")  # a token after "/" is a path component, not a host
# Public / tooling domains that identify nobody, and the prefixes of already-hashed names.
KEEP_DOMAINS = frozenset(("nmap.org", "example.com", "example.net", "example.org", "speedtest.net",
                          "github.com", "apple.com", "ubnt.com", "ui.com", "home.arpa", "in-addr.arpa"))
HASHED_PREFIX_RE = re.compile(r"^(host|domain|isp|ssid)-[0-9a-f]{6}(\.|$)")
# A dotted token whose last label is one of these is a file name, not a host name.
FILE_EXTENSIONS = frozenset(("json", "txt", "pdf", "png", "sh", "py", "log", "csv", "html", "xml",
                             "md", "grep", "pcap", "version", "app", "nse", "plist", "icns", "swift",
                             "conf", "cfg", "cnf", "ini", "yml", "yaml", "toml", "env", "db", "sqlite",
                             "dmg", "pkg", "zip", "tar", "gz", "service"))
URL_HOST_RE = re.compile(r"(://)([^/:\s]+)")
DATE_RE = re.compile(r"-([0-9]{2}-[0-9]{2}-[0-9]{4})(?=-|$)")
REPORT_RE = re.compile(r"^(lss-network-tools-report-)(.+)-([0-9]{2}-[0-9]{2}-[0-9]{4})-([0-9]{2}-[0-9]{2})\.txt$")


# ----------------------------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------------------------

def sanitize_for_filename(value):
    """Port of the bash sanitize_for_filename(): lowercase; any char outside [a-z0-9._-] -> '-';
    collapse repeated '-'; trim one leading / trailing '-'; empty -> 'unknown'."""
    value = value.lower()
    value = re.sub(r"[^a-z0-9._-]", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    value = re.sub(r"^-", "", value)
    value = re.sub(r"-$", "", value)
    return value or "unknown"


def norm_text(s):
    """Normalisation used for hashing names / hosts: lowercase, whitespace collapsed."""
    return " ".join(s.lower().split())


def hnorm(s):
    """Normalisation shared with the leak list: lowercase, every run of non-[a-z0-9] -> one space."""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", s.lower()).split())


def is_netmask(addr_int):
    inv = (~addr_int) & 0xFFFFFFFF
    return (inv & (inv + 1)) == 0


def classify_ip(text):
    """'keep' for addresses that must stay verbatim, 'public' for addresses to be mapped,
    None when the text is not a valid dotted quad."""
    try:
        addr = ipaddress.IPv4Address(text)
    except (ipaddress.AddressValueError, ValueError):
        return None
    if text in KEEP_ADDRESSES or is_netmask(int(addr)):
        return "keep"
    for net in KEEP_NETWORKS:
        if addr in net:
            return "keep"
    return "public"


def today_iso():
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch:
        return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).date().isoformat()
    return datetime.date.today().isoformat()


def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def dump_json(obj, path):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, indent=2, ensure_ascii=False))
        fh.write("\n")
    os.chmod(path, 0o644)


def assert_no_output_component(path):
    parts = os.path.normpath(os.path.abspath(path)).split(os.sep)
    if "output" in parts:
        raise SystemExit("refusing to write %s: a path component is named 'output', which the "
                         "repository .gitignore excludes" % path)


def read_text_for_scan(path, warn):
    """Return the scannable text of a file (None if unreadable). PDFs go through pdftotext."""
    if path.lower().endswith(".pdf"):
        exe = shutil.which("pdftotext")
        if not exe:
            warn("pdftotext not found; PDF text of %s was NOT checked" % path)
            return ""
        proc = subprocess.run([exe, "-layout", path, "-"], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        if proc.returncode != 0:
            warn("pdftotext failed on %s: %s" % (path, proc.stderr.decode("utf-8", "replace").strip()))
            return ""
        return proc.stdout.decode("utf-8", "replace")
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except OSError as exc:
        warn("cannot read %s: %s" % (path, exc))
        return None


def iter_scan_targets(root, warn):
    """Yield (relative path, what, text) for every directory name, file name and file content."""
    root = os.path.abspath(root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for d in dirnames:
            yield (os.path.relpath(os.path.join(dirpath, d), root), "name", d)
        for f in sorted(filenames):
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root)
            yield (rel, "name", f)
            text = read_text_for_scan(full, warn)
            if text:
                yield (rel, "content", text)


# ----------------------------------------------------------------------------------------------
# anonymiser state shared by all runs of one invocation
# ----------------------------------------------------------------------------------------------

class Anonymizer(object):
    def __init__(self, salt_hex):
        try:
            self.salt = binascii.unhexlify(salt_hex)
        except (binascii.Error, ValueError):
            raise SystemExit("--salt must be a hex string")
        if not self.salt:
            raise SystemExit("--salt must not be empty")
        self.salt_hex = salt_hex.lower()
        self.salt_is_default = (self.salt_hex == DEFAULT_SALT_HEX)
        self.plain_tokens = {}    # lower-case plaintext -> kind   (--check, never written to disk)
        self.hashed_tokens = {}   # hmac hex -> kind               (--leak-list)
        self._reverse = {}        # (prefix, hex6) -> normalised value, to detect collisions
        self.warnings = []

    def warn(self, msg):
        self.warnings.append(msg)
        print("  warning: %s" % msg, file=sys.stderr)

    def hmac_hex(self, text):
        return hmac.new(self.salt, text.encode("utf-8"), hashlib.sha256).hexdigest()

    def hex6(self, text, prefix=""):
        key = norm_text(text)
        digest = self.hmac_hex(key)[:6]
        previous = self._reverse.setdefault((prefix, digest), key)
        if previous != key:
            self.warn("hex6 collision for %r: two different values map to %s" % (prefix, digest))
        return digest

    def remember(self, plain, kind, hashed=True, words=False):
        """Register an original value for the leak checks."""
        low = plain.strip().lower()
        if not low or low in SENTINELS:
            return
        self.plain_tokens.setdefault(low, kind)
        if hashed:
            hn = hnorm(low)
            if hn:
                self.hashed_tokens.setdefault(self.hmac_hex(hn), kind)
        if words:
            for word in re.split(r"\s+", low):
                word = word.strip(".,;:()[]{}'\"")
                if len(word) >= 4 and word not in GENERIC_WORDS and not word.isdigit():
                    self.plain_tokens.setdefault(word, "word")
                    hw = hnorm(word)
                    if hw:
                        self.hashed_tokens.setdefault(self.hmac_hex(hw), "word")

    def max_ngram(self):
        """Longest hashed token in words (IPs and MACs are not hashed, so they do not count)."""
        longest = 1
        for token, kind in self.plain_tokens.items():
            if kind in ("ip", "mac"):
                continue
            longest = max(longest, len(hnorm(token).split(" ")))
        return longest


# ----------------------------------------------------------------------------------------------
# per-run string transformer
# ----------------------------------------------------------------------------------------------

class RunTransformer(object):
    def __init__(self, anon, token_pairs):
        self.anon = anon
        self.ip_map = {}
        self.ip_used = set()
        self.mac_cache = {}
        self.counts = {"tokens": 0, "domains": 0, "macs": 0, "ips": 0, "hosts": 0}
        pairs = {}
        for value, replacement in token_pairs:
            key = norm_text(value)
            if len(key) < 3 or key in SENTINELS:
                continue
            if key in pairs and pairs[key] != replacement:
                anon.warn("token %r has two replacements; keeping %r" % (key, pairs[key]))
                continue
            pairs[key] = replacement
        self.token_map = pairs
        if pairs:
            alternatives = []
            for key in sorted(pairs, key=len, reverse=True):
                alternatives.append(r"\s+".join(re.escape(w) for w in key.split(" ")))
            self.token_re = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(alternatives) + r")(?![A-Za-z0-9])",
                                       re.IGNORECASE)
        else:
            self.token_re = None

    # -- pass 1: public IP inventory ---------------------------------------------------------

    def collect_public_ips(self, obj, acc):
        if isinstance(obj, dict):
            for v in obj.values():
                self.collect_public_ips(v, acc)
        elif isinstance(obj, list):
            for v in obj:
                self.collect_public_ips(v, acc)
        elif isinstance(obj, str):
            for m in IPV4_RE.finditer(obj):
                if classify_ip(m.group(1)) == "public":
                    acc.add(m.group(1))

    def allocate_ips(self, public_ips):
        """Assign TEST-NET addresses in numeric order (deterministic for a given set). The
        original last octet is kept whenever it is still free so that network / gateway / host
        relationships of a public LAN survive; otherwise a HMAC-derived slot is probed."""
        for ip in sorted(set(public_ips) - set(self.ip_map), key=lambda t: int(ipaddress.IPv4Address(t))):
            last = ip.rsplit(".", 1)[1]
            candidate = None
            for pool in TEST_NET_POOLS:              # keep the last octet when it is free
                c = pool + last
                if c not in self.ip_used:
                    candidate = c
                    break
            if candidate is None:                    # otherwise a deterministic probe
                start = int(self.anon.hmac_hex("ip:" + ip)[:8], 16)
                for pool in TEST_NET_POOLS:
                    for k in range(256):
                        slot = (start + k) % 256
                        if slot in (0, 255):
                            continue
                        c = pool + str(slot)
                        if c not in self.ip_used:
                            candidate = c
                            break
                    if candidate is not None:
                        break
            if candidate is None:
                raise SystemExit("more distinct public IPv4 addresses than TEST-NET can hold")
            self.ip_used.add(candidate)
            self.ip_map[ip] = candidate
            self.anon.remember(ip, "ip", hashed=False)

    # -- pass 2: rewriting -------------------------------------------------------------------

    def transform(self, obj, key=None, fname=""):
        if isinstance(obj, dict):
            return dict((k, self.transform(v, k, fname)) for k, v in obj.items())
        if isinstance(obj, list):
            return [self.transform(v, key, fname) for v in obj]
        if isinstance(obj, str):
            return self.transform_string(obj, key, fname)
        return obj

    def transform_string(self, s, key, fname):
        host_keys = HOST_KEYS | FILE_HOST_KEYS.get(fname, frozenset())
        if key in host_keys or key in HOST_LIST_KEYS:
            return self.hash_hostlike(s, "host")
        if key in ISP_KEYS:
            return self.hash_hostlike(s, "isp")
        if key in SSID_KEYS:
            return self.hash_hostlike(s, "ssid")
        if key == "inform_url":
            s = URL_HOST_RE.sub(lambda m: m.group(1) + self.hash_hostlike(m.group(2), "host"), s)
        return self.generic(s)

    def hash_hostlike(self, s, prefix):
        stripped = s.strip()
        low = stripped.lower()
        if low in SENTINELS:
            return s
        if IP_ONLY_RE.match(stripped):           # an IP stored in a hostname field: IP rule instead
            return self.generic(s)
        suffix = ".local" if low.endswith(".local") else ""
        kind = {"host": "hostname", "isp": "isp", "ssid": "ssid"}[prefix]
        self.anon.remember(stripped, kind)
        self.counts["hosts"] += 1
        return "%s-%s%s" % (prefix, self.anon.hex6(stripped, prefix), suffix)

    def generic(self, s):
        if self.token_re is not None:
            s, n = self.token_re.subn(self._repl_token, s)
            self.counts["tokens"] += n
        s = DOMAIN_LINE_RE.sub(self._repl_domain, s)
        s = FQDN_RE.sub(self._repl_fqdn, s)
        s = MAC_RE.sub(self._repl_mac, s)
        s = IPV4_RE.sub(self._repl_ip, s)
        return s

    def _repl_fqdn(self, m):
        """Hash a host-name-looking token found anywhere in free text -> host-<hex6>.<tld>."""
        token = m.group(1)
        low = token.lower()
        labels = low.split(".")
        if low in GENERIC_DOMAINS or low in KEEP_DOMAINS or HASHED_PREFIX_RE.match(low):
            return token
        if labels[-1] in FILE_EXTENSIONS or IP_ONLY_RE.match(token):
            return token
        if not any(ch.isalpha() for ch in labels[0]):      # version numbers such as 7.98a
            return token
        if all(label in GENERIC_DOMAINS for label in labels):
            return token
        self.anon.remember(token, "hostname")
        for label in labels[:-1]:
            if len(label) >= 4 and label not in GENERIC_WORDS:
                self.anon.remember(label, "domain-label")
        self.counts["hosts"] += 1
        return "host-%s.%s" % (self.anon.hex6(token, "host"), labels[-1])

    def _repl_token(self, m):
        return self.token_map.get(norm_text(m.group(1)), m.group(1))

    def _repl_domain(self, m):
        domain = m.group(2)
        if domain.lower() in GENERIC_DOMAINS:
            return m.group(0)
        labels = domain.split(".")
        digest = self.anon.hex6(domain, "domain")
        if len(labels) >= 2:
            replacement = "domain-%s.%s" % (digest, labels[-1])
            identifying = labels[:-1]
        else:
            replacement = "domain-%s" % digest
            identifying = labels
        self.anon.remember(domain, "domain")
        for label in identifying:
            if len(label) >= 4 and label.lower() not in GENERIC_WORDS:
                self.anon.remember(label, "domain-label")
        self.counts["domains"] += 1
        return m.group(1) + replacement

    def _repl_mac(self, m):
        mac = m.group(1)
        low = mac.lower()
        if low in ("ff:ff:ff:ff:ff:ff", "00:00:00:00:00:00"):
            return mac
        new = self.mac_cache.get(low)
        if new is None:
            tail = self.anon.hmac_hex("mac:" + low)[:6]
            new = low[:9] + ":".join(tail[i:i + 2] for i in (0, 2, 4))
            self.mac_cache[low] = new
            self.anon.remember(low, "mac", hashed=False)
            self.counts["macs"] += 1
        return new.upper() if mac != low else new

    def _repl_ip(self, m):
        ip = m.group(1)
        new = self.ip_map.get(ip)
        if new is None:
            if classify_ip(ip) != "public":
                return ip
            # Not seen by the inventory pass (should not happen); never let it through verbatim.
            self.anon.warn("public IP %s was not in the inventory; allocated on the fly" % ip)
            self.allocate_ips([ip])
            new = self.ip_map[ip]
        self.counts["ips"] += 1
        return new


# ----------------------------------------------------------------------------------------------
# name rebuilding
# ----------------------------------------------------------------------------------------------

def rebuild_run_dir_name(old_basename, old_slugs, new_slugs, generated_at, warn):
    old_client, old_location, old_note = old_slugs
    new_client, new_location, new_note = new_slugs
    m = DATE_RE.search(old_basename)
    if m:
        date = m.group(1)
        tail = old_basename[m.end():]
        if old_basename[:m.start()] != old_client + "-" + old_location:
            warn("run directory %r does not start with the manifest slugs; rebuilt from the date part" % old_basename)
    else:
        warn("run directory %r has no dd-mm-yyyy part; using generated_at" % old_basename)
        date = (generated_at or "").split(" ")[0] or "00-00-0000"
        tail = ""
    if old_note and new_note:
        if tail.startswith("-" + old_note):
            tail = "-" + new_note + tail[len(old_note) + 1:]
        else:
            warn("note slug %r not found after the date in %r" % (old_note, old_basename))
    return "%s-%s-%s%s" % (new_client, new_location, date, tail)


def rebuild_report_name(old_report, new_client, new_location, generated_at, warn):
    m = REPORT_RE.match(old_report or "")
    if m:
        return "%s%s-%s-%s-%s.txt" % (m.group(1), new_client, new_location, m.group(3), m.group(4))
    if old_report:
        warn("report_file %r does not follow the expected pattern; rebuilt from generated_at" % old_report)
    date, _, hhmm = (generated_at or "").partition(" ")
    return "lss-network-tools-report-%s-%s-%s-%s.txt" % (
        new_client, new_location, date or "00-00-0000", (hhmm or "00:00").replace(":", "-"))


# ----------------------------------------------------------------------------------------------
# one run
# ----------------------------------------------------------------------------------------------

def process_run(anon, src_dir, dest_root, opts):
    src_dir = os.path.abspath(os.path.normpath(src_dir))
    src_base = os.path.basename(src_dir)
    if not os.path.isdir(src_dir):
        raise SystemExit("--src %s is not a directory" % src_dir)
    manifest_path = os.path.join(src_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise SystemExit("%s has no manifest.json (the anonymiser needs client/location/note)" % src_dir)
    if not os.access(manifest_path, os.R_OK):
        raise SystemExit("%s is not readable" % manifest_path)
    manifest = load_json(manifest_path)

    client = str(manifest.get("client") or "")
    location = str(manifest.get("location") or "")
    note = str(manifest.get("note") or "")
    prepared_by = str(manifest.get("prepared_by") or "")
    generated_at = str(manifest.get("generated_at") or "")

    new_client = "Client %s" % anon.hex6(client, "client")
    new_location = "Site %s" % anon.hex6(location, "site")
    new_note = ("note-%s" % anon.hex6(note, "note")) if note.strip() else ""

    old_slugs = (sanitize_for_filename(client), sanitize_for_filename(location),
                 sanitize_for_filename(note) if note.strip() else "")
    new_slugs = (sanitize_for_filename(new_client), sanitize_for_filename(new_location),
                 sanitize_for_filename(new_note) if new_note else "")

    # Tokens replaced everywhere (names + slug forms) and remembered for the leak checks.
    token_pairs = []
    for value, replacement, kind in ((client, new_client, "client"), (location, new_location, "location"),
                                     (note, new_note, "note"), (prepared_by, PREPARED_BY, "prepared_by")):
        if not value.strip() or norm_text(value) in SENTINELS:
            continue
        token_pairs.append((value, replacement))
        anon.remember(value, kind, words=True)
        slug = sanitize_for_filename(value)
        if slug != "unknown" and len(slug) >= 3:
            token_pairs.append((slug, sanitize_for_filename(replacement)))
            anon.remember(slug, kind + "-slug")

    new_base = rebuild_run_dir_name(src_base, old_slugs, new_slugs, generated_at, anon.warn)
    old_report = str(manifest.get("report_file") or "")
    new_report = rebuild_report_name(old_report, new_slugs[0], new_slugs[1], generated_at, anon.warn)

    # Inventory of the source directory.
    json_names, unreadable, dropped, raw_count = [], [], [], 0
    for name in sorted(os.listdir(src_dir)):
        full = os.path.join(src_dir, name)
        if os.path.isdir(full):
            if name == "raw":
                raw_count = sum(len(files) for _, _, files in os.walk(full))
            dropped.append(name + "/")
            continue
        if name == "provenance.json":
            continue
        if name.lower().endswith(".json"):
            if not os.access(full, os.R_OK):
                unreadable.append(name)
            else:
                json_names.append(name)
            continue
        # Anything else is free text or binary and is not copied. Record what was dropped
        # without ever writing an original (name-bearing) filename into the fixture.
        if name == old_report:
            dropped.append(new_report)
        elif name == "debug.txt":
            dropped.append(name)
        else:
            dropped.append("<other>" + (os.path.splitext(name)[1].lower() or ""))
    if unreadable and not opts.skip_unreadable:
        raise SystemExit("unreadable files in %s: %s (re-run with --skip-unreadable, or chmod 644 them)"
                         % (src_dir, ", ".join(unreadable)))

    documents, unparseable = {}, []
    for name in json_names:
        try:
            documents[name] = load_json(os.path.join(src_dir, name))
        except (ValueError, UnicodeDecodeError) as exc:
            anon.warn("%s/%s is not valid JSON and was skipped: %s" % (src_base, name, exc))
            unparseable.append(name)

    # Manifest: explicit fields first, then the generic walk like every other file.
    manifest_out = json.loads(json.dumps(manifest))
    manifest_out["client"] = new_client
    manifest_out["location"] = new_location
    manifest_out["note"] = new_note
    manifest_out["prepared_by"] = PREPARED_BY
    manifest_out["run_directory"] = new_base
    manifest_out["report_file"] = new_report
    for artifact in manifest_out.get("artifacts") or []:
        if isinstance(artifact, dict) and artifact.get("path") == old_report and old_report:
            artifact["path"] = new_report
    documents["manifest.json"] = manifest_out

    transformer = RunTransformer(anon, token_pairs)
    public_ips = set()
    for doc in documents.values():
        transformer.collect_public_ips(doc, public_ips)
    transformer.allocate_ips(public_ips)

    outputs = dict((name, transformer.transform(doc, None, name)) for name, doc in documents.items())

    # Destination.
    dest_run = os.path.join(os.path.abspath(dest_root), new_base)
    assert_no_output_component(dest_run)
    if os.path.exists(dest_run):
        if not os.path.isfile(os.path.join(dest_run, "provenance.json")):
            raise SystemExit("refusing to replace %s: it has no provenance.json, so it is not an "
                             "anonymised fixture" % dest_run)
        shutil.rmtree(dest_run)
    os.makedirs(dest_run)

    for name in sorted(outputs):
        dump_json(outputs[name], os.path.join(dest_run, name))

    pdf_name = None
    pdf_error = None
    if opts.pdf:
        pdf_name = os.path.splitext(new_report)[0] + ".pdf"
        pdf_error = generate_pdf(opts.pdf, dest_run, pdf_name)
        if pdf_error:
            pdf_name = None

    task_count = len(manifest.get("tasks") or [])
    provenance = {
        "anonymizer": ANONYMIZER_NAME,
        "anonymizer_version": ANONYMIZER_VERSION,
        "generated_on": today_iso(),
        "salt": "default" if anon.salt_is_default else "custom",
        "source_run_hmac": anon.hmac_hex("run:" + src_base)[:16],
        "manifest_task_count": task_count,
        "files": sorted(outputs) + ([pdf_name] if pdf_name else []),
        "skipped_unreadable": unreadable,
        "skipped_unparseable": unparseable,
        "dropped": sorted(set(dropped)),
        "raw_files_dropped": raw_count,
        "public_ips_mapped": len(transformer.ip_map),
        "macs_mapped": len(transformer.mac_cache),
        "hostnames_hashed": transformer.counts["hosts"],
        "domains_hashed": transformer.counts["domains"],
        "pdf": pdf_name,
    }
    dump_json(provenance, os.path.join(dest_run, "provenance.json"))

    return {
        "src_base": src_base, "dest_run": dest_run, "new_base": new_base,
        "task_count": task_count, "written": sorted(outputs), "unreadable": unreadable,
        "unparseable": unparseable, "dropped": sorted(set(dropped)), "raw_count": raw_count,
        "counts": transformer.counts, "ip_map_size": len(transformer.ip_map),
        "pdf": pdf_name, "pdf_error": pdf_error,
    }


def generate_pdf(app_root, dest_run, pdf_name):
    """Run generate_pdf_report.py for the anonymised run. Returns an error string or None."""
    generator = os.path.join(app_root, PDF_GENERATOR)
    if not os.path.isfile(generator):
        return "%s not found" % generator
    python = sys.executable
    for candidate in PDF_PYTHON_CANDIDATES:
        if os.path.isfile(candidate):
            python = candidate
            break
    pdf_path = os.path.join(dest_run, pdf_name)
    cmd = [python, generator, dest_run, app_root, pdf_path, PREPARED_BY]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0 or not os.path.isfile(pdf_path):
        return "PDF generation failed (%s): %s" % (" ".join(cmd), proc.stderr.decode("utf-8", "replace").strip())
    os.chmod(pdf_path, 0o644)
    return None


# ----------------------------------------------------------------------------------------------
# leak checks
# ----------------------------------------------------------------------------------------------

def plain_scan(root, plain_tokens, warn):
    """Case-insensitive plaintext search for every original token. Short single words use word
    boundaries (so 'mary' does not fire on 'primary'); everything else is a substring search (so
    'kevins' fires on 'stkevins')."""
    compiled = []
    for token, kind in sorted(plain_tokens.items()):
        if len(token) < 4:
            continue
        if kind == "word" and len(token) <= 5:
            pattern = re.compile(r"(?<![a-z0-9])" + re.escape(token) + r"(?![a-z0-9])")
        else:
            pattern = re.compile(re.escape(token))
        compiled.append((token, kind, pattern))
    leaks = []
    for rel, what, text in iter_scan_targets(root, warn):
        low = text.lower()
        for token, kind, pattern in compiled:
            if pattern.search(low):
                leaks.append((rel, what, kind, token))
    return leaks


def hashed_scan(root, salt, hashed_tokens, max_ngram, warn):
    """The rule a Swift test can apply with only the committed leak list: hash every 1..N-gram of
    the normalised text and look it up."""
    leaks = []
    for rel, what, text in iter_scan_targets(root, warn):
        words = hnorm(text).split(" ") if text.strip() else []
        for n in range(1, max_ngram + 1):
            for i in range(0, len(words) - n + 1):
                candidate = " ".join(words[i:i + n])
                digest = hmac.new(salt, candidate.encode("utf-8"), hashlib.sha256).hexdigest()
                kind = hashed_tokens.get(digest)
                if kind is not None:
                    leaks.append((rel, what, kind, candidate))
    return leaks


def ip_scan(root, warn):
    """Structural rule: no public IPv4 literal may survive anywhere in the fixture tree."""
    leaks = []
    for rel, what, text in iter_scan_targets(root, warn):
        for m in IPV4_RE.finditer(text):
            if classify_ip(m.group(1)) == "public":
                leaks.append((rel, what, "public-ip", m.group(1)))
    return leaks


def report_leaks(label, leaks):
    """Print each distinct leak once. The leaked text is printed in full: this runs on the
    machine that holds the real data, and the operator needs to see what escaped."""
    seen = set()
    for rel, what, kind, token in leaks:
        key = (rel, what, kind, token)
        if key in seen:
            continue
        seen.add(key)
        print("  LEAK [%s] %s in %s (%s): %r" % (label, kind, rel, what, token))
    return len(seen)


# ----------------------------------------------------------------------------------------------
# leak list file
# ----------------------------------------------------------------------------------------------

LEAK_LIST_HEADER = """\
# lss-network-tools fixture leak list -- written by {name} v{version}
#
# Each non-comment line is:  <hmac-sha256 hex>  <kind>
# where the digest is HMAC-SHA256(key = the salt below, message = the NORMALISED original token).
# Normalisation: lowercase; every run of characters outside [a-z0-9] becomes a single space; trim.
# A token has leaked if any 1..N-gram (N = max-ngram) of the normalised text of ANY file or path
# name under macos/Tests/Fixtures/runs hashes to a listed value. Hashes are listed (not plaintext)
# so that the original client names never enter the repository.
#
# IPv4 and MAC addresses are deliberately NOT listed: their hashes would be brute-forceable.
# They are covered by the structural rule "no IPv4 literal outside RFC 1918 / 127/8 / 169.254/16 /
# 100.64/10 / 224/4 / TEST-NET / netmasks / 0.0.0.0 / 255.255.255.255 / well-known anycast
# resolvers may appear anywhere in the fixture tree", and by the plaintext --check that runs at
# generation time (anonymize-run.py --check), which also catches substrings inside longer words.
#
# salt-hex: {salt}
# max-ngram: {maxn}
"""


def read_leak_list(path):
    entries, salt_hex, maxn = {}, None, 1
    if not os.path.isfile(path):
        return entries, salt_hex, maxn
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                m = re.match(r"#\s*salt-hex:\s*([0-9a-fA-F]+)", line)
                if m:
                    salt_hex = m.group(1).lower()
                m = re.match(r"#\s*max-ngram:\s*([0-9]+)", line)
                if m:
                    maxn = int(m.group(1))
                continue
            parts = line.split()
            if len(parts) >= 1 and re.match(r"^[0-9a-f]{64}$", parts[0]):
                entries[parts[0]] = parts[1] if len(parts) > 1 else "token"
    return entries, salt_hex, maxn


def write_leak_list(path, anon):
    existing, existing_salt, existing_maxn = read_leak_list(path)
    if existing_salt and existing_salt != anon.salt_hex:
        raise SystemExit("%s was written with a different salt; delete it or use the same --salt" % path)
    merged = dict(existing)
    merged.update(anon.hashed_tokens)
    maxn = max(existing_maxn, anon.max_ngram(), 1)
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(LEAK_LIST_HEADER.format(name=ANONYMIZER_NAME, version=ANONYMIZER_VERSION,
                                         salt=anon.salt_hex, maxn=maxn))
        for digest in sorted(merged):
            fh.write("%s %s\n" % (digest, merged[digest]))
    return len(merged), maxn


# ----------------------------------------------------------------------------------------------
# entry points
# ----------------------------------------------------------------------------------------------

def verify_mode(args):
    entries, salt_hex, maxn = read_leak_list(args.verify_leak_list)
    if not entries:
        raise SystemExit("%s has no entries" % args.verify_leak_list)
    salt_hex = args.salt if args.salt != DEFAULT_SALT_HEX else (salt_hex or DEFAULT_SALT_HEX)
    anon = Anonymizer(salt_hex)
    print("Verifying %s against %d hashed tokens (max n-gram %d) and the public-IPv4 rule"
          % (args.dest, len(entries), maxn))
    leaks = hashed_scan(args.dest, anon.salt, entries, maxn, anon.warn) + ip_scan(args.dest, anon.warn)
    count = report_leaks("verify", leaks)
    if count:
        print("FAILED: %d leak(s)" % count)
        return 1
    print("OK: no leaks")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog=ANONYMIZER_NAME,
        description="Anonymise lss-network-tools run directories into committed test fixtures.",
        epilog="The rules are documented in the header comment of this script and in macos/docs/PLAN.md section 6.")
    parser.add_argument("--src", action="append", default=[], metavar="RUN_DIR",
                        help="real run directory (repeatable)")
    parser.add_argument("--dest", metavar="FIXTURES_ROOT",
                        help="directory that receives one anonymised run directory per --src")
    parser.add_argument("--salt", default=DEFAULT_SALT_HEX, metavar="HEX",
                        help="HMAC salt as hex (default is public and documented in the script)")
    parser.add_argument("--pdf", metavar="APP_ROOT",
                        help="regenerate the PDF with APP_ROOT/generate_pdf_report.py")
    parser.add_argument("--check", action="store_true",
                        help="after writing, scan the destination runs for leaks and exit 1 on any")
    parser.add_argument("--skip-unreadable", action="store_true",
                        help="skip source files that cannot be read (e.g. 0600 root-owned) instead of failing")
    parser.add_argument("--leak-list", metavar="FILE",
                        help="write/merge the hashed token list used by --verify-leak-list and the Swift test")
    parser.add_argument("--verify-leak-list", metavar="FILE",
                        help="only scan --dest with the hashed list in FILE (no --src needed)")
    parser.add_argument("--source-id", nargs="+", default=[], metavar="RUN_DIR",
                        help="print the source_run_hmac that provenance.json records for each RUN_DIR and exit")
    args = parser.parse_args(argv)

    if args.source_id:
        anon = Anonymizer(args.salt)
        for run_dir in args.source_id:
            base = os.path.basename(os.path.normpath(run_dir))
            print("%s  %s" % (anon.hmac_hex("run:" + base)[:16], base))
        return 0
    if not args.dest:
        parser.error("--dest is required")
    if args.verify_leak_list:
        return verify_mode(args)
    if not args.src:
        parser.error("--src is required (repeatable) unless --verify-leak-list is given")

    anon = Anonymizer(args.salt)
    assert_no_output_component(args.dest)
    os.makedirs(args.dest, exist_ok=True)

    results = []
    for src in args.src:
        results.append(process_run(anon, src, args.dest, args))

    exit_code = 0
    print("anonymize-run.py v%s  salt=%s" % (ANONYMIZER_VERSION, "default (public)" if anon.salt_is_default else "custom"))
    for r in results:
        c = r["counts"]
        shown = os.path.relpath(r["dest_run"])
        if shown.startswith(".."):
            shown = r["dest_run"]
        print("== source %s -> %s" % (anon.hmac_hex("run:" + r["src_base"])[:16], shown))
        print("   manifest tasks: %d   json written: %d   unreadable skipped: %s   unparseable: %s"
              % (r["task_count"], len(r["written"]), ", ".join(r["unreadable"]) or "-",
                 ", ".join(r["unparseable"]) or "-"))
        print("   replaced: %d name tokens, %d public IPs (%d occurrences), %d MACs, %d hostnames, %d domains"
              % (c["tokens"], r["ip_map_size"], c["ips"], c["macs"], c["hosts"], c["domains"]))
        print("   dropped (not copied): %s%s" % (", ".join(r["dropped"]) or "-",
                                                  " (%d files under raw/)" % r["raw_count"] if r["raw_count"] else ""))
        if r["pdf"]:
            print("   pdf: %s" % r["pdf"])
        if r["pdf_error"]:
            print("   PDF ERROR: %s" % r["pdf_error"])
            exit_code = 1

    if args.leak_list:
        count, maxn = write_leak_list(args.leak_list, anon)
        print("leak list: %s (%d hashed tokens, max n-gram %d)" % (args.leak_list, count, maxn))

    if args.check:
        total = 0
        files_scanned = 0
        for r in results:
            files_scanned += sum(len(files) for _, _, files in os.walk(r["dest_run"]))
            leaks = (plain_scan(r["dest_run"], anon.plain_tokens, anon.warn)
                     + ip_scan(r["dest_run"], anon.warn)
                     + hashed_scan(r["dest_run"], anon.salt, anon.hashed_tokens, anon.max_ngram(), anon.warn))
            total += report_leaks(r["new_base"], leaks)
        if total:
            print("check: FAILED -- %d leak(s) across %d file(s)" % (total, files_scanned))
            exit_code = 1
        else:
            print("check: OK -- %d plaintext tokens, %d hashed tokens, public-IPv4 rule; %d file(s) scanned"
                  % (len(anon.plain_tokens), len(anon.hashed_tokens), files_scanned))

    if anon.warnings:
        print("%d warning(s) (see stderr)" % len(anon.warnings))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
