#!/usr/bin/env bash
# Builds the SwiftPM products and assembles "LSS Network Tools.app".
#
#   scripts/build-app.sh [debug|release] [--universal]
#
# Output: $LSS_BUILD_DIR/app/LSS Network Tools.app (see scripts/common.sh),
# ad-hoc signed unless CODESIGN_IDENTITY is set (scripts/sign.sh).
#
# Bundle layout:
#   Contents/MacOS/LSSNetworkTools            the app
#   Contents/MacOS/LSSHelper                  privileged helper (LaunchDaemon via SMAppService)
#   Contents/Library/LaunchDaemons/<label>.plist
#   Contents/Frameworks/Sparkle.framework     from the SwiftPM binary artifact
#   Contents/Resources/*.bundle, AppIcon.icns
#   Contents/Info.plist                       from Resources/Info.plist.in (+ Sparkle keys)
#
# Environment: SPARKLE_PUBLIC_ED_KEY (optional) enables Sparkle in the built app.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CONFIG="${1:-debug}"
UNIVERSAL=0
[[ "${2:-}" == "--universal" ]] && UNIVERSAL=1

VERSION="$(tr -d '[:space:]' < "$LSS_MACOS_DIR/VERSION")"
BUILD_NUMBER="$(git -C "$LSS_MACOS_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
HELPER_EXECUTABLE="LSSHelper"
HELPER_PLIST="ie.lssolutions.lss-network-tools.helper.plist"

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
build_product() {
  if [[ "$UNIVERSAL" -eq 1 ]]; then
    swift build -c "$CONFIG" --scratch-path "$LSS_BUILD_DIR" --arch arm64 --arch x86_64 --product "$1"
  else
    swift build -c "$CONFIG" --scratch-path "$LSS_BUILD_DIR" --product "$1"
  fi
}
build_product "$LSS_EXECUTABLE"
build_product "$HELPER_EXECUTABLE"
if [[ "$UNIVERSAL" -eq 1 ]]; then
  BIN_DIR="$LSS_BUILD_DIR/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
else
  BIN_DIR="$LSS_BUILD_DIR/$CONFIG"
fi
[[ -x "$BIN_DIR/$LSS_EXECUTABLE" ]] || { echo "error: built product not found at $BIN_DIR/$LSS_EXECUTABLE" >&2; exit 1; }
[[ -x "$BIN_DIR/$HELPER_EXECUTABLE" ]] || { echo "error: built helper not found at $BIN_DIR/$HELPER_EXECUTABLE" >&2; exit 1; }

# --- assemble the bundle -------------------------------------------------------
CONTENTS="$LSS_APP/Contents"
rm -rf "$LSS_APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchDaemons"

cp "$BIN_DIR/$LSS_EXECUTABLE" "$CONTENTS/MacOS/$LSS_EXECUTABLE"
cp "$BIN_DIR/$HELPER_EXECUTABLE" "$CONTENTS/MacOS/$HELPER_EXECUTABLE"
cp "$LSS_MACOS_DIR/Resources/$HELPER_PLIST" "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST"
plutil -lint "$CONTENTS/Library/LaunchDaemons/$HELPER_PLIST" >/dev/null

# SwiftPM resource bundles (SwiftTerm's shader library, etc.). Bundle.module
# looks in Bundle.main.resourceURL when running from an .app.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$CONTENTS/Resources/"
done

# Sparkle.framework from the SwiftPM binary artifact; the app links it as
# @rpath/Sparkle.framework, so add the in-bundle rpath and drop build-dir rpaths.
SPARKLE_FW="$(find "$LSS_BUILD_DIR/artifacts" -type d -name Sparkle.framework -path '*macos*' -print -quit 2>/dev/null || true)"
SPARKLE_EMBEDDED=0
if [[ -n "$SPARKLE_FW" ]]; then
  mkdir -p "$CONTENTS/Frameworks"
  cp -R "$SPARKLE_FW" "$CONTENTS/Frameworks/"
  SPARKLE_EMBEDDED=1
else
  echo "warning: Sparkle.framework not found under $LSS_BUILD_DIR/artifacts — the app will not launch if it links Sparkle" >&2
fi
APP_BIN="$CONTENTS/MacOS/$LSS_EXECUTABLE"
if ! otool -l "$APP_BIN" | grep -q '@executable_path/\.\./Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BIN"
fi
otool -l "$APP_BIN" | awk '/LC_RPATH/ {rp=1; next} rp && /path / {print $2; rp=0}' \
  | grep -F "$LSS_BUILD_DIR" | while IFS= read -r stale; do
      install_name_tool -delete_rpath "$stale" "$APP_BIN" 2>/dev/null || true
    done

sed -e "s|@EXECUTABLE@|$LSS_EXECUTABLE|g" \
    -e "s|@BUNDLE_ID@|$LSS_BUNDLE_ID|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@BUILD@|$BUILD_NUMBER|g" \
    "$LSS_MACOS_DIR/Resources/Info.plist.in" > "$CONTENTS/Info.plist"
# Sparkle keys: enabled only with a public EdDSA key (never run Sparkle unkeyed).
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" && "$SPARKLE_EMBEDDED" -eq 1 ]]; then
  plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist"
  plutil -insert SUEnableAutomaticChecks -bool true "$CONTENTS/Info.plist"
  SPARKLE_STATE="enabled"
else
  plutil -insert SUEnableAutomaticChecks -bool false "$CONTENTS/Info.plist"
  SPARKLE_STATE="disabled (set SPARKLE_PUBLIC_ED_KEY to enable)"
fi
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
echo "  helper  Contents/MacOS/$HELPER_EXECUTABLE + Library/LaunchDaemons/$HELPER_PLIST"
echo "  Sparkle $SPARKLE_STATE$( [[ $SPARKLE_EMBEDDED -eq 1 ]] && echo ', framework embedded')"
codesign -dv "$LSS_APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)' | sed 's/^/  /' || true
