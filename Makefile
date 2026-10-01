BUILD_PATH := .build
APP := $(BUILD_PATH)/NetToys.app
HELPER := $(APP)/Contents/Library/LoginItems/NetToysHelper.app
SOURCE_COMMIT := $(shell git rev-parse HEAD)
SIGNING_IDENTITY ?= -
ENTITLEMENTS := $(abspath packaging/macos/NetToys.entitlements)
SWIFT := taskpolicy -c utility nice -n 10 swift

.PHONY: build verify
build:
	@test -z "$$(git status --porcelain)" || (echo "Commit the source before packaging NetToys." >&2; exit 1)
	$(SWIFT) build --scratch-path "$(BUILD_PATH)" --configuration release --product NetToys --jobs 2
	$(SWIFT) build --scratch-path "$(BUILD_PATH)" --configuration release --product NetToysHelper --jobs 2
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(HELPER)/Contents/MacOS" "$(HELPER)/Contents/Resources" "$(APP)/Contents/Library/LaunchDaemons"
	@set -e; BIN="$$(swift build --scratch-path "$(BUILD_PATH)" --configuration release --show-bin-path)"; \
	cp "$$BIN/NetToys" "$(APP)/Contents/MacOS/NetToys"; \
	cp "$$BIN/NetToysHelper" "$(HELPER)/Contents/MacOS/NetToysHelper"; \
	for bundle in "$$BIN"/*.bundle; do \
	  test -d "$$bundle" || continue; \
	  cp -R "$$bundle" "$(APP)/Contents/MacOS/"; \
	  cp -R "$$bundle" "$(HELPER)/Contents/MacOS/"; \
	  cp -R "$$bundle" "$(APP)/Contents/Resources/"; \
	  cp -R "$$bundle" "$(HELPER)/Contents/Resources/"; \
	done
	cp packaging/macos/Info.plist "$(APP)/Contents/Info.plist"
	cp packaging/macos/Helper-Info.plist "$(HELPER)/Contents/Info.plist"
	cp packaging/macos/com.surajmandal.nettoys.neighbor.plist "$(APP)/Contents/Library/LaunchDaemons/"
	cp LICENSE Sources/NetToysCore/Resources/IEEE-MAC-VENDORS-NOTICE.txt "$(APP)/Contents/Resources/"
	@set -e; mkdir -p "$(BUILD_PATH)/NetToys.iconset"; \
	for size in 16 32 128 256 512; do \
	  sips -z $$size $$size Assets/NetToysLogo.png --out "$(BUILD_PATH)/NetToys.iconset/icon_$$size"x"$$size.png" >/dev/null; \
	  double=$$((size * 2)); \
	  sips -z $$double $$double Assets/NetToysLogo.png --out "$(BUILD_PATH)/NetToys.iconset/icon_$$size"x"$$size@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(BUILD_PATH)/NetToys.iconset" -o "$(APP)/Contents/Resources/AppIcon.icns"
	plutil -replace NetToysSourceCommit -string "$(SOURCE_COMMIT)" "$(APP)/Contents/Info.plist"
	plutil -replace NetToysSourceCommit -string "$(SOURCE_COMMIT)" "$(HELPER)/Contents/Info.plist"
	@test "$(SOURCE_COMMIT)" = "$$(git rev-parse HEAD)" && test -z "$$(git status --porcelain)" || (echo "Source changed during the build. Build again from clean HEAD." >&2; exit 1)
	@set -e; for bundle in "$(APP)/Contents/MacOS/"*.bundle "$(APP)/Contents/Resources/"*.bundle "$(HELPER)/Contents/MacOS/"*.bundle "$(HELPER)/Contents/Resources/"*.bundle; do \
	  test -d "$$bundle" || continue; \
	  codesign --force --timestamp=none --sign "$(SIGNING_IDENTITY)" "$$bundle"; \
	done
	codesign --force --options runtime --timestamp=none --entitlements "$(ENTITLEMENTS)" --sign "$(SIGNING_IDENTITY)" "$(HELPER)"
	codesign --force --options runtime --timestamp=none --entitlements "$(ENTITLEMENTS)" --sign "$(SIGNING_IDENTITY)" "$(APP)"
	$(MAKE) verify

verify:
	plutil -lint "$(APP)/Contents/Info.plist" "$(HELPER)/Contents/Info.plist" "$(APP)/Contents/Library/LaunchDaemons/com.surajmandal.nettoys.neighbor.plist"
	codesign --verify --deep --strict "$(HELPER)"
	codesign --verify --deep --strict "$(APP)"
	@test "$$(plutil -extract NetToysSourceCommit raw "$(APP)/Contents/Info.plist")" = "$(SOURCE_COMMIT)"
	@test "$$(plutil -extract NetToysSourceCommit raw "$(HELPER)/Contents/Info.plist")" = "$(SOURCE_COMMIT)"
	@test "$$(plutil -extract NetToysPackageVersion raw "$(APP)/Contents/Info.plist")" = "1.0.0"
	@test "$$(plutil -extract NetToysPackageVersion raw "$(HELPER)/Contents/Info.plist")" = "1.0.0"
	@test -f "$(APP)/Contents/MacOS/NetToys_NetToysCore.bundle/ieee-mac-vendors.tsv" || test -f "$(APP)/Contents/MacOS/NetToys_NetToysCore.bundle/Contents/Resources/ieee-mac-vendors.tsv"
	@test -f "$(HELPER)/Contents/MacOS/NetToys_NetToysCore.bundle/IEEE-MAC-VENDORS-NOTICE.txt" || test -f "$(HELPER)/Contents/MacOS/NetToys_NetToysCore.bundle/Contents/Resources/IEEE-MAC-VENDORS-NOTICE.txt"
	"$(HELPER)/Contents/MacOS/NetToysHelper" --verify-resources
	@for bundle in "$(APP)" "$(HELPER)"; do \
	  codesign -d --entitlements :- "$$bundle" > "$(BUILD_PATH)/signed-entitlements.plist" 2>/dev/null; \
	  test "$$(plutil -extract com.apple.security.app-sandbox raw "$(BUILD_PATH)/signed-entitlements.plist")" = "false" || exit 1; \
	  test "$$(plutil -extract com.apple.security.personal-information.location raw "$(BUILD_PATH)/signed-entitlements.plist")" = "true" || exit 1; \
	  if test "$(SIGNING_IDENTITY)" != "-"; then \
	    codesign -d --verbose=4 "$$bundle" 2>&1 | /usr/bin/grep -q '^TeamIdentifier=GF57JXJF5A$$' || exit 1; \
	  fi; \
	done
