#!/usr/bin/env bash
set -e
set -o pipefail

SCRIPT_NAME="lss-macos-network-tools"
TARGET="/usr/local/bin/lss-macos-network-tools"
ALIAS="/usr/local/bin/lss"

chmod +x "$SCRIPT_NAME"

sudo cp "$SCRIPT_NAME" "$TARGET"
sudo ln -sf "$TARGET" "$ALIAS"

echo "Installed successfully."
echo "Run the tool using:"
echo "  lss-macos-network-tools"
echo "or simply:"
echo "  lss"
