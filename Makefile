APP_NAME := Tuff
SCHEME := TuffBrowser
BUILD_DIR := build
DEBUG_APP := $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app
RELEASE_APP := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
# Builds are signed ad hoc unless the keychain holds a Developer ID certificate, which is then
# used automatically (see scripts/signing-args.sh; SIGN_KIND picks another kind of certificate).
SIGNING := $(shell scripts/signing-args.sh)
XCODEBUILD := xcodebuild -project TuffBrowser.xcodeproj -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR) $(SIGNING)

.PHONY: gen build test run release install size icon clean

## Generate the Xcode project from project.yml (needs `brew install xcodegen`)
gen:
	xcodegen generate

## Debug build
build: gen
	$(XCODEBUILD) -configuration Debug build | grep -E "error:|warning: |BUILD" || true

## Unit tests (TuffBrowserTests). Hosted in a Tuff that opens no windows and loads no profile.
test: gen
	$(XCODEBUILD) -configuration Debug test 2>&1 | grep -E "error:|Test Case .* failed|Executed|TEST (SUCCEEDED|FAILED)" || true

## Build and launch
run: build
	open $(DEBUG_APP)

## Optimised build
release: gen
	$(XCODEBUILD) -configuration Release build | grep -E "error:|BUILD" || true
	@$(MAKE) size

## Optimised build, copied to /Applications (where helper apps such as 1Password look for browsers)
install: release
	rm -rf "/Applications/$(APP_NAME).app"
	ditto $(RELEASE_APP) "/Applications/$(APP_NAME).app"
	@codesign -dv "/Applications/$(APP_NAME).app" 2>&1 | grep -E "^(Authority|TeamIdentifier|Signature)" | head -3

## Show how big the release app is
size:
	@du -sh $(RELEASE_APP) | awk '{print "App bundle: " $$1}'
	@du -sh $(RELEASE_APP)/Contents/MacOS/$(APP_NAME) | awk '{print "Executable: " $$1}'

## Regenerate the app icon
icon:
	swift scripts/make-icon.swift TuffBrowser/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf $(BUILD_DIR) dist
