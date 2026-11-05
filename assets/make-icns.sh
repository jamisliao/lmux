#!/bin/zsh
# Render assets/icon.svg -> assets/AppIcon.icns (+ a 512px PNG preview).
# Built-in tools only: swiftc (WKWebView rasterizer), sips, iconutil. No installs.
#
#   assets/make-icns.sh            # from the repo root or anywhere
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer assets/make-icns.sh
set -euo pipefail

here=${0:A:h}
repo=${here:h}
svg=$here/icon.svg
out=$here/AppIcon.icns
preview=$repo/design/previews/icon-512.png
work=$(mktemp -d -t lmux-icon)
trap 'rm -rf "$work"' EXIT

echo "• compiling rasterizer"
xcrun swiftc -O "$repo/design/tools/render.swift" -o "$work/render" 2>/dev/null \
  || swiftc -O "$repo/design/tools/render.swift" -o "$work/render"

echo "• rasterizing icon.svg at 1024px"
# 1024x1024 CSS px at scale 1 -> 1024px PNG with transparent background.
"$work/render" "$svg" "$work/icon-1024.png" 1024 1024 light 1 >/dev/null

iconset=$work/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

echo "• packing AppIcon.icns"
iconutil -c icns "$iconset" -o "$out"

mkdir -p "${preview:h}"
cp "$iconset/icon_512x512.png" "$preview"
echo "✓ $out"
echo "✓ $preview"
