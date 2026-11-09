#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
cd "$AW_PROJECT_ROOT"
# The self-contained checks also work with Command Line Tools installations
# whose bundled Testing.framework lacks its _TestingInterop runtime.
swift run "${AW_SWIFT_FLAGS[@]}" watcher-checks
bash Scripts/check-updates.sh
