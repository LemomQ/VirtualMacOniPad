#!/bin/bash
# Build the lock-screen-suspension baseline plus the diagnostics-observability
# fix and package it as a drop-in replacement for the main binary.
#
# Why this exists instead of reusing build-scroll-replacement.sh: the working
# tree carries an unrelated pointer-lock feature that the mainline release train
# deliberately excludes (every variant from device-deltas through
# lock-screen-suspension ships PointerLock=0; it only ever appeared in the
# side-line pointerlock / pointerlock-safe / fullscreen packages). Building from
# the working tree would drag those 152 lines of input-path code into a
# stability test, so this script starts from the checked-in
# build/lock-screen-suspension-src snapshot instead and layers on exactly one
# change: the VZDiagnostics.m observability fix.
#
# The source delta against that baseline is asserted below, so a future edit to
# the snapshot or to the working tree cannot silently widen this package.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command ldid
need_command shasum
need_command zip

RELEASE_VERSION="${VZ_RELEASE_VERSION:-1.2.3}"
LABEL="${VZ_LSS_LABEL:-lock-screen-suspension-diag}"
RELEASE="${VZ_LSS_RELEASE_DIR:-$VZ_BUILD_ROOT/release}"
STAGE="$RELEASE/${LABEL}-replacement"
ZIP_NAME="VirtualMac-${RELEASE_VERSION}-${LABEL}.zip"
PATCH_NAME="VirtualMacOniPad-${RELEASE_VERSION}-${LABEL}.patch"
# CDHash of the binary this package replaces: the lock-screen-suspension build
# the device is currently running.
PREVIOUS_CDHASH="${VZ_LSS_PREVIOUS_CDHASH:-7eb7d93a3031f0d0b667d31d8ed77d52c17faa32}"

BASELINE_SRC="$VZ_REPO_ROOT/build/lock-screen-suspension-src/VirtualMac"
need_file "$BASELINE_SRC/vz/host/VirtualMacApp.m"
need_file "$BASELINE_SRC/vz/host/VZDiagnostics.m"

GIT_ROOT="$(git -C "$VZ_REPO_ROOT" rev-parse --show-toplevel)"
BUILD_COUNT="$(git -C "$GIT_ROOT" rev-list --count HEAD)"
BUILD_HASH="$(git -C "$GIT_ROOT" rev-parse --short=10 HEAD)"
# The work tree has to stay inside the git checkout: build-ipad-app.sh derives
# CFBundleVersion from `git rev-list --count HEAD`, and an out-of-tree copy would
# abort the build.
WORK="${VZ_LSS_WORK_DIR:-$GIT_ROOT/.build-lss}"
SRC="$WORK/src/VirtualMac"
OUT="${VZ_LSS_OUT_DIR:-$WORK/out}"

echo "=== 1/6 组装锁屏基线 + 诊断修复的源树 ==="
rm -rf "$WORK"
mkdir -p "$WORK/src" "$OUT"
ditto "$BASELINE_SRC" "$SRC"
# The diagnostics fix is the only intended source delta. It lives in the working
# tree because it is independent of the pointer-lock work.
ditto "$VZ_REPO_ROOT/vz/host/VZDiagnostics.m" "$SRC/vz/host/VZDiagnostics.m"
# VZLowPower is not part of the baseline snapshot; carry the current revision so
# the packaged tweak and this app agree on the persistent log path.
if [[ -f "$VZ_REPO_ROOT/vz/tweak/VZLowPower.m" ]]; then
    ditto "$VZ_REPO_ROOT/vz/tweak/VZLowPower.m" "$SRC/vz/tweak/VZLowPower.m"
    ditto "$VZ_REPO_ROOT/vz/tweak/VZLowPower.plist" "$SRC/vz/tweak/VZLowPower.plist"
    ditto "$SCRIPT_DIR/build-lowpower-tweak.sh" \
        "$SRC/scripts/build-lowpower-tweak.sh"
fi

echo "=== 2/6 断言源增量只含诊断修复 ==="
# PointerLock is the marker for the excluded side-line; the other two must hold.
assert_lines() {
    local file="$1" pattern="$2" expected="$3" label="$4" actual
    actual="$(grep -c "$pattern" "$file" || true)"
    [[ "$actual" == "$expected" ]] ||
        die "$label: 期望 $expected 处，实际 $actual 处（$file）"
}
assert_lines "$SRC/vz/host/VirtualMacApp.m" 'PointerLock' 0 '指针锁定不应进入本包'
assert_lines "$SRC/vz/host/VZAppSettings.m" 'PointerLock' 0 '指针锁定不应进入本包'
assert_lines "$SRC/vz/host/VirtualMacApp.m" \
    'locked-screen presentation suppression installed' 1 '锁屏抑制必须存在'
assert_lines "$SRC/vz/host/VZDiagnostics.m" 'VZGuestMemorySummary' 2 '诊断修复必须存在'
if [[ -f "$SRC/vz/tweak/VZLowPower.m" ]]; then
    assert_lines "$SRC/vz/tweak/VZLowPower.m" 'VZLowPowerPersistentLogPath' 4 \
        'VZLowPower v3 持久化日志必须存在'
fi
# Only VZDiagnostics.m may differ from the baseline.
for relative in vz/host/VirtualMacApp.m vz/host/VZAppSettings.m \
                vz/host/VZSettingsViewController.m; do
    if ! diff -q "$BASELINE_SRC/$relative" "$SRC/$relative" >/dev/null; then
        die "$relative 与锁屏基线不一致，本包只应叠加 VZDiagnostics.m"
    fi
done

echo "=== 3/6 构建主程序与 tweak ==="
(
    cd "$SRC"
    VZ_BUILD_ROOT="$OUT" VZ_RELEASE_VERSION="$RELEASE_VERSION" \
        bash scripts/build-ipad-app.sh >/dev/null
)
APP="$OUT/ipad-app/VirtualMac.app"
need_file "$APP/VirtualMac"
if [[ -f "$SRC/scripts/build-lowpower-tweak.sh" ]]; then
    (
        cd "$SRC"
        VZ_BUILD_ROOT="$OUT" bash scripts/build-lowpower-tweak.sh >/dev/null
    )
fi

echo "=== 4/6 校验二进制指纹 ==="
BIN="$APP/VirtualMac"
assert_lines_str() {
    local pattern="$1" expected="$2" label="$3" actual
    actual="$(strings -a "$BIN" | grep -c "$pattern" || true)"
    [[ "$actual" == "$expected" ]] || die "$label: 期望 $expected，实际 $actual"
}
assert_lines_str 'PointerLock' 0 '二进制不应含指针锁定'
assert_lines_str 'pointer lock %s' 0 '二进制不应含指针锁定'
assert_lines_str 'locked-screen presentation suppression installed' 1 \
    '二进制必须含锁屏抑制'
assert_lines_str 'Guest memory: %@' 1 '二进制必须含诊断修复'

echo "=== 5/6 组装发布包 ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$BIN" "$STAGE/VirtualMac"
xattr -c "$STAGE/VirtualMac" 2>/dev/null || true
# Info.plist and VZHostCompat.dylib are untouched by this change and are already
# correct on device, so they travel for completeness only and need no CDHash
# registration.
ditto "$VZ_REPO_ROOT/build/release/lock-screen-suspension-replacement/Info.plist" \
    "$STAGE/Info.plist" 2>/dev/null || true
xattr -c "$STAGE/Info.plist" 2>/dev/null || true

main_cdhash="$(ldid -h "$STAGE/VirtualMac" | sed -n 's/^CDHash=//p')"
[[ -n "$main_cdhash" ]] || die "无法读取主二进制 CDHash"

# The patch is the delta against the package this one supersedes, so reviewing
# it shows exactly what changed on device.
{
    printf -- '--- a/VirtualMac/vz/host/VZDiagnostics.m\n'
    printf -- '+++ b/VirtualMac/vz/host/VZDiagnostics.m\n'
    diff -u "$BASELINE_SRC/vz/host/VZDiagnostics.m" \
        "$SRC/vz/host/VZDiagnostics.m" | tail -n +3 || true
} > "$STAGE/$PATCH_NAME"

cat > "$STAGE/SHA256SUMS" <<EOF
$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')  VirtualMac  cdhash=$main_cdhash
EOF

sed -e "s/@MAIN_CDHASH@/$main_cdhash/" \
    -e "s/@PREVIOUS_CDHASH@/$PREVIOUS_CDHASH/" \
    "$SCRIPT_DIR/lss-diag-install.sh.in" > "$STAGE/install-on-ipad.sh"
chmod 755 "$STAGE/install-on-ipad.sh"

cat > "$STAGE/README.md" <<EOF
# Virtual Mac ${RELEASE_VERSION} 锁屏抑制基线 + 诊断修复替换包

变体名称：\`${LABEL}\`

- 提交：${BUILD_HASH}（build ${BUILD_COUNT}）
- 基线：\`lock-screen-suspension-1.2.3\`（源码快照
  \`build/lock-screen-suspension-src/VirtualMac\`，与 \`VirtualMac-1.2.3-lock-screen-suspension.zip\`
  同源）
- 源码增量：\`${PATCH_NAME}\`，**只改 \`vz/host/VZDiagnostics.m\` 一个文件**。
  \`VirtualMacApp.m\` / \`VZAppSettings.m\` / \`VZSettingsViewController.m\`
  与锁屏基线逐字节相同（构建脚本里有断言）。
- 二进制信息：sha256 \`$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')\`，
  cdhash \`$main_cdhash\`

## 本包做了什么

**保留锁屏绘制修复的全部内容，只增加"让下一次过夜测试能得出结论"所需的诊断输出。**

锁屏抑制（\`com.apple.springboard.lockstate\` + \`hasBlankedScreen\` 检测、
摘除 guest CALayer、抑制 \`occlusionState\`、解锁恢复）与之前完全一致，
源码未动。

新增的三处诊断（都在 \`VZDiagnostics.m\`）：

1. 诊断包收录 \`VZLowPower\` 日志 —— 原先只收 \`/tmp\` 白名单，
   tweak 的日志从来没进过包；
2. \`manifest.txt\` 增加 \`Guest memory:\` 一行，直接给出
   "客户机内存 / 物理内存"这个最关键的比例；
3. 路径清单补上 \`VZLowPower.dylib\` 的四个注入位置。

配合 \`lowpower-reassert-v3\` 的持久化日志，下一次过夜测试可以直接读到
整夜的锁屏/省电心跳与客户机内存配置。

## 不包含什么

**不包含指针锁定（pointer lock）。** 主线从 \`device-deltas\` 到
\`lock-screen-suspension\` 的每一个发布都是 \`PointerLock=0\`；该功能只出现在
09-25 的 \`pointerlock\` / \`pointerlock-safe\` / \`fullscreen\` 三条侧线包里。
工作树里有它（\`VirtualMacApp.m\` 152 行），本包刻意不带。

## 文件清单

| 文件 | 说明 |
| --- | --- |
| VirtualMac | 主机可执行文件（arm64，最低 iOS 14.5） |
| Info.plist | 与锁屏包一致，设备上已装则**无需**替换 |
| install-on-ipad.sh | 在 iPad 上完成备份、替换与 CDHash 注册 |
| ${PATCH_NAME} | 相对锁屏基线的源码增量 |
| SHA256SUMS | sha256 与需要注册的 CDHash |

VZHostCompat.dylib 在所有历史包与本次构建中逐字节相同
（sha256 \`e83691795a7c6ceb…\`），因此本包不包含它，也无需重新注册其 CDHash。

## 安装（Filza，无根越狱 Dopamine）

只替换一个文件。把本目录拷到 iPad，执行：

    sh install-on-ipad.sh

或手工：停掉虚拟机，用 Filza 把 \`VirtualMac\` 覆盖到
\`/var/jb/Applications/VirtualMac.app/VirtualMac\`（权限 \`0755\`、\`root:wheel\`），
再用 jbctl 注册 CDHash：

    /var/jb/usr/bin/jbctl trustcache add $main_cdhash

## 回滚

把 \`LockScreenDiagBackup-*\` 里的 \`VirtualMac\` 拷回应用包，
并重新注册旧 CDHash \`$PREVIOUS_CDHASH\`。

## 与内存问题的关系

本包**不解决**虚拟机过夜被 \`SystemMemoryReset\` 杀掉的问题。
那需要把客户机内存从 10 GiB 降下来（见
\`build/diag-20261010/虚拟机夜间被杀原因分析-20261010.md\`）。
本包的作用是让下一次测试能拿到判定所需的证据。
EOF

rm -f "$RELEASE/$ZIP_NAME"
( cd "$STAGE" && zip -q -X "$ZIP_NAME" VirtualMac install-on-ipad.sh \
    README.md SHA256SUMS "$PATCH_NAME" Info.plist )

echo "=== 6/6 完成 ==="
echo "替换包：$STAGE"
echo "  $ZIP_NAME"
echo "  $PATCH_NAME"
echo "  VirtualMac sha256=$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')"
echo "  VirtualMac cdhash=$main_cdhash"

if [[ -d "$OUT/ipad-tweak" ]]; then
    TWEAK_STAGE="$RELEASE/lowpower-reassert-v3"
    rm -rf "$TWEAK_STAGE"
    mkdir -p "$TWEAK_STAGE"
    ditto "$OUT/ipad-tweak/VZLowPower.dylib" "$TWEAK_STAGE/VZLowPower.dylib"
    ditto "$OUT/ipad-tweak/VZLowPower.plist" "$TWEAK_STAGE/VZLowPower.plist"
    tweak_cdhash="$(ldid -h "$TWEAK_STAGE/VZLowPower.dylib" | sed -n 's/^CDHash=//p')"
    cat > "$TWEAK_STAGE/SHA256SUMS" <<EOF
$(shasum -a 256 "$TWEAK_STAGE/VZLowPower.dylib" | awk '{print $1}')  VZLowPower.dylib  cdhash=$tweak_cdhash
$(shasum -a 256 "$TWEAK_STAGE/VZLowPower.plist" | awk '{print $1}')  VZLowPower.plist
EOF
    cat > "$TWEAK_STAGE/使用说明.md" <<'EOF'
# VZLowPower v3（日志改到数据分区）

- 二进制：`VZLowPower.dylib`（arm64e，已 ldid 签名）
- 与 v2 的唯一区别：日志从 `/tmp/VZLowPower.log` 改为
  `/var/mobile/Library/Logs/VZLowPower.log`（打不开时退回 `/tmp`）。

## 为什么必须改

`SystemMemoryReset`（bug_type 301）执行的是 userspace reboot，**它会清空 `/tmp`**。
2026-10-10 那份日志第一行是 `03:12:07`，也就是 `03:12:00` 那次重置之后 7 秒，
之前整晚的内容全部丢失 —— 日志恰好丢掉了它本该记录的那一夜。

改到数据分区后，日志能跨过 userspace reboot 存活，整夜的
`heartbeat locked=… system-lowpower=…` 心跳可以被诊断包取到
（宿主 app 已同步改为收录 `logs/VZLowPower-persistent.log`）。

## 功能定位（重要）

v2 已被证伪：低电量模式整夜都是开的，虚拟机照样在 03:12 被杀。
原因是夜间维护守护进程合计只有 158 MiB，而门槛要求腾出约 5 GB。
**v3 不改变这一点**，它只是把日志修好。不要把它当成内存问题的解。

## 安装（Filza，Dopamine 无根越狱）

1. 解压到 `/var/mobile/Documents/`；
2. 覆盖这两个位置的 `VZLowPower.dylib` / `VZLowPower.plist`
   （Dopamine 上这两条路径常常是同一目录的两种视图，看到哪条换哪条）：
   ```
   /var/jb/Library/MobileSubstrate/DynamicLibraries/
   /var/jb/usr/lib/TweakInject/
   ```
   权限：dylib `0755`、plist `0644`，所有者 `root:wheel`；
3. `ldrestart`（Respring 不够）；
4. 用 Filza 打开 `/var/mobile/Library/Logs/VZLowPower.log`，
   首行应为 `loaded (v3; log=/var/mobile/Library/Logs/VZLowPower.log; …)`。

## 回滚

把旧的 v2 dylib 拷回原位（或删除这两个文件），然后 `ldrestart`。
EOF
    ( cd "$TWEAK_STAGE" && zip -q -X "VZLowPower-reassert-v3.zip" \
        VZLowPower.dylib VZLowPower.plist SHA256SUMS 使用说明.md )
    echo "tweak：$TWEAK_STAGE"
    echo "  VZLowPower.dylib cdhash=$tweak_cdhash"
fi

# Publish to the shared folder the iPad reads. Skipped when it is not mounted.
SHARE_DIR="${VZ_LSS_SHARE_DIR:-/Volumes/My Shared Files/File Provider Storage/macOS 测试}"
if [[ -n "$SHARE_DIR" && -d "$SHARE_DIR" ]]; then
    for pair in "$STAGE:${LABEL}-${RELEASE_VERSION}" \
                "${RELEASE}/lowpower-reassert-v3:lowpower-reassert-v3"; do
        from="${pair%%:*}"; to="${pair##*:}"
        [[ -d "$from" ]] || continue
        if mkdir -p "$SHARE_DIR/$to" && cp -p "$from"/* "$SHARE_DIR/$to/"; then
            echo "已发布到 $SHARE_DIR/$to"
        else
            echo "警告：无法写入 $SHARE_DIR/$to" >&2
        fi
    done
else
    echo "共享盘未挂载；请手动复制 $STAGE"
fi
