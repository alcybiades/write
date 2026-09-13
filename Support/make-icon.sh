#!/bin/sh
# Regenerates Support/AppIcon.icns from a square PNG (1024x1024 recommended).
# Usage: Support/make-icon.sh [path/to/icon.png]
# With no argument, uses Support/AppIcon-source.png.
set -e
cd "$(dirname "$0")"
SRC="${1:-AppIcon-source.png}"
[ -f "$SRC" ] || { echo "source image not found: $SRC" >&2; exit 1; }
rm -rf AppIcon.iconset
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$SRC" --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$SRC" --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "wrote $(pwd)/AppIcon.icns"
