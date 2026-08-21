#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_DIR/.build"
DIST_DIR="$REPO_DIR/dist"
APP_DIR="$DIST_DIR/AudioOutputSwitcher.app"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

if [[ -n "${SDK_PATH:-}" ]]; then
    SELECTED_SDK="$SDK_PATH"
elif [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    SELECTED_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
else
    SELECTED_SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$MODULE_CACHE_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$REPO_DIR/App/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

if [[ -n "${RELEASE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" \
        "$APP_DIR/Contents/Info.plist"
fi

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
swiftc \
    -parse-as-library \
    -swift-version 5 \
    -O \
    -sdk "$SELECTED_SDK" \
    -target arm64-apple-macosx13.0 \
    "$REPO_DIR/Sources/AudioOutputSwitcher.swift" \
    -o "$APP_DIR/Contents/MacOS/AudioOutputSwitcher" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AudioToolbox \
    -framework Carbon \
    -framework CoreAudio \
    -framework ServiceManagement

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/AudioOutputSwitcher.zip"

echo "Built: $APP_DIR"
echo "Archive: $DIST_DIR/AudioOutputSwitcher.zip"
