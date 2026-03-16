.PHONY: gen build run clean notarize release help

# ── Variables ────────────────────────────────────────────────────────────────
SCHEME  := TabRecordApp
PROJECT := TabRecordApp.xcodeproj
BUILD   := .build
APP     := $(BUILD)/Build/Products/Release/TabRecord.app

# ── Targets ──────────────────────────────────────────────────────────────────

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

gen: ## Generate Xcode project from project.yml (requires: brew install xcodegen)
	xcodegen generate

build: gen ## Build release app bundle
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD) \
		-quiet

run: gen ## Build debug and launch immediately
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(BUILD) \
		-quiet
	open $(BUILD)/Build/Products/Debug/TabRecord.app

release: ## Bump version and release (PART=major|minor|patch, default: patch)
	./scripts/bump.sh $(or $(PART),patch)

clean: ## Remove derived data
	rm -rf $(BUILD)

# Notarization — fill in APPLE_ID, TEAM_ID, APP_PASSWORD before using.
notarize: build ## Sign, notarize, and staple the release app
	@echo "Codesigning…"
	codesign --deep --force --options runtime \
		--entitlements TabRecordApp/TabRecord.entitlements \
		--sign "Developer ID Application: YOUR_NAME (TEAM_ID)" \
		$(APP)
	@echo "Creating zip for notarytool…"
	ditto -c -k --keepParent $(APP) $(BUILD)/TabRecord.zip
	@echo "Submitting for notarization…"
	xcrun notarytool submit $(BUILD)/TabRecord.zip \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_PASSWORD)" \
		--wait
	@echo "Stapling ticket…"
	xcrun stapler staple $(APP)
	@echo "Done — $(APP) is notarized and ready for distribution."
