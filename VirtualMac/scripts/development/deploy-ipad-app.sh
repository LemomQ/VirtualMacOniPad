#!/bin/bash

# Install Virtual Mac in the rootless jailbreak application directory. This is
# the proven System-app configuration used by the native VMM. VM bundles live
# outside the app registration/container model at /var/mobile/Media/VirtualMac.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

APP="$VZ_BUILD_ROOT/ipad-app/VirtualMac.app"
BIN="$APP/VirtualMac"
HOOK="$APP/VZHostCompat.dylib"
BUNDLE_ID="com.mac.virtual"
REMOTE_APP="/var/jb/Applications/VirtualMac.app"
REMOTE_LIBRARY="/var/mobile/Media/VirtualMac"
ARCHIVE="$(mktemp -t virtual-mac-app.XXXXXX.tar.gz)"
trap 'rm -f "$ARCHIVE"' EXIT

need_command ldid
need_command tar
need_file "$BIN"
need_file "$HOOK"


tar -C "$VZ_BUILD_ROOT/ipad-app" -czf "$ARCHIVE" VirtualMac.app
ensure_ipad_usb
ipad_scp "$ARCHIVE" "$IPAD_TARGET:/tmp/virtual-mac-app.tar.gz"

bin_hash="$(ldid -h "$BIN" | sed -n 's/^CDHash=//p')"
hook_hash="$(ldid -h "$HOOK" | sed -n 's/^CDHash=//p')"
VZ_STOP_HOST=1 "$SCRIPT_DIR/stop-ipad-vm.sh"
ipad_ssh "
set -eu
current_path=\$(/var/jb/usr/bin/uicache -i '$BUNDLE_ID' 2>/dev/null |
  sed -n 's/^Path: //p')
if test -n \"\$current_path\"; then
  /var/jb/usr/bin/uicache -u \"\$current_path\" || true
fi
rm -rf '$REMOTE_APP'
tar -xzf /tmp/virtual-mac-app.tar.gz -C /var/jb/Applications
rm -f /tmp/virtual-mac-app.tar.gz
chmod 755 '$REMOTE_APP/VirtualMac' '$REMOTE_APP/VZHostCompat.dylib'
mkdir -p '$REMOTE_LIBRARY'
chown mobile:mobile '$REMOTE_LIBRARY'
chmod 755 '$REMOTE_LIBRARY'
jbctl trustcache add '$bin_hash'
jbctl trustcache add '$hook_hash'
/var/jb/usr/bin/uicache -p '$REMOTE_APP'
rm -f /tmp/VirtualMac.log \\
  /tmp/vzxpchook.log /tmp/vmmhook.log \\
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
touch /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \\
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
chown mobile:mobile /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \\
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
rm -f /tmp/vz-dismiss-restart-alert
/var/jb/usr/bin/uiopen --bundleid '$BUNDLE_ID'
"

for _ in {1..5}; do
    if ipad_ssh "ps ax | grep '/VirtualMac.app/VirtualMac' | grep -v grep" \
        >/dev/null 2>&1; then
        break
    fi
    ipad_ssh "/var/jb/usr/bin/uiopen --bundleid '$BUNDLE_ID'" || true
    sleep 1
done
ipad_ssh "
echo REGISTRATION
/var/jb/usr/bin/uicache -i '$BUNDLE_ID'
echo PROCESS
ps ax | grep '/VirtualMac.app/VirtualMac' | grep -v grep || true
echo VM_LIBRARY
ls -la '$REMOTE_LIBRARY'
echo APP_LOG
cat /tmp/VirtualMac.log 2>/dev/null || true
echo HOST_HOOK_LOG
cat /tmp/vzxpchook.log 2>/dev/null || true
echo VMM_HOOK_LOG
cat /tmp/vmmhook.log 2>/dev/null || true
"
