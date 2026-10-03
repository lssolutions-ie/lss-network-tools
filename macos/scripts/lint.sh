#!/usr/bin/env bash
# Static checks for the GUI tree and the bash engine it drives:
#   - bash -n on lss-network-tools.sh and every script here
#   - shellcheck (warning level) when installed
#   - swift package manifest sanity (swift package describe)
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

status=0
echo "lint: bash -n"
for f in "$LSS_REPO_DIR/lss-network-tools.sh" "$LSS_REPO_DIR/install.sh" "$LSS_MACOS_DIR"/scripts/*.sh; do
  if bash -n "$f"; then printf '  ok   %s\n' "${f#"$LSS_REPO_DIR"/}"; else printf '  FAIL %s\n' "$f"; status=1; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "lint: shellcheck (GUI scripts)"
  shellcheck -S warning -x "$LSS_MACOS_DIR"/scripts/*.sh || status=1
  echo "lint: shellcheck (engine, new warning classes only)"
  # Pre-existing informational classes in the 12k-line engine are tolerated.
  if shellcheck -S warning "$LSS_REPO_DIR/lss-network-tools.sh" \
      | grep -E 'SC[0-9]+' | grep -vE 'SC2034|SC2155|SC2076|SC2178|SC2128' ; then
    status=1
  else
    echo "  ok"
  fi
else
  echo "lint: shellcheck not installed (brew install shellcheck) — skipped"
fi

echo "lint: swift package describe"
(cd "$LSS_MACOS_DIR" && swift package describe --type json >/dev/null) && echo "  ok"

exit "$status"
