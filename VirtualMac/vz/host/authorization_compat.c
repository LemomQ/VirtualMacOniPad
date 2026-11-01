#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <CoreFoundation/CoreFoundation.h>

typedef int32_t OSStatus;
typedef void *AuthorizationRef;
typedef uint32_t AuthorizationFlags;
typedef unsigned char Boolean;

typedef Boolean (*SMJobSetEnabledFn)(CFStringRef domain,
                                     AuthorizationRef authorization,
                                     CFStringRef jobLabel,
                                     Boolean enabled,
                                     CFErrorRef *error);

extern Boolean SMJobSetEnabled(CFStringRef domain,
                               AuthorizationRef authorization,
                               CFStringRef jobLabel,
                               Boolean enabled,
                               CFErrorRef *error);

typedef struct {
    int listener;
    struct sockaddr_storage client;
    socklen_t clientLength;
    size_t length;
    unsigned char packet[4096];
} DNSRequest;

static struct sockaddr_in upstreamDNS;

static void chooseUpstreamDNS(void) {
    const char *selected = NULL;
    typedef CFPropertyListRef (*SCDynamicStoreCopyValueFn)(void *, CFStringRef);
    SCDynamicStoreCopyValueFn copyValue =
        (SCDynamicStoreCopyValueFn)dlsym(RTLD_DEFAULT,
                                         "SCDynamicStoreCopyValue");
    CFDictionaryRef state = copyValue ? (CFDictionaryRef)copyValue(
        NULL, CFSTR("State:/Network/Global/DNS")) : NULL;
    if (state && CFGetTypeID(state) == CFDictionaryGetTypeID()) {
        CFArrayRef addresses = (CFArrayRef)CFDictionaryGetValue(
            state, CFSTR("ServerAddresses"));
        if (addresses && CFGetTypeID(addresses) == CFArrayGetTypeID()) {
            for (CFIndex index = 0; index < CFArrayGetCount(addresses); index++) {
                CFStringRef value = (CFStringRef)CFArrayGetValueAtIndex(
                    addresses, index);
                static char address[INET_ADDRSTRLEN];
                struct in_addr parsed;
                if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
                    CFStringGetCString(value, address, sizeof(address),
                                       kCFStringEncodingUTF8) &&
                    strcmp(address, "192.168.64.1") != 0 &&
                    inet_pton(AF_INET, address, &parsed) == 1) {
                    selected = address;
                    break;
                }
            }
        }
    }
    memset(&upstreamDNS, 0, sizeof(upstreamDNS));
    upstreamDNS.sin_family = AF_INET;
    upstreamDNS.sin_port = htons(53);
    inet_pton(AF_INET, selected ?: "1.1.1.1", &upstreamDNS.sin_addr);
    dprintf(STDERR_FILENO,
            "AuthorizationCompat: iPadOS 15 DNS relay upstream=%s\n",
            selected ?: "1.1.1.1");
    if (state)
        CFRelease(state);
}

static void *relayDNSRequest(void *context) {
    DNSRequest *request = context;
    int upstream = socket(AF_INET, SOCK_DGRAM, 0);
    if (upstream >= 0) {
        struct timeval timeout = {.tv_sec = 3, .tv_usec = 0};
        setsockopt(upstream, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout));
        if (sendto(upstream, request->packet, request->length, 0,
                   (const struct sockaddr *)&upstreamDNS,
                   sizeof(upstreamDNS)) >= 0) {
            unsigned char response[4096];
            ssize_t length = recvfrom(upstream, response, sizeof(response),
                                      0, NULL, NULL);
            if (length > 0) {
                sendto(request->listener, response, (size_t)length, 0,
                       (const struct sockaddr *)&request->client,
                       request->clientLength);
            }
        }
        close(upstream);
    }
    free(request);
    return NULL;
}

static void *runDNSRelay(void *unused) {
    (void)unused;
    int listener = socket(AF_INET, SOCK_DGRAM, 0);
    int yes = 1;
    if (listener < 0 ||
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) ||
        bind(listener, (const struct sockaddr *)&(struct sockaddr_in){
                 .sin_family = AF_INET,
                 .sin_port = htons(53),
                 .sin_addr.s_addr = htonl(INADDR_ANY)},
             sizeof(struct sockaddr_in))) {
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: iPadOS 15 DNS relay bind failed=%d\n",
                errno);
        if (listener >= 0)
            close(listener);
        return NULL;
    }
    dprintf(STDERR_FILENO,
            "AuthorizationCompat: iPadOS 15 DNS relay listening\n");
    for (;;) {
        DNSRequest *request = calloc(1, sizeof(*request));
        if (!request)
            break;
        request->listener = listener;
        request->clientLength = sizeof(request->client);
        ssize_t length = recvfrom(listener, request->packet,
                                  sizeof(request->packet), 0,
                                  (struct sockaddr *)&request->client,
                                  &request->clientLength);
        if (length <= 0) {
            free(request);
            continue;
        }
        request->length = (size_t)length;
        pthread_t worker;
        if (pthread_create(&worker, NULL, relayDNSRequest, request) == 0)
            pthread_detach(worker);
        else
            free(request);
    }
    close(listener);
    return NULL;
}

static void startLegacyDNSRelayIfNeeded(void) {
    char version[32] = {0};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) ||
        strtol(version, NULL, 10) >= 16)
        return;
    chooseUpstreamDNS();
    pthread_t thread;
    if (pthread_create(&thread, NULL, runDNSRelay, NULL) == 0)
        pthread_detach(thread);
}

__attribute__((constructor)) static void initializeInternetSharingCompat(void) {
    startLegacyDNSRelayIfNeeded();

    typedef CFTypeRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*SecTaskCopyValueForEntitlementFn)(
        CFTypeRef, CFStringRef, CFErrorRef *);
    SecTaskCreateFromSelfFn createTask =
        (SecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT,
                                      "SecTaskCreateFromSelf");
    SecTaskCopyValueForEntitlementFn copyEntitlement =
        (SecTaskCopyValueForEntitlementFn)dlsym(
            RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (createTask && copyEntitlement) {
        CFTypeRef task = createTask(kCFAllocatorDefault);
        CFTypeRef value = task ? copyEntitlement(
            task, CFSTR("com.apple.networking.ethernet.user-access"),
            NULL) : NULL;
        int granted = value && CFGetTypeID(value) == CFBooleanGetTypeID() &&
                      CFBooleanGetValue((CFBooleanRef)value);
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: ethernet entitlement=%d value=%p\n",
                granted, value);
        if (value)
            CFRelease(value);
        if (task)
            CFRelease(task);
    }
}

// InternetSharing runs as a root platform daemon on iPadOS. Desktop Security's
// Authorization Services entry points are absent there, while the daemon only
// uses them to establish and release its privileged launchd-operation context.
OSStatus AuthorizationCreate(const void *rights, const void *environment,
                             AuthorizationFlags flags,
                             AuthorizationRef *authorization) {
    (void)rights;
    (void)environment;
    (void)flags;
    if (authorization)
        *authorization = 0;
    return 0;
}

OSStatus AuthorizationFree(AuthorizationRef authorization,
                           AuthorizationFlags flags) {
    (void)authorization;
    (void)flags;
    return 0;
}

// iPadOS redirects rootless launch daemons without an explicit System session
// into the foreground-user domain. InternetSharing must live there to reach
// MobileInternetSharing, but Ventura hard-codes kSMDomainSystemLaunchd when it
// enables bootpd. Remap only our private matching-helper label to the user
// domain; every other ServiceManagement operation is forwarded unchanged.
static Boolean compatSMJobSetEnabled(CFStringRef domain,
                                     AuthorizationRef authorization,
                                     CFStringRef jobLabel,
                                     Boolean enabled,
                                     CFErrorRef *error);

static int cachedHostMajorVersion;
static pthread_once_t hostVersionOnce = PTHREAD_ONCE_INIT;

static void resolveHostMajorVersion(void) {
    char productVersion[32] = {0};
    size_t size = sizeof(productVersion);
    if (sysctlbyname("kern.osproductversion", productVersion,
                     &size, NULL, 0) == 0)
        cachedHostMajorVersion = (int)strtol(productVersion, NULL, 10);
}

static int hostMajorVersion(void) {
    pthread_once(&hostVersionOnce, resolveHostMajorVersion);
    return cachedHostMajorVersion;
}

static Boolean compatSMJobSetEnabled(CFStringRef domain,
                                     AuthorizationRef authorization,
                                     CFStringRef jobLabel,
                                     Boolean enabled,
                                     CFErrorRef *error) {
    bool isMatchingBootpd = jobLabel &&
        CFEqual(jobLabel, CFSTR("vzi.apple.bootpd"));
    int majorVersion = hostMajorVersion();
    // iPadOS 14 has no ServiceManagement implementation. Avoid repeating an
    // impossible dlopen/dlsym and thousands of identical stderr lines, while
    // retaining the established result for both the private bootpd job and
    // every other caller.
    if (majorVersion == 14) {
        if (isMatchingBootpd) {
            static unsigned int bootpdLogCount;
            if (__sync_fetch_and_add(&bootpdLogCount, 1) < 4)
                dprintf(STDERR_FILENO,
                        "AuthorizationCompat: iPadOS 14 private bootpd "
                        "requested=%d; package controller owns launchd\n",
                        enabled);
            return 1;
        }
        static unsigned int unavailableLogCount;
        if (__sync_fetch_and_add(&unavailableLogCount, 1) < 4)
            dprintf(STDERR_FILENO,
                    "AuthorizationCompat: SMJobSetEnabled unavailable\n");
        return 0;
    }

    // Preserve the proven iPadOS 15/16 lookup and retry behavior. In
    // particular, do not permanently cache an early failed symbol lookup.
    static SMJobSetEnabledFn realFunction;
    static const CFStringRef *userDomain;
    if (!realFunction || !userDomain) {
        void *serviceManagement = dlopen(
            "/System/Library/PrivateFrameworks/ServiceManagement.framework/ServiceManagement",
            RTLD_LAZY | RTLD_LOCAL);
        realFunction = serviceManagement ? (SMJobSetEnabledFn)dlsym(
            serviceManagement, "SMJobSetEnabled") : NULL;
        userDomain = serviceManagement ? (const CFStringRef *)dlsym(
            serviceManagement, "kSMDomainUserLaunchd") : NULL;
        if ((void *)realFunction == (void *)&compatSMJobSetEnabled)
            realFunction = (SMJobSetEnabledFn)dlsym(
                RTLD_NEXT, "SMJobSetEnabled");
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: resolved ServiceManagement "
                "function=%p user-domain=%p\n",
                realFunction, userDomain);
    }
    if (isMatchingBootpd && majorVersion >= 16 &&
        userDomain && *userDomain) {
        domain = *userDomain;
        dprintf(STDERR_FILENO,
                "AuthorizationCompat: bootpd launch domain -> user (%d)\n",
                enabled);
    }
    if (!realFunction) {
        static unsigned int unavailableLogCount;
        if (__sync_fetch_and_add(&unavailableLogCount, 1) < 4)
            dprintf(STDERR_FILENO,
                    "AuthorizationCompat: SMJobSetEnabled unavailable\n");
        return 0;
    }
    return realFunction(domain, authorization, jobLabel, enabled, error);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interposeSMJobSetEnabled __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&compatSMJobSetEnabled,
    (const void *)&SMJobSetEnabled,
};
