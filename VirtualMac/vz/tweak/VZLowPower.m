// VZLowPower — SpringBoard tweak（v3：日志改到数据分区；v2：延后初始化 + 不触碰 SpringBoard 内部对象）
//
// 行为：
//   锁屏   -> 若系统当前未处于低电量模式，则开启（并记为本 tweak 所开）
//   锁屏中 -> 每 ReassertSeconds 秒检查一次，若低电量模式已被系统关掉则重新开启
//   解锁   -> 只关闭本 tweak 开启的低电量模式；用户手动开启的保持不变
//
// 为什么需要"重申"：
//   iOS 会在充电到 80% 以上时自动退出低电量模式。初版只在锁屏那一刻设置一次，
//   于是插电过夜时低电量模式在 80% 之后失效，后台 App 刷新 / iCloud 备份 /
//   照片分析 / App 更新等夜间重任务放开跑，内存峰值把常驻 10 GiB 的虚拟机顶破
//   iOS 15 的 "user reclaimable >= 65%" 水位，触发 SystemMemoryReset（bug_type
//   301），VMM 与宿主 app 一起被清掉。周期性重申让低电量模式整夜有效。
//
// v2 相对 v1 的安全改动（v1 在设备上把 SpringBoard 弄进了 Safe Mode）：
//   1. 不再访问 SBLockScreenManager 等 SpringBoard 内部对象；锁屏判定只用
//      Darwin notify "com.apple.springboard.lockstate" + 受保护数据兜底。
//   2. 全部初始化推迟到 SpringBoard 完成启动之后（UIApplicationDidFinish-
//      LaunchingNotification，另有 3 秒兜底），避免在 dylib 构造阶段碰任何
//      还没就绪的东西。
//   3. 每个阶段先写日志再执行，崩溃时日志文件的最后一行就是现场
//      （路径见下方 VZLowPowerPersistentLogPath）。
//   4. 私有 API 调用外层加 @try/@catch（能挡住 ObjC 异常；信号级崩溃挡不住，
//      所以第 1、2 条才是关键）。
//
// 权限：系统低电量模式没有公开 API；越狱环境用 CoreDuet 的私有 _CDBatterySaver，
//   它需要与 CoreDuet 帮助程序通信，只有 SpringBoard（root）能成功。
//
// 偏好（域 com.mac.virtual.lowpower）：
//   Enabled          默认 YES   总开关
//   ReassertSeconds  默认 30    锁屏期间重申间隔（秒）；0 = 关闭重申（退化为初版）
//   HeartbeatSeconds 默认 1800  日志心跳间隔（秒）；0 = 关闭
//   Logging          默认 YES   是否写日志（数据分区，打不开时退回 /tmp）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <notify.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>

// SystemMemoryReset（bug_type 301）执行的是 userspace reboot，而它会清空 /tmp。
// 只写 /tmp 的日志因此恰好丢掉了它本该记录的那一夜：2026-10-10 那份日志第一行是
// 03:12:07，也就是 03:12:00 那次重置之后 7 秒，之前整晚的内容全部消失。
// 所以日志落到数据分区（不会被 userspace reboot 清掉），打不开时才退回 /tmp。
static const char *VZLowPowerPersistentLogPath =
    "/var/mobile/Library/Logs/VZLowPower.log";
static const char *VZLowPowerTemporaryLogPath = "/tmp/VZLowPower.log";
static const long long VZLowPowerDefaultReassertSeconds = 30;
static const long long VZLowPowerDefaultHeartbeatSeconds = 1800;
static const long long VZLowPowerStartDelaySeconds = 3;

static FILE *VZLowPowerOpenLog(void)
{
    FILE *file = fopen(VZLowPowerPersistentLogPath, "a");
    if (file)
        return file;
    return fopen(VZLowPowerTemporaryLogPath, "a");
}

static BOOL VZLowPowerPreferenceBool(CFStringRef key, BOOL fallback)
{
    Boolean valid = false;
    CFIndex value = CFPreferencesGetAppIntegerValue(
        key, CFSTR("com.mac.virtual.lowpower"), &valid);
    return valid ? (value != 0) : fallback;
}

static long long VZLowPowerPreferenceInt(CFStringRef key, long long fallback)
{
    Boolean valid = false;
    CFIndex value = CFPreferencesGetAppIntegerValue(
        key, CFSTR("com.mac.virtual.lowpower"), &valid);
    return valid ? (long long)value : fallback;
}

// 日志同时写文件与 stderr。文件用 fopen/fputs/fclose，写完立即落盘，
// 这样即使进程随后崩溃，最后一行依然留在盘上。
static void VZLowPowerLog(NSString *format, ...)
{
    if (!VZLowPowerPreferenceBool(CFSTR("Logging"), YES))
        return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);

    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &local);

    NSString *line = [[NSString alloc] initWithFormat:@"%s [VZLowPower] %@\n",
                                                stamp, message];
    FILE *file = VZLowPowerOpenLog();
    if (file) {
        fputs(line.UTF8String, file);
        fclose(file);
    }
    fputs(line.UTF8String, stderr);

    [line release];
    [message release];
}

static void VZLowPowerSetMode(BOOL enabled)
{
    static Class batterySaverClass;
    if (!batterySaverClass) {
        dlopen("/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet",
               RTLD_LAZY | RTLD_GLOBAL);
        batterySaverClass = objc_getClass("_CDBatterySaver");
    }
    if (!batterySaverClass ||
        ![batterySaverClass respondsToSelector:@selector(batterySaver)]) {
        VZLowPowerLog(@"_CDBatterySaver unavailable");
        return;
    }
    @try {
        id batterySaver = ((id(*)(id, SEL))objc_msgSend)(
            batterySaverClass, sel_registerName("batterySaver"));
        NSError *error = nil;
        ((BOOL(*)(id, SEL, long long, NSError **))objc_msgSend)(
            batterySaver, sel_registerName("setPowerMode:error:"),
            enabled ? 1 : 0, &error);
        if (error)
            VZLowPowerLog(@"set error: %@", error.localizedDescription);
    } @catch (NSException *exception) {
        VZLowPowerLog(@"set raised: %@", exception.reason);
    }
    VZLowPowerLog(@"set power mode=%d (system now=%d)",
                  enabled, NSProcessInfo.processInfo.lowPowerModeEnabled);
}

static BOOL gLowPowerForcedByUs;
static BOOL gProtectedDataUnavailable;
static int gLockStateToken = -1;
static dispatch_source_t gReassertTimer;
static double gLastHeartbeat;
static unsigned long gReassertCount;

// 只用 notify 状态（SpringBoard 锁屏时会 set state/post 通知）与受保护数据兜底，
// 不访问 SBLockScreenManager —— 这是 v1 进 Safe Mode 的最可疑原因。
static BOOL VZLowPowerDeviceIsLocked(void)
{
    if (gLockStateToken >= 0) {
        uint64_t state = 0;
        @try {
            if (notify_get_state(gLockStateToken, &state) == NOTIFY_STATUS_OK)
                return state != 0;
        } @catch (__unused NSException *exception) {
        }
    }
    return gProtectedDataUnavailable;
}

static void VZLowPowerEvaluate(const char *reason)
{
    if (!VZLowPowerPreferenceBool(CFSTR("Enabled"), YES))
        return;
    BOOL locked = VZLowPowerDeviceIsLocked();
    BOOL systemOn = NSProcessInfo.processInfo.lowPowerModeEnabled;
    if (locked) {
        if (!systemOn) {
            VZLowPowerSetMode(YES);
            gLowPowerForcedByUs = YES;
            gReassertCount++;
            if (gReassertCount > 1)
                VZLowPowerLog(@"reasserted low power mode (%s, count=%lu)",
                              reason, gReassertCount);
        }
    } else {
        // 只关我们自己开的；用户手动开启的保持不变。
        if (gLowPowerForcedByUs && systemOn) {
            VZLowPowerSetMode(NO);
            VZLowPowerLog(@"released low power mode on unlock (%s)", reason);
        }
        gLowPowerForcedByUs = NO;
        gReassertCount = 0;
    }
}

static void VZLowPowerHeartbeatIfDue(void)
{
    long long interval = VZLowPowerPreferenceInt(
        CFSTR("HeartbeatSeconds"), VZLowPowerDefaultHeartbeatSeconds);
    if (interval <= 0)
        return;
    double now = CFAbsoluteTimeGetCurrent();
    if (gLastHeartbeat != 0 && now - gLastHeartbeat < (double)interval)
        return;
    gLastHeartbeat = now;
    VZLowPowerLog(@"heartbeat locked=%d system-lowpower=%d forced=%d "
                  "reasserts=%lu",
                  VZLowPowerDeviceIsLocked(),
                  NSProcessInfo.processInfo.lowPowerModeEnabled,
                  gLowPowerForcedByUs, gReassertCount);
}

static void VZLowPowerStartReassertTimer(void)
{
    long long interval = VZLowPowerPreferenceInt(
        CFSTR("ReassertSeconds"), VZLowPowerDefaultReassertSeconds);
    if (interval <= 0) {
        VZLowPowerLog(@"reassert timer disabled (ReassertSeconds=%lld)",
                      interval);
        return;
    }
    uint64_t nanoseconds = (uint64_t)interval * NSEC_PER_SEC;
    gReassertTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gReassertTimer,
                              dispatch_time(DISPATCH_TIME_NOW, nanoseconds),
                              nanoseconds, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gReassertTimer, ^{
        VZLowPowerEvaluate("timer");
        VZLowPowerHeartbeatIfDue();
    });
    dispatch_resume(gReassertTimer);
    VZLowPowerLog(@"reassert timer started interval=%llds", interval);
}

// SpringBoard 完成启动后才真正开始工作。
static void VZLowPowerStart(void)
{
    VZLowPowerLog(@"stage 1: registering lock-state notify");
    int status = notify_register_dispatch(
        "com.apple.springboard.lockstate", &gLockStateToken,
        dispatch_get_main_queue(), ^(int token) {
            (void)token;
            VZLowPowerEvaluate("lockstate");
        });
    if (status != NOTIFY_STATUS_OK) {
        gLockStateToken = -1;
        VZLowPowerLog(@"lockstate notify unavailable status=%d", status);
    }

    VZLowPowerLog(@"stage 2: observing protected-data fallback");
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        (void)note;
        gProtectedDataUnavailable = YES;
        VZLowPowerEvaluate("protected-unavailable");
    }];
    [center addObserverForName:UIApplicationProtectedDataDidBecomeAvailable
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        (void)note;
        gProtectedDataUnavailable = NO;
        VZLowPowerEvaluate("protected-available");
    }];

    VZLowPowerLog(@"stage 3: starting reassert timer");
    VZLowPowerStartReassertTimer();

    VZLowPowerLog(@"stage 4: initial evaluation");
    VZLowPowerEvaluate("start");
    VZLowPowerLog(@"ready (locked=%d system-lowpower=%d)",
                  VZLowPowerDeviceIsLocked(),
                  NSProcessInfo.processInfo.lowPowerModeEnabled);
}

static void VZLowPowerScheduleStart(void)
{
    static BOOL started;
    if (started)
        return;
    started = YES;
    VZLowPowerStart();
}

__attribute__((constructor))
static void VZLowPowerInit(void)
{
    // 构造阶段只写一行日志：证明 dylib 被加载了；若崩溃发生在这行之后，
    // 日志文件里就看不到后续的 stage 行，可直接定位现场。
    VZLowPowerLog(@"loaded (v3; log=%@; enabled=%d reassert=%llds) waiting "
                  "for SpringBoard launch",
                  @(VZLowPowerPersistentLogPath),
                  VZLowPowerPreferenceBool(CFSTR("Enabled"), YES),
                  VZLowPowerPreferenceInt(CFSTR("ReassertSeconds"),
                                          VZLowPowerDefaultReassertSeconds));
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        (void)note;
        VZLowPowerScheduleStart();
    }];
    // 兜底：若启动通知早于本插件注入（不会再来），3 秒后照样开始。
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      VZLowPowerStartDelaySeconds * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            VZLowPowerScheduleStart();
        });
}
