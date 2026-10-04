#!/usr/bin/env bash
# Regenerates macos/appcast.xml from the DMGs in a dist directory with Sparkle's
# generate_appcast, signing each enclosure with the EdDSA private key.
#
#   SPARKLE_PRIVATE_KEY_FILE=~/.keys/lss-sparkle-ed25519 scripts/release-appcast.sh [dist dir]
#
# dist dir default: $LSS_BUILD_DIR/dist (where scripts/make-dmg.sh writes).
# Tool lookup order: `generate_appcast` on PATH → the bin/ directory of the Sparkle
# SwiftPM binary artifact under $LSS_BUILD_DIR/artifacts, which `swift package resolve`
# fetches with the checksum pinned in Package.resolved (nothing is downloaded by
# this script itself). If neither exists the script fails and names the expected
# location and the `brew install --cask sparkle` alternative.
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
  # The Sparkle binary artifact ships generate_appcast/sign_update/generate_keys in
  # bin/. SwiftPM verifies the artifact's checksum against Package.resolved, which is
  # why this replaces any ad-hoc download.
  echo "appcast: resolving the Sparkle package artifact (swift package resolve)" >&2
  swift package --package-path "$LSS_MACOS_DIR" --scratch-path "$LSS_BUILD_DIR" resolve >/dev/null
  while IFS= read -r -d '' candidate; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done < <(find "$LSS_BUILD_DIR/artifacts" -type f -path '*/bin/generate_appcast' -print0 2>/dev/null | sort -z)
  cat >&2 <<MSG
error: generate_appcast not found. Expected it in the Sparkle SwiftPM artifact at
       $LSS_BUILD_DIR/artifacts/sparkle/Sparkle/bin/generate_appcast
       (fetched by: swift package --package-path "$LSS_MACOS_DIR" --scratch-path "$LSS_BUILD_DIR" resolve),
       or install Sparkle's tools with: brew install --cask sparkle  (puts generate_appcast on PATH).
MSG
  return 1
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
xmllint --noout "$APPCAST"
# generate_appcast only signs an enclosure when the archived app embeds SUPublicEDKey,
# i.e. when it was built with SPARKLE_PUBLIC_ED_KEY set. An unsigned entry is useless
# to a keyed app (Sparkle rejects it), so say so instead of committing it silently.
total="$(grep -c '<enclosure[^>]*/>' "$APPCAST" || true)"
signed="$(grep -c '<enclosure[^>]*sparkle:edSignature=' "$APPCAST" || true)"
if [[ "$total" -gt "$signed" ]]; then
  echo "appcast: warning — $((total - signed)) of $total enclosure(s) carry no sparkle:edSignature; the archived app has no SUPublicEDKey (build the release with SPARKLE_PUBLIC_ED_KEY set)" >&2
fi
echo "appcast: wrote $APPCAST ($signed of $total enclosure(s) signed)"
