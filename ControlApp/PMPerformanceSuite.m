#import "PMPerformanceSuite.h"
#import <mach/mach.h>
#import <mach/task_info.h>
#import <math.h>
#import <string.h>
#import <CoreFoundation/CoreFoundation.h>

static BOOL PMPowerExactRatePreference(void)
{
    CFPreferencesAppSynchronize(CFSTR("com.dell.promotioncontrol"));
    Boolean valid = false;
    Boolean value = CFPreferencesGetAppBooleanValue(CFSTR("ExactRateEnforcement"),
                                                    CFSTR("com.dell.promotioncontrol"), &valid);
    return valid ? (value != 0) : YES;
}

#pragma mark - PMPerformanceMonitor

@interface PMPerformanceMonitor ()
@property (nonatomic, readwrite) NSUInteger droppedFrameCount;
@property (nonatomic) BOOL monitoring;
@property (nonatomic) CFTimeInterval lastFrameTimestamp;
@property (nonatomic, readwrite) CFTimeInterval lastFrameDelta;
@property (nonatomic, readwrite) CGFloat measuredFramesPerSecond;
@property (nonatomic) NSUInteger consecutiveLateFrames;
@property (nonatomic) NSUInteger consecutiveGoodFrames;
@property (nonatomic) BOOL framePressureActive;
@property (nonatomic) BOOL memoryPressureActive;
@end

@implementation PMPerformanceMonitor

+ (instancetype)sharedMonitor {
    static PMPerformanceMonitor *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMPerformanceMonitor alloc] init]; });
    return instance;
}

- (BOOL)shouldThrottleAuxiliaryWork {
    @synchronized (self) {
        return _framePressureActive || _memoryPressureActive;
    }
}

- (void)setMemoryPressureActive:(BOOL)active {
    @synchronized (self) {
        _memoryPressureActive = active;
    }
}

- (void)startMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startMonitoring]; });
        return;
    }
    self.monitoring = YES;
    self.lastFrameTimestamp = 0.0;
    self.lastFrameDelta = 0.0;
    self.measuredFramesPerSecond = 0.0;
    self.consecutiveLateFrames = 0;
    self.consecutiveGoodFrames = 0;
    self.droppedFrameCount = 0;
    self.framePressureActive = NO;
}

- (void)recordFrameTimestamp:(CFTimeInterval)timestamp targetTimestamp:(CFTimeInterval)targetTimestamp {
    if (!self.monitoring || !isfinite(timestamp) || timestamp <= 0.0) return;
    if (self.lastFrameTimestamp <= 0.0 || timestamp <= self.lastFrameTimestamp ||
        (timestamp - self.lastFrameTimestamp) > 0.5) {
        self.lastFrameTimestamp = timestamp;
        self.lastFrameDelta = 0.0;
        self.measuredFramesPerSecond = 0.0;
        self.consecutiveLateFrames = 0;
        self.consecutiveGoodFrames = 0;
        return;
    }

    CFTimeInterval delta = timestamp - self.lastFrameTimestamp;
    self.lastFrameTimestamp = timestamp;
    self.lastFrameDelta = delta;
    self.measuredFramesPerSecond = delta > 0.0 ? (CGFloat)(1.0 / delta) : 0.0;
    CFTimeInterval expectedInterval = targetTimestamp > timestamp ? targetTimestamp - timestamp : 0.0;
    CFTimeInterval lateThreshold = expectedInterval > 0.0 ? MAX(0.012, expectedInterval * 1.5) : 0.018;
    if (delta > lateThreshold) {
        if (self.droppedFrameCount < NSUIntegerMax) self.droppedFrameCount++;
        self.consecutiveLateFrames = MIN(self.consecutiveLateFrames + 1, (NSUInteger)64);
        self.consecutiveGoodFrames = 0;
        if (self.consecutiveLateFrames >= 8) self.framePressureActive = YES;
    } else {
        self.consecutiveLateFrames = 0;
        self.consecutiveGoodFrames = MIN(self.consecutiveGoodFrames + 1, (NSUInteger)64);
        if (self.consecutiveGoodFrames >= 18) self.framePressureActive = NO;
    }
}

- (void)stopMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopMonitoring]; });
        return;
    }
    self.monitoring = NO;
    self.lastFrameTimestamp = 0.0;
    self.lastFrameDelta = 0.0;
    self.measuredFramesPerSecond = 0.0;
    self.consecutiveLateFrames = 0;
    self.consecutiveGoodFrames = 0;
    self.framePressureActive = NO;
}

@end

#pragma mark - PMPowerRefreshEngine

@interface PMPowerRefreshEngine ()
@property (nonatomic, strong, nullable) CADisplayLink *customDisplayLink;
@property (nonatomic, readwrite) CGFloat targetMinimumRate;
@property (nonatomic, readwrite) CGFloat targetMaximumRate;
@property (nonatomic) CGFloat deviceMaximumRate;
@property (nonatomic) CGFloat targetPreferredRate;
@property (nonatomic) BOOL throttleApplied;
@property (nonatomic) BOOL exactRateLocked;
@end

@implementation PMPowerRefreshEngine

+ (instancetype)sharedEngine {
    static PMPowerRefreshEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMPowerRefreshEngine alloc] init]; });
    return instance;
}

- (CADisplayLink *)displayLink {
    return self.customDisplayLink;
}

- (void)configureRefreshRateFromMin:(CGFloat)minRate toMax:(CGFloat)maxRate {
    [self configureRefreshRateFromMin:minRate toMax:maxRate preferred:maxRate];
}

- (void)configureRefreshRateFromMin:(CGFloat)minRate toMax:(CGFloat)maxRate preferred:(CGFloat)preferredRate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self configureRefreshRateFromMin:minRate toMax:maxRate preferred:preferredRate]; });
        return;
    }
    BOOL exactRate = PMPowerExactRatePreference();
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        processInfo.isLowPowerModeEnabled ||
        processInfo.thermalState == NSProcessInfoThermalStateSerious ||
        processInfo.thermalState == NSProcessInfoThermalStateCritical) {
        [self stopRefreshEngine];
        return;
    }

    CGFloat requestedMin = isfinite(minRate) ? MIN(244.0, MAX(10.0, minRate)) : 10.0;
    CGFloat requestedMax = isfinite(maxRate) ? MIN(244.0, MAX(10.0, maxRate)) : 60.0;
    if (requestedMin > requestedMax) {
        CGFloat swap = requestedMin;
        requestedMin = requestedMax;
        requestedMax = swap;
    }

    NSInteger screenMaximum = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    self.deviceMaximumRate = (CGFloat)(screenMaximum > 0 ? screenMaximum : 60);
    self.exactRateLocked = exactRate;
    self.targetMaximumRate = MIN(requestedMax, self.deviceMaximumRate);
    self.targetMinimumRate = MIN(requestedMin, self.targetMaximumRate);
    self.targetPreferredRate = MIN(self.targetMaximumRate, MAX(self.targetMinimumRate,
        isfinite(preferredRate) ? preferredRate : self.targetMaximumRate));
    self.throttleApplied = NO;

    [self.customDisplayLink invalidate];
    self.customDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleRefreshTick:)];
    [self applyCurrentRateRange];
    [self.customDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)applyCurrentRateRange {
    if (!self.customDisplayLink) return;
    CGFloat maximum = self.targetMaximumRate;
    if (!self.exactRateLocked && [PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork) {
        maximum = MIN(maximum, MAX(30.0, floor(self.deviceMaximumRate * 0.50)));
    }
    CGFloat minimum = MIN(self.targetMinimumRate, maximum);
    CGFloat preferred = MIN(maximum, MAX(minimum, self.targetPreferredRate));
    if (@available(iOS 15.0, *)) {
        self.customDisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(minimum, maximum, preferred);
    } else {
        // Older iOS releases accept one preferred rate, not a min/max range.
        self.customDisplayLink.preferredFramesPerSecond = (NSInteger)preferred;
    }
}

- (void)handleRefreshTick:(CADisplayLink *)sender {
    [[PMPerformanceMonitor sharedMonitor] recordFrameTimestamp:sender.timestamp targetTimestamp:sender.targetTimestamp];
    if (self.exactRateLocked) return;
    BOOL shouldThrottle = [PMPerformanceMonitor sharedMonitor].shouldThrottleAuxiliaryWork;
    if (shouldThrottle != self.throttleApplied) {
        self.throttleApplied = shouldThrottle;
        [self applyCurrentRateRange];
    }
}

- (void)stopRefreshEngine {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopRefreshEngine]; });
        return;
    }
    [self.customDisplayLink invalidate];
    self.customDisplayLink = nil;
    self.targetMinimumRate = 0.0;
    self.targetMaximumRate = 0.0;
    self.deviceMaximumRate = 0.0;
    self.targetPreferredRate = 0.0;
    self.throttleApplied = NO;
}

@end

#pragma mark - PMCorePerformanceEngine

@implementation PMCorePerformanceEngine

+ (instancetype)sharedEngine {
    static PMCorePerformanceEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMCorePerformanceEngine alloc] init]; });
    return instance;
}

- (void)deployCorePerformanceEngine {
    [self deployCorePerformanceEngineWithMinRate:10.0 maxRate:244.0];
}

- (void)deployCorePerformanceEngineWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate {
    [self deployCorePerformanceEngineWithMinRate:minRate maxRate:maxRate preferred:maxRate];
}

- (void)deployCorePerformanceEngineWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate preferred:(CGFloat)preferredRate {
    [[PMPowerRefreshEngine sharedEngine] configureRefreshRateFromMin:minRate toMax:maxRate preferred:preferredRate];
}

- (void)optimizeViewRendering:(UIView *)targetView {
    if (![NSThread isMainThread] || ![targetView isKindOfClass:[UIView class]]) return;
    NSString *identifier = targetView.accessibilityIdentifier;
    CGColorRef background = targetView.backgroundColor.CGColor;
    if (![identifier hasPrefix:@"pm.admin.static."] || !targetView.opaque || !background ||
        CGColorGetAlpha(background) < 0.99 || CGRectGetWidth(targetView.bounds) < 2.0 ||
        CGRectGetHeight(targetView.bounds) < 2.0) return;
    targetView.layer.shouldRasterize = YES;
    targetView.layer.rasterizationScale = UIScreen.mainScreen.scale;
}

- (void)stopEngine {
    [[PMPowerRefreshEngine sharedEngine] stopRefreshEngine];
}

@end

#pragma mark - PMSysStabilizerEngine

@interface PMSysStabilizerEngine ()
@property (nonatomic, strong, nullable) dispatch_source_t memoryMonitorTimer;
@property (nonatomic) int32_t activeServerMode;
@property (nonatomic) CFTimeInterval lastCachePurgeTime;
@property (nonatomic) BOOL memoryWarningObserverInstalled;
- (void)sampleResidentMemory;
- (void)purgeSystemMemoryIfNeeded;
- (void)handleMemoryWarning:(NSNotification *)note;
@end

@implementation PMSysStabilizerEngine

+ (instancetype)sharedEngine {
    static PMSysStabilizerEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMSysStabilizerEngine alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        self.memoryWarningObserverInstalled = YES;
    }
    return self;
}

- (void)deploySystemStabilizer {
    [self deploySystemStabilizerForServerMode:0];
}

- (void)deploySystemStabilizerForServerMode:(NSInteger)serverMode {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self deploySystemStabilizerForServerMode:serverMode]; });
        return;
    }
    int32_t normalizedMode = (int32_t)MIN(MAX(serverMode, 0), 2);
    if (self.memoryMonitorTimer && self.activeServerMode == normalizedMode) return;
    [self stopStabilizer];
    __atomic_store_n(&_activeServerMode, normalizedMode, __ATOMIC_RELEASE);

    // FREE checks least often; PREMIUM/ADMIN use progressively shorter
    // intervals, but none continuously purges caches or allocates dummy RAM.
    NSTimeInterval interval = normalizedMode == 2 ? 60.0 : (normalizedMode == 1 ? 75.0 : 90.0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!timer) return;
    self.memoryMonitorTimer = timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self sampleResidentMemory];
    });
    dispatch_resume(timer);
}

- (void)sampleResidentMemory {
    mach_task_basic_info_data_t info;
    memset(&info, 0, sizeof(info));
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    if (result != KERN_SUCCESS) return;

    int32_t mode = __atomic_load_n(&_activeServerMode, __ATOMIC_ACQUIRE);
    uint64_t threshold = mode == 2 ? (384ULL * 1024ULL * 1024ULL) :
                         (mode == 1 ? (448ULL * 1024ULL * 1024ULL) : (512ULL * 1024ULL * 1024ULL));
    uint64_t resident = (uint64_t)info.resident_size;
    BOOL pressured = resident > threshold;
    BOOL recovered = resident < (threshold * 85ULL / 100ULL);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (pressured) {
            [[PMPerformanceMonitor sharedMonitor] setMemoryPressureActive:YES];
            [self purgeSystemMemoryIfNeeded];
        } else if (recovered) {
            [[PMPerformanceMonitor sharedMonitor] setMemoryPressureActive:NO];
        }
    });
}

- (void)handleMemoryWarning:(NSNotification *)note {
    (void)note;
    // React only to a real OS memory warning. Never synthesize a system-wide
    // UIApplicationDidReceiveMemoryWarningNotification.
    [[PMPerformanceMonitor sharedMonitor] setMemoryPressureActive:YES];
    [self purgeSystemMemoryInstantly];
}

- (void)purgeSystemMemoryInstantly {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self purgeSystemMemoryInstantly]; });
        return;
    }
    self.lastCachePurgeTime = CACurrentMediaTime();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
    });
}

- (void)purgeSystemMemoryIfNeeded {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastCachePurgeTime < 120.0) return;
    self.lastCachePurgeTime = now;
    // RSS threshold alone no longer clears NSURLCache: that can force network
    // refetches and add radio/CPU work. The governor sheds auxiliary frame work;
    // the cache is cleared only after a genuine OS memory-warning notification.
}

- (void)stopStabilizer {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self stopStabilizer]; });
        return;
    }
    if (self.memoryMonitorTimer) {
        dispatch_source_cancel(self.memoryMonitorTimer);
        self.memoryMonitorTimer = nil;
    }
}

- (void)dealloc {
    if (self.memoryMonitorTimer) dispatch_source_cancel(self.memoryMonitorTimer);
    if (self.memoryWarningObserverInstalled) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
}

@end

#pragma mark - PMUltimateNexusEngine

@implementation PMUltimateNexusEngine

+ (instancetype)sharedEngine {
    static PMUltimateNexusEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[PMUltimateNexusEngine alloc] init]; });
    return instance;
}

- (void)deployNexusPerformanceSuiteWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate {
    [self deployNexusPerformanceSuiteWithMinRate:minRate maxRate:maxRate preferred:maxRate];
}

- (void)deployNexusPerformanceSuiteWithMinRate:(CGFloat)minRate maxRate:(CGFloat)maxRate preferred:(CGFloat)preferredRate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self deployNexusPerformanceSuiteWithMinRate:minRate maxRate:maxRate preferred:preferredRate]; });
        return;
    }
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        processInfo.isLowPowerModeEnabled) {
        [self shutdownNexusEngine];
        return;
    }
    if (@available(iOS 11.0, *)) {
        if (processInfo.thermalState == NSProcessInfoThermalStateSerious ||
            processInfo.thermalState == NSProcessInfoThermalStateCritical) {
            [self shutdownNexusEngine];
            return;
        }
    }
    [[PMCorePerformanceEngine sharedEngine] deployCorePerformanceEngineWithMinRate:minRate maxRate:maxRate preferred:preferredRate];
}

- (void)shutdownNexusEngine {
    [[PMCorePerformanceEngine sharedEngine] stopEngine];
}

@end
