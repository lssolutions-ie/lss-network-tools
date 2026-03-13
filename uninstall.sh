#!/bin/bash
set -e
set -o pipefail

TARGET_PATH="/usr/local/bin/lss"

if [[ -f "$TARGET_PATH" ]]; then
  sudo rm "$TARGET_PATH"
  echo "Removed $TARGET_PATH"
else
  echo "$TARGET_PATH is not installed."
fi
