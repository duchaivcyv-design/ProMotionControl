// =================================================================================================
// TitaniumServerFreeEngine.x
// SERVER FREE — tầng chống giảm tải cơ bản nhưng vẫn hoạt động thật:
//  - Giữ phiên âm thanh nền sống và không cắt nhạc của app khác khi sạc / chạy nền.
//  - Dùng NSProcessInfo activity của Apple để chống iOS hạ ưu tiên lúc vừa dùng vừa sạc;
//    chỉ giữ wake-lock khi đang sạc và máy chưa nóng, nên không đốt pin vô ích.
//  - Chạy nền theo server: xin UIBackgroundTask khi app xuống nền và còn nhạc nền,
//    tối đa 5 phút cho FREE để không hao pin.
//  - Không giả nhiệt độ, không tắt dịch vụ hệ thống, không ghi 0xFFFFFFFF vào pixel clock.
//
// Lớp Hz/FPS nhận mục tiêu 10..244 từ cấu hình và yêu cầu qua CADisplayLink chung
// trong giới hạn panel, Low Power Mode và trạng thái nhiệt thực; file này thêm phần FREE.
//
// Crash-safety: mọi thứ chạm UIKit/AVFoundation được hoãn tới sau khi UIApplicationMain
// tạo UIApplication, và mọi hook đều @try để lỗi không bao giờ ném ngược vào app.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "TitaniumServerTierSupport.h"
#import "TitaniumBackgroundContinuity.h"

static id g_TitaniumFreeActivityToken = nil;
// Zero-initialised; Titanium_TierKeepAliveStop treats task == 0 as invalid.
static TitaniumBackgroundKeepAlive g_TitaniumFreeKeepAlive;
static TitaniumMemoryGuard g_TitaniumFreeMemoryGuard;
static dispatch_source_t g_TitaniumFreeTimer = nil;
static NSInteger g_TitaniumFreeTickCount = 0;

// 5 phút là mức trần cho FREE: đủ để giữ nhạc nền/phiên sạc ngắn, không hao pin.
static const NSTimeInterval kTitaniumFreeKeepAliveCap = 300.0;
// Nhịp sentinel FREE là 1 giây; các tier trên tăng tần suất kiểm tra có giới hạn,
// kiểm tra RAM mỗi 60 giây (cổng thời gian của thang nằm trong Titanium_TierReassertRate).
static const NSTimeInterval kTitaniumFreeSentinelInterval = 1.0;
static const NSInteger kTitaniumFreeMemoryTickEvery = 60;
static const uint64_t kTitaniumFreeMemoryGrowthLimit = 96ull * 1024ull * 1024ull;
static const NSTimeInterval kTitaniumFreeMemoryCooldown = 300.0;

static inline BOOL Titanium_FreeTierRunning(void) {
    return Titanium_TierActive(0) && Titanium_TierRuntimeEnabled(0);
}

static void Titanium_FreeStabilityTick(void) {
    // Continuity is evaluated every tick so a background transition, a tier change
    // or the per-tier switch is reflected without waiting for a preference event.
    Titanium_BackgroundContinuitySync();
    if (!Titanium_FreeTierRunning()) return;

    if (Titanium_ConfigBool(@"FreeRateSentinelEnabled", YES)) {
        Titanium_TierReassertRate();
    }
    if (!Titanium_ConfigBool(@"FreeMemoryGuardEnabled", YES)) return;

    g_TitaniumFreeTickCount += 1;
    if (g_TitaniumFreeTickCount % kTitaniumFreeMemoryTickEvery != 0) return;
    Titanium_TierStabilizeMemory(&g_TitaniumFreeMemoryGuard, 0,
                                 kTitaniumFreeMemoryGrowthLimit,
                                 kTitaniumFreeMemoryCooldown);
}

static void Titanium_FreeRefreshActivity(void) {
    @try {
        BOOL running = Titanium_FreeTierRunning();
        BOOL shouldBoost = running && Titanium_ConfigBool(@"FreeActivityBoostEnabled", YES);

        NSProcessInfo *info = [NSProcessInfo processInfo];
        if (g_TitaniumFreeActivityToken) {
            [info endActivity:g_TitaniumFreeActivityToken];
            g_TitaniumFreeActivityToken = nil;
        }
        if (shouldBoost) {
            g_TitaniumFreeActivityToken =
                [info beginActivityWithOptions:Titanium_TierActivityOptions(0, NULL)
                                        reason:@"Titanium FREE charge/background guard"];
        }

        BOOL keepAliveWanted = running &&
            Titanium_ConfigBool(@"FreeBackgroundKeepAliveEnabled", YES) &&
            Titanium_TierBackgroundAudioActive();
        Titanium_TierKeepAliveUpdate(&g_TitaniumFreeKeepAlive, keepAliveWanted, kTitaniumFreeKeepAliveCap);
        Titanium_BackgroundContinuitySync();
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] FREE refresh failed safely: %@", exception);
    }
}

static void Titanium_FreePreferencesChanged(CFNotificationCenterRef center, void *observer,
                                            CFNotificationName name, const void *object,
                                            CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_FreeRefreshActivity();
    });
}

%group TitaniumServerFreeGroup

// =================================================================================================
// 1. PROCESS ACTIVITY — chống hạ ưu tiên khi sạc, giữ nhạc nền không bị kill
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    @try {
        if (Titanium_FreeTierRunning() &&
            Titanium_ConfigBool(@"FreeActivityBoostEnabled", YES)) {
            options |= Titanium_TierActivityOptions(0, NULL);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] FREE activity guard failed safely: %@", exception);
    }
    return %orig(options, reason);
}

- (void)performActivityWithOptions:(NSActivityOptions)options
                            reason:(NSString *)reason
                        usingBlock:(void (^)(void))block {
    @try {
        if (Titanium_FreeTierRunning() &&
            Titanium_ConfigBool(@"FreeActivityBoostEnabled", YES)) {
            options |= Titanium_TierActivityOptions(0, NULL);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] FREE block activity guard failed safely: %@", exception);
    }
    %orig(options, reason, block);
}
%end

// =================================================================================================
// 2. BACKGROUND AUDIO — không cắt nhạc nền, không giành độc quyền âm thanh
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_TierActive(0) &&
            Titanium_ConfigBool(@"FreeBackgroundAudioGuardEnabled", YES)) {
            // Khi tắt phiên của chính app, báo cho các app khác (nhạc nền) tiếp tục phát.
            if (!active) options |= AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] FREE audio session guard failed safely: %@", exception);
    }
    return %orig(active, options, outError);
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_TierActive(0) &&
            Titanium_ConfigBool(@"FreeBackgroundAudioGuardEnabled", YES)) {
            // MixWithOthers để nhạc nền của app khác không bị dừng khi app này dùng âm thanh.
            options |= AVAudioSessionCategoryOptionMixWithOthers;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] FREE audio category guard failed safely: %@", exception);
    }
    return %orig(category, mode, options, outError);
}
%end

%end

%ctor {
    @autoreleasepool {
        %init(TitaniumServerFreeGroup);

        // Không chạm UIDevice/AVAudioSession/UIApplication trong dyld init.
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
                            if (Titanium_FreeTierRunning() &&
                                Titanium_ConfigBool(@"FreeMemoryGuardEnabled", YES)) {
                                Titanium_TierEmergencyMemoryRelief(0);
                            }
                            return;
                        }
                        Titanium_FreeRefreshActivity();
                    }];
                }
                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                    Titanium_FreePreferencesChanged, CFSTR("com.dell.promotioncontrol.changed"), NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
                if (!g_TitaniumFreeTimer) {
                    g_TitaniumFreeTimer = Titanium_TierCreateTimer(kTitaniumFreeSentinelInterval, ^{
                        Titanium_FreeStabilityTick();
                    });
                }
                Titanium_FreeRefreshActivity();
            } @catch (NSException *exception) {
                NSLog(@"[ProMotionControl] FREE tier install failed safely: %@", exception);
            }
        });
    }
}
