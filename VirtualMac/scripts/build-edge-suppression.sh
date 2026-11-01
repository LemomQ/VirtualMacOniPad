#!/bin/bash

# Package the SpringBoard-side system-UI suppression work: the injected tweak
# plus the host app binaries it is meant to be used with.
#
# The tweak is what suppresses the iPadOS Dock revealed by pointer rest on the
# bottom edge and the top multitasking affordance; both are pointer-driven
# system UI, so they cannot be handled by the app's own
# preferredScreenEdgesDeferringSystemGestures. Installing it requires replacing
# the injected dylib and respringing SpringBoard, so the package also registers
# the new CDHashes and ships an on-device installer.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command ldid
need_command shasum
need_command zip
need_command ditto

RELEASE_VERSION="${VZ_RELEASE_VERSION:-1.2.3}"
LABEL="${VZ_SCROLL_LABEL:-edgetweak}"
BUILD_COUNT="$(git -C "$VZ_REPO_ROOT" rev-list --count HEAD)"
BUILD_HASH="$(git -C "$VZ_REPO_ROOT" rev-parse --short=10 HEAD)"
RELEASE="${VZ_SCROLL_RELEASE_DIR:-$VZ_BUILD_ROOT/release}"
STAGE="$RELEASE/${LABEL}-replacement"
ZIP_NAME="VirtualMac-${RELEASE_VERSION}-${LABEL}.zip"
PATCH_NAME="VirtualMacOniPad-${RELEASE_VERSION}-${LABEL}.patch"

if [[ "${VZ_SKIP_REBUILD:-0}" != 1 ]]; then
    "$SCRIPT_DIR/build-ipad-app.sh"
    "$SCRIPT_DIR/build-springboard-tweak.sh"
fi

APP="$VZ_BUILD_ROOT/ipad-app/VirtualMac.app"
TWEAK="$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.dylib"
need_file "$APP/VirtualMac"
need_file "$APP/VZHostCompat.dylib"
need_file "$TWEAK"

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP/VirtualMac" "$STAGE/VirtualMac"
ditto "$APP/VZHostCompat.dylib" "$STAGE/VZHostCompat.dylib"
ditto "$TWEAK" "$STAGE/VZKeyboardPassthrough.dylib"
xattr -c "$STAGE"/* 2>/dev/null || true

app_cdhash="$(ldid -h "$STAGE/VirtualMac" | sed -n 's/^CDHash=//p')"
hook_cdhash="$(ldid -h "$STAGE/VZHostCompat.dylib" | sed -n 's/^CDHash=//p')"
tweak_cdhash="$(ldid -h "$STAGE/VZKeyboardPassthrough.dylib" | sed -n 's/^CDHash=//p')"
[[ -n "$app_cdhash" && -n "$hook_cdhash" && -n "$tweak_cdhash" ]] ||
    die "could not read CDHashes from the packaged binaries"

# Full working-tree diff, so the package can reproduce the exact tree it was
# built from (including the earlier scroll work it depends on).
git -C "$VZ_REPO_ROOT" diff > "$STAGE/$PATCH_NAME"

cat > "$STAGE/SHA256SUMS" <<EOF
$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')  VirtualMac  cdhash=$app_cdhash
$(shasum -a 256 "$STAGE/VZHostCompat.dylib" | awk '{print $1}')  VZHostCompat.dylib  cdhash=$hook_cdhash
$(shasum -a 256 "$STAGE/VZKeyboardPassthrough.dylib" | awk '{print $1}')  VZKeyboardPassthrough.dylib  cdhash=$tweak_cdhash
EOF

sed -e "s/@MAIN_CDHASH@/$app_cdhash/" \
    -e "s/@HOOK_CDHASH@/$hook_cdhash/" \
    -e "s/@TWEAK_CDHASH@/$tweak_cdhash/" \
    "$SCRIPT_DIR/edge-suppression-install.sh.in" \
    > "$STAGE/install-on-ipad.sh"
chmod 755 "$STAGE/install-on-ipad.sh"

cat > "$STAGE/README.md" <<EOF
# Virtual Mac 边缘系统 UI 抑制包（${LABEL}）

## 构建来源

- 提交：${BUILD_HASH}（build ${BUILD_COUNT}）
- 源码改动：${PATCH_NAME}

## 这解决什么

iPadOS 有两处**指针驱动**的系统 UI，应用层 API 管不到它们：

1. 指针停在屏幕**最底部**时唤起 iPadOS 的 Dock，会把 guest 画面顶走；
2. 指针到**最顶部**时出现多任务指示器（三个点），容易误触。

它们不是手势，所以 preferredScreenEdgesDeferringSystemGestures 与
SBSystemGestureManager 都覆盖不到，必须在 SpringBoard 呈现它们的地方抑制。
本包扩展了已注入 SpringBoard 的 VZKeyboardPassthrough tweak：

- Dock：拦截 SBDockView 的 setHidden: 与 setAlpha:；
- 顶部指示器：拦截多任务指示器候选类的 setHidden:；
- 两者都**只在 Virtual Mac 前台且虚拟机运行时**生效，退出应用后恢复；
- 同时按设置里的两个开关放行：SystemGestureSuppression（Dock）、
  MultitaskingGestureSuppression（顶部指示器）。默认都是关的，
  装上后请到 设置 → Input 打开你要抑制的那一项。

## 一次性探测

私有类名在不同 iPadOS 版本上会变。tweak 会在虚拟机首次成为前台时，
把 SpringBoard 的真实视图树与相关类名写进
/tmp/vz-springboard-shortcuts.log（标记文件 /tmp/vz-system-ui-probe.done，
安装脚本每次都会删掉它，所以重装即可重新探测）。
这个日志现在已经包含在应用的诊断收集里。

## 文件

| 文件 | 说明 |
| --- | --- |
| VZKeyboardPassthrough.dylib | 注入 SpringBoard 的 tweak（arm64e） |
| VirtualMac | 主机可执行文件（含 tweak 日志的诊断收集） |
| VZHostCompat.dylib | 主机兼容钩子（arm64e） |
| install-on-ipad.sh | 安装并 respring |
| ${PATCH_NAME} | 完整源码改动 |
| SHA256SUMS | 三个文件的 sha256 与 CDHash |

## 安装

把本目录拷到 iPad，执行：

    sh install-on-ipad.sh

脚本会备份原有文件、替换两个 tweak 路径下的 dylib 与应用二进制、注册三个
CDHash、删除探测标记，最后 respring SpringBoard。若是无根越狱，重启后请从
主屏幕启动一次 Virtual Mac，并到设置里打开对应的抑制开关。

## 回滚

脚本会把原文件备份到应用包内的 EdgeSuppressionBackup-时间戳 目录，
以及 /var/jb/Library/MobileSubstrate/DynamicLibraries 下的同名 .bak 文件；
拷回后 respring 即可。
EOF

rm -f "$RELEASE/$ZIP_NAME"
( cd "$STAGE" && zip -q -X "$ZIP_NAME" \
    VirtualMac VZHostCompat.dylib VZKeyboardPassthrough.dylib \
    install-on-ipad.sh README.md SHA256SUMS )

echo "边缘抑制包已生成：$STAGE"
echo "  $ZIP_NAME"
echo "  VirtualMac cdhash=$app_cdhash"
echo "  VZKeyboardPassthrough.dylib cdhash=$tweak_cdhash"

SHARE_DIR="${VZ_SCROLL_SHARE_DIR:-/Volumes/My Shared Files/File Provider Storage/macOS 测试}"
if [[ -n "$SHARE_DIR" && -d "$SHARE_DIR" ]]; then
    SHARE_STAGE="$SHARE_DIR/${LABEL}-${RELEASE_VERSION}"
    if mkdir -p "$SHARE_STAGE" && cp -p "$STAGE"/* "$SHARE_STAGE/"; then
        echo "已发布到 $SHARE_STAGE"
    else
        echo "警告：无法写入 $SHARE_STAGE" >&2
        echo "      请手动复制 $STAGE" >&2
    fi
else
    echo "共享盘未挂载；如需分发请手动复制 $STAGE"
fi
