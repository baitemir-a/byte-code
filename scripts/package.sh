#!/usr/bin/env bash
# Builds shareable release packages into dist/:
#   dist/byte-code-macos.zip            "byte code.app", universal (Apple Silicon + Intel), macOS 13+
#   dist/byte-code-windows.zip          byte-code.exe, x86_64
#   dist/byte-code-linux-x86_64.tar.gz  byte-code, x86_64, glibc 2.31+ (built in Docker)
#
# Run from anywhere with Zig 0.16:
#   scripts/package.sh
#
# Each package is built where it can be: the macOS app needs a Mac (lipo and
# codesign), the Linux build needs Docker or a Linux machine with the X11 and
# OpenGL development packages. Whatever can't be built here is skipped with a
# note, so the rest still comes out.
#
# Name platforms to build only those, as the release workflow does — one per
# machine:
#   scripts/package.sh macos
#   scripts/package.sh windows linux
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
NAME="byte code"
EXE="byte-code"
VERSION="0.1.5"
# Oldest macOS the app runs on. Without an explicit version Zig targets the
# macOS of the build machine, which friends on older systems can't open.
MACOS_MIN="13.0"
# Oldest glibc the Linux build runs on (Ubuntu 20.04, Debian 11).
GLIBC_MIN="2.31"

# Platforms to package: all of them unless some are named.
TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then TARGETS=(macos windows linux); fi
wanted() {
    local t
    for t in "${TARGETS[@]}"; do [[ "$t" == "$1" ]] && return 0; done
    return 1
}

BUILD="$ROOT/.zig-cache/package"
DIST="$ROOT/dist"
rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

build() { # target, prefix
    echo "==> zig build $1"
    zig build -Doptimize=ReleaseSafe -Dtarget="$1" --prefix "$2"
}

# Shipped with every package: the bundled DejaVu font's and Lucide icons'
# licenses ask for it.
LICENSES="$BUILD/THIRD-PARTY-LICENSES.txt"
{
    echo "byte code includes the DejaVu Sans Mono font, under this license:"
    echo
    cat "$ROOT/src/ui/fonts/DejaVu-LICENSE.txt"
    echo
    echo "byte code includes the Lucide icons (lucide.dev), under this license:"
    echo
    cat "$ROOT/src/ui/fonts/Lucide-LICENSE.txt"
} > "$LICENSES"
cp "$ROOT/scripts/README.txt" "$BUILD/README.txt"

# ---------------------------------------------------------------- macOS app
# Only on a Mac: the universal binary and its signature need Apple's tools.
if ! wanted macos; then
    :
elif [[ "$(uname)" != "Darwin" ]]; then
    echo "==> skipping macOS: the app bundle needs a Mac (lipo, codesign, ditto)"
else
    build "aarch64-macos.$MACOS_MIN" "$BUILD/arm64"
    build "x86_64-macos.$MACOS_MIN" "$BUILD/x86_64"

    APP="$BUILD/$NAME.app"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    # One binary that runs natively on both Apple Silicon and Intel Macs.
    lipo -create "$BUILD/arm64/bin/rl" "$BUILD/x86_64/bin/rl" -output "$APP/Contents/MacOS/$EXE"
    cp "$ROOT/src/assets/icon.icns" "$APP/Contents/Resources/icon.icns"

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
    <key>CFBundleIconFile</key>            <string>icon</string>
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

    # ditto keeps the bundle's permissions and signature intact inside the zip;
    # --norsrc leaves out extended attributes, which other unzip tools would
    # extract as "._*" files that break the signature.
    (cd "$BUILD" && ditto -c -k --norsrc --keepParent "$NAME.app" "$DIST/byte-code-macos.zip" \
        && zip -q "$DIST/byte-code-macos.zip" README.txt THIRD-PARTY-LICENSES.txt)
fi

# ------------------------------------------------------------------ Windows
if wanted windows; then
    build "x86_64-windows" "$BUILD/windows"
    mkdir -p "$BUILD/win-zip"
    cp "$BUILD/windows/bin/rl.exe" "$BUILD/win-zip/$EXE.exe"
    cp "$ROOT/scripts/README.txt" "$BUILD/win-zip/README.txt"
    cp "$LICENSES" "$BUILD/win-zip/"
    (cd "$BUILD/win-zip" && zip -q "$DIST/byte-code-windows.zip" "$EXE.exe" README.txt THIRD-PARTY-LICENSES.txt)
fi

# -------------------------------------------------------------------- Linux
# Needs the Linux X11/OpenGL libraries, so it's built in an Ubuntu container
# (scripts/linux/Dockerfile) with an older glibc pinned for compatibility.
LINUX_OUT=""
if ! wanted linux; then
    :
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    echo "==> zig build x86_64-linux-gnu.$GLIBC_MIN (in Docker)"
    docker build --quiet --platform linux/amd64 -t byte-code-linux-build "$ROOT/scripts/linux" >/dev/null
    mkdir -p "$BUILD/linux"
    docker run --rm --platform linux/amd64 \
        -v "$ROOT:/src" -v "$BUILD/linux:/out" -v byte-code-zig-cache:/zig-cache -w /src \
        byte-code-linux-build \
        zig build -Doptimize=ReleaseSafe -Dtarget="x86_64-linux-gnu.$GLIBC_MIN" --prefix /out \
            --cache-dir /zig-cache/local --global-cache-dir /zig-cache/global
    LINUX_OUT="$BUILD/linux/bin/rl"
elif [[ "$(uname)" == "Linux" ]]; then
    # No Docker, but this is Linux: build against the system's X11 and
    # OpenGL headers, with glibc pinned so the binary still runs on older
    # distributions. Needs libx11-dev, libgl1-mesa-dev, libxrandr-dev,
    # libxinerama-dev, libxi-dev and libxcursor-dev.
    build "x86_64-linux-gnu.$GLIBC_MIN" "$BUILD/linux"
    LINUX_OUT="$BUILD/linux/bin/rl"
else
    echo "==> skipping Linux: needs Docker, or a Linux machine with the X11 and OpenGL dev packages"
fi

if [[ -n "$LINUX_OUT" ]]; then
    PKG="$BUILD/linux-pkg/byte-code"
    mkdir -p "$PKG"
    cp "$LINUX_OUT" "$PKG/$EXE"
    cp "$ROOT/scripts/README.txt" "$PKG/README.txt"
    cp "$LICENSES" "$PKG/"
    tar -czf "$DIST/byte-code-linux-x86_64.tar.gz" -C "$BUILD/linux-pkg" byte-code
fi

echo
echo "==> done"
ls -lh "$DIST"
