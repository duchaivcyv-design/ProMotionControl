// =================================================================================================
// TitaniumServerTierSupport.h
// Shared read-only helpers for the three server-scoped runtime modules
// (FREE / PREMIUM / ADMIN). Everything here is inline and side-effect free: the
// tier value, selected Hz/FPS and option switches come from the bridge cache, so a
// display-link or audio-session callback never performs plist I/O.
//
// Safety notes:
//  - No UIKit/AVFoundation singleton is created during dyld init. Each module calls
//    Titanium_TierPrepareBatteryMonitoring() from a main-queue block after launch.
//  - All getters are wrapped in @try so a missing private framework object cannot
//    turn a status query into an app crash.
// =================================================================================================
#ifndef TitaniumServerTierSupport_h
#define TitaniumServerTierSupport_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <malloc/malloc.h>
#import <math.h>
#import "TitaniumSettingsAPI.h"

extern BOOL g_isCurrentAppBlacklisted;

// Implemented in Tweak.x. Re-applies the selected Hz/FPS to every CADisplayLink
// the core already tracks, without creating a second rate pipeline.
extern void Titanium_ReassertTrackedDisplayLinks(void);

// Implemented in Tweak.x. The unlock ladder reports which pacing contract level is
// active (0 off, 1 hint, 2 ceiling, 3 tier4, 4 adapter, 5 exact) and how often the
// sentinel should re-assert it. A zero interval means "ladder off, do nothing".
extern NSTimeInterval Titanium_UnlockReassertInterval(void);
extern NSInteger Titanium_UnlockLevel(void);

// The user-facing range is always 10...244. The panel still decides which values it
// can physically present; this clamp only prevents 0 Hz, +inf durations and overflow.
static inline NSInteger Titanium_TierClampRate(NSInteger value) {
    return MIN(MAX(value, 10), 244);
}

static inline NSInteger Titanium_TierHz(void) {
    NSInteger hz = Titanium_CurrentTargetHz();
    if (hz <= 0) hz = Titanium_CurrentTargetFPS();
    return Titanium_TierClampRate(hz);
}

static inline NSInteger Titanium_TierFPS(void) {
    NSInteger fps = Titanium_CurrentTargetFPS();
    if (fps <= 0) fps = Titanium_CurrentTargetHz();
    return Titanium_TierClampRate(fps);
}

static inline double Titanium_TierFrameDuration(void) {
    return 1.0 / (double)Titanium_TierHz();
}

// A module is effective only when the master engine is on, this app is not
// excluded, and the user selected exactly this tier.
static inline BOOL Titanium_TierActive(NSInteger tier) {
    if (tier < 0 || tier > 2) return NO;
    @try {
        if (!Apex_IsMasterEnabled() || g_isCurrentAppBlacklisted) return NO;
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Tier gate failed safely: %@", exception);
        return NO;
    }
    return Titanium_CurrentServerMode() == tier;
}

// Per-tier runtime switch already used by Tweak.x. Missing key means enabled.
static inline BOOL Titanium_TierRuntimeEnabled(NSInteger tier) {
    NSString *key = tier == 2 ? @"AdminCADisplayLinkHookEnabled" :
        (tier == 1 ? @"PremiumCADisplayLinkHookEnabled" : @"FreeCADisplayLinkHookEnabled");
    return Titanium_ConfigBool(key, YES);
}

// Enabling battery monitoring is a UIKit operation. Call this from the main queue
// after UIApplicationMain has started, never from a dyld constructor.
static inline void Titanium_TierPrepareBatteryMonitoring(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Titanium_TierPrepareBatteryMonitoring();
        });
        return;
    }
    @try {
        [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Battery monitoring unavailable: %@", exception);
    }
}

// Read-only: returns NO until monitoring is enabled, so a background thread can
// call this without touching UIKit state.
static inline BOOL Titanium_TierDeviceIsCharging(void) {
    @try {
        UIDevice *device = [UIDevice currentDevice];
        if (!device || !device.isBatteryMonitoringEnabled) return NO;
        UIDeviceBatteryState state = device.batteryState;
        return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
    } @catch (NSException *exception) {
        return NO;
    }
}

static inline BOOL Titanium_TierBackgroundAudioActive(void) {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (!session) return NO;
        return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint;
    } @catch (NSException *exception) {
        return NO;
    }
}

// Inside the control app the thermal/LPM hooks deliberately return the real values,
// so this snapshot is trustworthy for our own battery/thermal policy.
static inline NSProcessInfoThermalState Titanium_TierThermalState(void) {
    @try {
        return [NSProcessInfo processInfo].thermalState;
    } @catch (NSException *exception) {
        return NSProcessInfoThermalStateNominal;
    }
}

// Charging anti-throttle is expressed with public NSProcessInfo activity options
// instead of falsifying thermal telemetry. Idle-sleep is only held while plugged in
// and not already hot; a Serious/Critical device sheds the optional holds first.
static inline NSActivityOptions Titanium_TierActivityOptions(NSInteger tier, BOOL *shouldHold) {
    NSProcessInfoThermalState thermal = Titanium_TierThermalState();
    BOOL charging = Titanium_TierDeviceIsCharging();
    BOOL audio = Titanium_TierBackgroundAudioActive();
    BOOL hot = thermal >= NSProcessInfoThermalStateSerious;
    NSActivityOptions options = NSActivityUserInitiated;

    if (tier == 0) {
        if (audio) options |= NSActivityLatencyCritical;
        if (charging && !hot) options |= NSActivityIdleSystemSleepDisabled;
        if (audio) options |= (NSActivityAutomaticTerminationDisabled | NSActivitySuddenTerminationDisabled);
    } else if (tier == 1) {
        options |= NSActivityLatencyCritical;
        if (charging && !hot) options |= NSActivityIdleSystemSleepDisabled;
        if (audio) options |= (NSActivityAutomaticTerminationDisabled | NSActivitySuddenTerminationDisabled);
    } else {
        options |= (NSActivityLatencyCritical | NSActivityAutomaticTerminationDisabled |
                    NSActivitySuddenTerminationDisabled);
        if (!hot) options |= NSActivityIdleSystemSleepDisabled;
    }

    if (shouldHold) *shouldHold = (tier == 2) ? (thermal < NSProcessInfoThermalStateCritical) : YES;
    return options;
}

// -------------------------------------------------------------------------------------------------
// Deferred startup.
// A dylib constructor runs inside dyld, before UIApplicationMain exists. Creating
// UIDevice/AVAudioSession singletons or reading applicationState there can throw or
// deadlock and terminate the app, so every module installs its observers and runs its
// first refresh from the main queue once UIApplication is alive.
// -------------------------------------------------------------------------------------------------
static inline BOOL Titanium_TierApplicationReady(void) {
    @try {
        return [UIApplication sharedApplication] != nil;
    } @catch (NSException *exception) {
        return NO;
    }
}

static inline void Titanium_TierDeferUntilLaunch(dispatch_block_t block) {
    if (!block) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (Titanium_TierApplicationReady()) {
                block();
                return;
            }
        } @catch (NSException *exception) {
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Titanium_TierDeferUntilLaunch(block);
        });
    });
}

// -------------------------------------------------------------------------------------------------
// Background execution per tier.
// A UIApplication background task assertion keeps the tweak alive after the user
// leaves the app. The assertion is renewed from its own expiration handler and is
// hard-capped per tier so the app cannot spin forever and burn the battery:
//   FREE 5 minutes, PREMIUM 30 minutes, ADMIN unlimited while the tier is active.
// A value of 0 for maxDuration means "no time cap". Once the cap is reached the
// state is marked exhausted and refuses to restart until the trigger goes away,
// so a repeated refresh cannot silently reset the timer.
// -------------------------------------------------------------------------------------------------
typedef struct {
    UIBackgroundTaskIdentifier task;
    NSTimeInterval startedAt;
    NSTimeInterval maxDuration;
    BOOL running;
    BOOL exhausted;
} TitaniumBackgroundKeepAlive;

static inline BOOL Titanium_TierIsBackground(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        return app != nil && app.applicationState == UIApplicationStateBackground;
    } @catch (NSException *exception) {
        return NO;
    }
}

static inline void Titanium_TierKeepAliveStop(TitaniumBackgroundKeepAlive *state) {
    if (!state) return;
    UIBackgroundTaskIdentifier task = state->task;
    state->task = UIBackgroundTaskInvalid;
    state->running = NO;
    // A zero-initialized struct has task == 0, which is not a valid identifier.
    if (task == UIBackgroundTaskInvalid || task == 0) return;
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (app) [app endBackgroundTask:task];
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] endBackgroundTask failed safely: %@", exception);
    }
}

static inline void Titanium_TierKeepAliveBegin(TitaniumBackgroundKeepAlive *state);

static inline void Titanium_TierKeepAliveBegin(TitaniumBackgroundKeepAlive *state) {
    if (!state || state->exhausted) return;

    UIApplication *app = nil;
    @try {
        app = [UIApplication sharedApplication];
    } @catch (NSException *exception) {
        return;
    }
    if (!app) return;

    if (state->maxDuration > 0.0) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (state->startedAt <= 0.0) state->startedAt = now;
        if (now - state->startedAt >= state->maxDuration) {
            state->exhausted = YES;
            Titanium_TierKeepAliveStop(state);
            NSLog(@"[ProMotionControl] Tier background keep-alive reached its time cap.");
            return;
        }
    }

    __block UIBackgroundTaskIdentifier token = UIBackgroundTaskInvalid;
    @try {
        token = [app beginBackgroundTaskWithName:@"Titanium tier keep-alive" expirationHandler:^{
            if (state->task == token) {
                state->task = UIBackgroundTaskInvalid;
                state->running = NO;
            }
            // Renew after iOS expires the assertion; the cap check inside
            // Titanium_TierKeepAliveBegin terminates the chain when exhausted.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (state->exhausted || !Titanium_TierIsBackground()) return;
                Titanium_TierKeepAliveBegin(state);
            });
        }];
    } @catch (NSException *exception) {
        token = UIBackgroundTaskInvalid;
    }
    state->task = token;
    state->running = (token != UIBackgroundTaskInvalid);
}

static inline BOOL Titanium_TierIsForeground(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        return app != nil && app.applicationState == UIApplicationStateActive;
    } @catch (NSException *exception) {
        return NO;
    }
}

static inline void Titanium_TierKeepAliveUpdate(TitaniumBackgroundKeepAlive *state,
                                                BOOL shouldRun,
                                                NSTimeInterval maxDuration) {
    if (!state) return;
    if (!shouldRun) {
        Titanium_TierKeepAliveStop(state);
        state->startedAt = 0.0;
        state->maxDuration = 0.0;
        state->exhausted = NO;
        return;
    }
    // The assertion only means something while the app is in the background, and a
    // return to the foreground starts a fresh time budget for the next background run.
    if (!Titanium_TierIsBackground()) {
        Titanium_TierKeepAliveStop(state);
        state->startedAt = 0.0;
        state->exhausted = NO;
        return;
    }
    if (state->running || state->exhausted) return;
    if (state->startedAt <= 0.0) state->startedAt = [NSDate date].timeIntervalSince1970;
    state->maxDuration = maxDuration;
    Titanium_TierKeepAliveBegin(state);
}

// -------------------------------------------------------------------------------------------------
// Long-run memory stabiliser.
// A foreground GPU/UI app can grow its resident footprint for hours. This guard samples the
// process physical footprint (public task_info) and, only when growth crosses the tier limit
// and the cooldown has elapsed, returns free malloc pages to the OS and clears the app-local
// URL cache. It never purges system caches, never posts a fake memory warning and never frees
// live objects, so it cannot corrupt app state.
// -------------------------------------------------------------------------------------------------
typedef struct {
    uint64_t baselineFootprint;
    uint64_t lastFootprint;
    NSTimeInterval lastReliefAt;
    NSInteger reliefCount;
} TitaniumMemoryGuard;

static inline uint64_t Titanium_TierPhysicalFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO,
                                     (task_info_t)&info, &count);
    if (result != KERN_SUCCESS) return 0;
    return (uint64_t)info.phys_footprint;
}

static inline BOOL Titanium_TierStabilizeMemory(TitaniumMemoryGuard *guard,
                                                NSInteger tier,
                                                uint64_t growthLimitBytes,
                                                NSTimeInterval minimumInterval) {
    if (!guard || growthLimitBytes == 0) return NO;
    uint64_t footprint = Titanium_TierPhysicalFootprint();
    if (footprint == 0) return NO;

    // The baseline follows the low-water mark, so slow fragmentation that never
    // fully returns is treated as growth instead of being masked by the first sample.
    if (guard->baselineFootprint == 0 || footprint < guard->baselineFootprint) {
        guard->baselineFootprint = footprint;
        guard->lastFootprint = footprint;
        return NO;
    }
    guard->lastFootprint = footprint;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (guard->lastReliefAt > 0.0 && now - guard->lastReliefAt < minimumInterval) return NO;

    uint64_t growth = footprint - guard->baselineFootprint;
    if (growth < growthLimitBytes) return NO;

    uint64_t before = footprint;
    NSInteger releases = tier >= 1 ? 1 : 0;
    malloc_zone_pressure_relief(NULL, 0);
    if (releases > 0) {
        @try {
            NSURLCache *cache = [NSURLCache sharedURLCache];
            if (cache) [cache removeAllCachedResponses];
        } @catch (NSException *exception) {
            NSLog(@"[ProMotionControl] URL cache relief skipped safely: %@", exception);
        }
    }

    uint64_t after = Titanium_TierPhysicalFootprint();
    guard->lastReliefAt = now;
    guard->reliefCount += 1;
    guard->baselineFootprint = after > 0 ? after : footprint;

    NSLog(@"[ProMotionControl] Tier %ld memory relief #%ld: %.1f MB -> %.1f MB (growth %.1f MB)",
          (long)tier, (long)guard->reliefCount,
          (double)before / 1048576.0, (double)after / 1048576.0,
          (double)growth / 1048576.0);
    return YES;
}

// Immediate, cooldown-free relief for a real UIKit memory warning. Still app-local:
// free malloc pages plus the app's own URL cache, never a system-wide purge.
static inline void Titanium_TierEmergencyMemoryRelief(NSInteger tier) {
    malloc_zone_pressure_relief(NULL, 0);
    if (tier < 1) return;
    @try {
        NSURLCache *cache = [NSURLCache sharedURLCache];
        if (cache) [cache removeAllCachedResponses];
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Emergency URL cache relief skipped safely: %@", exception);
    }
}

// -------------------------------------------------------------------------------------------------
// Long-run rate sentinel.
// iOS and the app can change CADisplayLink pacing after interruptions, captures or long
// inactivity. A tier-scoped repeating timer re-applies the selected Hz/FPS through the core
// tracker, so the chosen cadence survives hours of use instead of drifting back to 60.
// -------------------------------------------------------------------------------------------------
static inline void Titanium_TierReassertRate(void) {
    @try {
        if (!Titanium_TierIsForeground()) return;
        NSTimeInterval interval = Titanium_UnlockReassertInterval();
        if (interval <= 0.0) return;
        // Sentinel chạy theo nhịp riêng của từng tầng; cổng này giữ đúng khoảng
        // cách mà thang bẻ khóa yêu cầu và tránh ghi lại dải khi chưa cần.
        static NSTimeInterval lastAsserted = 0.0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (lastAsserted > 0.0 && now - lastAsserted < interval) return;
        lastAsserted = now;
        Titanium_ReassertTrackedDisplayLinks();
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Rate sentinel failed safely: %@", exception);
    }
}

// Creates a main-queue repeating timer. The handler always runs inside an
// autorelease pool and an exception guard so a transient failure cannot kill the app.
static inline dispatch_source_t Titanium_TierCreateTimer(NSTimeInterval interval,
                                                         dispatch_block_t handler) {
    if (interval <= 0.0 || !handler) return nil;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    if (!timer) return nil;
    uint64_t intervalNanos = (uint64_t)(interval * (NSTimeInterval)NSEC_PER_SEC);
    if (intervalNanos == 0) intervalNanos = NSEC_PER_SEC;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNanos),
                              intervalNanos, intervalNanos / 10);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            @try {
                handler();
            } @catch (NSException *exception) {
                NSLog(@"[ProMotionControl] Tier timer tick failed safely: %@", exception);
            }
        }
    });
    dispatch_resume(timer);
    return timer;
}

#endif /* TitaniumServerTierSupport_h */
