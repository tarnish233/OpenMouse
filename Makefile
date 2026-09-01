APP_NAME := Open Mouse
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP := build/$(APP_NAME).app
DEBUG_APP_NAME := Open Mouse Debug
DEBUG_APP := build/$(DEBUG_APP_NAME).app
INSTALL_DIR := /Applications

.PHONY: all build app run debug debug-run install reinstall test dist dist-community clean tcc-reset tcc-reset-debug

all: app

## Compile only (fast feedback loop)
build:
	swift build -c release

## Compile + assemble + sign the .app bundle
app:
	./Scripts/bundle.sh

## Debug build with an isolated name, bundle id, TCC grant, and preferences directory
debug:
	CONFIG=debug DEBUG_VARIANT=1 ./Scripts/bundle.sh

## Relaunch only the isolated debug app
debug-run: debug
	-pkill -x OpenMouseDebug || true
	@while pgrep -x OpenMouseDebug >/dev/null; do sleep 0.1; done
	open "$(DEBUG_APP)" $(if $(strip $(DEBUG_ARGS)),--args $(DEBUG_ARGS),)

## Relaunch the app from the build directory
run: app
	-pkill -x OpenMouse || true
	open "$(APP)"

## Copy into /Applications and launch from there (needed for Login Item registration)
install: app
	-pkill -x OpenMouse || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

## Run the built-in logic checks
test:
	swift run -c debug OpenMouse --self-check
	swift run -c debug OpenMouseUpdater --self-check
	./Scripts/test-distribution-signature.sh
	./Scripts/test-community-signature.sh

## Zip the signed bundle for a GitHub release.
## ditto, not zip: it preserves the bundle's signature and resource forks.
dist:
	DISTRIBUTION=1 ./Scripts/bundle.sh
	rm -f "build/OpenMouse-$(VERSION).zip"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "build/OpenMouse-$(VERSION).zip"
	@shasum -a 256 "build/OpenMouse-$(VERSION).zip"

## Zip a launchable build signed with the repository-pinned self-signed identity.
## It is not notarized. The TCC requirement stays stable, and because the requirement pins the
## certificate rather than a per-build CDHash, in-app updates work between these builds.
dist-community:
	COMMUNITY_DISTRIBUTION=1 ./Scripts/bundle.sh
	rm -f "build/OpenMouse-$(VERSION).zip"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "build/OpenMouse-$(VERSION).zip"
	@shasum -a 256 "build/OpenMouse-$(VERSION).zip"

clean:
	swift package clean
	rm -rf build .build

## Forget the Accessibility grant, e.g. after changing the signing identity
tcc-reset:
	tccutil reset Accessibility com.openmouse.OpenMouse

## Forget only the isolated debug build's Accessibility grant
tcc-reset-debug:
	tccutil reset Accessibility com.openmouse.OpenMouse.debug
