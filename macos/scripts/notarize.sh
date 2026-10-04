#!/usr/bin/env bash
# Submits an app bundle or DMG to Apple's notary service and staples the ticket.
#
#   scripts/notarize.sh <path/to/LSS Network Tools.app | path/to/file.dmg>
#
# Credentials (one of):
#   NOTARY_KEYCHAIN_PROFILE   profile created with `xcrun notarytool store-credentials <name>`
#   NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD   (app-specific password)
#
# Without credentials the script prints one "skipped" line and exits 0, so
# `make notarize` is safe on machines without a Developer ID. An ad-hoc signed
# build (no CODESIGN_IDENTITY) cannot be notarized; the script says so and skips.
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <app or dmg>" >&2
  exit 2
fi
if [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" && -z "${NOTARY_APPLE_ID:-}" ]]; then
  echo "notarize: skipped — no credentials (set NOTARY_KEYCHAIN_PROFILE, or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD)"
  exit 0
fi
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "notarize: skipped — CODESIGN_IDENTITY is unset, so the build is ad-hoc signed and cannot be notarized"
  exit 0
fi
[[ -e "$TARGET" ]] || { echo "error: $TARGET does not exist" >&2; exit 1; }

SUBMIT="$TARGET"
CLEANUP=""
if [[ -d "$TARGET" ]]; then
  # notarytool takes a zip for bundles; the ticket is stapled to the bundle itself.
  SUBMIT="$(mktemp -d /tmp/lss-notarize-XXXXXX)/upload.zip"
  CLEANUP="$(dirname "$SUBMIT")"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi
trap '[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"' EXIT

args=(submit "$SUBMIT" --wait)
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  args+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  : "${NOTARY_TEAM_ID:?NOTARY_TEAM_ID is required with NOTARY_APPLE_ID}"
  : "${NOTARY_PASSWORD:?NOTARY_PASSWORD is required with NOTARY_APPLE_ID}"
  args+=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

echo "notarize: submitting $TARGET"
xcrun notarytool "${args[@]}"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "notarize: stapled $TARGET"
