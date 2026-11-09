# Chaperone: build with swiftc, no Xcode project. Ad-hoc signed, with the
# Hardened Runtime.
#
#   make            build build/Chaperone.app for this Mac's architecture
#   make test       build a test copy of the app and run test/run.sh against it
#   make install    build, then install the app to ~/Applications and the
#                   `chaperone` shim to ~/.local/bin (no sudo)
#   make uninstall  remove both (the Developer Tools entry and the allowlist
#                   in ~/.config/chaperone are left for you to remove)
#   make dist       build dist/Chaperone-<version>-<arch>.zip for a GitHub
#                   release (releases use ARCH="arm64 x86_64": universal)
#   make clean      remove build/ and dist/
#
#   ARCH        architectures to build: one, or several for a universal app
#               (default: this Mac's, from uname -m; MacPorts passes its own)
#
# Package managers install elsewhere and stage into a DESTDIR:
#   PREFIX_APP  directory the app goes in        (default ~/Applications)
#   PREFIX_BIN  directory the shim goes in       (default ~/.local/bin)
#   APP_PATH    the app's final path, written into the installed shim
#               (default $(PREFIX_APP)/Chaperone.app)
#   DESTDIR     staging root prepended to every installed file (MacPorts)
#
# Ad-hoc signing means the app's identity is its code hash. The hash is the
# same for every build of the same source with the same compiler, and
# changes when either changes: after installing such a build, remove
# Chaperone from Privacy & Security > Developer Tools and add it again.

APP      := build/Chaperone.app
BIN      := $(APP)/Contents/MacOS/chaperone-app
# Developer Tools keys on this identifier: never change it.
BUNDLEID := io.github.dedalozzo.chaperone
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
# The oldest macOS Chaperone runs on (Info.plist's LSMinimumSystemVersion).
MACOS    := 13.0

ARCH       ?= $(shell uname -m)
# The zip's name says which Macs it runs on: universal for both.
ZIPARCH    := $(if $(word 2,$(ARCH)),universal,$(ARCH))
ZIP        := dist/Chaperone-$(VERSION)-$(ZIPARCH).zip

PREFIX_APP ?= $(HOME)/Applications
PREFIX_BIN ?= $(HOME)/.local/bin
APP_PATH   ?= $(PREFIX_APP)/Chaperone.app
DESTDIR    ?=

.PHONY: all test install uninstall dist clean

all: $(APP)

# The bundle: Info.plist, the icon in Resources, the binary in MacOS. One
# swiftc call per architecture, then lipo joins them into one binary. The
# bundle is signed as a whole, after everything is in place, so the
# signature seals Info.plist and the icon too.
#
# --options runtime turns on the Hardened Runtime. Chaperone needs it: the
# shim hands the caller's environment to the app, and without it a DYLD_*
# variable there could load code into Chaperone before the allowlist check.
# The app needs no entitlements. `touch` gives the bundle directory a fresh
# time stamp for make.
$(APP): src/main.swift Info.plist icon/Chaperone.icns
	rm -rf build/arch
	mkdir -p build/arch $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp icon/Chaperone.icns $(APP)/Contents/Resources/Chaperone.icns
	for a in $(ARCH); do \
	    swiftc -O -target $$a-apple-macos$(MACOS) -o build/arch/chaperone-app-$$a src/main.swift || exit 1; \
	done
	lipo -create build/arch/chaperone-app-* -output $(BIN)
	codesign --force --sign - --options runtime --identifier $(BUNDLEID) $(APP)
	touch $(APP)

# The tests run against a separate copy of the app in build/test, compiled
# with -D CHAPERONE_TESTING so it reads its allowlist from
# $CHAPERONE_TEST_ALLOWLIST instead of yours. That copy is never installed.
# The script also checks that the real build has no trace of that hook.
test: all
	mkdir -p build/test/Chaperone.app/Contents/MacOS
	cp Info.plist build/test/Chaperone.app/Contents/Info.plist
	swiftc -O -D CHAPERONE_TESTING -o build/test/Chaperone.app/Contents/MacOS/chaperone-app src/main.swift
	codesign --force --sign - --options runtime --identifier $(BUNDLEID).test build/test/Chaperone.app
	test/run.sh build/test/Chaperone.app/Contents/MacOS/chaperone-app $(BIN)

# The old bundle is removed first, so no stale file survives inside it.
# ditto keeps the signature and extended attributes intact. The shim is
# installed with DEFAULT_APP set to the app's final path.
install: all
	@test -n "$(PREFIX_APP)" && test -n "$(PREFIX_BIN)" || { echo "PREFIX_APP and PREFIX_BIN must be set" >&2; exit 1; }
	mkdir -p "$(DESTDIR)$(PREFIX_APP)" "$(DESTDIR)$(PREFIX_BIN)"
	rm -rf "$(DESTDIR)$(PREFIX_APP)/Chaperone.app"
	ditto $(APP) "$(DESTDIR)$(PREFIX_APP)/Chaperone.app"
	sed 's|^DEFAULT_APP=.*|DEFAULT_APP="$(APP_PATH)"|' chaperone > build/chaperone
	install -m 755 build/chaperone "$(DESTDIR)$(PREFIX_BIN)/chaperone"
	@echo "Installed $(DESTDIR)$(PREFIX_APP)/Chaperone.app and $(DESTDIR)$(PREFIX_BIN)/chaperone."
	@echo "Now add $(APP_PATH) in System Settings > Privacy & Security > Developer Tools (again after every rebuild)."

uninstall:
	@test -n "$(PREFIX_APP)" && test -n "$(PREFIX_BIN)" || { echo "PREFIX_APP and PREFIX_BIN must be set" >&2; exit 1; }
	rm -rf "$(DESTDIR)$(PREFIX_APP)/Chaperone.app"
	rm -f "$(DESTDIR)$(PREFIX_BIN)/chaperone"
	@echo "Also remove Chaperone from Developer Tools, and ~/.config/chaperone if you no longer need the allowlist."

# The release zip: the app, the shim (expecting ~/Applications), README and
# LICENSE, in one folder. ditto keeps the app's signature intact. Build it
# from clean, so the app has every architecture in ARCH:
#   make clean dist ARCH="arm64 x86_64"
dist: all
	rm -rf "./dist"
	mkdir -p dist/Chaperone-$(VERSION)
	ditto $(APP) dist/Chaperone-$(VERSION)/Chaperone.app
	install -m 755 chaperone dist/Chaperone-$(VERSION)/chaperone
	cp README.md LICENSE dist/Chaperone-$(VERSION)/
	cd dist && ditto -c -k --norsrc --noextattr --noqtn --keepParent Chaperone-$(VERSION) $(notdir $(ZIP))
	shasum -a 256 $(ZIP)

clean:
	rm -rf "./build" "./dist"
