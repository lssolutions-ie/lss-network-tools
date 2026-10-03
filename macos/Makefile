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

.PHONY: help check-toolchain build release run screenshot test fixtures clean

help:
	@echo "targets: check-toolchain build release run screenshot [OUT=… VIEW=audit|task-N|runs|settings ARGS=…] test fixtures clean"
	@echo "build dir: $(BUILD_DIR)"

check-toolchain:
	@scripts/check-toolchain.sh

build:
	@scripts/build-app.sh debug

release:
	@scripts/build-app.sh release --universal

run: build
	@scripts/run-app.sh

screenshot: build
	@scripts/screenshot.sh "$(OUT)" "$(VIEW)" "$(DELAY)" $(ARGS)

test:
	@swift test --scratch-path "$(BUILD_DIR)"

# Rebuild the fictional 20-task run from the fixtures and re-run the plaintext-free leak scan.
fixtures:
	@python3 scripts/make-synthetic-run.py
	@python3 scripts/anonymize-run.py --dest Tests/Fixtures/runs --verify-leak-list Tests/Fixtures/leak-check.txt

clean:
	rm -rf "$(BUILD_DIR)" .build
