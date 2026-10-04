#!/usr/bin/env bash
# Packages "LSS Network Tools.app" into a compressed DMG with an Applications symlink.
#
#   scripts/make-dmg.sh [app path] [out.dmg]
#
# Defaults: the app from scripts/build-app.sh, output
# $LSS_BUILD_DIR/dist/LSS-Network-Tools-<VERSION>.dmg. Prints the sha256 for the
# appcast / release notes.
#
# Only release builds are packaged: the script reads the .build-config marker that
# build-app.sh writes next to the app and refuses a debug (or unmarked) app unless
# LSS_DMG_ALLOW_DEBUG=1 is set. With CODESIGN_IDENTITY set the image itself is
# signed after hdiutil verify. Notarize the app BEFORE packaging (scripts/notarize.sh)
# so the copy inside the image carries its ticket, then notarize the DMG too
# (`make notarize` does all three).
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP="${1:-$LSS_APP}"
VERSION="$(tr -d '[:space:]' < "$LSS_MACOS_DIR/VERSION")"
OUT="${2:-$LSS_BUILD_DIR/dist/LSS-Network-Tools-$VERSION.dmg}"
VOLNAME="LSS Network Tools"

[[ -d "$APP" ]] || { echo "error: app not found at $APP — run make release first" >&2; exit 1; }

# --- release-only guard -----------------------------------------------------------
BUILD_CONFIG_FILE="$(dirname "$APP")/.build-config"
BUILD_CONFIG=""
if [[ -f "$BUILD_CONFIG_FILE" ]]; then
  BUILD_CONFIG="$(tr -d '\n' < "$BUILD_CONFIG_FILE")"
fi
if [[ "${BUILD_CONFIG%% *}" != "release" ]]; then
  if [[ "${LSS_DMG_ALLOW_DEBUG:-0}" == "1" ]]; then
    echo "dmg: warning — packaging a non-release build (${BUILD_CONFIG:-no .build-config marker}) because LSS_DMG_ALLOW_DEBUG=1"
  else
    cat >&2 <<MSG
error: refusing to package a non-release build.
       app:      $APP
       built as: ${BUILD_CONFIG:-unknown (no .build-config next to the app)}
       Run \`make release\` (scripts/build-app.sh release --universal) first, or set
       LSS_DMG_ALLOW_DEBUG=1 to package this build anyway for local testing.
MSG
    exit 1
  fi
fi

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

STAGING="$(mktemp -d "$LSS_BUILD_DIR/dmg-staging-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# iCloud / Finder xattrs would end up in the image and break codesign verification.
xattr -cr "$STAGING" 2>/dev/null || true

rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null

# Sign the image itself so Gatekeeper can attribute it (and notarytool accept it).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$OUT"
  echo "dmg: signed with '$CODESIGN_IDENTITY'"
else
  echo "dmg: CODESIGN_IDENTITY is not set — image left unsigned (local use only)"
fi

echo "dmg: $OUT"
echo "  build  ${BUILD_CONFIG:-unknown}"
echo "  size   $(du -h "$OUT" | cut -f1 | tr -d ' ')"
echo "  sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
