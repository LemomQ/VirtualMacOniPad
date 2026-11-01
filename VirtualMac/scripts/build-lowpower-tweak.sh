#!/bin/bash
# Build the VZLowPower SpringBoard tweak.
#
# Lock -> enable system low power mode; while locked -> re-assert it every
# ReassertSeconds (iOS drops low power mode on its own once the device charges
# past 80%, which is what let nightly maintenance tasks run and reset memory
# with a large VM resident); unlock -> disable only if this tweak enabled it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$VZ_BUILD_ROOT/ipad-tweak"
DYLIB="$OUT/VZLowPower.dylib"
PLIST="$OUT/VZLowPower.plist"

need_command ldid
need_command xcrun
need_file "$VZ_REPO_ROOT/vz/tweak/VZLowPower.m"
need_file "$VZ_REPO_ROOT/vz/tweak/VZLowPower.plist"

mkdir -p "$OUT"
xcrun --sdk iphoneos clang -arch arm64e \
    -miphoneos-version-min="$VZ_IPADOS_MIN_VERSION" \
    -isysroot "$SDK" -dynamiclib -fblocks \
    -framework Foundation -framework UIKit \
    -Wl,-undefined,dynamic_lookup \
    -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/VZLowPower.dylib \
    "$VZ_REPO_ROOT/vz/tweak/VZLowPower.m" -o "$DYLIB"
cp "$VZ_REPO_ROOT/vz/tweak/VZLowPower.plist" "$PLIST"
ldid -S "$DYLIB"
echo "SpringBoard low-power tweak built: $OUT"
