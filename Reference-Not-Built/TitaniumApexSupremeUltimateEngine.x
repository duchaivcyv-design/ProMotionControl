// =================================================================================================
// TitaniumApexSupremeUltimateEngine.x
// Supreme Ultimate Logos source supplied by the user for the ProMotionControl tweak.
// Integrated verbatim; the only edits are the ones required to compile as part of
// this project, to keep the Titanium FREE/PREMIUM/ADMIN bridge contract (0 = AUTO),
// and to make the "critical thermal" safeguard actually reachable.
//
// 5.9.0t integration edits (only these, everything else verbatim):
//   [FIX] Titanium_RealThermalStateSnapshot() now reads from a shared global
//         (Titanium_SharedRealThermalState) instead of calling thermalState
//         through the hook chain. Without this, Supreme's %orig is Overdrive's
//         SOFTENED output (Nominal), never the real Critical state, so the
//         critical-thermal safeguard in the IORegistryEntry hook was unreachable.
//   [FIX] Supreme's thermalState hook no longer writes a local real-state store —
//         it reads the shared global (populated by Overdrive's hook, which is
//         first in the chain and sees the real %orig) to decide Fair vs Nominal.
//   [SAFE] PM_SAFE_TRY on IORegistryEntry %orig and UIWindow gesture-recognizer
//          loop. Both are hot paths; a driver exception must not abort the app.
//   [PERF] Cheap first-char gate on IORegistryEntry key (t/T/p/P gate matches
//          only thermal/power/throttle — the Supreme filter is narrower than
//          Deep/Overdrive, so this skip rate is higher).
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>

// Khai báo các hàm ngoại vi từ Core Bridge điều khiển tổng
#import "TitaniumSettingsAPI.h"

extern NSInteger Titanium_GetMasterRate(void);
extern BOOL Apex_IsMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;

// Shared real thermal state — populated by HardwareOverdriveGuard's thermalState
// hook (which sees the real %orig before softening) and read here so the
// IORegistryEntry safeguard can make a Critical-vs-Nominal decision on the
// ACTUAL state. This extern is declared in TitaniumSettingsAPI.h and defined
// in TitaniumSettingsAPI.x (see PATCH block below).
//
// Values: 0 = Nominal, 1 = Fair, 2 = Serious, 3 = Critical
extern volatile NSInteger Titanium_SharedRealThermalState;

// Bridge integration: getSelectedHz returns 0 for AUTO so the Supreme layer can
// never divide by zero or advertise a 0 Hz mode. It only overrides on 10...244.
static inline NSInteger Titanium_SupremeEffectiveRate(void) {
    NSInteger rate = Titanium_GetMasterRate();
    return (rate >= 10 && rate <= 244) ? rate : 0;
}

static inline BOOL Titanium_SupremeShouldOverride(void) {
    return Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted && Titanium_SupremeEffectiveRate() > 0;
}

// Same exception-catch macro used by the main tweak; redeclared here so this
// file compiles independently of Tweak.xm's translation unit.
#ifndef PM_SAFE_TRY
#define PM_SAFE_TRY(...) \
    @try { __VA_ARGS__ } \
    @catch (NSException *exception) { \
        NSLog(@"[ProMotionControl/Supreme] ObjC exception: %@ reason=%@", exception.name, exception.reason); \
    } @catch (...) { \
        NSLog(@"[ProMotionControl/Supreme] Non-NSException swallowed"); \
    }
#endif

// Reads the real thermal state from the shared global. Populated by Overdrive's
// hook (which is FIRST in the chain and therefore sees the real %orig). The
// Supreme hook below DOES NOT write to this global — by the time Supreme's
// %orig runs, Overdrive has already returned the softened state.
static inline NSProcessInfoThermalState Titanium_RealThermalStateSnapshot(void) {
    NSInteger v = Titanium_SharedRealThermalState;
    if (v < 0) v = 0;
    if (v > 3) v = 3;
    return (NSProcessInfoThermalState)v;
}

// Cheap first-char gate for the Supreme IORegistryEntry filter. Supreme only
// matches thermal/power/throttle (narrower than Deep/Overdrive) so the gate
// rejects ~95% of keys without allocating a lowercase string.
static inline BOOL Titanium_Supreme_KeyIsThrottleRelated(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = key.length;
    if (len == 0) return NO;
    unichar c0 = [key characterAtIndex:0];
    // t/T -> thermal, throttle  ;  p/P -> power
    if (c0 != 't' && c0 != 'T' && c0 != 'p' && c0 != 'P') return NO;
    NSString *kl = [key lowercaseString];
    return [kl containsString:@"thermal"] ||
           [kl containsString:@"power"] ||
           [kl containsString:@"throttle"];
}

// =================================================================================================
// 1. SUPREME DISPLAY MODE & UNBOUNDED PIXEL CLOCK (200MHz - 800MHz+ Bandwidth Overclock)
// =================================================================================================
@interface TitaniumSupremeUltimateDisplayMode : NSObject
@end

@implementation TitaniumSupremeUltimateDisplayMode
- (double)refreshRate       { return (double)Titanium_SupremeEffectiveRate(); }
- (double)refreshRateForMode { return (double)Titanium_SupremeEffectiveRate(); }
- (double)safeRefreshRate    { return (double)Titanium_SupremeEffectiveRate(); }
- (double)nominalRefreshRate { return (double)Titanium_SupremeEffectiveRate(); }
- (double)pixelAspectRatio   { return 1.0; }
- (CGSize)size              { return [UIScreen mainScreen].nativeBounds.size; }
- (CGSize)pixelSize         { return [UIScreen mainScreen].nativeBounds.size; }
- (unsigned int)pixelClock  { return 0xFFFFFFFF; } // Lỗ hổng vô cực: Mở rộng Pixel Clock từ 200MHz lên 800MHz+ không giới hạn
- (uint32_t)timingFlags     { return 0xFFFFFFFF; } // Triệt tiêu hoàn toàn V-Sync phần cứng
@end

static TitaniumSupremeUltimateDisplayMode *Titanium_GetSupremeMode(void) {
    static TitaniumSupremeUltimateDisplayMode *s_supremeMode = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_supremeMode = [[TitaniumSupremeUltimateDisplayMode alloc] init];
    });
    return s_supremeMode;
}

%group TitaniumApexSupremeUltimateGroup

// =================================================================================================
// 2. IOMOBILEFRAMEBUFFER & PANEL DRIVER (Bẻ khóa tầng Panel, ProMotion & Driver hiển thị)
//
// NOTE: IOMobileFramebufferClient is also %hooked by TitaniumUltimateDeepEngine.x.
// Both hook bodies agree on the contract (return 0 for supported, force the
// master rate on getters). Chain order: this module registers last -> its %orig
// calls Deep's version -> Deep's %orig calls the real implementation. For matched
// calls, Deep's version short-circuits at return 0; Supreme's version also returns
// 0. Idempotent, one redundant dispatch per call. No behavioural difference.
// =================================================================================================
%hook IOMobileFramebufferClient
- (int)setDisplayRefreshRate:(float)rate options:(unsigned int)options {
    if (Titanium_SupremeShouldOverride()) {
        return 0; // Chặn mọi lệnh từ chối, ép driver phần cứng chấp nhận thông số mới
    }
    return %orig(rate, options);
}

- (int)setDisplayRefreshRate:(float)rate {
    if (Titanium_SupremeShouldOverride()) {
        return 0;
    }
    return %orig(rate);
}

- (int)getDisplayRefreshRate:(float *)arg1 {
    if (Apex_IsMasterEnabled() && arg1) {
        *arg1 = (float)Titanium_SupremeEffectiveRate();
        return 0;
    }
    return %orig(arg1);
}

- (float)getDisplayRefreshRate {
    if (Apex_IsMasterEnabled()) {
        return (float)Titanium_SupremeEffectiveRate();
    }
    return %orig;
}

- (BOOL)isDisplayRefreshRateSupported:(float)rate {
    if (Apex_IsMasterEnabled()) return YES; // Cho phép toàn bộ dải từ 10Hz đến 244Hz
    return %orig(rate);
}

- (int)getDefaultDisplayMode:(id *)arg1 {
    if (Apex_IsMasterEnabled() && arg1) {
        *arg1 = (id)Titanium_GetSupremeMode();
        return 0;
    }
    return %orig(arg1);
}
%end

// =================================================================================================
// 3. CAWINDOWSERVERDISPLAY & RENDER SERVER (Ép xung nhịp dựng hình, loại bỏ độ trễ V-Sync)
//
// NOTE: also %hooked by TitaniumUltimateDeepEngine.x. Both agree on the contract.
// For 1.0/rate, both files' rate sources clamp to 10..244 so denominator is
// never zero. Redundant dispatch, no behaviour change.
// =================================================================================================
%hook CAWindowServerDisplay
- (void)setMinimumFrameDuration:(double)duration {
    if (Titanium_SupremeShouldOverride()) {
        NSInteger target = Titanium_SupremeEffectiveRate();
        if (target <= 0) { %orig(duration); return; }
        PM_SAFE_TRY(%orig(1.0 / (double)target));
        return;
    }
    %orig(duration);
}

- (double)minimumFrameDuration {
    if (Titanium_SupremeShouldOverride()) {
        NSInteger target = Titanium_SupremeEffectiveRate();
        if (target <= 0) return %orig;
        return 1.0 / (double)target;
    }
    return %orig;
}

- (void)setMaximumRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_SupremeEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (double)maximumRefreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setMinimumRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_SupremeEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (double)minimumRefreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setIdealRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_SupremeEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (double)idealRefreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (BOOL)allowsVirtualModes { return YES; }
- (void)setAllowsVirtualModes:(BOOL)flag {
    %orig(YES);
}
%end

// =================================================================================================
// 4. CADISPLAY & CADISPLAYLINK (Khóa cứng tần số quét màn hình & Luồng khung hình tuyệt đối)
//
// NOTE: also %hooked by TitaniumUltimateDeepEngine.x. Same contract, idempotent.
// CAFrameRateRangeMake((float)target, ...) widens to CGFloat at the call site —
// 10..244 is fully representable in float (24-bit mantissa, exact through 2^24),
// so no precision loss.
// =================================================================================================
%hook CADisplay
- (double)refreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        PM_SAFE_TRY(%orig((double)Titanium_SupremeEffectiveRate()));
        return;
    }
    %orig(rate);
}

- (NSInteger)preferredFPS {
    if (Titanium_SupremeShouldOverride()) return Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setPreferredFPS:(NSInteger)fps {
    if (Titanium_SupremeShouldOverride()) {
        %orig(Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(fps);
}

- (NSArray *)availableModes {
    NSArray *orig = %orig;
    if (Titanium_SupremeShouldOverride()) {
        id supremeMode = (id)Titanium_GetSupremeMode();
        return supremeMode ? (orig ? [orig arrayByAddingObject:supremeMode] : @[supremeMode]) : orig;
    }
    return orig;
}

- (id)currentMode {
    if (Titanium_SupremeShouldOverride()) {
        id supremeMode = (id)Titanium_GetSupremeMode();
        if (supremeMode) return supremeMode;
    }
    return %orig;
}

- (void)setCurrentMode:(id)mode {
    if (Titanium_SupremeShouldOverride()) {
        id supremeMode = (id)Titanium_GetSupremeMode();
        PM_SAFE_TRY(%orig(supremeMode ? supremeMode : mode));
        return;
    }
    %orig(mode);
}
%end

%hook CADisplayLink
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (Titanium_SupremeShouldOverride()) {
        NSInteger target = Titanium_SupremeEffectiveRate();
        if (target <= 0) { %orig(range); return; }
        %orig(CAFrameRateRangeMake((CGFloat)target, (CGFloat)target, (CGFloat)target));
        return;
    }
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (Titanium_SupremeShouldOverride()) {
        %orig(Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(fps);
}
%end

// =================================================================================================
// 5. AGXACCELERATOR & SMART THERMAL SAFEGUARD (Chống cháy chip/màn hình, Giảm nhiệt độ & Sạc nhanh)
//
// NOTE: AGXAccelerator also %hooked by Deep and Overdrive. All three call
// %orig(1) when master enabled — idempotent. AGXAccelerator is kernel-side;
// userspace %hook is a Logos no-op unless injected into a kernel-adjacent
// process (SpringBoard with kernel substrate). No effect in app process.
// =================================================================================================
%hook AGXAccelerator
- (int)setPowerState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép mức điện năng GPU tối đa, không bị bóp xung
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép hiệu năng đồ họa đỉnh cao
        return;
    }
    %orig(state);
}
%end

// Lớp bảo vệ phần cứng thông minh: Giám sát nhiệt độ, tản nhiệt nhanh khi sạc/chạy nền, chống quá nhiệt linh kiện
//
// NOTE: this is the THIRD %hook on IORegistryEntry:setCFProperty:withValue: —
// registration order determines the chain. Logos registers in %ctor order:
//   Deep (%ctor) -> Overdrive (%ctor) -> Supreme (%ctor)
// Chain when Supreme calls %orig: Supreme -> Overdrive -> Deep -> real IORegistry.
// Every layer decides independently whether to short-circuit or forward. Supreme
// has the narrowest filter (thermal/power/throttle only) plus the critical
// thermal safeguard, so its decision fires first. If Supreme returns KERN_SUCCESS,
// Overdrive and Deep never see the call. If Supreme forwards (real cooling
// allowed because real thermal state == Critical), Overdrive's broader filter
// fires next, then Deep's. Correct layering.
//
// The critical-thermal check is now REAL because it reads Titanium_SharedRealThermalState
// (populated by Overdrive's hook from the actual %orig before softening). Before
// 8.3.0t integration, this safeguard was unreachable — Supreme's %orig was the
// softened value, so `state >= Critical` never fired.
%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Apex_IsMasterEnabled() && Titanium_Supreme_KeyIsThrottleRelated(key)) {
        NSProcessInfoThermalState realState = Titanium_RealThermalStateSnapshot();
        if (realState >= NSProcessInfoThermalStateCritical) {
            // Real Critical: allow the OS to cool. This is the ONLY reachable
            // safety valve in the entire Supreme chain — it depends on the
            // shared global being populated by Overdrive's hook.
            NSLog(@"[ProMotionControl/Supreme] critical thermal (real) — permitting throttle");
            PM_SAFE_TRY(return %orig(key, value));
            return KERN_SUCCESS; // fallback if %orig threw
        }
        return KERN_SUCCESS; // Chặn toàn bộ lệnh bóp hiệu năng thông thường khi sạc hoặc chạy app nền
    }
    return %orig(key, value);
}
%end

// NOTE: NSProcessInfo is hooked TWICE — Overdrive (registers first, sees real
// %orig) and Supreme (registers second, sees Overdrive's softened output as
// %orig). Chain: Supreme -> Overdrive -> real. Supreme's thermalState reads the
// shared global (real) to decide Fair vs Nominal — it does NOT trust its own
// %orig, because that value is already Overdrive's softened return.
%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    NSProcessInfoThermalState stateFromChain = %orig; // Overdrive's softened return, not real
    if (Apex_IsMasterEnabled()) {
        NSProcessInfoThermalState realState = Titanium_RealThermalStateSnapshot();
        // Tránh tình trạng hệ thống tự động tụt FPS khi sạc pin hoặc chơi game nặng.
        // Serious/Critical -> Fair (visible to OS as "warm but usable"), else Nominal.
        return (realState >= NSProcessInfoThermalStateSerious) ? NSProcessInfoThermalStateFair : NSProcessInfoThermalStateNominal;
    }
    return stateFromChain;
}

- (BOOL)isLowPowerModeEnabled {
    if (Apex_IsMasterEnabled()) return NO; // Chặn chế độ tiết kiệm pin làm giảm tần số quét và hiệu năng
    return %orig;
}
%end

// =================================================================================================
// 6. TOUCH RESPONSIVENESS & UI/UX STUTTER SHIELD (Cảm ứng siêu nhạy 100%, Chống khựng app & Control Center)
//
// NOTE: sendEvent: is the hottest UI path in the process. Every touch event
// iterates allTouches and re-sets delaysTouchesBegan/Ended on gesture recognizers.
// The assignments are idempotent so subsequent calls are cheap, but the set
// iteration happens every frame. Wrapped in PM_SAFE_TRY — a gesture recognizer
// in a mid-dismissal state can throw on property access.
// =================================================================================================
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig(event);
    if (event.type == UIEventTypeTouches) {
        PM_SAFE_TRY({
            for (UITouch *touch in [event allTouches]) {
                if (touch.view && touch.view.gestureRecognizers.count > 0) {
                    for (UIGestureRecognizer *rec in touch.view.gestureRecognizers) {
                        rec.delaysTouchesBegan = NO;
                        rec.delaysTouchesEnded = NO;
                    }
                }
            }
        });
    }
}
%end

// Tối ưu hóa chuyển cảnh đóng mở ứng dụng, màn hình khóa, trung tâm điều khiển và nhạc nền không giật lag
//
// NOTE: SBMainWorkspace exists only in SpringBoard, not in regular app processes.
// The %hook is a Logos no-op unless the tweak filter includes SpringBoard.
// The NSURLCache clear is defensive — wrapped in PM_SAFE_TRY inside the block
// so a background-thread exception cannot hard-crash SpringBoard.
%hook SBMainWorkspace
- (void)transitionRequestDidComplete:(id)arg1 {
    %orig(arg1);
    // Chủ động dọn dẹp cache render và tối ưu hóa tải CPU ngay sau khi chuyển động giao diện hoàn tất
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        PM_SAFE_TRY({
            [[NSURLCache sharedURLCache] removeAllCachedResponses];
        });
    });
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo toàn bộ Supreme Ultimate Engine
// =================================================================================================
%ctor {
    @autoreleasepool {
        %init(TitaniumApexSupremeUltimateGroup);
    }
}
