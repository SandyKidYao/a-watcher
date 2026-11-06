#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
cd "$AW_PROJECT_ROOT"
swift build "${AW_SWIFT_FLAGS[@]}" -c release --product a-watcher
swift build "${AW_SWIFT_FLAGS[@]}" -c release --product watcherctl
AW_BIN_DIR="$(swift build "${AW_SWIFT_FLAGS[@]}" -c release --show-bin-path)"
AW_APP_DIR="$AW_PROJECT_ROOT/build/a-watcher.app"
mkdir -p "$AW_APP_DIR/Contents/MacOS" "$AW_APP_DIR/Contents/Resources/Brand"
cp "$AW_PROJECT_ROOT"/Resources/Brand/*.png "$AW_APP_DIR/Contents/Resources/Brand/"
cp "$AW_BIN_DIR/a-watcher" "$AW_APP_DIR/Contents/MacOS/a-watcher"
cp "$AW_BIN_DIR/watcherctl" "$AW_APP_DIR/Contents/MacOS/watcherctl"
cp "$AW_PROJECT_ROOT/Resources/Info.plist" "$AW_APP_DIR/Contents/Info.plist"
cp "$AW_PROJECT_ROOT/Resources/AppIcon.icns" "$AW_APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$AW_APP_DIR"
printf 'Built %s\n' "$AW_APP_DIR"
