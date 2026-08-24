# MacNetLab build entry points (ticket §Phase 1).
#
# Every target here is a thin wrapper around a script in Scripts/, so that CI, the Makefile,
# and a developer's shell all run exactly the same code path.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT      := MacNetLab.xcodeproj
SCHEME       := MacNetLab
PACKAGE_PATH := Packages/MacNetCore
DERIVED_DATA := build/DerivedData
XCB          := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA)

# Keep xcodebuild output readable without hiding failures.
XCPRETTY := | tail -40

.PHONY: help bootstrap generate build test test-all test-package test-xcode test-ui \
        vendor-dnsmasq verify-bundle install-dev clean

help:
	@echo "MacNetLab — available targets"
	@echo ""
	@echo "  bootstrap       install development tooling and generate the Xcode project"
	@echo "  generate        regenerate MacNetLab.xcodeproj from project.yml"
	@echo "  build           build app + helper (Debug)"
	@echo "  test            run package tests and integration tests (no human input needed)"
	@echo "  test-ui         run UI tests (needs a one-time macOS automation authorization)"
	@echo "  test-all        test + test-ui"
	@echo "  vendor-dnsmasq  fetch, verify, build, and stage dnsmasq 2.x as Universal 2"
	@echo "  verify-bundle   assert the built bundle meets the security checklist"
	@echo "  install-dev     stage a development build into /Applications"
	@echo "  clean           remove build output"

bootstrap:
	@Scripts/bootstrap.sh

generate:
	@Scripts/generate-project.sh

build: generate
	@echo "==> building $(SCHEME) (Debug)"
	@set -o pipefail; $(XCB) -configuration Debug build $(XCPRETTY)

# The shared core is a SwiftPM package and is tested directly; that keeps the pure logic
# suites fast and runnable without an Xcode project.
test-package:
	@echo "==> swift test ($(PACKAGE_PATH))"
	@swift test --package-path $(PACKAGE_PATH)

test-xcode: generate
	@echo "==> xcodebuild test ($(SCHEME)) — integration targets"
	@set -o pipefail; $(XCB) -configuration Debug \
		-only-testing:HelperIntegrationTests \
		-only-testing:MacNetLabTests test $(XCPRETTY)

# UI tests are separated from the default `test` target on purpose.
#
# XCUITest asks macOS for permission to drive another application. That authorization is a
# LocalAuthentication prompt which must be answered by a human at the keyboard; until it is
# granted, the runner fails with "Failed to initialize for UI testing" and xcodebuild sits
# waiting. Folding that into `make test` would make the whole suite unrunnable in CI and in
# any non-interactive shell, so the human-gated part is its own target.
# See Docs/RISKS.md R-11.
test-ui: generate
	@echo "==> xcodebuild test ($(SCHEME)) — UI targets"
	@echo "    Requires a one-time authorization; see Docs/RISKS.md R-11."
	@set -o pipefail; $(XCB) -configuration Debug \
		-only-testing:MacNetLabUITests test $(XCPRETTY)

test: test-package test-xcode

test-all: test test-ui

vendor-dnsmasq:
	@Scripts/build-dnsmasq.sh

verify-bundle:
	@Scripts/verify-bundle.sh

install-dev:
	@Scripts/install-dev-app.sh

clean:
	@echo "==> cleaning"
	@rm -rf build
	@rm -rf $(PACKAGE_PATH)/.build
	@if [ -d "$(PROJECT)" ]; then $(XCB) clean >/dev/null 2>&1 || true; fi
	@echo "==> done"
