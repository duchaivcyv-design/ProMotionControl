#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import "PMPerformanceSuite.h"

NS_ASSUME_NONNULL_BEGIN

// Shared thermal/load governor used by FREE, PREMIUM and ADMIN. It deliberately
// reuses each tier's existing CADisplayLink instead of creating a second render loop.
@interface TitaniumAdaptiveGovernorEngine : NSObject
@property (nonatomic, readonly) CGFloat targetHz;
@property (nonatomic, readonly) CGFloat targetFPS;
@property (nonatomic, readonly) CGFloat effectiveHz;
@property (nonatomic, readonly) CGFloat effectiveFPS;
@property (nonatomic, readonly) NSInteger activeServerMode;
@property (nonatomic, readonly) BOOL isThrottled;
+ (instancetype)sharedEngine;
- (void)deployAdaptiveGovernorWithHz:(CGFloat)hz fps:(CGFloat)fps;
- (void)deployAdaptiveGovernorWithHz:(CGFloat)hz
                                  fps:(CGFloat)fps
                           serverMode:(NSInteger)serverMode
                         thermalGuard:(BOOL)thermalGuard
                       chargingGuard:(BOOL)chargingGuard;
- (void)stopGovernorEngine;
@end

// ADMIN-only foreground transition helper. The handler runs inside the
// ControlApp process; it does not inject into or modify SpringBoard.
@interface TitaniumUltimateHomeShieldEngine : NSObject
@property (nonatomic, readonly) BOOL isHomeTransitionActive;
+ (instancetype)sharedEngine;
- (void)triggerHomeStutterShieldBoostWithHandler:(dispatch_block_t)handler;
- (void)stopEngine;
@end

// FREE engine: a low-overhead, app-local display cadence request.
@interface PMUltimateOptimizer : NSObject
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
+ (instancetype)sharedInstance;
- (void)deployUltimateOptimizations;
- (void)deployUltimateOptimizationsWithOptions:(NSDictionary *)options;
- (void)stopOptimizations;
@end

// FREE-facing facade matching the requested PMSmoothEngine API. It delegates
// to PMUltimateOptimizer so FREE owns exactly one DisplayLink (no duplicate
// render loops are created).
@interface PMSmoothEngine : NSObject
@property (nonatomic, strong, readonly, nullable) CADisplayLink *displayLink;
+ (instancetype)sharedInstance;
- (void)startEngine;
- (void)startEngineWithOptions:(NSDictionary *)options;
- (void)stopEngine;
@end

// PREMIUM engine: requests a higher display cadence while respecting iOS policy.
@interface PMAdvancedOptimizer : NSObject
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
+ (instancetype)sharedInstance;
- (void)startHighPerformanceRenderLoop;
- (void)startHighPerformanceRenderLoopWithThermalGuard:(BOOL)thermalGuard chargingGuard:(BOOL)chargingGuard lowLatency:(BOOL)lowLatency;
- (void)startHighPerformanceRenderLoopWithOptions:(NSDictionary *)options;
- (void)stopRenderLoop;
@end

// ADMIN engine: an app-local high-cadence request. It never raises thread
// priority, disables system thermal policy, or hooks third-party processes.
@interface PMUltimatePowerEngine : NSObject
+ (instancetype)sharedEngine;
- (void)deployMaximumPerformanceMode;
- (void)deployMaximumPerformanceModeWithThermalCooldown:(BOOL)enabled;
- (void)deployMaximumPerformanceModeWithThermalCooldown:(BOOL)thermalEnabled chargingCooldown:(BOOL)chargingEnabled;
- (void)deployMaximumPerformanceModeWithThermalCooldown:(BOOL)thermalEnabled chargingCooldown:(BOOL)chargingEnabled adaptiveFramePacing:(BOOL)adaptiveFramePacing;
- (void)deployMaximumPerformanceModeWithOptions:(NSDictionary *)options;
- (void)disengagePerformanceMode;
- (void)optimizeTargetView:(UIView *)view;
@end

// PREMIUM adapter for the supplied PMSmoothEngineAdvanced API. It delegates to
// PMAdvancedOptimizer and reuses its single CADisplayLink and shared monitor.
@interface PMSmoothEngineAdvanced : NSObject
@property (nonatomic, strong, readonly, nullable) CADisplayLink *displayLink;
+ (instancetype)sharedInstance;
- (void)startEngineWithMinHz:(CGFloat)minHz maxHz:(CGFloat)maxHz;
- (void)startEngineWithOptions:(NSDictionary *)options;
- (void)stopEngine;
@end

// ADMIN adapter for the supplied PMSmoothEnginePro API. Metrics are read from
// the existing shared monitor; no second display loop or cache purge is added.
@interface PMSmoothEnginePro : NSObject
@property (nonatomic, strong, readonly, nullable) CADisplayLink *displayLink;
@property (nonatomic, readonly) CFTimeInterval lastFrameTimestamp;
@property (nonatomic, readonly) NSUInteger stutterCount;
+ (instancetype)sharedInstance;
- (void)startEngineWithMinHz:(CGFloat)minHz maxHz:(CGFloat)maxHz;
- (void)startEngineWithOptions:(NSDictionary *)options;
- (void)stopEngine;
@end

// ADMIN rate adapter retaining the supplied API name. It requests the selected
// rate through the public CADisplayLink path; it cannot unlock panel hardware.
@interface TitaniumAbsoluteUnlockEngine : NSObject
@property (nonatomic, readonly) CGFloat targetHz;
@property (nonatomic, readonly) CGFloat targetFPS;
+ (instancetype)sharedEngine;
- (void)deployAbsoluteOverdriveWithHz:(CGFloat)hz fps:(CGFloat)fps;
- (void)deployAbsoluteOverdriveWithMinHz:(CGFloat)minHz maxHz:(CGFloat)maxHz fps:(CGFloat)fps;
- (void)deployConfiguredOverdriveWithOptions:(NSDictionary *)options;
- (void)stopOverdriveEngine;
@end

@interface PMInputAndDisplayBooster : NSObject
+ (instancetype)sharedBooster;
- (void)activateFreeOptimization;
- (void)activateFreeOptimizationWithOptions:(NSDictionary *)options;
- (void)activatePremiumOptimization;
- (void)activatePremiumOptimizationWithOptions:(NSDictionary *)options;
- (void)activateAdminOptimizationWithOptions:(NSDictionary *)options;
- (void)refreshAdminOptimizationWithOptions:(NSDictionary *)options;
- (void)deactivatePremiumOptimization;
- (void)suspendOptimizations;
- (void)boostKeyboardAndTouchResponsiveness;
- (void)preventLowPowerFrameDrops;
@end

NS_ASSUME_NONNULL_END
