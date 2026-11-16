#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// Shared, low-overhead frame sampler. It piggybacks on the active server's
// display link instead of creating a second CADisplayLink of its own.
@interface PMPerformanceMonitor : NSObject
@property (nonatomic, readonly) NSUInteger droppedFrameCount;
@property (nonatomic, readonly) BOOL shouldThrottleAuxiliaryWork;
@property (nonatomic, readonly) CFTimeInterval lastFrameTimestamp;
@property (nonatomic, readonly) CFTimeInterval lastFrameDelta;
@property (nonatomic, readonly) CGFloat measuredFramesPerSecond;
+ (instancetype)sharedMonitor;
- (void)startMonitoring;
- (void)stopMonitoring;
- (void)recordFrameTimestamp:(CFTimeInterval)timestamp targetTimestamp:(CFTimeInterval)targetTimestamp;
- (void)setMemoryPressureActive:(BOOL)active;
@end

// Device-aware refresh request facade. The requested 10...244 range is always
// clamped to the physical display maximum reported by UIKit.
@interface PMPowerRefreshEngine : NSObject
@property (nonatomic, strong, readonly, nullable) CADisplayLink *displayLink;
@property (nonatomic, readonly) CGFloat targetMinimumRate;
@property (nonatomic, readonly) CGFloat targetMaximumRate;
+ (instancetype)sharedEngine;
- (void)configureRefreshRateFromMin:(CGFloat)minRate toMax:(CGFloat)maxRate;
- (void)configureRefreshRateFromMin:(CGFloat)minRate toMax:(CGFloat)maxRate preferred:(CGFloat)preferredRate;
- (void)stopRefreshEngine;
@end

// Core performance facade used by ADMIN/Nexus. Rendering changes are limited
// to explicitly marked, opaque, static views owned by the ControlApp.
@interface PMCorePerformanceEngine : NSObject
+ (instancetype)sharedEngine;
- (void)deployCorePerformanceEngine;
- (void)deployCorePerformanceEngineWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate;
- (void)deployCorePerformanceEngineWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate preferred:(CGFloat)preferredRate;
- (void)optimizeViewRendering:(UIView *)targetView;
- (void)stopEngine;
@end

// App-local stabilizer. It reacts to real memory-warning notifications and
// samples this process's resident size at a tier-specific, low frequency.
@interface PMSysStabilizerEngine : NSObject
+ (instancetype)sharedEngine;
- (void)deploySystemStabilizer;
- (void)deploySystemStabilizerForServerMode:(NSInteger)serverMode;
- (void)purgeSystemMemoryInstantly;
- (void)stopStabilizer;
@end

// ADMIN-only orchestrator that composes CorePerformance, PowerRefresh,
// PerformanceMonitor, and the shared system stabilizer without duplicate loops.
@interface PMUltimateNexusEngine : NSObject
+ (instancetype)sharedEngine;
- (void)deployNexusPerformanceSuiteWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate;
- (void)deployNexusPerformanceSuiteWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate preferred:(CGFloat)preferredRate;
- (void)shutdownNexusEngine;
@end

NS_ASSUME_NONNULL_END
