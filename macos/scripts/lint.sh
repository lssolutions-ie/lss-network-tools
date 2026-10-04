#!/usr/bin/env bash
# Static checks for the GUI tree and the bash engine it drives:
#   - stray iCloud conflict copies under macos/
#   - bash -n on lss-network-tools.sh, install.sh and every script here
#   - shellcheck (warning level) when installed; the engine is checked with its
#     pre-existing informational classes excluded (-e), everything else fails
#   - swift package manifest sanity (swift package describe)
# Every gate is tested on the command's exit status (never on grep output in a
# pipeline, which pipefail would mask), so a failure really fails the script.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

status=0
# iCloud Drive (this checkout lives in ~/Documents) leaves "name 2.ext" conflict copies behind
# after fast rewrites; a stray .swift copy compiles, a stray fixture breaks the tests.
echo "lint: stray iCloud conflict copies"
if find "$LSS_MACOS_DIR" -type f -name '* [0-9].*' -not -path '*/.build/*' | grep . ; then
  echo "  FAIL: delete the files above (find macos -name '* [0-9].*' -delete)"
  status=1
else
  echo "  ok"
fi
echo "lint: bash -n"
for f in "$LSS_REPO_DIR/lss-network-tools.sh" "$LSS_REPO_DIR/install.sh" "$LSS_MACOS_DIR"/scripts/*.sh; do
  if bash -n "$f"; then printf '  ok   %s\n' "${f#"$LSS_REPO_DIR"/}"; else printf '  FAIL %s\n' "$f"; status=1; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "lint: shellcheck (GUI scripts)"
  if shellcheck -S warning -x "$LSS_MACOS_DIR"/scripts/*.sh; then
    echo "  ok"
  else
    echo "  FAIL: shellcheck reported problems in macos/scripts (or could not run)"
    status=1
  fi
  echo "lint: shellcheck (engine, new warning classes only)"
  # Pre-existing informational classes in the 12k-line engine are excluded; any other
  # warning (or a shellcheck failure, exit 2–4) fails the gate.
  if shellcheck -S warning -e SC2034,SC2155,SC2076,SC2178,SC2128 "$LSS_REPO_DIR/lss-network-tools.sh"; then
    echo "  ok"
  else
    echo "  FAIL: shellcheck reported new warnings in lss-network-tools.sh (or could not run)"
    status=1
  fi
else
  echo "lint: shellcheck not installed (brew install shellcheck) — skipped"
fi

echo "lint: swift package describe"
if (cd "$LSS_MACOS_DIR" && swift package describe --type json >/dev/null); then
  echo "  ok"
else
  echo "  FAIL: swift package describe failed (Package.swift does not parse)"
  status=1
fi

exit "$status"
