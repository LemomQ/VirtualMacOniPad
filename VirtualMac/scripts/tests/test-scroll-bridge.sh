#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

OUTPUT="$VZ_BUILD_ROOT/tests/test-scroll-bridge"
mkdir -p "$(dirname "$OUTPUT")"
xcrun --sdk macosx clang -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework QuartzCore \
    "$VZ_REPO_ROOT/tests/test-scroll-bridge.m" \
    "$VZ_REPO_ROOT/vz/host/VZTrackpadScrollBridge.m" \
    -o "$OUTPUT"
"$OUTPUT"
