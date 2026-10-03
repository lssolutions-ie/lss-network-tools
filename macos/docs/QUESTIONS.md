# Questions for the project owner — macOS GUI

Decisions that are genuinely yours. In each case the most conservative choice was taken so work could continue; change it later if you disagree.

## Before M1

- **Bugs found in the bash tool during research — fixed on this branch, not on `main`.** Five pre-existing CLI issues surfaced while mapping the script: (1) Build A Report's export directory is ignored since v1.2.246 because the report-name guard was inverted (a regression from the review fixes); (2) `build_report_for_run_dir` rewrote the manifest only when it was missing, so rebuilt PDFs could miss tasks; (3) stress-test JSON files were written 0600 root-only (mktemp + mv), unreadable by a GUI running as the user; (4) Task 10's skipped / early-failure results went to a non-indexed `gateway-stress-test.json` that the report, manifest and findings code never saw; (5) Task 20 returned 0 on insufficient privileges while Task 18 returns 1. They are committed here as **v1.2.247 (M0)** and will reach `main` with the GUI PR, because you asked for `main` to stay untouched until the merge. If you want CLI users to get them sooner, cherry-pick the single M0 commit onto `main` and release it; nothing in it depends on the GUI.
- **Metal Toolchain download.** Building SwiftTerm needs the Xcode Metal toolchain component, which was not installed on this Mac. It was downloaded (user-level, ~minutes, no sudo). Alternative would have been pinning SwiftTerm below v1.15 (older, unmaintained). Documented in DECISIONS.md and the build script.
