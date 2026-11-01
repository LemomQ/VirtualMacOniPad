#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static IMP gOriginalKeyCommands;
static IMP gOriginalApplicationKeyCommands;
static IMP gOriginalHandleKeyHIDEvent;
static IMP gOriginalHandleKeyUIEvent;
static IMP gOriginalShouldEnableSystemGesture;
static IMP gOriginalShouldEnableSystemGesturePrivate;
static IMP gOriginalFluidGestureShouldBegin;
static IMP gOriginalFluidGestureShouldReceiveTouch;
static BOOL gCommandIsDown;
static BOOL gSpringBoardReady;
static BOOL gGlobeIsDown;
// Globe+<key> chords in flight, keyed by the source HID usage (< 0x100). A
// nonzero value is the translated target HID usage. Recorded on the chord
// down so the release and any repeats keep routing to the target even after
// the globe itself is released first — otherwise the guest would get the
// translated key-down and then the raw key-up and end up with a stuck key.
static uint8_t gGlobeChordTargets[256];
static uint64_t gRelayingShortcutUsages;
static const char *gTargetBundleID = "com.mac.virtual";
static const char *gOpenAfterRespring =
    "/tmp/virtual-mac-open-after-respring";
static const char *gVMActiveMarker = "/tmp/virtual-mac-vm-active";
static NSString * const gSettingsPath = @"/var/mobile/Media/VirtualMac/Settings.plist";
static NSDictionary *gSettings;

static BOOL VZSettingEnabled(NSString *key)
{
    id value = gSettings[key];
    if ([value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSString.class])
        return [value boolValue];
    // Match the app's defaults exactly. Shortcut capture is the only
    // SpringBoard behavior enabled until the user opts in; edge and
    // multitasking gesture suppression remain off.
    return [key isEqualToString:@"KeyboardShortcutCapture"];
}

static void VZReloadSettings(void)
{
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:gSettingsPath];
    [gSettings release];
    gSettings = [[settings isKindOfClass:NSDictionary.class] ? settings : @{} retain];
}

static void VZSettingsChanged(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo)
{
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    VZReloadSettings();
}

// IOHIDEventTypeKeyboard is 3. Keyboard fields occupy its 0x30000 field
// namespace: usage page, usage, down, and repeat, in that order. These SPI
// constants are stable across the iPadOS releases supported by this project,
// but are kept local so the tweak builds with an unmodified public SDK.
enum {
    VZHIDKeyboardUsagePageField = 0x30000,
    VZHIDKeyboardUsageField = 0x30001,
    VZHIDKeyboardDownField = 0x30002,
};

typedef int64_t (*VZIOHIDEventGetIntegerValue)(CFTypeRef, uint32_t);

static void Log(const char *message)
{
    FILE *file = fopen("/tmp/vz-springboard-shortcuts.log", "a");
    if (!file)
        return;
    fprintf(file, "%s\n", message);
    fclose(file);
}

static void DebugLog(const char *message)
{
    if (VZSettingEnabled(@"DebugLogging"))
        Log(message);
}

// Formatted variant for the view-tree probe, which has to print class names and
// frames that cannot be built with a plain C string.
static void LogFormat(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format
                                            arguments:arguments];
    va_end(arguments);
    Log(line.UTF8String);
    [line release];
}

static BOOL VirtualMacIsFrontmost(id springBoard)
{
    // _accessibilityFrontMostApplication builds SpringBoard's app-switcher
    // controller tree behind +[SBMainSwitcherControllerCoordinator
    // sharedInstance]. Calling it from a swizzled gesture hook while
    // SpringBoard is still bootstrapping re-entrantly forces
    // SBApplicationController to construct before its restriction data source
    // exists; SBApplicationRestrictionController then asserts and the
    // exception escaping dispatch_once aborts SpringBoard (SIGABRT). Keep the
    // lookup disabled until SpringBoard reports a finished launch.
    if (!gSpringBoardReady) {
        static unsigned char logged;
        if (!logged) {
            Log("deferred frontmost check; SpringBoard still bootstrapping");
            logged = 1;
        }
        return NO;
    }
    SEL frontSelector = sel_registerName("_accessibilityFrontMostApplication");
    if (![springBoard respondsToSelector:frontSelector])
        return NO;
    @try {
        id application = ((id (*)(id, SEL))objc_msgSend)(
            springBoard, frontSelector);
        SEL bundleSelector = sel_registerName("bundleIdentifier");
        if (![application respondsToSelector:bundleSelector])
            return NO;
        NSString *bundleIdentifier = ((id (*)(id, SEL))objc_msgSend)(
            application, bundleSelector);
        return [bundleIdentifier isEqualToString:
            [NSString stringWithUTF8String:gTargetBundleID]];
    } @catch (NSException *exception) {
        Log("frontmost application lookup raised; leaving system input enabled");
        return NO;
    }
}

static BOOL VirtualMacVMIsActive(id springBoard)
{
    if (access(gVMActiveMarker, F_OK) != 0 ||
        !VirtualMacIsFrontmost(springBoard))
        return NO;
    // While the display is asleep, SpringBoard can continue reporting the VM
    // app as frontmost. Suppressing every system gesture in that state also
    // suppresses iPadOS 16.1's tap-to-wake recognizer. The lock screen must
    // always retain its native input path.
    Class lockClass = objc_getClass("SBLockScreenManager");
    id lockManager = lockClass ? ((id (*)(id, SEL))objc_msgSend)(
        lockClass, sel_registerName("sharedInstance")) : nil;
    if (lockManager && [lockManager respondsToSelector:
            sel_registerName("isUILocked")] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(
            lockManager, sel_registerName("isUILocked")))
        return NO;
    return YES;
}

static BOOL VZSharedApplicationIsTarget(void)
{
    id application = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
    return application && VirtualMacVMIsActive(application);
}

static BOOL VZShouldEnableSystemGesture(id self, SEL selector,
                                        unsigned long long type)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"SystemGestureSuppression")) {
        static unsigned long count;
        if (count++ < 12)
            Log("suppressed an iPadOS system gesture for frontmost Virtual Mac");
        return NO;
    }
    IMP original = selector == sel_registerName("_shouldEnableSystemGestureWithType:")
        ? gOriginalShouldEnableSystemGesturePrivate
        : gOriginalShouldEnableSystemGesture;
    return ((BOOL (*)(id, SEL, unsigned long long))original)(
        self, selector, type);
}

static BOOL VZFluidGestureShouldBegin(id self, SEL selector, id recognizer)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"MultitaskingGestureSuppression")) {
        static unsigned long count;
        if (count++ < 12)
            Log("suppressed a fluid multitasking gesture for active VM display");
        return NO;
    }
    return ((BOOL (*)(id, SEL, id))gOriginalFluidGestureShouldBegin)(
        self, selector, recognizer);
}

static BOOL VZFluidGestureShouldReceiveTouch(id self, SEL selector,
                                              id recognizer, id touch)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"MultitaskingGestureSuppression"))
        return NO;
    return ((BOOL (*)(id, SEL, id, id))
        gOriginalFluidGestureShouldReceiveTouch)(
            self, selector, recognizer, touch);
}

// iPadOS reveals the Dock whenever a pointer rests on the bottom edge, and a
// top multitasking affordance whenever the pointer reaches the top edge. Both
// are pointer-driven system UI rather than gestures, so neither
// preferredScreenEdgesDeferringSystemGestures nor SBSystemGestureManager
// covers them. They have to be suppressed where SpringBoard presents them, and
// only while Virtual Mac is the frontmost app.
static IMP gOriginalDockSetHidden;
static IMP gOriginalDockSetAlpha;
static IMP gOriginalAffordanceSetHidden;
static Class gAffordanceClass;

static void VZDockSetHidden(id self, SEL selector, BOOL hidden)
{
    if (VZSettingEnabled(@"SystemGestureSuppression") &&
        VZSharedApplicationIsTarget()) {
        static unsigned long count;
        if (count++ < 8)
            Log("hid the iPadOS Dock for the frontmost Virtual Mac");
        hidden = YES;
    }
    ((void (*)(id, SEL, BOOL))gOriginalDockSetHidden)(self, selector, hidden);
}

static void VZDockSetAlpha(id self, SEL selector, double alpha)
{
    if (VZSettingEnabled(@"SystemGestureSuppression") &&
        VZSharedApplicationIsTarget())
        alpha = 0.0;
    ((void (*)(id, SEL, double))gOriginalDockSetAlpha)(self, selector, alpha);
}

static void VZAffordanceSetHidden(id self, SEL selector, BOOL hidden)
{
    if (VZSettingEnabled(@"MultitaskingGestureSuppression") &&
        VZSharedApplicationIsTarget()) {
        static unsigned long count;
        if (count++ < 8)
            Log("hid the iPadOS top multitasking affordance");
        hidden = YES;
    }
    ((void (*)(id, SEL, BOOL))gOriginalAffordanceSetHidden)(
        self, selector, hidden);
}

// One-shot diagnostic. The affordance and Dock classes are private and can
// differ between iPadOS releases, so the tweak dumps the real view tree and the
// matching class names once, guarded by a marker file that the replacement
// installer removes.
static const char *gSystemUIProbeMarker = "/tmp/vz-system-ui-probe.done";

static void VZProbeViewTree(id view, int depth, CGRect screenBounds)
{
    if (!view || depth > 6)
        return;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(
        view, sel_registerName("frame"));
    BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(
        view, sel_registerName("isHidden"));
    double alpha = ((double (*)(id, SEL))objc_msgSend)(
        view, sel_registerName("alpha"));
    BOOL nearTop = frame.origin.y < 100.0;
    BOOL nearBottom =
        CGRectGetMaxY(frame) > CGRectGetMaxY(screenBounds) - 140.0;
    if (depth <= 3 || ((nearTop || nearBottom) && frame.size.width > 1.0)) {
        NSMutableString *indent = [NSMutableString string];
        for (int level = 1; level < depth; level++)
            [indent appendString:@"  "];
        LogFormat(@"[probe] %@%@ frame=%.0f,%.0f %.0fx%.0f hidden=%d "
                  @"alpha=%.2f%@%@",
                  indent, NSStringFromClass(object_getClass(view)),
                  frame.origin.x, frame.origin.y, frame.size.width,
                  frame.size.height, hidden, alpha,
                  nearTop ? @" TOP" : @"",
                  nearBottom ? @" BOTTOM" : @"");
    }
    NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(
        view, sel_registerName("subviews"));
    for (id child in subviews)
        VZProbeViewTree(child, depth + 1, screenBounds);
}

static void VZProbeSystemUIClasses(void)
{
    int count = objc_getClassList(NULL, 0);
    if (count <= 0)
        return;
    Class *classes = calloc((size_t)count, sizeof(Class));
    if (!classes)
        return;
    objc_getClassList(classes, count);
    for (int index = 0; index < count; index++) {
        NSString *name = NSStringFromClass(classes[index]);
        if (![name containsString:@"Dock"] &&
            ![name containsString:@"Affordance"] &&
            ![name containsString:@"Multitasking"] &&
            ![name containsString:@"HomeBar"])
            continue;
        LogFormat(@"[probe] class %@", name);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[index], &methodCount);
        for (unsigned int method = 0; method < methodCount; method++) {
            NSString *selector = NSStringFromSelector(
                method_getName(methods[method]));
            if ([selector containsString:@"idden"] ||
                [selector containsString:@"lpha"] ||
                [selector containsString:@"isible"] ||
                [selector containsString:@"hipTest"] ||
                [selector containsString:@"ointInside"])
                LogFormat(@"[probe]   %@", selector);
        }
        if (methods)
            free(methods);
    }
    free(classes);
}

static void VZProbeSystemUI(void)
{
    LogFormat(@"[probe] ===== SpringBoard UI probe =====");
    Class applicationClass = objc_getClass("UIApplication");
    id application = applicationClass
        ? ((id (*)(id, SEL))objc_msgSend)(
              applicationClass, sel_registerName("sharedApplication"))
        : nil;
    NSArray *windows = application
        ? ((id (*)(id, SEL))objc_msgSend)(
              application, sel_registerName("windows"))
        : nil;
    CGRect screenBounds = CGRectMake(0, 0, 0, 0);
    Class screenClass = objc_getClass("UIScreen");
    if (screenClass) {
        id screen = ((id (*)(id, SEL))objc_msgSend)(
            screenClass, sel_registerName("mainScreen"));
        if (screen)
            screenBounds = ((CGRect (*)(id, SEL))objc_msgSend)(
                screen, sel_registerName("bounds"));
    }
    for (id window in windows) {
        CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("frame"));
        double level = ((double (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("windowLevel"));
        LogFormat(@"[probe] window %@ level=%.0f frame=%.0f,%.0f %.0fx%.0f",
                  NSStringFromClass(object_getClass(window)), level,
                  frame.origin.x, frame.origin.y, frame.size.width,
                  frame.size.height);
        VZProbeViewTree(window, 1, screenBounds);
    }
    VZProbeSystemUIClasses();
}

static void VZScheduleSystemUIProbe(void)
{
    if (access(gSystemUIProbeMarker, F_OK) == 0)
        return;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 4ull * NSEC_PER_SEC),
        4ull * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{
        static int attempts;
        if (!VZSharedApplicationIsTarget()) {
            if (++attempts < 40)
                return;
            Log("system UI probe gave up waiting for the VM to be frontmost");
            dispatch_source_cancel(timer);
            return;
        }
        Log("system UI probe: VM is frontmost, dumping SpringBoard views");
        VZProbeSystemUI();
        FILE *marker = fopen(gSystemUIProbeMarker, "w");
        if (marker) {
            fprintf(marker, "done\n");
            fclose(marker);
        }
        dispatch_source_cancel(timer);
    });
    dispatch_resume(timer);
}

static id VZKeyCommands(id self, SEL selector)
{
    if (VirtualMacVMIsActive(self) &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        static unsigned long count;
        if (count++ < 8)
            Log("suppressed SpringBoard key commands for Virtual Mac");
        // Returning no system-shell UIKeyCommands lets the foreground app's
        // pressesBegan:/pressesEnded: path receive Command-Q, Command-Space,
        // Command-Tab, screenshot chords, and the other Mac guest shortcuts.
        return @[];
    }
    return ((id (*)(id, SEL))gOriginalKeyCommands)(self, selector);
}

static id VZApplicationKeyCommands(id self, SEL selector)
{
    if (VirtualMacVMIsActive(self) &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        static unsigned long count;
        if (count++ < 8)
            Log("suppressed UIApplication system-shell key commands for Virtual Mac");
        // SpringBoard's implementation calls this superclass method, but
        // UIKit can also query the UISystemShellApplication/UIApplication
        // layer directly. Command-Space is registered in that superclass
        // path on iPadOS 16, unlike Command-Q and the screenshot commands
        // that SpringBoard itself contributes.
        return @[];
    }
    return ((id (*)(id, SEL))gOriginalApplicationKeyCommands)(self, selector);
}

static void VZPostCommandShortcut(int64_t usage, BOOL pressed)
{
    NSString *shortcut = usage == 0x2c ? @"command-space"
        : usage == 0x2b ? @"command-tab" : @"command-grave";
    NSString *name = [NSString stringWithFormat:
        @"com.mac.virtual.%@.%@", shortcut,
        pressed ? @"down" : @"up"];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (CFStringRef)name, NULL, NULL, YES);
    DebugLog(pressed ? "relayed consumed Command shortcut down to Virtual Mac"
                     : "relayed consumed Command shortcut up to Virtual Mac");
}

static void VZPostShortcut(const char *name, BOOL pressed)
{
    NSString *notification = [NSString stringWithFormat:
        @"com.mac.virtual.%s.%@", name, pressed ? @"down" : @"up"];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (CFStringRef)notification, NULL, NULL, YES);
    char buffer[128];
    snprintf(buffer, sizeof(buffer),
             "relayed %s %s to Virtual Mac", name, pressed ? "down" : "up");
    DebugLog(buffer);
}

static BOOL VZIsGlobeUsage(int64_t usagePage, int64_t usage)
{
    // The globe/Fn key is an Apple vendor usage (AppleVendorTopCase page
    // 0xFF01 / 0xFF00 / 0xFF, usage 0x03). iPadOS may map it to a different
    // page. Be permissive: any non-keyboard page with usage 0x03 is almost
    // certainly the globe key. Also check Consumer page (0x0C) keyboard-layout
    // keys; 0x29D is what iPadOS keyboards actually send for the 🌐 key,
    // confirmed on-device.
    if (usage == 0x03 && usagePage != 0x07)
        return YES;
    if (usagePage == 0x0c)
        return usage == 0x22d || usage == 0x18a || usage == 0x29d;
    return NO;
}

// globe+<key> chords translate to a single macOS navigation key, mirroring a
// MacBook's Fn+arrow / Fn+Delete. Done at the HID layer because iPadOS's
// input-method switcher consumes globe+arrow before it ever reaches the VM
// app's press path (confirmed on-device: backspace chords arrive, arrow keys
// never do).
static BOOL VZGlobeTranslateUsage(int64_t usage, int64_t *target)
{
    static const struct { int64_t from; int64_t to; } kGlobeChords[] = {
        {0x52, 0x4b},  // Up          -> PageUp
        {0x51, 0x4e},  // Down        -> PageDown
        {0x50, 0x4a},  // Left        -> Home
        {0x4f, 0x4d},  // Right       -> End
        {0x2a, 0x4c},  // Backspace   -> Forward Delete
        {0x28, 0x58},  // Return      -> Keypad Enter
    };
    for (size_t i = 0; i < sizeof(kGlobeChords) / sizeof(kGlobeChords[0]); i++) {
        if (kGlobeChords[i].from == usage) {
            *target = kGlobeChords[i].to;
            return YES;
        }
    }
    return NO;
}

static void VZPostNavShortcut(int64_t target, BOOL pressed)
{
    const char *name = target == 0x4b ? "pageup"
        : target == 0x4e ? "pagedown"
        : target == 0x4a ? "home"
        : target == 0x4d ? "end"
        : target == 0x4c ? "forward-delete"
        : target == 0x58 ? "keypad-enter"
        : "unknown";
    VZPostShortcut(name, pressed);
}

static void VZHandleKeyHIDEvent(id self, SEL selector, CFTypeRef event)
{
    static VZIOHIDEventGetIntegerValue getIntegerValue;
    if (!getIntegerValue) {
        getIntegerValue = (VZIOHIDEventGetIntegerValue)dlsym(
            RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    }

    if (getIntegerValue && VirtualMacVMIsActive(self) &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        int64_t usagePage = getIntegerValue(
            event, VZHIDKeyboardUsagePageField);
        int64_t usage = getIntegerValue(event, VZHIDKeyboardUsageField);
        BOOL pressed = getIntegerValue(event, VZHIDKeyboardDownField) != 0;
        int64_t target;
        if (usagePage == 0x07 && (usage == 0xe3 || usage == 0xe7)) {
            gCommandIsDown = pressed;
        } else if (VZIsGlobeUsage(usagePage, usage)) {
            // The globe/Fn key is a system key (input-source switching) that
            // iPadOS would otherwise consume. Track held state so the chord
            // branch below can translate, relay it (the app uses it to swallow
            // raw chord keys that slip through), and swallow it so it never
            // reaches the system's input-method switcher.
            gGlobeIsDown = pressed;
            VZPostShortcut("globe", pressed);
            return;
        } else if (usagePage == 0x07 &&
                   VZGlobeTranslateUsage(usage, &target)) {
            uint8_t source = (uint8_t)usage;
            if (gGlobeIsDown || gGlobeChordTargets[source]) {
                // Translate globe+<key> to the single macOS navigation key and
                // relay it. Swallow the raw key so neither iPadOS's
                // input-method switcher nor the guest sees it. Record-driven:
                // once a chord is down, every repeat and the release route to
                // the target until the first release, even if the globe was
                // released first.
                gGlobeChordTargets[source] = pressed ? (uint8_t)target : 0;
                VZPostNavShortcut(target, pressed);
                return;
            }
        } else if (usagePage == 0x07 &&
                   (usage == 0x2c || usage == 0x2b || usage == 0x35)) {
            uint64_t bit = 1ULL << (usage & 63);
            if (gCommandIsDown || (gRelayingShortcutUsages & bit)) {
                // These three shell shortcuts are consumed below UIKit on
                // iPadOS. Relay only the non-modifier key; the physical
                // Command key already reaches the foreground VM app.
                if (pressed)
                    gRelayingShortcutUsages |= bit;
                else
                    gRelayingShortcutUsages &= ~bit;
                VZPostCommandShortcut(usage, pressed);
                return;
            }
        }
    }

    ((void (*)(id, SEL, CFTypeRef))gOriginalHandleKeyHIDEvent)(
        self, selector, event);
}

// The globe key also reaches UIKit's event layer, where iPadOS presents the
// input-method switcher. handleKeyHIDEvent: swallowing the raw HID event is
// not enough — the switcher still pops. Swallow the globe here too so the
// guest never sees the system popup.
static void VZHandleKeyUIEvent(id self, SEL selector, id event)
{
    if (VZSharedApplicationIsTarget() &&
        VZSettingEnabled(@"KeyboardShortcutCapture")) {
        SEL hidEventSel = sel_registerName("_hidEvent");
        id hidEvent = nil;
        if ([event respondsToSelector:hidEventSel])
            hidEvent = ((id (*)(id, SEL))objc_msgSend)(event, hidEventSel);
        if (hidEvent) {
            static VZIOHIDEventGetIntegerValue getIntegerValue;
            if (!getIntegerValue)
                getIntegerValue = (VZIOHIDEventGetIntegerValue)dlsym(
                    RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
            if (getIntegerValue) {
                int64_t usagePage = getIntegerValue(
                    (CFTypeRef)hidEvent, VZHIDKeyboardUsagePageField);
                int64_t usage = getIntegerValue(
                    (CFTypeRef)hidEvent, VZHIDKeyboardUsageField);
                if (VZIsGlobeUsage(usagePage, usage)) {
                    static unsigned char logged;
                    if (!logged) {
                        Log("swallowed globe in _handleKeyUIEvent:");
                        logged = 1;
                    }
                    return;
                }
            }
        }
    }
    ((void (*)(id, SEL, id))gOriginalHandleKeyUIEvent)(
        self, selector, event);
}

static void VZScheduleOneShotOpen(void)
{
    if (access(gOpenAfterRespring, F_OK) != 0)
        return;
    Log("scheduled one-shot unlock and Virtual Mac launch");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        // sbreload can briefly start more than one SpringBoard process. Leave
        // the sentinel present until a process survives the delay, then let
        // exactly one winner consume it.
        if (unlink(gOpenAfterRespring) != 0)
            return;
        Class managerClass = objc_getClass("SBLockScreenManager");
        id manager = ((id (*)(id, SEL))objc_msgSend)(
            managerClass, sel_registerName("sharedInstance"));
        BOOL locked = manager && ((BOOL (*)(id, SEL))objc_msgSend)(
            manager, sel_registerName("isUILocked"));
        BOOL unlocked = YES;
        if (locked) {
            unlocked = ((BOOL (*)(id, SEL, int, id))objc_msgSend)(
                manager, sel_registerName("unlockUIFromSource:withOptions:"),
                17, nil);
        }

        id springBoard = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("UIApplication"),
            sel_registerName("sharedApplication"));
        BOOL launched = ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(
            springBoard,
            sel_registerName("launchApplicationWithIdentifier:suspended:"),
            [NSString stringWithUTF8String:gTargetBundleID], NO);
        char message[160];
        snprintf(message, sizeof(message),
                 "one-shot open locked=%d unlocked=%d launched=%d",
                 locked, unlocked, launched);
        Log(message);
    });
}

// Arm the frontmost check only after SpringBoard finishes its initial launch
// (UIKit posts UIApplicationDidFinishLaunchingNotification at the end of
// _finishLaunching, after the controller tree the check depends on is built).
// Resolve the notification name at runtime so the tweak keeps compiling with
// just Foundation linked. Fail-safe: if it never fires, the frontmost lookup
// stays off and the tweak degrades to no suppression rather than crashing.
static void VZObserveSpringBoardFinishedLaunching(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *symbol = dlsym(RTLD_DEFAULT,
            "UIApplicationDidFinishLaunchingNotification");
        if (!symbol)
            return;
        NSString *name = *(NSString **)symbol;
        // MRC: retain the block-observer token or the current autorelease
        // pool drains it and the observation silently goes away.
        static id readyObserver = nil;
        readyObserver = [[[NSNotificationCenter defaultCenter]
            addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                gSpringBoardReady = YES;
                Log("SpringBoard finished launching; frontmost checks enabled");
            }] retain];
    });
}

__attribute__((constructor))
static void VZInstallKeyboardPassthrough(void)
{
    VZReloadSettings();
    VZObserveSpringBoardFinishedLaunching();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        VZSettingsChanged, CFSTR("com.mac.virtual.settings-changed"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    Class springBoard = objc_getClass("SpringBoard");
    VZScheduleOneShotOpen();
    Method method = class_getInstanceMethod(
        springBoard, sel_registerName("keyCommands"));
    if (!method) {
        Log("SpringBoard keyCommands method unavailable");
        return;
    }
    gOriginalKeyCommands = method_setImplementation(
        method, (IMP)VZKeyCommands);

    Method hidMethod = class_getInstanceMethod(
        springBoard, sel_registerName("handleKeyHIDEvent:"));
    if (hidMethod) {
        gOriginalHandleKeyHIDEvent = method_setImplementation(
            hidMethod, (IMP)VZHandleKeyHIDEvent);
        Log("installed raw HID Command-Space relay");
    } else {
        Log("SpringBoard handleKeyHIDEvent: unavailable");
    }

    Class application = objc_getClass("UIApplication");
    Method applicationMethod = class_getInstanceMethod(
        application, sel_registerName("keyCommands"));
    if (applicationMethod) {
        gOriginalApplicationKeyCommands = method_setImplementation(
            applicationMethod, (IMP)VZApplicationKeyCommands);
        Log("installed Virtual Mac SpringBoard and UIApplication key-command passthrough");
    } else {
        Log("UIApplication keyCommands method unavailable");
        Log("installed Virtual Mac SpringBoard key-command passthrough");
    }


    Class gestureManager = objc_getClass("SBSystemGestureManager");
    Method gestureMethod = class_getInstanceMethod(
        gestureManager, sel_registerName("shouldEnableSystemGestureWithType:"));
    if (gestureMethod) {
        gOriginalShouldEnableSystemGesture = method_setImplementation(
            gestureMethod, (IMP)VZShouldEnableSystemGesture);
    }
    Method privateGestureMethod = class_getInstanceMethod(
        gestureManager, sel_registerName("_shouldEnableSystemGestureWithType:"));
    if (privateGestureMethod) {
        gOriginalShouldEnableSystemGesturePrivate = method_setImplementation(
            privateGestureMethod, (IMP)VZShouldEnableSystemGesture);
    }
    Log("installed frontmost-only iPadOS system-gesture suppression");

    Class fluidManager = objc_getClass("SBFluidSwitcherGestureManager");
    Method fluidBeginMethod = class_getInstanceMethod(
        fluidManager, sel_registerName("gestureRecognizerShouldBegin:"));
    if (fluidBeginMethod)
        gOriginalFluidGestureShouldBegin = method_setImplementation(
            fluidBeginMethod, (IMP)VZFluidGestureShouldBegin);
    Method fluidTouchMethod = class_getInstanceMethod(
        fluidManager,
        sel_registerName("gestureRecognizer:shouldReceiveTouch:"));
    if (fluidTouchMethod)
        gOriginalFluidGestureShouldReceiveTouch = method_setImplementation(
            fluidTouchMethod, (IMP)VZFluidGestureShouldReceiveTouch);
    Log("installed active-VM fluid multitasking-gesture suppression");

    // Pointer rest on the bottom edge reveals SpringBoard's Dock, which pushes
    // the guest display out of the way. Hide it while the VM owns the screen.
    Class dockView = objc_getClass("SBDockView");
    Method dockHideMethod = dockView
        ? class_getInstanceMethod(dockView, sel_registerName("setHidden:"))
        : NULL;
    if (dockHideMethod)
        gOriginalDockSetHidden = method_setImplementation(
            dockHideMethod, (IMP)VZDockSetHidden);
    Method dockAlphaMethod = dockView
        ? class_getInstanceMethod(dockView, sel_registerName("setAlpha:"))
        : NULL;
    if (dockAlphaMethod)
        gOriginalDockSetAlpha = method_setImplementation(
            dockAlphaMethod, (IMP)VZDockSetAlpha);
    if (dockHideMethod)
        Log("installed iPadOS Dock hover suppression");
    else
        Log("SBDockView setHidden: unavailable");

    // The top multitasking affordance ("three dots") is a different private
    // class on different iPadOS builds; take the first one that exists.
    const char *affordanceClasses[] = {
        "SBTopAffordanceViewController",
        "SBTopAffordanceView",
        "SBMultitaskingAffordanceView",
        "SBMedusaAffordanceView",
        "SBContinuousExposeAffordanceView",
    };
    for (size_t index = 0;
         index < sizeof(affordanceClasses) / sizeof(affordanceClasses[0]);
         index++) {
        Class candidate = objc_getClass(affordanceClasses[index]);
        Method method = candidate
            ? class_getInstanceMethod(candidate, sel_registerName("setHidden:"))
            : NULL;
        if (!method)
            continue;
        gOriginalAffordanceSetHidden = method_setImplementation(
            method, (IMP)VZAffordanceSetHidden);
        gAffordanceClass = candidate;
        LogFormat(@"installed top affordance suppression on %s",
                  affordanceClasses[index]);
        break;
    }
    if (!gAffordanceClass)
        Log("no top affordance class matched; see the probe output");

    VZScheduleSystemUIProbe();

    // Swallow the globe key at the UIKit event layer to suppress the
    // input-method switcher popup that handleKeyHIDEvent: can't stop.
    Method keyUIEventMethod = class_getInstanceMethod(
        application, sel_registerName("_handleKeyUIEvent:"));
    if (keyUIEventMethod) {
        gOriginalHandleKeyUIEvent = method_setImplementation(
            keyUIEventMethod, (IMP)VZHandleKeyUIEvent);
        Log("installed _handleKeyUIEvent: globe input-method suppression");
    } else {
        Log("UIApplication _handleKeyUIEvent: unavailable");
    }

}
