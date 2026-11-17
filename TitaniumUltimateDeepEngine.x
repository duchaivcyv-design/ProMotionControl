// =================================================================================================
// TitaniumUltimateDeepEngine.x
// Deep Hook Logos source supplied by the user for the ProMotionControl tweak.
// Integrated verbatim; the only edits are the ones required to compile as part
// of this project and to stay in sync with the FREE/PREMIUM/ADMIN
// TitaniumSettingsAPI bridge (which returns 0 when the corresponding override
// is AUTO/disabled).
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <pthread.h>

// --- Bridge externs, inlined ------------------------------------------------
extern NSInteger Titanium_GetMasterRate(void);
extern BOOL Apex_IsMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;
// ---------------------------------------------------------------------------

// Same exception-catch macro used by the main tweak; redeclared here so this
// file compiles independently of Tweak.xm's translation unit.
// NOTE: trailing semicolon is REQUIRED so call sites like PM_SAFE_TRY(%orig(...));
// compile as a complete statement when %orig expands to a function call.
#ifndef PM_SAFE_TRY
#define PM_SAFE_TRY(...) \
    @try { __VA_ARGS__ } \
    @catch (NSException *exception) { \
        NSLog(@"[ProMotionControl/Deep] ObjC exception: %@ reason=%@", exception.name, exception.reason); \
    } @catch (...) { \
        NSLog(@"[ProMotionControl/Deep] Non-NSException swallowed"); \
    }
#endif

// Bridge integration: Titanium_GetMasterRate() returns 0 when the active tier has
// no numeric Hz selected (AUTO). Feeding 0 into 1.0/rate produces +inf frame
// durations, so the Deep layer only overrides while a real 10...244 Hz value exists.
static inline NSInteger Titanium_DeepEffectiveRate(void) {
    NSInteger rate = Titanium_GetMasterRate();
    return (rate >= 10 && rate <= 244) ? rate : 0;
}

static inline BOOL Titanium_DeepShouldOverride(void) {
    return Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted && Titanium_DeepEffectiveRate() > 0;
}

// =================================================================================================
// 1. FAKE DISPLAY MODE & PIXELCLOCK UNLOCK (Vượt rào băng thông driver đồ họa)
// =================================================================================================
@interface TitaniumUltimateDisplayMode : NSObject
@end

@implementation TitaniumUltimateDisplayMode
- (double)refreshRate       { return (double)Titanium_DeepEffectiveRate(); }
- (double)refreshRateForMode { return (double)Titanium_DeepEffectiveRate(); }
- (double)safeRefreshRate    { return (double)Titanium_DeepEffectiveRate(); }
- (double)nominalRefreshRate { return (double)Titanium_DeepEffectiveRate(); }
- (double)pixelAspectRatio   { return 1.0; }
- (CGSize)size              { return [UIScreen mainScreen].nativeBounds.size; }
- (CGSize)pixelSize         { return [UIScreen mainScreen].nativeBounds.size; }
- (unsigned int)pixelClock  { return 0xFFFFFFFF; } // Lỗ hổng vô cực: Bỏ qua hoàn toàn giới hạn pixel clock của driver
- (uint32_t)timingFlags     { return 0xFFFFFFFF; } // Vô hiệu hóa cờ kiểm tra đồng bộ V-Sync cứng
@end

static TitaniumUltimateDisplayMode *Titanium_MakeUltimateMode(void) {
    static TitaniumUltimateDisplayMode *s_mode = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_mode = [[TitaniumUltimateDisplayMode alloc] init];
    });
    return s_mode;
}

%group TitaniumUltimateDeepGroup

// =================================================================================================
// 2. IOMOBILEFRAMEBUFFER — Chiếm quyền Driver phần cứng hiển thị trực tiếp
// =================================================================================================
%hook IOMobileFramebufferClient
- (int)setDisplayRefreshRate:(float)rate options:(unsigned int)options {
    if (Titanium_DeepShouldOverride()) {
        return 0; // Chặn mọi lệnh từ chối (reject) từ driver, ép trả về mã thành công
    }
    return %orig(rate, options);
}

- (int)setDisplayRefreshRate:(float)rate {
    if (Titanium_DeepShouldOverride()) {
        return 0;
    }
    return %orig(rate);
}

- (int)getDisplayRefreshRate:(float *)arg1 {
    if (Apex_IsMasterEnabled() && arg1) {
        *arg1 = (float)Titanium_DeepEffectiveRate();
        return 0;
    }
    return %orig(arg1);
}

- (float)getDisplayRefreshRate {
    if (Apex_IsMasterEnabled()) {
        return (float)Titanium_DeepEffectiveRate();
    }
    return %orig;
}

- (BOOL)isDisplayRefreshRateSupported:(float)rate {
    if (Apex_IsMasterEnabled()) return YES; // Cho phép toàn bộ dải từ 10Hz đến 244Hz
    return %orig(rate);
}

- (int)getDefaultDisplayMode:(id *)arg1 {
    if (Apex_IsMasterEnabled() && arg1) {
        *arg1 = (id)Titanium_MakeUltimateMode();
        return 0;
    }
    return %orig(arg1);
}
%end

// =================================================================================================
// 3. CAWINDOWSERVERDISPLAY — Khóa cứng nhịp khung hình, triệt tiêu độ trễ dựng hình
// =================================================================================================
%hook CAWindowServerDisplay
- (void)setMinimumFrameDuration:(double)duration {
    if (Titanium_DeepShouldOverride()) {
        NSInteger target = Titanium_DeepEffectiveRate();
        if (target <= 0) { %orig(duration); return; }
        PM_SAFE_TRY(%orig(1.0 / (double)target));
        return;
    }
    %orig(duration);
}

- (double)minimumFrameDuration {
    if (Titanium_DeepShouldOverride()) {
        NSInteger target = Titanium_DeepEffectiveRate();
        if (target <= 0) return %orig;
        return 1.0 / (double)target;
    }
    return %orig;
}

- (void)setMaximumRefreshRate:(double)rate {
    if (Titanium_DeepShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_DeepEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (double)maximumRefreshRate {
    if (Titanium_DeepShouldOverride()) return (double)Titanium_DeepEffectiveRate();
    return %orig;
}

- (void)setMinimumRefreshRate:(double)rate {
    if (Titanium_DeepShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_DeepEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (double)minimumRefreshRate {
    if (Titanium_DeepShouldOverride()) return (double)Titanium_DeepEffectiveRate();
    return %orig;
}

- (void)setIdealRefreshRate:(double)rate {
    if (Titanium_DeepShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_DeepEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (double)idealRefreshRate {
    if (Titanium_DeepShouldOverride()) return (double)Titanium_DeepEffectiveRate();
    return %orig;
}

- (BOOL)allowsVirtualModes { return YES; }
- (void)setAllowsVirtualModes:(BOOL)flag {
    %orig(YES);
}
%end

// =================================================================================================
// 4. CADISPLAY & CADISPLAYLINK — Ép xung nhịp toàn hệ thống bám sát mục tiêu
// =================================================================================================
%hook CADisplay
- (double)refreshRate {
    if (Titanium_DeepShouldOverride()) return (double)Titanium_DeepEffectiveRate();
    return %orig;
}

- (void)setRefreshRate:(double)rate {
    if (Titanium_DeepShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_DeepEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (NSInteger)preferredFPS {
    if (Titanium_DeepShouldOverride()) return Titanium_DeepEffectiveRate();
    return %orig;
}

- (void)setPreferredFPS:(NSInteger)fps {
    if (Titanium_DeepShouldOverride()) {
        %orig(Titanium_DeepEffectiveRate());
        return;
    }
    %orig(fps);
}

- (NSArray *)availableModes {
    NSArray *orig = %orig;
    if (Titanium_DeepShouldOverride()) {
        id mode = (id)Titanium_MakeUltimateMode();
        return mode ? (orig ? [orig arrayByAddingObject:mode] : @[mode]) : orig;
    }
    return orig;
}

- (id)currentMode {
    if (Titanium_DeepShouldOverride()) {
        id mode = (id)Titanium_MakeUltimateMode();
        if (mode) return mode;
    }
    return %orig;
}

- (void)setCurrentMode:(id)mode {
    if (Titanium_DeepShouldOverride()) {
        id targetMode = (id)Titanium_MakeUltimateMode();
        PM_SAFE_TRY(%orig(targetMode ? targetMode : mode));
        return;
    }
    %orig(mode);
}
%end

%hook CADisplayLink
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (Titanium_DeepShouldOverride()) {
        NSInteger target = Titanium_DeepEffectiveRate();
        if (target <= 0) { %orig(range); return; }
        %orig(CAFrameRateRangeMake((CGFloat)target, (CGFloat)target, (CGFloat)target));
        return;
    }
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (Titanium_DeepShouldOverride()) {
        %orig(Titanium_DeepEffectiveRate());
        return;
    }
    %orig(fps);
}
%end

// =================================================================================================
// 5. AGXACCELERATOR & IOREGISTRY — Ép xung công suất GPU và chặn kiểm soát nhiệt độ
// =================================================================================================
%hook AGXAccelerator
- (int)setPowerState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép trạng thái nguồn điện đồ họa ở mức cao nhất
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép mức hiệu năng GPU tối đa, chống tụt xung
        return;
    }
    %orig(state);
}
%end

%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Apex_IsMasterEnabled() && key) {
        // Cheap first-char guard: only "thermal"/"power"/"throttle" matter, so
        // avoid allocating lowercase strings for keys that clearly cannot match.
        unichar c0 = [key length] ? [key characterAtIndex:0] : 0;
        if (c0 == 't' || c0 == 'T' || c0 == 'p' || c0 == 'P') {
            NSString *kl = [key lowercaseString];
            if ([kl containsString:@"thermal"] || [kl containsString:@"power"] || [kl containsString:@"throttle"]) {
                return KERN_SUCCESS; // Chặn mọi yêu cầu giảm hiệu năng do nhiệt độ
            }
        }
    }
    return %orig(key, value);
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo toàn bộ hệ thống Deep Hook
// =================================================================================================
%ctor {
    @autoreleasepool {
        %init(TitaniumUltimateDeepGroup);
    }
}
