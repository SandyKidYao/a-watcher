#!/bin/bash
# Source this file; tools and framework must stay on the same pinned release.
AW_SPARKLE_VERSION=2.10.1
AW_SPARKLE_TOOL_DIR="$AW_PROJECT_ROOT/.build/sparkle-tools/$AW_SPARKLE_VERSION"
if [[ ! -x "$AW_SPARKLE_TOOL_DIR/bin/generate_appcast" ]]; then
    AW_SPARKLE_DOWNLOAD="$(mktemp -d "${TMPDIR:-/tmp}/aw-sparkle.XXXXXX")"
    trap 'rm -rf "$AW_SPARKLE_DOWNLOAD"' EXIT
    curl --fail --location --silent --show-error --retry 3 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$AW_SPARKLE_VERSION/Sparkle-$AW_SPARKLE_VERSION.tar.xz" \
        -o "$AW_SPARKLE_DOWNLOAD/Sparkle.tar.xz"
    printf '%s  %s\n' '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27' "$AW_SPARKLE_DOWNLOAD/Sparkle.tar.xz" | shasum -a 256 -c -
    mkdir -p "$AW_SPARKLE_TOOL_DIR"
    tar -xf "$AW_SPARKLE_DOWNLOAD/Sparkle.tar.xz" -C "$AW_SPARKLE_TOOL_DIR"
    rm -rf "$AW_SPARKLE_DOWNLOAD"
    trap - EXIT
fi
