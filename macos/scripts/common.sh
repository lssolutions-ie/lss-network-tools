# shellcheck shell=bash
# Shared locations for the macOS GUI build scripts. Source, do not execute.
#
# Build products live OUTSIDE the repository by default: this checkout sits in
# ~/Documents, which a file provider (iCloud Drive) decorates with
# com.apple.FinderInfo / com.apple.fileprovider.* extended attributes, and
# codesign rejects such "detritus" inside bundles. Override with
# LSS_GUI_BUILD_DIR if you want the products elsewhere.

LSS_MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSS_REPO_DIR="$(cd "$LSS_MACOS_DIR/.." && pwd)"
LSS_BUILD_DIR="${LSS_GUI_BUILD_DIR:-$HOME/Library/Caches/ie.lssolutions.lss-network-tools/build}"
LSS_APP_NAME="LSS Network Tools"
LSS_EXECUTABLE="LSSNetworkTools"
LSS_BUNDLE_ID="ie.lssolutions.lss-network-tools"
LSS_APP="$LSS_BUILD_DIR/app/$LSS_APP_NAME.app"
LSS_SCREENSHOT_DIR="$LSS_BUILD_DIR/screenshots"

export LSS_MACOS_DIR LSS_REPO_DIR LSS_BUILD_DIR LSS_APP_NAME LSS_EXECUTABLE LSS_BUNDLE_ID LSS_APP LSS_SCREENSHOT_DIR
