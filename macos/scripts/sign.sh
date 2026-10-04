#!/usr/bin/env bash
# Signs an assembled .app inside-out.
#
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/sign.sh <app> [app-entitlements.plist]
#
# Without CODESIGN_IDENTITY the bundle is ad-hoc signed (fine for local use;
# not distributable). Never uses --deep: nested code is signed explicitly, in
# this order: Sparkle's XPC services / Autoupdate / Updater.app → frameworks →
# SwiftPM resource bundles → the privileged helper (its own identifier and
# entitlements) → the app (its entitlements). Entitlements default to the files
# in Resources/.
set -euo pipefail

APP="${1:?usage: sign.sh <app-bundle> [entitlements]}"
MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ENTITLEMENTS="${2:-$MACOS_DIR/Resources/LSSNetworkTools.entitlements}"
HELPER_ENTITLEMENTS="$MACOS_DIR/Resources/LSSHelper.entitlements"
HELPER_IDENTIFIER="ie.lssolutions.lss-network-tools.helper"
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

# Nested code first: Sparkle's XPC services, Autoupdate and Updater.app, then
# the frameworks themselves, then SwiftPM resource bundles.
if [[ -d "$APP/Contents/Frameworks" ]]; then
  # -type d skips the framework's top-level symlinks (Sparkle.framework/Updater.app → Versions/B/…).
  find "$APP/Contents/Frameworks" -mindepth 2 -type d \( -name '*.xpc' -o -name '*.app' \) -prune -print0 2>/dev/null \
    | while IFS= read -r -d '' nested; do sign_item "$nested"; done
  find "$APP/Contents/Frameworks" -mindepth 2 -type f -name Autoupdate -print0 2>/dev/null \
    | while IFS= read -r -d '' nested; do sign_item "$nested"; done
  find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -print0 \
    | while IFS= read -r -d '' framework; do sign_item "$framework"; done
fi
find "$APP/Contents/Resources" -mindepth 1 -maxdepth 1 -name '*.bundle' -print0 2>/dev/null \
  | while IFS= read -r -d '' bundle; do sign_item "$bundle"; done

# Embedded executables: the privileged helper gets its own identifier (the
# LaunchDaemon plist and the app's XPC requirement refer to it).
find "$APP/Contents/MacOS" -mindepth 1 -maxdepth 1 -type f ! -name LSSNetworkTools -print0 2>/dev/null \
  | while IFS= read -r -d '' helper; do
      if [[ "$(basename "$helper")" == "LSSHelper" && -f "$HELPER_ENTITLEMENTS" ]]; then
        sign_item --identifier "$HELPER_IDENTIFIER" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
      else
        sign_item "$helper"
      fi
    done

if [[ -f "$APP_ENTITLEMENTS" ]]; then
  sign_item --entitlements "$APP_ENTITLEMENTS" "$APP"
else
  sign_item "$APP"
fi

codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/sign: /'
if [[ -f "$APP/Contents/MacOS/LSSHelper" ]]; then
  codesign --verify --strict "$APP/Contents/MacOS/LSSHelper" && echo "sign: helper signature valid ($HELPER_IDENTIFIER)"
fi
