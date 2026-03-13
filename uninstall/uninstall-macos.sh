#!/usr/bin/env bash
set -e
set -o pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This uninstaller is intended for macOS."
  exit 1
fi

MAIN="/usr/local/bin/lss-network-tools"
LEGACY="/usr/local/bin/lss-macos-network-tools"

if [[ -f "$MAIN" || -L "$MAIN" ]]; then
  sudo rm "$MAIN"
  echo "Removed $MAIN"
else
  echo "$MAIN not found."
fi

if [[ -f "$LEGACY" || -L "$LEGACY" ]]; then
  sudo rm "$LEGACY"
  echo "Removed $LEGACY"
else
  echo "$LEGACY not found."
fi

echo "Uninstall complete."
