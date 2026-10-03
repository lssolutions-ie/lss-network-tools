#!/usr/bin/env bash
# Signs an assembled .app inside-out.
#
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/sign.sh <app> [entitlements.plist]
#
# Without CODESIGN_IDENTITY the bundle is ad-hoc signed (fine for local use;
# not distributable). Never uses --deep: nested code is signed explicitly.
set -euo pipefail

APP="${1:?usage: sign.sh <app-bundle> [entitlements]}"
ENTITLEMENTS="${2:-}"
IDENTITY="${CODESIGN_IDENTITY:-}"

opts=()
if [[ -z "$IDENTITY" ]]; then
  echo "sign: CODESIGN_IDENTITY is not set — ad-hoc signing (local use only)"
  IDENTITY="-"
else
  echo "sign: using identity '$IDENTITY' with hardened runtime"
  opts=(--options runtime --timestamp)
fi

# Finder/file-provider extended attributes make codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$APP" 2>/dev/null || true

sign_item() {
  codesign --force --sign "$IDENTITY" ${opts[@]+"${opts[@]}"} "$@"
}

# Nested code first: frameworks (incl. Sparkle's XPC services / helpers) and
# resource bundles, then any embedded helper executables.
if [[ -d "$APP/Contents/Frameworks" ]]; then
  find "$APP/Contents/Frameworks" -mindepth 2 \( -name '*.xpc' -o -name '*.app' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' nested; do sign_item "$nested"; done
  find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -print0 \
    | while IFS= read -r -d '' framework; do sign_item "$framework"; done
fi
find "$APP/Contents/Resources" -mindepth 1 -maxdepth 1 -name '*.bundle' -print0 2>/dev/null \
  | while IFS= read -r -d '' bundle; do sign_item "$bundle"; done
find "$APP/Contents/MacOS" -mindepth 1 -maxdepth 1 -type f ! -name LSSNetworkTools -print0 2>/dev/null \
  | while IFS= read -r -d '' helper; do sign_item "$helper"; done

if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
  sign_item --entitlements "$ENTITLEMENTS" "$APP"
else
  sign_item "$APP"
fi

codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/sign: /'
