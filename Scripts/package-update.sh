#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
cd "$AW_PROJECT_ROOT"
AW_TAG="${1:?Usage: bash Scripts/package-update.sh vX.Y.Z}"
[[ "$AW_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Only stable vX.Y.Z releases are supported.' >&2; exit 1; }
AW_PLIST="$AW_PROJECT_ROOT/build/a-watcher.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AW_PLIST")" == "${AW_TAG#v}" ]] || { echo 'Tag and application version differ.' >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$AW_PLIST" >/dev/null
/usr/bin/codesign --verify --deep --strict "$AW_PROJECT_ROOT/build/a-watcher.app"
source "$AW_PROJECT_ROOT/Scripts/sparkle-tools.sh"
AW_UPDATE_STAGE="$(mktemp -d "$AW_PROJECT_ROOT/.build/update-stage.XXXXXX")"
trap 'rm -rf "$AW_UPDATE_STAGE"' EXIT
AW_ARCHIVE="a-watcher-${AW_TAG}-macos-arm64.zip"
AW_DOWNLOAD_PREFIX="https://github.com/SandyKidYao/a-watcher/releases/download/$AW_TAG/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent build/a-watcher.app "$AW_UPDATE_STAGE/$AW_ARCHIVE"
AW_APPCAST_ARGS=(--maximum-deltas 0 --download-url-prefix "$AW_DOWNLOAD_PREFIX" -o "$AW_UPDATE_STAGE/appcast.xml" "$AW_UPDATE_STAGE")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # Pass secrets through stdin, never command-line arguments or logs.
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$AW_SPARKLE_TOOL_DIR/bin/generate_appcast" --ed-key-file - "${AW_APPCAST_ARGS[@]}"
else
    [[ "${CI:-false}" != true ]] || { echo 'SPARKLE_PRIVATE_KEY is required in CI.' >&2; exit 1; }
    "$AW_SPARKLE_TOOL_DIR/bin/generate_appcast" --account dev.awatcher.app "${AW_APPCAST_ARGS[@]}"
fi
swift -module-cache-path "$AW_BUILD_CACHE/modules" Scripts/verify-update.swift "$AW_PLIST" "$AW_UPDATE_STAGE/appcast.xml" "$AW_UPDATE_STAGE/$AW_ARCHIVE" "$AW_DOWNLOAD_PREFIX$AW_ARCHIVE"
mkdir -p dist
cp "$AW_UPDATE_STAGE/$AW_ARCHIVE" "$AW_UPDATE_STAGE/appcast.xml" dist/
(cd dist && shasum -a 256 "$AW_ARCHIVE" appcast.xml > SHA256SUMS.txt)
echo 'Signed update package ready in dist/ (not published).'
