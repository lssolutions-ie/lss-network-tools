#!/usr/bin/env bash
# Builds the SwiftPM products and assembles "LSS Network Tools.app".
#
#   scripts/build-app.sh [debug|release] [--universal]
#
# Output: $LSS_BUILD_DIR/app/LSS Network Tools.app (see scripts/common.sh),
# ad-hoc signed unless CODESIGN_IDENTITY is set (scripts/sign.sh), plus the marker
# $LSS_BUILD_DIR/app/.build-config ("release universal", "debug arm64", …) that
# scripts/make-dmg.sh reads so only release builds are packaged.
#
# Bundle layout:
#   Contents/MacOS/LSSNetworkTools            the app
#   Contents/MacOS/LSSHelper                  privileged helper (LaunchDaemon via SMAppService)
#   Contents/Library/LaunchDaemons/<label>.plist
#   Contents/Frameworks/Sparkle.framework     from the SwiftPM binary artifact
#   Contents/Resources/*.bundle, AppIcon.icns
#   Contents/Info.plist                       from Resources/Info.plist.in (+ Sparkle keys)
#
# Versions: CFBundleShortVersionString is macos/VERSION (MAJOR.MINOR.PATCH, enforced).
# CFBundleVersion is derived from it as major*1000000 + minor*1000 + patch, so it is
# monotonic across branches and machines (Sparkle and LaunchServices order builds by
# it; a git commit count is neither).
#
# Environment: SPARKLE_PUBLIC_ED_KEY (optional) enables Sparkle in the built app.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() { echo "usage: $0 [debug|release] [--universal]" >&2; exit 2; }

CONFIG="${1:-debug}"
UNIVERSAL=0
case "$CONFIG" in
  debug|release) ;;
  *) usage ;;
esac
case "${2:-}" in
  "") ;;
  --universal) UNIVERSAL=1 ;;
  *) usage ;;
esac
[[ $# -le 2 ]] || usage

HELPER_EXECUTABLE="LSSHelper"
HELPER_PLIST="ie.lssolutions.lss-network-tools.helper.plist"

# --- version -------------------------------------------------------------------
VERSION="$(tr -d '[:space:]' < "$LSS_MACOS_DIR/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: macos/VERSION must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2
  exit 1
fi
IFS=. read -r v_major v_minor v_patch <<< "$VERSION"
BUILD_NUMBER=$(( 10#$v_major * 1000000 + 10#$v_minor * 1000 + 10#$v_patch ))

if [[ "$UNIVERSAL" -eq 1 ]]; then
  ARCH_LABEL="universal"
else
  ARCH_LABEL="$(uname -m)"
fi

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

# --- stray iCloud conflict copies ------------------------------------------------
# "Name 2.swift" copies compile into the targets and silently change the app.
if find "$LSS_MACOS_DIR/Sources" "$LSS_MACOS_DIR/Tests" -type f -name '* [0-9].*' | grep -q . ; then
  echo "error: iCloud conflict copies under macos/Sources or macos/Tests (see scripts/lint.sh):" >&2
  find "$LSS_MACOS_DIR/Sources" "$LSS_MACOS_DIR/Tests" -type f -name '* [0-9].*' >&2
  exit 1
fi

# --- build ---------------------------------------------------------------------
cd "$LSS_MACOS_DIR"
archs=()
if [[ "$UNIVERSAL" -eq 1 ]]; then
  archs=(--arch arm64 --arch x86_64)
fi
build_product() {
  swift build -c "$CONFIG" --scratch-path "$LSS_BUILD_DIR" ${archs[@]+"${archs[@]}"} --product "$1"
}
build_product "$LSS_EXECUTABLE"
build_product "$HELPER_EXECUTABLE"
# SwiftPM decides where the products land (out/Products/<Config> under the
# swiftbuild build system, <config>/ under the native one, and universal builds
# used to differ again), so ask it rather than guessing. stdout is only the path.
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$LSS_BUILD_DIR" ${archs[@]+"${archs[@]}"} --show-bin-path)"
[[ -n "$BIN_DIR" && -d "$BIN_DIR" ]] || { echo "error: swift build --show-bin-path returned '$BIN_DIR', not a directory" >&2; exit 1; }
[[ -x "$BIN_DIR/$LSS_EXECUTABLE" ]] || { echo "error: built product not found at $BIN_DIR/$LSS_EXECUTABLE" >&2; exit 1; }
[[ -x "$BIN_DIR/$HELPER_EXECUTABLE" ]] || { echo "error: built helper not found at $BIN_DIR/$HELPER_EXECUTABLE" >&2; exit 1; }

# --- assemble the bundle -------------------------------------------------------
CONTENTS="$LSS_APP/Contents"
BUILD_CONFIG_FILE="$LSS_BUILD_DIR/app/.build-config"
rm -rf "$LSS_APP"
rm -f "$BUILD_CONFIG_FILE"
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
# @rpath/Sparkle.framework, so the in-bundle rpath is added below.
SPARKLE_FW="$(find "$LSS_BUILD_DIR/artifacts" -type d -name Sparkle.framework -path '*macos*' -print -quit 2>/dev/null || true)"
SPARKLE_EMBEDDED=0
if [[ -n "$SPARKLE_FW" ]]; then
  mkdir -p "$CONTENTS/Frameworks"
  cp -R "$SPARKLE_FW" "$CONTENTS/Frameworks/"
  SPARKLE_EMBEDDED=1
else
  echo "warning: Sparkle.framework not found under $LSS_BUILD_DIR/artifacts — the app will not launch if it links Sparkle" >&2
fi

# --- rpaths ---------------------------------------------------------------------
# SwiftPM links every product with an LC_RPATH into <bin dir>/PackageFrameworks so
# it runs in place. A shipped binary must not search the build machine's paths, so
# every rpath that points into the build directory is deleted from BOTH executables
# (delete-only; nothing else about the load commands changes). Paths are parsed with
# sed, not awk's $2, so build directories with spaces survive, and they are compared
# against the logical and the physical (pwd -P) spelling of the build directory.
# otool prints the load commands of every slice of a universal binary, hence sort -u.
list_rpaths() {
  otool -l "$1" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u
}
build_dir_rpaths() {
  local physical rpath
  physical="$(cd "$LSS_BUILD_DIR" && pwd -P)"
  while IFS= read -r rpath; do
    case "$rpath" in
      "$LSS_BUILD_DIR"|"$LSS_BUILD_DIR"/*|"$physical"|"$physical"/*) printf '%s\n' "$rpath" ;;
    esac
  done < <(list_rpaths "$1")
}
strip_build_rpaths() {
  local binary="$1" rpath stale
  stale="$(build_dir_rpaths "$binary")"
  [[ -n "$stale" ]] || return 0
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    install_name_tool -delete_rpath "$rpath" "$binary"
  done <<< "$stale"
  stale="$(build_dir_rpaths "$binary")"
  if [[ -n "$stale" ]]; then
    echo "error: $binary still carries LC_RPATH entries into the build directory:" >&2
    while IFS= read -r rpath; do echo "       $rpath" >&2; done <<< "$stale"
    exit 1
  fi
}
has_rpath() {
  local rpath
  while IFS= read -r rpath; do
    [[ "$rpath" == "$2" ]] && return 0
  done < <(list_rpaths "$1")
  return 1
}
APP_BIN="$CONTENTS/MacOS/$LSS_EXECUTABLE"
HELPER_BIN="$CONTENTS/MacOS/$HELPER_EXECUTABLE"
strip_build_rpaths "$APP_BIN"
strip_build_rpaths "$HELPER_BIN"
# Only the app links Sparkle (@rpath/Sparkle.framework → Contents/Frameworks); the
# helper links system frameworks only and gets no rpath added.
if ! has_rpath "$APP_BIN" "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BIN"
fi

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

# --- build marker (read by scripts/make-dmg.sh) ---------------------------------
# Written last, so a failed build never leaves a marker next to a half-built app.
printf '%s %s\n' "$CONFIG" "$ARCH_LABEL" > "$BUILD_CONFIG_FILE"

echo
echo "Built: $LSS_APP"
echo "  version $VERSION, CFBundleVersion $BUILD_NUMBER, $CONFIG $ARCH_LABEL (products: $BIN_DIR)"
echo "  helper  Contents/MacOS/$HELPER_EXECUTABLE + Library/LaunchDaemons/$HELPER_PLIST"
echo "  Sparkle $SPARKLE_STATE$( [[ $SPARKLE_EMBEDDED -eq 1 ]] && echo ', framework embedded')"
echo "  rpaths  none into $LSS_BUILD_DIR (app, helper); app searches @executable_path/../Frameworks"
codesign -dv "$LSS_APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)' | sed 's/^/  /' || true
