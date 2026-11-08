#!/bin/bash
# 本机仿真测试：在假的 VirtualMac.app 目录上运行设备安装脚本
# install-on-ipad.sh，覆盖 XML 合并、幂等、二进制 plist 回退、二进制替换与回滚。
#
# 先构建替换包，再运行本脚本：
#   bash scripts/build-lss-fullscreen-replacement.sh
#   bash scripts/tests/test-lss-fullscreen-installer.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/build/release/lock-screen-suspension-diag-fullscreen-replacement"
INSTALLER="$PKG/install-on-ipad.sh"
BIN="$PKG/VirtualMac"
SOURCE_PLIST="$ROOT/build/lock-screen-suspension-src/VirtualMac/vz/host/VirtualMac-Info.plist"

[[ -f "$INSTALLER" && -f "$BIN" && -f "$PKG/Info.plist" ]] || {
    echo "缺少替换包，请先运行 scripts/build-lss-fullscreen-replacement.sh" >&2
    exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lss-fullscreen-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 测试用的"设备现有 Info.plist"：源码基线 plist，去掉 UIRequiresFullScreen，
# 这样它和用户设备上安装 deb 后留下的 plist 一样（有其它键，但没有全屏声明）。
BASE_PLIST="$WORK/base-Info.plist"
cp "$SOURCE_PLIST" "$BASE_PLIST"
plutil -remove UIRequiresFullScreen "$BASE_PLIST" 2>/dev/null || true
cp "$PKG/Info.plist" "$WORK/package-Info.plist"

FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

run_installer() {
    local app="$1"; shift
    VIRTUALMAC_TEST_APP_DIR="$app" VIRTUALMAC_TEST_PREFIX="$WORK/empty-prefix" \
        sh "$INSTALLER" "$@"
}

new_app() {
    local dir="$1" plist="$2" binary="$3"
    rm -rf "$dir"; mkdir -p "$dir"
    cp "$plist" "$dir/Info.plist"
    if [[ "$binary" == "real" ]]; then
        cp "$BIN" "$dir/VirtualMac"
    else
        printf 'dummy-binary' >"$dir/VirtualMac"
    fi
    chmod 755 "$dir/VirtualMac"
}

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

echo "############ case 1: XML plist 缺键 -> 就地插入，其它键保持不变 ############"
app="$WORK/case1"; new_app "$app" "$BASE_PLIST" real
before_json="$(plutil -convert json -o - "$app/Info.plist")"
run_installer "$app" >"$WORK/case1.out" 2>&1; rc=$?
tail -n 5 "$WORK/case1.out"
check "case1 exit=0" "[[ $rc -eq 0 ]]"
check "case1 plist lint OK" "plutil -lint '$app/Info.plist' >/dev/null 2>&1"
check "case1 UIRequiresFullScreen=true" "[[ \$(plutil -extract UIRequiresFullScreen raw '$app/Info.plist') == true ]]"
check "case1 备份目录存在" "ls -d '$app'/LockScreenFullScreenBackup-* >/dev/null 2>&1"
check "case1 原键全部保留" "python3 - '$before_json' '$app/Info.plist' <<'PY'
import json, plistlib, sys
before = json.loads(sys.argv[1])
with open(sys.argv[2], 'rb') as f:
    after = plistlib.load(f)
missing = [k for k in before if k not in after]
changed = [k for k in before if k in after and after[k] != before[k]]
sys.exit(0 if not missing and not changed else 1)
PY"
check "case1 主二进制大小相同 -> 未替换" "[[ \$(shasum -a 256 '$app/VirtualMac' | awk '{print \$1}') == \$(shasum -a 256 '$BIN' | awk '{print \$1}') ]]"
check "case1 输出提示跳过二进制" "grep -q '跳过替换' '$WORK/case1.out'"
check "case1 输出提示已加入键" "grep -q '加入 UIRequiresFullScreen=true' '$WORK/case1.out'"

echo "############ case 2: 再跑一次 -> 幂等 ############"
after1_sha="$(sha "$app/Info.plist")"
run_installer "$app" >"$WORK/case2.out" 2>&1; rc=$?
check "case2 exit=0" "[[ $rc -eq 0 ]]"
check "case2 输出提示无需修改" "grep -q '没有需要修改的内容' '$WORK/case2.out'"
check "case2 plist 未变化" "[[ \$(sha '$app/Info.plist') == $after1_sha ]]"
check "case2 幂等运行不新增备份" "[[ \$(ls -d '$app'/LockScreenFullScreenBackup-* | wc -l | tr -d ' ') == 1 ]]"

echo "############ case 3: XML plist 已有 false -> 整份回退为 true ############"
app3="$WORK/case3"; mkdir -p "$app3"
cp "$BASE_PLIST" "$app3/Info.plist"
plutil -insert UIRequiresFullScreen -bool false "$app3/Info.plist"
printf 'dummy-binary' >"$app3/VirtualMac"; chmod 755 "$app3/VirtualMac"
run_installer "$app3" >"$WORK/case3.out" 2>&1; rc=$?
check "case3 exit=0" "[[ $rc -eq 0 ]]"
check "case3 plist lint OK" "plutil -lint '$app3/Info.plist' >/dev/null 2>&1"
check "case3 UIRequiresFullScreen=true" "[[ \$(plutil -extract UIRequiresFullScreen raw '$app3/Info.plist') == true ]]"

echo "############ case 4: 二进制 plist -> 用包内完整 plist 回退 ############"
app4="$WORK/case4"; mkdir -p "$app4"
cp "$BASE_PLIST" "$app4/Info.plist"
plutil -convert binary1 "$app4/Info.plist"
cp "$BIN" "$app4/VirtualMac"; chmod 755 "$app4/VirtualMac"
check "case4 输入确实是二进制 plist" "[[ \$(head -c 8 '$app4/Info.plist') == bplist00 ]]"
run_installer "$app4" >"$WORK/case4.out" 2>&1; rc=$?
check "case4 exit=0" "[[ $rc -eq 0 ]]"
check "case4 plist lint OK" "plutil -lint '$app4/Info.plist' >/dev/null 2>&1"
check "case4 UIRequiresFullScreen=true" "[[ \$(plutil -extract UIRequiresFullScreen raw '$app4/Info.plist') == true ]]"
check "case4 使用回退包版本号（57）" "[[ \$(plutil -extract CFBundleVersion raw '$app4/Info.plist') == 57 ]]"

echo "############ case 5: 主二进制大小不同 -> 被替换成包内二进制 ############"
app5="$WORK/case5"; new_app "$app5" "$BASE_PLIST" dummy
run_installer "$app5" >"$WORK/case5.out" 2>&1; rc=$?
check "case5 exit=0" "[[ $rc -eq 0 ]]"
check "case5 二进制已替换" "[[ \$(sha '$app5/VirtualMac') == \$(sha '$BIN') ]]"
check "case5 输出提示替换" "grep -q '替换为包内二进制' '$WORK/case5.out'"

echo "############ case 6: restore 回滚 ############"
orig_plist_sha="$(sha "$BASE_PLIST")"
run_installer "$app" restore >"$WORK/case6.out" 2>&1; rc=$?
check "case6 exit=0" "[[ $rc -eq 0 ]]"
check "case6 Info.plist 已还原" "[[ \$(sha '$app/Info.plist') == $orig_plist_sha ]]"

echo "############ case 7: 畸形 plist -> 安全失败，不改文件 ############"
app7="$WORK/case7"; mkdir -p "$app7"
printf '<?xml version="1.0"?>\n<plist><dict><key>X</key><true/></dict>\n' >"$app7/Info.plist"
printf 'dummy' >"$app7/VirtualMac"; chmod 755 "$app7/VirtualMac"
bad_sha="$(sha "$app7/Info.plist")"
run_installer "$app7" >"$WORK/case7.out" 2>&1; rc=$?
check "case7 非零退出" "[[ $rc -ne 0 ]]"
check "case7 原 plist 未被破坏" "[[ \$(sha '$app7/Info.plist') == $bad_sha ]]"

echo "############ case 8: 二进制被替换后 restore 同时还原二进制 ############"
app8="$WORK/case8"; new_app "$app8" "$BASE_PLIST" dummy
run_installer "$app8" >"$WORK/case8.out" 2>&1
check "case8 安装后二进制已替换" "[[ \$(sha '$app8/VirtualMac') == \$(sha '$BIN') ]]"
run_installer "$app8" restore >"$WORK/case8r.out" 2>&1; rc=$?
check "case8 restore exit=0" "[[ $rc -eq 0 ]]"
check "case8 restore 还原 Info.plist" "[[ \$(sha '$app8/Info.plist') == $orig_plist_sha ]]"
check "case8 restore 还原主二进制" "[[ \$(sha '$app8/VirtualMac') == \$(printf 'dummy-binary' | shasum -a 256 | awk '{print \$1}') ]]"

echo
if [[ $FAIL -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TEST(S) FAILED"
    exit 1
fi
