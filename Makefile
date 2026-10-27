# bash, so the recipes below can `set -o pipefail`: `xcodebuild ... | tee <log>` must report
# xcodebuild's status, not tee's, or a failed build would look like a pass. pipefail is set
# per recipe rather than via .SHELLFLAGS because macOS ships GNU Make 3.81, which ignores it.
SHELL := /bin/bash

BUNDLE=rbenv exec bundle
LANG_VAR=LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
FASTLANE=$(LANG_VAR) $(BUNDLE) exec fastlane
# Explicit --config prevents SwiftLint from picking up nested configs in
# BuildTools/.build/checkouts/ (e.g., SwiftGenPlugin's .swiftlint.yml).
SWIFTLINT_FROM_BUILDTOOLS=swiftlint lint --working-directory .. --config .swiftlint.yml --quiet
# Parse the human-readable output of simctl
SIMULATOR_NAME = $(shell xcrun simctl list devices available \
	| grep "iPhone" \
	| tail -1 | sed 's/^[[:space:]]*//' | sed 's/ *(.*) *$$//')

# Never build the x86_64 simulator slice on Apple Silicon. A `generic/platform=iOS Simulator`
# destination has no active arch, so ONLY_ACTIVE_ARCH cannot narrow ARCHS: every source is
# compiled twice and the x86_64 link then fails anyway, because the prebuilt
# ThirdParty/llama-cpp-build/*/lfm/liblfm_runtime.a is arm64-only. Concrete destinations
# (`name=`/`id=`) already resolve ARCHS to the host arch, so this only costs on Intel hosts,
# where it deliberately stays empty.
HOST_ARCH = $(shell uname -m)
SIM_ARCH = $(if $(filter arm64,$(HOST_ARCH)),ARCHS=arm64,)

# Bound a hung test. PocketCastsTests/UnitTests.xctestplan sets `testTimeoutsEnabled` but no
# allowance, so without this a stuck test burns the caller's whole outer timeout.
TEST_TIMEOUT_FLAGS = -test-timeouts-enabled YES \
	-default-test-execution-time-allowance 60 \
	-maximum-test-execution-time-allowance 120

# Local iteration only. dwarf skips dsymutil, CODE_SIGNING_ALLOWED=NO skips CodeSign and the
# seven ValidateEmbeddedBinary tasks (the unsigned .app still installs and launches on a
# simulator), -disableAutomaticPackageResolution skips re-resolving 23 packages per
# invocation, and SKIP_LINT short-circuits the two always-run SwiftLint build phases.
# Do not use these for archives, device builds, or CI verification.
FAST_FLAGS = -disableAutomaticPackageResolution $(SIM_ARCH) \
	DEBUG_INFORMATION_FORMAT=dwarf CODE_SIGNING_ALLOWED=NO
FAST_ENV = SKIP_LINT=1

# Build logs land here (gitignored) so a killed or timed-out run still leaves its output
# behind instead of being swallowed by a `| grep | tail` pipeline.
LOG_DIR = artifacts

.PHONY: help build clean test lint lint_lenient format install_dependencies build_mac launch_mac debug debug_all build_fast test_fast

define run_in_buildtools
	@pushd BuildTools && \
	export SDKROOT=$$(xcrun --sdk macosx --show-sdk-path) && \
	swift package plugin \
		--allow-writing-to-directory .. \
		--allow-writing-to-package-directory \
		$(1) && \
	popd
endef

help: ## Show this list of commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

swift_percentage: ## Swift and Obj-C percentage on the project
	./scripts/count.rb

generate_colors: ## Generate colors and themes based on themes.csv
	ruby scripts/themes/generate_themes.rb scripts/themes/theme.csv

generate_code:
	$(call run_in_buildtools,generate-code-for-resources --config ../swiftgen.yml)

lint: ## Lint the codebase
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS))

lint_lenient:
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS) --lenient)

build: ensure_llama_ios ## Builds the Debug configuration using Xcode
	set -o pipefail; mkdir -p $(LOG_DIR) && xcodebuild -project podcasts.xcodeproj \
       -scheme pocketcasts \
       -configuration Debug \
       -destination 'generic/platform=iOS Simulator' \
       $(SIM_ARCH) \
       build 2>&1 | tee $(LOG_DIR)/build.log

clean: ## Cleans the build artifacts
	xcodebuild -project podcasts.xcodeproj \
       -scheme pocketcasts \
       -configuration Debug \
       clean

ONLY_TESTING ?= PocketCastsTests

test: ensure_llama_ios ## Build and run the PocketCastsTests target with Unit Tests using Xcode
	set -o pipefail; mkdir -p $(LOG_DIR) && xcodebuild test -project podcasts.xcodeproj \
	    -scheme pocketcasts \
        -only-testing:$(ONLY_TESTING) \
        $(TEST_TIMEOUT_FLAGS) \
        $(SIM_ARCH) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest' \
        2>&1 | tee $(LOG_DIR)/test.log

build_staging: ensure_llama_ios ## Builds using the StagingDebug configuration
	set -o pipefail; mkdir -p $(LOG_DIR) && xcodebuild -project podcasts.xcodeproj \
       -scheme "Pocket Casts Staging" \
       -configuration StagingDebug \
       -destination 'generic/platform=iOS Simulator' \
       $(SIM_ARCH) \
       build 2>&1 | tee $(LOG_DIR)/build_staging.log

test_staging: ensure_llama_ios ## Build and run Unit Tests using the StagingDebug configuration
	set -o pipefail; mkdir -p $(LOG_DIR) && xcodebuild test -project podcasts.xcodeproj \
	    -scheme "Pocket Casts Staging" \
        -only-testing:$(ONLY_TESTING) \
        $(TEST_TIMEOUT_FLAGS) \
        $(SIM_ARCH) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest' \
        2>&1 | tee $(LOG_DIR)/test_staging.log

build_fast: ensure_llama_ios ## Fast local StagingDebug build (no dSYM/signing/lint); not for CI
	set -o pipefail; mkdir -p $(LOG_DIR) && $(FAST_ENV) xcodebuild -project podcasts.xcodeproj \
       -scheme "Pocket Casts Staging" \
       -configuration StagingDebug \
       -destination 'generic/platform=iOS Simulator' \
       $(FAST_FLAGS) \
       build 2>&1 | tee $(LOG_DIR)/build_fast.log

test_fast: ensure_llama_ios ## Fast local test run (no dSYM/signing/lint); not for CI
	set -o pipefail; mkdir -p $(LOG_DIR) && $(FAST_ENV) xcodebuild test -project podcasts.xcodeproj \
	    -scheme "Pocket Casts Staging" \
        -only-testing:$(ONLY_TESTING) \
        $(TEST_TIMEOUT_FLAGS) \
        $(FAST_FLAGS) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest' \
        2>&1 | tee $(LOG_DIR)/test_fast.log

build_mac: ensure_llama_ios ## Builds for iOS Simulator (use for log stream on Mac)
	# $(SIM_ARCH), not a hardcoded ARCHS=arm64: Intel hosts are not supported, and
	# scripts/build-llama-ios.sh builds the simulator slice arm64-only ("no x86_64 simulator
	# slice"), so an Intel build fails loudly at the x86_64 link. That is deliberate — the
	# previous arm64 pin made it "succeed" into an arm64 simulator app an Intel Mac cannot run.
	xcodebuild -project podcasts.xcodeproj \
	       -scheme pocketcasts \
	       -configuration Debug \
	       -destination 'generic/platform=iOS Simulator' \
	       $(SIM_ARCH) \
	       build

launch_mac: build_mac ## Builds and launches in iOS Simulator for log stream
	killall podcasts 2>/dev/null || true; \
	APP="$$(for d in "$$HOME"/Library/Developer/Xcode/DerivedData/podcasts-*; do \
		[ "$$(plutil -extract WorkspacePath raw "$$d/info.plist" 2>/dev/null)" = "$$PWD/podcasts.xcodeproj" ] || continue; \
		echo "$$d/Build/Products/Debug-iphonesimulator/podcasts.app"; \
		break; \
	done)"; \
	if [ ! -d "$$APP" ]; then \
		echo "error: no Debug-iphonesimulator podcasts.app in DerivedData for $$PWD"; \
		exit 1; \
	fi; \
	if [ -d podcasts/VoiceControl/Resources/earcons ]; then \
		mkdir -p "$$APP/earcons" && cp podcasts/VoiceControl/Resources/earcons/*.wav "$$APP/earcons/"; \
	fi; \
	xcrun simctl boot "$(SIMULATOR_NAME)" 2>/dev/null; \
	xcrun simctl install booted "$$APP" && \
	xcrun simctl launch booted fm.auris

debug: launch_mac ## Builds, launches, and streams VoicePipeline app logs
	log stream --predicate 'subsystem == "com.pocketcasts" AND category == "VoicePipeline"' --level debug --style compact

debug_all: launch_mac ## Builds, launches, and streams all process logs
	log stream --process podcasts --level debug --style compact

format: ## Lint and autocorrect linter errors
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS) --autocorrect)

upload_dsyms: ## Upload dSYMs
	./scripts/upload-symbols -gsp $(HOME)/.configure/pocketcasts-ios/secrets/GoogleService-Info.plist -p ios ./podcasts.app.dSYM.zip

install_dependencies: ## Install dependencies to run this project
	bundle install

update_proto: ## Generates the protobuffer Swift files
	./scripts/update_proto.sh $(API_PATH)

external_contributor: ## Generates an empty ApiCredentials.swift so the app builds
	@cp podcasts/Credentials/ApiCredentials.tpl podcasts/Credentials/LocalApiCredentials.swift
	@sed -i '' 's/%{.*}//' "podcasts/Credentials/LocalApiCredentials.swift"
	$(info You're ready to build the app, go ahead! 🎙)

ensure_llama_ios: ## Build CPU-only llama.cpp static libs for simulator/device
	./scripts/build-llama-ios.sh
