# Chaperone: build with swiftc, no Xcode project. Arm64, ad-hoc signed.

APP      := build/Chaperone.app
BIN      := $(APP)/Contents/MacOS/chaperone-app
BUNDLEID := io.github.dedalozzo.chaperone
PREFIX_APP := $(HOME)/Applications
PREFIX_BIN := $(HOME)/.local/bin

.PHONY: all install uninstall clean

all: $(APP)

$(APP): src/main.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -O -target arm64-apple-macos13.0 -o $(BIN) src/main.swift
	codesign --force --sign - --identifier $(BUNDLEID) $(APP)
	touch $(APP)

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
