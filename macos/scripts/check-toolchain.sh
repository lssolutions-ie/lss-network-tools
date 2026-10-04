#!/usr/bin/env bash
# Reports whether this Mac can build, run, sign and notarize the GUI.
# Exit 3 when a hard requirement (Xcode toolchain, Metal compiler) is missing.
set -euo pipefail

status=0
ok()   { printf '  [OK]      %s\n' "$1"; }
info() { printf '  [INFO]    %s\n' "$1"; }
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

# fpdf2 is the engine's PDF dependency; it lives in the Homebrew python3 that the
# CLI wrapper puts first on PATH. Homebrew's prefix differs between Apple silicon
# (/opt/homebrew) and Intel (/usr/local), so ask brew, then try both.
brew_prefix=""
if command -v brew >/dev/null 2>&1; then
  brew_prefix="$(brew --prefix 2>/dev/null || true)"
fi
homebrew_python3=""
for candidate in ${brew_prefix:+"$brew_prefix/bin/python3"} /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if [[ -x "$candidate" ]]; then
    homebrew_python3="$candidate"
    break
  fi
done
if [[ -z "$homebrew_python3" ]]; then
  info "no Homebrew python3 found (${brew_prefix:-/opt/homebrew}/bin, /usr/local/bin) — the CLI's install.sh installs it; fpdf2 not checked"
elif "$homebrew_python3" -c 'import fpdf' >/dev/null 2>&1; then
  ok "fpdf2 importable from $homebrew_python3 (PDF reports)"
else
  warn "fpdf2 not importable from $homebrew_python3 — the CLI cannot build PDFs ($homebrew_python3 -m pip install fpdf2)"
fi

exit "$status"
