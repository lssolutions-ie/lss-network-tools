#!/usr/bin/env bash
# Builds the SwiftPM products and assembles "LSS Network Tools.app".
#
#   scripts/build-app.sh [debug|release] [--universal]
#
# Output: $LSS_BUILD_DIR/app/LSS Network Tools.app (see scripts/common.sh),
# ad-hoc signed unless CODESIGN_IDENTITY is set (scripts/sign.sh).
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CONFIG="${1:-debug}"
UNIVERSAL=0
[[ "${2:-}" == "--universal" ]] && UNIVERSAL=1

VERSION="$(tr -d '[:space:]' < "$LSS_MACOS_DIR/VERSION")"
BUILD_NUMBER="$(git -C "$LSS_MACOS_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release] [--universal]" >&2; exit 2 ;;
esac

# --- toolchain -----------------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
  echo "error: Xcode Command Line Tools not found (xcode-select --install)" >&2
  exit 3
fi
if ! xcrun metal --version >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: the Metal toolchain is not installed. SwiftTerm ships a Metal shader
       that SwiftPM compiles at build time. Install the component with:

           xcodebuild -downloadComponent MetalToolchain

MSG
  exit 3
fi

# --- build ---------------------------------------------------------------------
mkdir -p "$LSS_BUILD_DIR"
cd "$LSS_MACOS_DIR"
if [[ "$UNIVERSAL" -eq 1 ]]; then
  swift build -c "$CONFIG" --scratch-path "$LSS_BUILD_DIR" --arch arm64 --arch x86_64 --product "$LSS_EXECUTABLE"
  BIN_DIR="$LSS_BUILD_DIR/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
else
  swift build -c "$CONFIG" --scratch-path "$LSS_BUILD_DIR" --product "$LSS_EXECUTABLE"
  BIN_DIR="$LSS_BUILD_DIR/$CONFIG"
fi
[[ -x "$BIN_DIR/$LSS_EXECUTABLE" ]] || { echo "error: built product not found at $BIN_DIR/$LSS_EXECUTABLE" >&2; exit 1; }

# --- assemble the bundle -------------------------------------------------------
CONTENTS="$LSS_APP/Contents"
rm -rf "$LSS_APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/$LSS_EXECUTABLE" "$CONTENTS/MacOS/$LSS_EXECUTABLE"

# SwiftPM resource bundles (SwiftTerm's shader library, etc.). Bundle.module
# looks in Bundle.main.resourceURL when running from an .app.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$CONTENTS/Resources/"
done

sed -e "s|@EXECUTABLE@|$LSS_EXECUTABLE|g" \
    -e "s|@BUNDLE_ID@|$LSS_BUNDLE_ID|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@BUILD@|$BUILD_NUMBER|g" \
    "$LSS_MACOS_DIR/Resources/Info.plist.in" > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- icon (built once from the repo's PNG, cached in the build dir) -------------
ICON_SRC="$LSS_MACOS_DIR/Resources/AppIcon.png"
[[ -f "$ICON_SRC" ]] || ICON_SRC="$LSS_REPO_DIR/assets/wifi-scan-icon.png"
ICNS="$LSS_BUILD_DIR/AppIcon.icns"
if [[ -f "$ICON_SRC" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  if [[ ! -f "$ICNS" || "$ICON_SRC" -nt "$ICNS" ]]; then
    ICON_WORK="$(mktemp -d "$LSS_BUILD_DIR/iconset-XXXXXX")"
    mkdir -p "$ICON_WORK/AppIcon.iconset"
    for size in 16 32 64 128 256 512; do
      sips -z "$size" "$size" "$ICON_SRC" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
      sips -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$ICNS"
    rm -rf "$ICON_WORK"
  fi
  cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"
fi

# --- sign ----------------------------------------------------------------------
"$LSS_MACOS_DIR/scripts/sign.sh" "$LSS_APP"

echo
echo "Built: $LSS_APP"
echo "  version $VERSION (build $BUILD_NUMBER), $CONFIG$( [[ $UNIVERSAL -eq 1 ]] && echo ', universal')"
codesign -dv "$LSS_APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)' | sed 's/^/  /' || true
