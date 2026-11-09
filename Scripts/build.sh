#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
cd "$AW_PROJECT_ROOT"
swift build "${AW_SWIFT_FLAGS[@]}" -c release --product a-watcher
swift build "${AW_SWIFT_FLAGS[@]}" -c release --product watcherctl
AW_BIN_DIR="$(swift build "${AW_SWIFT_FLAGS[@]}" -c release --show-bin-path)"
AW_APP_DIR="$AW_PROJECT_ROOT/build/a-watcher.app"
mkdir -p "$AW_APP_DIR/Contents/MacOS" "$AW_APP_DIR/Contents/Resources/Brand"
# SwiftPM links the binary framework but does not embed it into our hand-built .app.
AW_SPARKLE_FRAMEWORK="$AW_PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$AW_SPARKLE_FRAMEWORK"
mkdir -p "$AW_APP_DIR/Contents/Frameworks"
rm -rf "$AW_APP_DIR/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$AW_SPARKLE_FRAMEWORK" "$AW_APP_DIR/Contents/Frameworks/Sparkle.framework"
mkdir -p "$AW_APP_DIR/Contents/Resources/Licenses"
cp "$AW_PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$AW_APP_DIR/Contents/Resources/Licenses/Sparkle.txt"
cp "$AW_PROJECT_ROOT"/Resources/Brand/*.png "$AW_APP_DIR/Contents/Resources/Brand/"
cp "$AW_BIN_DIR/a-watcher" "$AW_APP_DIR/Contents/MacOS/a-watcher"
cp "$AW_BIN_DIR/watcherctl" "$AW_APP_DIR/Contents/MacOS/watcherctl"
cp "$AW_PROJECT_ROOT/Resources/Info.plist" "$AW_APP_DIR/Contents/Info.plist"
cp "$AW_PROJECT_ROOT/Resources/AppIcon.icns" "$AW_APP_DIR/Contents/Resources/AppIcon.icns"
# Preserve Sparkle's upstream signatures, including its on-demand installer/XPCs.
/usr/bin/codesign --force --sign - "$AW_APP_DIR"
/usr/bin/codesign --verify --deep --strict "$AW_APP_DIR"
printf 'Built %s\n' "$AW_APP_DIR"
