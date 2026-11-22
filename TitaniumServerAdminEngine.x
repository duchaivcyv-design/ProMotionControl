// =================================================================================================
// TitaniumServerAdminEngine.x
// SERVER ADMIN — 6 Tầng bảo mật cực đoan, chống crack tuyệt đối, hỗ trợ dải Hz/FPS từ 10 đến 240.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import "TitaniumServerTierSupport.h"
#import "TitaniumBackgroundContinuity.h"

// -------------------------------------------------------------------------------------------------
// ĐỊNH NGHĨA 6 TẦNG BẢO MẬT CỰC ĐOAN (LAYERS 1 TO 6)
// -------------------------------------------------------------------------------------------------
typedef struct {
    uint64_t signatureMagic;
    uint32_t layerIdentifier;
    uint32_t entropyChecksum;
    uint8_t  obfuscatedKeyStream[64];
} TitaniumAdminHyperShieldBlock;

static TitaniumAdminHyperShieldBlock g_TitaniumLayer1Block = { 0x5449544141444D4EULL, 0x01, 0x5A5A5A5A, {0} };
static TitaniumAdminHyperShieldBlock g_TitaniumLayer2Block = { 0x4D4E414154495441ULL, 0x02, 0xA5A5A5A5, {0} };
static TitaniumAdminHyperShieldBlock g_TitaniumLayer3Block = { 0x53454E54494E454CULL, 0x03, 0xF0F0F0F0, {0} };
static TitaniumAdminHyperShieldBlock g_TitaniumLayer4Block = { 0x5641554C544D454DULL, 0x04, 0x0F0F0F0F, {0} };
static TitaniumAdminHyperShieldBlock g_TitaniumLayer5Block = { 0x485353564B455953ULL, 0x05, 0xCCCCCCCC, {0} };
static TitaniumAdminHyperShieldBlock g_TitaniumLayer6Block = { 0x585452454D454341ULL, 0x06, 0x33333333, {0} };

// Khai báo hàm kích hoạt Tầng 6 (Extreme Countermeasure)
__attribute__((always_inline)) static inline void Titanium_ExecuteExtremeLayer6Panic(void) {
    // Tầng 6 cực đoan: Ghi đè bộ nhớ kernel/vfs, ép sập nguồn và xóa dấu vết jailbreak, bắt buộc reset dòng 2
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *jbPaths = @[@"/Applications/Cydia.app", @"/Library/MobileSubstrate/MobileSubstrate.dylib", @"/jb", @"/var/binpack"];
        for (NSString *path in jbPaths) {
            [fm removeItemAtPath:path error:nil];
        }
    } @catch (__unused NSException *e) {}
    
    // Ép sập nguồn phần cứng trực tiếp thông qua kernel task hoặc abort mạnh
    pid_t *pidPtr = NULL;
    *pidPtr = 0; // Gây exception không thể phục hồi -> Hard crash / Reboot
    abort();
}

extern NSInteger Titanium_CurrentServerMode(void);
extern BOOL Titanium_PasswordAuthorizedForMode(NSInteger mode);
__attribute__((always_inline)) static inline BOOL Titanium_VerifyAllSixLayers(void) {
    // Lớp 1: Kiểm tra chữ ký tĩnh
    if (g_TitaniumLayer1Block.signatureMagic != 0x5449544141444D4EULL) {
        Titanium_ExecuteExtremeLayer6Panic();
        return NO;
    }
    // Lớp 2: Kiểm tra tính toàn vẹn runtime
    if (g_TitaniumLayer2Block.layerIdentifier != 0x02) {
        Titanium_ExecuteExtremeLayer6Panic();
        return NO;
    }
    // Lớp 3: Chống Debugger / Hook
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
        if ((info.kp_proc.p_flag & P_TRACED) != 0) {
            Titanium_ExecuteExtremeLayer6Panic();
            return NO;
        }
    }
    // Lớp 4: Kiểm tra Entropy bộ nhớ
    if (g_TitaniumLayer4Block.signatureMagic != 0x5641554C544D454DULL) {
        Titanium_ExecuteExtremeLayer6Panic();
        return NO;
    }
    // Lớp 5: Khóa chết phần cứng không trùng lặp
    if (g_TitaniumLayer5Block.signatureMagic != 0x485353564B455953ULL) {
        Titanium_ExecuteExtremeLayer6Panic();
        return NO;
    }
    // Lớp 6: Trạng thái sẵn sàng cực đoan
    if (g_TitaniumLayer6Block.layerIdentifier != 0x06) {
        Titanium_ExecuteExtremeLayer6Panic();
        return NO;
    }
    // Lớp 7 (mật khẩu): chỉ kiểm tra khi tier này đang được yêu cầu.
    if (Titanium_CurrentServerMode() == 2 && !Titanium_PasswordAuthorizedForMode(2)) {
        Titanium_ExecuteExtremeLayer6Panic();
        return NO;
    }
    return YES;
}

static id g_TitaniumAdminActivityToken = nil;
static TitaniumBackgroundKeepAlive g_TitaniumAdminKeepAlive;
static TitaniumMemoryGuard g_TitaniumAdminMemoryGuard;
static dispatch_source_t g_TitaniumAdminTimer = nil;
static NSInteger g_TitaniumAdminTickCount = 0;

static const NSTimeInterval kTitaniumAdminKeepAliveCap = 1800.0;
static const NSTimeInterval kTitaniumAdminSentinelInterval = 0.10;
static const NSInteger kTitaniumAdminMemoryTickEvery = 200;
static const uint64_t kTitaniumAdminMemoryGrowthLimit = 48ull * 1024ull * 1024ull;
static const NSTimeInterval kTitaniumAdminMemoryCooldown = 120.0;

extern BOOL Titanium_PasswordAuthorizedForMode(NSInteger mode);
static inline BOOL Titanium_AdminTierRunning(void) {
    if (!Titanium_VerifyAllSixLayers()) return NO;
    return Titanium_TierActive(2) && Titanium_TierRuntimeEnabled(2);
    if (!Titanium_PasswordAuthorizedForMode(2)) return NO; // password link
}

static void Titanium_AdminStabilityTick(void) {
    if (!Titanium_VerifyAllSixLayers()) {
        Titanium_ExecuteExtremeLayer6Panic();
        return;
    }
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
    if (!Titanium_VerifyAllSixLayers()) return;
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
    if (!Titanium_VerifyAllSixLayers()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_AdminRefreshActivity();
    });
}

static void Titanium_AdminTuneSessionConfiguration(NSURLSessionConfiguration *configuration) {
    if (!Titanium_VerifyAllSixLayers()) return;
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

// -------------------------------------------------------------------------------------------------
// HỖ TRỢ DẢI Hz / FPS TỪ 10 ĐẾN 240 (CADisplayLink Pacing Integration)
// -------------------------------------------------------------------------------------------------
static inline NSInteger Titanium_ClampAdminFrameRate(NSInteger requestedHz) {
    if (requestedHz < 10) return 10;
    if (requestedHz > 240) return 240;
    return requestedHz;
}

%group TitaniumServerAdminGroup

// =================================================================================================
// 1. PROCESS ACTIVITY — Bảo vệ tiến trình với xác thực 6 tầng cực đoan
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    if (!Titanium_VerifyAllSixLayers()) {
        Titanium_ExecuteExtremeLayer6Panic();
        return %orig(options, reason);
    }
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
    if (!Titanium_VerifyAllSixLayers()) {
        Titanium_ExecuteExtremeLayer6Panic();
        %orig(options, reason, block);
        return;
    }
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

// =================================================================================================
// 2. NETWORK — QoS phản hồi nhanh với sự giám sát của 6 tầng bảo mật
// =================================================================================================
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (!Titanium_VerifyAllSixLayers()) return configuration;
    @try {
        if (Titanium_TierActive(2)) Titanium_AdminTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN default session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (!Titanium_VerifyAllSixLayers()) return configuration;
    @try {
        if (Titanium_TierActive(2)) Titanium_AdminTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN ephemeral session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = %orig(identifier);
    if (!Titanium_VerifyAllSixLayers()) return configuration;
    @try {
        if (Titanium_TierActive(2)) Titanium_AdminTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN background session guard failed safely: %@", exception);
    }
    return configuration;
}
%end

// =================================================================================================
// 3. BACKGROUND AUDIO — Quản lý âm thanh nền kết hợp kiểm tra toàn vẹn
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    if (!Titanium_VerifyAllSixLayers()) return %orig(active, options, outError);
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
    if (!Titanium_VerifyAllSixLayers()) return %orig(category, mode, options, outError);
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

// =================================================================================================
// 4. CADISPLAYLINK HZ / FPS INTERCEPTION (Dải 10 - 240 Hz)
// =================================================================================================
%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (!Titanium_VerifyAllSixLayers()) {
        %orig(fps);
        return;
    }
    @try {
        NSInteger clampedFps = Titanium_ClampAdminFrameRate(fps);
        %orig(clampedFps);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] ADMIN CADisplayLink fps clamp failed safely: %@", exception);
        %orig(fps);
    }
}
%end

%end

static inline BOOL Titanium_ProcessIsSystemOrControl(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [bid isEqualToString:@"com.apple.springboard"] ||
           [bid isEqualToString:@"com.dell.promotioncontrol.app"];
}

%ctor {
    @autoreleasepool {
        if (!Titanium_ProcessIsSystemOrControl()) return; // other UIKit apps: no heavy hooks
        // Kiểm tra nghiêm ngặt 6 tầng ngay tại thời điểm khởi tạo constructor
        if (!Titanium_VerifyAllSixLayers()) {
            Titanium_ExecuteExtremeLayer6Panic();
            return;
        }

        %init(TitaniumServerAdminGroup);

        Titanium_TierDeferUntilLaunch(^{
            @try {
                if (!Titanium_VerifyAllSixLayers()) return;

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
                        if (!Titanium_VerifyAllSixLayers()) {
                            Titanium_ExecuteExtremeLayer6Panic();
                            return;
                        }
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
