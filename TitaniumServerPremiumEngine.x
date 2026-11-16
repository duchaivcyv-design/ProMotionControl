// =================================================================================================
// TitaniumServerPremiumEngine.x
// SERVER PREMIUM — nâng cấp so với FREE:
//  - Giữ wake-lock/hiệu năng khi vừa sạc vừa dùng và khi chạy nhạc nền.
//  - Chạy nền theo server: giữ app sống tới 30 phút khi đang sạc hoặc còn nhạc nền,
//    có công tắc riêng và tự nhả khi hết hạn hoặc khi nhiệt độ xấu đi.
//  - Không giả mạo UIScreen.maximumFramesPerSecond; nhịp render được yêu cầu qua
//    CADisplayLink chung và luôn theo trần vật lý của panel.
//  - Hạ độ trễ mạng bằng networkServiceType ResponsiveData (QoS của Apple), tăng số kết nối
//    song song và chặn timeout quá dài — tốt cho tải bản đồ / chẩn đoán mạng.
//  - Vẫn giữ clamp 10..244 và không giả trạng thái nhiệt độ của ControlApp.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "TitaniumServerTierSupport.h"
#import "TitaniumBackgroundContinuity.h"

static id g_TitaniumPremiumActivityToken = nil;
// Zero-initialised; Titanium_TierKeepAliveStop treats task == 0 as invalid.
static TitaniumBackgroundKeepAlive g_TitaniumPremiumKeepAlive;
static TitaniumMemoryGuard g_TitaniumPremiumMemoryGuard;
static dispatch_source_t g_TitaniumPremiumTimer = nil;
static NSInteger g_TitaniumPremiumTickCount = 0;

// 30 phút cho PREMIUM: đủ dài cho phiên game có nhạc nền hoặc cắm sạc, vẫn có trần.
static const NSTimeInterval kTitaniumPremiumKeepAliveCap = 1800.0;
// Sentinel 0.5 giây/lần (2x tần suất FREE), kiểm tra RAM mỗi 30 giây.
static const NSTimeInterval kTitaniumPremiumSentinelInterval = 0.5;
static const NSInteger kTitaniumPremiumMemoryTickEvery = 60;
static const uint64_t kTitaniumPremiumMemoryGrowthLimit = 64ull * 1024ull * 1024ull;
static const NSTimeInterval kTitaniumPremiumMemoryCooldown = 180.0;

static inline BOOL Titanium_PremiumTierRunning(void) {
    return Titanium_TierActive(1) && Titanium_TierRuntimeEnabled(1);
}

static void Titanium_PremiumStabilityTick(void) {
    Titanium_BackgroundContinuitySync();
    if (!Titanium_PremiumTierRunning()) return;

    if (Titanium_ConfigBool(@"PremiumRateSentinelEnabled", YES)) {
        Titanium_TierReassertRate();
    }
    if (!Titanium_ConfigBool(@"PremiumMemoryGuardEnabled", YES)) return;

    g_TitaniumPremiumTickCount += 1;
    if (g_TitaniumPremiumTickCount % kTitaniumPremiumMemoryTickEvery != 0) return;
    Titanium_TierStabilizeMemory(&g_TitaniumPremiumMemoryGuard, 1,
                                 kTitaniumPremiumMemoryGrowthLimit,
                                 kTitaniumPremiumMemoryCooldown);
}

static void Titanium_PremiumRefreshActivity(void) {
    @try {
        BOOL running = Titanium_PremiumTierRunning();
        BOOL shouldBoost = running && Titanium_ConfigBool(@"PremiumActivityBoostEnabled", YES);

        NSProcessInfo *info = [NSProcessInfo processInfo];
        if (g_TitaniumPremiumActivityToken) {
            [info endActivity:g_TitaniumPremiumActivityToken];
            g_TitaniumPremiumActivityToken = nil;
        }
        if (shouldBoost) {
            g_TitaniumPremiumActivityToken =
                [info beginActivityWithOptions:Titanium_TierActivityOptions(1, NULL)
                                        reason:@"Titanium PREMIUM charge/background guard"];
        }

        BOOL keepAliveWanted = running &&
            Titanium_ConfigBool(@"PremiumBackgroundKeepAliveEnabled", YES) &&
            (Titanium_TierDeviceIsCharging() || Titanium_TierBackgroundAudioActive());
        Titanium_TierKeepAliveUpdate(&g_TitaniumPremiumKeepAlive, keepAliveWanted,
                                     kTitaniumPremiumKeepAliveCap);
        Titanium_BackgroundContinuitySync();
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM refresh failed safely: %@", exception);
    }
}

static void Titanium_PremiumPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                               CFNotificationName name, const void *object,
                                               CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_PremiumRefreshActivity();
    });
}

static void Titanium_PremiumTuneSessionConfiguration(NSURLSessionConfiguration *configuration) {
    @try {
        if (![configuration isKindOfClass:[NSURLSessionConfiguration class]]) return;
        if (!Titanium_ConfigBool(@"PremiumNetworkLowLatencyEnabled", YES)) return;
        // QoS hint của Apple cho lưu lượng cần phản hồi nhanh (API, tile bản đồ, chẩn đoán).
        configuration.networkServiceType = NSURLNetworkServiceTypeResponsiveData;
        if (configuration.timeoutIntervalForRequest <= 0.0 ||
            configuration.timeoutIntervalForRequest > 20.0) {
            configuration.timeoutIntervalForRequest = 20.0;
        }
        if (configuration.HTTPMaximumConnectionsPerHost < 8) {
            configuration.HTTPMaximumConnectionsPerHost = 8;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM session tuning failed safely: %@", exception);
    }
}

%group TitaniumServerPremiumGroup

// =================================================================================================
// 1. PROCESS ACTIVITY — chống hạ ưu tiên khi sạc và khi app chạy nền
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    @try {
        if (Titanium_PremiumTierRunning() &&
            Titanium_ConfigBool(@"PremiumActivityBoostEnabled", YES)) {
            options |= Titanium_TierActivityOptions(1, NULL);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM activity guard failed safely: %@", exception);
    }
    return %orig(options, reason);
}

- (void)performActivityWithOptions:(NSActivityOptions)options
                            reason:(NSString *)reason
                        usingBlock:(void (^)(void))block {
    @try {
        if (Titanium_PremiumTierRunning() &&
            Titanium_ConfigBool(@"PremiumActivityBoostEnabled", YES)) {
            options |= Titanium_TierActivityOptions(1, NULL);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM block activity guard failed safely: %@", exception);
    }
    %orig(options, reason, block);
}
%end

// =================================================================================================
// 2. NETWORK — QoS phản hồi nhanh, nhiều kết nối hơn, timeout ngắn hơn
// =================================================================================================
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM default session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM ephemeral session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = %orig(identifier);
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM background session guard failed safely: %@", exception);
    }
    return configuration;
}
%end

// =================================================================================================
// 3. BACKGROUND AUDIO — giữ nhạc nền liên tục khi sạc / chuyển nền
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_TierActive(1) &&
            Titanium_ConfigBool(@"PremiumBackgroundAudioGuardEnabled", YES)) {
            if (!active) options |= AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM audio session guard failed safely: %@", exception);
    }
    return %orig(active, options, outError);
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_TierActive(1) &&
            Titanium_ConfigBool(@"PremiumBackgroundAudioGuardEnabled", YES)) {
            options |= AVAudioSessionCategoryOptionMixWithOthers;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM audio category guard failed safely: %@", exception);
    }
    return %orig(category, mode, options, outError);
}
%end

%end

%ctor {
    @autoreleasepool {
        %init(TitaniumServerPremiumGroup);

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
                            if (Titanium_PremiumTierRunning() &&
                                Titanium_ConfigBool(@"PremiumMemoryGuardEnabled", YES)) {
                                Titanium_TierEmergencyMemoryRelief(1);
                            }
                            return;
                        }
                        Titanium_PremiumRefreshActivity();
                    }];
                }
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                    Titanium_PremiumPreferencesChanged, CFSTR("com.dell.promotioncontrol.changed"), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                if (!g_TitaniumPremiumTimer) {
                    g_TitaniumPremiumTimer = Titanium_TierCreateTimer(kTitaniumPremiumSentinelInterval, ^{
                        Titanium_PremiumStabilityTick();
                    });
                }
                Titanium_PremiumRefreshActivity();
            } @catch (NSException *exception) {
                NSLog(@"[ProMotionControl] PREMIUM tier install failed safely: %@", exception);
            }
        });
    }
}
