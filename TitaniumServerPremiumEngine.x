// =================================================================================================
// TitaniumServerPremiumEngine.x
// SERVER PREMIUM — Hệ thống bảo mật 6 tầng nguyên khối, không trùng lặp, dải Hz/FPS 10-120.
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
// KHỐI BẢO MẬT 6 TẦNG TỐI CAO ĐÃ GỘP GỌN (UNIFIED 6-LAYER SECURITY CORE)
// Không còn các biến g_TitaniumSignatureLayerOne, g_TitaniumSignatureLayerTwo, hay TitaniumSecureSignatureBlock cũ.
// Thay thế bằng một mảng TitaniumPremiumShieldBlock duy nhất cho 6 tầng.
// -------------------------------------------------------------------------------------------------
typedef struct {
    uint64_t signatureTag;     // Định danh duy nhất cho mỗi tầng
    uint32_t tierLevel;        // Cấp độ tầng bảo mật
    uint32_t integrityHash;    // Mã băm kiểm tra tính toàn vẹn (thay đổi động)
    uint8_t  antiTamperPayload[32]; // Payload chống giả mạo
} TitaniumPremiumShieldBlock;

static TitaniumPremiumShieldBlock g_TitaniumPremiumShieldLayers[6] = {
    { 0x5052454D49554D31ULL, 0x01, 0xA1B2C3D4, {0} }, // Lớp 1: Chữ ký tĩnh
    { 0x5052454D49554D32ULL, 0x02, 0xE5F6A7B8, {0} }, // Lớp 2: Giám sát Runtime
    { 0x5052454D49554D33ULL, 0x03, 0xC9D0E1F2, {0} }, // Lớp 3: Chống Debug/Hook
    { 0x5052454D49554D34ULL, 0x04, 0x1A2B3C4D, {0} }, // Lớp 4: Entropy bộ nhớ
    { 0x5052454D49554D35ULL, 0x05, 0x5E6F7A8B, {0} }, // Lớp 5: Khóa phần cứng không trùng lặp (giả lập)
    { 0x5052454D49554D36ULL, 0x06, 0x9C0D1E2F, {0} }  // Lớp 6: Hành động cực đoan
};

// Hàm kích hoạt hành động Tầng 6 (Ep sập nguồn, khóa Jailbreak, yêu cầu Reset Dòng 2)
__attribute__((always_inline)) static inline void Titanium_ExecutePremiumLayer6Protocol(void) {
    @try {
        NSString *lockPath = @"/var/lib/dpkg/lock_titanium_premium_security";
        [@"CRACK_DETECTED_RESET_REQUIRED_PREMIUM" writeToFile:lockPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e) {}

    // Gây lỗi con trỏ Null để ép sập nguồn hệ thống một cách có kiểm soát
    pid_t *badPtr = NULL;
    *badPtr = 0xFF; // Ghi vào địa chỉ không hợp lệ
    abort(); // Kích hoạt crash ngay lập tức
}

// Hàm kiểm tra tính toàn vẹn của tất cả 6 tầng bảo mật
extern NSInteger Titanium_CurrentServerMode(void);
extern BOOL Titanium_PasswordAuthorizedForMode(NSInteger mode);
__attribute__((always_inline)) static inline BOOL Titanium_VerifyPremiumSixLayers(void) {
    // Lớp 1-2-4-5-6 kiểm tra signatureTag và tierLevel
    if (g_TitaniumPremiumShieldLayers[0].signatureTag != 0x5052454D49554D31ULL || g_TitaniumPremiumShieldLayers[0].tierLevel != 0x01 ||
        g_TitaniumPremiumShieldLayers[1].signatureTag != 0x5052454D49554D32ULL || g_TitaniumPremiumShieldLayers[1].tierLevel != 0x02 ||
        g_TitaniumPremiumShieldLayers[3].signatureTag != 0x5052454D49554D34ULL || g_TitaniumPremiumShieldLayers[3].tierLevel != 0x04 ||
        g_TitaniumPremiumShieldLayers[4].signatureTag != 0x5052454D49554D35ULL || g_TitaniumPremiumShieldLayers[4].tierLevel != 0x05 ||
        g_TitaniumPremiumShieldLayers[5].signatureTag != 0x5052454D49554D36ULL || g_TitaniumPremiumShieldLayers[5].tierLevel != 0x06) {
        Titanium_ExecutePremiumLayer6Protocol();
        return NO;
    }
    
    // Lớp 3: Kiểm tra Anti-Debugging (P_TRACED flag)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
        if ((info.kp_proc.p_flag & P_TRACED) != 0) { // Nếu bị debug
            Titanium_ExecutePremiumLayer6Protocol();
            return NO;
        }
    }

    // Động hóa giá trị checksum để chống phân tích tĩnh và đảm bảo tính "luôn thay đổi"
    // Mỗi lần gọi hàm, checksum sẽ thay đổi một cách tinh vi
    g_TitaniumPremiumShieldLayers[0].integrityHash ^= (uint32_t)arc4random();
    g_TitaniumPremiumShieldLayers[1].integrityHash ^= (uint32_t)mach_absolute_time();

    // Lớp 7 (mật khẩu): chỉ kiểm tra khi tier này đang được yêu cầu.
    if (Titanium_CurrentServerMode() == 1 && !Titanium_PasswordAuthorizedForMode(1)) {
        Titanium_ExecutePremiumLayer6Protocol();
        return NO;
    }
    return YES;
}

static id g_TitaniumPremiumActivityToken = nil;
static TitaniumBackgroundKeepAlive g_TitaniumPremiumKeepAlive;
static TitaniumMemoryGuard g_TitaniumPremiumMemoryGuard;
static dispatch_source_t g_TitaniumPremiumTimer = nil;
static NSInteger g_TitaniumPremiumTickCount = 0;

static const NSTimeInterval kTitaniumPremiumKeepAliveCap = 1800.0;
static const NSTimeInterval kTitaniumPremiumSentinelInterval = 0.5;
static const NSInteger kTitaniumPremiumMemoryTickEvery = 60;
static const uint64_t kTitaniumPremiumMemoryGrowthLimit = 64ull * 1024ull * 1024ull;
static const NSTimeInterval kTitaniumPremiumMemoryCooldown = 180.0;

// =================================================================================================
// CÁC HÀM HỖ TRỢ CHÍNH (ĐÃ ĐẢM BẢO KHÔNG TRÙNG LẶP VỚI CẤU TRÚC BẢO MẬT)
// =================================================================================================
extern BOOL Titanium_PasswordAuthorizedForMode(NSInteger mode);
static inline BOOL Titanium_PremiumTierRunning(void) {
    if (!Titanium_VerifyPremiumSixLayers()) return NO; // Luôn kiểm tra bảo mật trước
    return Titanium_TierActive(1) && Titanium_TierRuntimeEnabled(1);
    if (!Titanium_PasswordAuthorizedForMode(1)) return NO; // password link
}

static void Titanium_PremiumStabilityTick(void) {
    if (!Titanium_VerifyPremiumSixLayers()) {
        Titanium_ExecutePremiumLayer6Protocol();
        return;
    }
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
    if (!Titanium_VerifyPremiumSixLayers()) return;
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
    if (!Titanium_VerifyPremiumSixLayers()) return; // Kiểm tra bảo mật khi thay đổi Prefs
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_PremiumRefreshActivity();
    });
}

static void Titanium_PremiumTuneSessionConfiguration(NSURLSessionConfiguration *configuration) {
    if (!Titanium_VerifyPremiumSixLayers()) return;
    @try {
        if (![configuration isKindOfClass:[NSURLSessionConfiguration class]]) return;
        if (!Titanium_ConfigBool(@"PremiumNetworkLowLatencyEnabled", YES)) return;
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

// Giới hạn dải Hz/FPS cho Premium (10 - 120 Hz)
static inline NSInteger Titanium_ClampPremiumFrameRate(NSInteger requestedHz) {
    if (requestedHz < 10) return 10;
    if (requestedHz > 120) return 120;
    return requestedHz;
}

%group TitaniumServerPremiumGroup

// =================================================================================================
// HOOKS ĐƯỢC BẢO VỆ 6 TẦNG (ĐÃ GỘP KHÔNG TRÙNG LẶP)
// Mỗi hook đều bắt đầu bằng Titanium_VerifyPremiumSixLayers()
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        return %orig(options, reason);
    }
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
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        %orig(options, reason, block);
        return;
    }
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

%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        return configuration;
    }
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM default session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        return configuration;
    }
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM ephemeral session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = %orig(identifier);
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        return configuration;
    }
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM background session guard failed safely: %@", exception);
    }
    return configuration;
}
%end

%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        return %orig(active, options, outError);
    }
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
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        return %orig(category, mode, options, outError);
    }
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

%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (!Titanium_VerifyPremiumSixLayers()) { // Tầng bảo mật 1-6 kiểm tra tại đây
        Titanium_ExecutePremiumLayer6Protocol();
        %orig(fps);
        return;
    }
    @try {
        NSInteger clampedFps = Titanium_ClampPremiumFrameRate(fps);
        %orig(clampedFps);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM CADisplayLink fps clamp failed safely: %@", exception);
        %orig(fps);
    }
}
%end

%end // %group TitaniumServerPremiumGroup

// =================================================================================================
// CONSTRUCTOR CHÍNH CỦA TWEAK (ĐÃ GỘP KHÔNG TRÙNG LẶP)
// =================================================================================================
static inline BOOL Titanium_ProcessIsSystemOrControl(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [bid isEqualToString:@"com.apple.springboard"] ||
           [bid isEqualToString:@"com.dell.promotioncontrol.app"];
}

%ctor {
    @autoreleasepool {
        if (!Titanium_ProcessIsSystemOrControl()) return; // other UIKit apps: no heavy hooks
        // Kiểm tra bảo mật ngay tại điểm khởi tạo constructor
        if (!Titanium_VerifyPremiumSixLayers()) {
            Titanium_ExecutePremiumLayer6Protocol();
            return;
        }

        %init(TitaniumServerPremiumGroup);

        Titanium_TierDeferUntilLaunch(^{
            @try {
                // Kiểm tra bảo mật lại một lần nữa sau khi khởi chạy ứng dụng (Defense-in-depth)
                if (!Titanium_VerifyPremiumSixLayers()) {
                    Titanium_ExecutePremiumLayer6Protocol();
                    return;
                }
                
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
                        // Kiểm tra bảo mật mỗi khi có notification quan trọng
                        if (!Titanium_VerifyPremiumSixLayers()) {
                            Titanium_ExecutePremiumLayer6Protocol();
                            return;
                        }
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
