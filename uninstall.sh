#!/usr/bin/env bash
set -e
set -o pipefail

MAIN="/usr/local/bin/lss-macos-network-tools"
ALIAS="/usr/local/bin/lss"

if [[ -f "$MAIN" ]]; then
  sudo rm "$MAIN"
  echo "Removed $MAIN"
else
  echo "$MAIN not found."
fi

if [[ -L "$ALIAS" || -f "$ALIAS" ]]; then
  sudo rm "$ALIAS"
  echo "Removed $ALIAS"
else
  echo "$ALIAS not found."
fi

echo "Uninstall complete."
