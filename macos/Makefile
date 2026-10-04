# LSS Network Tools — macOS GUI
# Everything runs from the command line; Xcode is never opened.
# Build products go to $LSS_GUI_BUILD_DIR (default: ~/Library/Caches/ie.lssolutions.lss-network-tools/build),
# outside this iCloud-synced checkout; see scripts/common.sh.

SHELL := /bin/bash
BUILD_DIR := $(or $(LSS_GUI_BUILD_DIR),$(HOME)/Library/Caches/ie.lssolutions.lss-network-tools/build)
OUT   ?= $(BUILD_DIR)/screenshots/shot.png
VIEW  ?= audit
DELAY ?= 4
# Extra automation flags for `make screenshot`, e.g.
#   ARGS="--select-run 0 --tab tasks --task 5 --collapse-grid"
#   ARGS="--output-dir Tests/Fixtures/synthetic-run --select-run 0 --tab tasks --task 10 --collapse-grid"
ARGS  ?=

.PHONY: help check-toolchain build release run install screenshot test lint fixtures dmg sign notarize appcast clean

help:
	@echo "targets: check-toolchain build release run screenshot [OUT=… VIEW=audit|task-N|runs|settings|new-run|consent|setup|session-guard ARGS=…] test lint fixtures"
	@echo "         install (release build → /Applications, re-register the helper, open Setup & Permissions; refuses while an audit runs — LSS_INSTALL_FORCE=1 overrides; LSS_INSTALL_UNIVERSAL=1 for a universal binary)"
	@echo "         dmg (universal release build → DMG; a debug app is refused unless LSS_DMG_ALLOW_DEBUG=1)"
	@echo "         sign (re-sign the built app with CODESIGN_IDENTITY)"
	@echo "         notarize (release → notarize app → dmg → notarize dmg; skips without NOTARY_KEYCHAIN_PROFILE)"
	@echo "         appcast (regenerate appcast.xml with SPARKLE_PRIVATE_KEY_FILE, skips without it)"
	@echo "build dir: $(BUILD_DIR)"

check-toolchain:
	@scripts/check-toolchain.sh

# Debug build: what run, screenshot and test use.
build:
	@scripts/build-app.sh debug

# Universal release build: what dmg and notarize package. Both write the same
# $(BUILD_DIR)/app/LSS Network Tools.app (plus app/.build-config saying which one it is).
release:
	@scripts/build-app.sh release --universal

run: build
	@scripts/run-app.sh

# Personal-use install (scripts/install-app.sh): release build → /Applications/LSS Network
# Tools.app, stale helper registrations dropped and the helper registered again from the
# installed copy (an ad-hoc cdhash changes with every build), then the app opens its
# Setup & Permissions window. Runs as the user; never sudo. Run it after every rebuild.
# Every step prints at least one `install:` line (the helper's own output is indented
# under it); it refuses while an audit started from the app is running.
install:
	@scripts/install-app.sh

screenshot: build
	@scripts/screenshot.sh "$(OUT)" "$(VIEW)" "$(DELAY)" $(ARGS)

test:
	@swift test --scratch-path "$(BUILD_DIR)"

# Static checks (scripts/lint.sh): iCloud conflict copies, bash -n, shellcheck, manifest.
lint:
	@scripts/lint.sh

# Rebuild the fictional 20-task run from the anonymised fixtures (the structural leak
# checks run with `make test`; regenerating the real-run fixtures needs the private salt,
# see Tests/Fixtures/runs/README.md).
fixtures:
	@python3 scripts/make-synthetic-run.py

# Distribution, always from the universal release build. Each step skips with one
# clear line when credentials/keys are absent.
dmg: release
	@scripts/make-dmg.sh

sign:
	@scripts/sign.sh "$(BUILD_DIR)/app/LSS Network Tools.app"

notarize: release
	@scripts/notarize.sh "$(BUILD_DIR)/app/LSS Network Tools.app"
	@scripts/make-dmg.sh
	@scripts/notarize.sh "$(BUILD_DIR)/dist/LSS-Network-Tools-$(shell tr -d '[:space:]' < VERSION).dmg"

appcast:
	@scripts/release-appcast.sh "$(BUILD_DIR)/dist"

clean:
	rm -rf "$(BUILD_DIR)" .build
