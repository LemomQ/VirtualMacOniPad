#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ATTEMPTS="${1:-5}"
START_WAIT="${VZ_IPAD_START_WAIT:-12}"
INPUT_SELF_TEST="${VZ_IPAD_INPUT_SELF_TEST:-0}"
BUNDLE="${VZ_IPAD_VM_BUNDLE:-/var/mobile/Media/VirtualMac/Sequoia.bundle}"

[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
    die "attempt count must be a positive integer"
[[ "$START_WAIT" =~ ^[1-9][0-9]*$ ]] ||
    die "VZ_IPAD_START_WAIT must be a positive integer"
[[ "$INPUT_SELF_TEST" == "0" || "$INPUT_SELF_TEST" == "1" ]] ||
    die "VZ_IPAD_INPUT_SELF_TEST must be 0 or 1"

ipad_ssh "
find /tmp -maxdepth 1 -name 'vz-launch-attempt-*' -exec rm -f {} +
"
for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    echo "native VZ launch attempt $attempt/$ATTEMPTS"
    VZ_STOP_HOST=1 "$SCRIPT_DIR/development/stop-ipad-vm.sh"
    ipad_ssh "
set -eu
app=/var/jb/Applications/VirtualMac.app
uiopen=/var/jb/usr/bin/uiopen
if test ! -x \"\$app/VirtualMac\"; then
  app=/Applications/VirtualMac.app
  uiopen=/usr/bin/uiopen
fi
test -x \"\$app/VirtualMac\"
test -x \"\$uiopen\"
test -d '$BUNDLE'
printf '%s\n' '$BUNDLE' >/tmp/vz-autoboot-path
chown mobile:mobile /tmp/vz-autoboot-path
rm -f /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
touch /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
chown mobile:mobile /tmp/VirtualMac.log /tmp/vzxpchook.log /tmp/vmmhook.log \
  /tmp/vmm.stderr.log /tmp/vmm_ep.txt /tmp/pvg-trace.log
if test '$INPUT_SELF_TEST' = 1; then
  touch /tmp/vz-input-self-test
  chown mobile:mobile /tmp/vz-input-self-test
else
  rm -f /tmp/vz-input-self-test
fi
rm -f /tmp/vz-dismiss-restart-alert
\"\$uiopen\" --bundleid com.mac.virtual
"
    sleep "$START_WAIT"
    result="$(ipad_ssh "
if grep -q 'VM STARTED state=1' /tmp/VirtualMac.log; then
  echo started
elif grep -q 'VM start failed:' /tmp/VirtualMac.log; then
  echo failed
else
  echo pending
fi
")"
    if [[ "$result" == "started" ]]; then
        ipad_ssh "
tail -12 /tmp/VirtualMac.log
grep -E 'hv_vcpu_(create|run)' /tmp/vmmhook.log | tail -6
"
        echo "native iPad VM started on attempt $attempt"
        exit 0
    fi
    echo "attempt $attempt result: $result"
    ipad_ssh "
for log in VirtualMac vzxpchook vmmhook vmm.stderr pvg-trace; do
  test ! -f /tmp/\$log.log ||
    cp /tmp/\$log.log /tmp/vz-launch-attempt-$attempt.\$log.log
done
"
done

ipad_ssh "
echo APP_LOG
tail -40 /tmp/VirtualMac.log 2>/dev/null || true
echo HOST_HOOK_LOG
tail -60 /tmp/vzxpchook.log 2>/dev/null || true
echo VMM_HOOK_LOG
tail -80 /tmp/vmmhook.log 2>/dev/null || true
"
die "native iPad VM did not start after $ATTEMPTS attempts"
