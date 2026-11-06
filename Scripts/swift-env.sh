#!/bin/bash
set -euo pipefail
AW_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AW_BUILD_CACHE="${TMPDIR:-/tmp}/a-watcher-build-cache"
mkdir -p "$AW_BUILD_CACHE/modules" "$AW_BUILD_CACHE/spm"
export CLANG_MODULE_CACHE_PATH="$AW_BUILD_CACHE/modules"
AW_SWIFT_FLAGS=(--cache-path "$AW_BUILD_CACHE/spm" --scratch-path "$AW_PROJECT_ROOT/.build" -Xswiftc -module-cache-path -Xswiftc "$AW_BUILD_CACHE/modules")
if [[ "${AW_SPM_NO_SANDBOX:-0}" == "1" ]]; then AW_SWIFT_FLAGS+=(--disable-sandbox); fi
