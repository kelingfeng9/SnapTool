#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCH="arm64"
if [[ "${1:-}" == "--universal" ]]; then ARCH="universal";
elif [[ $# -gt 0 ]]; then echo "Usage: $0 [--universal]" >&2; exit 2; fi
if [[ "$(uname -s)" != "Darwin" ]]; then echo "This script requires macOS 14+ and Xcode Command Line Tools." >&2; exit 1; fi
command -v swift >/dev/null
mkdir -p "$BUILD_DIR"
STAGE_DIR="$(mktemp -d "$BUILD_DIR/package.XXXXXX")"
PACKAGE_DIR="$STAGE_DIR/package"
APP_DIR="$PACKAGE_DIR/SnapTool.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=14.0

build_arch() {
    local target_arch="$1"
    local swift_build="$BUILD_DIR/swift-$target_arch"
    swift build --package-path "$PROJECT_DIR" --build-path "$swift_build" -c release --arch "$target_arch" --product SnapTool
    local bin_path
    bin_path="$(swift build --package-path "$PROJECT_DIR" --build-path "$swift_build" -c release --arch "$target_arch" --show-bin-path)"
    cp "$bin_path/SnapTool" "$STAGE_DIR/SnapTool-$target_arch"
}

build_arch arm64
if [[ "$ARCH" == "universal" ]]; then
    build_arch x86_64
    lipo -create "$STAGE_DIR/SnapTool-arm64" "$STAGE_DIR/SnapTool-x86_64" -output "$APP_DIR/Contents/MacOS/SnapTool"
else
    cp "$STAGE_DIR/SnapTool-arm64" "$APP_DIR/Contents/MacOS/SnapTool"
fi
chmod 755 "$APP_DIR/Contents/MacOS/SnapTool"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist"

ICON_SOURCE="$REPO_DIR/assets/SnapTool-logo-512.png"
if [[ ! -f "$ICON_SOURCE" ]]; then echo "Missing icon source: $ICON_SOURCE" >&2; exit 1; fi
ICONSET="$STAGE_DIR/SnapTool.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/SnapTool.icns"

# This is an ad-hoc signature for bundle integrity, not Developer ID signing or notarization.
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
ZIP_PATH="$BUILD_DIR/SnapTool-macOS-$VERSION-$ARCH.zip"
if [[ -f "$PROJECT_DIR/README.md" ]]; then cp "$PROJECT_DIR/README.md" "$PACKAGE_DIR/README.md"; fi
ditto -c -k --sequesterRsrc "$PACKAGE_DIR" "$ZIP_PATH"
echo "App: $APP_DIR"
echo "Package: $ZIP_PATH"
echo "Ad-hoc signed only. Developer ID signing and notarization are not included."
