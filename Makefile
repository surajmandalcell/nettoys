BUILD_PATH := .build
APP := $(BUILD_PATH)/NetToys.app
SOURCE_COMMIT := $(shell git rev-parse HEAD)
SIGNING_IDENTITY ?= -
ENTITLEMENTS := $(abspath packaging/macos/NetToys.entitlements)

.PHONY: build
build:
	@test -z "$$(git status --porcelain)" || (echo "Commit the source before packaging NetToys." >&2; exit 1)
	swift build --scratch-path "$(BUILD_PATH)" --configuration release --product NetToys --jobs 4
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build --scratch-path "$(BUILD_PATH)" --configuration release --show-bin-path)/NetToys" "$(APP)/Contents/MacOS/NetToys"
	cp packaging/macos/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace NetToysSourceCommit -string "$(SOURCE_COMMIT)" "$(APP)/Contents/Info.plist"
	@test "$(SOURCE_COMMIT)" = "$$(git rev-parse HEAD)" && test -z "$$(git status --porcelain)" || (echo "Source changed during the build. Build again from clean HEAD." >&2; exit 1)
	codesign --force --options runtime --timestamp=none --entitlements "$(ENTITLEMENTS)" --sign "$(SIGNING_IDENTITY)" "$(APP)"
	plutil -lint "$(APP)/Contents/Info.plist"
	codesign --verify --deep --strict "$(APP)"
