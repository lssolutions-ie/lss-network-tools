# Synthetic v1.2.252 run (Tasks 4, 5, 6 with the DHCP/DNS detection fields)

`client-synthetic-site-dhcp-04-10-2026/` is one **fictional** run directory that carries every
optional field engine v1.2.252 added to the DHCP and DNS tasks, so the typed payloads, the
detail views and both PDF generators can be exercised before a real run with the new engine
exists. Nothing here describes a real network: addresses are RFC 1918 (`10.20.x`, `10.99.x`,
`192.168.8.x`) or TEST-NET-3, MACs are locally administered or arbitrary device parts, the
domain is `lab.lan`.

| File | What it carries |
|---|---|
| `dhcp-scan.json` | `probe_mac`/`probe_mac_source`, `attempts_failed`, `system_lease`, `dns_servers_offered`, `reply_sources_seen` (`{ip, mac}`), `relay_agents_seen` (+ the `relay_sources_seen` alias), `passive_servers_seen`, `capture_message_types`; per server `offered_router`/`offered_subnet_mask`/`offered_dns`/`offered_domain`/`lease_time_seconds`, `responder_mac`, `non_offer_replies`, `rogue_reasons` (one legitimate gateway, one rogue responder with three reasons). |
| `dhcp-response-time.json` | `servers_seen`, `multiple_responders`, `offered_*`, `receive_method: "bpf"`, `send_method: "layer2"`, `probe_mac`, `probe_options`, `interval_seconds`, `unexpected_servers`, `indicators.probe_inconsistent`/`server_mismatch`, one lost probe — **and `edited_at`**, the Edit Results stamp, so the Edited badge and the PDF marker render. |
| `dns-scan.json` | `scanned_range` + `range_truncated`; per server `sources`, `on_subnet`, `transport`; `resolution_test` with `attempts`, `rcode`, `ra`, `recursion` (all three states), `external_private_answer`, `internal_test`; one server with `resolution_test: null` (probe did not run) and one configured resolver outside the subnet. |
| `manifest.json` | per task `sha256` + `written_at`. Tasks 4 and 5 match their files; **Task 6's checksum is deliberately wrong** (a hand edit without the engine), which the loader reports as `.modifiedSinceRun`. |
| `findings.json`, `remediation.json` | three findings in the v1.2.252 wording, no hints. |

Regenerate with `python3 scripts/make-v252-fixture.py` (recomputes the checksums). Used by
`FixtureDecodingTests` (every file decodes), `FixtureLeakTests` (no public IPv4) and
`RunLoaderTests` ("v1.2.252 fixture: integrity states"). Render it with
`python3 generate_pdf_report.py macos/Tests/Fixtures/synthetic-v252/client-synthetic-site-dhcp-04-10-2026 . /tmp/x.pdf`.
