#!/bin/bash
set -e
set -o pipefail

SCRIPT_NAME="lss-macos-network-tools"
TARGET_PATH="/usr/local/bin/lss"

if [[ ! -f "$SCRIPT_NAME" ]]; then
  echo "Error: $SCRIPT_NAME not found in current directory."
  exit 1
fi

chmod +x "$SCRIPT_NAME"
sudo cp "$SCRIPT_NAME" "$TARGET_PATH"
sudo chmod +x "$TARGET_PATH"

echo "Installation complete."
echo "Run the tool with: lss"
