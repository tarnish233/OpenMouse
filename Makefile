APP_NAME := Open Mouse
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP := build/$(APP_NAME).app
INSTALL_DIR := /Applications

.PHONY: all build app run install reinstall debug test dist clean tcc-reset

all: app

## Compile only (fast feedback loop)
build:
	swift build -c release

## Compile + assemble + sign the .app bundle
app:
	./Scripts/bundle.sh

## Debug build of the bundle
debug:
	CONFIG=debug ./Scripts/bundle.sh

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
	./Scripts/test-distribution-signature.sh

## Zip the signed bundle for a GitHub release.
## ditto, not zip: it preserves the bundle's signature and resource forks.
dist:
	DISTRIBUTION=1 ./Scripts/bundle.sh
	rm -f "build/OpenMouse-$(VERSION).zip"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "build/OpenMouse-$(VERSION).zip"
	@shasum -a 256 "build/OpenMouse-$(VERSION).zip"

clean:
	swift package clean
	rm -rf build .build

## Forget the Accessibility grant, e.g. after changing the signing identity
tcc-reset:
	tccutil reset Accessibility com.openmouse.OpenMouse
