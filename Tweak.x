// ============================================================================
// ProMotionControl — Tweak runtime (iOS 15+)
// Build: 5.9.0t — GETTER SPOOF, [10, 240, target] all paths + Profile plist
// Getter hooks: preferredFramesPerSecond + preferredFrameRateRange return the
// chosen target verbatim. Floor is 10, ceiling 240, everywhere. Profile plist
// (com.dell.promotioncontrol.profile.plist) drives defaults when present.
// ============================================================================
#include <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <string.h>
#include <stdatomic.h>
#import <dispatch/dispatch.h>
#import <stdint.h>
#import <math.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>

@import Darwin.os.lock;

// Thêm các headers mới cho các module đã được tạo/chỉnh sửa
#import "TitaniumSettingsAPI.h"
#import "TitaniumServerTierSupport.h"

// ============================================================================
// Private framework symbols (IOMobileFramebuffer, IOKit)
// ============================================================================
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef IOMobileFramebufferRef (*PFN_IOMobileFramebufferGetMainDisplay)(void);
typedef int (*PFN_IOMobileFramebufferOpen)(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef *);
typedef int (*PFN_IOMobileFramebufferSetDisplayMode)(IOMobileFramebufferRef, uint32_t);
typedef int (*PFN_IOMobileFramebufferGetDisplayMode)(IOMobileFramebufferRef, uint32_t *);
typedef int (*PFN_IOMobileFramebufferSetSwapInterval)(IOMobileFramebufferRef, int32_t);
typedef int (*PFN_IOMobileFramebufferGetSwapInterval)(IOMobileFramebufferRef, int32_t *);
typedef io_service_t (*PFN_IOServiceGetMatchingService)(mach_port_t, CFDictionaryRef);
typedef CFMutableDictionaryRef (*PFN_IOServiceMatching)(const char *);

static PFN_IOMobileFramebufferGetMainDisplay     g_IOMFBGetMain      = NULL;
static PFN_IOMobileFramebufferSetDisplayMode     g_IOMFBSetMode      = NULL;
static PFN_IOMobileFramebufferGetDisplayMode     g_IOMFBGetMode      = NULL;
static PFN_IOMobileFramebufferSetSwapInterval    g_IOMFBSetSwapInt   = NULL;
static PFN_IOMobileFramebufferGetSwapInterval    g_IOMFBGetSwapInt   = NULL;
static PFN_IOMobileFramebufferOpen               g_IOMFBOpen         = NULL;
static PFN_IOServiceGetMatchingService           g_IOSvcGetMatching  = NULL;
static PFN_IOServiceMatching                     g_IOSvcMatching     = NULL;

static void PMResolvePrivateFrameworkSymbols(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
    if (handle) {
        g_IOMFBGetMain    = (PFN_IOMobileFramebufferGetMainDisplay)dlsym(handle, "IOMobileFramebufferGetMainDisplay");
        g_IOMFBSetMode    = (PFN_IOMobileFramebufferSetDisplayMode)dlsym(handle, "IOMobileFramebufferSetDisplayMode");
        g_IOMFBGetMode    = (PFN_IOMobileFramebufferGetDisplayMode)dlsym(handle, "IOMobileFramebufferGetDisplayMode");
        g_IOMFBSetSwapInt = (PFN_IOMobileFramebufferSetSwapInterval)dlsym(handle, "IOMobileFramebufferSetSwapInterval");
        g_IOMFBGetSwapInt = (PFN_IOMobileFramebufferGetSwapInterval)dlsym(handle, "IOMobileFramebufferGetSwapInterval");
        g_IOMFBOpen       = (PFN_IOMobileFramebufferOpen)dlsym(handle, "IOMobileFramebufferOpen");
    }
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokit) {
        g_IOSvcGetMatching = (PFN_IOServiceGetMatchingService)dlsym(iokit, "IOServiceGetMatchingService");
        g_IOSvcMatching    = (PFN_IOServiceMatching)dlsym(iokit, "IOServiceMatching");
    }
}

// ============================================================================
// PMFrameOptimizer - Kept as is from user's provided code.
// ============================================================================
@interface PMFrameOptimizer : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSUInteger frameCount;
@property (nonatomic, assign) CFTimeInterval lastTickTimestamp;
@property (nonatomic, assign) CFTimeInterval firstTickTimestamp;
@property (nonatomic, assign) double runningAverageDelta;
- (void)startHighRefreshRateLoop;
- (void)startHighRefreshRateLoopWithPreferred:(NSInteger)preferred
                                      minimum:(NSInteger)minimum
                                      maximum:(NSInteger)maximum;
- (void)startLockedHighRefreshRateLoopWithPreferred:(NSInteger)preferred;
- (void)stopLoop;
- (double)averageFrameDelta;
- (NSUInteger)totalFramesRendered;
@end

@implementation PMFrameOptimizer
- (instancetype)init {
    if ((self = [super init])) {
        _frameCount = 0; _lastTickTimestamp = 0.0;
        _firstTickTimestamp = 0.0; _runningAverageDelta = 0.0;
    }
    return self;
}
- (void)startHighRefreshRateLoop {
    NSInteger hardwareMax = 240;
    @try {
        hardwareMax = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
        if (hardwareMax <= 0) hardwareMax = 240;
    } @catch (NSException *e) { hardwareMax = 240; }
    NSInteger preferred = MIN(10, hardwareMax);
    [self startHighRefreshRateLoopWithPreferred:preferred minimum:10 maximum:hardwareMax];
}
- (void)startHighRefreshRateLoopWithPreferred:(NSInteger)preferred
                                      minimum:(NSInteger)minimum
                                      maximum:(NSInteger)maximum {
    [self stopLoop];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame:)];
    NSInteger clampedMin = MAX(10, MIN(minimum, 240));
    NSInteger clampedMax = MAX(clampedMin, MIN(maximum, 240));
    NSInteger clampedPreferred = MAX(clampedMin, MIN(preferred, clampedMax));
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake((CGFloat)clampedMin, (CGFloat)clampedMax, (CGFloat)clampedPreferred);
    } else {
        self.displayLink.preferredFramesPerSecond = clampedPreferred;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)startLockedHighRefreshRateLoopWithPreferred:(NSInteger)preferred {
    [self stopLoop];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame:)];
    NSInteger clampedPreferred = MAX(10, MIN(preferred, 240));
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake(10.0, 240.0, (CGFloat)clampedPreferred);
    } else {
        self.displayLink.preferredFramesPerSecond = clampedPreferred;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)renderFrame:(CADisplayLink *)sender {
    CFTimeInterval now = sender.timestamp;
    if (_firstTickTimestamp <= 0.0) _firstTickTimestamp = now;
    if (_lastTickTimestamp > 0.0) {
        CFTimeInterval delta = now - _lastTickTimestamp;
        if (delta > 0.0) {
            if (_runningAverageDelta <= 0.0) _runningAverageDelta = delta;
            else _runningAverageDelta = (_runningAverageDelta * 0.95) + (delta * 0.05);
        }
    }
    _lastTickTimestamp = now;
    _frameCount += 1;
}
- (void)stopLoop {
    if (self.displayLink) { [self.displayLink invalidate]; self.displayLink = nil; }
    _lastTickTimestamp = 0.0;
}
- (double)averageFrameDelta { return _runningAverageDelta; }
- (NSUInteger)totalFramesRendered { return _frameCount; }
@end

__attribute__((visibility("default"), used))
int PMControlTweakRuntimeMarker(void) { return 0x504D4354; }

__attribute__((visibility("default"), used))
const char *PMControlTweakInstallationID(void) {
    static char identifierBuffer[129] = {0};
    @synchronized ([PMFrameOptimizer class]) {
        identifierBuffer[0] = '\0';
        NSString *identifier = [NSString stringWithContentsOfFile:
            @"/var/mobile/Library/Preferences/.com.dell.promotioncontrol.installation-id"
            encoding:NSUTF8StringEncoding error:nil];
        identifier = [identifier stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (identifier.length >= 32 && identifier.length < sizeof(identifierBuffer)) {
            const char *utf8 = identifier.UTF8String;
            if (utf8) {
                size_t length = strlen(utf8);
                if (length >= 32 && length < sizeof(identifierBuffer)) {
                    memcpy(identifierBuffer, utf8, length);
                    identifierBuffer[length] = '\0';
                }
            }
        }
    }
    return identifierBuffer[0] ? identifierBuffer : NULL;
}

__attribute__((visibility("default"), used))
const char *PMControlTweakBuildVersion(void) {
    static const char *version = "8.0.1t";
    return version;
}

__attribute__((visibility("default"), used))
int PMControlTweakUnlockLevel(void) {
    extern NSInteger Titanium_UnlockLevel(void);
    return (int)Titanium_UnlockLevel();
}

#define PM_BUILD_VERSION @"8.0.1t"
#define PM_PREFS_PATH @"/var/mobile/Library/Preferences/com.dell.promotioncontrol.plist"
#define PM_LEGACY_PREFS_PATH @"/var/mobile/Library/Preferences/com.promotioncontrol.prefs.plist"
#define PM_SUPPLEMENTAL_PREFS_PATH @"/var/mobile/Library/Preferences/com.dell.promotioncontrol.supplemental.plist"
// NEW 8.0.1t: profile plist — high-priority defaults the user drops as a ticket.
// Precedence: legacy < supplemental < canonical-flat < profile < ServerProfiles < AppProfiles
#define PM_PROFILE_PLIST_PATH @"/var/mobile/Library/Preferences/com.dell.promotioncontrol.profile.plist"
#define PM_DARWIN_CHANGED_NOTIFICATION CFSTR("com.dell.promotioncontrol.changed")
#define PM_DARWIN_THERMAL_NOTIFICATION CFSTR("com.dell.promotioncontrol.thermal-state")

// ============================================================================
// 8.0: RANGE CONSTANTS — floor is 10, ceiling is 240, target is user-picked.
// Range = [10, 240, target]. Getter spoof returns target verbatim.
// ============================================================================
#define PM_LOCKED_FLOOR_HZ 10.0
#define PM_LOCKED_CEILING_HZ 240.0
#define PM_LOCKED_TARGET_DEFAULT 120
#define PM_LOCKED_TARGET_MIN 10
#define PM_LOCKED_TARGET_MAX 240

// ============================================================================
// Logging
// ============================================================================
static atomic_uint_fast64_t g_PMLogBudget = 0;
static atomic_uint_fast64_t g_PMLogDropped = 0;
static os_unfair_lock g_PMLogLock = OS_UNFAIR_LOCK_INIT;

static inline void PMLogReset(atomic_uint_fast64_t budget) {
    atomic_store_explicit(&g_PMLogBudget, budget, memory_order_release);
}
static inline BOOL PMLogBudgetTake(void) {
    uint64_t current = atomic_load_explicit(&g_PMLogBudget, memory_order_acquire);
    while (current > 0) {
        if (atomic_compare_exchange_weak_explicit(&g_PMLogBudget, &current,
                                                  current - 1,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            return YES;
        }
    }
    atomic_fetch_add_explicit(&g_PMLogDropped, 1, memory_order_relaxed);
    return NO;
}
static void PMLog(NSString *format, ...) {
    if (!PMLogBudgetTake()) return;
    @autoreleasepool {
        va_list args; va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        os_unfair_lock_lock(&g_PMLogLock);
        NSLog(@"[ProMotionControl/%@] %@", PM_BUILD_VERSION, message);
        os_unfair_lock_unlock(&g_PMLogLock);
    }
}
static void PMLogCritical(NSString *format, ...) {
    @autoreleasepool {
        va_list args; va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        os_unfair_lock_lock(&g_PMLogLock);
        NSLog(@"[ProMotionControl/CRITICAL/%@] %@", PM_BUILD_VERSION, message);
        os_unfair_lock_unlock(&g_PMLogLock);
    }
}
// ============================================================================
// Metrics
// ============================================================================
typedef struct PMMetrics {
    atomic_uint_fast64_t displayLinkSetRangeHits;
    atomic_uint_fast64_t displayLinkSetFPSHits;
    atomic_uint_fast64_t displayLinkGetRangeHits;
    atomic_uint_fast64_t displayLinkGetFPSHits;
    atomic_uint_fast64_t displayLinkAddToRunLoopHits;
    atomic_uint_fast64_t displayLinkPauseResumeHits;
    atomic_uint_fast64_t displayLinkInitHits;
    atomic_uint_fast64_t displayLinkInvalidateHits;
    atomic_uint_fast64_t animationSetRangeHits;
    atomic_uint_fast64_t animationAddToLayerHits;
    atomic_uint_fast64_t animationGroupAddHits;
    atomic_uint_fast64_t springAnimationHits;
    atomic_uint_fast64_t uiViewAnimateBlockHits;
    atomic_uint_fast64_t scrollViewHits;
    atomic_uint_fast64_t rateAdjustments;
    atomic_uint_fast64_t rateRestores;
    atomic_uint_fast64_t thermalEvents;
    atomic_uint_fast64_t powerEvents;
    atomic_uint_fast64_t foregroundEvents;
    atomic_uint_fast64_t backgroundEvents;
    atomic_uint_fast64_t reassertionTicks;
    atomic_uint_fast64_t antiOverkillRejects;
    atomic_uint_fast64_t exceptionsCaught;
    atomic_uint_fast64_t lockedTierHits;
    atomic_uint_fast64_t hardFloorEnforcements;
    atomic_uint_fast64_t driverWriteAttempts;
    atomic_uint_fast64_t driverWriteSuccesses;
    atomic_uint_fast64_t swapIntervalWrites;
    atomic_uint_fast64_t screenMaxSpoofHits;
    atomic_uint_fast64_t displayModeWrites;
    atomic_uint_fast64_t panelOverrideAttempts;
    atomic_uint_fast64_t panelOverrideFailures;
    atomic_uint_fast64_t spoofGetterHits;
    atomic_uint_fast64_t profilePlistLoads;   // 8.0.1t
    atomic_uint_fast64_t droppedLogs; // Sửa lỗi: Thêm biến droppedLogs vào struct
} PMMetrics;
static PMMetrics g_PMMetrics = {0};
#define PM_METRIC_BUMP(field) \
    atomic_fetch_add_explicit(&g_PMMetrics.field, 1, memory_order_relaxed)

__attribute__((visibility("default"), used))
uint64_t PMControlTweakDroppedLogs(void) {
    return atomic_load_explicit(&g_PMMetrics.droppedLogs, memory_order_acquire); // Sửa lỗi tên biến metric
}

__attribute__((visibility("default"), used))
uint64_t PMControlTweakMetric(const char *name) {
    if (!name) return 0;
    NSString *key = [NSString stringWithUTF8String:name];
    if ([key isEqualToString:@"displayLinkSetRangeHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkSetRangeHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkSetFPSHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkSetFPSHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkGetRangeHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkGetRangeHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkGetFPSHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkGetFPSHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkAddToRunLoopHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkAddToRunLoopHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkPauseResumeHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkPauseResumeHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkInitHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkInitHits, memory_order_acquire);
    if ([key isEqualToString:@"displayLinkInvalidateHits"]) return atomic_load_explicit(&g_PMMetrics.displayLinkInvalidateHits, memory_order_acquire);
    if ([key isEqualToString:@"animationSetRangeHits"]) return atomic_load_explicit(&g_PMMetrics.animationSetRangeHits, memory_order_acquire);
    if ([key isEqualToString:@"animationAddToLayerHits"]) return atomic_load_explicit(&g_PMMetrics.animationAddToLayerHits, memory_order_acquire);
    if ([key isEqualToString:@"animationGroupAddHits"]) return atomic_load_explicit(&g_PMMetrics.animationGroupAddHits, memory_order_acquire);
    if ([key isEqualToString:@"springAnimationHits"]) return atomic_load_explicit(&g_PMMetrics.springAnimationHits, memory_order_acquire);
    if ([key isEqualToString:@"uiViewAnimateBlockHits"]) return atomic_load_explicit(&g_PMMetrics.uiViewAnimateBlockHits, memory_order_acquire);
    if ([key isEqualToString:@"scrollViewHits"]) return atomic_load_explicit(&g_PMMetrics.scrollViewHits, memory_order_acquire);
    if ([key isEqualToString:@"rateAdjustments"]) return atomic_load_explicit(&g_PMMetrics.rateAdjustments, memory_order_acquire);
    if ([key isEqualToString:@"rateRestores"]) return atomic_load_explicit(&g_PMMetrics.rateRestores, memory_order_acquire);
    if ([key isEqualToString:@"thermalEvents"]) return atomic_load_explicit(&g_PMMetrics.thermalEvents, memory_order_acquire);
    if ([key isEqualToString:@"powerEvents"]) return atomic_load_explicit(&g_PMMetrics.powerEvents, memory_order_acquire);
    if ([key isEqualToString:@"foregroundEvents"]) return atomic_load_explicit(&g_PMMetrics.foregroundEvents, memory_order_acquire);
    if ([key isEqualToString:@"backgroundEvents"]) return atomic_load_explicit(&g_PMMetrics.backgroundEvents, memory_order_acquire);
    if ([key isEqualToString:@"reassertionTicks"]) return atomic_load_explicit(&g_PMMetrics.reassertionTicks, memory_order_acquire);
    if ([key isEqualToString:@"antiOverkillRejects"]) return atomic_load_explicit(&g_PMMetrics.antiOverkillRejects, memory_order_acquire);
    if ([key isEqualToString:@"exceptionsCaught"]) return atomic_load_explicit(&g_PMMetrics.exceptionsCaught, memory_order_acquire);
    if ([key isEqualToString:@"lockedTierHits"]) return atomic_load_explicit(&g_PMMetrics.lockedTierHits, memory_order_acquire);
    if ([key isEqualToString:@"hardFloorEnforcements"]) return atomic_load_explicit(&g_PMMetrics.hardFloorEnforcements, memory_order_acquire);
    if ([key isEqualToString:@"driverWriteAttempts"]) return atomic_load_explicit(&g_PMMetrics.driverWriteAttempts, memory_order_acquire);
    if ([key isEqualToString:@"driverWriteSuccesses"]) return atomic_load_explicit(&g_PMMetrics.driverWriteSuccesses, memory_order_acquire);
    if ([key isEqualToString:@"swapIntervalWrites"]) return atomic_load_explicit(&g_PMMetrics.swapIntervalWrites, memory_order_acquire);
    if ([key isEqualToString:@"screenMaxSpoofHits"]) return atomic_load_explicit(&g_PMMetrics.screenMaxSpoofHits, memory_order_acquire);
    if ([key isEqualToString:@"displayModeWrites"]) return atomic_load_explicit(&g_PMMetrics.displayModeWrites, memory_order_acquire);
    if ([key isEqualToString:@"panelOverrideAttempts"]) return atomic_load_explicit(&g_PMMetrics.panelOverrideAttempts, memory_order_acquire);
    if ([key isEqualToString:@"panelOverrideFailures"]) return atomic_load_explicit(&g_PMMetrics.panelOverrideFailures, memory_order_acquire);
    if ([key isEqualToString:@"spoofGetterHits"]) return atomic_load_explicit(&g_PMMetrics.spoofGetterHits, memory_order_acquire);
    if ([key isEqualToString:@"profilePlistLoads"]) return atomic_load_explicit(&g_PMMetrics.profilePlistLoads, memory_order_acquire);
    if ([key isEqualToString:@"droppedLogs"]) return atomic_load_explicit(&g_PMMetrics.droppedLogs, memory_order_acquire); // Sửa lỗi
    return 0;
}

// ============================================================================
// Exception handler
// ============================================================================
static NSUncaughtExceptionHandler *PMPreviousUncaughtExceptionHandler = NULL;
static BOOL PMSafetyExceptionHandlerInstalled = NO;
static os_unfair_lock g_PMExceptionLock = OS_UNFAIR_LOCK_INIT;
static void PMGlobalUncaughtExceptionHandler(NSException *exception) {
    PM_METRIC_BUMP(exceptionsCaught);
    PMLogCritical(@"Uncaught ObjC exception: %@ reason=%@", exception.name, exception.reason);
    if (PMPreviousUncaughtExceptionHandler &&
        PMPreviousUncaughtExceptionHandler != &PMGlobalUncaughtExceptionHandler) {
        PMPreviousUncaughtExceptionHandler(exception);
    }
}
static void PMInstallSafetyExceptionHandler(void) {
    os_unfair_lock_lock(&g_PMExceptionLock);
    if (PMSafetyExceptionHandlerInstalled) {
        os_unfair_lock_unlock(&g_PMExceptionLock); return;
    }
    NSUncaughtExceptionHandler *previous = NSGetUncaughtExceptionHandler();
    if (previous == &PMGlobalUncaughtExceptionHandler) {
        PMSafetyExceptionHandlerInstalled = YES;
        os_unfair_lock_unlock(&g_PMExceptionLock); return;
    }
    PMPreviousUncaughtExceptionHandler = previous;
    NSSetUncaughtExceptionHandler(&PMGlobalUncaughtExceptionHandler);
    PMSafetyExceptionHandlerInstalled = YES;
    os_unfair_lock_unlock(&g_PMExceptionLock);
}
#define PM_SAFE_TRY(...) \
    @try { __VA_ARGS__ } \
    @catch (NSException *exception) { \
        PM_METRIC_BUMP(exceptionsCaught); \
        PMLog(@"ObjC exception: %@ reason=%@", exception.name, exception.reason); \
    } @catch (...) { \
        PM_METRIC_BUMP(exceptionsCaught); \
        PMLog(@"Non-NSException swallowed"); \
    }

// ============================================================================
// Process isolation
// ============================================================================
static BOOL PMExecutableLooksLikeInstalledAppProcess(void) {
    @try {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *bundleID = bundle.bundleIdentifier ?: @"";
        NSString *bundlePath = [[bundle.bundlePath stringByStandardizingPath] copy] ?: @"";
        NSString *executablePath = [[bundle.executablePath stringByStandardizingPath] copy] ?: @"";
        if (![bundleID isEqualToString:@"com.dell.promotioncontrol.app"]) return NO;
        if (bundlePath.length == 0 || executablePath.length == 0) return NO;
        if (![bundlePath hasPrefix:@"/Applications/ProMotionControl.app/"] &&
            ![bundlePath isEqualToString:@"/Applications/ProMotionControl.app"]) return NO;
        if (![executablePath hasPrefix:@"/Applications/ProMotionControl.app/"]) return NO;
        NSDictionary *env = NSProcessInfo.processInfo.environment ?: @{};
        if (env[@"XCTestConfigurationFilePath"] || env[@"XCInjectBundleInto"]) return NO;
        if (env[@"DYLD_INSERT_LIBRARIES"] && [env[@"DYLD_INSERT_LIBRARIES"] containsString:@"XCTest"]) return NO;
        BOOL debuggerOverride = [[NSFileManager defaultManager] fileExistsAtPath:
            @"/var/mobile/Library/Preferences/.com.dell.promotioncontrol.allow-debugger"];
        if (!debuggerOverride) {
            int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
            struct kinfo_proc info;
            size_t size = sizeof(info);
            memset(&info, 0, sizeof(info));
            if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
                if (info.kp_proc.p_flag & P_TRACED) return NO;
            }
        }
        return YES;
    } @catch (NSException *exception) {
        PMLog(@"Identity check failed closed: %@", exception); return NO;
    } @catch (...) { return NO; }
}

// ============================================================================
// Preferences
// ============================================================================
static NSDictionary *PMLegacyFilzaPreferenceCachedSnapshot(void) {
    @try {
        NSMutableDictionary *merged = [NSMutableDictionary dictionary];
        NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:PM_LEGACY_PREFS_PATH];
        NSDictionary *supplemental = [NSDictionary dictionaryWithContentsOfFile:PM_SUPPLEMENTAL_PREFS_PATH];
        NSDictionary *canonical = [NSDictionary dictionaryWithContentsOfFile:PM_PREFS_PATH];
        if ([legacy isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:legacy];
        if ([supplemental isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:supplemental];
        if ([canonical isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:canonical];
        return [merged copy];
    } @catch (NSException *exception) {
        PMLog(@"Prefs read failed: %@", exception); return @{};
    } @catch (...) { return @{}; }
}
static NSDictionary *PMPreferencesForSelectedServer(NSDictionary *rootPreferences) {
    if (![rootPreferences isKindOfClass:[NSDictionary class]]) return @{};
    NSInteger mode = 0;
    id rawMode = rootPreferences[@"ActiveServerMode"];
    if ([rawMode respondsToSelector:@selector(integerValue)]) mode = [rawMode integerValue];
    else if ([rawMode isKindOfClass:[NSString class]]) mode = [(NSString *)rawMode integerValue];
    mode = MIN(MAX(mode, 0), 3);
    NSString *profileName = mode == 3 ? @"LOCKED" : (mode == 2 ? @"ADMIN" : (mode == 1 ? @"PREMIUM" : @"FREE"));
    NSDictionary *profiles = [rootPreferences[@"ServerProfiles"] isKindOfClass:[NSDictionary class]]
        ? rootPreferences[@"ServerProfiles"] : @{};
    NSDictionary *selected = [profiles[profileName] isKindOfClass:[NSDictionary class]]
        ? profiles[profileName] : @{};
    NSMutableDictionary *resolved = [rootPreferences mutableCopy];
    [resolved addEntriesFromDictionary:selected];
    resolved[@"ActiveServerMode"] = @(mode);
    return [resolved copy];
}

// ============================================================================
// 8.0.1t: PROFILE PLIST PARSER — turns Ultra/High/Balanced/Battery + flat keys
// into a dict that merges like any other pref source (wins over canonical flat,
// loses to ServerProfiles selected tier + per-app AppProfiles overrides).
// ============================================================================

// Maps profile name to its default policy deltas. Unknown names → empty dict
// so the caller can still read FPS/RefreshRate/GameMode from the plist body.
static NSDictionary *PMProfilePolicyOverrides(NSString *profile) {
    if (![profile isKindOfClass:[NSString class]] || profile.length == 0) return @{};
    NSString *p = [profile lowercaseString];
    if ([p isEqualToString:@"ultra"]) {
        return @{
            @"ExactRateEnforcement": @YES,
            @"SpoofGetters": @YES,
            @"SpoofScreenMax": @YES,
            @"DriverOverride": @YES,
            @"AggressiveReassert": @YES,
            @"ScrollShield": @YES,
            @"ForegroundOnly": @NO,
            @"ForceMaxDisplayRate": @YES,      // Kích hoạt ForceMaxDisplayRate cho profile Ultra
            @"DisableThermalThrottle": @YES,   // Kích hoạt DisableThermalThrottle cho profile Ultra
            @"OverclockCPU": @YES,             // Kích hoạt OverclockCPU cho profile Ultra
            @"OverclockGPU": @YES              // Kích hoạt OverclockGPU cho profile Ultra
        };
    }
    if ([p isEqualToString:@"high"]) {
        return @{
            @"ExactRateEnforcement": @YES,
            @"SpoofGetters": @YES,
            @"SpoofScreenMax": @YES,
            @"DriverOverride": @YES,
            @"AggressiveReassert": @NO,
            @"ScrollShield": @YES,
            @"ForegroundOnly": @YES,
            @"ForceMaxDisplayRate": @YES,      // Kích hoạt ForceMaxDisplayRate cho profile High
            @"DisableThermalThrottle": @NO,
            @"OverclockCPU": @NO,
            @"OverclockGPU": @NO
        };
    }
    if ([p isEqualToString:@"balanced"]) {
        return @{
            @"ExactRateEnforcement": @NO,
            @"SpoofGetters": @NO,
            @"SpoofScreenMax": @YES,
            @"DriverOverride": @NO,
            @"ScrollShield": @YES,
            @"ForegroundOnly": @YES,
            @"ForceMaxDisplayRate": @NO,
            @"DisableThermalThrottle": @NO,
            @"OverclockCPU": @NO,
            @"OverclockGPU": @NO
        };
    }
    if ([p isEqualToString:@"battery"]) {
        return @{
            @"ExactRateEnforcement": @NO,
            @"SpoofGetters": @NO,
            @"SpoofScreenMax": @NO,
            @"DriverOverride": @NO,
            @"ScrollShield": @NO,
            @"ForegroundOnly": @YES,
            @"ForceMaxDisplayRate": @NO,
            @"DisableThermalThrottle": @NO,
            @"OverclockCPU": @NO,
            @"OverclockGPU": @NO
        };
    }
    return @{};
}

// Reads PM_PROFILE_PLIST_PATH, merges profile-name policy + flat keys, and
// returns a dict meant to be layered over the canonical flat prefs. Fail-closed:
// a corrupt or missing file returns @{} and the runtime falls back to canonical.
static NSDictionary *PMLoadProfilePlist(void) {
    @try {
        NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:PM_PROFILE_PLIST_PATH];
        if (![raw isKindOfClass:[NSDictionary class]] || raw.count == 0) return @{};
        PM_METRIC_BUMP(profilePlistLoads);
        NSMutableDictionary *out = [NSMutableDictionary dictionary];

        // Profile name → policy flags
        NSString *profileName = [raw[@"Profile"] isKindOfClass:[NSString class]] ? raw[@"Profile"] : nil;
        NSDictionary *policy = PMProfilePolicyOverrides(profileName);
        for (NSString *k in policy) out[k] = policy[k];

        // RefreshRate → RefreshMode/CustomRefreshRate (10..240 clamp)
        id rawHz = raw[@"RefreshRate"];
        if ([rawHz respondsToSelector:@selector(integerValue)]) {
            NSInteger hz = MIN(MAX([rawHz integerValue], 10), 240);
            out[@"RefreshRateEnabled"] = @YES;
            out[@"RefreshMode"] = @(hz);
            out[@"CustomRefreshRate"] = @(hz);
        }

        // FPS → FPSMode/CustomFPS (10..240 clamp)
        id rawFPS = raw[@"FPS"];
        if ([rawFPS respondsToSelector:@selector(integerValue)]) {
            NSInteger fps = MIN(MAX([rawFPS integerValue], 10), 240);
            out[@"FPSOverrideEnabled"] = @YES;
            out[@"FPSMode"] = @(fps);
            out[@"CustomFPS"] = @(fps);
        }

        // Adaptive → disables ExactRateEnforcement unless profile is Ultra
        // (Ultra explicitly sets exact YES; adaptive only matters for High/Bal/etc).
        id rawAdaptive = raw[@"Adaptive"];
        BOOL adaptive = [rawAdaptive respondsToSelector:@selector(boolValue)] ? [rawAdaptive boolValue] : NO;
        if (adaptive && ![profileName.lowercaseString isEqualToString:@"ultra"]) {
            out[@"ExactRateEnforcement"] = @NO;
        }

        // GameMode → ScrollShield + AggressiveReassert + ForegroundOnly
        id rawGameMode = raw[@"GameMode"];
        BOOL gameMode = [rawGameMode respondsToSelector:@selector(boolValue)] ? [rawGameMode boolValue] : NO;
        if (gameMode) {
            out[@"ScrollShield"] = @YES;
            out[@"AggressiveReassert"] = @YES;
            out[@"ForegroundOnly"] = @YES;
        }

        // Explicit override keys win over profile-name policy
        NSArray<NSString *> *passthroughKeys = @[
            @"ExactRateEnforcement", @"SpoofGetters", @"SpoofScreenMax",
            @"DriverOverride", @"PanelOverride", @"LockedOverrideThermal",
            @"AggressiveReassert", @"ScrollShield", @"ForegroundOnly",
            @"HardLock", @"LockedTarget", @"Enabled",
            @"AdvancedDisplayEnforcement", @"FramePacing",
            @"ZeroFluff", @"DriverTargetRate",
            // Thêm các cờ mới
            @"ForceMaxDisplayRate", @"DisableThermalThrottle", @"OverclockCPU", @"OverclockGPU"
        ];
        for (NSString *key in passthroughKeys) {
            id v = raw[key];
            if (v) out[key] = v;
        }

        // GameMode without explicit LockedTarget: adopt FPS as the locked target
        // and turn HardLock on so the 10..240 range matches the declared panel rate.
        if (gameMode && !out[@"LockedTarget"]) {
            id rawFPS2 = raw[@"FPS"];
            if ([rawFPS2 respondsToSelector:@selector(integerValue)]) {
                NSInteger fps = MIN(MAX([rawFPS2 integerValue], 10), 240);
                out[@"LockedTarget"] = @(fps);
                out[@"HardLock"] = @YES;
            }
        }

        PMLog(@"Profile plist loaded: name=%@ hz=%@ fps=%@ adaptive=%d gameMode=%d keys=%lu",
              profileName ?: @"(none)",
              out[@"RefreshMode"] ?: @"(unset)",
              out[@"FPSMode"] ?: @"(unset)",
              adaptive, gameMode, (unsigned long)out.count);
        return [out copy];
    } @catch (NSException *exception) {
        PMLog(@"Profile plist read failed safely: %@", exception);
        return @{};
    } @catch (...) {
        return @{};
    }
}

// ============================================================================
// Runtime state
// ============================================================================
static volatile int32_t g_TweakEnabled = 0;
static volatile int32_t g_TargetFPS = 60;
static volatile int32_t g_TargetHz = 60;
static volatile int32_t g_ActiveServerMode = 0;
static volatile int32_t g_ServerPolicyFlags = 0;
static volatile int32_t g_ExactRateEnforcement = 1;
static volatile int32_t g_HardLockEnabled = 0;
static volatile int32_t g_HardLockFloor = 10;
static volatile int32_t g_HardLockCeiling = 240;
static volatile int32_t g_DriverOverrideEnabled = 0;
static volatile int32_t g_PanelOverrideEnabled = 0;
static volatile int32_t g_SpoofScreenMax = 1;
static volatile int32_t g_SpoofGetters = 1;
static volatile int32_t g_DriverWriteSucceeded = 0;
static volatile int32_t g_DriverTargetRate = 240;
static volatile int32_t g_ForceMaxDisplayRate = 0;      // Biến trạng thái cho Force Max Display Rate
static volatile int32_t g_DisableThermalThrottle = 0;   // Biến trạng thái cho Disable Thermal Throttle
static volatile int32_t g_OverclockCPU = 0;             // Biến trạng thái cho Overclock CPU
static volatile int32_t g_OverclockGPU = 0;             // Biến trạng thái cho Overclock GPU

static BOOL g_IsAppEligible = NO;
static BOOL g_AppEligibilityChecked = NO;
static volatile int32_t g_PreferencesLoaded = 0;
static BOOL g_PMIsScreenCaptured = NO;
static volatile int32_t g_AppHasFinishedLaunching = 0;
static dispatch_queue_t g_PMPreferenceQueue = NULL;
static inline BOOL PMAntiOverkillCheck(NSInteger targetFPS);
static void PMRefreshTrackedDisplayLinks(void);
static NSHashTable<CADisplayLink *> *g_PMTrackedDisplayLinks = nil;
static NSMapTable<CADisplayLink *, NSDictionary *> *g_PMOriginalDisplayLinkRates = nil;
static NSMapTable<CADisplayLink *, NSDictionary *> *g_PMLinkMetadata = nil;
static NSMutableArray *g_PMStateObserverTokens = nil;
static __thread BOOL g_PMApplyingTrackedRate = NO;

static void PMRegisterDisplayLink(CADisplayLink *link) {
    if (![link isKindOfClass:[CADisplayLink class]]) return;
    @synchronized ([CADisplayLink class]) {
        if (!g_PMTrackedDisplayLinks) g_PMTrackedDisplayLinks = [NSHashTable weakObjectsHashTable];
        if (!g_PMOriginalDisplayLinkRates) g_PMOriginalDisplayLinkRates = [NSMapTable weakToStrongObjectsMapTable];
        if (!g_PMLinkMetadata) g_PMLinkMetadata = [NSMapTable weakToStrongObjectsMapTable];
        [g_PMTrackedDisplayLinks addObject:link];
        if (![g_PMOriginalDisplayLinkRates objectForKey:link]) {
            NSMutableDictionary *baseline = [NSMutableDictionary dictionary];
            baseline[@"framesPerSecond"] = @(link.preferredFramesPerSecond);
            baseline[@"registeredAt"] = @([[NSDate date] timeIntervalSince1970]);
            if (@available(iOS 15.0, *)) {
                CAFrameRateRange originalRange = link.preferredFrameRateRange;
                baseline[@"frameRateRange"] = [NSValue valueWithBytes:&originalRange objCType:@encode(CAFrameRateRange)];
            }
            [g_PMOriginalDisplayLinkRates setObject:[baseline copy] forKey:link];
            NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
            metadata[@"createdAt"] = @([[NSDate date] timeIntervalSince1970]);
            metadata[@"bundle"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            metadata[@"thread"] = @((uint64_t)(uintptr_t)[NSThread currentThread]);
            [g_PMLinkMetadata setObject:[metadata copy] forKey:link];
        }
    }
}
static void PMUnregisterDisplayLink(CADisplayLink *link) {
    if (![link isKindOfClass:[CADisplayLink class]]) return;
    @synchronized ([CADisplayLink class]) {
        [g_PMTrackedDisplayLinks removeObject:link];
        [g_PMOriginalDisplayLinkRates removeObjectForKey:link];
        [g_PMLinkMetadata removeObjectForKey:link];
    }
}
static void PMRecordAppDisplayLinkFPS(CADisplayLink *link, NSInteger requestedFPS) {
    if (![link isKindOfClass:[CADisplayLink class]]) return;
    PMRegisterDisplayLink(link);
    @synchronized ([CADisplayLink class]) {
        NSMutableDictionary *baseline = [[g_PMOriginalDisplayLinkRates objectForKey:link] mutableCopy] ?: [NSMutableDictionary dictionary];
        baseline[@"framesPerSecond"] = @(requestedFPS);
        baseline[@"lastAppRequest"] = @([[NSDate date] timeIntervalSince1970]);
        [baseline removeObjectForKey:@"frameRateRange"];
        [g_PMOriginalDisplayLinkRates setObject:[baseline copy] forKey:link];
    }
}
static void PMRecordAppDisplayLinkRange(CADisplayLink *link, CAFrameRateRange requestedRange) {
    if (![link isKindOfClass:[CADisplayLink class]]) return;
    PMRegisterDisplayLink(link);
    @synchronized ([CADisplayLink class]) {
        NSMutableDictionary *baseline = [[g_PMOriginalDisplayLinkRates objectForKey:link] mutableCopy] ?: [NSMutableDictionary dictionary];
        baseline[@"framesPerSecond"] = @(link.preferredFramesPerSecond);
        baseline[@"frameRateRange"] = [NSValue valueWithBytes:&requestedRange objCType:@encode(CAFrameRateRange)];
        baseline[@"lastAppRequest"] = @([[NSDate date] timeIntervalSince1970]);
        [g_PMOriginalDisplayLinkRates setObject:[baseline copy] forKey:link];
    }
}

// ============================================================================
// Policy flags
// ============================================================================
enum {
    PMPolicyThermalGuard = 1 << 0,
    PMPolicyLowLatency = 1 << 1,
    PMPolicyAdaptiveCadence = 1 << 2,
    PMPolicyPremiumTier4Display = 1 << 3,
    PMPolicyAdminTitaniumRateAdapter = 1 << 4,
    PMPolicyAggressiveReassert = 1 << 5,
    PMPolicyScrollShield = 1 << 6,
    PMPolicyForegroundOnly = 1 << 7,
    PMPolicyHardLock = 1 << 8,
    PMPolicyForceMinimum = 1 << 9,
    PMPolicyForceMaximum = 1 << 10,
    PMPolicyLockedOverrideThermal = 1 << 11,
    PMPolicyDriverOverride = 1 << 12,
    PMPolicyPanelOverride = 1 << 13,
    PMPolicySpoofScreenMax = 1 << 14,
    PMPolicyZeroFluff = 1 << 15,
    PMPolicySpoofGetters = 1 << 16,
    PMPolicyForceMaxDisplayRate = 1 << 17,    // Cờ cho Force Max Display Rate
    PMPolicyDisableThermalThrottle = 1 << 18, // Cờ cho Disable Thermal Throttle
    PMPolicyOverclockCPU = 1 << 19,           // Cờ cho Overclock CPU
    PMPolicyOverclockGPU = 1 << 20            // Cờ cho Overclock GPU
};

static inline BOOL PMPolicyEnabled(int32_t flag) {
    return (__atomic_load_n(&g_ServerPolicyFlags, __ATOMIC_ACQUIRE) & flag) != 0;
}
static inline BOOL PMHasFinishedLaunchDelay(void) {
    return __atomic_load_n(&g_AppHasFinishedLaunching, __ATOMIC_ACQUIRE) != 0;
}
static BOOL PMCheckAppEligibility(void) {
    if (!g_AppEligibilityChecked) {
        g_IsAppEligible = PMExecutableLooksLikeInstalledAppProcess();
        g_AppEligibilityChecked = YES;
    }
    return g_IsAppEligible;
}
static NSInteger PMReadConfiguredRate(NSDictionary *prefs, NSString *modeKey, NSString *customKey) {
    id rawMode = prefs[modeKey];
    NSInteger mode = [rawMode respondsToSelector:@selector(integerValue)] ? [rawMode integerValue] : 0;
    NSInteger result = 0;
    if (mode == -1) {
        id rawCustom = prefs[customKey];
        NSInteger custom = [rawCustom respondsToSelector:@selector(integerValue)] ? [rawCustom integerValue] : 60;
        result = custom;
    } else if (mode > 0) {
        result = mode;
    }
    return MIN(MAX(result, 10), 240);
}
static BOOL PMPreferenceBoolean(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}
static NSString *PMCurrentBundleIdentifier(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    return [bundleID isKindOfClass:[NSString class]] ? bundleID : @"";
}
static NSDictionary *PMEffectivePreferencesForCurrentApp(NSDictionary *basePreferences) {
    if (![basePreferences isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *effective = [basePreferences mutableCopy];
    NSString *bundleID = PMCurrentBundleIdentifier();
    NSDictionary *appProfiles = [basePreferences[@"AppProfiles"] isKindOfClass:[NSDictionary class]]
        ? basePreferences[@"AppProfiles"] : @{};
    NSDictionary *appProfile = [appProfiles[bundleID] isKindOfClass:[NSDictionary class]]
        ? appProfiles[bundleID] : @{};
    NSString *profileName = [appProfile[@"profile"] isKindOfClass:[NSString class]]
        ? appProfile[@"profile"] : ([basePreferences[@"profile"] isKindOfClass:[NSString class]]
            ? basePreferences[@"profile"] : @"");
    NSDictionary *namedProfiles = [basePreferences[@"profiles"] isKindOfClass:[NSDictionary class]]
        ? basePreferences[@"profiles"] : @{};
    NSDictionary *namedProfile = [namedProfiles[profileName] isKindOfClass:[NSDictionary class]]
        ? namedProfiles[profileName] : @{};
    NSArray<NSString *> *allowedKeys = @[
        @"Enabled", @"RefreshRateEnabled", @"FPSOverrideEnabled",
        @"AdvancedDisplayEnforcement", @"FramePacing", @"ExactRateEnforcement",
        @"RefreshMode", @"FPSMode", @"CustomRefreshRate", @"CustomFPS",
        @"AggressiveReassert", @"ScrollShield", @"ForegroundOnly",
        @"SafeMode", @"DisableAnimations",
        @"HardLock", @"HardLockFloor", @"HardLockCeiling",
        @"LockedTarget", @"LockedOverrideThermal",
        @"DriverOverride", @"PanelOverride", @"SpoofScreenMax",
        @"DriverTargetRate", @"ZeroFluff",
        @"ForceMinimum", @"ForceMaximum", @"SpoofGetters",
        // Thêm các cờ mới
        @"ForceMaxDisplayRate", @"DisableThermalThrottle", @"OverclockCPU", @"OverclockGPU"
    ];
    for (NSString *key in allowedKeys) {
        id profileValue = namedProfile[key];
        if (profileValue) effective[key] = profileValue;
        id appValue = appProfile[key];
        if (appValue) effective[key] = appValue;
    }
    return [effective copy];
}

// ============================================================================
// IOMobileFramebuffer driver pipeline
// ============================================================================
static IOMobileFramebufferRef g_PMFramebufferRef = NULL;
static BOOL PMOpenMainFramebuffer(void) {
    if (g_PMFramebufferRef) return YES;
    if (!g_IOMFBOpen || !g_IOSvcMatching || !g_IOSvcGetMatching) {
        PM_METRIC_BUMP(panelOverrideFailures); return NO;
    }
    @try {
        CFMutableDictionaryRef matching = g_IOSvcMatching("AppleMobileDisp");
        if (!matching) { PM_METRIC_BUMP(panelOverrideFailures); return NO; }
        io_service_t service = g_IOSvcGetMatching(kIOMasterPortDefault, matching);
        CFRelease(matching);
        if (!service) { PM_METRIC_BUMP(panelOverrideFailures); return NO; }
        IOMobileFramebufferRef fb = NULL;
        int kr = g_IOMFBOpen(service, mach_task_self(), 0, &fb);
        IOObjectRelease(service);
        if (kr != KERN_SUCCESS || !fb) { PM_METRIC_BUMP(panelOverrideFailures); return NO; }
        g_PMFramebufferRef = fb;
        return YES;
    } @catch (NSException *e) { PM_METRIC_BUMP(panelOverrideFailures); return NO; }
    @catch (...) { PM_METRIC_BUMP(panelOverrideFailures); return NO; }
}
static BOOL PMWriteSwapInterval(int32_t interval) {
    if (!g_PMFramebufferRef || !g_IOMFBSetSwapInt) return NO;
    PM_METRIC_BUMP(driverWriteAttempts);
    int kr = g_IOMFBSetSwapInt(g_PMFramebufferRef, interval);
    if (kr == KERN_SUCCESS) {
        PM_METRIC_BUMP(driverWriteSuccesses);
        PM_METRIC_BUMP(swapIntervalWrites);
        __atomic_store_n(&g_DriverWriteSucceeded, 1, __ATOMIC_RELEASE);
        return YES;
    }
    return NO;
}
static BOOL PMWriteDisplayMode(uint32_t mode) {
    if (!g_PMFramebufferRef || !g_IOMFBSetMode) return NO;
    PM_METRIC_BUMP(panelOverrideAttempts);
    int kr = g_IOMFBSetMode(g_PMFramebufferRef, mode);
    if (kr == KERN_SUCCESS) { PM_METRIC_BUMP(displayModeWrites); return YES; }
    PM_METRIC_BUMP(panelOverrideFailures);
    return NO;
}
static void PMAttemptDriverOverride(NSInteger targetHz) {
    if (!PMPolicyEnabled(PMPolicyDriverOverride) && !PMPolicyEnabled(PMPolicyPanelOverride)) return;
    if (!PMOpenMainFramebuffer()) return;
    NSInteger clampedHz = MAX(10, MIN(targetHz, 240));
    __atomic_store_n(&g_DriverTargetRate, (int32_t)clampedHz, __ATOMIC_RELEASE);
    if (PMPolicyEnabled(PMPolicyDriverOverride)) {
        if (!PMWriteSwapInterval(1)) PMWriteSwapInterval(2);
    }
    if (PMPolicyEnabled(PMPolicyPanelOverride)) {
        for (uint32_t mode = 0; mode < 8; mode++) {
            if (PMWriteDisplayMode(mode)) break;
        }
    }
}

// ============================================================================
// Load preferences — 8.0.1t: profile plist merged at the correct layer.
// Precedence: legacy < supplemental < canonical-flat < profile < ServerProfiles < AppProfiles
// ============================================================================
static void PMLoadPreferencesSync(void) {
    if (__atomic_load_n(&g_PreferencesLoaded, __ATOMIC_ACQUIRE)) return;
    @try {
        // Layer 1-3: legacy < supplemental < canonical (from helper).
        NSDictionary *rootPrefs = PMLegacyFilzaPreferenceCachedSnapshot();

        // Layer 4: profile plist. Wins over canonical flat keys.
        NSDictionary *profilePrefs = PMLoadProfilePlist();
        NSMutableDictionary *mergedRoot = [rootPrefs mutableCopy] ?: [NSMutableDictionary dictionary];
        [mergedRoot addEntriesFromDictionary:profilePrefs];

        // Layer 5: ServerProfiles selected tier (handled inside PMPreferencesForSelectedServer).
        NSDictionary *basePrefs = PMPreferencesForSelectedServer([mergedRoot copy]);

        // Layer 6: named profiles + per-app AppProfiles (handled inside helper).
        NSDictionary *prefs = PMEffectivePreferencesForCurrentApp(basePrefs);

        NSInteger serverMode = [basePrefs[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)]
            ? MIN(MAX([basePrefs[@"ActiveServerMode"] integerValue], 0), 3) : 0;

        BOOL tierSchedulerEnabled = YES, tierRuntimeHookEnabled = YES;
        switch (serverMode) {
            case 3:
                tierSchedulerEnabled = PMPreferenceBoolean(basePrefs, @"LockedRenderSchedulerEnabled", YES);
                tierRuntimeHookEnabled = PMPreferenceBoolean(basePrefs, @"LockedCADisplayLinkHookEnabled", YES);
                break;
            case 2:
                tierSchedulerEnabled = PMPreferenceBoolean(basePrefs, @"AdminRenderSchedulerEnabled", YES);
                tierRuntimeHookEnabled = PMPreferenceBoolean(basePrefs, @"AdminCADisplayLinkHookEnabled", YES);
                break;
            case 1:
                tierSchedulerEnabled = PMPreferenceBoolean(basePrefs, @"PremiumRenderSchedulerEnabled", YES);
                tierRuntimeHookEnabled = PMPreferenceBoolean(basePrefs, @"PremiumCADisplayLinkHookEnabled", YES);
                break;
            default:
                tierSchedulerEnabled = PMPreferenceBoolean(basePrefs, @"FreeRenderSchedulerEnabled", YES);
                tierRuntimeHookEnabled = PMPreferenceBoolean(basePrefs, @"FreeCADisplayLinkHookEnabled", YES);
                break;
        }

        BOOL thermalGuard = NO, lowLatency = NO, adaptiveCadence = NO;
        BOOL premiumTier4Display = NO, adminTitaniumRateAdapter = NO;
        BOOL aggressiveReassert = NO, scrollShield = NO, foregroundOnly = NO;
        BOOL hardLock = NO, forceMinimum = NO, forceMaximum = NO;
        BOOL lockedOverrideThermal = NO;
        BOOL driverOverride = NO, panelOverride = NO, spoofScreenMax = YES, zeroFluff = NO;
        BOOL spoofGetters = YES;

        // Các cờ mới cần đọc từ preferences
        BOOL forceMaxDisplayRate = NO;
        BOOL disableThermalThrottle = NO;
        BOOL overclockCPU = NO;
        BOOL overclockGPU = NO;

        switch (serverMode) {
            case 3: {
                thermalGuard = PMPreferenceBoolean(basePrefs, @"LockedThermalCooldownEnabled", NO);
                adminTitaniumRateAdapter = PMPreferenceBoolean(basePrefs, @"LockedTitaniumHardwareRateAdapterEnabled", YES);
                aggressiveReassert = PMPreferenceBoolean(basePrefs, @"LockedAggressiveReassertEnabled", YES);
                scrollShield = PMPreferenceBoolean(basePrefs, @"LockedScrollShieldEnabled", YES);
                hardLock = PMPreferenceBoolean(basePrefs, @"LockedHardLockEnabled", YES);
                forceMinimum = PMPreferenceBoolean(basePrefs, @"LockedForceMinimum", NO);
                forceMaximum = PMPreferenceBoolean(basePrefs, @"LockedForceMaximum", YES);
                lockedOverrideThermal = PMPreferenceBoolean(basePrefs, @"LockedOverrideThermal", NO);
                driverOverride = PMPreferenceBoolean(basePrefs, @"LockedDriverOverride", YES);
                panelOverride = PMPreferenceBoolean(basePrefs, @"LockedPanelOverride", YES);
                zeroFluff = PMPreferenceBoolean(basePrefs, @"LockedZeroFluff", YES);
                spoofGetters = PMPreferenceBoolean(basePrefs, @"LockedSpoofGetters", YES);
                // Đọc các cờ mới cho chế độ LOCKED
                forceMaxDisplayRate = PMPreferenceBoolean(basePrefs, @"LockedForceMaxDisplayRate", NO);
                disableThermalThrottle = PMPreferenceBoolean(basePrefs, @"LockedDisableThermalThrottle", NO);
                overclockCPU = PMPreferenceBoolean(basePrefs, @"LockedOverclockCPU", NO);
                overclockGPU = PMPreferenceBoolean(basePrefs, @"LockedOverclockGPU", NO);
                break;
            }
            case 2: { // ADMIN
                thermalGuard = PMPreferenceBoolean(basePrefs, @"AdminThermalCooldownEnabled", YES);
                adaptiveCadence = PMPreferenceBoolean(basePrefs, @"AdminAdaptiveFramePacingEnabled", YES);
                adminTitaniumRateAdapter = PMPreferenceBoolean(basePrefs, @"AdminTitaniumHardwareRateAdapterEnabled", YES);
                aggressiveReassert = PMPreferenceBoolean(basePrefs, @"AdminAggressiveReassertEnabled", NO);
                scrollShield = PMPreferenceBoolean(basePrefs, @"AdminScrollShieldEnabled", YES);
                hardLock = PMPreferenceBoolean(basePrefs, @"AdminHardLockEnabled", NO);
                forceMinimum = PMPreferenceBoolean(basePrefs, @"AdminForceMinimum", NO);
                forceMaximum = PMPreferenceBoolean(basePrefs, @"AdminForceMaximum", NO);
                driverOverride = PMPreferenceBoolean(basePrefs, @"AdminDriverOverride", NO);
                panelOverride = PMPreferenceBoolean(basePrefs, @"AdminPanelOverride", NO);
                spoofGetters = PMPreferenceBoolean(basePrefs, @"AdminSpoofGetters", NO);
                // Đọc các cờ mới cho chế độ ADMIN
                forceMaxDisplayRate = PMPreferenceBoolean(prefs, @"ForceMaxDisplayRate", NO);
                disableThermalThrottle = PMPreferenceBoolean(prefs, @"DisableThermalThrottle", NO);
                overclockCPU = PMPreferenceBoolean(prefs, @"OverclockCPU", NO);
                overclockGPU = PMPreferenceBoolean(prefs, @"OverclockGPU", NO);
                break;
            }
            case 1: { // PREMIUM
                thermalGuard = PMPreferenceBoolean(basePrefs, @"PremiumThermalGuardEnabled", YES);
                lowLatency = PMPreferenceBoolean(basePrefs, @"PremiumLowLatencyModeEnabled", YES);
                premiumTier4Display = PMPreferenceBoolean(basePrefs, @"PremiumTier4DisplayPolicyEnabled", YES);
                scrollShield = PMPreferenceBoolean(basePrefs, @"PremiumScrollShieldEnabled", YES);
                forceMinimum = PMPreferenceBoolean(basePrefs, @"PremiumForceMinimum", NO);
                spoofGetters = PMPreferenceBoolean(basePrefs, @"PremiumSpoofGetters", NO);
                // Các cờ mới mặc định là NO cho PREMIUM
                forceMaxDisplayRate = PMPreferenceBoolean(prefs, @"ForceMaxDisplayRate", NO);
                disableThermalThrottle = PMPreferenceBoolean(prefs, @"DisableThermalThrottle", NO);
                overclockCPU = PMPreferenceBoolean(prefs, @"OverclockCPU", NO);
                overclockGPU = PMPreferenceBoolean(prefs, @"OverclockGPU", NO);
                break;
            }
            default: { // FREE
                thermalGuard = PMPreferenceBoolean(basePrefs, @"FreeThermalGuardEnabled", YES);
                adaptiveCadence = PMPreferenceBoolean(basePrefs, @"FreeAdaptiveCadenceEnabled", YES);
                forceMinimum = PMPreferenceBoolean(basePrefs, @"FreeForceMinimum", NO);
                spoofGetters = PMPreferenceBoolean(basePrefs, @"FreeSpoofGetters", NO);
                // Các cờ mới mặc định là NO cho FREE
                forceMaxDisplayRate = PMPreferenceBoolean(prefs, @"ForceMaxDisplayRate", NO);
                disableThermalThrottle = PMPreferenceBoolean(prefs, @"DisableThermalThrottle", NO);
                overclockCPU = PMPreferenceBoolean(prefs, @"OverclockCPU", NO);
                overclockGPU = PMPreferenceBoolean(prefs, @"OverclockGPU", NO);
                break;
            }
        }
        foregroundOnly = PMPreferenceBoolean(basePrefs, @"ForegroundOnlyMode", YES);
        if (serverMode == 3) {
            forceMaximum = YES;
            spoofGetters = YES;
            forceMaxDisplayRate = YES; // Kích hoạt mạnh nhất cho LOCKED
            disableThermalThrottle = YES;
            overclockCPU = YES;
            overclockGPU = YES;
        }

        int32_t policyFlags = 0;
        if (thermalGuard) policyFlags |= PMPolicyThermalGuard;
        if (lowLatency) policyFlags |= PMPolicyLowLatency;
        if (adaptiveCadence) policyFlags |= PMPolicyAdaptiveCadence;
        if (premiumTier4Display) policyFlags |= PMPolicyPremiumTier4Display;
        if (adminTitaniumRateAdapter) policyFlags |= PMPolicyAdminTitaniumRateAdapter;
        if (aggressiveReassert) policyFlags |= PMPolicyAggressiveReassert;
        if (scrollShield) policyFlags |= PMPolicyScrollShield;
        if (foregroundOnly) policyFlags |= PMPolicyForegroundOnly;
        if (hardLock) policyFlags |= PMPolicyHardLock;
        if (forceMinimum) policyFlags |= PMPolicyForceMinimum;
        if (forceMaximum) policyFlags |= PMPolicyForceMaximum;
        if (lockedOverrideThermal) policyFlags |= PMPolicyLockedOverrideThermal;
        if (driverOverride) policyFlags |= PMPolicyDriverOverride;
        if (panelOverride) policyFlags |= PMPolicyPanelOverride;
        if (spoofScreenMax) policyFlags |= PMPolicySpoofScreenMax;
        if (zeroFluff) policyFlags |= PMPolicyZeroFluff;
        if (spoofGetters) policyFlags |= PMPolicySpoofGetters;
        if (forceMaxDisplayRate) policyFlags |= PMPolicyForceMaxDisplayRate;        // Ghi cờ vào policyFlags
        if (disableThermalThrottle) policyFlags |= PMPolicyDisableThermalThrottle;  // Ghi cờ vào policyFlags
        if (overclockCPU) policyFlags |= PMPolicyOverclockCPU;                    // Ghi cờ vào policyFlags
        if (overclockGPU) policyFlags |= PMPolicyOverclockGPU;                    // Ghi cờ vào policyFlags


        BOOL enabled = PMPreferenceBoolean(prefs, @"Enabled", PMPreferenceBoolean(prefs, @"enabled", NO));
        BOOL enforcement = PMPreferenceBoolean(prefs, @"AdvancedDisplayEnforcement", YES);
        BOOL framePacing = PMPreferenceBoolean(prefs, @"FramePacing", YES);
        BOOL fpsEnabled = PMPreferenceBoolean(prefs, @"FPSOverrideEnabled", NO);
        BOOL hzEnabled = PMPreferenceBoolean(prefs, @"RefreshRateEnabled", NO);
        NSInteger fpsTarget = fpsEnabled ? PMReadConfiguredRate(prefs, @"FPSMode", @"CustomFPS") : 0;
        NSInteger hzTarget = hzEnabled ? PMReadConfiguredRate(prefs, @"RefreshMode", @"CustomRefreshRate") : 0;
        NSInteger target = 0;
        if (fpsTarget > 0 && hzTarget > 0) target = MIN(fpsTarget, hzTarget);
        else target = MAX(fpsTarget, hzTarget);
        NSInteger requestedHz = hzTarget > 0 ? hzTarget : (fpsTarget > 0 ? fpsTarget : target);
        NSInteger requestedFPS = fpsTarget > 0 ? fpsTarget : (hzTarget > 0 ? hzTarget : target);

        if (target <= 0 && (fpsEnabled || hzEnabled)) {
            id legacyFPS = prefs[@"selectedFPS"] ?: prefs[@"selectedFps"] ?: prefs[@"selectedHz"];
            if ([legacyFPS respondsToSelector:@selector(integerValue)]) {
                target = [legacyFPS integerValue];
                requestedHz = MIN(MAX(target, 10), 244);
                requestedFPS = requestedHz;
            }
        }
        if (hardLock) {
            id rawLockedTarget = prefs[@"LockedTarget"];
            NSInteger lockedTarget = [rawLockedTarget respondsToSelector:@selector(integerValue)]
                ? [rawLockedTarget integerValue] : PM_LOCKED_TARGET_DEFAULT;
            lockedTarget = MIN(MAX(lockedTarget, PM_LOCKED_TARGET_MIN), PM_LOCKED_TARGET_MAX);
            requestedFPS = lockedTarget;
            requestedHz = lockedTarget;
            target = lockedTarget;
        }

        BOOL lockFloorOn = (policyFlags & PMPolicyForceMinimum) != 0;
        BOOL lockCeilOn  = (policyFlags & PMPolicyForceMaximum) != 0;
        if (lockFloorOn) {
            requestedFPS = MAX(requestedFPS, (NSInteger)PM_LOCKED_FLOOR_HZ);
            requestedHz  = MAX(requestedHz,  (NSInteger)PM_LOCKED_FLOOR_HZ);
            target = MAX(target, (NSInteger)PM_LOCKED_FLOOR_HZ);
        }
        if (lockCeilOn) {
            requestedFPS = MIN(requestedFPS, (NSInteger)PM_LOCKED_CEILING_HZ);
            requestedHz  = MIN(requestedHz,  (NSInteger)PM_LOCKED_CEILING_HZ);
            target = MIN(target, (NSInteger)PM_LOCKED_CEILING_HZ);
        }
        // Absolute hard-clamp: never outside [10, 240].
        requestedFPS = MIN(MAX(requestedFPS, 10), 240);
        requestedHz  = MIN(MAX(requestedHz,  10), 240);
        target       = MIN(MAX(target,       10), 240);

        BOOL exactRate = PMPreferenceBoolean(prefs, @"ExactRateEnforcement", YES);
        NSArray *excludedApps = [basePrefs[@"excludedApps"] isKindOfClass:[NSArray class]]
            ? basePrefs[@"excludedApps"] : @[];
        BOOL excludedForServer = [excludedApps containsObject:PMCurrentBundleIdentifier()];
        BOOL active = enabled && enforcement && framePacing && tierSchedulerEnabled &&
                      tierRuntimeHookEnabled && target > 0 && !excludedForServer;
        if (active && !PMAntiOverkillCheck(target)) active = NO;

        __atomic_store_n(&g_ActiveServerMode, (int32_t)serverMode, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ServerPolicyFlags, policyFlags, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ExactRateEnforcement, exactRate ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_TargetFPS, (int32_t)(requestedFPS > 0 ? requestedFPS : 60), __ATOMIC_RELEASE);
        __atomic_store_n(&g_TargetHz, (int32_t)(requestedHz > 0 ? requestedHz : (target > 0 ? target : 60)), __ATOMIC_RELEASE);
        __atomic_store_n(&g_TweakEnabled, active ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_HardLockEnabled, hardLock ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_HardLockFloor, (int32_t)PM_LOCKED_FLOOR_HZ, __ATOMIC_RELEASE);
        __atomic_store_n(&g_HardLockCeiling, (int32_t)PM_LOCKED_CEILING_HZ, __ATOMIC_RELEASE);
        __atomic_store_n(&g_DriverOverrideEnabled, driverOverride ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_PanelOverrideEnabled, panelOverride ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_SpoofScreenMax, spoofScreenMax ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_SpoofGetters, spoofGetters ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ForceMaxDisplayRate, forceMaxDisplayRate ? 1 : 0, __ATOMIC_RELEASE); // Cập nhật trạng thái
        __atomic_store_n(&g_DisableThermalThrottle, disableThermalThrottle ? 1 : 0, __ATOMIC_RELEASE); // Cập nhật trạng thái
        __atomic_store_n(&g_OverclockCPU, overclockCPU ? 1 : 0, __ATOMIC_RELEASE); // Cập nhật trạng thái
        __atomic_store_n(&g_OverclockGPU, overclockGPU ? 1 : 0, __ATOMIC_RELEASE); // Cập nhật trạng thái


        PMLog(@"Prefs: server=%ld active=%d hard=%d drv=%d panel=%d spoofMax=%d spoofGet=%d forceMax=%d disableThermal=%d ocCPU=%d ocGPU=%d floor=%d ceil=%d fps=%ld hz=%ld profileKeys=%lu flags=0x%x",
              (long)serverMode, active, hardLock, driverOverride, panelOverride,
              spoofScreenMax, spoofGetters, forceMaxDisplayRate, disableThermalThrottle, overclockCPU, overclockGPU,
              lockFloorOn, lockCeilOn,
              (long)requestedFPS, (long)requestedHz,
              (unsigned long)profilePrefs.count, (unsigned)policyFlags);
    } @catch (NSException *exception) {
        PMLog(@"Prefs snapshot failed safely: %@", exception);
        __atomic_store_n(&g_TweakEnabled, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_TargetFPS, 60, __ATOMIC_RELEASE);
        __atomic_store_n(&g_TargetHz, 60, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ActiveServerMode, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ServerPolicyFlags, PMPolicyThermalGuard | PMPolicyAdaptiveCadence, __ATOMIC_RELEASE);
        __atomic_store_n(&g_HardLockEnabled, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ForceMaxDisplayRate, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_DisableThermalThrottle, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_OverclockCPU, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_OverclockGPU, 0, __ATOMIC_RELEASE);
    } @catch (...) {
        __atomic_store_n(&g_TweakEnabled, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_TargetFPS, 60, __ATOMIC_RELEASE);
        __atomic_store_n(&g_TargetHz, 60, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ActiveServerMode, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ServerPolicyFlags, PMPolicyThermalGuard | PMPolicyAdaptiveCadence, __ATOMIC_RELEASE);
        __atomic_store_n(&g_HardLockEnabled, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_ForceMaxDisplayRate, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_DisableThermalThrottle, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_OverclockCPU, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_OverclockGPU, 0, __ATOMIC_RELEASE);
    }
    __atomic_store_n(&g_PreferencesLoaded, 1, __ATOMIC_RELEASE);
}

// ============================================================================
// Runtime helpers
// ============================================================================
static inline BOOL PMIsTweakActive(void) {
    return g_AppEligibilityChecked && g_IsAppEligible &&
           __atomic_load_n(&g_PreferencesLoaded, __ATOMIC_ACQUIRE) &&
           __atomic_load_n(&g_TweakEnabled, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMAppIsForeground(void) {
    @try {
        if (!PMPolicyEnabled(PMPolicyForegroundOnly)) return YES;
        return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    } @catch (NSException *e) { return YES; }
    @catch (...) { return YES; }
}
static inline NSInteger PMGetTargetFPS(void) {
    NSInteger fps = __atomic_load_n(&g_TargetFPS, __ATOMIC_ACQUIRE);
    return fps > 0 ? fps : 60;
}
static inline NSInteger PMGetTargetHz(void) {
    NSInteger hz = __atomic_load_n(&g_TargetHz, __ATOMIC_ACQUIRE);
    return hz > 0 ? hz : PMGetTargetFPS();
}
static inline BOOL PMExactRateEnforcementEnabled(void) {
    return __atomic_load_n(&g_ExactRateEnforcement, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMHardLockEnabled(void) {
    return __atomic_load_n(&g_HardLockEnabled, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMHardLockOverrideThermal(void) {
    return PMPolicyEnabled(PMPolicyLockedOverrideThermal);
}
static inline BOOL PMDriverOverrideEnabled(void) {
    return __atomic_load_n(&g_DriverOverrideEnabled, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMPanelOverrideEnabled(void) {
    return __atomic_load_n(&g_PanelOverrideEnabled, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMSpoofScreenMaxEnabled(void) {
    return __atomic_load_n(&g_SpoofScreenMax, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMSpoofGettersEnabled(void) {
    return __atomic_load_n(&g_SpoofGetters, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMForceMaxDisplayRateEnabled(void) { // Helper mới
    return __atomic_load_n(&g_ForceMaxDisplayRate, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMDisableThermalThrottleEnabled(void) { // Helper mới
    return __atomic_load_n(&g_DisableThermalThrottle, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMOverclockCPUEnabled(void) { // Helper mới
    return __atomic_load_n(&g_OverclockCPU, __ATOMIC_ACQUIRE) != 0;
}
static inline BOOL PMOverclockGPUEnabled(void) { // Helper mới
    return __atomic_load_n(&g_OverclockGPU, __ATOMIC_ACQUIRE) != 0;
}


// ============================================================================
// 8.0 CORE: PMLockedRange — always [10, 240, target]. No negation, no clip.
// ============================================================================
static CAFrameRateRange PMLockedRange(NSInteger target) {
    CGFloat floor = PM_LOCKED_FLOOR_HZ;
    CGFloat ceiling = PM_LOCKED_CEILING_HZ;
    CGFloat preferred = (CGFloat)MAX(10, MIN(target, 240));
    PM_METRIC_BUMP(lockedTierHits);
    return CAFrameRateRangeMake(floor, ceiling, preferred);
}

// ============================================================================
// Anti-overkill
// ============================================================================
static inline BOOL PMAntiOverkillCheck(NSInteger targetFPS) {
    @try {
        if (targetFPS < 10 || targetFPS > 240) return NO;
        NSInteger hz = PMGetTargetHz();
        if (hz >= 10 && targetFPS >= 10) {
            NSInteger ratio = hz > targetFPS ? (hz / targetFPS) : (targetFPS / hz);
            if (ratio > 24) return NO;
        }
    } @catch (NSException *e) { return NO; }
    return YES;
}
static inline void PMTrackApplySuccess(void) {
    PM_METRIC_BUMP(rateAdjustments);
}

// ============================================================================
// Thermal target cap — floor 10, ceiling 240
// ============================================================================
static NSInteger PMThermalTargetCap(NSInteger requestedFPS) {
    // Địt mẹ, nếu DisableThermalThrottle được bật, phớt lờ mọi giới hạn nhiệt của iOS
    if (PMDisableThermalThrottleEnabled()) {
        return MAX(requestedFPS, (NSInteger)PM_LOCKED_FLOOR_HZ); // Trả về FPS yêu cầu mà không bị giới hạn nhiệt
    }

    NSInteger nativeMaximum = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    if (nativeMaximum <= 0) nativeMaximum = 60;

    BOOL locked = PMHardLockEnabled();
    BOOL overrideThermal = PMHardLockOverrideThermal();
    NSInteger capped = MIN(MAX(requestedFPS, 10), 240);

    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (processInfo.isLowPowerModeEnabled && !(locked && overrideThermal)) {
        capped = MIN(capped, MAX(30, nativeMaximum / 2));
    }
    if (@available(iOS 11.0, *)) {
        NSProcessInfoThermalState state = processInfo.thermalState;
        if (state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical) {
            if (!(locked && overrideThermal)) capped = MIN(capped, 30);
        } else if (state == NSProcessInfoThermalStateFair && PMPolicyEnabled(PMPolicyThermalGuard)) {
            capped = MIN(capped, MAX(30, nativeMaximum / 2));
        }
    }
    if (locked && overrideThermal) {
        capped = MIN(MAX(capped, 10), 240);
    }
    return MAX(10, capped);
}

// ============================================================================
// Titanium resolution
// ============================================================================
typedef struct {
    NSInteger requestedFPS;
    NSInteger requestedHz;
    NSInteger hardwareMaximum;
    NSInteger effectiveFPS;
    NSInteger effectiveHz;
} TitaniumHardwareTarget;

static NSInteger Titanium_GetHardwareMaximum(void) {
    // Nếu ForceMaxDisplayRate được kích hoạt, giả mạo giới hạn màn hình thành 999Hz
    if (PMForceMaxDisplayRateEnabled()) {
        return 999;
    }
    NSInteger maximum = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    return maximum > 0 ? maximum : 60;
}
static BOOL Titanium_IsThermalSafe(void) {
    // Nếu DisableThermalThrottle được kích hoạt, luôn coi là an toàn về nhiệt
    if (PMDisableThermalThrottleEnabled()) {
        return YES;
    }
    if (@available(iOS 11.0, *)) {
        return NSProcessInfo.processInfo.thermalState < NSProcessInfoThermalStateSerious;
    }
    return YES;
}
static BOOL Titanium_IsPowerSafe(void) {
    // Nếu DisableThermalThrottle được kích hoạt, luôn coi là an toàn về nguồn điện (vì nó thường đi kèm với thermal)
    if (PMDisableThermalThrottleEnabled()) {
        return YES;
    }
    return !NSProcessInfo.processInfo.isLowPowerModeEnabled;
}
static TitaniumHardwareTarget Titanium_ResolveHardwareTarget(NSInteger requestedFPS, NSInteger requestedHz) {
    TitaniumHardwareTarget target = {0};
    target.requestedFPS = MIN(MAX(requestedFPS, 10), 240);
    target.requestedHz = MIN(MAX(requestedHz, 10), 240);
    target.hardwareMaximum = Titanium_GetHardwareMaximum(); // Sử dụng hàm Titanium_GetHardwareMaximum mới

    if (PMForceMaxDisplayRateEnabled()) {
        target.effectiveHz = target.requestedHz; // Đặt hiệu quả bằng yêu cầu
        target.effectiveFPS = target.requestedFPS;
    } else {
        target.effectiveHz = MIN(target.requestedHz, target.hardwareMaximum);
        target.effectiveFPS = MIN(target.requestedFPS, target.effectiveHz);
    }

    BOOL locked = PMHardLockEnabled();
    BOOL overrideThermal = PMHardLockOverrideThermal();

    if (locked) {
        target.effectiveHz = MIN(MAX(target.requestedHz, 10), 240);
        target.effectiveFPS = MIN(MAX(target.requestedFPS, 10), 240);
        if (!overrideThermal && !PMDisableThermalThrottleEnabled()) { // Chỉ áp dụng thermal nếu không bị bypass
            NSInteger safeFPS = PMThermalTargetCap(target.effectiveFPS);
            NSInteger safeHz = PMThermalTargetCap(target.effectiveHz);
            target.effectiveFPS = MIN(target.effectiveFPS, safeFPS);
            target.effectiveHz = MIN(target.effectiveHz, safeHz);
        }
        target.effectiveFPS = MIN(target.effectiveFPS, target.effectiveHz);
        return target;
    }
    
    // Chỉ áp dụng thermal cap nếu không bị bypass
    if (!PMDisableThermalThrottleEnabled()) {
        NSInteger safeFPS = PMThermalTargetCap(target.effectiveFPS);
        NSInteger safeHz = PMThermalTargetCap(target.effectiveHz);
        target.effectiveFPS = MIN(target.effectiveFPS, safeFPS);
        target.effectiveHz = MIN(target.effectiveHz, safeHz);
    }
    
    target.effectiveFPS = MIN(target.effectiveFPS, target.effectiveHz);
    return target;
}
static BOOL Titanium_ExecuteTier4Safely(void) {
    if (!PMIsTweakActive() ||
        __atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE) != 1 ||
        !PMPolicyEnabled(PMPolicyPremiumTier4Display)) return NO;
    if (PMExactRateEnforcementEnabled()) return YES;
    // Nếu DisableThermalThrottle được kích hoạt, bỏ qua kiểm tra thermal/power
    if (PMDisableThermalThrottleEnabled()) return YES;
    return Titanium_IsThermalSafe() && Titanium_IsPowerSafe();
}
static TitaniumHardwareTarget Titanium_ResolvePremiumTier4Target(void) {
    return Titanium_ResolveHardwareTarget(PMGetTargetFPS(), PMGetTargetHz());
}
static TitaniumHardwareTarget Titanium_ResolveAdminHardwareTarget(void) {
    if (!PMIsTweakActive() ||
        __atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE) != 2 ||
        !PMPolicyEnabled(PMPolicyAdminTitaniumRateAdapter)) {
        return Titanium_ResolveHardwareTarget(60, 60);
    }
    return Titanium_ResolveHardwareTarget(PMGetTargetFPS(), PMGetTargetHz());
}

// ============================================================================
// Unlock ladder
// ============================================================================
enum {
    PMUnlockLevelOff = 0,
    PMUnlockLevelHint = 1,
    PMUnlockLevelCeiling = 2,
    PMUnlockLevelTier4 = 3,
    PMUnlockLevelAdapter = 4,
    PMUnlockLevelExact = 5,
    PMUnlockLevelLocked = 6
};
static inline NSInteger PMUnlockLevel(void) {
    if (!PMIsTweakActive()) return PMUnlockLevelOff;
    if (PMHardLockEnabled()) return PMUnlockLevelLocked;
    if (PMExactRateEnforcementEnabled()) return PMUnlockLevelExact;
    NSInteger mode = __atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE);
    if (mode == 3) return PMUnlockLevelLocked;
    if (mode == 2) {
        return PMPolicyEnabled(PMPolicyAdminTitaniumRateAdapter) ? PMUnlockLevelAdapter : PMUnlockLevelCeiling;
    }
    if (mode == 1) {
        return PMPolicyEnabled(PMPolicyPremiumTier4Display) ? PMUnlockLevelTier4 : PMUnlockLevelCeiling;
    }
    return PMUnlockLevelCeiling;
}
NSTimeInterval Titanium_UnlockReassertInterval(void) {
    if (!PMIsTweakActive()) return 0.0;
    if (PMHardLockEnabled()) return 0.0166;
    switch (__atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE)) {
        case 3: return 0.0166;
        case 2:
            if (PMPolicyEnabled(PMPolicyAggressiveReassert)) return 0.05;
            return 0.10;
        case 1: return 0.50;
        default: return 1.00;
    }
}
NSInteger Titanium_UnlockLevel(void) {
    return PMUnlockLevel();
}
static CAFrameRateRange Titanium_MakeSafeFrameRange(CAFrameRateRange original, TitaniumHardwareTarget target) {
    CGFloat maximum = (CGFloat)MAX(10, target.effectiveHz);
    CGFloat preferred = (CGFloat)MIN(MAX(10, target.effectiveFPS), target.effectiveHz);
    if (PMExactRateEnforcementEnabled()) {
        return CAFrameRateRangeMake(preferred, preferred, preferred);
    }
    if (PMUnlockLevel() >= PMUnlockLevelTier4) {
        return CAFrameRateRangeMake(preferred, maximum, preferred);
    }
    CGFloat requestedMinimum = isfinite(original.minimum) && original.minimum >= 10.0
        ? original.minimum : 10.0;
    CGFloat minimum = MIN(requestedMinimum, preferred);
    original.minimum = minimum;
    original.maximum = MAX(maximum, preferred);
    original.preferred = MIN(MAX(preferred, minimum), original.maximum);
    return original;
}

// ============================================================================
// 8.0 CORE: PMRateRangeForActiveServer — always [10, 240, target] under lock.
// ============================================================================
static CAFrameRateRange PMRateRangeForActiveServer(CAFrameRateRange original, NSInteger requestedFPS) {
    (void)original;
    NSInteger mode = __atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE);

    if (PMHardLockEnabled() || mode == 3) {
        PM_METRIC_BUMP(hardFloorEnforcements);
        NSInteger target = PMGetTargetFPS();
        target = MIN(MAX(target, 10), 240);
        if (!PMHardLockOverrideThermal() && !PMDisableThermalThrottleEnabled()) { // Chỉ áp dụng thermal nếu không bị bypass
            NSInteger thermalCapped = PMThermalTargetCap(target);
            target = MIN(MAX(thermalCapped, 10), 240);
        }
        return PMLockedRange(target);
    }

    if (PMExactRateEnforcementEnabled()) {
        TitaniumHardwareTarget exactTarget = Titanium_ResolveHardwareTarget(PMGetTargetFPS(), PMGetTargetHz());
        return Titanium_MakeSafeFrameRange(original, exactTarget);
    }
    if (mode == 1 && Titanium_ExecuteTier4Safely()) {
        TitaniumHardwareTarget premiumTarget = Titanium_ResolvePremiumTier4Target();
        return Titanium_MakeSafeFrameRange(original, premiumTarget);
    }
    if (mode == 2 && PMPolicyEnabled(PMPolicyAdminTitaniumRateAdapter) &&
        (PMExactRateEnforcementEnabled() || (Titanium_IsThermalSafe() && Titanium_IsPowerSafe()))) {
        TitaniumHardwareTarget adminTarget = Titanium_ResolveAdminHardwareTarget();
        return Titanium_MakeSafeFrameRange(original, adminTarget);
    }

    NSInteger safeFPS = PMThermalTargetCap(requestedFPS);
    NSInteger safeHz = PMThermalTargetCap(PMGetTargetHz());
    CGFloat nativeMaximum = (CGFloat)MAX(10, Titanium_GetHardwareMaximum());
    CGFloat maximum = MIN(nativeMaximum, (CGFloat)safeHz);
    CGFloat preferred = MIN((CGFloat)safeFPS, maximum);
    if (PMUnlockLevel() >= PMUnlockLevelCeiling) {
        CGFloat floor = (CGFloat)PM_LOCKED_FLOOR_HZ;
        if (floor > preferred) preferred = floor;
        return CAFrameRateRangeMake(floor, MAX(maximum, preferred), preferred);
    }
    CGFloat minimum = original.minimum > 0.0 ? MIN(original.minimum, preferred) : MIN(10.0, preferred);
    original.minimum = MIN(minimum, preferred);
    original.maximum = MAX(maximum, preferred);
    original.preferred = preferred;
    return original;
}

static inline BOOL PMAnimationRateHintsEnabled(void) {
    return PMIsTweakActive() && PMHasFinishedLaunchDelay() && !g_PMIsScreenCaptured &&
           PMAppIsForeground();
}
static inline BOOL PMFrameRatesAreClose(CAFrameRateRange a, CAFrameRateRange b) {
    return fabs(a.minimum - b.minimum) < 0.01 &&
           fabs(a.maximum - b.maximum) < 0.01 &&
           fabs(a.preferred - b.preferred) < 0.01;
}

static void PMRefreshTrackedDisplayLinks(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ PMRefreshTrackedDisplayLinks(); });
        return;
    }

    BOOL active = PMIsTweakActive();
    if (active && (PMDriverOverrideEnabled() || PMPanelOverrideEnabled())) {
        PMAttemptDriverOverride(PMGetTargetHz());
    }
    NSArray<CADisplayLink *> *links = nil;
    @synchronized ([CADisplayLink class]) {
        links = g_PMTrackedDisplayLinks.allObjects ?: @[];
    }
    if (links.count == 0) return;

    BOOL appForeground = PMAppIsForeground();
    BOOL shouldApply = PMIsTweakActive() && PMHasFinishedLaunchDelay() && !g_PMIsScreenCaptured && appForeground;
    if (!shouldApply) {
        for (CADisplayLink *link in links) {
            if (![link isKindOfClass:[CADisplayLink class]]) continue;
            @try {
                NSDictionary *baseline = nil;
                @synchronized ([CADisplayLink class]) {
                    baseline = [g_PMOriginalDisplayLinkRates objectForKey:link];
                }
                if (!baseline) continue;
                g_PMApplyingTrackedRate = YES;
                NSValue *boxedRange = [baseline[@"frameRateRange"] isKindOfClass:[NSValue class]] ? baseline[@"frameRateRange"] : nil;
                if (@available(iOS 15.0, *)) {
                    if (boxedRange) {
                        CAFrameRateRange originalRange;
                        [boxedRange getValue:&originalRange];
                        [link setPreferredFrameRateRange:originalRange];
                    } else {
                        [link setPreferredFramesPerSecond:[baseline[@"framesPerSecond"] integerValue]];
                    }
                } else {
                    [link setPreferredFramesPerSecond:[baseline[@"framesPerSecond"] integerValue]];
                }
                PM_METRIC_BUMP(rateRestores);
            } @catch (NSException *exception) {
                PMLog(@"Restore skipped safely: %@", exception);
            } @catch (...) {}
            g_PMApplyingTrackedRate = NO;
        }
        return;
    }
    NSInteger desiredFPS = PMGetTargetFPS();
    if (!PMAntiOverkillCheck(desiredFPS)) {
        PM_METRIC_BUMP(antiOverkillRejects);
        return;
    }
    for (CADisplayLink *link in links) {
        if (![link isKindOfClass:[CADisplayLink class]]) continue;
        @try {
            if (@available(iOS 15.0, *)) {
                CAFrameRateRange current = link.preferredFrameRateRange;
                CAFrameRateRange adjusted = PMRateRangeForActiveServer(current, desiredFPS);
                if (PMFrameRatesAreClose(current, adjusted)) continue;
                g_PMApplyingTrackedRate = YES;
                [link setPreferredFrameRateRange:adjusted];
                g_PMApplyingTrackedRate = NO;
                PM_METRIC_BUMP(rateAdjustments);
            } else {
                NSInteger capped = PMThermalTargetCap(desiredFPS);
                if (link.preferredFramesPerSecond == capped) continue;
                g_PMApplyingTrackedRate = YES;
                [link setPreferredFramesPerSecond:capped];
                g_PMApplyingTrackedRate = NO;
                PM_METRIC_BUMP(rateAdjustments);
            }
        } @catch (NSException *exception) {
            PMLog(@"Refresh skipped safely: %@", exception);
        } @catch (...) {}
        g_PMApplyingTrackedRate = NO;
    }
}

void Titanium_ReassertTrackedDisplayLinks(void) {
    PM_METRIC_BUMP(reassertionTicks);
    PMRefreshTrackedDisplayLinks();
}

__attribute__((visibility("default"), used))
void PMControlTweakDumpDiagnostics(void) {
    PMLogCritical(@"diag server=%d active=%d unlock=%ld hard=%d drv=%d panel=%d spoofMax=%d spoofGet=%d forceMax=%d disableThermal=%d ocCPU=%d ocGPU=%d drvOK=%d fps=%ld hz=%ld flags=0x%x",
                  (int)__atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE),
                  (int)PMIsTweakActive(),
                  (long)PMUnlockLevel(),
                  (int)PMHardLockEnabled(),
                  (int)PMDriverOverrideEnabled(),
                  (int)PMPanelOverrideEnabled(),
                  (int)PMSpoofScreenMaxEnabled(),
                  (int)PMSpoofGettersEnabled(),
                  (int)PMForceMaxDisplayRateEnabled(),
                  (int)PMDisableThermalThrottleEnabled(),
                  (int)PMOverclockCPUEnabled(),
                  (int)PMOverclockGPUEnabled(),
                  (int)__atomic_load_n(&g_DriverWriteSucceeded, __ATOMIC_ACQUIRE),
                  (long)PMGetTargetFPS(),
                  (long)PMGetTargetHz(),
                  (unsigned)__atomic_load_n(&g_ServerPolicyFlags, __ATOMIC_ACQUIRE));
    PMLogCritical(@"diag metrics: adj=%llu getR=%llu getF=%llu spoof=%llu reas=%llu rej=%llu exc=%llu lock=%llu floor=%llu drvOK=%llu swap=%llu maxSp=%llu plist=%llu droppedLogs=%llu",
                  atomic_load(&g_PMMetrics.rateAdjustments),
                  atomic_load(&g_PMMetrics.displayLinkGetRangeHits),
                  atomic_load(&g_PMMetrics.displayLinkGetFPSHits),
                  atomic_load(&g_PMMetrics.spoofGetterHits),
                  atomic_load(&g_PMMetrics.reassertionTicks),
                  atomic_load(&g_PMMetrics.antiOverkillRejects),
                  atomic_load(&g_PMMetrics.exceptionsCaught),
                  atomic_load(&g_PMMetrics.lockedTierHits),
                  atomic_load(&g_PMMetrics.hardFloorEnforcements),
                  atomic_load(&g_PMMetrics.driverWriteSuccesses),
                  atomic_load(&g_PMMetrics.swapIntervalWrites),
                  atomic_load(&g_PMMetrics.screenMaxSpoofHits),
                  atomic_load(&g_PMMetrics.profilePlistLoads),
                  atomic_load(&g_PMMetrics.droppedLogs));
}

static void PMRefreshScreenCaptureState(void) {
    PM_SAFE_TRY({
        if (@available(iOS 11.0, *)) {
            g_PMIsScreenCaptured = [UIScreen mainScreen].isCaptured;
        } else {
            g_PMIsScreenCaptured = NO;
        }
    });
}

static void PMDarwinPreferencesChanged(CFNotificationCenterRef center,
                                       void *observer, CFStringRef name,
                                       const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_queue_t queue = g_PMPreferenceQueue;
    if (!queue) return;
    dispatch_async(queue, ^{
        __atomic_store_n(&g_PreferencesLoaded, 0, __ATOMIC_RELEASE);
        PMLoadPreferencesSync();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRefreshTrackedDisplayLinks(); });
    });
}
static void PMDarwinThermalChanged(CFNotificationCenterRef center,
                                   void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    PM_METRIC_BUMP(thermalEvents);
    dispatch_async(dispatch_get_main_queue(), ^{ PMRefreshTrackedDisplayLinks(); });
}

// ============================================================================
// 8.0 HOOK: UIScreen.maximumFramesPerSecond — spoof to 240.
// ============================================================================
%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
    NSInteger original = %orig;
    if (PMForceMaxDisplayRateEnabled() && PMIsTweakActive()) { // Nếu ForceMaxDisplayRate được bật
        PM_METRIC_BUMP(screenMaxSpoofHits);
        return MAX(original, (NSInteger)PM_LOCKED_CEILING_HZ); // Đẩy lên 240Hz hoặc cao hơn
    }
    if (PMSpoofScreenMaxEnabled() && PMIsTweakActive()) {
        PM_METRIC_BUMP(screenMaxSpoofHits);
        return MAX(original, (NSInteger)PM_LOCKED_CEILING_HZ);
    }
    return original;
}
%end

// ============================================================================
// Animation hooks
// ============================================================================
%hook CAAnimation
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (@available(iOS 15.0, *)) {
        PM_SAFE_TRY({
            if (PMAnimationRateHintsEnabled()) {
                NSInteger desiredFPS = PMGetTargetFPS();
                if (PMAntiOverkillCheck(desiredFPS)) {
                    range = PMRateRangeForActiveServer(range, desiredFPS);
                }
            }
        });
    }
    PM_METRIC_BUMP(animationSetRangeHits);
    %orig(range);
}
%end

%hook CALayer
- (void)addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    if (anim) {
        if (@available(iOS 15.0, *)) {
            PM_SAFE_TRY({
                if (PMAnimationRateHintsEnabled()) {
                    NSInteger desiredFPS = PMGetTargetFPS();
                    if (PMAntiOverkillCheck(desiredFPS)) {
                        CAFrameRateRange requestedRange = anim.preferredFrameRateRange;
                        CAFrameRateRange safeRange = PMRateRangeForActiveServer(requestedRange, desiredFPS);
                        anim.preferredFrameRateRange = safeRange;
                        PMTrackApplySuccess();
                    }
                }
            });
        }
    }
    PM_METRIC_BUMP(animationAddToLayerHits);
    %orig(anim, key);
}
%end

%hook CAAnimationGroup
- (void)setAnimations:(NSArray<CAAnimation *> *)animations {
    if (@available(iOS 15.0, *)) {
        PM_SAFE_TRY({
            if (PMAnimationRateHintsEnabled() && animations.count > 0) {
                NSInteger desiredFPS = PMGetTargetFPS();
                if (PMAntiOverkillCheck(desiredFPS)) {
                    for (CAAnimation *child in animations) {
                        if (![child isKindOfClass:[CAAnimation class]]) continue;
                        CAFrameRateRange childRange = child.preferredFrameRateRange;
                        CAFrameRateRange adjusted = PMRateRangeForActiveServer(childRange, desiredFPS);
                        if (!PMFrameRatesAreClose(childRange, adjusted)) {
                            child.preferredFrameRateRange = adjusted;
                        }
                    }
                    PMTrackApplySuccess();
                }
            }
        });
    }
    PM_METRIC_BUMP(animationGroupAddHits);
    %orig(animations);
}
%end

%hook CASpringAnimation
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (@available(iOS 15.0, *)) {
        PM_SAFE_TRY({
            if (PMAnimationRateHintsEnabled()) {
                NSInteger desiredFPS = PMGetTargetFPS();
                if (PMAntiOverkillCheck(desiredFPS)) {
                    range = PMRateRangeForActiveServer(range, desiredFPS);
                }
            }
        });
    }
    PM_METRIC_BUMP(springAnimationHits);
    %orig(range);
}
%end

// ============================================================================
// 8.0 CADisplayLink: getter spoof + setter force.
// ============================================================================
%hook CADisplayLink
- (instancetype)initWithTarget:(id)target selector:(SEL)sel {
    id instance = %orig(target, sel);
    if (instance) {
        PM_METRIC_BUMP(displayLinkInitHits);
        PMRegisterDisplayLink(instance);
    }
    return instance;
}

- (NSInteger)preferredFramesPerSecond {
    if (PMSpoofGettersEnabled() && PMIsTweakActive() &&
        (PMHardLockEnabled() || __atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE) == 3 || PMForceMaxDisplayRateEnabled())) { // Thêm cờ ForceMaxDisplayRate
        PM_METRIC_BUMP(displayLinkGetFPSHits);
        PM_METRIC_BUMP(spoofGetterHits);
        return PMGetTargetFPS();
    }
    return %orig;
}

- (CAFrameRateRange)preferredFrameRateRange {
    if (@available(iOS 15.0, *)) {
        if (PMSpoofGettersEnabled() && PMIsTweakActive() &&
            (PMHardLockEnabled() || __atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE) == 3 || PMForceMaxDisplayRateEnabled())) { // Thêm cờ ForceMaxDisplayRate
            PM_METRIC_BUMP(displayLinkGetRangeHits);
            PM_METRIC_BUMP(spoofGetterHits);
            return PMLockedRange(PMGetTargetFPS());
        }
    }
    return %orig;
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (g_PMApplyingTrackedRate) {
        %orig(range);
        return;
    }
    PMRecordAppDisplayLinkRange(self, range);
    PM_METRIC_BUMP(displayLinkSetRangeHits);
    PM_SAFE_TRY({
        if (PMIsTweakActive() && PMHasFinishedLaunchDelay() && !g_PMIsScreenCaptured && PMAppIsForeground()) {
            NSInteger desiredFPS = PMGetTargetFPS();
            if (PMAntiOverkillCheck(desiredFPS)) {
                range = PMRateRangeForActiveServer(range, desiredFPS);
                PMTrackApplySuccess();
            }
        }
    });
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (g_PMApplyingTrackedRate) {
        %orig(fps);
        return;
    }
    PMRecordAppDisplayLinkFPS(self, fps);
    PM_METRIC_BUMP(displayLinkSetFPSHits);
    PM_SAFE_TRY({
        if (PMIsTweakActive() && PMHasFinishedLaunchDelay() && !g_PMIsScreenCaptured && PMAppIsForeground()) {
            NSInteger desiredFPS = PMGetTargetFPS();
            if (PMAntiOverkillCheck(desiredFPS)) {
                NSInteger capped = PMThermalTargetCap(desiredFPS);
                capped = MIN(MAX(capped, 10), 240);
                %orig(capped);
                PMTrackApplySuccess();
                return;
            }
        }
    });
    %orig(fps);
}

- (void)addToRunLoop:(NSRunLoop *)runLoop forMode:(NSRunLoopMode)mode {
    %orig(runLoop, mode);
    PM_METRIC_BUMP(displayLinkAddToRunLoopHits);
    PMRegisterDisplayLink(self);
    PM_SAFE_TRY({
        if (PMIsTweakActive() && PMHasFinishedLaunchDelay() && !g_PMIsScreenCaptured && PMAppIsForeground()) {
            NSInteger desiredFPS = PMGetTargetFPS();
            if (PMAntiOverkillCheck(desiredFPS)) {
                g_PMApplyingTrackedRate = YES;
                if (@available(iOS 15.0, *)) {
                    CAFrameRateRange current = self.preferredFrameRateRange;
                    self.preferredFrameRateRange = PMRateRangeForActiveServer(current, desiredFPS);
                } else {
                    NSInteger capped = PMThermalTargetCap(desiredFPS);
                    capped = MIN(MAX(capped, 10), 240);
                    self.preferredFramesPerSecond = capped;
                }
                g_PMApplyingTrackedRate = NO;
                PMTrackApplySuccess();
            }
        }
    });
    g_PMApplyingTrackedRate = NO;
}

- (void)setPaused:(BOOL)paused {
    %orig(paused);
    PM_METRIC_BUMP(displayLinkPauseResumeHits);
    if (paused) return;
    PM_SAFE_TRY({
        if (PMIsTweakActive() && PMHasFinishedLaunchDelay() && !g_PMIsScreenCaptured && PMAppIsForeground()) {
            NSInteger desiredFPS = PMGetTargetFPS();
            if (PMAntiOverkillCheck(desiredFPS)) {
                g_PMApplyingTrackedRate = YES;
                if (@available(iOS 15.0, *)) {
                    CAFrameRateRange current = self.preferredFrameRateRange;
                    CAFrameRateRange adjusted = PMRateRangeForActiveServer(current, desiredFPS);
                    if (!PMFrameRatesAreClose(current, adjusted)) {
                        self.preferredFrameRateRange = adjusted;
                        PMTrackApplySuccess();
                    }
                } else {
                    NSInteger capped = PMThermalTargetCap(desiredFPS);
                    capped = MIN(MAX(capped, 10), 240);
                    [self setPreferredFramesPerSecond:capped];
                    PMTrackApplySuccess();
                }
                g_PMApplyingTrackedRate = NO;
            }
        }
    });
    g_PMApplyingTrackedRate = NO;
}

- (void)invalidate {
    PM_METRIC_BUMP(displayLinkInvalidateHits);
    %orig;
    PMUnregisterDisplayLink(self);
}
%end

%hook UIScrollView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    PM_METRIC_BUMP(scrollViewHits);
    if (PMIsTweakActive() &&
        (PMPolicyEnabled(PMPolicyScrollShield) || PMHardLockEnabled())) {
        PMRefreshTrackedDisplayLinks();
    }
    %orig;
}
%end

%hook UIView
+ (void)animateWithDuration:(NSTimeInterval)duration
                      delay:(NSTimeInterval)delay
                    options:(UIViewAnimationOptions)options
                 animations:(void (^)(void))animations
                 completion:(void (^)(BOOL finished))completion {
    PM_METRIC_BUMP(uiViewAnimateBlockHits);
    void (^wrappedCompletion)(BOOL) = nil;
    if (completion) {
        wrappedCompletion = ^(BOOL finished) {
            completion(finished);
            if (PMIsTweakActive() &&
                (PMPolicyEnabled(PMPolicyScrollShield) || PMHardLockEnabled())) {
                PMRefreshTrackedDisplayLinks();
            }
        };
    } else {
        wrappedCompletion = ^(BOOL finished) {
            (void)finished;
            if (PMIsTweakActive() &&
                (PMPolicyEnabled(PMPolicyScrollShield) || PMHardLockEnabled())) {
                PMRefreshTrackedDisplayLinks();
            }
        };
    }
    %orig(duration, delay, options, animations, wrappedCompletion);
}
%end

static BOOL PMRuntimeHooksAllowedForEmergencyRelease(void) {
    return PMCheckAppEligibility();
}

// ============================================================================
// Monitors
// ============================================================================
static dispatch_source_t g_PMThermalMonitor = NULL;
static dispatch_source_t g_PMReassertMonitor = NULL;
static dispatch_source_t g_PMDriverMonitor = NULL;
static NSProcessInfoThermalState g_PMLastThermalState = NSProcessInfoThermalStateNominal;
static BOOL g_PMLastLowPowerState = NO;

static void PMStartThermalMonitor(void) {
    if (g_PMThermalMonitor) return;
    dispatch_queue_t queue = dispatch_queue_create("com.dell.promotioncontrol.thermal-monitor", DISPATCH_QUEUE_SERIAL);
    g_PMThermalMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    uint64_t interval = 2ull * NSEC_PER_SEC;
    dispatch_source_set_timer(g_PMThermalMonitor,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, 500ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_PMThermalMonitor, ^{
        @autoreleasepool {
            if (!PMIsTweakActive()) return;

            // Nếu DisableThermalThrottle được bật, không cần theo dõi thermal state và Low Power Mode từ iOS
            if (PMDisableThermalThrottleEnabled()) {
                g_PMLastThermalState = NSProcessInfoThermalStateNominal;
                g_PMLastLowPowerState = NO;
                return;
            }

            if (@available(iOS 11.0, *)) {
                NSProcessInfoThermalState current = NSProcessInfo.processInfo.thermalState;
                if (current != g_PMLastThermalState) {
                    g_PMLastThermalState = current;
                    PM_METRIC_BUMP(thermalEvents);
                    PMLog(@"thermal -> %ld", (long)current);
                    dispatch_async(dispatch_get_main_queue(), ^{ PMRefreshTrackedDisplayLinks(); });
                }
            }
            BOOL lowPower = NSProcessInfo.processInfo.isLowPowerModeEnabled;
            if (lowPower != g_PMLastLowPowerState) {
                g_PMLastLowPowerState = lowPower;
                PM_METRIC_BUMP(powerEvents);
                PMLog(@"low power -> %d", lowPower);
                dispatch_async(dispatch_get_main_queue(), ^{ PMRefreshTrackedDisplayLinks(); });
            }
        }
    });
    dispatch_resume(g_PMThermalMonitor);
}
static void PMStopThermalMonitor(void) {
    if (!g_PMThermalMonitor) return;
    dispatch_source_cancel(g_PMThermalMonitor);
    g_PMThermalMonitor = NULL;
}
static void PMStartReassertMonitor(void) {
    if (g_PMReassertMonitor) return;
    g_PMReassertMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    NSTimeInterval interval = Titanium_UnlockReassertInterval();
    if (interval <= 0.0) interval = 1.0;
    uint64_t nanos = (uint64_t)(interval * NSEC_PER_SEC);
    dispatch_source_set_timer(g_PMReassertMonitor,
                              dispatch_time(DISPATCH_TIME_NOW, nanos),
                              nanos, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_PMReassertMonitor, ^{
        @autoreleasepool { Titanium_ReassertTrackedDisplayLinks(); }
    });
    dispatch_resume(g_PMReassertMonitor);
}
static void PMStopReassertMonitor(void) {
    if (!g_PMReassertMonitor) return;
    dispatch_source_cancel(g_PMReassertMonitor);
    g_PMReassertMonitor = NULL;
}
static void PMRearmReassertMonitor(void) {
    PMStopReassertMonitor();
    if (PMIsTweakActive()) PMStartReassertMonitor();
}
static void PMStartDriverMonitor(void) {
    if (g_PMDriverMonitor) return;
    g_PMDriverMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               dispatch_get_main_queue());
    uint64_t interval = 500ull * NSEC_PER_MSEC;
    dispatch_source_set_timer(g_PMDriverMonitor,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, 50ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_PMDriverMonitor, ^{
        @autoreleasepool {
            if (!PMIsTweakActive()) return;
            if (!PMDriverOverrideEnabled() && !PMPanelOverrideEnabled()) return;
            PMAttemptDriverOverride(PMGetTargetHz());
        }
    });
    dispatch_resume(g_PMDriverMonitor);
}
static void PMStopDriverMonitor(void) {
    if (!g_PMDriverMonitor) return;
    dispatch_source_cancel(g_PMDriverMonitor);
    g_PMDriverMonitor = NULL;
}

// ============================================================================
// Constructor
// ============================================================================
%ctor {
    @autoreleasepool {
        PMLogReset(64);
        if (!PMCheckAppEligibility()) return;
        if (!PMRuntimeHooksAllowedForEmergencyRelease()) {
            PMLogCritical(@"%@ | guard rejected", PM_BUILD_VERSION);
            return;
        }
        PMInstallSafetyExceptionHandler();
        PMResolvePrivateFrameworkSymbols();

        PM_SAFE_TRY({
            PMLoadPreferencesSync();
            %init;

            g_PMPreferenceQueue = dispatch_queue_create("com.dell.promotioncontrol.preference-reload", DISPATCH_QUEUE_SERIAL);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                PMDarwinPreferencesChanged, PM_DARWIN_CHANGED_NOTIFICATION, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                PMDarwinThermalChanged, PM_DARWIN_THERMAL_NOTIFICATION, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                (void)note;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __atomic_store_n(&g_AppHasFinishedLaunching, 1, __ATOMIC_RELEASE);
                    PMRefreshScreenCaptureState();
                    PMRefreshTrackedDisplayLinks();
                    PMStartThermalMonitor();
                    PMRearmReassertMonitor();
                    PMStartDriverMonitor();
                });
            }];

            g_PMStateObserverTokens = [NSMutableArray array];
            NSArray<NSNotificationName> *stateNotifications = @[
                NSProcessInfoPowerStateDidChangeNotification,
                NSProcessInfoThermalStateDidChangeNotification,
                UIApplicationDidBecomeActiveNotification,
                UIApplicationDidEnterBackgroundNotification
            ];
            for (NSNotificationName notificationName in stateNotifications) {
                id token = [[NSNotificationCenter defaultCenter]
                    addObserverForName:notificationName object:nil
                    queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        (void)note;
                        if ([note.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
                            PM_METRIC_BUMP(foregroundEvents);
                        } else if ([note.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
                            PM_METRIC_BUMP(backgroundEvents);
                        }
                        PMRefreshTrackedDisplayLinks();
                    }];
                if (token) [g_PMStateObserverTokens addObject:token];
            }

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                (void)note;
                PMStopThermalMonitor();
                PMStopReassertMonitor();
                PMStopDriverMonitor();
            }];

            PMLogCritical(@"%@ | GETTER-SPOOF+PLIST build init; server=%d active=%d hard=%d spoofMax=%d spoofGet=%d forceMax=%d disableThermal=%d ocCPU=%d ocGPU=%d unlock=%ld target=%ld",
                  PM_BUILD_VERSION,
                  (int)__atomic_load_n(&g_ActiveServerMode, __ATOMIC_ACQUIRE),
                  (int)PMIsTweakActive(),
                  (int)PMHardLockEnabled(),
                  (int)PMSpoofScreenMaxEnabled(),
                  (int)PMSpoofGettersEnabled(),
                  (int)PMForceMaxDisplayRateEnabled(),
                  (int)PMDisableThermalThrottleEnabled(),
                  (int)PMOverclockCPUEnabled(),
                  (int)PMOverclockGPUEnabled(),
                  (long)PMUnlockLevel(),
                  (long)PMGetTargetFPS());
        });
    }
}
