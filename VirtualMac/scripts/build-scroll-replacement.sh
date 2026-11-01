#!/bin/bash

# Build the two host binaries that carry the scroll pipeline and package them
# as a drop-in replacement, mirroring the "VirtualMac-1.2-smooth2.zip" release
# layout: replacing VirtualMac and VZHostCompat.dylib inside an already
# installed VirtualMac.app is enough to test an input-path change without
# rebuilding or reinstalling the whole package.
#
# The binaries are still produced by build-ipad-app.sh so the compiler flags,
# the deployment target, and the entitlements stay identical to a normal build.
# The replacement changes each file's CDHash, so the package also records the
# new CDHashes and ships an on-device installer that registers them with the
# jailbreak's trust cache (Dopamine jbctl, Taurine jbexec).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command ldid
need_command shasum
need_command zip

RELEASE_VERSION="${VZ_RELEASE_VERSION:-1.2.3}"
# Label distinguishes experimental variants that have to coexist in the shared
# folder while a device test compares them.
LABEL="${VZ_SCROLL_LABEL:-scroll-coalescing}"
BUILD_COUNT="$(git -C "$VZ_REPO_ROOT" rev-list --count HEAD)"
BUILD_HASH="$(git -C "$VZ_REPO_ROOT" rev-parse --short=10 HEAD)"
RELEASE="${VZ_SCROLL_RELEASE_DIR:-$VZ_BUILD_ROOT/release}"
STAGE="$RELEASE/${LABEL}-replacement"
ZIP_NAME="VirtualMac-${RELEASE_VERSION}-${LABEL}.zip"
PATCH_NAME="VirtualMacOniPad-${RELEASE_VERSION}-${LABEL}.patch"

if [[ "${VZ_SKIP_REBUILD:-0}" != 1 ]]; then
    "$SCRIPT_DIR/build-ipad-app.sh"
fi

APP="$VZ_BUILD_ROOT/ipad-app/VirtualMac.app"
# Binaries can also be taken from an already packaged replacement. That is how a
# plist-only change is layered onto an older, already verified binary without
# rebuilding (and therefore without pulling in later source changes).
BINARY_SOURCE="${VZ_SCROLL_BINARY_SOURCE:-$APP}"
need_file "$BINARY_SOURCE/VirtualMac"
need_file "$BINARY_SOURCE/VZHostCompat.dylib"

rm -rf "$STAGE"
mkdir -p "$STAGE"

# ditto preserves the executable bit and the code signature.
ditto "$BINARY_SOURCE/VirtualMac" "$STAGE/VirtualMac"
ditto "$BINARY_SOURCE/VZHostCompat.dylib" "$STAGE/VZHostCompat.dylib"
xattr -c "$STAGE/VirtualMac" "$STAGE/VZHostCompat.dylib" 2>/dev/null || true

# Info.plist changes (UIRequiresFullScreen in particular) only take effect when
# the bundle's plist is replaced as well, so it has to travel with the binaries.
WITH_PLIST="${VZ_SCROLL_WITH_PLIST:-0}"
if [[ "$WITH_PLIST" == 1 ]]; then
    ditto "$APP/Info.plist" "$STAGE/Info.plist"
    xattr -c "$STAGE/Info.plist" 2>/dev/null || true
fi

main_cdhash="$(ldid -h "$STAGE/VirtualMac" | sed -n 's/^CDHash=//p')"
hook_cdhash="$(ldid -h "$STAGE/VZHostCompat.dylib" | sed -n 's/^CDHash=//p')"
[[ -n "$main_cdhash" && -n "$hook_cdhash" ]] ||
    die "could not read CDHashes from the replacement binaries"

# The replacement is meant to be reviewable: one patch with the complete
# source change next to the binaries it was built from.
if [[ -n "${VZ_SCROLL_PATCH_SOURCE:-}" ]]; then
    # A package assembled from an older binary carries that binary's own patch
    # plus the plist change layered on top, so the patch always matches the
    # binaries actually shipped here.
    cat "$VZ_SCROLL_PATCH_SOURCE" > "$STAGE/$PATCH_NAME"
    printf '\n' >> "$STAGE/$PATCH_NAME"
    git -C "$VZ_REPO_ROOT" diff -- vz/host/VirtualMac-Info.plist \
        >> "$STAGE/$PATCH_NAME"
else
    git -C "$VZ_REPO_ROOT" diff -- \
        vz/host/VirtualMacApp.m \
        vz/host/VZTrackpadScrollBridge.h \
        vz/host/VZTrackpadScrollBridge.m \
        vz/host/VZAppSettings.h \
        vz/host/VZAppSettings.m \
        vz/host/VZSettingsViewController.m \
        tests/test-scroll-bridge.m \
        resources/Localizations \
        > "$STAGE/$PATCH_NAME"
fi

cat > "$STAGE/SHA256SUMS" <<EOF
$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')  VirtualMac  cdhash=$main_cdhash
$(shasum -a 256 "$STAGE/VZHostCompat.dylib" | awk '{print $1}')  VZHostCompat.dylib  cdhash=$hook_cdhash
EOF

sed -e "s/@MAIN_CDHASH@/$main_cdhash/" \
    -e "s/@HOOK_CDHASH@/$hook_cdhash/" \
    "$SCRIPT_DIR/scroll-replacement-install.sh.in" \
    > "$STAGE/install-on-ipad.sh"
chmod 755 "$STAGE/install-on-ipad.sh"

{
cat <<EOF
# Virtual Mac ${RELEASE_VERSION} 滚动修复替换包

变体名称：${LABEL}

## 构建来源

- 提交：${BUILD_HASH}（build ${BUILD_COUNT}）
- 基线：上游 1.2.3 加上本分支已有的两个主机网络提交
- 源码改动：${PATCH_NAME}（可在仓库根目录执行 git apply 复现本包）
EOF
case "$LABEL" in
    device-deltas-speed*)
cat <<'EOF'

## 本包做了什么

**触控板使用设备自身增量与动量，加逐帧合流，再加触控板速度调节。**

1. 触控板直接使用 iPadOS 提供的 raw 与 acceleratedDelta，以及它自己的动量包，
   以 phase-less 事件注入 guest。这就是 1.2 scroll-fix 那条实测不卡的输入
   通路，速度天然跟随 iPadOS 的「指针控制 到 鼠标选项 到 滚动速度」。
2. 所有滚动来源统一经过逐帧合流器：guest 每帧最多收到一个滚动事件，而不是
   每个 HID 包一次 XPC（最高约 180 次/秒）。
3. 新增「触控板滚动速度」设置（设置 到 Touch 分区，范围 0.1 到 1.0，
   默认 0.5）：在系统速度之上再缩放 raw 与 accelerated 两个分量，1.0 等于
   不额外缩放。直接两指触摸仍由原有的 Scrolling Speed 控制，两者互不影响。

### 关于跟随系统设置

本变体本身就使用 iPadOS 计算好的加速增量，所以系统里的滚动速度已经生效，
应用内滑块是在它之上再乘一层。若希望完全交给系统，把滑块拉到 1.0 即可。
EOF
        ;;
    device-deltas)
cat <<'EOF'

## 本包做了什么

**触控板改回使用设备自身增量与动量（A/B 对照变体）。**

触控板不再经过 1.2.1 引入的 Mac 加速/动量桥，而是直接使用 iPadOS 提供的
acceleratedDelta 以及它自己的动量包，再经过逐帧合流限速。

这就是 1.2 scroll-fix 那条实测不卡的输入通路，用来把两类原因区分开：
注入速率问题，还是桥本身的加速曲线/合成动量/相位生命周期问题。
EOF
        ;;
    *)
cat <<'EOF'

## 本包做了什么

**逐帧合流 + 动量时间补偿。**

1. 触控板、直接触摸、Magic Mouse 的滚动输出全部接入与鼠标滚轮相同的逐帧
   合流器：guest 每帧最多收到一个滚动事件，而不是每个 HID 包一次 XPC
   （最高约 180 次/秒）。这正是 9db7ea0 为滚轮引入、ee8510f（1.2.1）在
   触控板上丢掉的那套机制。
2. 合成动量按真实流逝时间积分，而不是每次定时器触发固定衰减一步。
   用 tests/test-scroll-bridge.m 实测：主线程停顿 200 ms 时，旧实现只补发
   56 mickey，而正确积分是 528（差 9.3 倍），本构建补发 528。
3. 新增「触控板滚动速度」设置（设置 到 Touch 分区，范围 0.1 到 1.0，
   默认 0.5）。倍率只在注入层缩放位移：bridge 内部的速度估计、惯性触发
   阈值和动量积分仍使用设备原始 mickey 刻度，所以调慢之后轻甩依然会有
   惯性，1.0 等于未经修改的 Ventura 曲线。直接两指触摸仍由原有的
   Scrolling Speed 控制，两者互不影响。

### 关于跟随系统设置

妙控键盘的「指针控制 到 鼠标选项 到 滚动速度」只影响 iPadOS 自己的
acceleratedDelta，而本变体使用重构的 Ventura 曲线，所以目前不会自动跟随。
Debug Logging 打开后，VM 启动时会在日志里打印 system pointer pref 开头的
候选偏好键；确认键名之后即可把默认倍率绑定到系统设置。
EOF
        ;;
esac
if [[ "$WITH_PLIST" == 1 ]]; then
cat <<'EOF'

## 本包还包含 Info.plist（关闭 iPad 多任务 / 侧拉）

Info.plist 里声明了 `UIRequiresFullScreen`。在 iPadOS 18 及更早（包括 15.7），
这个键让应用退出 iPad 多任务：场景保持全屏、**不能进入 Split View，也不能被
拖成侧拉**，因此系统不再显示顶部的多任务三个点，误触也就不会发生。

- 纯应用层，不需要越狱 hook，不会影响指针手感；
- 安装脚本会替换 Info.plist 并执行 uicache，让系统重新读取；
- 若三点仍然出现，重启一次设备再试（SpringBoard 需要重新读取应用信息）。
EOF
    if grep -q UIBackgroundModes "$STAGE/Info.plist" 2>/dev/null; then
cat <<'EOF'

## 本包的 Info.plist 还声明了 UIBackgroundModes（锁屏后保持 VM 存活）

`UIBackgroundModes` 声明了 `audio`。应用本来就为麦克风透传持有一个活跃的
`AVAudioSessionCategoryPlayAndRecord` 会话，但**只有声明了 audio 后台模式，
活跃会话才能换来后台运行时间**；否则 iPad 一锁屏、应用进入后台就被挂起，而挂起
的应用会在内存压力下被系统回收。

VM 是设备上最大的内存占用者，因此它总是第一个被回收的目标——这正是"放置一晚、
屏幕关闭后虚拟机自己退出"的原因。

### 这一版要验证什么

这是本变体相对 `device-deltas-speed-fs` 的**唯一改动**：两个二进制与本包完全
一致（sha256 与 CDHash 都相同，因此不需要重新注册信任缓存），只多了 Info.plist
里的这一个键。

- **之前**：iPad 锁屏放置一晚，第二天回来虚拟机已经退出。
- **期望**：锁屏一晚后 VM 仍然存活。

验证步骤：

1. 装好后正常启动虚拟机；
2. 锁屏，放置一晚（建议保留"锁屏后开启省电模式"那条自动化，以便在**最不利
   条件**下测试）；
3. 第二天唤醒后，第一件事是确认虚拟机是否还在运行；
4. 无论结果如何都记录下面两条，用于和之前对比：

       last reboot | head -5     # 上一个会话若无 shutdown 记录 = 又是被强制终止
       uptime                    # guest 是否连续运行了整晚

注意：即使声明了后台模式，内存压力极大时 iOS 仍可能回收。这一版去掉的是
"锁屏即被挂起"这条路径，不是保证绝对不被回收。
EOF
    fi
fi
cat <<EOF

## 文件清单

| 文件 | 说明 |
| --- | --- |
| VirtualMac | 主机可执行文件（arm64，最低 iOS 14.5） |
| VZHostCompat.dylib | 主机兼容钩子（arm64e），应用启动时从自身包内 dlopen |
| install-on-ipad.sh | 在 iPad 上完成备份、替换与 CDHash 注册 |
| ${PATCH_NAME} | 本包对应的完整源码改动 |
| SHA256SUMS | 两个文件的 sha256 与需要注册的 CDHash |

## 安装（iPad）

1. 停止正在运行的虚拟机，回到虚拟机库界面。
2. 把本目录拷到 iPad，然后在 iPad 上执行：

       sh install-on-ipad.sh

脚本会做四件事：

- 把当前的两个二进制备份到应用包内 ScrollReplacementBackup-时间戳 目录；
- 用新 inode 覆盖安装（Taurine 会按 vnode 缓存签名状态，原地覆盖可能报 EAUTH）；
- 用 jbctl trustcache add（无根越狱）或 taurine jbexec 预检（有根越狱）注册新的 CDHash；
- 执行 uicache。脚本不会 respring。

两个包的 VZHostCompat.dylib 完全一致，只替换 VirtualMac 一个文件也可以。

## 回滚

把备份目录里的两个文件拷回应用包，并重新注册旧 CDHash；或者重装上一个 .deb。

## 在设备上验证

设置 到 Debug Logging 选 “On for Next Boot”，重启虚拟机，然后观察
/tmp/VirtualMac.log：

- input-rate scroll=/received=/peak= ：注入速率是否已被压到接近刷新率，
  而 received 仍然很高；
- input scroll=N raw=.. phase=.. momentum=.. ：动量包间隔应稳定在 16.7 ms
  左右，并且总是以 momentum=0x8 收尾；
- health state=1 frames=.. ：连续两次相减即可算出 guest 实际出帧率。

## 如果仍然卡顿

先确认这个变体是否比另一个变体好，再决定改哪里：

- device-deltas 变体不卡而 scroll-coalescing 卡：说明问题出在 1.2.1 引入的
  Mac 加速/动量桥，应按 device-deltas 的方向重做加速与动量。
- 两个变体都卡：说明主机输入通路可以排除，问题在 guest 内部的滚动与合成渲染，
  例如显示刷新率、Chromium 合成器的像素对齐等。
EOF
} > "$STAGE/README.md"

rm -f "$RELEASE/$ZIP_NAME"
archive_files=(VirtualMac VZHostCompat.dylib install-on-ipad.sh README.md
    SHA256SUMS)
[[ "$WITH_PLIST" == 1 ]] && archive_files+=(Info.plist)
( cd "$STAGE" && zip -q -X "$ZIP_NAME" "${archive_files[@]}" )

echo "滚动替换包已生成：$STAGE"
echo "  $ZIP_NAME"
echo "  $PATCH_NAME"
echo "  VirtualMac cdhash=$main_cdhash"
echo "  VZHostCompat.dylib cdhash=$hook_cdhash"

# Publish to the shared folder used to carry the replacement over to the iPad.
# The pairing lives in its own subdirectory so the previous known-good binaries
# that may already sit in the share are never overwritten. Sharing is skipped
# when VZ_SCROLL_SHARE_DIR is empty or the volume is not mounted.
SHARE_DIR="${VZ_SCROLL_SHARE_DIR:-/Volumes/My Shared Files/File Provider Storage/macOS 测试}"
if [[ -n "$SHARE_DIR" && -d "$SHARE_DIR" ]]; then
    SHARE_STAGE="$SHARE_DIR/${LABEL}-${RELEASE_VERSION}"
    publish_files=("$STAGE/VirtualMac" "$STAGE/VZHostCompat.dylib"
        "$STAGE/install-on-ipad.sh" "$STAGE/README.md" "$STAGE/SHA256SUMS"
        "$STAGE/$PATCH_NAME" "$STAGE/$ZIP_NAME")
    [[ "$WITH_PLIST" == 1 ]] && publish_files+=("$STAGE/Info.plist")
    if mkdir -p "$SHARE_STAGE" && cp -p "${publish_files[@]}" \
            "$SHARE_STAGE/"; then
        echo "已发布到 $SHARE_STAGE"
    else
        # 共享盘只读或未挂载时不应让一次成功的构建失败。
        echo "警告：无法写入 $SHARE_STAGE" >&2
        echo "      请手动复制 $STAGE" >&2
    fi
else
    echo "共享盘未挂载；如需分发请手动复制 $STAGE"
    echo "  （可用 VZ_SCROLL_SHARE_DIR 修改目标目录）"
fi
