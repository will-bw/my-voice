# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
WHISPER_CPP_REPOSITORY := https://github.com/ggml-org/whisper.cpp.git
WHISPER_CPP_REVISION := da54572229bcf64ba367d96c7ef15770376c4280
WHISPER_REVISION_FILE := $(FRAMEWORK_PATH)/.my-voice-whisper-revision
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build
LOCAL_OUTPUT_DIR := $(CURDIR)/dist
LOCAL_APP_NAME := my-voice
LOCAL_CODESIGN_IDENTITY ?=
RUN_APP_NAME ?= my-voice

.PHONY: all clean whisper setup build local check healthcheck verify-local-isolation help dev run release release-setup

# Default target
all: check build

# Development workflow
dev: RUN_APP_NAME = VoiceInk Dev
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@xcodebuild -version >/dev/null 2>&1 || { echo "xcodebuild is not usable; install/select the full Xcode app with xcode-select"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

verify-local-isolation:
	@./scripts/verify-local-isolation.sh

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -e "$(WHISPER_CPP_DIR)" ]; then \
		mkdir -p "$(WHISPER_CPP_DIR)"; \
		git -C "$(WHISPER_CPP_DIR)" init; \
		git -C "$(WHISPER_CPP_DIR)" remote add origin "$(WHISPER_CPP_REPOSITORY)"; \
	elif [ ! -d "$(WHISPER_CPP_DIR)/.git" ]; then \
		echo "$(WHISPER_CPP_DIR) exists but is not a Git checkout; refusing to overwrite it"; \
		exit 1; \
	fi
	@if [ -n "$$(git -C "$(WHISPER_CPP_DIR)" status --porcelain)" ]; then \
		echo "$(WHISPER_CPP_DIR) has local changes; refusing to change the pinned dependency"; \
		exit 1; \
	fi
	@ORIGIN_URL=$$(git -C "$(WHISPER_CPP_DIR)" remote get-url origin 2>/dev/null || true); \
	case "$$ORIGIN_URL" in \
		"https://github.com/ggml-org/whisper.cpp.git"|"https://github.com/ggerganov/whisper.cpp.git") ;; \
		*) echo "Unexpected whisper.cpp origin: $$ORIGIN_URL"; exit 1 ;; \
	esac; \
	CURRENT_REVISION=$$(git -C "$(WHISPER_CPP_DIR)" rev-parse HEAD 2>/dev/null || true); \
	if [ "$$CURRENT_REVISION" != "$(WHISPER_CPP_REVISION)" ]; then \
		git -C "$(WHISPER_CPP_DIR)" fetch --depth 1 origin "$(WHISPER_CPP_REVISION)"; \
		git -C "$(WHISPER_CPP_DIR)" checkout --detach "$(WHISPER_CPP_REVISION)"; \
	fi
	@if [ ! -f "$(WHISPER_REVISION_FILE)" ] || \
		[ "$$(sed -n '1p' "$(WHISPER_REVISION_FILE)" 2>/dev/null)" != "$(WHISPER_CPP_REVISION)" ]; then \
		echo "Building pinned whisper.xcframework at $(WHISPER_CPP_REVISION)..."; \
		rm -rf "$(FRAMEWORK_PATH)"; \
		cd "$(WHISPER_CPP_DIR)" && ./build-xcframework.sh; \
		printf '%s\n' "$(WHISPER_CPP_REVISION)" > "$(WHISPER_REVISION_FILE)"; \
	else \
		echo "Pinned whisper.xcframework already built at $(WHISPER_CPP_REVISION), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		build

# Build locally with stable Apple Development signing when available.
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	@SIGNING_IDENTITY="$(LOCAL_CODESIGN_IDENTITY)"; \
	if [ -z "$$SIGNING_IDENTITY" ]; then \
		SIGNING_IDENTITIES=$$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $$2 }'); \
		SIGNING_IDENTITY_COUNT=$$(printf '%s\n' "$$SIGNING_IDENTITIES" | awk 'NF { count++ } END { print count + 0 }'); \
		if [ "$$SIGNING_IDENTITY_COUNT" -eq 1 ]; then \
			SIGNING_IDENTITY=$$(printf '%s\n' "$$SIGNING_IDENTITIES" | awk 'NF { print; exit }'); \
		elif [ "$$SIGNING_IDENTITY_COUNT" -gt 1 ]; then \
			echo "Multiple Apple Development identities found; set LOCAL_CODESIGN_IDENTITY to choose one; using ad-hoc signing"; \
		fi; \
	fi; \
	if [ -n "$$SIGNING_IDENTITY" ] && [ "$$SIGNING_IDENTITY" != "-" ]; then \
		SIGNING_REQUIRED=YES; \
		echo "Using stable local signing identity: $$SIGNING_IDENTITY"; \
	else \
		SIGNING_IDENTITY="-"; \
		SIGNING_REQUIRED=NO; \
		echo "Using ad-hoc signing (permissions may need approval after rebuilds)"; \
	fi; \
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="$$SIGNING_IDENTITY" \
		CODE_SIGNING_REQUIRED="$$SIGNING_REQUIRED" \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		PRODUCT_BUNDLE_IDENTIFIER='com.will.myvoice.$$(TARGET_NAME:rfc1034identifier)' \
		INFOPLIST_KEY_CFBundleDisplayName="my-voice" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD MYVOICE_LOCAL_BUILD' \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying $(LOCAL_APP_NAME).app to $(LOCAL_OUTPUT_DIR)..."; \
		mkdir -p "$(LOCAL_OUTPUT_DIR)"; \
		rm -rf "$(LOCAL_OUTPUT_DIR)/$(LOCAL_APP_NAME).app"; \
		ditto "$$APP_PATH" "$(LOCAL_OUTPUT_DIR)/$(LOCAL_APP_NAME).app"; \
		xattr -cr "$(LOCAL_OUTPUT_DIR)/$(LOCAL_APP_NAME).app"; \
		echo ""; \
		echo "Build complete! App saved to: $(LOCAL_OUTPUT_DIR)/$(LOCAL_APP_NAME).app"; \
		echo "Run with: open $(LOCAL_OUTPUT_DIR)/$(LOCAL_APP_NAME).app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built $(LOCAL_APP_NAME).app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$(LOCAL_OUTPUT_DIR)/$(RUN_APP_NAME).app" ]; then \
		echo "Opening $(LOCAL_OUTPUT_DIR)/$(RUN_APP_NAME).app..."; \
		open "$(LOCAL_OUTPUT_DIR)/$(RUN_APP_NAME).app"; \
	else \
		echo "Looking for $(RUN_APP_NAME).app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "$(RUN_APP_NAME).app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "$(RUN_APP_NAME).app not found. Build it with 'make local' or use 'make dev' for the development app."; \
			exit 1; \
		fi; \
	fi

# Build a signed, notarized DMG and matching local Sparkle Appcast.
release: whisper
	@if [ -n "$(NOTES)" ]; then \
		./scripts/release.sh --notes "$(NOTES)" $(RELEASE_ARGS); \
	else \
		./scripts/release.sh $(RELEASE_ARGS); \
	fi

# Store Apple's notarization credentials securely in Keychain.
release-setup:
	@./scripts/setup-release-notarization.sh

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf "$(WHISPER_CPP_DIR)"
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build locally with stable signing when available"
	@echo "    LOCAL_CODESIGN_IDENTITY=<SHA or name> overrides automatic Apple Development detection"
	@echo "  verify-local-isolation  Check updater, license, bundle, Keychain, and data isolation"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  release            Build DMG and Appcast using release-notes/<version>.html"
	@echo "  release-setup      Store notarization credentials in Keychain"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
