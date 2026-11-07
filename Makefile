# Chaperone: build with swiftc, no Xcode project. Arm64, ad-hoc signed.
#
#   make            build build/Chaperone.app
#   make install    build, then install the app to ~/Applications and the
#                   `chaperone` shim to ~/.local/bin (no sudo)
#   make uninstall  remove both (the Developer Tools entry and the allowlist
#                   in ~/.config/chaperone are left for you to remove)
#   make clean      remove build/
#
# Ad-hoc signing means the app's identity is its code hash, which changes on
# every rebuild: after installing a rebuilt app, remove Chaperone from
# Privacy & Security > Developer Tools and add it again.

APP      := build/Chaperone.app
BIN      := $(APP)/Contents/MacOS/chaperone-app
# Developer Tools keys on this identifier: never change it.
BUNDLEID := io.github.dedalozzo.chaperone
PREFIX_APP := $(HOME)/Applications
PREFIX_BIN := $(HOME)/.local/bin

.PHONY: all install uninstall clean

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
# ditto keeps the signature and extended attributes intact.
install: all
	mkdir -p "$(PREFIX_APP)" "$(PREFIX_BIN)"
	rm -rf "$${HOME:?}/Applications/Chaperone.app"
	ditto $(APP) "$(PREFIX_APP)/Chaperone.app"
	install -m 755 chaperone "$(PREFIX_BIN)/chaperone"
	@echo "Installed $(PREFIX_APP)/Chaperone.app and $(PREFIX_BIN)/chaperone."
	@echo "Now add $(PREFIX_APP)/Chaperone.app in System Settings > Privacy & Security > Developer Tools (again after every rebuild)."

uninstall:
	rm -rf "$${HOME:?}/Applications/Chaperone.app"
	rm -f "$${HOME:?}/.local/bin/chaperone"
	@echo "Also remove Chaperone from Developer Tools, and ~/.config/chaperone if you no longer need the allowlist."

clean:
	rm -rf "./build"
