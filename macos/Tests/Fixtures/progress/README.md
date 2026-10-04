# Progress-stream fixtures

Hand-written pty captures of `lss-network-tools --run-task …` in non-interactive
mode, following `docs/research/06-m3-execution-contract.md` §1.2 (events) and the
human output style of the script (2-space-indented startup text, flush-left task
output, `[OK]      tool` checklist, braille spinners written with bare `\r`,
ANSI colours, CRLF line endings as a pty produces them).

**They are not real captures.** They were written before the bash side of M3
existed, from the contract alone. Once a root run of the real engine is
possible, capture it (`script -q capture.log sudo lss-network-tools --run-task …`
or the GUI's byte tap) and diff the `@@LSS` lines against these files; replace
them with the real stream if the two disagree, and update `ProgressLineParserTests`.

| File | Exercises |
|---|---|
| `full-audit.log` | sudo `Password:` line, `hello` with tasks 1–12, a `warning` (`interface_no_ip`), the startup checklist, `run_dir` (created), 12× `task_start`/`task_done` mixing `success` and `completed_with_warnings`, `task_stage` for the six stress stages of Task 10 (`baseline`, `jitter`, `large_packet`, `ramping`, `sustained`, `recovery`) and the two Task 11 steps, spinner frames (`\r`) overwritten by result lines, one event sharing a physical line with a spinner frame, `report_built`, `pdf_built`, `bye 0` |
| `single-task-17.log` | continue run: `run_dir` with `created:false`, Task 17 only, `warning` `task_17_helper_fallback`, `bye 0` |
| `consent-required.log` | `hello`, `error` `consent_required`, `bye 4` — nothing else (validation happens before the checklist) |
| `not-root.log` | checklist, `error` `not_root`, `bye 5` |
| `missing-deps.log` | checklist with `[MISSING]` rows, `error` `missing_dependencies` with `tools`, `bye 3` |
| `task-failed.log` | `task_done` with `failed` (Task 6) and `no_output` (Task 9, empty `json_files`), `pdf_failed`, `bye 1` |
| `real-task1-events.log` | **Real capture** (stderr only, LF endings): `sudo bash lss-network-tools.sh --run-task 1 --interface en0 --client … --location … 2>progress.log` on 2026-10-04 with v1.2.249; run-directory paths and client/location slugs anonymised, nothing else changed. Shows the extra `path` field on `report_built`/`pdf_built`. Pinned by `RealCaptureTests`. |

The real capture confirmed the hand-written streams' event names, field names and
ordering for `hello`, `run_dir`, `task_start`, `task_done`, `report_built`,
`pdf_built` and `bye`. The stress-stage, warning and error events are still only
covered by the hand-written files.

The files were produced by a throw-away Python generator and are meant to be
edited by hand or replaced with real captures — keep the CRLF endings and the
raw `\r` / ESC bytes (open them in an editor that does not normalise line
endings). `ProgressLineParserTests` pins their event counts, statuses, stage
keys and a handful of human lines, so update the tests with the files.
