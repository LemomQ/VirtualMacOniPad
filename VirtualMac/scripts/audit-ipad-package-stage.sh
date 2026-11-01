#!/bin/bash

set -euo pipefail

command -v nm >/dev/null || { echo "package audit failed: missing command: nm" >&2; exit 1; }

STAGE="${1:-}"
[[ -n "$STAGE" && -d "$STAGE" ]] || {
    echo "usage: $0 <deb-stage-directory>" >&2
    exit 2
}

RUNTIME="$STAGE/var/root/VirtualMac"
PAYLOAD="$RUNTIME/payload"
FRAMEWORKS="$PAYLOAD/Frameworks"
VMM="$PAYLOAD/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
VMM_IPADOS14="$VMM.ipados14"
VMM_IPADOS15="$VMM.ipados15"
VMM_IPADOS16="$VMM.ipados16"
INSTALL_FRAMEWORKS="$PAYLOAD/Installation.xpc/Contents/Frameworks"
INSTALL_EXECUTABLE="$PAYLOAD/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
VIDEO_TOOLBOX="$FRAMEWORKS/VideoToolbox.framework/VideoToolbox"
VIDEO_TOOLBOX15="$PAYLOAD/Compatibility/iPadOS15/VideoToolbox"
VIDEO_TOOLBOX14="$PAYLOAD/Compatibility/iPadOS14/VideoToolbox"

die() {
    echo "package audit failed: $*" >&2
    exit 1
}

for binary in \
    "$FRAMEWORKS/Hypervisor.framework/Hypervisor" \
    "$FRAMEWORKS/ParavirtualizedGraphics.framework/ParavirtualizedGraphics" \
    "$FRAMEWORKS/Virtualization.framework/Virtualization" \
    "$FRAMEWORKS/vmnet.framework/vmnet" \
    "$FRAMEWORKS/Netrb.framework/Netrb" \
    "$FRAMEWORKS/VideoToolbox.framework/VideoToolbox" \
    "$FRAMEWORKS/VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport" \
    "$FRAMEWORKS/MetalSerializer.framework/MetalSerializer" \
    "$FRAMEWORKS/MetalCompat.dylib" \
    "$FRAMEWORKS/LaunchServicesCompat.dylib" \
    "$FRAMEWORKS/Virtualization.framework/Resources/AVPBooter.vmapple2.bin" \
    "$VMM"; do
    [[ -f "$binary" ]] || die "missing runtime file: ${binary#"$STAGE/"}"
done

for variant in \
    "$VMM_IPADOS14" \
    "$VMM_IPADOS15" \
    "$VMM_IPADOS16" \
    "$INSTALL_EXECUTABLE.ipados14" \
    "$INSTALL_EXECUTABLE.ipados15" \
    "$INSTALL_EXECUTABLE.ipados15-auth" \
    "$INSTALL_EXECUTABLE.ipados16" \
    "$INSTALL_FRAMEWORKS/InstallationCompat.dylib.ipados14" \
    "$INSTALL_FRAMEWORKS/InstallationCompat.dylib.ipados15" \
    "$INSTALL_FRAMEWORKS/InstallationCompat.dylib.ipados16" \
    "$INSTALL_FRAMEWORKS/MobileDevice.framework/Versions/A/MobileDevice.ipados14" \
    "$INSTALL_FRAMEWORKS/MobileDevice.framework/Versions/A/MobileDevice.ipados15" \
    "$INSTALL_FRAMEWORKS/MobileDevice.framework/Versions/A/MobileDevice.ipados15-auth" \
    "$INSTALL_FRAMEWORKS/MobileDevice.framework/Versions/A/MobileDevice.ipados16"; do
    [[ -f "$variant" ]] || die "missing installation host variant: ${variant#"$STAGE/"}"
    [[ ! -L "$variant" ]] ||
        die "host variant must be an independent file: ${variant#"$STAGE/"}"
done

ROOTFUL_PRIVATE="$STAGE/var/root/VirtualMac/rootful"
ROOTFUL_BOOTSTRAP="$STAGE/var/root/VirtualMac/bootstrap-rootful"
COMMON_BOOTSTRAP="$STAGE/var/root/VirtualMac/bootstrap-common"
[[ -f "$ROOTFUL_BOOTSTRAP/usr/libexec/VirtualMac/bootpd" ]] ||
    die "missing private matching iPadOS 14 bootpd"
[[ -f "$ROOTFUL_PRIVATE/Library/LaunchDaemons/com.apple.bootpd.plist" ]] ||
    die "missing private iPadOS 14 bootpd job"
[[ -f "$ROOTFUL_PRIVATE/Library/LaunchDaemons/vzi.apple.bootpd-controller.plist" ]] ||
    die "missing iPadOS 14 private DHCP controller job"
[[ -x "$ROOTFUL_BOOTSTRAP/usr/libexec/VirtualMac/bootpd-controller.sh" ]] ||
    die "missing iPadOS 14 private DHCP controller"
for duplicate in \
    "$ROOTFUL_BOOTSTRAP/Applications/VirtualMac.app" \
    "$ROOTFUL_BOOTSTRAP/usr/bin/virtualmac-diagnostics" \
    "$ROOTFUL_BOOTSTRAP/usr/lib/TweakInject/VZKeyboardPassthrough.dylib" \
    "$ROOTFUL_BOOTSTRAP/usr/lib/VirtualMac/libmrc.dylib" \
    "$ROOTFUL_BOOTSTRAP/usr/sbin/VirtualMac/rtadvd"; do
    [[ ! -e "$duplicate" ]] ||
        die "rootful bootstrap duplicates universal payload: ${duplicate#"$STAGE/"}"
done
[[ "$(plutil -extract Label raw \
    "$ROOTFUL_PRIVATE/Library/LaunchDaemons/com.apple.bootpd.plist")" == \
    vzi.apple.bootpd ]] || die "iPadOS 14 bootpd must use a private label"
[[ "$(plutil -extract Program raw \
    "$ROOTFUL_PRIVATE/Library/LaunchDaemons/com.apple.bootpd.plist")" == \
    /usr/libexec/VirtualMac/bootpd ]] ||
    die "iPadOS 14 bootpd must use a private path"
[[ "$(plutil -extract Disabled raw \
    "$ROOTFUL_PRIVATE/Library/LaunchDaemons/com.apple.bootpd.plist")" == \
    true ]] || die "iPadOS 14 bootpd must install disabled until configured"
for forbidden in \
    "$STAGE/usr/libexec/bootpd" \
    "$STAGE/var/root/VirtualMac/bootstrap-rootful/usr/libexec/bootpd" \
    "$STAGE/var/root/VirtualMac/bootstrap-rootful/Library/LaunchDaemons/com.apple.bootpd.plist"; do
    [[ ! -e "$forbidden" ]] ||
        die "package must not stage an Apple system-path replacement: $forbidden"
done

for variant in \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados14" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados15" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados16" \
    "$STAGE/var/jb/usr/lib/IOKit14Compat.dylib"; do
    [[ -f "$variant" ]] || die "missing network host variant: ${variant#"$STAGE/"}"
    [[ ! -L "$variant" ]] ||
        die "network host variant must be an independent file: ${variant#"$STAGE/"}"
done
[[ -f "$STAGE/var/jb/usr/lib/libmrc.ipados15-auth.dylib" ]] ||
    die "missing authenticated iPadOS 15 libmrc variant"
[[ -f "$STAGE/var/jb/usr/lib/NetworkMemoryPolicy.dylib" ]] ||
    die "missing network memory policy"
for executable in \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados14" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados15" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados16" \
    "$STAGE/var/jb/usr/libexec/bootpd"; do
    otool -L "$executable" | grep -Fq \
        @loader_path/../lib/NetworkMemoryPolicy.dylib ||
        die "network helper is missing memory policy: ${executable#"$STAGE/"}"
done
for executable in \
    "$ROOTFUL_BOOTSTRAP/usr/libexec/VirtualMac/InternetSharing.ipados14" \
    "$ROOTFUL_BOOTSTRAP/usr/libexec/VirtualMac/bootpd"; do
    otool -L "$executable" | grep -Fq \
        /usr/lib/VirtualMac/NetworkMemoryPolicy.dylib ||
        die "rootful helper is missing memory policy: ${executable#"$STAGE/"}"
done

for name in Hypervisor ParavirtualizedGraphics Virtualization MetalSerializer \
    VideoToolbox DiskImages2; do
    [[ -f "$PAYLOAD/Compatibility/iPadOS14/$name" ]] ||
        die "missing iPadOS 14 framework variant: $name"
    [[ ! -L "$PAYLOAD/Compatibility/iPadOS14/$name" ]] ||
        die "iPadOS 14 framework variant must be an independent file: $name"
    [[ -f "$PAYLOAD/Compatibility/iPadOS15/$name" ]] ||
        die "missing iPadOS 15 framework variant: $name"
    [[ ! -L "$PAYLOAD/Compatibility/iPadOS15/$name" ]] ||
        die "iPadOS 15 framework variant must be an independent file: $name"
    [[ -f "$PAYLOAD/Compatibility/iPadOS15Authenticated/$name" ]] ||
        die "missing authenticated iPadOS 15 framework variant: $name"
    [[ ! -L "$PAYLOAD/Compatibility/iPadOS15Authenticated/$name" ]] ||
        die "authenticated iPadOS 15 framework variant must be an independent file: $name"
done
[[ -f "$PAYLOAD/Compatibility/iPadOS14/HypervisorBigSur" ]] ||
    die "missing iPadOS 14 Big Sur Hypervisor implementation"
[[ -f "$PAYLOAD/Compatibility/iPadOS14/LibSystemCompat.dylib" ]] ||
    die "missing iPadOS 14 libSystem compatibility variant"
[[ -f "$FRAMEWORKS/LibCxx.dylib" ]] ||
    die "missing iPadOS 14 Ventura libc++ compatibility variant"
[[ -f "$FRAMEWORKS/ParavirtualizedGraphics.framework/Resources/default.ipados14.metallib" ]] ||
    die "missing iPadOS 14 Metal library"

# Compatibility artifacts may coexist in the package, but the established
# iPadOS 16 executable must remain byte-for-byte equal to the normal staged
# executable and must retain system dependencies. Only the postinst-selected
# iPadOS 15 VMM may reference the bundled legacy shims.
cmp -s "$VMM" "$VMM_IPADOS16" ||
    die "normal VMM differs from its preserved iPadOS 16 variant"
for dependency in \
    '@loader_path/../../../Frameworks/DiskImages2.framework/DiskImages2' \
    '@loader_path/../../../Frameworks/LibSystem15Compat.dylib' \
    '@loader_path/../../../Frameworks/IOKit15Compat.dylib'; do
    otool -L "$VMM_IPADOS16" | grep -Fq "$dependency" &&
        die "iPadOS 15 compatibility dependency leaked into iPadOS 16 VMM: $dependency"
    otool -L "$VMM_IPADOS15" | grep -Fq "$dependency" ||
        die "iPadOS 15 VMM is missing compatibility dependency: $dependency"
done

# VideoToolbox is deliberately three-way isolated. iPadOS 16 retains the
# system support-framework dependency. The 15.x compatibility image uses the
# bundled support framework, while only 14.x receives a private dylib identity
# to prevent old dyld from coalescing it with iPadOS's VideoToolbox.
system_vt_support='/System/Library/PrivateFrameworks/VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport'
bundled_vt_support='@loader_path/../VideoToolboxParavirtualizationSupport.framework/VideoToolboxParavirtualizationSupport'
otool -L "$VIDEO_TOOLBOX" | grep -Fq "$system_vt_support" ||
    die "iPadOS 16 VideoToolbox no longer uses its proven system support framework"
otool -L "$VIDEO_TOOLBOX" | grep -Fq "$bundled_vt_support" &&
    die "legacy VideoToolbox dependency leaked into iPadOS 16"
for legacy_vt in "$VIDEO_TOOLBOX15" "$VIDEO_TOOLBOX14"; do
    otool -L "$legacy_vt" | grep -Fq "$bundled_vt_support" ||
        die "legacy VideoToolbox is missing bundled support dependency: $legacy_vt"
done
otool -D "$VIDEO_TOOLBOX15" | grep -Fq \
    '/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox' ||
    die "iPadOS 15 VideoToolbox identity was unexpectedly changed"
otool -D "$VIDEO_TOOLBOX14" | grep -Fq '@rpath/VirtualMacVideoToolbox' ||
    die "iPadOS 14 VideoToolbox is missing its private dyld identity"
# The private identity alone is insufficient on iPadOS 14: dyld may still
# satisfy a weak VMM import from its shared cache. Verify the host endpoint is
# a required load command in 14.x and remains weak in the newer variants.
video_toolbox_dependency='@loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox'
load_command_for_dependency() {
    otool -l "$1" | awk -v dependency="$video_toolbox_dependency" '
        /cmd LC_LOAD(_WEAK)?_DYLIB/ { command=$2 }
        $1 == "name" && $2 == dependency { print command; exit }
    '
}
[[ "$(load_command_for_dependency "$VMM_IPADOS14")" == "LC_LOAD_DYLIB" ]] ||
    die "iPadOS 14 VMM does not strongly load its private VideoToolbox endpoint"
for newer_vmm in "$VMM_IPADOS15" "$VMM_IPADOS16"; do
    [[ "$(load_command_for_dependency "$newer_vmm")" == "LC_LOAD_WEAK_DYLIB" ]] ||
        die "iPadOS 14 VideoToolbox load policy leaked into $newer_vmm"
done
# Our Hypervisor adaptation is runtime-selected from the common hook. Only the
# iPadOS 14 vmnet checksum adapter remains a separately compiled hot path.
HOOK="$FRAMEWORKS/LaunchServicesCompat.dylib"
HOOK14="$FRAMEWORKS/LaunchServicesCompat.dylib.ipados14"
[[ ! -e "$FRAMEWORKS/LaunchServicesCompat.dylib.ipados15" ]] ||
    die "redundant iPadOS 15 VMM hook variant is still packaged"
nm -u "$HOOK" | grep -Eq '(_vmnet_write|_vmnet_start_interface)$' &&
    die "iPadOS 14 vmnet interposition leaked into the iPadOS 15/16 hook"
nm -u "$HOOK14" | grep -Eq '(_vmnet_write|_vmnet_start_interface)$' ||
    die "iPadOS 14 hook is missing its private vmnet interposition"
nm -u "$HOOK" | grep -Eq '_hv_vm_config_set_ipa_size$' ||
    die "common hook is missing runtime Hypervisor adaptation"
nm -u "$HOOK14" | grep -Eq '_hv_vm_config_set_ipa_size$' ||
    die "iPadOS 14 hook is missing runtime Hypervisor adaptation"
for dependency in \
    '@loader_path/../../../Frameworks/LibSystem14' \
    '@loader_path/../../../Frameworks/LibCxx.dylib'; do
    otool -L "$VMM_IPADOS14" | grep -Fq "$dependency" ||
        die "iPadOS 14 VMM is missing compatibility dependency: $dependency"
    otool -L "$VMM_IPADOS15" | grep -Fq "$dependency" &&
        die "iPadOS 14 dependency leaked into iPadOS 15 VMM: $dependency"
    otool -L "$VMM_IPADOS16" | grep -Fq "$dependency" &&
        die "iPadOS 14 dependency leaked into iPadOS 16 VMM: $dependency"
done

[[ ! -e "$PAYLOAD/VirtualMachine.xpc/Contents/Frameworks" ]] ||
    die "VirtualMachine.xpc contains a second framework tree"
[[ ! -e "$PAYLOAD/AVPBooter.vmapple2.bin" ]] ||
    die "AVPBooter duplicates the Virtualization framework resource"

for development_file in \
    "$PAYLOAD/bin" \
    "$PAYLOAD/trustcache.txt" \
    "$RUNTIME/install/restore-image-probe" \
    "$RUNTIME/install/usb-bridge-probe" \
    "$STAGE/var/jb/usr/share/VirtualMac/VM-LIBRARY-README.md"; do
    [[ ! -e "$development_file" ]] ||
        die "development-only file was packaged: ${development_file#"$STAGE/"}"
done

[[ ! -e "$STAGE/var/jb/Library/MobileSubstrate" ]] ||
    die "package must not duplicate ElleKit's MobileSubstrate compatibility path"
for extension in dylib plist; do
    tweak_path="$COMMON_BOOTSTRAP/usr/lib/TweakInject/VZKeyboardPassthrough.$extension"
    [[ -f "$tweak_path" && ! -L "$tweak_path" ]] ||
        die "SpringBoard tweak is missing from its upgrade-safe staging path"
done
[[ ! -e "$STAGE/var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.dylib" ]] ||
    die "SpringBoard tweak must be installed by postinst after legacy cleanup"

metadata="$(find "$STAGE" -type f \( -name .DS_Store -o -name '._*' \) -print -quit)"
[[ -z "$metadata" ]] || die "host metadata was packaged: ${metadata#"$STAGE/"}"
extended_attribute="$(xattr -lr "$STAGE" 2>/dev/null | head -1)"
[[ -z "$extended_attribute" ]] ||
    die "extended attribute was packaged: $extended_attribute"
bridge_support="$(find "$FRAMEWORKS" -type d -name BridgeSupport -print -quit)"
[[ -z "$bridge_support" ]] ||
    die "developer-only BridgeSupport metadata was packaged: ${bridge_support#"$STAGE/"}"

broken_link="$(find -L "$STAGE" -type l -print -quit)"
[[ -z "$broken_link" ]] || die "broken symlink: ${broken_link#"$STAGE/"}"

unexpected_framework=""
while IFS= read -r framework; do
    case "$framework" in
        "$FRAMEWORKS"/*|"$PAYLOAD/Installation.xpc/Contents/Frameworks"/*) ;;
        *) unexpected_framework="$framework"; break ;;
    esac
done < <(find "$PAYLOAD" -type d -name '*.framework' -print)
[[ -z "$unexpected_framework" ]] ||
    die "framework outside an authoritative dependency directory: ${unexpected_framework#"$STAGE/"}"

if otool -L "$VMM" | grep -Fq '@loader_path/../Frameworks/'; then
    die "VMM still references its removed nested framework directory"
fi
for dependency in \
    '@loader_path/../../../Frameworks/Hypervisor.framework/Hypervisor' \
    '@loader_path/../../../Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics' \
    '@loader_path/../../../Frameworks/MetalCompat.dylib' \
    '@loader_path/../../../Frameworks/LaunchServicesCompat.dylib' \
    '@loader_path/../../../Frameworks/vmnet.framework/vmnet' \
    '@loader_path/../../../Frameworks/VideoToolbox.framework/VideoToolbox'; do
    otool -L "$VMM" | grep -Fq "$dependency" ||
        die "VMM is missing shared dependency: $dependency"
done

echo "package stage audit passed: one shared VM framework tree, XPC installs dependencies only"
