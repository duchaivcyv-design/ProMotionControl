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
#import <objc/runtime.h>

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
// SỬA LỖI: Thêm dấu chấm phẩy vào sau __VA_ARGS__ để đảm bảo cú pháp hợp lệ sau khi mở rộng macro.
// Đồng thời, thêm một `@catch` chung để bắt mọi loại ngoại lệ.
#define PM_SAFE_TRY(...) \
    @try { __VA_ARGS__; } \
    @catch (NSException *exception) { \
        NSLog(@"[ProMotionControl/Deep] ObjC exception: %@ reason=%@", exception.name, exception.reason); \
    } @catch (...) { \
        NSLog(@"[ProMotionControl/Deep] Non-NSException swallowed (unknown type)"); \
    }
#endif

// Bridge integration: Titanium_GetMasterRate() returns 0 when the active tier has
// no numeric Hz selected (AUTO). Feeding 0 into 1.0/rate produces +inf frame
// durations, so the Deep layer only overrides while a real 10...244 Hz value exists.
static inline NSInteger Titanium_DeepEffectiveRate(void) {
    NSInteger rate = Titanium_GetMasterRate();
    return (rate >= 10 && rate <= 244) ? rate : 0; // Đảm bảo rate > 0
}

static inline BOOL Titanium_DeepShouldOverride(void) {
    return Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted && Titanium_DeepEffectiveRate() > 0;
}


// =================================================================================================
// Display-mode proxy. Wraps the REAL CADisplayMode object from the system and overrides only the
// refresh-rate getters. Every other selector (width, height, pixel format, description, ...) is
// forwarded to the real object, so FrontBoardServices always receives a valid mode. Nothing is
// fabricated and no pixel-clock / timing-flag values are forced.
// =================================================================================================
@interface TitaniumDisplayModeProxy : NSProxy {
    id _realMode;
    double (^_rateProvider)(void);
}
- (instancetype)initWithRealMode:(id)realMode rateProvider:(double (^)(void))rateProvider;
- (id)realMode;
@end

@implementation TitaniumDisplayModeProxy

- (instancetype)initWithRealMode:(id)realMode rateProvider:(double (^)(void))rateProvider {
    _realMode = realMode;
    _rateProvider = [rateProvider copy];
    return self;
}

- (id)realMode { return _realMode; }

- (double)pm_effectiveRate {
    double rate = _rateProvider ? _rateProvider() : 0.0;
    return rate > 0.0 ? rate : 60.0;
}

- (double)refreshRate            { return [self pm_effectiveRate]; }
- (double)refreshRateForMode     { return [self pm_effectiveRate]; }
- (double)safeRefreshRate        { return [self pm_effectiveRate]; }
- (double)nominalRefreshRate     { return [self pm_effectiveRate]; }
// pixelClock / timingFlags are forwarded to the real mode. Forcing 0xFFFFFFFF there is passed
// to the display driver by FrontBoard and resets SpringBoard on mode changes.

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [_realMode methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:_realMode];
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [_realMode respondsToSelector:sel] || class_respondsToSelector([TitaniumDisplayModeProxy class], sel);
}

- (BOOL)isKindOfClass:(Class)cls {
    return [_realMode isKindOfClass:cls];
}

- (NSString *)description      { return [_realMode description]; }
- (NSString *)debugDescription { return [_realMode debugDescription]; }
- (NSUInteger)hash             { return [_realMode hash]; }
- (BOOL)isEqual:(id)object {
    id other = object_getClass(object) == [TitaniumDisplayModeProxy class]
        ? [(TitaniumDisplayModeProxy *)object realMode] : object;
    return [_realMode isEqual:other];
}

@end

id Titanium_WrapDisplayMode(id realMode, double (^rateProvider)(void)) {
    if (!realMode) return nil;
    if (object_getClass(realMode) == [TitaniumDisplayModeProxy class]) return realMode;
    return [[TitaniumDisplayModeProxy alloc] initWithRealMode:realMode rateProvider:rateProvider];
}

id Titanium_UnwrapDisplayMode(id mode) {
    if (mode && object_getClass(mode) == [TitaniumDisplayModeProxy class]) {
        return [(TitaniumDisplayModeProxy *)mode realMode];
    }
    return mode;
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
    int result = %orig(arg1);
    if (result == 0 && arg1 && *arg1 && Titanium_DeepShouldOverride()) {
        *arg1 = Titanium_WrapDisplayMode(*arg1, ^double(void) { return (double)Titanium_DeepEffectiveRate(); });
    }
    return result;
}

%end

// =================================================================================================
// 3. CAWINDOWSERVERDISPLAY — Khóa cứng nhịp khung hình, triệt tiêu độ trễ dựng hình
// =================================================================================================
%hook CAWindowServerDisplay
- (void)setMinimumFrameDuration:(double)duration {
    if (Titanium_DeepShouldOverride()) {
        NSInteger target = Titanium_DeepEffectiveRate();
        if (target <= 0) { // Đảm bảo target hợp lệ trước khi chia để tránh Infinity
            PM_SAFE_TRY(%orig(duration)); // Vẫn gọi orig với duration ban đầu nếu target không hợp lệ
            return;
        }
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
        // Đảm bảo Titanium_DeepEffectiveRate() > 0 để tránh lỗi.
        NSInteger effectiveRate = Titanium_DeepEffectiveRate();
        if (effectiveRate > 0) {
            %orig(effectiveRate);
        } else {
            %orig(fps); // Fallback về giá trị ban đầu nếu effectiveRate không hợp lệ
        }
        return;
    }
    %orig(fps);
}



- (NSArray *)availableModes {
    NSArray *orig = %orig;
    if (!orig || !Titanium_DeepShouldOverride()) return orig;
    NSMutableArray *wrapped = [NSMutableArray arrayWithCapacity:orig.count];
    for (id mode in orig) {
        [wrapped addObject:Titanium_WrapDisplayMode(mode, ^double(void) { return (double)Titanium_DeepEffectiveRate(); })];
    }
    return wrapped;
}
- (id)currentMode {
    id mode = %orig;
    if (mode && Titanium_DeepShouldOverride()) return Titanium_WrapDisplayMode(mode, ^double(void) { return (double)Titanium_DeepEffectiveRate(); });
    return mode;
}
- (void)setCurrentMode:(id)mode {
    %orig(Titanium_UnwrapDisplayMode(mode));
}

%end

%hook CADisplayLink
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (Titanium_DeepShouldOverride()) {
        NSInteger target = Titanium_DeepEffectiveRate();
        if (target <= 0) { // Đảm bảo target hợp lệ
            %orig(range);
            return;
        }
        %orig(CAFrameRateRangeMake((CGFloat)target, (CGFloat)target, (CGFloat)target));
        return;
    }
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (Titanium_DeepShouldOverride()) {
        // Đảm bảo Titanium_DeepEffectiveRate() > 0 để tránh lỗi.
        NSInteger effectiveRate = Titanium_DeepEffectiveRate();
        if (effectiveRate > 0) {
            %orig(effectiveRate);
        } else {
            %orig(fps); // Fallback về giá trị ban đầu nếu effectiveRate không hợp lệ
        }
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
        // Luôn ép trạng thái nguồn điện đồ họa ở mức cao nhất (state 1)
        // Các state khác có thể là low power, off, v.v.
        PM_SAFE_TRY(%orig(1));
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        // Luôn ép mức hiệu năng GPU tối đa (state 1), chống tụt xung
        PM_SAFE_TRY(%orig(1));
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
                // Chặn mọi yêu cầu giảm hiệu năng do nhiệt độ, nguồn điện hoặc điều tiết
                return KERN_SUCCESS;
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
static inline BOOL Titanium_ProcessIsSystemOrControl(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [bid isEqualToString:@"com.apple.springboard"] ||
           [bid isEqualToString:@"com.dell.promotioncontrol.app"];
}

%ctor {
    @autoreleasepool {
        if (!Titanium_ProcessIsSystemOrControl()) return; // other UIKit apps: no heavy hooks
        %init(TitaniumUltimateDeepGroup);
    }
}
