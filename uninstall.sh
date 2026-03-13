#!/usr/bin/env bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname)" in
  Darwin)
    exec "$SCRIPT_DIR/uninstall/uninstall-macos.sh"
    ;;
  Linux)
    exec "$SCRIPT_DIR/uninstall/uninstall-linux.sh"
    ;;
  *)
    echo "Unsupported operating system: $(uname)"
    echo "Supported operating systems are macOS (Darwin) and Linux."
    exit 1
    ;;
esac
