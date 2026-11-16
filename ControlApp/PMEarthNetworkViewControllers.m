#import "PMEarthNetworkViewControllers.h"
#import "PMPerformanceSuite.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Network/Network.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <string.h>
#import <math.h>

#pragma mark - Shared local styling

static UIColor *PMMediaAccentColor(void) {
    if (@available(iOS 13.0, *)) return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.24 green:0.78 blue:1.0 alpha:1.0]
            : [UIColor colorWithRed:0.05 green:0.42 blue:0.78 alpha:1.0];
    }];
    return [UIColor colorWithRed:0.05 green:0.42 blue:0.78 alpha:1.0];
}

static UIButton *PMMediaButton(NSString *title, SEL action, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 13.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = PMMediaAccentColor().CGColor;
    button.backgroundColor = [PMMediaAccentColor() colorWithAlphaComponent:0.12];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:PMMediaAccentColor() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(10.0, 12.0, 10.0, 12.0);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:42.0].active = YES;
    return button;
}

static UILabel *PMEarthLabel(NSString *text, CGFloat size, UIFontWeight weight) {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont monospacedSystemFontOfSize:size weight:weight];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    return label;
}

#pragma mark - Earth location and network diagnostics

@interface PMEarthViewController () <CLLocationManagerDelegate, MKMapViewDelegate>
@property (nonatomic, strong) UIImageView *earthView;
@property (nonatomic, strong) UILabel *connectionLabel;
@property (nonatomic, strong) UILabel *latencyLabel;
@property (nonatomic, strong) UILabel *endpointLabel;
@property (nonatomic, strong) UILabel *tierLabel;
@property (nonatomic, strong) UILabel *locationLabel;
@property (nonatomic, strong) UILabel *rateTargetLabel;
@property (nonatomic, strong) UILabel *rateRuntimeLabel;
@property (nonatomic, strong) MKMapView *deviceMapView;
@property (nonatomic, strong) UIView *mapFallbackView;
@property (nonatomic, strong) UILabel *mapFallbackLabel;
@property (nonatomic) BOOL mapTilesLoaded;
@property (nonatomic, strong) NSTimer *mapLoadTimeoutTimer;
@property (nonatomic, strong) UILabel *mapStatusLabel;
@property (nonatomic, strong) UILabel *mapDetailsLabel;
@property (nonatomic, strong) MKCircle *accuracyCircle;
@property (nonatomic, strong) CLLocation *lastCenteredLocation;
@property (nonatomic) BOOL mapCenteredOnFix;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) NSTimer *locationFallbackTimer;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSTimer *rateTimer;
@property (nonatomic, strong) NSURLSessionDataTask *probeTask;
@property (nonatomic, strong) nw_path_monitor_t pathMonitor;
@property (nonatomic, strong) dispatch_queue_t pathQueue;
@property (nonatomic, copy) NSArray<NSString *> *probeEndpoints;
@property (nonatomic) BOOL probeInProgress;
@property (nonatomic) BOOL locationRequested;
@property (nonatomic) BOOL locationUpdatesActive;
@property (nonatomic) BOOL singleLocationRequestActive;
@property (nonatomic) BOOL preciseLocationRequestActive;
@property (nonatomic) BOOL pageActive;
@property (nonatomic) CLLocation *lastLocation;
@end

@implementation PMEarthViewController

- (void)setupContent {
    [super setupContent];
    self.title = @"Trái đất";
    [self addHeaderWithEyebrow:@"EARTH POSITION & NETWORK" title:@"Trái đất · Vị trí & kết nối" subtitle:@"Mô phỏng quả địa cầu, hiển thị vị trí iPhone khi được cấp quyền và đo phản hồi mạng hiện tại."];

    UIStackView *earthCard = [self newCardWithTitle:@"BẢN ĐỒ TRÁI ĐẤT MÔ PHỎNG" subtitle:@"Hình ảnh địa cầu minh họa; vị trí GPS được hiển thị bằng tọa độ riêng bên dưới."];
    UIView *globeStage = [UIView new];
    globeStage.translatesAutoresizingMaskIntoConstraints = NO;
    [earthCard addArrangedSubview:globeStage];
    [globeStage.heightAnchor constraintEqualToConstant:238.0].active = YES;

    UIView *orbitRing = [UIView new];
    orbitRing.translatesAutoresizingMaskIntoConstraints = NO;
    orbitRing.userInteractionEnabled = NO;
    orbitRing.layer.cornerRadius = 108.0;
    orbitRing.layer.borderWidth = 1.0;
    orbitRing.layer.borderColor = [PMMediaAccentColor() colorWithAlphaComponent:0.42].CGColor;
    [globeStage addSubview:orbitRing];
    [NSLayoutConstraint activateConstraints:@[
        [orbitRing.widthAnchor constraintEqualToConstant:216.0],
        [orbitRing.heightAnchor constraintEqualToConstant:216.0],
        [orbitRing.centerXAnchor constraintEqualToAnchor:globeStage.centerXAnchor],
        [orbitRing.centerYAnchor constraintEqualToAnchor:globeStage.centerYAnchor]
    ]];

    UIImage *earthImage = [UIImage imageNamed:@"EarthGlobe"];
    if (!earthImage) earthImage = [UIImage systemImageNamed:@"globe.americas.fill"] ?: [UIImage systemImageNamed:@"globe"];
    self.earthView = [[UIImageView alloc] initWithImage:earthImage];
    self.earthView.translatesAutoresizingMaskIntoConstraints = NO;
    self.earthView.contentMode = UIViewContentModeScaleAspectFill;
    self.earthView.clipsToBounds = YES;
    self.earthView.layer.cornerRadius = 102.0;
    self.earthView.layer.borderWidth = 1.0;
    self.earthView.layer.borderColor = [PMMediaAccentColor() colorWithAlphaComponent:0.7].CGColor;
    self.earthView.layer.shadowColor = PMMediaAccentColor().CGColor;
    self.earthView.layer.shadowOpacity = 0.24;
    self.earthView.layer.shadowRadius = 14.0;
    [globeStage addSubview:self.earthView];
    [NSLayoutConstraint activateConstraints:@[
        [self.earthView.widthAnchor constraintEqualToConstant:204.0],
        [self.earthView.heightAnchor constraintEqualToConstant:204.0],
        [self.earthView.centerXAnchor constraintEqualToAnchor:globeStage.centerXAnchor],
        [self.earthView.centerYAnchor constraintEqualToAnchor:globeStage.centerYAnchor]
    ]];

    UIView *locationBar = [UIView new];
    locationBar.translatesAutoresizingMaskIntoConstraints = NO;
    locationBar.backgroundColor = [PMMediaAccentColor() colorWithAlphaComponent:0.10];
    locationBar.layer.cornerRadius = 13.0;
    locationBar.layer.borderWidth = 1.0;
    locationBar.layer.borderColor = [PMMediaAccentColor() colorWithAlphaComponent:0.55].CGColor;
    UIStackView *locationContent = [[UIStackView alloc] initWithFrame:CGRectZero];
    locationContent.translatesAutoresizingMaskIntoConstraints = NO;
    locationContent.axis = UILayoutConstraintAxisHorizontal;
    locationContent.alignment = UIStackViewAlignmentCenter;
    locationContent.spacing = 9.0;
    UIImageView *locationGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"location.fill"]];
    locationGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    locationGlyph.tintColor = PMMediaAccentColor();
    locationGlyph.contentMode = UIViewContentModeScaleAspectFit;
    [locationGlyph.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [locationGlyph.heightAnchor constraintEqualToConstant:18.0].active = YES;
    self.locationLabel = PMEarthLabel(@"iPhone của bạn: chưa xác định vị trí", 12.0, UIFontWeightSemibold);
    self.locationLabel.numberOfLines = 1;
    [locationContent addArrangedSubview:locationGlyph];
    [locationContent addArrangedSubview:self.locationLabel];
    [locationBar addSubview:locationContent];
    [NSLayoutConstraint activateConstraints:@[
        [locationContent.leadingAnchor constraintEqualToAnchor:locationBar.leadingAnchor constant:12.0],
        [locationContent.trailingAnchor constraintEqualToAnchor:locationBar.trailingAnchor constant:-12.0],
        [locationContent.topAnchor constraintEqualToAnchor:locationBar.topAnchor constant:9.0],
        [locationContent.bottomAnchor constraintEqualToAnchor:locationBar.bottomAnchor constant:-9.0],
        [locationBar.heightAnchor constraintGreaterThanOrEqualToConstant:42.0]
    ]];
    self.connectionLabel = PMEarthLabel(@"Trạng thái mạng: đang kiểm tra…", 13.0, UIFontWeightSemibold);
    self.latencyLabel = PMEarthLabel(@"Độ trễ HTTPS: chưa đo", 16.0, UIFontWeightBold);
    self.endpointLabel = PMEarthLabel(@"Máy chủ kiểm tra: —", 12.0, UIFontWeightMedium);
    self.tierLabel = PMEarthLabel(@"SERVER: —", 12.0, UIFontWeightMedium);
    self.rateTargetLabel = PMEarthLabel(@"Mục tiêu đã chọn: —", 13.0, UIFontWeightSemibold);
    self.rateRuntimeLabel = PMEarthLabel(@"Giới hạn màn hình / FPS callback: —", 12.0, UIFontWeightMedium);
    [earthCard addArrangedSubview:locationBar];
    [earthCard addArrangedSubview:self.connectionLabel];
    [earthCard addArrangedSubview:self.latencyLabel];
    [earthCard addArrangedSubview:self.endpointLabel];
    [earthCard addArrangedSubview:self.tierLabel];
    [earthCard addArrangedSubview:self.rateTargetLabel];
    [earthCard addArrangedSubview:self.rateRuntimeLabel];

    UIStackView *deviceMapCard = [self newCardWithTitle:@"BẢN ĐỒ VỊ TRÍ CHÍNH XÁC CỦA IPHONE" subtitle:@"Bản đồ chỉ hiển thị tọa độ GPS thật của chính iPhone này. Không dùng vị trí ước lượng theo IP và không gửi tọa độ tới máy chủ nào."];
    self.mapStatusLabel = PMEarthLabel(@"GPS: chưa có tọa độ", 13.0, UIFontWeightSemibold);
    self.mapDetailsLabel = PMEarthLabel(@"Cấp quyền Vị trí khi dùng để bản đồ căn đúng vị trí iPhone và hiển thị vòng sai số GPS.", 12.0, UIFontWeightMedium);
    self.mapDetailsLabel.textColor = UIColor.secondaryLabelColor;
    self.deviceMapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.deviceMapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.deviceMapView.delegate = self;
    self.deviceMapView.mapType = MKMapTypeStandard;
    self.deviceMapView.showsCompass = YES;
    self.deviceMapView.showsScale = YES;
    self.deviceMapView.showsTraffic = NO;
    self.deviceMapView.showsBuildings = YES;
    self.deviceMapView.showsUserLocation = YES;
    self.deviceMapView.userTrackingMode = MKUserTrackingModeNone;
    self.deviceMapView.layer.cornerRadius = 15.0;
    self.deviceMapView.layer.borderWidth = 1.0;
    self.deviceMapView.layer.borderColor = [PMMediaAccentColor() colorWithAlphaComponent:0.5].CGColor;
    self.deviceMapView.clipsToBounds = YES;
    [self applyDeviceMapDefaultRegion];

    // The map sits on a stage together with an offline globe fallback. If Apple's
    // tile service does not render (no network, MapKit unavailable), the fallback
    // image is shown instead of an empty gray rectangle.
    UIView *mapStage = [UIView new];
    mapStage.translatesAutoresizingMaskIntoConstraints = NO;
    [mapStage.heightAnchor constraintEqualToConstant:260.0].active = YES;
    [mapStage addSubview:self.deviceMapView];
    [NSLayoutConstraint activateConstraints:@[
        [self.deviceMapView.topAnchor constraintEqualToAnchor:mapStage.topAnchor],
        [self.deviceMapView.leadingAnchor constraintEqualToAnchor:mapStage.leadingAnchor],
        [self.deviceMapView.trailingAnchor constraintEqualToAnchor:mapStage.trailingAnchor],
        [self.deviceMapView.bottomAnchor constraintEqualToAnchor:mapStage.bottomAnchor]
    ]];

    self.mapFallbackView = [UIView new];
    self.mapFallbackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapFallbackView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.mapFallbackView.layer.cornerRadius = 15.0;
    self.mapFallbackView.layer.borderWidth = 1.0;
    self.mapFallbackView.layer.borderColor = [PMMediaAccentColor() colorWithAlphaComponent:0.5].CGColor;
    self.mapFallbackView.clipsToBounds = YES;
    self.mapFallbackView.hidden = YES;
    UIImage *fallbackEarth = [UIImage imageNamed:@"EarthGlobe"] ?: [UIImage systemImageNamed:@"globe.americas.fill"];
    UIImageView *fallbackImage = [[UIImageView alloc] initWithImage:fallbackEarth];
    fallbackImage.translatesAutoresizingMaskIntoConstraints = NO;
    fallbackImage.contentMode = UIViewContentModeScaleAspectFill;
    fallbackImage.layer.cornerRadius = 74.0;
    fallbackImage.clipsToBounds = YES;
    [self.mapFallbackView addSubview:fallbackImage];
    self.mapFallbackLabel = PMEarthLabel(@"Bản đồ nền Apple chưa tải được · đang hiển thị địa cầu dự phòng", 11.0, UIFontWeightMedium);
    self.mapFallbackLabel.numberOfLines = 2;
    self.mapFallbackLabel.textAlignment = NSTextAlignmentCenter;
    self.mapFallbackLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.mapFallbackView addSubview:self.mapFallbackLabel];
    [NSLayoutConstraint activateConstraints:@[
        [fallbackImage.widthAnchor constraintEqualToConstant:148.0],
        [fallbackImage.heightAnchor constraintEqualToConstant:148.0],
        [fallbackImage.centerXAnchor constraintEqualToAnchor:self.mapFallbackView.centerXAnchor],
        [fallbackImage.centerYAnchor constraintEqualToAnchor:self.mapFallbackView.centerYAnchor constant:-14.0],
        [self.mapFallbackLabel.leadingAnchor constraintEqualToAnchor:self.mapFallbackView.leadingAnchor constant:12.0],
        [self.mapFallbackLabel.trailingAnchor constraintEqualToAnchor:self.mapFallbackView.trailingAnchor constant:-12.0],
        [self.mapFallbackLabel.bottomAnchor constraintEqualToAnchor:self.mapFallbackView.bottomAnchor constant:-10.0]
    ]];
    [mapStage addSubview:self.mapFallbackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.mapFallbackView.topAnchor constraintEqualToAnchor:mapStage.topAnchor],
        [self.mapFallbackView.leadingAnchor constraintEqualToAnchor:mapStage.leadingAnchor],
        [self.mapFallbackView.trailingAnchor constraintEqualToAnchor:mapStage.trailingAnchor],
        [self.mapFallbackView.bottomAnchor constraintEqualToAnchor:mapStage.bottomAnchor]
    ]];
    [deviceMapCard addArrangedSubview:self.mapStatusLabel];
    [deviceMapCard addArrangedSubview:mapStage];
    [deviceMapCard addArrangedSubview:self.mapDetailsLabel];
    [deviceMapCard addArrangedSubview:PMMediaButton(@"Căn giữa vị trí iPhone", @selector(recenterDeviceMap), self)];

    UIStackView *actions = [self newCardWithTitle:@"ĐỊNH VỊ VÀ KIỂM TRA" subtitle:@"Vị trí GPS chỉ được đọc sau khi bạn cấp quyền iOS và chỉ dùng để vẽ bản đồ trong ứng dụng."];
    [actions addArrangedSubview:PMMediaButton(@"Cập nhật vị trí iPhone (GPS)", @selector(requestDeviceLocation), self)];
    [actions addArrangedSubview:PMMediaButton(@"Đo độ trễ mạng / Apple", @selector(runEarthProbe), self)];
    [actions addArrangedSubview:PMMediaButton(@"Mở Cloudflare 1.1.1.1 / WARP", @selector(openCloudflareOne), self)];
    [self addNote:@"Bản đồ chỉ vẽ tọa độ GPS do Core Location của iPhone trả về khi bạn đã cấp quyền Vị trí khi dùng. Không có bước tra cứu IP, không có ghim vị trí ước lượng và tọa độ không được gửi tới bất kỳ máy chủ nào của ứng dụng. Vòng tròn quanh điểm xanh là sai số GPS báo cáo bởi iOS: ngoài trời thường vài mét, trong nhà có thể vài chục mét. Bản đồ nền do MapKit tải từ Apple. GPS không tự giảm ping và không điều khiển vệ tinh hoặc máy chủ Apple. Ứng dụng chỉ kiểm tra phản hồi HTTPS công khai của Apple/Cloudflare và một số endpoint kết nối; không thể can thiệp tuyến mạng, modem, nhà mạng hay vệ tinh để tăng tốc toàn hệ thống. Ba server là ba profile lựa chọn loại trừ lẫn nhau: chỉ profile đang chọn được chạy, theo đúng công tắc của profile đó. Khi ứng dụng ra nền hoặc bị đóng, iOS có thể tạm dừng/kết thúc tiến trình; không có chế độ refresh liên tục sau force-quit." toStack:self.contentStack];

    self.probeEndpoints = @[
        @"https://1.1.1.1/cdn-cgi/trace",
        @"https://www.cloudflare.com/cdn-cgi/trace",
        @"https://www.google.com/generate_204",
        @"https://connectivitycheck.gstatic.com/generate_204",
        @"https://www.apple.com/library/test/success.html",
        @"https://captive.apple.com/hotspot-detect.html"
    ];
    self.locationManager = [CLLocationManager new];
    self.locationManager.delegate = self;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    self.locationManager.distanceFilter = kCLDistanceFilterNone;
    self.locationManager.activityType = CLActivityTypeOther;
    self.locationManager.pausesLocationUpdatesAutomatically = NO;
    self.locationManager.showsBackgroundLocationIndicator = NO;

    self.pathQueue = dispatch_queue_create("com.dell.promotioncontrol.earth-path", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(earthApplicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(earthApplicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(earthSystemPolicyChanged:) name:NSProcessInfoThermalStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(earthSystemPolicyChanged:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    [self updateSelectedTierAndRates];
    [self updateLocationAuthorizationLabel];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.pageActive = YES;
    [self startEarthUpdates];
    [self startMapLoadWatchdog];
    [self updateSelectedTierAndRates];
    [self updateLocationAuthorizationLabel];
    CLAuthorizationStatus authorization = CLLocationManager.authorizationStatus;
    if (authorization == kCLAuthorizationStatusNotDetermined) {
        self.locationRequested = YES;
        [self.locationManager requestWhenInUseAuthorization];
    } else if (authorization == kCLAuthorizationStatusAuthorizedWhenInUse || authorization == kCLAuthorizationStatusAuthorizedAlways) {
        self.locationRequested = YES;
        self.deviceMapView.showsUserLocation = YES;
        [self startForegroundLocationUpdates];
        self.locationLabel.text = @"iPhone của bạn: đang xác định vị trí…";
        if (!self.lastLocation) self.mapStatusLabel.text = @"GPS: đang xác định vị trí…";
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self runEarthProbe];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.pageActive = NO;
    [self.mapLoadTimeoutTimer invalidate];
    self.mapLoadTimeoutTimer = nil;
    [self stopEarthUpdates];
    [self stopForegroundLocationUpdates];
    self.locationRequested = NO;
    [super viewWillDisappear:animated];
}

- (void)startForegroundLocationUpdates {
    if (!self.pageActive || !self.locationRequested || ![CLLocationManager locationServicesEnabled]) return;
    CLAuthorizationStatus authorization = CLLocationManager.authorizationStatus;
    if (authorization != kCLAuthorizationStatusAuthorizedWhenInUse && authorization != kCLAuthorizationStatusAuthorizedAlways) return;
    self.deviceMapView.showsUserLocation = YES;
    if (!self.locationUpdatesActive && !self.singleLocationRequestActive) {
        [self.locationManager startUpdatingLocation];
        self.locationUpdatesActive = YES;
        self.mapStatusLabel.text = self.lastLocation ? self.mapStatusLabel.text : @"GPS: đang chờ tín hiệu từ vệ tinh…";
        [self.locationFallbackTimer invalidate];
        if (!self.lastLocation) {
            self.locationFallbackTimer = [NSTimer timerWithTimeInterval:12.0
                target:self selector:@selector(requestOneShotLocationFallback) userInfo:nil repeats:NO];
            [NSRunLoop.mainRunLoop addTimer:self.locationFallbackTimer forMode:NSRunLoopCommonModes];
        }
    }
}

- (void)requestOneShotLocationFallback {
    self.locationFallbackTimer = nil;
    if (!self.pageActive || !self.locationRequested || self.lastLocation || self.singleLocationRequestActive ||
        ![CLLocationManager locationServicesEnabled]) return;
    CLAuthorizationStatus authorization = CLLocationManager.authorizationStatus;
    if (authorization != kCLAuthorizationStatusAuthorizedWhenInUse && authorization != kCLAuthorizationStatusAuthorizedAlways) return;
    // A one-shot request kicks Core Location again if continuous updates were
    // started before iOS finished preparing the GPS provider.
    [self.locationManager stopUpdatingLocation];
    self.locationUpdatesActive = NO;
    self.singleLocationRequestActive = YES;
    self.mapStatusLabel.text = @"GPS: đang yêu cầu tọa độ trực tiếp…";
    [self.locationManager requestLocation];
}

- (void)stopForegroundLocationUpdates {
    [self.locationFallbackTimer invalidate];
    self.locationFallbackTimer = nil;
    if (self.locationUpdatesActive) [self.locationManager stopUpdatingLocation];
    self.locationUpdatesActive = NO;
    self.singleLocationRequestActive = NO;
}

- (void)earthApplicationDidEnterBackground:(NSNotification *)note {
    (void)note;
    self.pageActive = NO;
    [self stopEarthUpdates];
    [self stopForegroundLocationUpdates];
}

- (void)earthApplicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    BOOL visible = self.isViewLoaded && self.view.window &&
        self.navigationController.topViewController == self &&
        self.tabBarController.selectedViewController == self.navigationController;
    if (!visible) return;
    self.pageActive = YES;
    [self startEarthUpdates];
    if (self.locationRequested) [self startForegroundLocationUpdates];
    [self runEarthProbe];
}

- (void)earthSystemPolicyChanged:(NSNotification *)note {
    (void)note;
    if (!self.pageActive) return;
    [self updateEarthRefreshPolicy];
}

- (void)startEarthUpdates {
    [self startPathMonitor];
    if (self.earthView.layer.animationKeys.count == 0) {
        CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotation.fromValue = @0.0;
        rotation.toValue = @(M_PI * 2.0);
        rotation.duration = 36.0;
        rotation.repeatCount = HUGE_VALF;
        rotation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [self.earthView.layer addAnimation:rotation forKey:@"pm.earth.continuousRotation"];
    }
    [self updateEarthRefreshPolicy];
}

- (void)updateEarthRefreshPolicy {
    if (!self.pageActive) return;
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    NSProcessInfoThermalState thermal = NSProcessInfoThermalStateNominal;
    if (@available(iOS 11.0, *)) thermal = processInfo.thermalState;

    // Refresh network diagnostics only while foregrounded, with a longer
    // interval under heat/Low Power Mode and no automatic probes at Critical.
    NSTimeInterval probeInterval = 20.0;
    NSTimeInterval statusInterval = 3.0;
    if (processInfo.isLowPowerModeEnabled || thermal == NSProcessInfoThermalStateFair) {
        probeInterval = 45.0;
        statusInterval = 5.0;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
        self.locationManager.distanceFilter = 20.0;
        [self startForegroundLocationUpdates];
    } else if (thermal == NSProcessInfoThermalStateSerious) {
        probeInterval = 90.0;
        statusInterval = 8.0;
        [self stopForegroundLocationUpdates];
    } else if (thermal == NSProcessInfoThermalStateCritical) {
        probeInterval = 0.0;
        statusInterval = 12.0;
        [self stopForegroundLocationUpdates];
    } else {
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
        self.locationManager.distanceFilter = 10.0;
        [self startForegroundLocationUpdates];
    }

    NSTimeInterval currentProbe = self.refreshTimer ? self.refreshTimer.timeInterval : -1.0;
    if (fabs(currentProbe - probeInterval) > 0.5) {
        [self.refreshTimer invalidate];
        self.refreshTimer = nil;
        if (probeInterval > 0.0) {
            self.refreshTimer = [NSTimer timerWithTimeInterval:probeInterval
                target:self selector:@selector(runEarthProbe) userInfo:nil repeats:YES];
            self.refreshTimer.tolerance = MIN(5.0, probeInterval * 0.15);
            [NSRunLoop.mainRunLoop addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
        }
    }

    NSTimeInterval currentStatus = self.rateTimer ? self.rateTimer.timeInterval : -1.0;
    if (fabs(currentStatus - statusInterval) > 0.5) {
        [self.rateTimer invalidate];
        self.rateTimer = [NSTimer timerWithTimeInterval:statusInterval
            target:self selector:@selector(refreshEarthStatus) userInfo:nil repeats:YES];
        self.rateTimer.tolerance = MIN(2.0, statusInterval * 0.15);
        [NSRunLoop.mainRunLoop addTimer:self.rateTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)refreshEarthStatus {
    if (!self.pageActive) return;
    [self updateSelectedTierAndRates];
    [self updateEarthRefreshPolicy];
}

- (void)stopEarthUpdates {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.rateTimer invalidate];
    self.rateTimer = nil;
    [self.probeTask cancel];
    self.probeTask = nil;
    self.probeInProgress = NO;
    [self.earthView.layer removeAnimationForKey:@"pm.earth.continuousRotation"];
    [self stopPathMonitor];
}

- (void)startPathMonitor {
    if (self.pathMonitor) return;
    self.pathMonitor = nw_path_monitor_create();
    if (!self.pathMonitor) return;
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(self.pathMonitor, ^(nw_path_t path) {
        nw_path_status_t pathStatus = nw_path_get_status(path);
        NSString *status = pathStatus == nw_path_status_satisfied ? @"Đã kết nối" :
            (pathStatus == nw_path_status_satisfiable ? @"Có thể kết nối" : @"Mất kết nối");
        NSString *interface = nw_path_uses_interface_type(path, nw_interface_type_wifi) ? @"Wi‑Fi" :
            (nw_path_uses_interface_type(path, nw_interface_type_cellular) ? @"Di động" :
             (nw_path_uses_interface_type(path, nw_interface_type_wired) ? @"Ethernet" : @"Khác"));
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self && self.pageActive && self.isViewLoaded) {
                self.connectionLabel.text = [NSString stringWithFormat:@"Trạng thái mạng: %@ · %@", status, interface];
            }
        });
    });
    nw_path_monitor_set_queue(self.pathMonitor, self.pathQueue);
    nw_path_monitor_start(self.pathMonitor);
}

- (void)stopPathMonitor {
    if (!self.pathMonitor) return;
    nw_path_monitor_cancel(self.pathMonitor);
    self.pathMonitor = nil;
}

- (void)applyDeviceMapDefaultRegion {
    CLLocationCoordinate2D center = CLLocationCoordinate2DMake(16.047079, 108.206230);
    double span = 9.0;
    if (self.lastLocation) {
        center = self.lastLocation.coordinate;
        span = 0.01;
    }
    MKCoordinateRegion region = MKCoordinateRegionMake(center, MKCoordinateSpanMake(span, span));
    [self.deviceMapView setRegion:[self.deviceMapView regionThatFits:region] animated:NO];
}

- (void)centerDeviceMapOnLocation:(CLLocation *)location animated:(BOOL)animated {
    if (!self.deviceMapView || ![location isKindOfClass:[CLLocation class]]) return;
    // Street-level span derived from the reported GPS accuracy, clamped so a
    // single bad fix cannot zoom the map to the whole country.
    CLLocationDistance span = MAX(250.0, MIN(1500.0, location.horizontalAccuracy * 6.0));
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(location.coordinate, span, span);
    [self.deviceMapView setRegion:[self.deviceMapView regionThatFits:region] animated:animated];
}

- (void)recenterDeviceMap {
    if (!self.pageActive) return;
    CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        [self requestDeviceLocation];
        return;
    }
    self.locationRequested = YES;
    [self startForegroundLocationUpdates];
    [self requestPreciseLocationIfNeeded];
    if (self.lastLocation) {
        [self centerDeviceMapOnLocation:self.lastLocation animated:YES];
        self.lastCenteredLocation = self.lastLocation;
        self.mapCenteredOnFix = YES;
    } else {
        self.mapStatusLabel.text = @"GPS: đang chờ tín hiệu định vị…";
        self.mapDetailsLabel.text = @"Giữ iPhone ở nơi thoáng để nhận tọa độ GPS chính xác.";
        [self requestOneShotLocationFallback];
    }
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    (void)mapView;
    (void)annotation;
    // Only the system user-location dot and the accuracy overlay are drawn, so
    // MapKit's default blue marker is kept and no custom pin is ever added.
    return nil;
}

- (void)mapView:(MKMapView *)mapView didUpdateUserLocation:(MKUserLocation *)userLocation {
    (void)mapView;
    if (!userLocation.location) return;
    // MapKit has its own Core Location pipeline. Feed its real device fix through
    // the same validator so the map still gets a fix if the other callback lags.
    [self locationManager:self.locationManager didUpdateLocations:@[userLocation.location]];
}

- (void)mapView:(MKMapView *)mapView didFailToLocateUserWithError:(NSError *)error {
    (void)mapView;
    if (error.code == kCLErrorLocationUnknown) {
        self.mapStatusLabel.text = @"GPS: chưa khóa được vệ tinh, đang thử lại…";
        return;
    }
    self.mapStatusLabel.text = [NSString stringWithFormat:@"GPS: %@ · nhấn Cập nhật vị trí để thử lại", error.localizedDescription ?: @"không xác định được vị trí"];
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    (void)mapView;
    if ([overlay isKindOfClass:[MKCircle class]]) {
        MKCircleRenderer *renderer = [[MKCircleRenderer alloc] initWithCircle:(MKCircle *)overlay];
        renderer.fillColor = [PMMediaAccentColor() colorWithAlphaComponent:0.14];
        renderer.strokeColor = [PMMediaAccentColor() colorWithAlphaComponent:0.7];
        renderer.lineWidth = 1.0;
        return renderer;
    }
    return nil;
}

- (void)mapViewDidFinishLoadingMap:(MKMapView *)mapView {
    (void)mapView;
    self.mapTilesLoaded = YES;
    [self.mapLoadTimeoutTimer invalidate];
    self.mapLoadTimeoutTimer = nil;
    self.mapFallbackView.hidden = YES;
}

- (void)mapViewDidFailLoadingMapView:(MKMapView *)mapView withError:(NSError *)error API_AVAILABLE(ios(13.0)) {
    (void)mapView;
    self.mapDetailsLabel.text = [NSString stringWithFormat:@"Không tải được ảnh bản đồ Apple (%@). Đang hiển thị địa cầu dự phòng; tọa độ GPS vẫn chính xác.", error.localizedDescription ?: @"lỗi MapKit"];
    [self showMapFallbackWithReason:@"Bản đồ nền Apple chưa tải được · đang hiển thị địa cầu dự phòng"];
}

- (void)showMapFallbackWithReason:(NSString *)reason {
    self.mapFallbackLabel.text = reason;
    self.mapFallbackView.hidden = NO;
}

- (void)startMapLoadWatchdog {
    [self.mapLoadTimeoutTimer invalidate];
    self.mapLoadTimeoutTimer = nil;
    if (self.mapTilesLoaded) return;
    self.mapLoadTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:6.0
                                                               target:self
                                                             selector:@selector(mapLoadWatchdogFired:)
                                                             userInfo:nil
                                                              repeats:NO];
}

- (void)mapLoadWatchdogFired:(NSTimer *)timer {
    (void)timer;
    self.mapLoadTimeoutTimer = nil;
    if (self.mapTilesLoaded) return;
    [self showMapFallbackWithReason:@"Bản đồ nền Apple chưa tải được · đang hiển thị địa cầu dự phòng"];
}

- (void)requestPreciseLocationIfNeeded {
    if (self.preciseLocationRequestActive) return;
    if (@available(iOS 14.0, *)) {
        if (self.locationManager.accuracyAuthorization != CLAccuracyAuthorizationReducedAccuracy) return;
        self.preciseLocationRequestActive = YES;
        self.mapDetailsLabel.text = @"iOS đang dùng vị trí giảm độ chính xác; đang xin quyền GPS chính xác cho lần định vị này…";
        __weak typeof(self) weakSelf = self;
        [self.locationManager requestTemporaryFullAccuracyAuthorizationWithPurposeKey:@"ProMotionControlPreciseLocation" completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                self.preciseLocationRequestActive = NO;
                if (error) {
                    self.mapDetailsLabel.text = [NSString stringWithFormat:@"Không bật được GPS chính xác: %@ · bật Vị trí chính xác trong Cài đặt nếu cần.", error.localizedDescription];
                }
                [self startForegroundLocationUpdates];
            });
        }];
    }
}

- (void)requestDeviceLocation {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestDeviceLocation]; });
        return;
    }
    if (![CLLocationManager locationServicesEnabled]) {
        self.locationLabel.text = @"iPhone của bạn: dịch vụ Vị trí đang tắt";
        self.mapStatusLabel.text = @"GPS: bật Dịch vụ vị trí trong Cài đặt để định vị";
    }
    CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusNotDetermined) {
        self.locationRequested = YES;
        [self.locationManager requestWhenInUseAuthorization];
    } else if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        self.locationRequested = YES;
        self.deviceMapView.showsUserLocation = YES;
        [self startForegroundLocationUpdates];
        [self requestPreciseLocationIfNeeded];
        self.locationLabel.text = @"iPhone của bạn: đang xác định vị trí…";
        if (!self.lastLocation) {
            self.mapStatusLabel.text = @"GPS: đang yêu cầu tọa độ trực tiếp…";
            [self requestOneShotLocationFallback];
        }
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cần quyền vị trí" message:@"Bật quyền Vị trí khi dùng trong Cài đặt iOS để bản đồ hiển thị đúng tọa độ GPS của iPhone. Tọa độ chỉ dùng trong ứng dụng và không được gửi tới máy chủ đo mạng." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Mở Cài đặt" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            if (settingsURL && [UIApplication.sharedApplication canOpenURL:settingsURL]) [UIApplication.sharedApplication openURL:settingsURL options:@{} completionHandler:nil];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)updateLocationAuthorizationLabel {
    CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
    if (![CLLocationManager locationServicesEnabled]) {
        self.locationLabel.text = @"iPhone của bạn: dịch vụ Vị trí đang tắt";
        self.mapStatusLabel.text = @"GPS: bật Dịch vụ vị trí trong Cài đặt";
    } else if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.locationLabel.text = @"iPhone của bạn: quyền vị trí bị từ chối";
        self.mapStatusLabel.text = @"GPS: cần cấp quyền Vị trí khi dùng";
    } else if (status == kCLAuthorizationStatusNotDetermined) {
        self.locationLabel.text = @"iPhone của bạn: nhấn Cập nhật vị trí";
    } else if (!self.lastLocation) {
        self.locationLabel.text = @"iPhone của bạn: đã cấp quyền · đang chờ GPS";
        if (@available(iOS 14.0, *)) {
            if (self.locationManager.accuracyAuthorization == CLAccuracyAuthorizationReducedAccuracy) {
                self.mapDetailsLabel.text = @"Đã cấp quyền nhưng iOS đang giảm độ chính xác. Nhấn Cập nhật vị trí để xin GPS chính xác.";
            }
        }
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    [self updateLocationAuthorizationLabel];
    CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
        // The delegate can receive the initial authorization callback before the
        // first button tap. Treat an authorized visible page as an active request.
        if (self.pageActive) self.locationRequested = YES;
        self.deviceMapView.showsUserLocation = YES;
        [self startForegroundLocationUpdates];
        if (self.pageActive && !self.lastLocation) [self requestOneShotLocationFallback];
    }
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.locationRequested = NO;
        [self stopForegroundLocationUpdates];
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    (void)manager;
    (void)status;
    [self locationManagerDidChangeAuthorization:self.locationManager];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    CLLocation *location = locations.lastObject;
    if (![location isKindOfClass:[CLLocation class]] || location.horizontalAccuracy < 0.0 ||
        !CLLocationCoordinate2DIsValid(location.coordinate)) {
        if (self.singleLocationRequestActive) {
            self.singleLocationRequestActive = NO;
            [self startForegroundLocationUpdates];
        }
        return;
    }
    // Ignore cached/previously stored fixes; only a fresh GPS reading may move
    // the map, otherwise the pin could show where the iPhone was hours ago.
    if (fabs([location.timestamp timeIntervalSinceNow]) > 60.0) {
        self.mapStatusLabel.text = @"GPS: tọa độ cũ, đang chờ tín hiệu mới…";
        if (self.singleLocationRequestActive) {
            self.singleLocationRequestActive = NO;
            [self startForegroundLocationUpdates];
        }
        return;
    }
    [self.locationFallbackTimer invalidate];
    self.locationFallbackTimer = nil;
    BOOL resumeContinuousUpdates = self.singleLocationRequestActive;
    self.singleLocationRequestActive = NO;
    self.lastLocation = location;
    NSString *latitudeText = [NSString stringWithFormat:@"%.6f° %@", fabs(location.coordinate.latitude),
        location.coordinate.latitude >= 0.0 ? @"Bắc" : @"Nam"];
    NSString *longitudeText = [NSString stringWithFormat:@"%.6f° %@", fabs(location.coordinate.longitude),
        location.coordinate.longitude >= 0.0 ? @"Đông" : @"Tây"];
    self.locationLabel.text = [NSString stringWithFormat:@"iPhone: %@, %@ · ±%.0f m", latitudeText, longitudeText, location.horizontalAccuracy];
    self.mapStatusLabel.text = [NSString stringWithFormat:@"GPS: %@, %@ · sai số ±%.0f m", latitudeText, longitudeText, location.horizontalAccuracy];
    if (!self.mapFallbackView.hidden) {
        self.mapFallbackLabel.text = [NSString stringWithFormat:@"Bản đồ nền chưa tải được · GPS: %@, %@", latitudeText, longitudeText];
    }

    NSString *source = location.speed >= 0.0
        ? [NSString stringWithFormat:@"tốc độ %.0f km/h", location.speed * 3.6]
        : @"tốc độ không xác định";
    self.mapDetailsLabel.text = [NSString stringWithFormat:@"Nguồn: GPS/Core Location của iPhone · %@ · độ cao %.0f m · vòng tròn là sai số GPS", source, location.altitude];

    if (self.accuracyCircle) [self.deviceMapView removeOverlay:self.accuracyCircle];
    MKCircle *circle = [MKCircle circleWithCenterCoordinate:location.coordinate
                                                     radius:MAX(8.0, location.horizontalAccuracy)];
    self.accuracyCircle = circle;
    [self.deviceMapView addOverlay:circle];

    // Center on the first fix, then only re-center after real movement so the
    // user can pan/zoom freely while standing still.
    if (!self.mapCenteredOnFix || !self.lastCenteredLocation ||
        [self.lastCenteredLocation distanceFromLocation:location] > 25.0) {
        [self centerDeviceMapOnLocation:location animated:self.mapCenteredOnFix];
        self.lastCenteredLocation = location;
        self.mapCenteredOnFix = YES;
    }
    if (resumeContinuousUpdates) [self startForegroundLocationUpdates];
    // Keep this one location bar fresh while the Earth page is visible; updates stop on page/app background.
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)manager;
    BOOL wasSingleRequest = self.singleLocationRequestActive;
    self.singleLocationRequestActive = NO;
    if (error.code == kCLErrorLocationUnknown) {
        self.mapStatusLabel.text = @"GPS: chưa khóa được vệ tinh, đang thử lại…";
        self.mapDetailsLabel.text = @"Ra nơi thoáng, bật Vị trí chính xác và giữ yên iPhone trong vài giây.";
        if (wasSingleRequest && self.locationRequested) [self startForegroundLocationUpdates];
        return;
    }
    self.locationLabel.text = [NSString stringWithFormat:@"iPhone của bạn: %@", error.localizedDescription ?: @"không xác định được"];
    self.mapStatusLabel.text = [NSString stringWithFormat:@"GPS: %@", error.localizedDescription ?: @"không xác định được vị trí"];
    if (error.code == kCLErrorDenied) {
        self.locationRequested = NO;
        [self stopForegroundLocationUpdates];
    } else if (wasSingleRequest && self.locationRequested) {
        [self startForegroundLocationUpdates];
    }
}

- (NSDictionary *)selectedServerPreferences {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.dell.promotioncontrol.plist"] ?: @{};
    NSInteger mode = [root[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)] ? MIN(MAX([root[@"ActiveServerMode"] integerValue], 0), 2) : 0;
    NSString *profileName = mode == 2 ? @"ADMIN" : (mode == 1 ? @"PREMIUM" : @"FREE");
    NSDictionary *profiles = [root[@"ServerProfiles"] isKindOfClass:[NSDictionary class]] ? root[@"ServerProfiles"] : @{};
    NSDictionary *profile = [profiles[profileName] isKindOfClass:[NSDictionary class]] ? profiles[profileName] : @{};
    NSMutableDictionary *merged = [root mutableCopy];
    [merged addEntriesFromDictionary:profile];
    merged[@"ActiveServerMode"] = @(mode);
    return [merged copy];
}

- (NSInteger)configuredRateForPreferences:(NSDictionary *)prefs modeKey:(NSString *)modeKey customKey:(NSString *)customKey enabledKey:(NSString *)enabledKey {
    if (![prefs[enabledKey] respondsToSelector:@selector(boolValue)] || ![prefs[enabledKey] boolValue]) return 0;
    NSInteger mode = [prefs[modeKey] respondsToSelector:@selector(integerValue)] ? [prefs[modeKey] integerValue] : 0;
    if (mode == -1) return [prefs[customKey] respondsToSelector:@selector(integerValue)] ? MIN(MAX([prefs[customKey] integerValue], 10), 244) : 60;
    return mode > 0 ? MIN(MAX(mode, 10), 244) : 0;
}

- (void)updateSelectedTierAndRates {
    NSDictionary *prefs = [self selectedServerPreferences];
    NSInteger mode = [prefs[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)] ? [prefs[@"ActiveServerMode"] integerValue] : 0;
    NSString *tier = mode == 2 ? @"ADMIN" : (mode == 1 ? @"PREMIUM" : @"FREE");
    BOOL masterEnabled = [prefs[@"Enabled"] respondsToSelector:@selector(boolValue)] && [prefs[@"Enabled"] boolValue];
    NSString *schedulerKey = mode == 2 ? @"AdminRenderSchedulerEnabled" : (mode == 1 ? @"PremiumRenderSchedulerEnabled" : @"FreeRenderSchedulerEnabled");
    NSString *hookKey = mode == 2 ? @"AdminCADisplayLinkHookEnabled" : (mode == 1 ? @"PremiumCADisplayLinkHookEnabled" : @"FreeCADisplayLinkHookEnabled");
    BOOL schedulerEnabled = !prefs[schedulerKey] || [prefs[schedulerKey] boolValue];
    BOOL hookEnabled = !prefs[hookKey] || [prefs[hookKey] boolValue];
    NSInteger hz = [self configuredRateForPreferences:prefs modeKey:@"RefreshMode" customKey:@"CustomRefreshRate" enabledKey:@"RefreshRateEnabled"];
    NSInteger fps = [self configuredRateForPreferences:prefs modeKey:@"FPSMode" customKey:@"CustomFPS" enabledKey:@"FPSOverrideEnabled"];
    BOOL framePacing = !prefs[@"FramePacing"] || [prefs[@"FramePacing"] boolValue];
    BOOL enforcement = !prefs[@"AdvancedDisplayEnforcement"] || [prefs[@"AdvancedDisplayEnforcement"] boolValue];
    BOOL runtimeEnabled = masterEnabled && schedulerEnabled && hookEnabled && framePacing && enforcement && (hz > 0 || fps > 0);
    self.tierLabel.text = [NSString stringWithFormat:@"SERVER đang chọn: %@ · %@", tier, runtimeEnabled ? @"CÔNG TẮC ĐANG BẬT" : @"ĐANG TẮT / CHƯA ĐỦ ĐIỀU KIỆN"];
    NSString *hzText = hz > 0 ? [NSString stringWithFormat:@"%ld Hz", (long)hz] : @"AUTO Hz";
    NSString *fpsText = fps > 0 ? [NSString stringWithFormat:@"%ld FPS", (long)fps] : @"AUTO FPS";
    self.rateTargetLabel.text = [NSString stringWithFormat:@"Mục tiêu đã chọn: %@ / %@", hzText, fpsText];
    NSInteger physicalMax = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    if (physicalMax <= 0) physicalMax = 60;
    CGFloat measured = [PMPerformanceMonitor sharedMonitor].measuredFramesPerSecond;
    NSString *measuredText = measured > 0.0 ? [NSString stringWithFormat:@"%.0f callback FPS", measured] : @"đang lấy mẫu callback";
    self.rateRuntimeLabel.text = [NSString stringWithFormat:@"Màn hình tối đa báo cáo: %ld Hz · %@", (long)physicalMax, measuredText];
}

- (void)runEarthProbe {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self runEarthProbe]; });
        return;
    }
    if (self.probeInProgress || self.probeEndpoints.count == 0 || !self.pageActive) return;
    self.probeInProgress = YES;
    [self.probeTask cancel];
    NSUInteger index = arc4random_uniform((uint32_t)self.probeEndpoints.count);
    NSString *endpoint = self.probeEndpoints[index];
    self.endpointLabel.text = [NSString stringWithFormat:@"Endpoint kiểm tra: %@", [NSURL URLWithString:endpoint].host ?: endpoint];
    self.latencyLabel.text = @"Độ trễ HTTPS: đang đo…";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:7.0];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    __weak typeof(self) weakSelf = self;
    self.probeTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSTimeInterval elapsed = (NSProcessInfo.processInfo.systemUptime - start) * 1000.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.probeInProgress = NO;
            self.probeTask = nil;
            if (!self.pageActive) return;
            if (error || ![response isKindOfClass:[NSHTTPURLResponse class]]) {
                self.latencyLabel.text = [NSString stringWithFormat:@"Độ trễ HTTPS: không đo được · %@", error.localizedDescription ?: @"không có phản hồi"];
            } else {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                self.latencyLabel.text = [NSString stringWithFormat:@"Độ trễ HTTPS: %.0f ms · HTTP %ld", elapsed, (long)status];
            }
        });
    }];
    [self.probeTask resume];
}

- (void)openCloudflareOne {
    NSURL *url = [NSURL URLWithString:@"https://one.one.one.one/"];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopEarthUpdates];
    [self stopForegroundLocationUpdates];
    self.locationManager.delegate = nil;
    [self stopPathMonitor];
}

@end

#pragma mark - Network information / latency

static NSDictionary *PMReadNetworkInterfaces(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || !interfaces) return @{};
    NSMutableDictionary<NSString *, NSMutableDictionary *> *records = [NSMutableDictionary dictionary];
    for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || !(cursor->ifa_flags & IFF_UP) || (cursor->ifa_flags & IFF_LOOPBACK)) continue;
        int family = cursor->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;
        NSString *name = [NSString stringWithUTF8String:cursor->ifa_name ?: ""];
        if (name.length == 0) continue;
        NSMutableDictionary *entry = records[name] ?: [NSMutableDictionary dictionary];
        char host[INET6_ADDRSTRLEN] = {0};
        const void *address = family == AF_INET
            ? (const void *)&((struct sockaddr_in *)cursor->ifa_addr)->sin_addr
            : (const void *)&((struct sockaddr_in6 *)cursor->ifa_addr)->sin6_addr;
        if (inet_ntop(family, address, host, sizeof(host))) {
            NSString *value = [NSString stringWithUTF8String:host];
            if (family == AF_INET) entry[@"IPv4"] = value;
            else entry[@"IPv6"] = value;
        }
        records[name] = entry;
    }
    freeifaddrs(interfaces);

    NSArray<NSString *> *priority = @[@"en0", @"en1", @"pdp_ip0", @"utun0", @"awdl0"];
    NSString *selectedName = nil;
    for (NSString *candidate in priority) {
        if (records[candidate].count > 0) { selectedName = candidate; break; }
    }
    if (!selectedName) selectedName = records.allKeys.firstObject;
    if (!selectedName) return @{};
    NSMutableDictionary *result = [records[selectedName] mutableCopy];
    result[@"Interface"] = selectedName;
    if ([selectedName hasPrefix:@"en"]) result[@"Kind"] = @"Wi‑Fi / Ethernet";
    else if ([selectedName hasPrefix:@"pdp"]) result[@"Kind"] = @"Mạng di động";
    else if ([selectedName hasPrefix:@"utun"]) result[@"Kind"] = @"VPN / Tunnel";
    else result[@"Kind"] = @"Mạng khác";
    return [result copy];
}

static NSString *PMReadCurrentWiFiSSID(void) {
    CFArrayRef supported = CNCopySupportedInterfaces();
    if (!supported) return nil;
    NSArray *interfaces = CFBridgingRelease(supported);
    for (id rawName in interfaces) {
        if (![rawName isKindOfClass:[NSString class]]) continue;
        CFDictionaryRef infoRef = CNCopyCurrentNetworkInfo((__bridge CFStringRef)rawName);
        if (!infoRef) continue;
        NSDictionary *info = CFBridgingRelease(infoRef);
        id ssid = info[(__bridge NSString *)kCNNetworkInfoKeySSID];
        if ([ssid isKindOfClass:[NSString class]] && [ssid length] > 0) return [ssid copy];
    }
    return nil;
}

@interface PMNetworkViewController () <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) UILabel *networkNameLabel;
@property (nonatomic, strong) UILabel *interfaceLabel;
@property (nonatomic, strong) UILabel *ipv4Label;
@property (nonatomic, strong) UILabel *ipv6Label;
@property (nonatomic, strong) UILabel *publicIPLabel;
@property (nonatomic, strong) UILabel *latencyLabel;
@property (nonatomic, strong) UILabel *updatedLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSURLSessionDataTask *latencyTask;
@property (nonatomic) BOOL refreshInProgress;
@property (nonatomic) BOOL locationPermissionRequested;
@end

@implementation PMNetworkViewController

- (void)setupContent {
    [super setupContent];
    self.title = @"Mạng";
    [self addHeaderWithEyebrow:@"NETWORK STATUS" title:@"Hệ thống mạng" subtitle:@"Thông tin kết nối hiện tại của iPhone, chỉ đọc tại thiết bị."];

    UIStackView *connectionCard = [self newCardWithTitle:@"KẾT NỐI ĐANG DÙNG" subtitle:@"Tên Wi‑Fi, giao diện mạng và địa chỉ IP nội bộ."];
    self.networkNameLabel = [self networkValueLabel:@"Đang kiểm tra tên mạng…"];
    self.interfaceLabel = [self networkValueLabel:@"Giao diện: —"];
    self.ipv4Label = [self networkValueLabel:@"IPv4: —"];
    self.ipv6Label = [self networkValueLabel:@"IPv6: —"];
    self.publicIPLabel = [self networkValueLabel:@"IP công khai: Chưa đo"];
    self.latencyLabel = [self networkValueLabel:@"Độ trễ HTTPS: Chưa đo"];
    self.updatedLabel = [self networkValueLabel:@"Chưa cập nhật"];
    for (UILabel *label in @[self.networkNameLabel, self.interfaceLabel, self.ipv4Label, self.ipv6Label, self.publicIPLabel, self.latencyLabel, self.updatedLabel]) {
        [connectionCard addArrangedSubview:label];
    }

    UIStackView *actions = [self newCardWithTitle:@"THAO TÁC" subtitle:@"Làm mới thông tin và kiểm tra độ trễ kết nối."];
    [actions addArrangedSubview:PMMediaButton(@"Làm mới mạng", @selector(refreshNetworkInfo), self)];
    [actions addArrangedSubview:PMMediaButton(@"Cho phép đọc tên Wi‑Fi", @selector(requestWiFiNamePermission), self)];
    [self addNote:@"iOS có thể ẩn SSID nếu chưa cấp quyền vị trí khi dùng hoặc thiếu quyền Access Wi‑Fi Information. Trang Mạng không dùng tọa độ; trang Trái đất chỉ đọc vị trí khi bạn chủ động nhấn nút Lấy vị trí thiết bị. IP nội bộ và tên Wi‑Fi chỉ hiển thị trên thiết bị; để lấy IP công khai và đo độ trễ, ứng dụng gửi một yêu cầu HTTPS tới 1.1.1.1 nên máy chủ đó có thể nhìn thấy IP công khai của kết nối. Độ trễ này không phải ICMP ping thuần." toStack:self.contentStack];
    self.locationManager = [CLLocationManager new];
    self.locationManager.delegate = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (UILabel *)networkValueLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    label.numberOfLines = 0;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    return label;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self startNetworkUpdates];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshNetworkInfo];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self stopNetworkUpdates];
    [super viewWillDisappear:animated];
}

- (void)startNetworkUpdates {
    if (self.refreshTimer) return;
    [self refreshNetworkInfo];
    self.refreshTimer = [NSTimer timerWithTimeInterval:20.0 target:self selector:@selector(refreshNetworkInfo) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)stopNetworkUpdates {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.latencyTask cancel];
    self.latencyTask = nil;
    self.refreshInProgress = NO;
}

- (void)applicationWillResignActive:(NSNotification *)note {
    (void)note;
    [self stopNetworkUpdates];
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isViewLoaded && self.view.window && self.tabBarController.selectedViewController == self.navigationController) {
            [self startNetworkUpdates];
            [self refreshNetworkInfo];
        }
    });
}

- (void)refreshNetworkInfo {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshNetworkInfo]; });
        return;
    }
    if (self.refreshInProgress || !self.isViewLoaded || !self.view.window) return;
    self.refreshInProgress = YES;
    CLAuthorizationStatus authorization = CLLocationManager.authorizationStatus;
    BOOL canReadSSID = (authorization == kCLAuthorizationStatusAuthorizedAlways || authorization == kCLAuthorizationStatusAuthorizedWhenInUse);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *interfaces = PMReadNetworkInterfaces();
        NSString *ssid = canReadSSID ? PMReadCurrentWiFiSSID() : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshInProgress = NO;
            if (!self.isViewLoaded || !self.view.window) return;
            NSString *kind = interfaces[@"Kind"] ?: @"Không xác định";
            NSString *name = interfaces[@"Interface"] ?: @"—";
            BOOL isWiFi = [name isEqualToString:@"en0"] || [name isEqualToString:@"en1"];
            NSString *networkName = ssid.length ? ssid :
                (isWiFi ? (canReadSSID ? @"SSID bị iOS ẩn / thiếu quyền Wi‑Fi" : @"Cần quyền vị trí khi dùng để đọc SSID") :
                 ([name hasPrefix:@"pdp"] ? @"Mạng di động" : @"Không có SSID trên giao diện này"));
            self.networkNameLabel.text = [NSString stringWithFormat:@"Tên mạng: %@", networkName];
            self.interfaceLabel.text = [NSString stringWithFormat:@"Loại mạng: %@ (%@)", kind, name];
            self.ipv4Label.text = [NSString stringWithFormat:@"IPv4: %@", interfaces[@"IPv4"] ?: @"Không khả dụng"];
            self.ipv6Label.text = [NSString stringWithFormat:@"IPv6: %@", interfaces[@"IPv6"] ?: @"Không khả dụng"];
            self.updatedLabel.text = [NSString stringWithFormat:@"Cập nhật: %@", [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
            [self startLatencyProbe];
        });
    });
}

- (void)startLatencyProbe {
    [self.latencyTask cancel];
    self.latencyTask = nil;
    NSURL *url = [NSURL URLWithString:@"https://1.1.1.1/cdn-cgi/trace"];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    __weak typeof(self) weakSelf = self;
    self.latencyTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSTimeInterval elapsed = (NSProcessInfo.processInfo.systemUptime - start) * 1000.0;
        NSString *publicAddress = nil;
        if (data.length > 0) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            for (NSString *line in [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                if ([line hasPrefix:@"ip="] && line.length > 3) { publicAddress = [line substringFromIndex:3]; break; }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !self.isViewLoaded || !self.view.window) return;
            if (error || ![response isKindOfClass:[NSHTTPURLResponse class]]) {
                self.latencyLabel.text = [NSString stringWithFormat:@"Độ trễ HTTPS: Không đo được (%@)", error.localizedDescription ?: @"không có phản hồi"];
                self.publicIPLabel.text = @"IP công khai: Không lấy được";
            } else {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                self.latencyLabel.text = [NSString stringWithFormat:@"Độ trễ HTTPS tới 1.1.1.1: %.0f ms · HTTP %ld", elapsed, (long)status];
                self.publicIPLabel.text = [NSString stringWithFormat:@"IP công khai: %@", publicAddress ?: @"Endpoint không trả IP"];
            }
        });
    }];
    [self.latencyTask resume];
}

- (void)requestWiFiNamePermission {
    CLAuthorizationStatus status = CLLocationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusNotDetermined) {
        self.locationPermissionRequested = YES;
        [self.locationManager requestWhenInUseAuthorization];
    } else if (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse) {
        [self refreshNetworkInfo];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Chưa được cấp quyền Wi‑Fi" message:@"Hãy bật quyền Vị trí khi dùng trong Cài đặt iOS. Trang Mạng cần trạng thái quyền để đọc SSID khi iOS cho phép; trang Trái đất chỉ đọc tọa độ sau khi bạn chủ động nhấn nút lấy vị trí." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Mở Cài đặt" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            if (settingsURL && [UIApplication.sharedApplication canOpenURL:settingsURL]) [UIApplication.sharedApplication openURL:settingsURL options:@{} completionHandler:nil];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    if (self.locationPermissionRequested) {
        self.locationPermissionRequested = NO;
        [self refreshNetworkInfo];
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    (void)manager; (void)status;
    if (self.locationPermissionRequested) {
        self.locationPermissionRequested = NO;
        [self refreshNetworkInfo];
    }
}

- (void)dealloc {
    [self stopNetworkUpdates];
    self.locationManager.delegate = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
