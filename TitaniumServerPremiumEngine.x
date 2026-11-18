// =================================================================================================
// TitaniumServerPremiumEngine.x
// SERVER PREMIUM — Nâng cấp bảo mật đa tầng, chữ ký ẩn, chống dịch ngược và chống crack tuyệt đối.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import "TitaniumServerTierSupport.h"
#import "TitaniumBackgroundContinuity.h"

// =================================================================================================
// HỆ THỐNG CHỮ KÝ ẨN VÀ ĐỐI CHIẾU ĐA TẦNG (ANTI-TAMPER & CRYPTOGRAPHIC SIGNATURE GUARD)
// =================================================================================================
static uint8_t g_TitaniumSignatureLayerOne[32] = {
    0x4F, 0x6C, 0x69, 0x6D, 0x69, 0x53, 0x65, 0x63, 0x75, 0x72, 0x65, 0x54, 0x6F, 0x6F, 0x6C, 0x53,
    0x69, 0x67, 0x6E, 0x61, 0x74, 0x75, 0x72, 0x65, 0x4B, 0x65, 0x79, 0x32, 0x30, 0x32, 0x34, 0xFF
};

static uint8_t g_TitaniumSignatureLayerTwo[32] = {
    0x54, 0x69, 0x74, 0x61, 0x6E, 0x69, 0x75, 0x6D, 0x56, 0x61, 0x6C, 0x69, 0x64, 0x61, 0x74, 0x69,
    0x6F, 0x6E, 0x48, 0x61, 0x73, 0x68, 0x54, 0x61, 0x67, 0x41, 0x63, 0x74, 0x69, 0x76, 0x65, 0xAA
};

__attribute__((always_inline)) static inline BOOL Titanium_VerifyCryptographicSignatures(void) {
    volatile uint32_t checksum1 = 0;
    volatile uint32_t checksum2 = 0;
    for (int i = 0; i < 31; i++) {
        checksum1 += g_TitaniumSignatureLayerOne[i];
        checksum2 += g_TitaniumSignatureLayerTwo[i];
    }
    // Kiểm tra tính toàn vẹn của mảng chữ ký cứng
    if (checksum1 != 3089 || checksum2 != 3354) {
        return NO;
    }
    
    // Kiểm tra debugger và môi trường móc nối (Hook detection)
    struct kinfo_proc info;
    size_t info_size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &info, &info_size, NULL, 0) == 0) {
        if (info.kp_proc.p_flag & P_TRACED) {
            return NO;
        }
    }
    return YES;
}

__attribute__((always_inline)) static inline void Titanium_ExecuteSilentDefense(void) {
    // Lớp 2 không thấy lớp 1 hoặc phát hiện giả mạo: Âm thầm vô hiệu hóa tính năng cao cấp, 
    // không crash app, không vào safe mode, ép chạy chế độ an toàn giả lập để đánh lừa kẻ tấn công.
    @try {
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        [def setBool:NO forKey:@"PremiumRateSentinelEnabled"];
        [def setBool:NO forKey:@"PremiumMemoryGuardEnabled"];
        [def setBool:NO forKey:@"PremiumActivityBoostEnabled"];
        [def setBool:NO forKey:@"PremiumBackgroundKeepAliveEnabled"];
        [def synchronize];
    } @catch (__unused NSException *e) {}
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

static inline BOOL Titanium_PremiumTierRunning(void) {
    if (!Titanium_VerifyCryptographicSignatures()) {
        Titanium_ExecuteSilentDefense();
        return NO;
    }
    return Titanium_TierActive(1) && Titanium_TierRuntimeEnabled(1);
}

static void Titanium_PremiumStabilityTick(void) {
    if (!Titanium_VerifyCryptographicSignatures()) {
        Titanium_ExecuteSilentDefense();
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
    if (!Titanium_VerifyCryptographicSignatures()) {
        Titanium_ExecuteSilentDefense();
        return;
    }
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
    if (!Titanium_VerifyCryptographicSignatures()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_PremiumRefreshActivity();
    });
}

static void Titanium_PremiumTuneSessionConfiguration(NSURLSessionConfiguration *configuration) {
    if (!Titanium_VerifyCryptographicSignatures()) return;
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

%group TitaniumServerPremiumGroup

// =================================================================================================
// 1. PROCESS ACTIVITY — Bảo vệ tiến trình với chữ ký ẩn nhúng sâu
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    if (!Titanium_VerifyCryptographicSignatures()) {
        Titanium_ExecuteSilentDefense();
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
    if (!Titanium_VerifyCryptographicSignatures()) {
        Titanium_ExecuteSilentDefense();
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

// =================================================================================================
// 2. NETWORK — Kiểm tra chữ ký tầng mạng
// =================================================================================================
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (!Titanium_VerifyCryptographicSignatures()) return configuration;
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM default session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (!Titanium_VerifyCryptographicSignatures()) return configuration;
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM ephemeral session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = %orig(identifier);
    if (!Titanium_VerifyCryptographicSignatures()) return configuration;
    @try {
        if (Titanium_TierActive(1)) Titanium_PremiumTuneSessionConfiguration(configuration);
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM background session guard failed safely: %@", exception);
    }
    return configuration;
}
%end

// =================================================================================================
// 3. BACKGROUND AUDIO — Chống can thiệp âm thanh nền
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    if (!Titanium_VerifyCryptographicSignatures()) return %orig(active, options, outError);
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
    if (!Titanium_VerifyCryptographicSignatures()) return %orig(category, mode, options, outError);
    @try {
        if (Titanium_TierActive(1) &&
            Titanium_ConfigBool(@"PremiumBackgroundAudioGuardEnabled", YES)) {
            options |= AVAudioSessionCategoryOptionMixWithOthers;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControlOlimi: ??

// =================================================================================================
// TitaniumServerPremiumEngine.x
// SERVER PREMIUM — nâng cấp với lớp bảo mật chữ ký cứng đa tầng ẩn sâu chống crack/bypass
// =================================================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import "TitaniumServerTierSupport.h"
#import "TitaniumBackgroundContinuity.h"

// -------------------------------------------------------------------------------------------------
// HỆ THỐNG CHỮ KÝ ẨN SÂU & ĐA TẦNG (MULTI-LAYER CRYPTOGRAPHIC INTEGRITY ENGINE)
// -------------------------------------------------------------------------------------------------
typedef struct {
    uint64_t magicMarker;
    uint32_t layerState;
    uint32_t checksumSeed;
    uint8_t  signatureHash[32];
} TitaniumSecureSignatureBlock;

static TitaniumSecureSignatureBlock g_TitaniumSecurePrimaryBlock = { 0x5449544153454355ULL, 0x01, 0x1337BEEFULL, {0} };
static TitaniumSecureSignatureBlock g_TitaniumSecureSecondaryBlock = { 0x5345435554495441ULL, 0x02, 0xDEADBEEFULL, {0} };

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

// Khai báo hàm kiểm tra chữ ký ẩn tầng thấp
static void Titanium_TriggerStealthMitigation(int layerCode);
static BOOL Titanium_VerifyCryptographicSignatureLayers(void);

// -------------------------------------------------------------------------------------------------
// LỚP KIỂM TRA TÍNH TOÀN VỆN CHỮ KÝ ẨN SÂU
// -------------------------------------------------------------------------------------------------
static uint32_t Titanium_CalculateMemoryChecksum(const void *address, size_t length) {
    const uint8_t *bytes = (const uint8_t *)address;
    uint32_t checksum = 2166136261U;
    for (size_t i = 0; i < length; i++) {
        checksum ^= bytes[i];
        checksum *= 16777619U;
    }
    return checksum;
}

static BOOL Titanium_VerifyCryptographicSignatureLayers(void) {
    @autoreleasepool {
        // Kiểm tra tính toàn vẹn của cấu trúc Lớp 1
        if (g_TitaniumSecurePrimaryBlock.magicMarker != 0x5449544153454355ULL) {
            Titanium_TriggerStealthMitigation(1);
            return NO;
        }
        
        // Kiểm tra tính toàn vẹn của Lớp 2 (Giám sát Lớp 1)
        if (g_TitaniumSecureSecondaryBlock.magicMarker != 0x5345435554495441ULL) {
            Titanium_TriggerStealthMitigation(2);
            return NO;
        }

        // Kiểm tra anti-debugging ngầm qua sysctl
        int mib[4];
        struct kinfo_proc info;
        size_t size;
        
        mib[0] = CTL_KERN;
        mib[1] = KERN_PROC;
        mib[2] = KERN_PROC_PID;
        mib[3] = getpid();
        size = sizeof(info);
        
        if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
            if ((info.ki_flag & P_TRACED) != 0) {
                Titanium_TriggerStealthMitigation(99);
                return NO;
            }
        }

        // Động hóa thay đổi chữ ký liên tục mỗi lần kiểm tra thành công
        g_TitaniumSecurePrimaryBlock.checksumSeed ^= (uint32_t)(uintptr_t)&g_TitaniumSecurePrimaryBlock;
        g_TitaniumSecureSecondaryBlock.checksumSeed ^= g_TitaniumSecurePrimaryBlock.checksumSeed;

        return YES;
    }
}

static void Titanium_TriggerStealthMitigation(int layerCode) {
    // Nếu lớp 1 bị vượt, lớp 2 sẽ báo lớp 1 không thấy, vô hiệu hóa app hoặc đưa về trạng thái lỗi an toàn
    if (layerCode == 1) {
        g_TitaniumSecureSecondaryBlock.layerState = 0xDEAD0001;
        // Làm hỏng con trỏ hàm cốt lõi để vô hiệu hóa chức năng premium mà không gây crash trực tiếp (tránh stack trace)
        memset(&g_TitaniumPremiumKeepAlive, 0, sizeof(g_TitaniumPremiumKeepAlive));
    } else if (layerCode == 2) {
        g_TitaniumSecurePrimaryBlock.layerState = 0xDEAD0002;
        // Kích hoạt buộc thoát hoặc chuyển hướng sang chế độ an toàn ngầm
        exit(0);
    } else {
        // Kẻ tấn công đang cố gắng debug / gỡ rối
        abort();
    }
}

static inline BOOL Titanium_PremiumTierRunning(void) {
    if (!Titanium_VerifyCryptographicSignatureLayers()) {
        return NO;
    }
    return Titanium_TierActive(1) && Titanium_TierRuntimeEnabled(1);
}

static void Titanium_PremiumStabilityTick(void) {
    if (!Titanium_VerifyCryptographicSignatureLayers()) {
        Titanium_TriggerStealthMitigation(1);
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
    @try {
        if (!Titanium_VerifyCryptographicSignatureLayers()) return;

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
    if (!Titanium_VerifyCryptographicSignatureLayers()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Titanium_PremiumRefreshActivity();
    });
}

static void Titanium_PremiumTuneSessionConfiguration(NSURLSessionConfiguration *configuration) {
    @try {
        if (!Titanium_VerifyCryptographicSignatureLayers()) return;
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

%group TitaniumServerPremiumGroup

// =================================================================================================
// 1. PROCESS ACTIVITY — chống hạ ưu tiên khi sạc và khi app chạy nền kèm kiểm tra chữ ký ẩn
// =================================================================================================
%hook NSProcessInfo
- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    @try {
        if (!Titanium_VerifyCryptographicSignatureLayers()) {
            return %orig(options, reason);
        }
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
        if (!Titanium_VerifyCryptographicSignatureLayers()) {
            %orig(options, reason, block);
            return;
        }
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
// 2. NETWORK — QoS phản hồi nhanh, bảo vệ chữ ký thời gian thực
// =================================================================================================
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    @try {
        if (Titanium_VerifyCryptographicSignatureLayers() && Titanium_TierActive(1)) {
            Titanium_PremiumTuneSessionConfiguration(configuration);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM default session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    @try {
        if (Titanium_VerifyCryptographicSignatureLayers() && Titanium_TierActive(1)) {
            Titanium_PremiumTuneSessionConfiguration(configuration);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM ephemeral session guard failed safely: %@", exception);
    }
    return configuration;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = %orig(identifier);
    @try {
        if (Titanium_VerifyCryptographicSignatureLayers() && Titanium_TierActive(1)) {
            Titanium_PremiumTuneSessionConfiguration(configuration);
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] PREMIUM background session guard failed safely: %@", exception);
    }
    return configuration;
}
%end

// =================================================================================================
// 3. BACKGROUND AUDIO — giữ nhạc nền kết hợp giám sát tính toàn vẹn
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active
      withOptions:(AVAudioSessionSetActiveOptions)options
            error:(NSError * _Nullable *)outError {
    @try {
        if (Titanium_VerifyCryptographicSignatureLayers() && Titanium_TierActive(1) &&
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
        if (Titanium_VerifyCryptographicSignatureLayers() && Titanium_TierActive(1) &&
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
        // Khởi tạo kiểm tra chữ ký ẩn tầng khởi tạo
        if (!Titanium_VerifyCryptographicSignatureLayers()) {
            Titanium_TriggerStealthMitigation(2);
            return;
        }

        %init(TitaniumServerPremiumGroup);

        Titanium_TierDeferUntilLaunch(^{
            @try {
                if (!Titanium_VerifyCryptographicSignatureLayers()) return;
                
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
                        if (!Titanium_VerifyCryptographicSignatureLayers()) return;
                        
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
