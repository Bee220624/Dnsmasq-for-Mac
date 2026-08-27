# Dnsmasq for Mac build entry points.
#
# Every target here is a thin wrapper around a script in Scripts/, so that CI, the Makefile,
# and a developer's shell all run exactly the same code path.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT      := DnsmasqForMac.xcodeproj
SCHEME       := DnsmasqForMac
PACKAGE_PATH := Packages/MacNetCore
DERIVED_DATA := build/DerivedData
XCB          := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA)

# Keep xcodebuild output readable without hiding failures.
#
# A plain `tail` is wrong for tests: with more than one test bundle it truncates away an
# earlier bundle's summary, so a run can look like it covered less than it did — or hide a
# failure entirely. XCB_FILTER keeps every failure, every error, and each bundle's own summary.
XCB_FILTER := | grep -E "error:|Test run with|Executed .* test|\*\* (BUILD|TEST) (SUCCEEDED|FAILED)|recorded an issue" || true
XCPRETTY := | tail -40

.PHONY: help bootstrap generate build test test-all test-package test-xcode test-ui \
        check-localization \
        screenshots \
        vendor-dnsmasq verify-bundle install-dev clean

help:
	@echo "Dnsmasq for Mac — available targets"
	@echo ""
	@echo "  bootstrap       install development tooling and generate the Xcode project"
	@echo "  generate        regenerate DnsmasqForMac.xcodeproj from project.yml"
	@echo "  build           build app + helper (Debug)"
	@echo "  test            run package tests and integration tests (no human input needed)"
	@echo "  test-ui         run UI tests (needs a one-time macOS automation authorization)"
	@echo "  test-all        test + test-ui"
	@echo "  screenshots     render each page, in every shipped language"
	@echo "  check-localization  assert every localizable string is translated"
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
	@$(XCB) -configuration Debug \
		-only-testing:HelperIntegrationTests \
		-only-testing:DnsmasqForMacTests test $(XCB_FILTER)

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
	@$(XCB) -configuration Debug \
		-only-testing:DnsmasqForMacUITests test $(XCB_FILTER)

test: test-package test-xcode

test-all: test test-ui

# Renders every page to build/Screenshots/<language>/, in each language the app ships in.
#
# Off-screen via NSHostingView, so it needs no window server and no Screen Recording
# permission and works headless. The language is chosen through AppleLanguages — the same
# mechanism macOS uses for any app — so the output is localized exactly as the app would be.
SCREENSHOT_TOOL := $(DERIVED_DATA)/Build/Products/Debug/DnsmasqForMacScreenshots.app/Contents/MacOS/DnsmasqForMacScreenshots
SCREENSHOT_LANGUAGES := en zh-Hans

# Uses the compiler's own list of localizable strings, so it catches literals a grep over the
# sources would miss.
check-localization: build
	@Scripts/check-localization.sh

screenshots: generate
	@echo "==> building the screenshot tool"
	@xcodebuild -project $(PROJECT) -scheme DnsmasqForMacScreenshots \
		-derivedDataPath $(DERIVED_DATA) -configuration Debug build $(XCB_FILTER)
	@for lang in $(SCREENSHOT_LANGUAGES); do \
		echo "==> rendering $$lang"; \
		rm -rf build/Screenshots/$$lang; \
		"$(SCREENSHOT_TOOL)" --output "$(PWD)/build/Screenshots/$$lang" \
			-AppleLanguages "($$lang)" -AppleLocale "$$lang" || exit 1; \
	done

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
