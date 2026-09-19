#!/usr/bin/env bash
# Generates the app icons from src/assets/icon.svg (run again after editing it):
#   src/assets/icon.png   256px, set as the window icon at runtime (Windows, Linux)
#   src/assets/icon.ico   embedded into byte-code.exe (Explorer, taskbar, shortcuts)
#   src/assets/icon.icns  the macOS app icon (Finder, Dock, Launchpad)
#
# Needs only what ships with macOS: sips, iconutil and python3.
set -euo pipefail

cd "$(dirname "$0")/.."
ASSETS="$(pwd)/src/assets"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

png() { # size, output
    sips -s format png -z "$1" "$1" "$ASSETS/icon.svg" --out "$2" >/dev/null
}

png 256 "$ASSETS/icon.png"

# Windows: an .ico is a small directory of images; PNG entries are fine.
for s in 16 24 32 48 64 128 256; do png "$s" "$TMP/$s.png"; done
python3 - "$TMP" "$ASSETS/icon.ico" <<'PY'
import struct, sys
tmp, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
data = [open(f"{tmp}/{s}.png", "rb").read() for s in sizes]
head = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, d in zip(sizes, data):
    head += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(d), offset)
    offset += len(d)
open(out, "wb").write(head + b"".join(data))
PY

# macOS: Apple's icon grid leaves a margin around the artwork (824 of 1024
# px), so the icon matches the size of the other icons in the Dock.
# Done by widening the SVG's viewBox by 1024/824 around its 192x192 canvas.
sed -E '1s/viewBox="[^"]*"/viewBox="-23.3 -23.3 238.6 238.6"/' "$ASSETS/icon.svg" > "$TMP/mac.svg"
sips -s format png -z 1024 1024 "$TMP/mac.svg" --out "$TMP/mac.png" >/dev/null
ICONSET="$TMP/icon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/mac.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/mac.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ASSETS/icon.icns"

ls -l "$ASSETS"
