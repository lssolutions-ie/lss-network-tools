#!/usr/bin/env bash
# Produces a PNG of the running app for build evidence.
#
#   scripts/screenshot.sh [out.png] [view] [delay-seconds]
#   view: audit | task-N | runs | settings      (default: audit)
#
# Strategy 1 (exact pixels): launch the app on the requested view, find its
# window id, and `screencapture -l` it. This needs Screen Recording permission
# for the terminal running the script; when that is missing macOS returns a
# blank image, which is detected.
# Strategy 2 (no permission needed): the app's own `--screenshot` flag renders
# the window with cacheDisplay. Good for most views; scrolled lists may render
# unclipped.
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

OUT="${1:-$LSS_SCREENSHOT_DIR/shot-$(date +%Y%m%d-%H%M%S).png}"
VIEW="${2:-audit}"
DELAY="${3:-5}"

[[ -d "$LSS_APP" ]] || { echo "error: $LSS_APP not found — run make build" >&2; exit 1; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

quit_app() {
  osascript -e 'tell application "LSS Network Tools" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$LSS_EXECUTABLE" >/dev/null 2>&1 || true
}

report() {
  local width height
  width="$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')"
  echo "screenshot: $1 (${width}x${height}, $2)"
}

# Returns 0 when the image is essentially a single colour (blank capture).
is_blank() {
  # Downscale to 1x1: a uniform image stays uniform; the average of a real UI
  # does too, so compare a few sample points instead via sips min/max is not
  # available — use a Python-free heuristic: file size of a PNG of a blank
  # window is tiny.
  local size
  size="$(stat -f '%z' "$1" 2>/dev/null || echo 0)"
  [[ "$size" -lt 20000 ]]
}

# --- strategy 1: window server capture ----------------------------------------
quit_app
open -n "$LSS_APP" --args --view "$VIEW" --no-exit
sleep "$DELAY"
WINDOW_ID="$(swift "$LSS_MACOS_DIR/scripts/window-id.swift" "$LSS_APP_NAME" 2>/dev/null || true)"
if [[ -n "$WINDOW_ID" ]]; then
  screencapture -x -o -l "$WINDOW_ID" "$OUT" 2>/dev/null || true
fi
quit_app
if [[ -s "$OUT" ]] && ! is_blank "$OUT"; then
  report "$OUT" "window capture"
  exit 0
fi
rm -f "$OUT"
echo "screenshot: window capture unavailable (Screen Recording permission?) — using in-app render" >&2

# --- strategy 2: in-app render -------------------------------------------------
open -n -W "$LSS_APP" --args --screenshot "$OUT" --view "$VIEW" --delay "$DELAY"
for _ in $(seq 1 20); do
  [[ -s "$OUT" ]] && break
  sleep 1
done
if [[ ! -s "$OUT" ]]; then
  echo "error: screenshot was not produced at $OUT" >&2
  echo "       check Console.app for 'LSSNetworkTools: screenshot' messages" >&2
  exit 1
fi
report "$OUT" "in-app render"
