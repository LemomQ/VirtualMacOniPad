#!/bin/bash
# 本机仿真测试：在假的 VirtualMac.app 上运行 1.2.4 测试包的 install-on-ipad.sh，
# 覆盖替换、备份、幂等与回滚。
#
# 前置：
#   VZ_RELEASE_VERSION=1.2.4 bash scripts/build-ipad-app.sh
#   bash scripts/build-124-scroll-fullscreen-replacement.sh
# 运行：
#   bash scripts/tests/test-124-scroll-fullscreen-installer.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/build/release/VirtualMac-1.2.4-scroll-fullscreen"
INSTALLER="$PKG/install-on-ipad.sh"

[[ -f "$INSTALLER" && -f "$PKG/VirtualMac" && -f "$PKG/Info.plist" ]] || {
    echo "缺少替换包，请先运行 scripts/build-124-scroll-fullscreen-replacement.sh" >&2
    exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vm124-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

OLD_PLIST="$WORK/old-Info.plist"
cp "$PKG/Info.plist" "$OLD_PLIST"
plutil -replace CFBundleShortVersionString -string "1.2.3" "$OLD_PLIST"
plutil -replace UIRequiresFullScreen -bool false "$OLD_PLIST"

new_app() {
    local dir="$1" plist="$2"
    rm -rf "$dir"
    mkdir -p "$dir/GuestTools" "$dir/en.lproj" "$dir/zh_CN.lproj"
    printf 'old-binary-with-different-size' >"$dir/VirtualMac"
    chmod 755 "$dir/VirtualMac"
    cp "$plist" "$dir/Info.plist"
    printf 'old-guesttools-payload' >"$dir/GuestTools/VirtualMacGuestTools.tar.gz"
    grep -v 'Trackpad Scrolling Speed' \
        "$PKG/Localizations/en.lproj/Localizable.strings" \
        >"$dir/en.lproj/Localizable.strings"
    grep -v 'Trackpad Scrolling Speed' \
        "$PKG/Localizations/zh_CN.lproj/Localizable.strings" \
        >"$dir/zh_CN.lproj/Localizable.strings"
}

run_installer() {
    local app="$1"; shift
    VIRTUALMAC_TEST_APP_DIR="$app" VIRTUALMAC_TEST_PREFIX="$WORK/empty-prefix" \
        sh "$INSTALLER" "$@"
}

app="$WORK/VirtualMac.app"
new_app "$app" "$OLD_PLIST"
old_bin_sha="$(sha "$app/VirtualMac")"
old_plist_sha="$(sha "$app/Info.plist")"
old_tar_sha="$(sha "$app/GuestTools/VirtualMacGuestTools.tar.gz")"
old_en_sha="$(sha "$app/en.lproj/Localizable.strings")"

echo "############ case 1: 从旧版本安装到 1.2.4 测试版 ############"
run_installer "$app" >"$WORK/case1.out" 2>&1; rc=$?
tail -n 6 "$WORK/case1.out"
check "case1 exit=0" "[[ $rc -eq 0 ]]"
check "case1 主二进制已替换" "[[ \$(sha '$app/VirtualMac') == \$(sha '$PKG/VirtualMac') ]]"
check "case1 Info.plist 已替换" "[[ \$(sha '$app/Info.plist') == \$(sha '$PKG/Info.plist') ]]"
check "case1 GuestTools 已替换" "[[ \$(sha '$app/GuestTools/VirtualMacGuestTools.tar.gz') == \$(sha '$PKG/GuestTools/VirtualMacGuestTools.tar.gz') ]]"
check "case1 英文本地化已替换" "[[ \$(sha '$app/en.lproj/Localizable.strings') == \$(sha '$PKG/Localizations/en.lproj/Localizable.strings') ]]"
check "case1 中文本地化含新设置项" "grep -q '触控板滚动速度' '$app/zh_CN.lproj/Localizable.strings'"
check "case1 版本=1.2.4" "[[ \$(plutil -extract CFBundleShortVersionString raw '$app/Info.plist') == 1.2.4 ]]"
check "case1 全屏声明=true" "[[ \$(plutil -extract UIRequiresFullScreen raw '$app/Info.plist') == true ]]"
check "case1 不包含后台保活" "! plutil -extract UIBackgroundModes raw '$app/Info.plist' >/dev/null 2>&1"

backup="$(ls -d "$app"/VirtualMac124Backup-* 2>/dev/null | tail -1)"
check "case1 生成备份目录" "[[ -n '$backup' ]]"
check_file_matches() {
    if [[ "$(sha "$3")" == "$2" ]]; then pass "$1"; else fail "$1"; fi
}
check_file_matches "case1 备份了旧二进制" "$old_bin_sha" "$backup/VirtualMac"
check_file_matches "case1 备份了旧 plist" "$old_plist_sha" "$backup/Info.plist"
check_file_matches "case1 备份了旧 GuestTools" "$old_tar_sha" "$backup/VirtualMacGuestTools.tar.gz"
check_file_matches "case1 备份了旧英文本地化" "$old_en_sha" "$backup/Localizations/en.lproj/Localizable.strings"

echo "############ case 2: 重复安装 -> 幂等，不新增备份 ############"
before_backups="$(ls -d "$app"/VirtualMac124Backup-* 2>/dev/null | wc -l | tr -d ' ')"
run_installer "$app" >"$WORK/case2.out" 2>&1; rc=$?
grep -E "已经是该测试版本|没有需要修改" "$WORK/case2.out" | head -2
check "case2 exit=0" "[[ $rc -eq 0 ]]"
check "case2 识别为已安装" "grep -q '已经是该测试版本' '$WORK/case2.out'"
check "case2 不新增备份" "[[ \$(ls -d '$app'/VirtualMac124Backup-* 2>/dev/null | wc -l | tr -d ' ') == $before_backups ]]"

echo "############ case 3: restore 回滚到安装前 ############"
run_installer "$app" restore >"$WORK/case3.out" 2>&1; rc=$?
tail -n 3 "$WORK/case3.out"
check "case3 exit=0" "[[ $rc -eq 0 ]]"
check "case3 还原主二进制" "[[ \$(sha '$app/VirtualMac') == $old_bin_sha ]]"
check "case3 还原 Info.plist" "[[ \$(sha '$app/Info.plist') == $old_plist_sha ]]"
check "case3 还原 GuestTools" "[[ \$(sha '$app/GuestTools/VirtualMacGuestTools.tar.gz') == $old_tar_sha ]]"
check "case3 还原本地化" "[[ \$(sha '$app/en.lproj/Localizable.strings') == $old_en_sha ]]"

echo "############ case 4: 二进制 Info.plist -> 也能替换 ############"
app4="$WORK/case4/VirtualMac.app"
new_app "$app4" "$OLD_PLIST"
plutil -convert binary1 "$app4/Info.plist"
check "case4 输入是二进制 plist" "[[ \$(head -c 8 '$app4/Info.plist') == bplist00 ]]"
run_installer "$app4" >"$WORK/case4.out" 2>&1; rc=$?
check "case4 exit=0" "[[ $rc -eq 0 ]]"
check "case4 替换为 1.2.4 XML plist" "[[ \$(plutil -extract CFBundleShortVersionString raw '$app4/Info.plist') == 1.2.4 ]]"
check "case4 全屏声明=true" "[[ \$(plutil -extract UIRequiresFullScreen raw '$app4/Info.plist') == true ]]"

echo
if [[ $FAIL -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TEST(S) FAILED"
    exit 1
fi
