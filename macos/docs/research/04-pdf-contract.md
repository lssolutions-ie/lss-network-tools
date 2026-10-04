# Research: PDF generation contract

From `lss-network-tools.sh` v1.2.246 (worktree) and both Python generators. The installed CLI is v1.2.245, whose generators are older (Task 20 not rendered, Task 10 first file only, Latin-1 sanitising, tracebacks on error, compare pairs by index).

## 1. `generate_pdf_report()` (L3760–3790)

```bash
py_script="$APP_ROOT/generate_pdf_report.py"
pdf_path="${RUN_REPORT_FILE%.txt}.pdf"      # PDF = TXT path with .pdf
pdf_err="$(python3 "$py_script" "$RUN_OUTPUT_DIR" "$APP_ROOT" "$pdf_path" "${RUN_PREPARED_BY:-}" 2>&1 >/dev/null || true)"
```

- Arguments: `run_dir app_root pdf_path prepared_by`. stdout discarded, stderr captured.
- Preconditions (each failure returns 0): `RUN_OUTPUT_DIR` empty → silent; no `python3` → silent; `python3 -c "import fpdf"` fails → prints `PDF generation skipped: fpdf2 not installed (pip3 install fpdf2)`; script missing → silent; `manifest.json` missing → silent.
- Success is judged by `[[ -f "$pdf_path" ]]` (a stale PDF looks like success). Prints `  PDF report:    <path>` or `  PDF generation failed: <stderr>`. Always returns 0.
- Call sites: Build A Report (L1821), Save Run & Exit (L11912), main-loop "Save report?" (L12450, after `finalize_run`).
- New-run PDF path: `$RUN_OUTPUT_DIR/lss-network-tools-report-{client}-{location}-{dd-mm-yyyy}-{HH-MM}.pdf`.

### Compare PDF — `build_compare_report_for_run_dir` (L2860–2955)

```bash
pdf_path="$export_dir/lss-compare-$(date '+%d-%m-%Y-%H-%M').pdf"
python3 "$APP_ROOT/generate_pdf_compare_report.py" "$run_dir_a" "$run_dir_b" "$pdf_path" "$APP_ROOT"
```
Different argument order. No python3/manifest check; `mkdir -p` export dir; `PDF saved: <path>` / `PDF generation failed: <stderr>`; no TXT/findings/manifest side effects.

## 2. The Python generators (repo v1.2.246)

### `generate_pdf_report.py`
- `main()` L1517–1653: <3 args → usage, exit 1; `argv[3]` `''` = no override; `argv[4]` prepared_by (falls back to `manifest.prepared_by`).
- Reads from `run_dir`: `manifest.json` (`client, location, note, generated_at` [cover Date], `prepared_by, report_file, tasks[].{task_id, json_file, json_files, json_present}`), `findings.json`, `remediation.json`, each task JSON. `load_json` treats missing/unreadable/non-dict as absent.
- Without a manifest it still produces a PDF ("Unknown Client", no task sections) — task paths come only from the manifest.
- Fonts: `Path(__file__).parent/"assets/fonts"` (`Inter-Regular/Bold/Italic.ttf`) — next to the script, **not** `app_root`; missing → exit 1. Logo: `app_root/assets/logo.png`, optional (falls back to text "LSS").
- Sections: cover (Client, Location, Note, Date, Prepared By); About This Report (tasks 1–12, 17–20; 13–16 in a footnote); Executive Summary (findings high > warning > info > advice); Remediation Hints; Audit Results in order 1–9, 10 (multi), 11–12, 13–16 (multi), 17–20, each with `render_task_status` failure/warning notes.
- Multi-entry (`all_task_json_paths` L494): manifest `json_files` + `json_file`; globs `<stem>-device-*.json` only if neither exists; natural sort; label = N from filename.
- Success: prints PDF path to stdout, exit 0. `ImportError` on fpdf → message, exit 1. Top-level handler: `ExcType: message` on stderr, exit 1.
- Python 3.8+ (walrus operator); fpdf2 ≥ 2.5.2 (`new_x/new_y`).

### `generate_pdf_compare_report.py`
- `main()` L1056–1138: <5 args → usage, exit 1. Reads only the two manifests and task JSONs (no findings/remediation/prepared_by). A4 landscape; same font/logo rules. Tasks 1–20 in ID order; multi-entry paired by `target_ip` / `gateway`, fallback index.

### Interpreters on this Mac
- `/opt/homebrew/bin/python3` = Homebrew python@3.14 (3.14.5) with **fpdf2 2.8.7** (plus Pillow, fontTools).
- `/usr/bin/python3` = CLT Python 3.9.6, **no fpdf2** (and fpdf2 2.8.7 needs 3.10+ anyway).
- The CLI gets Homebrew's interpreter because the wrapper and `ensure_standard_path` put `/opt/homebrew/bin` first. **A launchd-started GUI gets `/usr/bin:/bin:/usr/sbin:/sbin`**, so a bare `python3` resolves to 3.9.6 without fpdf2 → the GUI (and the privileged helper) must export the wrapper's PATH or call `/opt/homebrew/bin/python3` explicitly.

## 3. TXT build, manifest, Prepared By

- `build_report_for_current_run` (L1525–1673): needs ≥1 usable `*.json`; header (Location, Client, Note, Generated now, `Prepared By: ${RUN_PREPARED_BY:-Unknown}`, interface); Executed/Not Executed lists; one section per task file via the `render_*` functions (multi-entry labelled "Device N" by **position**, unlike the PDF's filename index). Side effects: writes `findings.json` (`append_findings_summary` L3350) and `remediation.json` (`append_remediation_hints` L3595) — only this path produces them.
- `build_report_for_run_dir` (L1723–1838) is fully interactive (export dir choice, `prompt_prepared_by`, Press Enter). It sets `RUN_*` from the manifest (`load_run_metadata_from_dir` — does **not** read `prepared_by`), calls `build_report_for_current_run`, **writes the manifest only if missing (L1818–1820)**, then `generate_pdf_report`, then restores state. Stale-manifest consequences: cover Date stays as original `generated_at`; later device files hidden; old manifests (tasks ≤17/18) never render Task 19/20 JSON.
- **Bug (v1.2.246):** the naming guard at L1555 was inverted (`!=`), so an export path outside the run dir is renamed back into the run dir — Build A Report writes TXT and PDF into `<run_dir>/…-{today}-{HH-MM}.*` while telling the user they went to the Desktop. v1.2.245 used `==` and honoured the export dir. Correct rule: regenerate the name only when `RUN_REPORT_FILE` is empty or points inside `OUTPUT_DIR` but not inside the current `RUN_OUTPUT_DIR` (a stale run path).
- `prompt_prepared_by` (L1518–1523) is called only from Build A Report; new-run save paths never ask → `""` ("Unknown" in TXT, no cover row). The global is never reset, so it leaks into later runs in the same session.

## 4. PDFs present in real runs

Only the two June runs (`paul-clarke-…-staff-wi-fi`, `…-student-wi-fi`) have a PDF in the run directory (`lss-network-tools-report-…-{HH-MM}.pdf`); the March/April runs have TXT only (their PDFs, if built, went to the Desktop under v1.2.245).

## 5. What a GUI must provide to regenerate a PDF

1. The right interpreter: `/opt/homebrew/bin/python3` or the wrapper's PATH; pre-flight `python3 -c "import fpdf"`.
2. The script in place: `$APP_ROOT/generate_pdf_report.py` (APP_ROOT from `install.env`); do not copy it away from `assets/fonts/`.
3. Arguments: absolute `run_dir`, `app_root` (logo), absolute writable `pdf_path`, optional `prepared_by`; compare: `run_a run_b pdf_path app_root`.
4. A current `manifest.json` (rewriting it moves the cover Date to now — decide audit date vs regeneration date).
5. Current `findings.json`/`remediation.json` (optional; only the bash TXT build produces them).
6. Write access: run dirs are root-owned → writing into them needs root; Desktop/temp does not.
7. Check the exit code and stdout path, not file existence.

**Can the GUI call the bash build path?** Not as-is: no report flag in `parse_args`; the script has no source guard (sourcing runs the TUI); Build A Report is prompt-driven and has the export bug. Robust fix: a non-interactive `--build-report RUN_DIR [--prepared-by N] [--output DIR]` that calls `load_run_metadata_from_dir`, `build_report_for_current_run`, **always** `write_manifest_for_current_run`, `generate_pdf_report`, and prints a machine-readable result.
