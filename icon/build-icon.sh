#!/bin/bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ICONSET_DIR="$PACKAGE_DIR/Chaperone.iconset"
MASTER_PNG="$PACKAGE_DIR/Chaperone-1024.png"
MODULE_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chaperone-swift.XXXXXX")"
trap 'rm -rf "$MODULE_CACHE_DIR"' EXIT

swift -module-cache-path "$MODULE_CACHE_DIR" \
  "$PACKAGE_DIR/render-svg.swift" \
  "$PACKAGE_DIR/Chaperone.svg" \
  "$MASTER_PNG"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

make_size() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$name" >/dev/null
}

make_size 16 icon_16x16.png
make_size 32 icon_16x16@2x.png
make_size 32 icon_32x32.png
make_size 64 icon_32x32@2x.png
make_size 128 icon_128x128.png
make_size 256 icon_128x128@2x.png
make_size 256 icon_256x256.png
make_size 512 icon_256x256@2x.png
make_size 512 icon_512x512.png
make_size 1024 icon_512x512@2x.png

swift -module-cache-path "$MODULE_CACHE_DIR" \
  "$PACKAGE_DIR/build-icns.swift" \
  "$ICONSET_DIR" \
  "$PACKAGE_DIR/Chaperone.icns"
printf 'Built %s\n' "$PACKAGE_DIR/Chaperone.icns"
