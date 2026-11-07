# Chaperone: build with swiftc, no Xcode project. Arm64, ad-hoc signed.
#
#   make            build build/Chaperone.app
#   make install    build, then install the app to ~/Applications and the
#                   `chaperone` shim to ~/.local/bin (no sudo)
#   make uninstall  remove both (the Developer Tools entry and the allowlist
#                   in ~/.config/chaperone are left for you to remove)
#   make dist       build dist/Chaperone-<version>-arm64.zip for a GitHub release
#   make clean      remove build/ and dist/
#
# Package managers install elsewhere and stage into a DESTDIR:
#   PREFIX_APP  directory the app goes in        (default ~/Applications)
#   PREFIX_BIN  directory the shim goes in       (default ~/.local/bin)
#   APP_PATH    the app's final path, written into the installed shim
#               (default $(PREFIX_APP)/Chaperone.app)
#   DESTDIR     staging root prepended to every installed file (MacPorts)
#
# Ad-hoc signing means the app's identity is its code hash, which changes on
# every rebuild: after installing a rebuilt app, remove Chaperone from
# Privacy & Security > Developer Tools and add it again.

APP      := build/Chaperone.app
BIN      := $(APP)/Contents/MacOS/chaperone-app
# Developer Tools keys on this identifier: never change it.
BUNDLEID := io.github.dedalozzo.chaperone
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
ZIP      := dist/Chaperone-$(VERSION)-arm64.zip

PREFIX_APP ?= $(HOME)/Applications
PREFIX_BIN ?= $(HOME)/.local/bin
APP_PATH   ?= $(PREFIX_APP)/Chaperone.app
DESTDIR    ?=

.PHONY: all install uninstall dist clean

all: $(APP)

# The bundle: Info.plist, the icon in Resources, the binary in MacOS. The
# bundle is signed as a whole, after everything is in place, so the
# signature seals Info.plist and the icon too. `touch` gives the bundle
# directory a fresh time stamp for make.
$(APP): src/main.swift Info.plist icon/Chaperone.icns
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp icon/Chaperone.icns $(APP)/Contents/Resources/Chaperone.icns
	swiftc -O -target arm64-apple-macos13.0 -o $(BIN) src/main.swift
	codesign --force --sign - --identifier $(BUNDLEID) $(APP)
	touch $(APP)

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
# LICENSE, in one folder. ditto keeps the app's signature intact.
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
