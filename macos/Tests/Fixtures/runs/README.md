# Anonymised run fixtures

Every directory here is a real `lss-network-tools` run directory that went through
`macos/scripts/anonymize-run.py` (design: `macos/docs/PLAN.md` section 6). The fixtures are
**anonymised, not synthetic**: the JSON shapes, counts, ports, warnings, timings and private
addresses are exactly what the bash engine wrote; only identifying values were replaced.

## The rule

Nothing in this tree may identify a client, a site, a person, a public address or a device:

| What | Replacement |
|---|---|
| `client` / `location` / `note` / `prepared_by` | `Client <hex6>` / `Site <hex6>` / `note-<hex6>` (empty stays empty) / `Test Engineer`; the same real value always yields the same `<hex6>` (HMAC-SHA256 with a **private** salt, see below), so two runs for one client share a `client-…` prefix |
| run directory, `run_directory`, `report_file`, `artifacts[].path` | rebuilt from the new slugs with the bash `sanitize_for_filename` rules; date and `HH-MM` parts are the originals |
| public IPv4 literals (any string, any depth, DHCP excerpts included) | TEST-NET `203.0.113.0/24` (then `198.51.100.0/24`, `192.0.2.0/24`), keeping the original last octet when free so `network` / `gateway` / host relationships survive. RFC 1918, loopback, link-local, CGNAT, multicast, netmasks, `0.0.0.0`, `255.255.255.255` and well-known anycast resolvers (e.g. `8.8.8.8`) are kept |
| MAC addresses / BSSIDs | first three octets (OUI) kept so vendor strings stay truthful; last three hashed |
| `hostname`, `ptr_hostname`, `gateway_ptr`, `device_id`, `system_name`, `system_description`, `vtp_domain`, `test_server`, speed-test `location`, DNS `answers[]` | `host-<hex6>` (a `.local` suffix is kept); sentinels `unknown`, `--`, empty are kept |
| `isp_name` / `ssid` | `isp-<hex6>` / `ssid-<hex6>` (`(hidden)` kept) |
| `Domain Name: …` inside nmap DHCP excerpts | `domain-<hex6>.<tld>` (`localdomain` kept) |
| **any other host-name-looking token in free text** (e.g. `TFTP Server Name:`, `Hostname:`, `Domain Search:` in DHCP excerpts) | `host-<hex6>.<tld>`; tooling domains (`nmap.org`, `example.com`, …), version numbers and file names are left alone |
| `vendor`, `vendors[]`, `model`, interface names, ports, metrics | untouched |
| `debug.txt`, `raw/`, the TXT report, the original PDF | **not copied** (free text) |

Each fixture carries a `provenance.json` (anonymiser version, generation date, `source_run_hmac`
= HMAC of the real directory name, files written, files skipped, files dropped). Note that the
manifest is otherwise left faithful: a `tasks[]` entry may say `json_present: true` for a file
that was skipped as unreadable (see below), which is a real-world state the GUI must tolerate.

## The salt is private

The anonymiser hashes with HMAC-SHA256. The salt is **not** in the repository: with a public
salt anyone could confirm a guessed client or site name against the `client-…`/`site-…` slugs
(24 bits each) — an oracle, even without plaintext. The maintainer keeps the salt in
`~/.config/lss-network-tools/fixture-salt.hex` (0600; created with `openssl rand -hex 32`) and
passes it with `--salt`. Regenerating on another machine with another salt simply produces
different (equally meaningless) slugs; the shapes are identical.

## Fixtures

| Fixture directory | Shape generation | `source_run_hmac` | Task JSON present | Skipped (unreadable 0600) | Extra |
|---|---|---|---|---|---|
| `client-5b1fab-site-a86304-27-03-2026` | oldest: 17-task manifest, no `smb_signing_required`, no `isp_name` / `subnet_utilization`; the LAN itself is a public /25, now `203.0.113.0/25` | `7066511e4a9fd683` | 1, 2, 4, 5, 6, 7, 8, 9, 12 (+ `findings.json`, `remediation.json`) | none | DHCP excerpt with a hashed `Domain Name` |
| `client-58566a-site-dc14c8-31-03-2026` | 18-task manifest, `smb_signing_required` present, `prepared_by` was set | `ba2771cef03f9599` | 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12 | `gateway-stress-test-device-1.json` | NFS / JetDirect / SMB-signing findings, `8.8.8.8` kept in the DHCP excerpt |
| `client-5b1fab-site-2c5a22-02-04-2026` | 18-task manifest, trunk port detected (`observed_vlan_ids`), same client as the 27-03 run | `54f44539c4ea2da5` | 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12 | `gateway-stress-test-device-1.json` | `status: success` with a non-empty `warnings[]` (hazard 6) |
| `client-5db93c-site-b1cbd8-11-06-2026-note-0111c5` | newest: 20-task manifest, `isp_name`, `subnet_utilization`, `indicators.high_utilization`, non-empty `note` | `46fb5db12b29b51c` | 1, 2, 3, 4, 5, 6, 7, 8, 9, 11 | none | regenerated **PDF** (`lss-network-tools-report-…-12-20.pdf`), 100 % DHCP loss on Wi-Fi |
| `client-5db93c-site-b1cbd8-11-06-2026-note-4584d8` | newest generation, second run for the same client/site on the same day (different note) | `0058f59bac80448b` | 1, 2, 3, 4, 5, 6, 7, 8, 9, 11 | none | no PDF copied (the fixture above already carries one) |
| `client-1351c4-site-546ec1-23-03-2026-note-ae952a` | 17-task manifest with a non-empty `note`; Task 12 reported `total_hosts_seen: 0` with `success` (old arp-scan bug) | `28ae3cf4c6e72df2` | 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12 | `gateway-stress-test-device-1.json` | hashed DHCP `Domain Name` and `TFTP Server Name` |

All six real runs on the development Mac are represented. The four stress-test files could not be
read: older CLI versions wrote them `0600 root` (research 03, hazard 1) and the anonymiser runs
without sudo. Task 10 decoding is covered by synthetic fixtures instead. No real run contains
tasks 13–20 (see `../synthetic/` and `../synthetic-run/`).

## Leak checks

* `anonymize-run.py --check` (run at generation time, where the plaintext is available) searches
  every file and path name of each fixture for every original name, slug, distinctive word, public
  IP, MAC, hostname, domain and SSID (PDF text via `pdftotext`), applies the structural rule
  "no public IPv4 literal anywhere", and fails on any hit.
* `FixtureLeakTests` (Swift Testing, runs with `make test`, needs no secret) re-applies the
  structural rules to the committed tree: no public IPv4 literal in any fixture JSON (real,
  synthetic, assembled), no raw host-name-looking token in the real runs (everything dotted must
  be a `host-`/`domain-`/`isp-`/`ssid-` replacement, a generic domain or a tooling domain), and
  fixture/report names made only of hashed slugs and dates.
* A plain `grep` sweep for `\.(local|lan|ie|com|net|org)` tokens is a good habit after regenerating.

## How these were generated

Run on the machine that holds the real runs (`/usr/local/share/lss-network-tools/output/`) and the
private salt. The real directory names are not written here because they contain the client
names; map them with `--source-id`, which prints the `source_run_hmac` used in `provenance.json`:

```sh
cd macos
SALT="$(cat ~/.config/lss-network-tools/fixture-salt.hex)"
SRC=/usr/local/share/lss-network-tools/output
python3 scripts/anonymize-run.py --salt "$SALT" --source-id "$SRC"/*      # which real run is which fixture

rm -rf Tests/Fixtures/runs/client-*
# five runs without a PDF
python3 scripts/anonymize-run.py --salt "$SALT" --dest Tests/Fixtures/runs --skip-unreadable --check \
  --src "$SRC/<run>" --src "$SRC/<run>" --src "$SRC/<run>" --src "$SRC/<run>" --src "$SRC/<run>"
# the newest run, with a regenerated PDF (fpdf2 must be installed for /opt/homebrew/bin/python3)
python3 scripts/anonymize-run.py --salt "$SALT" --dest Tests/Fixtures/runs --skip-unreadable --check \
  --pdf /usr/local/share/lss-network-tools --src "$SRC/<run with source_run_hmac 46fb5db12b29b51c>"
python3 scripts/make-synthetic-run.py        # rebuild the assembled 20-task run from the new fixtures
```

Regenerating with the same salt is idempotent: names, hashes and IP mappings come out identical;
only `provenance.json`'s `generated_on` changes (set `SOURCE_DATE_EPOCH` to pin it). An existing
fixture directory is replaced only if it contains a `provenance.json`. The script refuses to
create any directory named `output`, which the repository `.gitignore` excludes. Never commit
`debug.txt`, `raw/`, TXT reports or an original PDF.
