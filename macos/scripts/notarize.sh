#!/usr/bin/env bash
# Submits an app bundle or DMG to Apple's notary service and staples the ticket.
#
#   NOTARY_KEYCHAIN_PROFILE=<profile> scripts/notarize.sh <path/to/LSS Network Tools.app | path/to/file.dmg>
#
# Credentials come only from a notarytool keychain profile. Create it once with
#
#   xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>
#
# which prompts for the app-specific password and stores it in the login keychain.
# The password is deliberately not accepted through the environment or on the
# command line: `notarytool submit --password …` is visible to every process via ps.
#
# Without NOTARY_KEYCHAIN_PROFILE the script prints one "skipped" line and exits 0,
# so `make notarize` is safe on machines without a Developer ID. An ad-hoc signed
# build (no CODESIGN_IDENTITY) cannot be notarized; the script says so and skips.
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <app or dmg>" >&2
  exit 2
fi
if [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  echo "notarize: skipped — NOTARY_KEYCHAIN_PROFILE is unset (create one with: xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>)"
  exit 0
fi
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "notarize: skipped — CODESIGN_IDENTITY is unset, so the build is ad-hoc signed and cannot be notarized"
  exit 0
fi
[[ -e "$TARGET" ]] || { echo "error: $TARGET does not exist" >&2; exit 1; }

# The cleanup trap is armed before anything is created, so an interrupted ditto
# never leaves the upload directory behind.
CLEANUP=""
trap 'if [[ -n "$CLEANUP" ]]; then rm -rf "$CLEANUP"; fi' EXIT
SUBMIT="$TARGET"
if [[ -d "$TARGET" ]]; then
  # notarytool takes a zip for bundles; the ticket is stapled to the bundle itself.
  CLEANUP="$(mktemp -d "${TMPDIR:-/tmp}/lss-notarize-XXXXXX")"
  SUBMIT="$CLEANUP/upload.zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "notarize: submitting $TARGET (keychain profile '$NOTARY_KEYCHAIN_PROFILE')"
xcrun notarytool submit "$SUBMIT" --wait --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "notarize: stapled $TARGET"
