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
//
// 8.4.0t integration notes (user requested no .h changes):
//  - Removed `#import "TitaniumSettingsAPI.h"`. The bridge externs are inlined
//    below so this file builds standalone against the existing dylib symbols.
//  - Titanium_GetMasterFPS() does NOT exist in the bridge. In this build,
//    PM_ExportMasterRate() already returns PMGetTargetFPS() — i.e. the FPS
//    selection is the master rate. Aliased via a static inline so the call
//    sites in this file stay verbatim.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <pthread.h>
#import <math.h>

// --- Bridge externs, inlined (was: #import "TitaniumSettingsAPI.h") ---------
extern NSInteger PM_ExportMasterRate(void);
extern BOOL PM_ExportMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;

// These two resolve to the bridge's TitaniumSettingsAPI.x definitions.
extern NSInteger Titanium_GetMasterRate(void);
extern BOOL Apex_IsMasterEnabled(void);

// [8.4.0t] Alias for the missing Titanium_GetMasterFPS(). PM_ExportMasterRate
// already returns PMGetTargetFPS() in Tweak.xm, so Hz and FPS resolve to the
// same value in this build. Kept as a separate symbol so the supplied call
// sites in Titanium_AntiThrottleEffectiveFPS() remain verbatim.
static inline NSInteger Titanium_GetMasterFPS(void) { return PM_ExportMasterRate(); }
// ---------------------------------------------------------------------------

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
//
// NOTE: also %hooked by Tweak.xm (8.0.1t), Deep (8.1.0t), Supreme (8.3.0t).
// 4-way chain in registration order: AntiThrottle -> Supreme -> Deep -> Tweak.xm -> real.
// Each layer, when active, writes [target, target, target]. All four resolve target
// from PM_ExportMasterRate() (same value), so the final output is identical regardless
// of chain depth. Cost is 4x dispatch per setter call — acceptable, but if you ever
// want to slim the hot path, remove this module's CADisplayLink section or remove
// the equivalent section from Tweak.xm/Deep/Supreme (all four are redundant).
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
//
// NOTE: also %hooked by Deep (8.1.0t) and Supreme (8.3.0t). Same contract,
// idempotent — 3-way chain. 1.0/rate is safe here because all three modules
// clamp the rate to 10..244 before dividing.
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
//
// NOTE: also %hooked by Deep (8.1.0t) and Supreme (8.3.0t). 3-way chain. The
// framebuffer write is a no-op on iOS 15+ in userspace (returns -1 / rejects)
// regardless of hook; the hook short-circuits with return 0 for callers that
// interpret success, avoiding the retry path. No physical hardware change.
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
//
// NOTE: 4th %hook on IORegistryEntry:setCFProperty:withValue:. Full chain:
// AntiThrottle -> Supreme -> Overdrive -> Deep -> real IORegistry.
// AntiThrottle is guarded by Titanium_AntiThrottleSystemHooksAllowed(), which
// returns NO in com.dell.promotioncontrol.app — the ONLY bundle this tweak
// loads in. Net effect: this section is a pass-through %orig in the control
// app. Its real target is SpringBoard (out of current filter scope). Ship as
// supplied; document only.
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
//
// NOTE: 3rd %hook on NSProcessInfo thermalState / isLowPowerModeEnabled. Chain:
// AntiThrottle -> Supreme -> Overdrive -> real. AntiThrottle is guarded by
// Titanium_AntiThrottleSystemHooksAllowed() — this section is a pass-through
// in the control app. Section 4/5/6 combined are dead code in the current
// filter (control-app-only); they exist for future SpringBoard injection.
// %orig is called first, per the supplied code, so the chain stays correct.
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
//
// NOTE: 4th %hook on AGXAccelerator. Also guarded by
// Titanium_AntiThrottleSystemHooksAllowed(). AGXAccelerator is kernel-side and
// does not exist in a userspace app process — the %hook compiles to a Logos
// no-op regardless of the guard. Pass-through %orig.
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
