#!/usr/bin/env bash
# Reports whether this Mac can build, run, sign and notarize the GUI.
# Exit 3 when a hard requirement (Xcode toolchain, Metal compiler) is missing.
set -euo pipefail

status=0
ok()   { printf '  [OK]      %s\n' "$1"; }
warn() { printf '  [WARN]    %s\n' "$1"; }
miss() { printf '  [MISSING] %s\n' "$1"; status=3; }

echo "Toolchain check"
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode developer directory: $(xcode-select -p)"
else
  miss "Xcode / Command Line Tools (run: xcode-select --install)"
fi

if swift_version="$(swift --version 2>/dev/null | head -n 1)"; then
  ok "$swift_version"
else
  miss "swift toolchain"
fi

if xcrun metal --version >/dev/null 2>&1; then
  ok "Metal toolchain (SwiftTerm ships a .metal shader)"
else
  miss "Metal toolchain — run: xcodebuild -downloadComponent MetalToolchain"
fi

if xcrun notarytool --version >/dev/null 2>&1; then
  ok "notarytool $(xcrun notarytool --version 2>/dev/null | head -n 1)"
else
  warn "notarytool not available (notarization will be skipped)"
fi

identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -c '"' || true)"
if [[ "${CODESIGN_IDENTITY:-}" != "" ]]; then
  ok "CODESIGN_IDENTITY set: ${CODESIGN_IDENTITY}"
elif [[ "$identities" -gt 0 ]]; then
  warn "$identities code-signing identit(y/ies) in the keychain but CODESIGN_IDENTITY is unset — builds are ad-hoc signed"
else
  warn "no code-signing identity — builds are ad-hoc signed (local use only)"
fi

if /opt/homebrew/bin/python3 -c 'import fpdf' >/dev/null 2>&1; then
  ok "Homebrew python3 with fpdf2 (PDF reports)"
else
  warn "fpdf2 not importable from /opt/homebrew/bin/python3 — the CLI cannot build PDFs (pip3 install fpdf2)"
fi

exit "$status"
