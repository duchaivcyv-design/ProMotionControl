#import "PMPremiumOptimizationEngine.h"
#import "PMLocalBridge.h"
#import "PMPerformanceSuite.h"
#import <math.h>
#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>

// Exact-rate policy. The app writes ExactRateEnforcement into the shared
// com.dell.promotioncontrol domain; default is ON so 10..244 selections are
// declared verbatim instead of being silently clamped to the panel maximum.
static BOOL PMEngineExactRatePreference(void)
{
    CFPreferencesAppSynchronize(CFSTR("com.dell.promotioncontrol"));
    Boolean valid = false;
    Boolean value = CFPreferencesGetAppBooleanValue(CFSTR("ExactRateEnforcement"),
                                                    CFSTR("com.dell.promotioncontrol"), &valid);
    return valid ? (value != 0) : YES;
}

static BOOL PMEngineExactRateEnabled(NSDictionary *options)
{
    id raw = [options isKindOfClass:[NSDictionary class]] ? options[@"ExactRateEnforcement"] : nil;
    if ([raw respondsToSelector:@selector(boolValue)]) return [raw boolValue];
    return PMEngineExactRatePreference();
}

static BOOL PMEngineDeviceIsCharging(void)
{
    UIDevice *device = UIDevice.currentDevice;
    BOOL wasEnabled = device.batteryMonitoringEnabled;
    UIDeviceBatteryState state = UIDeviceBatteryStateUnknown;

    @try {
        if (!wasEnabled) device.batteryMonitoringEnabled = YES;
        state = device.batteryState;
    } @catch (NSException *exception) {
        (void)exception;
    } @finally {
        // Restore the caller's original monitoring state even if batteryState fails.
        if (!wasEnabled) {
            @try {
                device.batteryMonitoringEnabled = NO;
            } @catch (NSException *restoreException) {
                (void)restoreException;
            }
        }
    }

    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

static NSProcessInfoThermalState PMEngineThermalState(void)
{
    if (@available(iOS 11.0, *)) return NSProcessInfo.processInfo.thermalState;
    return NSProcessInfoThermalStateNominal;
}

static BOOL PMEngineOption(NSDictionary *options, NSString *key, BOOL fallback)
{
    id value = [options isKindOfClass:[NSDictionary class]] ? options[key] : nil;
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}


static CGFloat PMEngineConfiguredRate(NSDictionary *options, NSString *modeKey, NSString *customKey)
{
    id rawMode = [options isKindOfClass:[NSDictionary class]] ? options[modeKey] : nil;
    NSInteger mode = [rawMode respondsToSelector:@selector(integerValue)] ? [rawMode integerValue] : 0;
    NSInteger value = 0;
    if (mode == -1) {
        id rawCustom = options[customKey];
        value = [rawCustom respondsToSelector:@selector(integerValue)] ? [rawCustom integerValue] : 60;
    } else if (mode > 0) {
        value = mode;
    }
    return value > 0 ? (CGFloat)MIN(244, MAX(10, value)) : 0.0;
}

static void PMEngineResolveConfiguredRates(NSDictionary *options, CGFloat hardwareMaximum,
                                           BOOL exactRate,
                                           CGFloat *minimum, CGFloat *maximum, CGFloat *preferred)
{
    CGFloat hz = PMEngineOption(options, @"RefreshRateEnabled", NO)
        ? PMEngineConfiguredRate(options, @"RefreshMode", @"CustomRefreshRate") : 0.0;
    CGFloat fps = PMEngineOption(options, @"FPSOverrideEnabled", NO)
        ? PMEngineConfiguredRate(options, @"FPSMode", @"CustomFPS") : 0.0;
    CGFloat requestedHz = hz > 0.0 ? hz : (fps > 0.0 ? fps : hardwareMaximum);
    CGFloat requestedFPS = fps > 0.0 ? fps : (hz > 0.0 ? hz : hardwareMaximum);
    // Exact mode keeps the saved user target exact in configuration, while the
    // active request is still capped to the panel's real maximum.
    (void)exactRate;
    CGFloat effectiveMaximum = MIN(hardwareMaximum, requestedHz);
    CGFloat effectivePreferred = MIN(effectiveMaximum, requestedFPS);
    *maximum = MAX(10.0, effectiveMaximum);
    *preferred = MIN(*maximum, MAX(10.0, effectivePreferred));
    *minimum = MIN(10.0, *preferred);
}

// Shared thermal/load governor for all three server engines.
// Charger state never lowers the selected Hz/FPS. Only physical panel limits,
// Low Power Mode, actual thermal pressure and sustained frame overload apply.
// iOS remains the authority for CPU/GPU clocks and hardware thermal limits.
static CGFloat PMEngineThermalSafeMaximumRate(CGFloat requestedMaximum,
                                               NSInteger serverMode,
                                               BOOL thermalGuard,
                                               BOOL chargingGuard,
                                               BOOL exactRate)
{
    if (serverMode < 0 || serverMode > 2) return 0.0;

    // All modes respect the physical panel, Low Power Mode and real thermal state.
    // ExactRateEnforcement changes cadence locking, not hardware safety boundaries.
    (void)exactRate;
    NSInteger hardwareValue = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    CGFloat hardwareMaximum = (CGFloat)(hardwareValue > 0 ? hardwareValue : 60);
    CGFloat maximum = isfinite(requestedMaximum)
        ? MIN(hardwareMaximum, MAX(10.0, requestedMaximum)) : hardwareMaximum;

    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (processInfo.isLowPowerModeEnabled) return 0.0;

    NSProcessInfoThermalState thermal = PMEngineThermalState();
    if (thermal == NSProcessInfoThermalStateSerious || thermal == NSProcessInfoThermalStateCritical) {
        return 0.0; // callers stop their auxiliary render scheduler in these states
    }

    if (thermalGuard && thermal == NSProcessInfoThermalStateFair) {
        // Half-panel cadence is an exact, conservative divisor on common 60/120 Hz panels.
        // A 60 Hz device therefore sheds auxiliary frame work at 30 FPS, not 60.
        CGFloat warmCeiling = MIN(hardwareMaximum, MAX(30.0, floor(hardwareMaximum * 0.50)));
        maximum = MIN(maximum, warmCeiling);
    }

    // Keep chargingGuard in the method signature for source/API compatibility
    // with existing callers and stored preferences, but intentionally do not
    // use charger state as a frame-rate limiter.
    (void)chargingGuard;

    // The shared sampler detects sustained late frames. Reduce auxiliary
    // render cadence instead of adding more work to an already overloaded app.
    if ([PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork) {
        CGFloat overloadCeiling = MIN(hardwareMaximum, MAX(30.0, floor(hardwareMaximum * 0.50)));
        maximum = MIN(maximum, overloadCeiling);
    }

    return MAX(10.0, maximum);
}

// One shared policy state for the three tiers. This is the safe equivalent of
// the supplied TitaniumAdaptiveGovernorEngine: existing tier render links are
// paced in place; no extra CADisplayLink, realtime-priority escalation or kernel hook
// is created. The operating system remains the final thermal/power authority.
@interface TitaniumAdaptiveGovernorEngine ()
@property (nonatomic, readwrite) CGFloat targetHz;
@property (nonatomic, readwrite) CGFloat targetFPS;
@property (nonatomic, readwrite) CGFloat effectiveHz;
@property (nonatomic, readwrite) CGFloat effectiveFPS;
@property (nonatomic, readwrite) NSInteger activeServerMode;
@property (nonatomic, readwrite) BOOL isThrottled;
@end

@implementation TitaniumAdaptiveGovernorEngine

+ (instancetype)sharedEngine {
    static TitaniumAdaptiveGovernorEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TitaniumAdaptiveGovernorEngine alloc] init]; });
    return instance;
}

- (void)deployAdaptiveGovernorWithHz:(CGFloat)hz fps:(CGFloat)fps {
    [self deployAdaptiveGovernorWithHz:hz fps:fps serverMode:0 thermalGuard:YES chargingGuard:YES];
}

- (void)deployAdaptiveGovernorWithHz:(CGFloat)hz
                                  fps:(CGFloat)fps
                           serverMode:(NSInteger)serverMode
                         thermalGuard:(BOOL)thermalGuard
                       chargingGuard:(BOOL)chargingGuard {
    CGFloat safeHz = isfinite(hz) ? MIN(244.0, MAX(10.0, hz)) : 60.0;
    CGFloat safeFPS = isfinite(fps) ? MIN(244.0, MAX(10.0, fps)) : safeHz;
    NSInteger mode = MIN(MAX(serverMode, 0), 2);
    BOOL exactRate = PMEngineExactRatePreference();
    CGFloat hardwareMaximum = (CGFloat)MAX(10, (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond);
    CGFloat requestedMaximum = MIN(safeHz, hardwareMaximum);
    CGFloat requestedPreferred = MIN(safeFPS, requestedMaximum);
    CGFloat effectiveMaximum = PMEngineThermalSafeMaximumRate(requestedMaximum, mode,
                                                               thermalGuard, chargingGuard, exactRate);
    CGFloat effectivePreferred = effectiveMaximum >= 10.0
        ? MIN(requestedPreferred, effectiveMaximum) : 0.0;

    @synchronized (self) {
        self.targetHz = safeHz;
        self.targetFPS = safeFPS;
        self.activeServerMode = mode;
        self.effectiveHz = effectiveMaximum >= 10.0 ? effectiveMaximum : 0.0;
        self.effectiveFPS = effectivePreferred;
        self.isThrottled = (effectiveMaximum + 0.01 < safeHz) ||
                           (effectivePreferred + 0.01 < safeFPS);
    }
}

- (void)stopGovernorEngine {
    @synchronized (self) {
        self.targetHz = 0.0;
        self.targetFPS = 0.0;
        self.effectiveHz = 0.0;
        self.effectiveFPS = 0.0;
        self.activeServerMode = 0;
        self.isThrottled = NO;
    }
}

@end

// ADMIN foreground-transition assist. The existing ADMIN scheduler is
// restarted by the supplied handler; this helper does not create another link.
@interface TitaniumUltimateHomeShieldEngine ()
@property (nonatomic, readwrite) BOOL isHomeTransitionActive;
@end

@implementation TitaniumUltimateHomeShieldEngine

+ (instancetype)sharedEngine {
    static TitaniumUltimateHomeShieldEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TitaniumUltimateHomeShieldEngine alloc] init]; });
    return instance;
}

- (void)triggerHomeStutterShieldBoostWithHandler:(dispatch_block_t)handler {
    if (!handler) return;
    dispatch_block_t work = ^{
        if (self.isHomeTransitionActive) return;
        self.isHomeTransitionActive = YES;
        handler();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.isHomeTransitionActive = NO;
        });
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)stopEngine {
    self.isHomeTransitionActive = NO;
}

@end

static void PMEngineApplyRate(CADisplayLink *link, CGFloat minimum, CGFloat maximum, CGFloat preferred)
{
    if (!link || !isfinite(minimum) || !isfinite(maximum) || !isfinite(preferred)) return;
    maximum = MIN(244.0, MAX(10.0, maximum));
    minimum = MIN(maximum, MAX(10.0, minimum));
    preferred = MIN(maximum, MAX(minimum, preferred));
    if (@available(iOS 15.0, *)) {
        link.preferredFrameRateRange = CAFrameRateRangeMake(minimum, maximum, preferred);
    } else {
        link.preferredFramesPerSecond = (NSInteger)preferred;
    }
}

@interface PMUltimateOptimizer ()
@property (nonatomic) CGFloat requestedMinimumRate;
@property (nonatomic) CGFloat requestedMaximumRate;
@property (nonatomic) CGFloat requestedPreferredRate;
@property (nonatomic) BOOL stutterThrottleApplied;
@property (nonatomic) BOOL exactRateLocked;
@end

@interface PMAdvancedOptimizer ()
@property (nonatomic) CGFloat requestedMinimumRate;
@property (nonatomic) CGFloat requestedMaximumRate;
@property (nonatomic) CGFloat requestedPreferredRate;
@property (nonatomic) BOOL stutterThrottleApplied;
@property (nonatomic) BOOL exactRateLocked;
@end

#pragma mark - FREE display cadence

@implementation PMUltimateOptimizer

+ (instancetype)sharedInstance {
    static PMUltimateOptimizer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PMUltimateOptimizer alloc] init];
    });
    return instance;
}

- (void)deployUltimateOptimizations {
    [self deployUltimateOptimizationsWithOptions:@{}];
}

- (void)deployUltimateOptimizationsWithOptions:(NSDictionary *)options {
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [options copy] ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{ [self deployUltimateOptimizationsWithOptions:snapshot]; });
        return;
    }
    BOOL exactRate = PMEngineExactRateEnabled(options);
    if (!PMEngineOption(options, @"FreeRenderSchedulerEnabled", YES) ||
        NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        [self stopOptimizations];
        return;
    }
    NSProcessInfoThermalState thermal = PMEngineThermalState();
    // Exact mode keeps the declared cadence until the user changes it; iOS
    // still owns hardware clocks and the panel's physical refresh limit.
    if (thermal == NSProcessInfoThermalStateSerious || thermal == NSProcessInfoThermalStateCritical) {
        [self stopOptimizations];
        return;
    }
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderTick:)];
    NSInteger deviceMaximum = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    CGFloat hardwareMaximum = (CGFloat)(deviceMaximum > 0 ? deviceMaximum : 60);
    CGFloat maximum = hardwareMaximum;
    CGFloat preferred = hardwareMaximum;
    CGFloat minimum = 10.0;
    PMEngineResolveConfiguredRates(options, hardwareMaximum,
                                   PMEngineExactRateEnabled(options),
                                   &minimum, &maximum, &preferred);
    BOOL thermalGuard = PMEngineOption(options, @"FreeThermalGuardEnabled", YES);
    BOOL chargingGuard = PMEngineOption(options, @"FreeChargingGuardEnabled",
        PMEngineOption(options, @"ChargingOptimization", YES));
    [[TitaniumAdaptiveGovernorEngine sharedEngine] deployAdaptiveGovernorWithHz:maximum
                                                                              fps:preferred
                                                                       serverMode:0
                                                                     thermalGuard:thermalGuard
                                                                   chargingGuard:chargingGuard];
    maximum = [TitaniumAdaptiveGovernorEngine sharedEngine].effectiveHz;
    preferred = MIN(preferred, [TitaniumAdaptiveGovernorEngine sharedEngine].effectiveFPS);
    if (maximum < 10.0) {
        [self stopOptimizations];
        return;
    }
    preferred = MIN(preferred, maximum);
    BOOL adaptiveCadence = PMEngineOption(options, @"FreeAdaptiveCadenceEnabled", YES);
    self.requestedMinimumRate = adaptiveCadence ? MIN(minimum, preferred) : preferred;
    self.requestedMaximumRate = maximum;
    self.requestedPreferredRate = MIN(preferred, maximum);
    self.stutterThrottleApplied = NO;
    self.exactRateLocked = exactRate;
    if (!exactRate && [PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork) {
        self.requestedMaximumRate = MIN(self.requestedMaximumRate,
            MAX(30.0, floor(hardwareMaximum * 0.50)));
        self.stutterThrottleApplied = YES;
    }
    PMEngineApplyRate(self.displayLink, self.requestedMinimumRate, self.requestedMaximumRate, self.requestedPreferredRate);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)renderTick:(CADisplayLink *)sender {
    [[PMPerformanceMonitor sharedMonitor] recordFrameTimestamp:sender.timestamp targetTimestamp:sender.targetTimestamp];
    if (self.exactRateLocked) return;
    BOOL throttle = [PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork;
    if (throttle != self.stutterThrottleApplied) {
        self.stutterThrottleApplied = throttle;
        CGFloat overloadCeiling = MAX(30.0,
            floor((CGFloat)UIScreen.mainScreen.maximumFramesPerSecond * 0.50));
        CGFloat maximum = throttle ? MIN(self.requestedMaximumRate, overloadCeiling) : self.requestedMaximumRate;
        PMEngineApplyRate(self.displayLink, self.requestedMinimumRate, maximum, MIN(self.requestedPreferredRate, maximum));
    }
}

- (void)stopOptimizations {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopOptimizations]; });
        return;
    }
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.requestedMinimumRate = 0.0;
    self.requestedMaximumRate = 0.0;
    self.requestedPreferredRate = 0.0;
    self.stutterThrottleApplied = NO;
    self.exactRateLocked = NO;
}

@end

#pragma mark - FREE PMSmoothEngine facade

@implementation PMSmoothEngine

+ (instancetype)sharedInstance {
    static PMSmoothEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMSmoothEngine alloc] init]; });
    return instance;
}

- (CADisplayLink *)displayLink {
    return [PMUltimateOptimizer sharedInstance].displayLink;
}

- (void)startEngine {
    [self startEngineWithOptions:@{}];
}

- (void)startEngineWithOptions:(NSDictionary *)options {
    NSDictionary *snapshot = [options isKindOfClass:[NSDictionary class]] ? [options copy] : @{};
    BOOL smoothEnabled = PMEngineOption(snapshot, @"FreeSmoothEngineEnabled", YES);
    if (!smoothEnabled) {
        [[PMUltimateOptimizer sharedInstance] stopOptimizations];
        return;
    }
    [[PMUltimateOptimizer sharedInstance] deployUltimateOptimizationsWithOptions:snapshot];
}

- (void)stopEngine {
    [[PMUltimateOptimizer sharedInstance] stopOptimizations];
}

@end

#pragma mark - PREMIUM display cadence

@implementation PMAdvancedOptimizer

+ (instancetype)sharedInstance {
    static PMAdvancedOptimizer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PMAdvancedOptimizer alloc] init];
    });
    return instance;
}

- (void)startHighPerformanceRenderLoop {
    [self startHighPerformanceRenderLoopWithThermalGuard:YES chargingGuard:YES lowLatency:YES];
}

- (void)startHighPerformanceRenderLoopWithThermalGuard:(BOOL)thermalGuard chargingGuard:(BOOL)chargingGuard lowLatency:(BOOL)lowLatency {
    [self startHighPerformanceRenderLoopWithOptions:@{
        @"PremiumThermalGuardEnabled": @(thermalGuard),
        @"PremiumChargingGuardEnabled": @(chargingGuard),
        @"PremiumLowLatencyModeEnabled": @(lowLatency)
    }];
}

- (void)startHighPerformanceRenderLoopWithOptions:(NSDictionary *)options {
    NSDictionary *snapshot = [options isKindOfClass:[NSDictionary class]] ? options : @{};
    BOOL thermalGuard = PMEngineOption(snapshot, @"PremiumThermalGuardEnabled", YES);
    BOOL chargingGuard = PMEngineOption(snapshot, @"PremiumChargingGuardEnabled", YES);
    BOOL lowLatency = PMEngineOption(snapshot, @"PremiumLowLatencyModeEnabled", YES);
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startHighPerformanceRenderLoopWithOptions:snapshot];
        });
        return;
    }
    BOOL exactRate = PMEngineExactRateEnabled(snapshot);
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        processInfo.isLowPowerModeEnabled) {
        [self stopRenderLoop];
        return;
    }
    NSProcessInfoThermalState thermal = PMEngineThermalState();
    // Serious/Critical always stop the auxiliary render loop, including Exact mode.
    if (thermal == NSProcessInfoThermalStateSerious || thermal == NSProcessInfoThermalStateCritical) {
        [self stopRenderLoop];
        return;
    }
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderTick:)];
    NSInteger deviceMaximum = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    CGFloat hardwareMaximum = (CGFloat)(deviceMaximum > 0 ? deviceMaximum : 60);
    CGFloat maximum = hardwareMaximum;
    CGFloat preferred = hardwareMaximum;
    CGFloat minimum = 10.0;
    PMEngineResolveConfiguredRates(snapshot, hardwareMaximum,
                                   PMEngineExactRateEnabled(snapshot),
                                   &minimum, &maximum, &preferred);
    [[TitaniumAdaptiveGovernorEngine sharedEngine] deployAdaptiveGovernorWithHz:maximum
                                                                              fps:preferred
                                                                       serverMode:1
                                                                     thermalGuard:thermalGuard
                                                                   chargingGuard:chargingGuard];
    maximum = [TitaniumAdaptiveGovernorEngine sharedEngine].effectiveHz;
    preferred = MIN(preferred, [TitaniumAdaptiveGovernorEngine sharedEngine].effectiveFPS);
    if (maximum < 10.0) {
        [self stopRenderLoop];
        return;
    }
    preferred = MIN(preferred, maximum);
    BOOL guardedState = thermalGuard && thermal == NSProcessInfoThermalStateFair;
    // Keep the selected preferred rate while cool; charger state alone does
    // not change the requested display cadence.
    id configuredMinimum = snapshot[@"PremiumMinimumDisplayRate"];
    if (exactRate) {
        // Lock min = max = preferred so the declared value is never re-paced.
        minimum = maximum;
    } else if ([configuredMinimum respondsToSelector:@selector(doubleValue)]) {
        minimum = MIN(maximum, MAX(10.0, [configuredMinimum doubleValue]));
    } else if (lowLatency || guardedState) {
        minimum = MIN(10.0, preferred);
    } else {
        minimum = MIN(preferred, maximum);
    }
    minimum = MIN(minimum, preferred);
    self.requestedMinimumRate = minimum;
    self.requestedMaximumRate = maximum;
    self.requestedPreferredRate = MIN(preferred, maximum);
    self.stutterThrottleApplied = NO;
    self.exactRateLocked = exactRate;
    if (!exactRate && [PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork) {
        self.requestedMaximumRate = MIN(self.requestedMaximumRate,
            MAX(30.0, floor(hardwareMaximum * 0.50)));
        self.stutterThrottleApplied = YES;
    }
    PMEngineApplyRate(self.displayLink, self.requestedMinimumRate, self.requestedMaximumRate, self.requestedPreferredRate);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)renderTick:(CADisplayLink *)sender {
    [[PMPerformanceMonitor sharedMonitor] recordFrameTimestamp:sender.timestamp targetTimestamp:sender.targetTimestamp];
    if (self.exactRateLocked) return;
    BOOL throttle = [PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork;
    if (throttle != self.stutterThrottleApplied) {
        self.stutterThrottleApplied = throttle;
        CGFloat overloadCeiling = MAX(30.0,
            floor((CGFloat)UIScreen.mainScreen.maximumFramesPerSecond * 0.50));
        CGFloat maximum = throttle ? MIN(self.requestedMaximumRate, overloadCeiling) : self.requestedMaximumRate;
        PMEngineApplyRate(self.displayLink, self.requestedMinimumRate, maximum, MIN(self.requestedPreferredRate, maximum));
    }
}

- (void)stopRenderLoop {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopRenderLoop]; });
        return;
    }
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.requestedMinimumRate = 0.0;
    self.requestedMaximumRate = 0.0;
    self.requestedPreferredRate = 0.0;
    self.stutterThrottleApplied = NO;
    self.exactRateLocked = NO;
}

@end


@interface TitaniumAbsoluteUnlockEngine (PMInternalRateState)
- (void)noteRequestedHz:(CGFloat)hz fps:(CGFloat)fps;
@end

#pragma mark - ADMIN display cadence and Nexus integration
// The ADMIN suite stays app-local. Logos runtime hooks remain bounded by the
// exact ControlApp bundle filter in Tweak.x; this engine does not inject into
// game or system processes.

@implementation PMUltimatePowerEngine

+ (instancetype)sharedEngine {
    static PMUltimatePowerEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMUltimatePowerEngine alloc] init]; });
    return instance;
}

- (void)deployMaximumPerformanceMode {
    [self deployMaximumPerformanceModeWithThermalCooldown:YES];
}

- (void)deployMaximumPerformanceModeWithThermalCooldown:(BOOL)thermalCooldownEnabled {
    [self deployMaximumPerformanceModeWithThermalCooldown:thermalCooldownEnabled chargingCooldown:YES];
}

- (void)deployMaximumPerformanceModeWithThermalCooldown:(BOOL)thermalCooldownEnabled chargingCooldown:(BOOL)chargingCooldownEnabled {
    [self deployMaximumPerformanceModeWithThermalCooldown:thermalCooldownEnabled chargingCooldown:chargingCooldownEnabled adaptiveFramePacing:YES];
}

- (void)deployMaximumPerformanceModeWithThermalCooldown:(BOOL)thermalCooldownEnabled chargingCooldown:(BOOL)chargingCooldownEnabled adaptiveFramePacing:(BOOL)adaptiveFramePacing {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self deployMaximumPerformanceModeWithThermalCooldown:thermalCooldownEnabled chargingCooldown:chargingCooldownEnabled adaptiveFramePacing:adaptiveFramePacing];
        });
        return;
    }
    BOOL exactRate = PMEngineExactRatePreference();
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        processInfo.isLowPowerModeEnabled) {
        [self disengagePerformanceMode];
        return;
    }
    NSProcessInfoThermalState thermal = PMEngineThermalState();
    if (thermal == NSProcessInfoThermalStateSerious || thermal == NSProcessInfoThermalStateCritical) {
        [self disengagePerformanceMode];
        return;
    }

    NSInteger hardwareMaximum = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    CGFloat maximum = (CGFloat)(hardwareMaximum > 0 ? hardwareMaximum : 60);
    maximum = PMEngineThermalSafeMaximumRate(maximum, 2, thermalCooldownEnabled,
                                             chargingCooldownEnabled, exactRate);
    if (maximum < 10.0) {
        [self disengagePerformanceMode];
        return;
    }
    BOOL guardedState = thermalCooldownEnabled && thermal == NSProcessInfoThermalStateFair;
    (void)chargingCooldownEnabled; // retained for compatibility; charging never caps Hz/FPS.
    CGFloat minimum = (adaptiveFramePacing || guardedState) ? MIN(10.0, maximum) : maximum;
    [[PMUltimateNexusEngine sharedEngine] deployNexusPerformanceSuiteWithMinRate:minimum
                                                                          maxRate:maximum
                                                                       preferred:maximum];
}

- (void)deployMaximumPerformanceModeWithOptions:(NSDictionary *)options {
    BOOL exactRate = PMEngineExactRateEnabled(options);
    BOOL thermal = PMEngineOption(options, @"AdminThermalCooldownEnabled", YES);
    BOOL charging = PMEngineOption(options, @"AdminChargingCooldownEnabled", YES);
    BOOL adaptive = PMEngineOption(options, @"AdminAdaptiveFramePacingEnabled", YES);

    BOOL hzEnabled = PMEngineOption(options, @"RefreshRateEnabled", NO);
    BOOL fpsEnabled = PMEngineOption(options, @"FPSOverrideEnabled", NO);
    NSInteger selectedHz = hzEnabled ? (NSInteger)PMEngineConfiguredRate(options, @"RefreshMode", @"CustomRefreshRate") : 0;
    NSInteger selectedFPS = fpsEnabled ? (NSInteger)PMEngineConfiguredRate(options, @"FPSMode", @"CustomFPS") : 0;
    CGFloat requestedMaximum = selectedHz > 0 ? selectedHz : (selectedFPS > 0 ? selectedFPS : 244.0);
    CGFloat requestedPreferred = selectedFPS > 0
        ? MIN(selectedFPS, requestedMaximum) : requestedMaximum;
    requestedMaximum = MIN(244.0, MAX(10.0, requestedMaximum));
    requestedPreferred = MIN(requestedMaximum, MAX(10.0, requestedPreferred));
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [options copy] ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{ [self deployMaximumPerformanceModeWithOptions:snapshot]; });
        return;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        [self disengagePerformanceMode];
        return;
    }

    NSProcessInfoThermalState thermalState = PMEngineThermalState();
    if (thermalState == NSProcessInfoThermalStateSerious || thermalState == NSProcessInfoThermalStateCritical) {
        [self disengagePerformanceMode];
        return;
    }
    [[TitaniumAdaptiveGovernorEngine sharedEngine] deployAdaptiveGovernorWithHz:requestedMaximum
                                                                              fps:requestedPreferred
                                                                       serverMode:2
                                                                     thermalGuard:thermal
                                                                   chargingGuard:charging];
    requestedMaximum = [TitaniumAdaptiveGovernorEngine sharedEngine].effectiveHz;
    requestedPreferred = MIN(requestedPreferred, [TitaniumAdaptiveGovernorEngine sharedEngine].effectiveFPS);
    if (requestedMaximum < 10.0) {
        [self disengagePerformanceMode];
        return;
    }
    requestedPreferred = MIN(requestedPreferred, requestedMaximum);
    BOOL guardedState = thermal && thermalState == NSProcessInfoThermalStateFair;
    // ADMIN keeps the selected rate while charging. Only actual thermal
    // pressure or sustained frame misses can activate adaptive safeguards.
    CGFloat requestedMinimum = (adaptive || guardedState)
        ? MIN(10.0, requestedPreferred) : requestedPreferred;
    id configuredMinimum = options[@"AdminMinimumDisplayRate"];
    if (exactRate) {
        requestedMinimum = requestedMaximum;
    } else if ([configuredMinimum respondsToSelector:@selector(doubleValue)]) {
        requestedMinimum = MIN(requestedMaximum, MAX(10.0, [configuredMinimum doubleValue]));
    }
    requestedMinimum = MIN(requestedMinimum, requestedPreferred);
    [[TitaniumAbsoluteUnlockEngine sharedEngine] noteRequestedHz:requestedMaximum fps:requestedPreferred];
    [[PMUltimateNexusEngine sharedEngine] deployNexusPerformanceSuiteWithMinRate:requestedMinimum
                                                                          maxRate:requestedMaximum
                                                                       preferred:requestedPreferred];
}

- (void)optimizeTargetView:(UIView *)view {
    [[PMCorePerformanceEngine sharedEngine] optimizeViewRendering:view];
}

- (void)disengagePerformanceMode {
    [[PMUltimateNexusEngine sharedEngine] shutdownNexusEngine];
}

@end


#pragma mark - Requested smooth/pro/titanium adapters (single-loop integration)

@implementation PMSmoothEngineAdvanced

+ (instancetype)sharedInstance {
    static PMSmoothEngineAdvanced *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMSmoothEngineAdvanced alloc] init]; });
    return instance;
}

- (CADisplayLink *)displayLink {
    return [PMAdvancedOptimizer sharedInstance].displayLink;
}

- (void)startEngineWithMinHz:(CGFloat)minHz maxHz:(CGFloat)maxHz {
    CGFloat safeMin = isfinite(minHz) ? MIN(244.0, MAX(10.0, minHz)) : 10.0;
    CGFloat safeMax = isfinite(maxHz) ? MIN(244.0, MAX(10.0, maxHz)) : 60.0;
    if (safeMin > safeMax) { CGFloat swap = safeMin; safeMin = safeMax; safeMax = swap; }
    NSDictionary *options = @{
        @"RefreshRateEnabled": @YES, @"RefreshMode": @(-1), @"CustomRefreshRate": @(safeMax),
        @"FPSOverrideEnabled": @YES, @"FPSMode": @(-1), @"CustomFPS": @(safeMax),
        @"PremiumMinimumDisplayRate": @(safeMin),
        @"PremiumThermalGuardEnabled": @YES, @"PremiumChargingGuardEnabled": @YES,
        @"PremiumLowLatencyModeEnabled": @YES
    };
    [self startEngineWithOptions:options];
}

- (void)startEngineWithOptions:(NSDictionary *)options {
    [[PMAdvancedOptimizer sharedInstance] startHighPerformanceRenderLoopWithOptions:
        [options isKindOfClass:[NSDictionary class]] ? options : @{}];
}

- (void)stopEngine {
    [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
}

@end

@interface TitaniumAbsoluteUnlockEngine ()
@property (nonatomic, readwrite) CGFloat targetHz;
@property (nonatomic, readwrite) CGFloat targetFPS;
@end

@implementation TitaniumAbsoluteUnlockEngine

+ (instancetype)sharedEngine {
    static TitaniumAbsoluteUnlockEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TitaniumAbsoluteUnlockEngine alloc] init]; });
    return instance;
}

- (void)noteRequestedHz:(CGFloat)hz fps:(CGFloat)fps {
    self.targetHz = isfinite(hz) ? MIN(244.0, MAX(10.0, hz)) : 60.0;
    self.targetFPS = isfinite(fps) ? MIN(244.0, MAX(10.0, fps)) : self.targetHz;
}

- (void)deployAbsoluteOverdriveWithHz:(CGFloat)hz fps:(CGFloat)fps {
    [self deployAbsoluteOverdriveWithMinHz:10.0 maxHz:hz fps:fps];
}

- (void)deployAbsoluteOverdriveWithMinHz:(CGFloat)minHz maxHz:(CGFloat)hz fps:(CGFloat)fps {
    CGFloat safeHz = isfinite(hz) ? MIN(244.0, MAX(10.0, hz)) : 60.0;
    CGFloat safeFPS = isfinite(fps) ? MIN(244.0, MAX(10.0, fps)) : safeHz;
    CGFloat safeMin = isfinite(minHz) ? MIN(safeHz, MAX(10.0, minHz)) : 10.0;
    NSDictionary *options = @{
        @"RefreshRateEnabled": @YES, @"RefreshMode": @(-1), @"CustomRefreshRate": @(safeHz),
        @"FPSOverrideEnabled": @YES, @"FPSMode": @(-1), @"CustomFPS": @(safeFPS),
        @"AdminMinimumDisplayRate": @(safeMin),
        @"AdminAdaptiveFramePacingEnabled": @YES,
        @"AdminThermalCooldownEnabled": @YES, @"AdminChargingCooldownEnabled": @YES
    };
    [self deployConfiguredOverdriveWithOptions:options];
}

- (void)deployConfiguredOverdriveWithOptions:(NSDictionary *)options {
    NSDictionary *snapshot = [options isKindOfClass:[NSDictionary class]] ? [options copy] : @{};
    NSInteger hz = PMEngineOption(snapshot, @"RefreshRateEnabled", NO)
        ? (NSInteger)PMEngineConfiguredRate(snapshot, @"RefreshMode", @"CustomRefreshRate") : 0;
    NSInteger fps = PMEngineOption(snapshot, @"FPSOverrideEnabled", NO)
        ? (NSInteger)PMEngineConfiguredRate(snapshot, @"FPSMode", @"CustomFPS") : 0;
    [self noteRequestedHz:(CGFloat)(hz > 0 ? hz : (fps > 0 ? fps : 60))
                      fps:(CGFloat)(fps > 0 ? fps : (hz > 0 ? hz : 60))];
    [[PMUltimatePowerEngine sharedEngine] deployMaximumPerformanceModeWithOptions:snapshot];
}

- (void)stopOverdriveEngine {
    [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
}

@end

@implementation PMSmoothEnginePro

+ (instancetype)sharedInstance {
    static PMSmoothEnginePro *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMSmoothEnginePro alloc] init]; });
    return instance;
}

- (CADisplayLink *)displayLink {
    return [PMPowerRefreshEngine sharedEngine].displayLink;
}

- (CFTimeInterval)lastFrameTimestamp {
    return [PMPerformanceMonitor sharedMonitor].lastFrameTimestamp;
}

- (NSUInteger)stutterCount {
    return [PMPerformanceMonitor sharedMonitor].droppedFrameCount;
}

- (void)startEngineWithMinHz:(CGFloat)minHz maxHz:(CGFloat)maxHz {
    [[TitaniumAbsoluteUnlockEngine sharedEngine] deployAbsoluteOverdriveWithMinHz:minHz
                                                                          maxHz:maxHz
                                                                            fps:maxHz];
}

- (void)startEngineWithOptions:(NSDictionary *)options {
    [[TitaniumAbsoluteUnlockEngine sharedEngine] deployConfiguredOverdriveWithOptions:
        [options isKindOfClass:[NSDictionary class]] ? options : @{}];
}

- (void)stopEngine {
    [[TitaniumAbsoluteUnlockEngine sharedEngine] stopOverdriveEngine];
}

@end

#pragma mark - App-scoped touch and power lifecycle

@interface PMInputAndDisplayBooster ()
@property (nonatomic) BOOL freeActive;
@property (nonatomic) BOOL premiumActive;
@property (nonatomic) BOOL adminActive;
@property (nonatomic) BOOL paused;
@property (nonatomic, copy) NSDictionary *lastAdminOptions;
@property (nonatomic, copy) NSDictionary *lastFreeOptions;
@property (nonatomic, copy) NSDictionary *lastPremiumOptions;
@property (nonatomic, strong) NSMapTable<UIScrollView *, NSNumber *> *originalTouchDelayValues;
@property (nonatomic, strong) NSMapTable<UIScrollView *, NSDictionary *> *originalAdminScrollValues;
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *originalAdminRasterValues;
@property (nonatomic) BOOL adminBridgeStatusChecked;
@property (nonatomic) BOOL adminBridgeThermalReduced;
@property (nonatomic, strong) dispatch_source_t adaptiveWatchdogTimer;
@property (nonatomic) NSInteger watchdogLastThermalState;
@property (nonatomic) BOOL watchdogLastLowPowerMode;
@property (nonatomic) BOOL watchdogLastCharging;
- (BOOL)deviceIsConstrained;
- (void)startAdaptiveWatchdog;
- (void)stopAdaptiveWatchdog;
- (void)applicationDidBecomeActive:(NSNotification *)note;
- (void)systemConstraintsChanged:(NSNotification *)note;
- (void)restoreTouchResponsiveness;
- (void)restoreAdminInterfaceOptions;
- (void)applyAdminInterfaceOptions:(NSDictionary *)options;
- (void)updateAdminLocalBridgeWithOptions:(NSDictionary *)options;
- (void)restoreAdminLocalBridge;
@end

@implementation PMInputAndDisplayBooster

+ (instancetype)sharedBooster {
    static PMInputAndDisplayBooster *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PMInputAndDisplayBooster alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _originalTouchDelayValues = [NSMapTable weakToStrongObjectsMapTable];
        _originalAdminScrollValues = [NSMapTable weakToStrongObjectsMapTable];
        _originalAdminRasterValues = [NSMapTable weakToStrongObjectsMapTable];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(systemConstraintsChanged:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
        if (@available(iOS 11.0, *)) {
            [center addObserver:self selector:@selector(systemConstraintsChanged:) name:NSProcessInfoThermalStateDidChangeNotification object:nil];
        }
        // Battery-state notifications are used only to reduce auxiliary work
        // while charging; they do not change charging current or voltage.
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        [center addObserver:self selector:@selector(systemConstraintsChanged:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)activateFreeOptimization {
    [self activateFreeOptimizationWithOptions:@{}];
}

- (void)activateFreeOptimizationWithOptions:(NSDictionary *)options {
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [options copy] ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{ [self activateFreeOptimizationWithOptions:snapshot]; });
        return;
    }
    BOOL needsActivation = !self.freeActive || self.paused;
    self.freeActive = YES;
    self.premiumActive = NO;
    self.adminActive = NO;
    self.paused = NO;
    self.lastFreeOptions = [options copy] ?: @{};
    self.lastPremiumOptions = @{};
    self.lastAdminOptions = @{};
    [[PMPerformanceMonitor sharedMonitor] startMonitoring];
    [self startAdaptiveWatchdog];
    [[PMSysStabilizerEngine sharedEngine] deploySystemStabilizerForServerMode:0];
    [self restoreAdminLocalBridge];
    [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
    [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
    [self restoreAdminInterfaceOptions];
    if (PMEngineOption(self.lastFreeOptions, @"FreeTouchTuningEnabled", YES)) {
        if (needsActivation) [self boostKeyboardAndTouchResponsiveness];
    } else {
        [self restoreTouchResponsiveness];
    }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && ![self deviceIsConstrained] &&
        PMEngineOption(self.lastFreeOptions, @"FreeRenderSchedulerEnabled", YES) &&
        PMEngineOption(self.lastFreeOptions, @"FreeSmoothEngineEnabled", YES)) {
        [[PMSmoothEngine sharedInstance] startEngineWithOptions:self.lastFreeOptions];
    } else {
        [[PMUltimateOptimizer sharedInstance] stopOptimizations];
    }
}

- (void)activatePremiumOptimization {
    [self activatePremiumOptimizationWithOptions:@{}];
}

- (void)activatePremiumOptimizationWithOptions:(NSDictionary *)options {
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [options copy] ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{ [self activatePremiumOptimizationWithOptions:snapshot]; });
        return;
    }
    BOOL needsActivation = !self.premiumActive || self.paused;
    self.freeActive = NO;
    self.premiumActive = YES;
    self.adminActive = NO;
    self.paused = NO;
    self.lastFreeOptions = @{};
    self.lastPremiumOptions = [options copy] ?: @{};
    self.lastAdminOptions = @{};
    [[PMPerformanceMonitor sharedMonitor] startMonitoring];
    [self startAdaptiveWatchdog];
    [[PMSysStabilizerEngine sharedEngine] deploySystemStabilizerForServerMode:1];
    [self restoreAdminLocalBridge];
    [[PMUltimateOptimizer sharedInstance] stopOptimizations];
    [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
    [self restoreAdminInterfaceOptions];
    if (PMEngineOption(self.lastPremiumOptions, @"PremiumTouchTuningEnabled", YES)) {
        if (needsActivation) [self boostKeyboardAndTouchResponsiveness];
    } else {
        [self restoreTouchResponsiveness];
    }
    [self preventLowPowerFrameDrops];
}

- (void)activateAdminOptimizationWithOptions:(NSDictionary *)options {
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [options copy] ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{ [self activateAdminOptimizationWithOptions:snapshot]; });
        return;
    }
    self.freeActive = NO;
    self.premiumActive = NO;
    self.adminActive = YES;
    self.paused = NO;
    self.lastAdminOptions = [options copy] ?: @{};
    [[PMPerformanceMonitor sharedMonitor] startMonitoring];
    [self startAdaptiveWatchdog];
    [[PMSysStabilizerEngine sharedEngine] deploySystemStabilizerForServerMode:2];
    [[PMUltimateOptimizer sharedInstance] stopOptimizations];
    [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
    [self applyAdminInterfaceOptions:self.lastAdminOptions];
}

- (void)refreshAdminOptimizationWithOptions:(NSDictionary *)options {
    if (![NSThread isMainThread]) {
        NSDictionary *snapshot = [options copy] ?: @{};
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshAdminOptimizationWithOptions:snapshot]; });
        return;
    }
    if (!self.adminActive || self.paused) return;
    self.lastAdminOptions = [options copy] ?: @{};
    [self applyAdminInterfaceOptions:self.lastAdminOptions];
}

- (void)applyAdminInterfaceOptions:(NSDictionary *)options {
    if (!self.adminActive || self.paused) return;
    [self restoreAdminInterfaceOptions];

    BOOL renderEnabled = options[@"AdminRenderSchedulerEnabled"]
        ? [options[@"AdminRenderSchedulerEnabled"] boolValue] : YES;
    BOOL touchEnabled = options[@"AdminTouchTuningEnabled"]
        ? [options[@"AdminTouchTuningEnabled"] boolValue] : YES;
    BOOL fastScrollEnabled = [options[@"AdminFastScrollEnabled"] boolValue];
    BOOL hideIndicators = [options[@"AdminHideScrollIndicatorsEnabled"] boolValue];
    BOOL staticCacheEnabled = [options[@"AdminStaticSurfaceCacheEnabled"] boolValue];
    [self updateAdminLocalBridgeWithOptions:options];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && ![self deviceIsConstrained] && renderEnabled) {
        [[PMSmoothEnginePro sharedInstance] startEngineWithOptions:options];
    } else {
        [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
    }

    if (touchEnabled) [self boostKeyboardAndTouchResponsiveness];
    else [self restoreTouchResponsiveness];

    NSMutableArray<UIView *> *pending = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if ([window isKindOfClass:[UIWindow class]]) [pending addObject:window];
    }
    NSUInteger visited = 0;
    const NSUInteger maximumVisitedViews = 4096;
    while (pending.count > 0 && visited < maximumVisitedViews) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (![view isKindOfClass:[UIView class]]) continue;
        visited++;

        if ([view isKindOfClass:[UIScrollView class]] && (fastScrollEnabled || hideIndicators)) {
            UIScrollView *scrollView = (UIScrollView *)view;
            if (![self.originalAdminScrollValues objectForKey:scrollView]) {
                [self.originalAdminScrollValues setObject:@{
                    @"decelerationRate": @(scrollView.decelerationRate),
                    @"vertical": @(scrollView.showsVerticalScrollIndicator),
                    @"horizontal": @(scrollView.showsHorizontalScrollIndicator)
                } forKey:scrollView];
            }
            if (fastScrollEnabled) scrollView.decelerationRate = UIScrollViewDecelerationRateFast;
            if (hideIndicators) {
                scrollView.showsVerticalScrollIndicator = NO;
                scrollView.showsHorizontalScrollIndicator = NO;
            }
        }

        NSString *identifier = view.accessibilityIdentifier;
        CGColorRef background = view.backgroundColor.CGColor;
        if (staticCacheEnabled && [identifier hasPrefix:@"pm.admin.static."] &&
            view.opaque && background && CGColorGetAlpha(background) >= 0.99) {
            if (![self.originalAdminRasterValues objectForKey:view]) {
                [self.originalAdminRasterValues setObject:@(view.layer.shouldRasterize) forKey:view];
            }
            [[PMUltimatePowerEngine sharedEngine] optimizeTargetView:view];
        }

        for (UIView *subview in [view.subviews reverseObjectEnumerator]) {
            if (visited + pending.count >= maximumVisitedViews) break;
            if ([subview isKindOfClass:[UIView class]]) [pending addObject:subview];
        }
    }
}

- (void)updateAdminLocalBridgeWithOptions:(NSDictionary *)options {
    BOOL bridgeEnabled = [options[@"AdminLocalDaemonBridgeEnabled"] boolValue];
    if (!bridgeEnabled) {
        [self restoreAdminLocalBridge];
        return;
    }

    if (!self.adminBridgeStatusChecked) {
        self.adminBridgeStatusChecked = YES;
        [PMLocalBridge sendLocalCommand:@"status" completion:^(BOOL success, NSString *response) {
            NSLog(@"[ProMotionControl][ADMIN Bridge] status %@: %@", success ? @"OK" : @"unavailable", response ?: @"");
        }];
    }

    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    BOOL thermalCooldownEnabled = options[@"AdminThermalCooldownEnabled"]
        ? [options[@"AdminThermalCooldownEnabled"] boolValue] : YES;
    BOOL shouldReduce = processInfo.isLowPowerModeEnabled;
    if (@available(iOS 11.0, *)) {
        NSProcessInfoThermalState state = processInfo.thermalState;
        if (state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical ||
            (thermalCooldownEnabled && state == NSProcessInfoThermalStateFair)) {
            shouldReduce = YES;
        }
    }
    if (shouldReduce == self.adminBridgeThermalReduced) return;

    self.adminBridgeThermalReduced = shouldReduce;
    NSString *command = shouldReduce ? @"thermal_reduce" : @"thermal_resume";
    [PMLocalBridge sendLocalCommand:command completion:^(BOOL success, NSString *response) {
        NSLog(@"[ProMotionControl][ADMIN Bridge] %@ %@: %@", command,
              success ? @"OK" : @"unavailable", response ?: @"");
    }];
}

- (void)restoreAdminLocalBridge {
    if (self.adminBridgeThermalReduced) {
        [PMLocalBridge sendLocalCommand:@"thermal_resume" completion:^(BOOL success, NSString *response) {
            NSLog(@"[ProMotionControl][ADMIN Bridge] restore %@: %@", success ? @"OK" : @"unavailable", response ?: @"");
        }];
    }
    self.adminBridgeThermalReduced = NO;
    self.adminBridgeStatusChecked = NO;
}

- (void)restoreAdminInterfaceOptions {
    NSArray<UIScrollView *> *scrollViews = [[self.originalAdminScrollValues keyEnumerator] allObjects];
    for (id candidate in scrollViews) {
        if (![candidate isKindOfClass:[UIScrollView class]]) continue;
        UIScrollView *scrollView = (UIScrollView *)candidate;
        NSDictionary *saved = [self.originalAdminScrollValues objectForKey:scrollView];
        if (![saved isKindOfClass:[NSDictionary class]]) continue;
        id deceleration = saved[@"decelerationRate"];
        id vertical = saved[@"vertical"];
        id horizontal = saved[@"horizontal"];
        if ([deceleration respondsToSelector:@selector(floatValue)]) scrollView.decelerationRate = [deceleration floatValue];
        if ([vertical respondsToSelector:@selector(boolValue)]) scrollView.showsVerticalScrollIndicator = [vertical boolValue];
        if ([horizontal respondsToSelector:@selector(boolValue)]) scrollView.showsHorizontalScrollIndicator = [horizontal boolValue];
    }
    [self.originalAdminScrollValues removeAllObjects];

    NSArray<UIView *> *views = [[self.originalAdminRasterValues keyEnumerator] allObjects];
    for (id candidate in views) {
        if (![candidate isKindOfClass:[UIView class]]) continue;
        UIView *view = (UIView *)candidate;
        NSNumber *saved = [self.originalAdminRasterValues objectForKey:view];
        if (saved) view.layer.shouldRasterize = saved.boolValue;
    }
    [self.originalAdminRasterValues removeAllObjects];
}

- (void)startAdaptiveWatchdog {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startAdaptiveWatchdog]; });
        return;
    }
    if (self.adaptiveWatchdogTimer || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || self.paused) return;

    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    self.watchdogLastThermalState = PMEngineThermalState();
    self.watchdogLastLowPowerMode = processInfo.isLowPowerModeEnabled;
    self.watchdogLastCharging = PMEngineDeviceIsCharging();

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;
    self.adaptiveWatchdogTimer = timer;
    // A 10-second fallback watchdog backs up iOS state notifications. It only
    // re-evaluates on a changed constraint or a missing selected-tier link.
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        10 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || strongSelf.paused) {
            [strongSelf stopAdaptiveWatchdog];
            return;
        }

        NSProcessInfo *currentProcessInfo = NSProcessInfo.processInfo;
        NSInteger thermal = PMEngineThermalState();
        BOOL lowPower = currentProcessInfo.isLowPowerModeEnabled;
        BOOL charging = PMEngineDeviceIsCharging();
        BOOL stateChanged = thermal != strongSelf.watchdogLastThermalState ||
                            lowPower != strongSelf.watchdogLastLowPowerMode ||
                            charging != strongSelf.watchdogLastCharging;
        strongSelf.watchdogLastThermalState = thermal;
        strongSelf.watchdogLastLowPowerMode = lowPower;
        strongSelf.watchdogLastCharging = charging;

        BOOL missingSelectedLink = NO;
        if (strongSelf.freeActive && ![strongSelf deviceIsConstrained] &&
            PMEngineOption(strongSelf.lastFreeOptions, @"FreeRenderSchedulerEnabled", YES) &&
            PMEngineOption(strongSelf.lastFreeOptions, @"FreeSmoothEngineEnabled", YES)) {
            missingSelectedLink = ([PMUltimateOptimizer sharedInstance].displayLink == nil);
        } else if (strongSelf.premiumActive && ![strongSelf deviceIsConstrained] &&
                   PMEngineOption(strongSelf.lastPremiumOptions, @"PremiumRenderSchedulerEnabled", YES)) {
            missingSelectedLink = ([PMAdvancedOptimizer sharedInstance].displayLink == nil);
        } else if (strongSelf.adminActive && ![strongSelf deviceIsConstrained] &&
                   PMEngineOption(strongSelf.lastAdminOptions, @"AdminRenderSchedulerEnabled", YES)) {
            missingSelectedLink = ([PMSmoothEnginePro sharedInstance].displayLink == nil);
        }

        if (stateChanged || missingSelectedLink) [strongSelf systemConstraintsChanged:nil];
    });
    dispatch_resume(timer);
}

- (void)stopAdaptiveWatchdog {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopAdaptiveWatchdog]; });
        return;
    }
    if (self.adaptiveWatchdogTimer) {
        dispatch_source_cancel(self.adaptiveWatchdogTimer);
        self.adaptiveWatchdogTimer = nil;
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applicationDidBecomeActive:nil]; });
        return;
    }
    if (!self.paused) {
        [self startAdaptiveWatchdog];
        return;
    }

    self.paused = NO;
    [[PMPerformanceMonitor sharedMonitor] startMonitoring];
    if (self.adminActive) {
        NSDictionary *adminOptions = self.lastAdminOptions ?: @{};
        BOOL transitionAssist = PMEngineOption(adminOptions, @"AdminHomeTransitionShieldEnabled", YES);
        if (transitionAssist) {
            [[TitaniumUltimateHomeShieldEngine sharedEngine] triggerHomeStutterShieldBoostWithHandler:^{
                if (self.adminActive && !self.paused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                    [self applyAdminInterfaceOptions:self.lastAdminOptions ?: @{}];
                }
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.adminActive && !self.paused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                    [self applyAdminInterfaceOptions:self.lastAdminOptions ?: @{}];
                }
            });
        }
    } else if (self.premiumActive) {
        [self preventLowPowerFrameDrops];
    } else if (self.freeActive) {
        BOOL enabled = PMEngineOption(self.lastFreeOptions, @"FreeRenderSchedulerEnabled", YES) &&
                       PMEngineOption(self.lastFreeOptions, @"FreeSmoothEngineEnabled", YES);
        if (enabled && ![self deviceIsConstrained]) {
            [[PMSmoothEngine sharedInstance] startEngineWithOptions:self.lastFreeOptions ?: @{}];
        } else {
            [[PMUltimateOptimizer sharedInstance] stopOptimizations];
        }
    }
    [self startAdaptiveWatchdog];
}

- (void)deactivatePremiumOptimization {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self deactivatePremiumOptimization]; });
        return;
    }
    self.freeActive = NO;
    self.premiumActive = NO;
    self.adminActive = NO;
    self.paused = NO;
    self.lastAdminOptions = @{};
    [self stopAdaptiveWatchdog];
    [[TitaniumAdaptiveGovernorEngine sharedEngine] stopGovernorEngine];
    [[TitaniumUltimateHomeShieldEngine sharedEngine] stopEngine];
    [self restoreAdminLocalBridge];
    [[PMUltimateOptimizer sharedInstance] stopOptimizations];
    [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
    [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
    [[PMPerformanceMonitor sharedMonitor] stopMonitoring];
    [[PMSysStabilizerEngine sharedEngine] stopStabilizer];
    [self restoreTouchResponsiveness];
    [self restoreAdminInterfaceOptions];
}

- (void)suspendOptimizations {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self suspendOptimizations]; });
        return;
    }
    // Preserve selected server state, but release transient UI/render work while
    // this app is backgrounded. Do not alter AVAudioSession: system/third-party
    // background music is owned by its own process and remains untouched.
    self.paused = YES;
    [self stopAdaptiveWatchdog];
    [[TitaniumAdaptiveGovernorEngine sharedEngine] stopGovernorEngine];
    [[TitaniumUltimateHomeShieldEngine sharedEngine] stopEngine];
    [[PMUltimateOptimizer sharedInstance] stopOptimizations];
    [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
    [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
    [[PMPerformanceMonitor sharedMonitor] stopMonitoring];
    [[PMSysStabilizerEngine sharedEngine] stopStabilizer];
    [self restoreTouchResponsiveness];
    [self restoreAdminInterfaceOptions];
}

- (void)boostKeyboardAndTouchResponsiveness {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self boostKeyboardAndTouchResponsiveness]; });
        return;
    }
    if ((!self.freeActive && !self.premiumActive && !self.adminActive) || self.paused ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    // Only tune scroll views owned by this application. Never change system or
    // third-party gesture recognizers. Iterative traversal is bounded to avoid
    // deep-recursion stack growth on large/complex view trees.
    NSMutableArray<UIView *> *pending = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if ([window isKindOfClass:[UIWindow class]]) [pending addObject:window];
    }
    NSUInteger visited = 0;
    const NSUInteger maximumVisitedViews = 4096;
    while (pending.count > 0 && visited < maximumVisitedViews) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (![view isKindOfClass:[UIView class]]) continue;
        visited++;

        if ([view isKindOfClass:[UIScrollView class]]) {
            UIScrollView *scrollView = (UIScrollView *)view;
            if (![self.originalTouchDelayValues objectForKey:scrollView]) {
                [self.originalTouchDelayValues setObject:@(scrollView.delaysContentTouches) forKey:scrollView];
            }
            // Keep immediate touch delivery scoped to app-owned scroll views.
            scrollView.delaysContentTouches = NO;
        }

        NSArray<UIView *> *subviews = view.subviews;
        for (UIView *subview in [subviews reverseObjectEnumerator]) {
            // Bound both the visited count and pending queue so a pathological
            // view tree cannot allocate an unbounded traversal array.
            if (visited + pending.count >= maximumVisitedViews) break;
            if ([subview isKindOfClass:[UIView class]]) [pending addObject:subview];
        }
    }
}

- (void)restoreTouchResponsiveness {
    // Enumerate a retained snapshot. Weak keys may disappear as UIKit tears
    // down a view hierarchy; taking a snapshot avoids mutating a live enumerator.
    NSArray<UIScrollView *> *scrollViews = [[self.originalTouchDelayValues keyEnumerator] allObjects];
    for (id candidate in scrollViews) {
        if (![candidate isKindOfClass:[UIScrollView class]]) continue;
        UIScrollView *scrollView = (UIScrollView *)candidate;
        NSNumber *savedValue = [self.originalTouchDelayValues objectForKey:scrollView];
        if (savedValue) scrollView.delaysContentTouches = savedValue.boolValue;
    }
    [self.originalTouchDelayValues removeAllObjects];
}

- (BOOL)deviceIsConstrained {
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (processInfo.isLowPowerModeEnabled) return YES;
    if (@available(iOS 11.0, *)) {
        NSProcessInfoThermalState state = processInfo.thermalState;
        return state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical;
    }
    return NO;
}

- (void)preventLowPowerFrameDrops {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self preventLowPowerFrameDrops]; });
        return;
    }
    if (!self.premiumActive || self.paused ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
        return;
    }

    // Respect Low Power Mode and serious thermal pressure. We do not attempt to
    // defeat OS throttling or hold CPU/GPU clocks above the system's safe limits.
    if ([self deviceIsConstrained]) {
        [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
        return;
    }
    if (!PMEngineOption(self.lastPremiumOptions, @"PremiumRenderSchedulerEnabled", YES)) {
        [[PMAdvancedOptimizer sharedInstance] stopRenderLoop];
        return;
    }
    [[PMUltimateOptimizer sharedInstance] stopOptimizations];
    [[PMSmoothEngineAdvanced sharedInstance] startEngineWithOptions:self.lastPremiumOptions ?: @{}];
}

- (void)applicationDidEnterBackground:(NSNotification *)note {
    (void)note;
    [self suspendOptimizations];
}

- (void)systemConstraintsChanged:(NSNotification *)note {
    (void)note;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self systemConstraintsChanged:nil]; });
        return;
    }
    if (self.paused) return;
    if (self.adminActive) {
        NSDictionary *adminOptions = self.lastAdminOptions ?: @{};
        if (![self deviceIsConstrained] && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            [self applyAdminInterfaceOptions:adminOptions];
        } else {
            [self updateAdminLocalBridgeWithOptions:adminOptions];
            [[PMUltimatePowerEngine sharedEngine] disengagePerformanceMode];
        }
    } else if (self.premiumActive) {
        [self preventLowPowerFrameDrops];
    } else if (self.freeActive && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        BOOL freeRenderEnabled = PMEngineOption(self.lastFreeOptions, @"FreeRenderSchedulerEnabled", YES) &&
            PMEngineOption(self.lastFreeOptions, @"FreeSmoothEngineEnabled", YES);
        if ([self deviceIsConstrained] || !freeRenderEnabled) {
            [[PMUltimateOptimizer sharedInstance] stopOptimizations];
        } else {
            // FREE remains lightweight and never requests a high-priority thread.
            [[PMSmoothEngine sharedInstance] startEngineWithOptions:self.lastFreeOptions ?: @{}];
        }
    }
}

@end
