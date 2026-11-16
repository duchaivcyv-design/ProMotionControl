// =================================================================================================
// TitaniumServerAdminEngine.x
// SERVER ADMIN — mức tối ưu ứng dụng cao nhất trong ba tier:
//  1. NSProcessInfo activity với tự nhả khi thiết bị quá nóng.
//  2. Network QoS ResponsiveData và cấu hình kết nối cho request của ControlApp.
//  3. Background audio continuity và tác vụ nền có thời hạn, trong giới hạn iOS.
//  4. Memory guard và sentinel 10 lần tần suất FREE; không giả trạng thái phần cứng.
// Hz/FPS được xử lý một lần bởi Tweak.x qua CADisplayLink công khai và luôn
// tôn trọng trần panel, Low Power Mode và trạng thái nhiệt thực tế.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import "TitaniumServerTierSupport.h"
#import "TitaniumBackgroundContinuity.h"

static id g_TitaniumAdminActivityToken = nil;
// Zero-initialised; Titanium_TierKeepAliveStop treats task == 0 as invalid.
static TitaniumBackgroundKeepAlive g_TitaniumAdminKeepAlive;
static TitaniumMemoryGuard g_TitaniumAdminMemoryGuard;
static dispatch_source_t g_TitaniumAdminTimer = nil;
static NSInteger g_TitaniumAdminTickCount = 0;

// ADMIN may request a bounded background task; iOS can still expire it sooner.
static const NSTimeInterval kTitaniumAdminKeepAliveCap = 1800.0;
// 0.1 s = 10x FREE's 1.0 s reassert cadence; memory check remains about every 20 s.
static const NSTimeInterval kTitaniumAdminSentinelInterval = 0.10;
static const NSInteger kTitaniumAdminMemoryTickEvery = 200;
static const uint64_t kTitaniumAdminMemoryGrowthLimit = 48ull * 1024ull * 1024ull;
static const NSTimeInterval kTitaniumAdminMemoryCooldown = 120.0;

static inline BOOL Titanium_AdminTierRunning(void) {
    return Titanium_TierActive(2) && Titanium_TierRuntimeEnabled(2);
}

static void Titanium_AdminStabilityTick(void) {
    Titanium_BackgroundContinuitySync();
    if (!Titanium_AdminTierRunning()) return;

    if (Titanium_ConfigBool(@"AdminRateSentinelEnabled", YES)) {
        Titanium_TierReassertRate();
    }
    if (!Titanium_ConfigBool(@"AdminMemoryGuardEnabled", YES)) return;

    g_TitaniumAdminTickCount += 1;
    if (g_TitaniumAdminTickCount % kTitaniumAdminMemoryTickEvery != 0) return;
    Titanium_TierStabilizeMemory(&g_TitaniumAdminMemoryGuard, 2,
                                 kTitaniumAdminMemoryGrowthLimit,
                                 kTitaniumAdminMemoryCooldown);
}

static void Titanium_AdminRefreshActivity(void) {
    @try {
        BOOL running = Titanium_AdminTierRunning();

        NSProcessInfo *info = [NSProcessInfo processInfo];
        if (g_TitaniumAdminActivityToken) {
            [info endActivity:g_TitaniumAdminActivityToken];
            g_TitaniumAdminActivityToken = nil;
        }
        if (running) {
            BOOL thermalOk = YES;
            NSActivityOptions options = Titanium_TierActivityOptions(2, &thermalOk);
            if (thermalOk) {
                g_TitaniumAdminActivityToken =
                    [info beginActivityWithOptions:options
                                            reason:@"Titanium ADMIN network and foreground engine"];
            }
        }

        BOOL keepAliveWanted = running &&
            Titanium_ConfigBool(@"AdminBackgroundKeepAliveEnabled", YES) &&
            Titanium_TierThermalState() < NSProcessInfoThermalStateCritical;
        Titanium_TierKeepAliveUpdate(&g_TitaniumAdminKeepAlive, keepAliveWanted,
                                     kTitaniumAdminKeepAliveCap);
        Titanium_BackgroundContinuitySync();
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN refresh failed safely: %@", exception);
    }
}

static void Titanium_AdminPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                             CFNotificationName name, const void *object,
                                             CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_AdminRefreshActivity();
    });
}

static void Titanium_AdminTuneSessionConfiguration(NSURLSessionConfiguration *configuration) {
    @try {
        if (![configuration isKindOfClass:[NSURLSessionConfiguration class]]) return;
        if (!Titanium_ConfigBool(@"AdminNetworkLowLatencyEnabled", YES)) return;
        configuration.networkServiceType = NSURLNetworkServiceTypeResponsiveData;
        if (configuration.timeoutIntervalForRequest <= 0.0 ||
            configuration.timeoutIntervalForRequest > 20.0) {
            configuration.timeoutIntervalForRequest = 20.0;
        }
        if (configuration.HTTPMaximumConnectionsPerHost < 10) {
            configuration.HTTPMaximumConnectionsPerHost = 10;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN session tuning failed safely: %@", exception);
    }
}

%group TitaniumServerAdminGroup

// =================================================================================================
// 1. PROCESS ACTIVITY — mức cao nhất nhưng tự nhả khi nhiệt Serious/Critical
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    @try {
        if (Titanium_AdminTierRunning()) {
            BOOL thermalOk = YES;
            options |= Titanium_TierActivityOptions(2, &thermalOk);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN activity guard failed safely: %@", exception);
    }
    return %orig(options, reason);
}

- (void)performActivityWithOptions:(NSActivityOptions)options
                            reason:(NSString *)reason
                        usingBlock:(void (^)(void))block {
    @try {
        if (Titanium_AdminTierRunning()) {
            BOOL thermalOk = YES;
            options |= Titanium_TierActivityOptions(2, &thermalOk);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN block activity guard failed safely: %@", exception);
    }
    %orig(options, reason, block);
}
%end

// Display pacing is centralized in Tweak.x so all tiers share the same
// tracked CADisplayLink pipeline and the selected Hz/FPS are not overwritten.

// The Core Animation public CADisplayLink request is the supported display
// pacing interface; no private window-server, framebuffer, pixel-clock or
// V-Sync control is loaded by the ADMIN tier.

// =================================================================================================
// 2. NETWORK — QoS phản hồi nhanh, timeout ngắn, nhiều kết nối song song
// =================================================================================================
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    @try {
        if (Titanium_TierActive(2)) Titanium_AdminTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN default session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    @try {
        if (Titanium_TierActive(2)) Titanium_AdminTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN ephemeral session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = %orig(identifier);
    @try {
        if (Titanium_TierActive(2)) Titanium_AdminTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN background session guard failed safely: %@", exception);
    }
    return configuration;
}
%end

// =================================================================================================
// 3. BACKGROUND AUDIO — ADMIN giữ phiên âm thanh và nhạc nền liên tục
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_TierActive(2) &&
            Titanium_ConfigBool(@"AdminBackgroundAudioGuardEnabled", YES)) {
            if (!active) options |= AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN audio session guard failed safely: %@", exception);
    }
    return %orig(active, options, outError);
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_TierActive(2) &&
            Titanium_ConfigBool(@"AdminBackgroundAudioGuardEnabled", YES)) {
            options |= AVAudioSessionCategoryOptionMixWithOthers;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN audio category guard failed safely: %@", exception);
    }
    return %orig(category, mode, options, outError);
}
%end

%end

%ctor {
    @autoreleasepool {
        %init(TitaniumServerAdminGroup);

        Titanium_TierDeferUntilLaunch(^{
            @try {
                Titanium_TierPrepareBatteryMonitoring();

                NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
                for (NSNotificationName note in @[
                         NSProcessInfoPowerStateDidChangeNotification,
                         NSProcessInfoThermalStateDidChangeNotification,
                         UIDeviceBatteryStateDidChangeNotification,
                         UIApplicationDidBecomeActiveNotification,
                         UIApplicationDidEnterBackgroundNotification,
                         UIApplicationDidReceiveMemoryWarningNotification]) {
                    [center addObserverForName:note object:nil queue:[NSOperationQueue mainQueue]
                                    usingBlock:^(NSNotification *observation) {
                        if ([observation.name isEqualToString:UIApplicationDidReceiveMemoryWarningNotification]) {
                            if (Titanium_AdminTierRunning() &&
                                Titanium_ConfigBool(@"AdminMemoryGuardEnabled", YES)) {
                                Titanium_TierEmergencyMemoryRelief(2);
                            }
                            return;
                        }
                        Titanium_AdminRefreshActivity();
                    }];
                }
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                    Titanium_AdminPreferencesChanged, CFSTR("com.dell.promotioncontrol.changed"), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                if (!g_TitaniumAdminTimer) {
                    g_TitaniumAdminTimer = Titanium_TierCreateTimer(kTitaniumAdminSentinelInterval, ^{
                        Titanium_AdminStabilityTick();
                    });
                }
                Titanium_AdminRefreshActivity();
            } @catch (NSException *exception) {
                NSLog(@"[ProMotionControl] ADMIN tier install failed safely: %@", exception);
            }
        });
    }
}
