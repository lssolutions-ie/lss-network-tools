#!/usr/bin/env bash
# Packages "LSS Network Tools.app" into a compressed DMG with an Applications symlink.
#
#   scripts/make-dmg.sh [app path] [out.dmg]
#
# Defaults: the app from scripts/build-app.sh, output
# $LSS_BUILD_DIR/dist/LSS-Network-Tools-<VERSION>.dmg. Prints the sha256 for the
# appcast / release notes. Notarize the app BEFORE packaging (scripts/notarize.sh)
# so the copy inside the image carries its ticket, then notarize the DMG too.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP="${1:-$LSS_APP}"
VERSION="$(tr -d '[:space:]' < "$LSS_MACOS_DIR/VERSION")"
OUT="${2:-$LSS_BUILD_DIR/dist/LSS-Network-Tools-$VERSION.dmg}"
VOLNAME="LSS Network Tools"

[[ -d "$APP" ]] || { echo "error: app not found at $APP — run make build first" >&2; exit 1; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")" "$LSS_BUILD_DIR"

STAGING="$(mktemp -d "$LSS_BUILD_DIR/dmg-staging-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# iCloud / Finder xattrs would end up in the image and break codesign verification.
xattr -cr "$STAGING" 2>/dev/null || true

rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null

echo "dmg: $OUT"
echo "  size   $(du -h "$OUT" | cut -f1 | tr -d ' ')"
echo "  sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
