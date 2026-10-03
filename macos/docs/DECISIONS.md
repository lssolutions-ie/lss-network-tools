# Decisions log — macOS GUI

One line per non-obvious choice and why. Newest at the bottom.

- 2026-10-03 — Work happens in a git worktree at `.claude/worktrees/macos-gui` on branch `macos-gui`, branched from `main` at 474e45d (v1.2.246), so the CLI on `main` is untouched until the PR merges.
- 2026-10-03 — Research notes are kept in `macos/docs/research/` (install/update/Wi-Fi helper, interactive surface, JSON schemas) so future sessions do not have to re-derive them from the 12k-line script.
- 2026-10-03 — Installed the Xcode "Metal Toolchain" component (`xcodebuild -downloadComponent MetalToolchain`) rather than pinning SwiftTerm to a pre-1.16 release: every SwiftTerm tag from v1.15.0 onwards ships `Apple/Metal/Shaders.metal` as a processed SPM resource, and Xcode 26+ no longer bundles the Metal compiler by default. The build script checks `xcrun metal --version` and prints the download command when it is missing.
- 2026-10-03 — Dependency smoke build (SwiftTerm 1.20.0 + Sparkle 2.x + Defaults 8.2.0, Swift 6 language mode, macOS 14 platform) compiles from the CLI in ~11 s; the GUI uses the latest tags rather than older pins.
- 2026-10-03 — There is no Developer ID / Apple Development signing identity on this Mac (`security find-identity -v -p codesigning` → 0). Local builds are ad-hoc signed; the sign/notarize scripts read the identity from an environment variable and skip cleanly when it is unset.
- 2026-10-03 — M0 (CLI fixes found during research) is committed on `macos-gui` as v1.2.247 rather than on `main`: the owner asked for `main` to stay untouched until the PR merges. The commit is self-contained so it can be cherry-picked.
- 2026-10-03 — Task 10 early exits now write `-device-N.json` (via `next_multi_entry_output_path 10`) instead of the non-indexed name, and `append_findings_summary` loops over every Task 10 file. The legacy non-indexed name is still read so old runs keep working.
