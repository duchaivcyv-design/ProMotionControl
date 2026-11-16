// =================================================================================================
// TitaniumAbsoluteAntiThrottleEngine.x
// User-supplied absolute anti-throttle / exact-refresh module, integrated for the shared
// FREE / PREMIUM / ADMIN Titanium bridge. Every supplied hook section is kept.
//
// Upgrade notes (no supplied section removed):
//  - Added <math.h> for fmax/fmin, converted the supplied stray "end" to "%end".
//  - Added effective Hz/FPS helpers so a profile that only selects Hz or only FPS never
//    produces a 0 Hz / 0 FPS hardware request.
//  - All rates are clamped to 10...244 before being divided or handed to the panel.
//  - Thermal/LPM getters call %orig first to preserve the hook chain of the other modules.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <pthread.h>
#import <math.h>
#import "TitaniumSettingsAPI.h"

// Khai báo extern lấy thông số Hz & FPS chuẩn xác từ Core API
extern NSInteger Titanium_GetMasterRate(void);
extern NSInteger Titanium_GetMasterFPS(void);
extern BOOL Apex_IsMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;

#pragma mark - Shared helpers

// Fallback between Hz and FPS selections, then clamp to a hardware-safe window.
static inline NSInteger Titanium_AntiThrottleEffectiveRate(void) {
    NSInteger rate = Titanium_GetMasterRate();
    if (rate <= 0) rate = Titanium_GetMasterFPS();
    return MIN(MAX(rate, 10), 244);
}

static inline NSInteger Titanium_AntiThrottleEffectiveFPS(void) {
    NSInteger fps = Titanium_GetMasterFPS();
    if (fps <= 0) fps = Titanium_GetMasterRate();
    return MIN(MAX(fps, 10), 244);
}

// 1 / Hz, guarded against a zero denominator.
static inline double Titanium_AntiThrottleFrameDuration(void) {
    return 1.0 / (double)Titanium_AntiThrottleEffectiveRate();
}

// True only when the master engine is on and this app is not excluded by the user's
// profile list. The package itself is already scoped to the control app by ProMotionControl.plist.
static inline BOOL Titanium_AntiThrottleActive(void) {
    return Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted;
}

// Kernel/GPU/thermal-state spoofing must never run inside the control app itself:
// forcing AGX power/perf state or swallowing IORegistry power properties breaks
// MapKit's Metal tile rendering (blank map) and falsifies the app's own thermal
// telemetry. Display-rate hooks (sections 1-3) stay active everywhere.
static inline BOOL Titanium_AntiThrottleSystemHooksAllowed(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return Titanium_AntiThrottleActive() &&
           ![bundle isEqualToString:@"com.dell.promotioncontrol.app"];
}

%group TitaniumAbsoluteAntiThrottleGroup

// =================================================================================================
// 1. CADISPLAYLINK — Ép chính xác Hz/FPS đã chọn cho mọi vòng lặp render
// =================================================================================================
%hook CADisplayLink
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (Titanium_AntiThrottleActive()) {
        NSInteger targetHz = Titanium_AntiThrottleEffectiveRate();

        // Khai báo chính xác min = max = preferred để iOS không tự do hạ xuống mức thấp hơn.
        float exactHz = (float)fmax(10, fmin((double)targetHz, 244.0));
        CAFrameRateRange lockedRange = CAFrameRateRangeMake(exactHz, exactHz, exactHz);

        %orig(lockedRange);
        return;
    }
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (Titanium_AntiThrottleActive()) {
        NSInteger targetFPS = Titanium_AntiThrottleEffectiveFPS();
        NSInteger exactFPS = (NSInteger)fmax(10, fmin((double)targetFPS, 244.0));

        %orig(exactFPS);
        return;
    }
    %orig(fps);
}
%end

// =================================================================================================
// 2. CAWINDOWSERVERDISPLAY — Khóa thời lượng khung hình và tần số quét tối đa
// =================================================================================================
%hook CAWindowServerDisplay
- (void)setMinimumFrameDuration:(double)duration {
    if (Titanium_AntiThrottleActive()) {
        // Thời lượng khung hình tương ứng chính xác mức Hz đã chọn.
        double exactDuration = Titanium_AntiThrottleFrameDuration();
        %orig(exactDuration);
        return;
    }
    %orig(duration);
}

- (double)minimumFrameDuration {
    double originalDuration = %orig;
    if (Titanium_AntiThrottleActive()) {
        return Titanium_AntiThrottleFrameDuration();
    }
    return originalDuration;
}

- (void)setMaximumRefreshRate:(double)rate {
    if (Titanium_AntiThrottleActive()) {
        %orig((double)Titanium_AntiThrottleEffectiveRate());
        return;
    }
    %orig(rate);
}

- (double)maximumRefreshRate {
    double originalRate = %orig;
    if (Titanium_AntiThrottleActive()) {
        return (double)Titanium_AntiThrottleEffectiveRate();
    }
    return originalRate;
}
%end

// =================================================================================================
// 3. IOMOBILEFRAMEBUFFERCLIENT — Chặn lệnh hạ tần số quét từ tầng framebuffer
// =================================================================================================
%hook IOMobileFramebufferClient
- (int)setDisplayRefreshRate:(float)rate options:(unsigned int)options {
    if (Titanium_AntiThrottleActive()) {
        // Bỏ qua yêu cầu hạ Hz; báo thành công để caller không retry bằng đường khác.
        return 0;
    }
    return %orig(rate, options);
}

- (int)getDisplayRefreshRate:(float *)arg1 {
    if (Titanium_AntiThrottleActive()) {
        if (arg1) {
            *arg1 = (float)Titanium_AntiThrottleEffectiveRate();
        }
        return 0;
    }
    return %orig(arg1);
}

- (float)getDisplayRefreshRate {
    float originalRate = %orig;
    if (Titanium_AntiThrottleActive()) {
        return (float)Titanium_AntiThrottleEffectiveRate();
    }
    return originalRate;
}
%end

// =================================================================================================
// 4. IOREGISTRY & POWER MANAGEMENT — Triệt tiêu lệnh bóp hiệu năng ở tầng thuộc tính
// =================================================================================================
%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Titanium_AntiThrottleSystemHooksAllowed() && key) {
        NSString *lowerKey = [key lowercaseString];
        if ([lowerKey containsString:@"thermal"] || [lowerKey containsString:@"power"] ||
            [lowerKey containsString:@"throttle"] || [lowerKey containsString:@"performance"]) {
            return KERN_SUCCESS;
        }
    }
    return %orig(key, value);
}
%end

// =================================================================================================
// 5. PROCESS INFO — Khóa trạng thái nhiệt độ và Low Power Mode ở mức hiệu năng đầy đủ
// =================================================================================================
%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    NSProcessInfoThermalState realState = %orig;
    if (Titanium_AntiThrottleSystemHooksAllowed()) {
        // Báo Nominal để iOS không hạ Hz/FPS, nhưng vẫn gọi %orig trước để các module
        // khác (Hardware Overdrive, Thermal Battery Guardian) giữ đúng chuỗi hook.
        return NSProcessInfoThermalStateNominal;
    }
    return realState;
}

- (BOOL)isLowPowerModeEnabled {
    BOOL realLowPower = %orig;
    if (Titanium_AntiThrottleSystemHooksAllowed()) {
        return NO;
    }
    return realLowPower;
}
%end

// =================================================================================================
// 6. AGXACCELERATOR — Ép GPU/CPU bám mức hiệu năng cao nhất, chống tụt khung hình
// =================================================================================================
%hook AGXAccelerator
- (int)setPowerState:(unsigned int)state {
    if (Titanium_AntiThrottleSystemHooksAllowed()) {
        %orig(1);
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Titanium_AntiThrottleSystemHooksAllowed()) {
        %orig(1);
        return;
    }
    %orig(state);
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo module chống bóp Hz/FPS tuyệt đối
// =================================================================================================
%ctor {
    @autoreleasepool {
        %init(TitaniumAbsoluteAntiThrottleGroup);
    }
}
