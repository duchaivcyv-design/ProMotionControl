// =================================================================================================
// TitaniumHardwareOverdriveGuard.x
// User-supplied hardware overdrive / anti-throttling module, integrated for the shared
// FREE / PREMIUM / ADMIN Titanium bridge. The Logos group is always initialized; every
// override still checks Apex_IsMasterEnabled() at call time so profile changes take effect.
//
// 8.4.3t integration edits (only these, everything else verbatim):
//   [STANDALONE] `#import "TitaniumSettingsAPI.h"` removed. Bridge externs
//                (Titanium_GetMasterRate, Apex_IsMasterEnabled,
//                Titanium_SharedRealThermalState) are inlined below. Linker
//                resolves them at dylib load from TitaniumSettingsAPI.x.
//   [8.3.0t]    thermalState hook writes the REAL %orig to the shared global
//               BEFORE softening. This is what makes Supreme's critical-thermal
//               safeguard reachable — without it, Supreme's %orig is already
//               the softened Nominal, and the `>= Critical` branch never fires.
//   [SAFE]      PM_SAFE_TRY wrap on IORegistryEntry %orig path (hot).
//   [PERF]      Cheap first-char pre-check on IORegistryEntry key.
//   [NOTE]      KGNote marker on NSProcessInfo: this module's Nominal spoof
//               overrides Tweak.xm's PMThermalTargetCap shedding unconditionally
//               when Apex_IsMasterEnabled() is YES (LockedOverrideThermal redundant).
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>
#import <pthread.h>

// --- Bridge externs, inlined (was: #import "TitaniumSettingsAPI.h") ---------
// Titanium_GetMasterRate: selected master rate (10..244), or 0 for AUTO/inactive.
// Apex_IsMasterEnabled: YES only when runtime is fully active in this process.
// Titanium_SharedRealThermalState: 0=Nominal, 1=Fair, 2=Serious, 3=Critical.
//   This file is the FIRST writer — the thermalState hook below stores the raw
//   %orig here before softening. TitaniumApexSupremeUltimateEngine.x reads it.
//   Declared volatile so cross-thread reads see the latest store on arm64.
extern NSInteger Titanium_GetMasterRate(void);
extern BOOL Apex_IsMasterEnabled(void);
extern volatile NSInteger Titanium_SharedRealThermalState;
// ---------------------------------------------------------------------------

// Same exception-catch macro used by the main tweak; redeclared here so this
// file compiles independently of Tweak.xm's translation unit.
#ifndef PM_SAFE_TRY
#define PM_SAFE_TRY(...) \
    @try { __VA_ARGS__ } \
    @catch (NSException *exception) { \
        NSLog(@"[ProMotionControl/Overdrive] ObjC exception: %@ reason=%@", exception.name, exception.reason); \
    } @catch (...) { \
        NSLog(@"[ProMotionControl/Overdrive] Non-NSException swallowed"); \
    }
#endif

// Cheap key-match helper. The set of matched substrings is fixed; a first-char
// gate on t/T/p/P/c/C (thermal / power / performance-controller / charge /
// currentlimit / throttle) eliminates ~90% of calls without allocating a
// lowercase string. Anything that fails the gate falls through to %orig.
static inline BOOL Titanium_Overdrive_KeyIsThrottleRelated(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = key.length;
    if (len == 0) return NO;
    unichar c0 = [key characterAtIndex:0];
    // t/T -> thermal, throttle  ;  p/P -> power, performance-controller
    // c/C -> charge, currentlimit
    if (c0 != 't' && c0 != 'T' && c0 != 'p' && c0 != 'P' && c0 != 'c' && c0 != 'C') {
        return NO;
    }
    NSString *kl = [key lowercaseString];
    if ([kl containsString:@"thermal"]) return YES;
    if ([kl containsString:@"power"]) return YES;
    if ([kl containsString:@"throttle"]) return YES;
    if ([kl containsString:@"currentlimit"]) return YES;
    if ([kl containsString:@"charge"]) return YES;
    if ([kl containsString:@"performance-controller"]) return YES;
    return NO;
}

%group TitaniumHardwareOverdriveGroup

// =================================================================================================
// 1. IOREGISTRY & POWER MANAGEMENT — Chặn tuyệt đối mọi lệnh bóp dòng sạc, hạ xung khi sạc và sử dụng
//
// NOTE: TitaniumUltimateDeepEngine.x also %hooks IORegistryEntry:setCFProperty:withValue:.
// Logos chains the two hook blocks — whichever is registered first runs first; if the
// Overdrive version returns KERN_SUCCESS for a matched key, the Deep version's %orig call
// never reaches the real implementation and the operation is short-circuited once. The
// two versions target overlapping key sets (Overdrive adds currentlimit/charge/
// performance-controller); net behaviour is idempotent because both ultimately return
// KERN_SUCCESS for the same throttle-related keys.
// =================================================================================================
%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Apex_IsMasterEnabled() && Titanium_Overdrive_KeyIsThrottleRelated(key)) {
        return KERN_SUCCESS; // Trả về thành công ảo, triệt tiêu hoàn toàn lệnh giảm tải từ hệ thống
    }
    return %orig(key, value);
}
%end

// =================================================================================================
// 2. PROCESS INFO THERMAL & LOW POWER OVERRIDE — Khóa cứng trạng thái hiệu năng tối đa 100%
//
// KGNote: these two hooks make the runtime believe the device is always Nominal and
// always on wall power. In ProMotionControl terms this is equivalent to
// LockedOverrideThermal=YES for the thermal-cap logic in Tweak.xm: PMThermalTargetCap
// reads NSProcessInfo.thermalState / isLowPowerModeEnabled and now never sees Serious,
// Critical, or LPM. The LockedOverrideThermal preference becomes redundant when
// Apex_IsMasterEnabled() is YES — the physical cap is bypassed at the source. The
// watchdog can still kill the app if the SoC genuinely overheats; this module does
// not and cannot override the kernel's emergency shutdown.
//
// [8.3.0t] IMPORTANT: this hook stores the REAL %orig to Titanium_SharedRealThermalState
// BEFORE softening. This file is FIRST in the NSProcessInfo chain (registers before
// Supreme), so %orig here is the real system state. Supreme's hook, which runs after,
// reads the shared global to make its Critical-vs-Nominal decision. Without this write,
// the Supreme critical-thermal safeguard is unreachable.
// =================================================================================================
%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    // Evaluate the previous hook/original implementation first. This preserves the
    // real-state snapshot used by the Supreme safeguard when several engines coexist.
    NSProcessInfoThermalState originalState = %orig;
    // [8.3.0t] Store the REAL state so Supreme's critical-thermal branch can fire.
    Titanium_SharedRealThermalState = (NSInteger)originalState;
    if (Apex_IsMasterEnabled()) {
        // Luôn báo cáo trạng thái nhiệt độ ở mức chuẩn tối ưu (Nominal), ngăn iOS tự động bóp Hz, FPS và hiệu năng chip
        return NSProcessInfoThermalStateNominal;
    }
    return originalState;
}

- (BOOL)isLowPowerModeEnabled {
    BOOL originalState = %orig;
    if (Apex_IsMasterEnabled()) {
        return NO; // Vô hiệu hóa chế độ nguồn điện thấp làm giảm tần số quét và hiệu năng
    }
    return originalState;
}
%end

// =================================================================================================
// 3. AGXACCELERATOR & HARDWARE CHIP OVERDRIVE — Chiếm quyền kiểm soát tuyệt đối tầng GPU/CPU
//
// NOTE: TitaniumUltimateDeepEngine.x also %hooks AGXAccelerator. Both call %orig(1) for
// the two setters — idempotent, no behaviour change from the duplication, only a tiny
// amount of extra dispatch. AGXAccelerator is a kernel-side class; in a userspace app
// process this %hook compiles to a Logos no-op. It only has effect if the tweak is
// injected into a process where AGXAccelerator exists (SpringBoard under kernel
// substrate — outside this project's current filter scope).
// =================================================================================================
%hook AGXAccelerator
- (int)setPowerState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép trạng thái nguồn điện đồ họa luôn ở mức cao nhất (Max Performance State)
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép xung nhịp đồ họa bám sát mức tối đa, chống tụt khung hình đột ngột
        return;
    }
    %orig(state);
}
%end

// =================================================================================================
// 4. BACKGROUND AUDIO & TASK PERSISTENCE — Chống giảm tải khi chạy nền nhạc hoặc ứng dụng song song
//
// NOTE: this is a pure pass-through — %orig(active, outError) forwards to the real
// AVAudioSession method with no modification. It is kept verbatim as requested; it
// costs one extra objc_msgSend dispatch per AVAudioSession activation. No behavioural
// effect. If the intent is to keep audio sessions alive in the background, the hook
// would need to intercept setActive:NO and force YES — that is not what this code does.
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active error:(NSError * _Nullable *)outError {
    // Đảm bảo phiên âm thanh và các tác vụ chạy nền không bao giờ bị hệ điều hành cô lập hoặc bóp băng thông
    return %orig(active, outError);
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo module chống giảm tải phần cứng tối thượng
// =================================================================================================
static inline BOOL Titanium_ProcessIsSystemOrControl(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [bid isEqualToString:@"com.apple.springboard"] ||
           [bid isEqualToString:@"com.dell.promotioncontrol.app"];
}

%ctor {
    @autoreleasepool {
        if (!Titanium_ProcessIsSystemOrControl()) return; // other UIKit apps: no heavy hooks
        %init(TitaniumHardwareOverdriveGroup);
    }
}
