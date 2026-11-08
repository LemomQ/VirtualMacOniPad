#!/bin/bash
# 在用户当前使用的 lock-screen-suspension-diag 1.2.3（锁屏抑制基线 + 诊断修复）
# 之上，补上"仅全屏、关闭 iPadOS 多任务顶部三个点"所需的 Info.plist 安装步骤。
#
# 为什么需要单独一个包：lock-screen-suspension-diag 的替换包只替换主二进制
# VirtualMac，从不替换 Info.plist；设备上 app bundle 里的 Info.plist 还是安装
# deb 时留下的，里面没有 UIRequiresFullScreen，所以 iPadOS 15.7 仍然把应用当作
# 支持多任务的 App，顶部一直有"全屏 / 分屏 / 侧拉"三个点。
#
# 本脚本不重新编译、也不改动主二进制：它复用 lock-screen-suspension-diag 包里
# 逐字节相同的 VirtualMac（sha256 与 cdhash 都有断言），只生成一份带全屏声明的
# Info.plist，并生成会在设备上"把该键合并进现有 Info.plist"的安装脚本。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command plutil
need_command shasum
need_command zip

RELEASE_VERSION="${VZ_RELEASE_VERSION:-1.2.3}"
LABEL="${VZ_LSS_FULLSCREEN_LABEL:-lock-screen-suspension-diag-fullscreen}"
RELEASE="${VZ_LSS_FULLSCREEN_RELEASE_DIR:-$VZ_BUILD_ROOT/release}"
STAGE="$RELEASE/${LABEL}-replacement"
ZIP_NAME="VirtualMac-${RELEASE_VERSION}-${LABEL}.zip"

# 用户当前使用的包：主二进制取自这里，保证与现在设备上运行的文件逐字节一致。
BASELINE_PKG="$RELEASE/lock-screen-suspension-diag-replacement"
# 该二进制对应的源码快照：Info.plist 模板取自这里。
BASELINE_SRC="$VZ_REPO_ROOT/build/lock-screen-suspension-src/VirtualMac"
INSTALL_TEMPLATE="$SCRIPT_DIR/lss-fullscreen-install.sh.in"

EXPECTED_BINARY_SHA="ec60ef70e6903b6f071c1e34cca6624f38b85ee82b292f040e5bcfc9ae1a607f"
EXPECTED_BINARY_SIZE="795024"
EXPECTED_CDHASH="260a31634a221a74aa1b04af2989b1b4ff9fdef2"
BUILD_HASH="6e240fbf3b"
BUILD_COUNT="57"

need_file "$BASELINE_PKG/VirtualMac"
need_file "$BASELINE_SRC/vz/host/VirtualMac-Info.plist"
need_file "$INSTALL_TEMPLATE"

echo "=== 1/5 校验当前版本的主二进制 ==="
binary_sha="$(shasum -a 256 "$BASELINE_PKG/VirtualMac" | awk '{print $1}')"
[[ "$binary_sha" == "$EXPECTED_BINARY_SHA" ]] ||
    die "主二进制 sha256 不符：期望 $EXPECTED_BINARY_SHA，实际 $binary_sha"
binary_size="$(wc -c <"$BASELINE_PKG/VirtualMac" | tr -d '[:space:]')"
[[ "$binary_size" == "$EXPECTED_BINARY_SIZE" ]] ||
    die "主二进制大小不符：期望 $EXPECTED_BINARY_SIZE，实际 $binary_size"

read_cdhash() {
    if command -v ldid >/dev/null 2>&1; then
        ldid -h "$1" | sed -n 's/^CDHash=//p'
    elif command -v codesign >/dev/null 2>&1; then
        codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'
    fi
}
main_cdhash="$(read_cdhash "$BASELINE_PKG/VirtualMac")"
[[ -n "$main_cdhash" ]] || die "无法读取主二进制 CDHash"
[[ "$main_cdhash" == "$EXPECTED_CDHASH" ]] ||
    die "CDHash 不符：期望 $EXPECTED_CDHASH，实际 $main_cdhash"

echo "=== 2/5 生成带全屏声明的 Info.plist ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$BASELINE_SRC/vz/host/VirtualMac-Info.plist" "$STAGE/Info.plist"
plutil -replace CFBundleShortVersionString -string "$RELEASE_VERSION" \
    "$STAGE/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_COUNT" "$STAGE/Info.plist"
plutil -replace MinimumOSVersion -string "$VZ_IPADOS_MIN_VERSION" \
    "$STAGE/Info.plist"
xattr -c "$STAGE/Info.plist" 2>/dev/null || true

# 这份 plist 只用作两件事：以二进制 plist 形式出现时的完整回退，以及人工核对。
# 主路径是安装脚本把同一个键合并进设备现有 Info.plist，不会覆盖其它键。
fullscreen_raw="$(plutil -extract UIRequiresFullScreen raw "$STAGE/Info.plist")"
case "$fullscreen_raw" in
    1 | true) ;;
    *) die "生成的 Info.plist 缺少 UIRequiresFullScreen=true（实际：$fullscreen_raw）" ;;
esac
[[ "$(plutil -extract UIBackgroundModes.0 raw "$STAGE/Info.plist")" == "audio" ]] ||
    die "生成的 Info.plist 缺少 UIBackgroundModes=audio（锁屏保活基线的键）"
plutil -lint "$STAGE/Info.plist" >/dev/null

echo "=== 3/5 放入与当前版本逐字节相同的主二进制 ==="
cp -p "$BASELINE_PKG/VirtualMac" "$STAGE/VirtualMac"
xattr -c "$STAGE/VirtualMac" 2>/dev/null || true
shipped_sha="$(shasum -a 256 "$STAGE/VirtualMac" | awk '{print $1}')"
[[ "$shipped_sha" == "$EXPECTED_BINARY_SHA" ]] ||
    die "复制后的主二进制 sha256 不符"

echo "=== 4/5 生成设备安装脚本与说明 ==="
sed -e "s/@MAIN_CDHASH@/$main_cdhash/" \
    -e "s/@EXPECTED_BINARY_SIZE@/$EXPECTED_BINARY_SIZE/" \
    "$INSTALL_TEMPLATE" > "$STAGE/install-on-ipad.sh"
chmod 755 "$STAGE/install-on-ipad.sh"

plist_sha="$(shasum -a 256 "$STAGE/Info.plist" | awk '{print $1}')"
cat > "$STAGE/SHA256SUMS" <<EOF
$shipped_sha  VirtualMac  cdhash=$main_cdhash
$plist_sha  Info.plist
EOF

cat > "$STAGE/README.md" <<EOF
# Virtual Mac ${RELEASE_VERSION} 关闭 iPadOS 多任务（顶部三个点）替换包

变体名称：\`${LABEL}\`

- 基础版本：锁屏抑制基线 + 诊断修复（\`lock-screen-suspension-diag\`，
  commit \`${BUILD_HASH}\`，build ${BUILD_COUNT}），也就是你现在使用的版本
- 主二进制：与 \`lock-screen-suspension-diag\` 包**逐字节相同**
  （sha256 \`${EXPECTED_BINARY_SHA}\`，cdhash \`${EXPECTED_CDHASH}\`）
- 本包唯一改动：把 \`Info.plist\` 中的 \`UIRequiresFullScreen\` **真正装到设备上**

## 为什么之前三个点还在

之前每一个替换包（包括当前的 \`lock-screen-suspension-diag\`）都只替换主二进制
\`VirtualMac\`，**从不替换 \`Info.plist\`**。设备上 app bundle 里的 Info.plist
还是安装 deb 时留下的，里面没有 \`UIRequiresFullScreen\`，所以 iPadOS 15.7 仍然
把这个应用当作"支持多任务"的 App，顶部一直显示全屏 / 分屏 / 侧拉三个点。

本包不改源码、不重新编译二进制，只补上安装 Info.plist 这一步：在设备**现有的**
Info.plist 里加入

    <key>UIRequiresFullScreen</key>
    <true/>

其余键（\`CFBundleVersion\`、\`UIBackgroundModes\`、URL scheme、图标、方向等）
全部原样保留，然后执行 \`uicache\`，让 SpringBoard 重新读取。

## 在 iPadOS 15.7 上的效果

- 应用固定全屏，不能拖成侧拉（Slide Over），也不能进入分屏（Split View）；
- 顶部不再出现三点菜单，避免误触；
- 纯应用层声明，不需要越狱 hook，不影响指针手感与虚拟机功能；
- 只增加一个 plist 键，不改动锁屏抑制、诊断、输入等任何已有逻辑。

## 文件清单

| 文件 | 说明 |
| --- | --- |
| VirtualMac | 主机可执行文件，与当前版本逐字节相同（仅在设备上的文件大小不符时才会替换） |
| Info.plist | 完整的全屏声明 plist，仅当设备上的 Info.plist 是二进制格式时用于整份回退 |
| install-on-ipad.sh | 在 iPad 上完成备份、合并 UIRequiresFullScreen、按需替换二进制、uicache |
| SHA256SUMS | sha256 与 CDHash |

## 安装（Filza / 终端，Dopamine 无根越狱或 Taurine 有根越狱均可）

1. **完全关闭** Virtual Mac（先正常关闭虚拟机），把本目录拷到 iPad；
2. 在设备上、于本目录执行：

       sh install-on-ipad.sh

脚本会：

- 把当前的 \`Info.plist\`（以及主二进制）备份到 app 包内
  \`LockScreenFullScreenBackup-时间戳\`；
- 把 \`UIRequiresFullScreen=true\` 合并进现有 Info.plist（其它键不动）；
- 主二进制大小与当前版本一致时**不替换**、也不需要重新注册 CDHash；
- 执行 \`uicache\`。

3. 从主屏幕重新启动 Virtual Mac。

**如果三个点仍然出现**：重启一次 iPad 再试（SpringBoard 需要重新读取应用信息）。

## 回滚

在设备上于本目录执行：

    sh install-on-ipad.sh restore

或手工把 \`LockScreenFullScreenBackup-时间戳/Info.plist\` 拷回 app 包。

## 核对是否生效

生效后：

- 顶部中央不再出现三点按钮；
- 在多任务界面里，这个应用不能再被拖成侧拉或分屏。

如果重启后仍未生效，说明设备上 app bundle 的 Info.plist 可能不在预期位置，
把 \`ls -l /var/jb/Applications/VirtualMac.app/Info.plist\` 的输出发回来即可。
EOF

echo "=== 5/5 打包与发布 ==="
rm -f "$RELEASE/$ZIP_NAME"
(
    cd "$STAGE"
    zip -q -X "$ZIP_NAME" VirtualMac Info.plist install-on-ipad.sh \
        README.md SHA256SUMS
)

# 发布到共享盘，供 iPad 的"文件"App 取用。共享盘只读/未挂载时不影响构建成功。
SHARE_DIR="${VZ_LSS_FULLSCREEN_SHARE_DIR:-/Volumes/My Shared Files/File Provider Storage/macOS 测试}"
SHARE_STAGE="$SHARE_DIR/${LABEL}-${RELEASE_VERSION}"
if [[ -n "$SHARE_DIR" && -d "$SHARE_DIR" ]]; then
    if mkdir -p "$SHARE_STAGE" &&
        cp -p "$STAGE/VirtualMac" "$STAGE/Info.plist" \
            "$STAGE/install-on-ipad.sh" "$STAGE/README.md" \
            "$STAGE/SHA256SUMS" "$STAGE/$ZIP_NAME" "$SHARE_STAGE/"; then
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
echo "  VirtualMac sha256=$shipped_sha cdhash=$main_cdhash（未改动）"
echo "  Info.plist sha256=$plist_sha（含 UIRequiresFullScreen=true）"
echo "  install-on-ipad.sh 会把该键合并进设备现有 Info.plist，不覆盖其它键。"
