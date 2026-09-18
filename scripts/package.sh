#!/usr/bin/env bash
# Builds shareable release packages into dist/:
#   dist/byte-code-macos.zip            "byte code.app", universal (Apple Silicon + Intel), macOS 13+
#   dist/byte-code-windows.zip          byte-code.exe, x86_64
#   dist/byte-code-linux-x86_64.tar.gz  byte-code, x86_64, glibc 2.31+ (built in Docker)
#
# Run from anywhere on a Mac with Zig 0.16, the Xcode command line tools and
# (for Linux) Docker:
#   scripts/package.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
NAME="byte code"
EXE="byte-code"
VERSION="0.1.0"
# Oldest macOS the app runs on. Without an explicit version Zig targets the
# macOS of the build machine, which friends on older systems can't open.
MACOS_MIN="13.0"
# Oldest glibc the Linux build runs on (Ubuntu 20.04, Debian 11).
GLIBC_MIN="2.31"

BUILD="$ROOT/.zig-cache/package"
DIST="$ROOT/dist"
rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

build() { # target, prefix
    echo "==> zig build $1"
    zig build -Doptimize=ReleaseSafe -Dtarget="$1" --prefix "$2"
}

# ---------------------------------------------------------------- macOS app
build "aarch64-macos.$MACOS_MIN" "$BUILD/arm64"
build "x86_64-macos.$MACOS_MIN" "$BUILD/x86_64"

APP="$BUILD/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# One binary that runs natively on both Apple Silicon and Intel Macs.
lipo -create "$BUILD/arm64/bin/rl" "$BUILD/x86_64/bin/rl" -output "$APP/Contents/MacOS/$EXE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>$NAME</string>
    <key>CFBundleDisplayName</key>         <string>$NAME</string>
    <key>CFBundleIdentifier</key>          <string>dev.bytecode.editor</string>
    <key>CFBundleExecutable</key>          <string>$EXE</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>$MACOS_MIN</string>
    <!-- Render at full Retina resolution instead of blurry upscaling. -->
    <key>NSHighResolutionCapable</key>     <true/>
    <!-- Shown when macOS asks to let the app control Finder (Move to Trash). -->
    <key>NSAppleEventsUsageDescription</key>
    <string>byte code asks Finder to move deleted files to the Trash.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Apple Developer account): required to run on Apple
# Silicon at all. Friends still see a Gatekeeper warning; see README.
codesign --force --deep --sign - "$APP"

# Shipped with every package: the bundled DejaVu font's license asks for it.
LICENSES="$BUILD/THIRD-PARTY-LICENSES.txt"
{
    echo "byte code includes the DejaVu Sans Mono font, under this license:"
    echo
    cat "$ROOT/src/ui/fonts/DejaVu-LICENSE.txt"
} > "$LICENSES"

cp "$ROOT/scripts/README.txt" "$BUILD/README.txt"
# ditto keeps the bundle's permissions and signature intact inside the zip;
# --norsrc leaves out extended attributes, which other unzip tools would
# extract as "._*" files that break the signature.
(cd "$BUILD" && ditto -c -k --norsrc --keepParent "$NAME.app" "$DIST/byte-code-macos.zip" \
    && zip -q "$DIST/byte-code-macos.zip" README.txt THIRD-PARTY-LICENSES.txt)

# ------------------------------------------------------------------ Windows
build "x86_64-windows" "$BUILD/windows"
mkdir -p "$BUILD/win-zip"
cp "$BUILD/windows/bin/rl.exe" "$BUILD/win-zip/$EXE.exe"
cp "$ROOT/scripts/README.txt" "$BUILD/win-zip/README.txt"
cp "$LICENSES" "$BUILD/win-zip/"
(cd "$BUILD/win-zip" && zip -q "$DIST/byte-code-windows.zip" "$EXE.exe" README.txt THIRD-PARTY-LICENSES.txt)

# -------------------------------------------------------------------- Linux
# Needs the Linux X11/OpenGL libraries, so it's built in an Ubuntu container
# (scripts/linux/Dockerfile) with an older glibc pinned for compatibility.
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    echo "==> zig build x86_64-linux-gnu.$GLIBC_MIN (in Docker)"
    docker build --quiet --platform linux/amd64 -t byte-code-linux-build "$ROOT/scripts/linux" >/dev/null
    mkdir -p "$BUILD/linux"
    docker run --rm --platform linux/amd64 \
        -v "$ROOT:/src" -v "$BUILD/linux:/out" -v byte-code-zig-cache:/zig-cache -w /src \
        byte-code-linux-build \
        zig build -Doptimize=ReleaseSafe -Dtarget="x86_64-linux-gnu.$GLIBC_MIN" --prefix /out \
            --cache-dir /zig-cache/local --global-cache-dir /zig-cache/global
    PKG="$BUILD/linux-pkg/byte-code"
    mkdir -p "$PKG"
    cp "$BUILD/linux/bin/rl" "$PKG/$EXE"
    cp "$ROOT/scripts/README.txt" "$PKG/README.txt"
    cp "$LICENSES" "$PKG/"
    tar -czf "$DIST/byte-code-linux-x86_64.tar.gz" -C "$BUILD/linux-pkg" byte-code
else
    echo "==> skipping Linux: Docker isn't running"
fi

echo
echo "==> done"
ls -lh "$DIST"
