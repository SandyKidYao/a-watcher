#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
cd "$AW_PROJECT_ROOT"
AW_UPDATE_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aw-update-checks.XXXXXX")"
trap 'rm -rf "$AW_UPDATE_CHECK_DIR"' EXIT
swiftc -module-cache-path "$AW_BUILD_CACHE/modules" Scripts/verify-update.swift -o "$AW_UPDATE_CHECK_DIR/verify-update"
swift -module-cache-path "$AW_BUILD_CACHE/modules" Tests/UpdateChecks.swift "$AW_UPDATE_CHECK_DIR/verify-update"
