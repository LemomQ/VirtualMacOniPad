#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef EXPERIMENTAL_UNREAL_GAMES
#define EXPERIMENTAL_UNREAL_GAMES 0
#endif
#import <sys/sysctl.h>

// macOS does not advertise its Metal-backed OpenGL renderer for a paravirtual GPU.
// The renderer itself works over PVG, but the Ventura-era serializer rejects GLD's 
// defaultRasterSampleCount hint and custom FSAA sample locations. This guest shim 
// opts PVG into GLD and normalizes only those redundant overrides before the render 
// pass is serialized. Attachment sample counts, including MSAA, are unchanged.

static IMP gSupportsFamily;
static IMP gNewCommandQueue;
static IMP gCommandBuffer;
static IMP gCommandBufferUnretained;
static IMP gRenderEncoder;
static IMP gSetVertexBuffer;
static IMP gSetVertexBuffers;
static char gInlineVertexStorageKey;
static void InstallRenderEncoderCompatibility(id encoder);

static BOOL DebugEnabled(void) {
    const char *value = getenv("VIRTUAL_MAC_OPENGL_DEBUG");
    return value != NULL && value[0] != '\0' && strcmp(value, "0") != 0;
}

static BOOL ProcessUsesUnsupportedOpenGLPath(void) {
    static BOOL excluded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Resolve the executable names from the corresponding app bundles,
        // rather than relying on where users install the apps. Firefox does
        // its relevant compositing in its GPU helper and plugin-container,
        // not the main executable. Keep global environment injection, but
        // leave only these exact helper/Sublime executables on macOS's stock
        // renderer.
        NSString *executable = NSProcessInfo.processInfo.processName;
        excluded = [executable isEqualToString:@"firefox"] ||
            [executable isEqualToString:@"Firefox GPU Helper"] ||
            [executable isEqualToString:
                @"Firefox Developer Edition GPU Helper"] ||
            [executable isEqualToString:@"plugin-container"] ||
            [executable isEqualToString:@"sublime_merge"] ||
            [executable isEqualToString:@"sublime_text"];
    });
    return excluded;
}

static BOOL ProcessIsTranslated(void) {
    static BOOL translated;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int value = 0;
        size_t size = sizeof(value);
        translated = sysctlbyname("sysctl.proc_translated", &value, &size,
                                  NULL, 0) == 0 && value == 1;
    });
    return translated;
}

static void ReplaceMethod(Class cls, SEL selector, IMP replacement,
                          IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL || *original != NULL)
        return;
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement,
                        method_getTypeEncoding(method));
}

static id UnderlyingDevice(id device) {
    SEL selector = NSSelectorFromString(@"originalObject");
    while ([device respondsToSelector:selector]) {
        id next = ((id (*)(id, SEL))objc_msgSend)(device, selector);
        if (next == nil || next == device)
            break;
        device = next;
    }
    return device;
}

static BOOL ClearCustomSamplePositions(id descriptor, NSUInteger count) {
    // Metal's public setter ignores a zero count once custom positions have
    // been installed. Locate the count field from Objective-C's complete
    // runtime type encoding rather than relying on an OS-specific offset.
    Ivar privateIvar = class_getInstanceVariable(
        object_getClass(descriptor), "_private");
    const char *encoding = privateIvar != NULL
        ? ivar_getTypeEncoding(privateIvar) : NULL;
    const char *cursor = encoding != NULL ? strchr(encoding, '=') : NULL;
    if (cursor == NULL)
        return NO;
    ++cursor;

    NSUInteger offset = 0;
    while (*cursor != '\0' && *cursor != '}') {
        const char *name = NULL;
        size_t nameLength = 0;
        if (*cursor == '"') {
            name = ++cursor;
            while (*cursor != '\0' && *cursor != '"')
                ++cursor;
            nameLength = (size_t)(cursor - name);
            if (*cursor == '"')
                ++cursor;
        }

        NSUInteger size = 0;
        NSUInteger alignment = 0;
        const char *next = NSGetSizeAndAlignment(
            cursor, &size, &alignment);
        if (next == NULL || next <= cursor || alignment == 0)
            return NO;
        offset = (offset + alignment - 1) & ~(alignment - 1);

        static const char target[] = "numCustomSamplePositions";
        if (nameLength == sizeof(target) - 1 &&
            memcmp(name, target, sizeof(target) - 1) == 0 &&
            size == sizeof(NSUInteger)) {
            ptrdiff_t privateOffset = ivar_getOffset(privateIvar);
            NSUInteger instanceSize = class_getInstanceSize(
                object_getClass(descriptor));
            if (privateOffset < 0 ||
                (NSUInteger)privateOffset + offset + size > instanceSize)
                return NO;
            NSUInteger *storedCount = (NSUInteger *)(
                (uint8_t *)(__bridge void *)descriptor + privateOffset +
                offset);
            if (*storedCount != count)
                return NO;
            *storedCount = 0;
            return YES;
        }

        offset += size;
        cursor = next;
    }
    return NO;
}

static BOOL PVGSupportsFamily(id self, SEL selector, NSUInteger family) {
    // M1 and M2 implement at least Apple7. GLD selects its modern agx2 path
    // when Apple7 is present; PVG otherwise exposes only Mac/Common families.
    const NSUInteger maximumFamily = 1007;
    if (family >= 1001 && family <= maximumFamily)
        return YES;
    return ((BOOL (*)(id, SEL, NSUInteger))gSupportsFamily)(
        self, selector, family);
}

static id PVGRenderEncoder(id self, SEL selector, id descriptor) {
    SEL getter = NSSelectorFromString(@"defaultRasterSampleCount");
    SEL setter = NSSelectorFromString(@"setDefaultRasterSampleCount:");
    if ([descriptor respondsToSelector:getter] &&
        [descriptor respondsToSelector:setter] &&
        ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, getter) != 0) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
            descriptor, setter, 0);
        if (DebugEnabled())
            fprintf(stderr,
                    "OpenGLPVGCompat: cleared default raster sample count\n");
    }
    SEL sampleGetter = @selector(getSamplePositions:count:);
    if ([descriptor respondsToSelector:sampleGetter] &&
        class_getInstanceVariable(object_getClass(descriptor), "_private") !=
            NULL) {
        NSUInteger count =
            ((NSUInteger (*)(id, SEL, MTLSamplePosition *, NSUInteger))
                 objc_msgSend)(descriptor, sampleGetter, NULL, 0);
        if (count != 0 && ClearCustomSamplePositions(descriptor, count)) {
            if (DebugEnabled())
                fprintf(stderr,
                        "OpenGLPVGCompat: cleared %lu custom sample "
                        "positions\n", (unsigned long)count);
        }
    }
    id encoder = ((id (*)(id, SEL, id))gRenderEncoder)(
        self, selector, descriptor);
    if (encoder != nil && ProcessIsTranslated())
        InstallRenderEncoderCompatibility(encoder);
    return encoder;
}

static void PVGSetVertexBuffer(id self, SEL selector, id buffer,
                               NSUInteger offset, NSUInteger index) {
    // Rosetta writes GLD's managed 16 KiB staging buffer through its x86
    // address space. PVG's no-copy mapping does not make those translated
    // stores visible to the host GPU, even after didModifyRange. Serialize
    // the staging bytes with the command instead. Native Arm buffers retain
    // the normal zero-copy path.
    const NSUInteger maximumInlineLength = 16 * 1024;
    if (ProcessIsTranslated() && buffer != nil &&
        [buffer respondsToSelector:@selector(contents)] &&
        [buffer respondsToSelector:@selector(length)] &&
        [buffer length] > offset) {
        // GLD suballocates the active draw data from a larger ring. Its
        // private inline path transfers one 16 KiB window from the selected
        // offset, which is also the largest payload validated over PVG.
        NSUInteger length = MIN([buffer length] - offset,
                                maximumInlineLength);
        const uint8_t *bytes = (const uint8_t *)[buffer contents] + offset;
        if (bytes != NULL) {
            NSData *snapshot = [NSData dataWithBytes:bytes length:length];
            NSMutableArray *storage = objc_getAssociatedObject(
                self, &gInlineVertexStorageKey);
            if (storage == nil) {
                storage = [NSMutableArray array];
                objc_setAssociatedObject(
                    self, &gInlineVertexStorageKey, storage,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [storage addObject:snapshot];
            ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))
                 objc_msgSend)(self,
                               @selector(setVertexBytes:length:atIndex:),
                               snapshot.bytes, length, index);
            if (DebugEnabled()) {
                static unsigned long count;
                unsigned long current = __sync_add_and_fetch(&count, 1);
                if (current <= 8)
                    fprintf(stderr,
                            "OpenGLPVGCompat: inlined Rosetta vertex "
                            "buffer length=%lu index=%lu\n",
                            (unsigned long)length, (unsigned long)index);
            }
            return;
        }
    }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))gSetVertexBuffer)(
        self, selector, buffer, offset, index);
}

static void PVGSetVertexBuffers(id self, SEL selector, const id *buffers,
                                const NSUInteger *offsets, NSRange range) {
    if (!ProcessIsTranslated()) {
        ((void (*)(id, SEL, const id *, const NSUInteger *, NSRange))
             gSetVertexBuffers)(self, selector, buffers, offsets, range);
        return;
    }
    for (NSUInteger position = 0; position < range.length; ++position) {
        PVGSetVertexBuffer(self, @selector(setVertexBuffer:offset:atIndex:),
                           buffers[position], offsets[position],
                           range.location + position);
    }
}

static void InstallRenderEncoderCompatibility(id encoder) {
    ReplaceMethod([encoder class],
                  @selector(setVertexBuffer:offset:atIndex:),
                  (IMP)PVGSetVertexBuffer, &gSetVertexBuffer);
    ReplaceMethod([encoder class],
                  @selector(setVertexBuffers:offsets:withRange:),
                  (IMP)PVGSetVertexBuffers, &gSetVertexBuffers);
}

static void InstallCommandBufferCompatibility(id commandBuffer) {
    ReplaceMethod([commandBuffer class],
                  @selector(renderCommandEncoderWithDescriptor:),
                  (IMP)PVGRenderEncoder, &gRenderEncoder);
}

static id PVGCommandBuffer(id self, SEL selector) {
    id commandBuffer = ((id (*)(id, SEL))gCommandBuffer)(self, selector);
    InstallCommandBufferCompatibility(commandBuffer);
    return commandBuffer;
}

static id PVGCommandBufferUnretained(id self, SEL selector) {
    id commandBuffer =
        ((id (*)(id, SEL))gCommandBufferUnretained)(self, selector);
    InstallCommandBufferCompatibility(commandBuffer);
    return commandBuffer;
}

static void InstallQueueCompatibility(id queue) {
    ReplaceMethod([queue class], @selector(commandBuffer),
                  (IMP)PVGCommandBuffer, &gCommandBuffer);
    ReplaceMethod([queue class],
                  NSSelectorFromString(
                      @"commandBufferWithUnretainedReferences"),
                  (IMP)PVGCommandBufferUnretained,
                  &gCommandBufferUnretained);
}

static id PVGNewCommandQueue(id self, SEL selector) {
    id queue = ((id (*)(id, SEL))gNewCommandQueue)(self, selector);
    InstallQueueCompatibility(queue);
    return queue;
}

static void EnablePVGOpenGL(id<MTLDevice> device) {
    device = UnderlyingDevice(device);
    if (![NSStringFromClass([device class])
            isEqualToString:@"AppleParavirtDevice"])
        return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ReplaceMethod([device class], @selector(supportsFamily:),
                      (IMP)PVGSupportsFamily, &gSupportsFamily);
        ReplaceMethod([device class], @selector(newCommandQueue),
                      (IMP)PVGNewCommandQueue, &gNewCommandQueue);
        if (DebugEnabled())
            fprintf(stderr,
                    "OpenGLPVGCompat: enabled Apple7 GLD profile for PVG\n");
    });
}

static bool IsParavirtualGPU(io_registry_entry_t entry) {
    io_name_t className = {0};
    return IOObjectGetClass(entry, className) == KERN_SUCCESS &&
           strcmp(className, "AppleParavirtGPU") == 0;
}

#if EXPERIMENTAL_UNREAL_GAMES
static bool IsParavirtualGPUProvider(io_registry_entry_t entry,
                                     CFDictionaryRef properties) {
    CFTypeRef compatible = properties != NULL
        ? CFDictionaryGetValue(properties, CFSTR("compatible")) : NULL;
    if (compatible != NULL && CFGetTypeID(compatible) == CFDataGetTypeID()) {
        static const char name[] = "paravirtualizedgraphics,gpu";
        CFDataRef data = compatible;
        if (CFDataGetLength(data) >= (CFIndex)sizeof(name) - 1 &&
            memcmp(CFDataGetBytePtr(data), name, sizeof(name) - 1) == 0)
            return true;
    }
    io_name_t registryName = {0};
    return IORegistryEntryGetName(entry, registryName) == KERN_SUCCESS &&
           strcmp(registryName, "gfx") == 0;
}

static kern_return_t PVGCreateRegistryProperties(
    io_registry_entry_t entry, CFMutableDictionaryRef *properties,
    CFAllocatorRef allocator, IOOptionBits options) {
    kern_return_t result = IORegistryEntryCreateCFProperties(
        entry, properties, allocator, options);
    if (result != KERN_SUCCESS || properties == NULL || *properties == NULL ||
        !IsParavirtualGPUProvider(entry, *properties))
        return result;
    static const UInt8 sgx[] = {'s', 'g', 'x'};
    CFDataRef deviceType = CFDataCreate(allocator, sgx, sizeof(sgx));
    if (deviceType != NULL) {
        CFDictionarySetValue(*properties, CFSTR("device_type"), deviceType);
        CFRelease(deviceType);
    }
    return result;
}

static CFTypeRef PVGSearchRegistryProperty(
    io_registry_entry_t entry, const io_name_t plane, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options) {
    if (IsParavirtualGPU(entry) && CFEqual(key, CFSTR("IOMatchCategory")))
        return CFRetain(CFSTR("IOAccelerator"));
    return IORegistryEntrySearchCFProperty(
        entry, plane, key, allocator, options);
}
#endif

static CFTypeRef PVGCreateRegistryProperty(
    io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator,
    IOOptionBits options) {
    if (!ProcessUsesUnsupportedOpenGLPath() && IsParavirtualGPU(entry) &&
        CFEqual(key, CFSTR("IOGLBundleName"))) {
        for (id<MTLDevice> device in MTLCopyAllDevices())
            EnablePVGOpenGL(device);
        return CFRetain(CFSTR("AppleMetalOpenGLRenderer"));
    }
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}

#define INTERPOSE(name, replacement, original)                              \
    __attribute__((used)) static struct {                                   \
        const void *replacement;                                            \
        const void *original;                                               \
    } name __attribute__((section("__DATA,__interpose"))) = {               \
        (const void *)&replacement, (const void *)&original                 \
    }

INTERPOSE(pvg_iogl_property, PVGCreateRegistryProperty,
          IORegistryEntryCreateCFProperty);
#if EXPERIMENTAL_UNREAL_GAMES
INTERPOSE(pvg_gpu_registry_properties, PVGCreateRegistryProperties,
          IORegistryEntryCreateCFProperties);
INTERPOSE(pvg_gpu_search_property, PVGSearchRegistryProperty,
          IORegistryEntrySearchCFProperty);
#endif
