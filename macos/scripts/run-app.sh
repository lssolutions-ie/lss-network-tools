#!/usr/bin/env bash
# Launches the built app through LaunchServices (so TCC prompts and Bundle.main
# behave as for a normal double-click). Build first with scripts/build-app.sh.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ -d "$LSS_APP" ]] || { echo "error: $LSS_APP not found — run make build" >&2; exit 1; }
open -n "$LSS_APP" --args "$@"
