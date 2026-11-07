# Chaperone macOS App Icon

This package contains an original macOS app icon for **Chaperone**. The shield represents protection, the north-star beacon represents trusted guidance, and the illuminated route leads to a small developer artifact.

## Files

- `Chaperone.icns` — ready-to-use macOS icon file.
- `Chaperone.iconset/` — PNG exports at the standard 16, 32, 64, 128, 256, 512, and 1024 pixel sizes, including the `@2x` variants.
- `Chaperone-1024.png` — full-size rendered artwork.
- `Chaperone.svg` — editable vector source.
- `build-icon.sh`, `render-svg.swift`, and `build-icns.swift` — rebuild the PNGs and `.icns` on macOS.

## Use in a macOS app

Copy `Chaperone.icns` into `YourApp.app/Contents/Resources/`. Set `CFBundleIconFile` in `YourApp.app/Contents/Info.plist` to `Chaperone.icns`, then rebuild or re-sign the app bundle as appropriate.

To regenerate the package on macOS, run `./build-icon.sh` from this folder. The script uses the built-in Swift/AppKit and `sips` tools.
