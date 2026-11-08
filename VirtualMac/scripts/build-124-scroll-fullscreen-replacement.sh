#!/bin/bash
# 把「1.2.4 + 鼠标滚轮/触控板修复 + 全屏声明」的构建结果打包成与之前相同的
# 设备替换包（install-on-ipad.sh + 文件 + README + patch），并发布到共享盘。
#
# 前置：先构建 app（只应用了滚动/触控板补丁与全屏声明的 1.2.4 源树）：
#     bash scripts/build-ipad-app.sh
#
# 本脚本不重新编译，只打包 build/ipad-app/VirtualMac.app。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command plutil
need_command shasum
need_command zip
need_command tar

RELEASE_VERSION="1.2.4"
LABEL="scroll-fullscreen"
STAGE="$VZ_BUILD_ROOT/release/VirtualMac-${RELEASE_VERSION}-${LABEL}"
ZIP_NAME="VirtualMac-${RELEASE_VERSION}-${LABEL}.zip"
PATCH_NAME="VirtualMacOniPad-${RELEASE_VERSION}-scroll-touchpad-fullscreen.patch"
APP="$VZ_BUILD_ROOT/ipad-app/VirtualMac.app"
INSTALL_TEMPLATE="$SCRIPT_DIR/scroll-fullscreen-124-install.sh.in"
SHARE_DIR="${VZ_124_SHARE_DIR:-/Volumes/My Shared Files/File Provider Storage/macOS 测试}"
SOURCE_TAG="1.2.4"

need_file "$APP/VirtualMac"
need_file "$APP/Info.plist"
need_file "$APP/GuestTools/VirtualMacGuestTools.tar.gz"
need_file "$INSTALL_TEMPLATE"
need_file "$VZ_REPO_ROOT/tests/test-scroll-bridge.m"

echo "=== 1/6 校验构建结果的范围（只含滚动/触控板 + 全屏） ==="
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")" == "$RELEASE_VERSION" ]] ||
    die "Info.plist 版本不是 $RELEASE_VERSION"
fullscreen_raw="$(plutil -extract UIRequiresFullScreen raw "$APP/Info.plist")"
case "$fullscreen_raw" in
    1 | true) ;;
    *) die "Info.plist 缺少 UIRequiresFullScreen=true（实际：$fullscreen_raw）" ;;
esac
if plutil -extract UIBackgroundModes raw "$APP/Info.plist" >/dev/null 2>&1; then
    die "不应该包含 UIBackgroundModes（后台保活属于未应用的修复）"
fi
BIN="$APP/VirtualMac"
assert_bin_present() {
    local pattern="$1" label="$2" actual
    actual="$(strings -a "$BIN" | grep -c "$pattern" || true)"
    [[ "$actual" -ge 1 ]] || die "主二进制缺少 $label（$pattern）"
}
assert_bin_absent() {
    local pattern="$1" label="$2" actual
    actual="$(strings -a "$BIN" | grep -c "$pattern" || true)"
    [[ "$actual" == 0 ]] || die "主二进制不应含 $label（$pattern）"
}
assert_bin_present "TrackpadScrollingSpeed" "触控板滚动速度设置"
assert_bin_present "trackpad=" "触控板速度诊断输出"
assert_bin_absent "PointerLock" "指针锁定"
assert_bin_absent "locked-screen presentation suppression installed" "锁屏抑制"
assert_bin_absent "VZLowPower" "低电量 tweak"
assert_bin_absent "SBTopAffordance" "SpringBoard 三点抑制 hook"

localization_count=0
for source in "$APP"/*.lproj/Localizable.strings; do
    test -f "$source" || continue
    if grep -q "Trackpad Scrolling Speed" "$source"; then
        localization_count=$((localization_count + 1))
    fi
done
[[ "$localization_count" == 37 ]] ||
    die "本地化字符串数量不符：$localization_count（预期 37）"

guesttools_version="$(tar -xOzf "$APP/GuestTools/VirtualMacGuestTools.tar.gz" \
    "Library/VirtualMac/Virtual Mac Guest Tools.app/Contents/Info.plist" |
    plutil -extract CFBundleShortVersionString raw - 2>/dev/null || true)"
[[ "$guesttools_version" == "$RELEASE_VERSION" ]] ||
    die "GuestTools 版本不符：${guesttools_version:-未知}"

echo "=== 2/6 组装替换包文件 ==="
rm -rf "$STAGE"
mkdir -p "$STAGE/GuestTools" "$STAGE/Localizations"
cp -p "$BIN" "$STAGE/VirtualMac"
cp -p "$APP/Info.plist" "$STAGE/Info.plist"
cp -p "$APP/GuestTools/VirtualMacGuestTools.tar.gz" \
    "$STAGE/GuestTools/VirtualMacGuestTools.tar.gz"
for source in "$APP"/*.lproj/Localizable.strings; do
    test -f "$source" || continue
    language="$(basename "$(dirname "$source")")"
    mkdir -p "$STAGE/Localizations/$language"
    cp -p "$source" "$STAGE/Localizations/$language/Localizable.strings"
done
xattr -cr "$STAGE" 2>/dev/null || true

main_cdhash="$(ldid -h "$STAGE/VirtualMac" | sed -n 's/^CDHash=//p')"
[[ -n "$main_cdhash" ]] || die "无法读取主二进制 CDHash"
main_sha="$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')"
main_size="$(wc -c <"$STAGE/VirtualMac" | tr -d '[:space:]')"
guesttools_size="$(wc -c <"$STAGE/GuestTools/VirtualMacGuestTools.tar.gz" | tr -d '[:space:]')"

echo "=== 3/6 生成设备安装脚本 ==="
sed -e "s/@MAIN_CDHASH@/$main_cdhash/" \
    -e "s/@EXPECTED_BINARY_SIZE@/$main_size/" \
    -e "s/@EXPECTED_GUESTTOOLS_SIZE@/$guesttools_size/" \
    "$INSTALL_TEMPLATE" > "$STAGE/install-on-ipad.sh"
chmod 755 "$STAGE/install-on-ipad.sh"
sh -n "$STAGE/install-on-ipad.sh" || die "安装脚本语法错误"

echo "=== 4/6 生成 SHA256SUMS 与源码补丁 ==="
{
    printf '%s  VirtualMac  cdhash=%s\n' "$main_sha" "$main_cdhash"
    shasum -a 256 "$STAGE/Info.plist" "$STAGE/GuestTools/VirtualMacGuestTools.tar.gz" |
        sed "s#  $STAGE/#  #"
    (cd "$STAGE" && find Localizations -type f | LC_ALL=C sort |
        while IFS= read -r file; do
            shasum -a 256 "$file" | sed "s#  $file#  $file#"
        done)
} >"$STAGE/SHA256SUMS"

GIT_ROOT="$(git -C "$VZ_REPO_ROOT" rev-parse --show-toplevel)"
git -C "$GIT_ROOT" diff "$SOURCE_TAG" -- \
    VirtualMac/resources VirtualMac/tests VirtualMac/vz >"$STAGE/$PATCH_NAME"

echo "=== 5/6 生成 README ==="
cat >"$STAGE/README.md" <<EOF
# Virtual Mac ${RELEASE_VERSION} 测试替换包（鼠标滚轮/触控板 + 全屏声明）

变体名称：\`${LABEL}\`

- 基线：upstream **1.2.4**（\`${SOURCE_TAG}\`）
- 只应用你的两类修复：
  1. **鼠标滚轮/触控板更改**（device-deltas-speed-fs 变体）：触控板使用 iPadOS
     自身的 raw/acceleratedDelta 与动量包，所有滚动来源统一走逐帧合流器，
     并新增「触控板滚动速度」设置（0.1–1.0，默认 0.5）；
  2. **全屏声明**：Info.plist 中 \`UIRequiresFullScreen=true\`，关闭 iPadOS
     分屏/侧拉，顶部不再出现三个点。
- 主二进制：sha256 \`${main_sha}\`，cdhash \`${main_cdhash}\`，
  ${main_size} 字节（1.2.4 + 滚动/触控板修复）
- GuestTools 载荷：1.2.4（${guesttools_size} 字节）
- 源码补丁：\`${PATCH_NAME}\`（对 1.2.4 的完整改动，可直接 \`git apply\`）

## 明确不包含的修复

锁屏绘制修复、键盘/低电量适配、指针锁定（PointerLock）、后台保活
（UIBackgroundModes）、主机网络修复，以及任何 tweak 都用 1.2.4 原生状态。
这些不在本测试包范围内。

## 文件清单

| 文件 | 说明 |
| --- | --- |
| VirtualMac | 1.2.4 + 滚动/触控板修复的主二进制 |
| Info.plist | 1.2.4 plist + UIRequiresFullScreen |
| GuestTools/VirtualMacGuestTools.tar.gz | 1.2.4 GuestTools 载荷 |
| Localizations/ | 37 种语言的本地化字符串（含新的触控板滚动速度项） |
| install-on-ipad.sh | 设备端安装/回滚脚本 |
| SHA256SUMS | 全部文件的 sha256 与 CDHash |
| ${PATCH_NAME} | 对 1.2.4 的源码改动 |

## 安装（Filza / 终端）

1. **完全关闭** Virtual Mac（先正常关闭虚拟机）；
2. 把本目录拷到 iPad，在设备上于本目录执行（需要 root）：

       sh install-on-ipad.sh

脚本会备份原有文件到 app 包内 \`VirtualMac124Backup-时间戳\`，然后替换主二进制、
Info.plist、GuestTools 载荷与 37 个本地化文件，注册新 CDHash 并执行 \`uicache\`。

3. 从主屏幕重新启动 Virtual Mac。顶部三个点应消失；设置 → Touch 中应出现
   「触控板滚动速度」。
4. GuestTools 新载荷会在下次启动虚拟机时自动更新到 guest；如果没生效，在
   Virtual Mac 的菜单里执行一次 Guest Tools 安装。

**若三个点仍在**：重启一次 iPad（SpringBoard 需要重新读取场景声明）。

## 回滚

    sh install-on-ipad.sh restore

会把最近一次安装前的 VirtualMac、Info.plist、GuestTools 载荷与本地化文件还原。
若主二进制启动报 EAUTH，说明旧二进制需要重新注册 CDHash，重装原来的 deb 即可。

## 验证建议

- 全屏：顶部无三点；应用不能被拖成侧拉/分屏；
- 触控板：滚动跟随系统速度，设置里的「触控板滚动速度」0.1–1.0 生效，
  轻甩有惯性且主线程卡顿后动量会补齐；
- 确认没有意外带上的功能：设置里不应出现「锁定指针到显示画面」，锁屏行为
  应与 1.2.4 原生一致。
EOF

echo "=== 6/6 打包与发布 ==="
rm -f "$STAGE/$ZIP_NAME"
(cd "$STAGE" && zip -q -X "$ZIP_NAME" VirtualMac Info.plist \
    GuestTools/VirtualMacGuestTools.tar.gz Localizations \
    install-on-ipad.sh README.md SHA256SUMS "$PATCH_NAME")

SHARE_STAGE="$SHARE_DIR/VirtualMac-${RELEASE_VERSION}-${LABEL}"
if [[ -n "$SHARE_DIR" && -d "$SHARE_DIR" ]]; then
    if mkdir -p "$SHARE_STAGE" &&
        cp -p "$STAGE/VirtualMac" "$STAGE/Info.plist" \
            "$STAGE/install-on-ipad.sh" "$STAGE/README.md" \
            "$STAGE/SHA256SUMS" "$STAGE/$PATCH_NAME" "$STAGE/$ZIP_NAME" \
            "$SHARE_STAGE/" &&
        mkdir -p "$SHARE_STAGE/GuestTools" "$SHARE_STAGE/Localizations" &&
        cp -p "$STAGE/GuestTools/VirtualMacGuestTools.tar.gz" \
            "$SHARE_STAGE/GuestTools/" &&
        cp -R "$STAGE/Localizations/." "$SHARE_STAGE/Localizations/"; then
        echo "已发布到 $SHARE_STAGE"
    else
        echo "警告：无法写入 $SHARE_STAGE（共享盘只读或未挂载）" >&2
        echo "      请手动复制：$STAGE" >&2
    fi
else
    echo "共享盘未挂载；如需分发请手动复制 $STAGE"
fi

echo ""
echo "替换包：$STAGE"
echo "  $ZIP_NAME"
echo "  VirtualMac sha256=$main_sha cdhash=$main_cdhash"
echo "  GuestTools=$guesttools_size bytes"
