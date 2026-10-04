#!/usr/bin/env bash
# Regenerates macos/appcast.xml from the DMGs in a dist directory with Sparkle's
# generate_appcast, signing each enclosure with the EdDSA private key.
#
#   SPARKLE_PRIVATE_KEY_FILE=~/.keys/lss-sparkle-ed25519 scripts/release-appcast.sh [dist dir]
#
# dist dir default: $LSS_BUILD_DIR/dist (where scripts/make-dmg.sh writes).
# Tool lookup order: `generate_appcast` on PATH → the Sparkle SwiftPM artifact's
# bin/ directory under $LSS_BUILD_DIR/artifacts → the pinned Sparkle release
# tarball (version from Package.resolved) downloaded into
# $LSS_BUILD_DIR/sparkle-tools (sha256 checked when SPARKLE_TOOLS_SHA256 is set).
# Without SPARKLE_PRIVATE_KEY_FILE the script prints one "skipped" line and exits 0.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DIST="${1:-$LSS_BUILD_DIR/dist}"
APPCAST="$LSS_MACOS_DIR/appcast.xml"
DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_PREFIX:-https://github.com/lssolutions-ie/lss-network-tools/releases/download}"

if [[ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  echo "appcast: skipped — SPARKLE_PRIVATE_KEY_FILE is unset (generate a key pair with Sparkle's generate_keys)"
  exit 0
fi
[[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]] || { echo "error: $SPARKLE_PRIVATE_KEY_FILE not found" >&2; exit 1; }
[[ -d "$DIST" ]] || { echo "error: dist directory $DIST not found — run make dmg first" >&2; exit 1; }
if ! ls "$DIST"/*.dmg >/dev/null 2>&1; then
  echo "error: no .dmg in $DIST" >&2
  exit 1
fi

find_tool() {
  local candidate
  if command -v generate_appcast >/dev/null 2>&1; then
    command -v generate_appcast
    return 0
  fi
  for candidate in "$LSS_BUILD_DIR"/artifacts/*/Sparkle/bin/generate_appcast "$LSS_BUILD_DIR"/artifacts/*/*/bin/generate_appcast; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  local version tools_dir tarball
  version="$(sed -n '/"identity" *: *"sparkle"/,/}/p' "$LSS_MACOS_DIR/Package.resolved" 2>/dev/null | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$version" ]] || { echo "error: Sparkle version not found in Package.resolved" >&2; return 1; }
  tools_dir="$LSS_BUILD_DIR/sparkle-tools/$version"
  if [[ ! -x "$tools_dir/bin/generate_appcast" ]]; then
    mkdir -p "$tools_dir"
    tarball="$tools_dir/Sparkle-$version.tar.xz"
    echo "appcast: downloading Sparkle $version tools" >&2
    curl -fsSL -o "$tarball" "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
    if [[ -n "${SPARKLE_TOOLS_SHA256:-}" ]]; then
      echo "$SPARKLE_TOOLS_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || { echo "error: Sparkle tools checksum mismatch" >&2; return 1; }
    else
      echo "appcast: warning — SPARKLE_TOOLS_SHA256 unset, tarball not verified" >&2
    fi
    tar -xJf "$tarball" -C "$tools_dir"
  fi
  [[ -x "$tools_dir/bin/generate_appcast" ]] || { echo "error: generate_appcast not found after download" >&2; return 1; }
  echo "$tools_dir/bin/generate_appcast"
}

TOOL="$(find_tool)"
echo "appcast: using $TOOL"
"$TOOL" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --download-url-prefix "$DOWNLOAD_PREFIX/" -o "$APPCAST" "$DIST"
# generate_appcast writes <prefix>/<file>; GitHub release assets live under <prefix>/macos-vX.Y.Z/<file>.
# Rewrite each enclosure URL to include the tag directory derived from the DMG name.
python3 - "$APPCAST" "$DOWNLOAD_PREFIX" <<'PY'
import re, sys
path, prefix = sys.argv[1], sys.argv[2].rstrip("/")
text = open(path, encoding="utf-8").read()
def fix(match):
    name = match.group(1)
    version = re.search(r"LSS-Network-Tools-(\d+\.\d+\.\d+)\.dmg", name)
    if not version:
        return match.group(0)
    return 'url="%s/macos-v%s/%s"' % (prefix, version.group(1), name)
text = re.sub(r'url="%s/([^"/]+\.dmg)"' % re.escape(prefix), fix, text)
open(path, "w", encoding="utf-8").write(text)
PY
plutil -lint "$APPCAST" >/dev/null 2>&1 || true
xmllint --noout "$APPCAST"
echo "appcast: wrote $APPCAST"
