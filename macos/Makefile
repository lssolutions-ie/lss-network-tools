# LSS Network Tools — macOS GUI
# Everything runs from the command line; Xcode is never opened.
# Build products go to $LSS_GUI_BUILD_DIR (default: ~/Library/Caches/ie.lssolutions.lss-network-tools/build),
# outside this iCloud-synced checkout; see scripts/common.sh.

SHELL := /bin/bash
BUILD_DIR := $(or $(LSS_GUI_BUILD_DIR),$(HOME)/Library/Caches/ie.lssolutions.lss-network-tools/build)
OUT   ?= $(BUILD_DIR)/screenshots/shot.png
VIEW  ?= audit
DELAY ?= 4

.PHONY: help check-toolchain build release run screenshot test clean

help:
	@echo "targets: check-toolchain build release run screenshot [OUT=… VIEW=audit|task-N|runs|settings] test clean"
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
	@scripts/screenshot.sh "$(OUT)" "$(VIEW)" "$(DELAY)"

test:
	@swift test --scratch-path "$(BUILD_DIR)"

clean:
	rm -rf "$(BUILD_DIR)" .build
