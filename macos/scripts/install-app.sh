#!/usr/bin/env bash
# Installs the GUI on this Mac for personal use: build → copy to /Applications →
# re-register the privileged helper → open the Setup & Permissions window.
#
#   scripts/install-app.sh            (make install)
#
# Runs as the user, never with sudo. The app is ad-hoc signed for good (no Developer
# ID), which has two consequences this script is built around:
#   * launchd pins the registered helper to the app's cdhash, and an ad-hoc cdhash
#     changes on every rebuild — so every install unregisters the helper from every
#     copy it can find and registers it again from the installed copy; macOS may ask
#     for approval again under Login Items & Extensions.
#   * a locally built app carries no quarantine attribute, so Gatekeeper is not
#     involved: installing is copying the built bundle to /Applications.
#
# The only path this script ever removes is the constant /Applications/LSS Network
# Tools.app, and only after its Info.plist was verified to carry our bundle id.
# Environment: LSS_INSTALL_UNIVERSAL=1 builds a universal binary (default: native arch);
#              LSS_INSTALL_FORCE=1 installs even while an audit started from the app is
#              running (quitting the app aborts that run — see refuse_if_audit_running).
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

INSTALLED_APP="/Applications/LSS Network Tools.app"
APPLICATIONS_DIR="/Applications"
WRAPPER="/usr/local/bin/lss-network-tools"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

log()  { printf 'install: %s\n' "$*"; }
fail() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" == "0" ]]; then
  fail "run this as your own user, not with sudo (the helper registration and the privacy prompts belong to your account)"
fi

# An audit must not be cut off: quitting the app closes the pty (SIGHUP to sudo and the
# engine) or drops the helper's XPC session (the helper ends its orphaned children) —
# either way the run is left with a partial task and a partial report. Checked before
# the build, so the owner hears it before waiting minutes, and again right before the
# quit, because a run may have been started meanwhile.
refuse_if_audit_running() {
  [[ "${LSS_INSTALL_FORCE:-0}" == "1" ]] && return 0
  local pids
  pids="$(pgrep -f -- 'lss-network-tools\.sh .*--(run-task|build-report)( |$)' || true)"
  [[ -z "$pids" ]] && return 0
  fail "an audit or report build is running (lss-network-tools --run-task/--build-report, pid(s): ${pids//$'\n'/ }); let it finish or stop it in the app, then run make install again (LSS_INSTALL_FORCE=1 overrides)"
}
refuse_if_audit_running

# --- 1. build -----------------------------------------------------------------------
build_args=(release)
if [[ "${LSS_INSTALL_UNIVERSAL:-0}" == "1" ]]; then
  build_args+=(--universal)
  log "building the universal release app"
else
  log "building the release app ($(uname -m))"
fi
"$LSS_MACOS_DIR/scripts/build-app.sh" "${build_args[@]}"
[[ -d "$LSS_APP" ]] || fail "build finished but $LSS_APP is missing"
[[ -x "$LSS_APP/Contents/MacOS/$LSS_EXECUTABLE" ]] || fail "built app has no executable at Contents/MacOS/$LSS_EXECUTABLE"

# --- 2. verify the target before touching it ------------------------------------------
# Only a bundle with our CFBundleIdentifier is ever removed from /Applications.
bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}
[[ -d "$APPLICATIONS_DIR" && -w "$APPLICATIONS_DIR" ]] || fail "$APPLICATIONS_DIR is not writable by $(id -un); add your account to the admin group or install from an administrator account (never with sudo)"
OLD_COPY_PRESENT=0
if [[ -e "$INSTALLED_APP" || -L "$INSTALLED_APP" ]]; then
  [[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] || fail "$INSTALLED_APP exists but is not a directory — remove it yourself, nothing was changed"
  existing_id="$(bundle_id_of "$INSTALLED_APP")"
  if [[ "$existing_id" != "$LSS_BUNDLE_ID" ]]; then
    fail "$INSTALLED_APP has CFBundleIdentifier '${existing_id:-<none>}', expected '$LSS_BUNDLE_ID' — not ours, nothing was changed"
  fi
  # The whole tree must be deletable by this user: a copy placed with sudo (root-owned
  # contents) would make rm -rf fail half-way, after the app was quit.
  foreign="$(find "$INSTALLED_APP" ! -user "$(id -u)" -print -quit 2>/dev/null || true)"
  if [[ -n "$foreign" ]]; then
    fail "$INSTALLED_APP contains files not owned by $(id -un) (e.g. $foreign) — it was probably installed with sudo; remove it yourself (sudo rm -rf \"$INSTALLED_APP\"), then run make install again; nothing was changed"
  fi
  OLD_COPY_PRESENT=1
  log "existing copy verified ($LSS_BUNDLE_ID, version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo unknown))"
else
  log "no copy at $INSTALLED_APP yet"
fi

# --- 3. quit a running app ------------------------------------------------------------
refuse_if_audit_running
if pgrep -x "$LSS_EXECUTABLE" >/dev/null 2>&1; then
  log "quitting the running app"
  osascript -e "tell application id \"$LSS_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  waited=0
  while pgrep -x "$LSS_EXECUTABLE" >/dev/null 2>&1 && (( waited < 10 )); do
    sleep 1
    waited=$(( waited + 1 ))
  done
  if pgrep -x "$LSS_EXECUTABLE" >/dev/null 2>&1; then
    log "the app did not quit within 10 s — terminating it"
    pkill -x "$LSS_EXECUTABLE" || true
    sleep 1
    if pgrep -x "$LSS_EXECUTABLE" >/dev/null 2>&1; then
      # Replacing the bundle under a live process would leave it running the old code
      # while the new copy registers the helper.
      fail "the app is still running (a modal dialog or a password prompt may be holding it) — quit it yourself, then run make install again; nothing was changed"
    fi
  fi
else
  log "the app is not running"
fi

# --- 4. drop stale helper registrations -----------------------------------------------
# launchd pins the daemon to the cdhash of the copy that registered it; both the old
# installed copy and the build-dir copy may hold a registration. Not fatal: the new
# copy registers again below, and a leftover is visible in Settings → Privileges.
# A copy whose automation does not know a flag would ignore it and open the GUI
# (and this script would wait on it), so the flag is looked up in the binary first.
knows_flag() {
  local count
  count="$(strings -a "$1" | grep -F -x -c -- "$2" || true)"
  [[ "${count:-0}" -gt 0 ]]
}
unregister_helper_from() {
  local copy="$1" label="$2" binary
  binary="$copy/Contents/MacOS/$LSS_EXECUTABLE"
  [[ -x "$binary" ]] || return 0
  if [[ "$(bundle_id_of "$copy")" != "$LSS_BUNDLE_ID" ]]; then
    log "skipping helper unregistration from the $label copy (not our bundle id)"
    return 0
  fi
  if ! knows_flag "$binary" "--unregister-helper"; then
    log "the $label copy predates --unregister-helper; its registration is replaced by the new copy's (use Re-register in the Setup window if the helper does not answer)"
    return 0
  fi
  if "$binary" --unregister-helper 2>&1 | sed 's/^/install:   /'; then
    log "helper unregistered from the $label copy ($copy)"
  else
    log "warning: --unregister-helper failed for the $label copy ($copy); continuing"
  fi
}
if [[ "$OLD_COPY_PRESENT" -eq 1 ]]; then
  unregister_helper_from "$INSTALLED_APP" "installed"
fi
unregister_helper_from "$LSS_APP" "build-dir"

# --- 5. install the new copy ----------------------------------------------------------
if [[ "$OLD_COPY_PRESENT" -eq 1 ]]; then
  log "removing the old copy at $INSTALLED_APP"
  rm -rf "$INSTALLED_APP" || fail "could not remove the old copy at $INSTALLED_APP — remove it yourself, then run make install again"
fi
log "copying $LSS_APP → $INSTALLED_APP"
ditto "$LSS_APP" "$INSTALLED_APP"
[[ -x "$INSTALLED_APP/Contents/MacOS/$LSS_EXECUTABLE" ]] || fail "copy finished but $INSTALLED_APP has no executable"
if [[ -x "$LSREGISTER" ]]; then
  if "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1; then
    log "registered with LaunchServices"
  else
    log "warning: lsregister failed (LaunchServices will pick the app up on its own)"
  fi
else
  log "warning: lsregister not found at $LSREGISTER — skipped"
fi
if codesign --verify --strict "$INSTALLED_APP" 2>/dev/null; then
  signature="$(codesign -dv "$INSTALLED_APP" 2>&1 | sed -n 's/^Signature=//p' || true)"
  log "signature verified (${signature:-unknown})"
else
  fail "codesign --verify --strict failed for $INSTALLED_APP — the copied bundle is not intact"
fi
# The installed copy must be the only one macOS can find: Background Task Management
# records the helper's parent app by bundle identifier *and* path, and while the build
# directory still holds a bundle with our identifier, a registration from /Applications
# re-enables that old record (old path, old cdhash) and launchd then refuses to spawn
# the helper (OS_REASON_CODESIGNING). Observed on macOS 27. `make build`/`make run`/
# `make screenshot` recreate the build-dir copy whenever they need it.
log "removing the build-dir copy so launchd and Login Items track the installed copy only"
rm -rf "$LSS_APP"
"$LSREGISTER" -u "$LSS_APP" >/dev/null 2>&1 || true

# --- 6. register the helper from the installed copy -----------------------------------
# Exit 0 also covers "waiting for approval": the user allows it under System Settings →
# General → Login Items & Extensions, which the app opens. `--register-helper` ends with
# a `version()` probe; when the helper does not answer right after registering, the
# record still points at a previous copy — one unregister/register cycle from the
# installed copy makes Background Task Management follow the new path.
REGISTER_OUTPUT=""
register_helper_from_installed() {
  REGISTER_OUTPUT="$("$INSTALLED_APP/Contents/MacOS/$LSS_EXECUTABLE" --register-helper 2>&1 | grep -v NSFontManager || true)"
  printf '%s\n' "$REGISTER_OUTPUT" | sed 's/^/install:   /'
  [[ "$REGISTER_OUTPUT" == *"version(): helper"* ]]
}
log "registering the privileged helper from the installed copy"
if register_helper_from_installed; then
  log "helper registered and answering"
elif [[ "$REGISTER_OUTPUT" == *"requiresApproval"* ]]; then
  # Waiting for the user's approval: the helper cannot answer yet, and another
  # unregister/register cycle would only repeat the same request.
  log "the helper is registered and waiting for your approval — allow 'LSS Network Tools' under System Settings → General → Login Items & Extensions → Allow in the Background, then use Check Again in the Setup window"
else
  log "the helper did not answer after registering — unregistering and registering once more"
  "$INSTALLED_APP/Contents/MacOS/$LSS_EXECUTABLE" --unregister-helper 2>&1 | grep -v NSFontManager | sed 's/^/install:   /' || true
  sleep 3
  if register_helper_from_installed; then
    log "helper registered and answering"
  else
    log "warning: the helper is registered but not answering yet — approve it under Login Items if System Settings opened, then use Check Again (or Re-register) in the Setup window"
  fi
fi

# --- 7. command-line tool check -------------------------------------------------------
# The app needs the engine from the same checkout (non-interactive mode). It is never
# installed from here: the engine install needs root, and this script must not use sudo.
repo_version="$(sed -n 's/^APP_VERSION="\{0,1\}\(v[0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$LSS_REPO_DIR/lss-network-tools.sh" | head -n 1)"
installed_version=""
if [[ -x "$WRAPPER" ]]; then
  installed_version="$("$WRAPPER" --version 2>/dev/null | sed -n 's/.*\(v[0-9][0-9.]*\).*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$installed_version" ]]; then
  log "command-line tool: not installed at $WRAPPER"
  log "  install it from the repository root (needs root; run it yourself):  cd \"$LSS_REPO_DIR\" && sudo ./install.sh"
elif [[ -n "$repo_version" && "$(printf '%s\n%s\n' "$installed_version" "$repo_version" | sort -V | tail -n 1)" != "$installed_version" ]]; then
  log "command-line tool: $installed_version installed, this checkout is $repo_version"
  log "  update it from the repository root (needs root; run it yourself):  cd \"$LSS_REPO_DIR\" && sudo ./install.sh"
else
  log "command-line tool: $installed_version installed${repo_version:+ (checkout $repo_version)}"
fi

# --- 8. open the Setup & Permissions window -------------------------------------------
log "opening the app with --setup"
open "$INSTALLED_APP" --args --setup || log "warning: open failed; start the app from /Applications and choose Setup & Permissions… from the app menu"
log "done — approve the helper in Login Items when System Settings opens, then work through the Setup window"
