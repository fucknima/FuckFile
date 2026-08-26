#import <UIKit/UIKit.h>
#import "FFAppDataScanCoordinator.h"
#import "FFAppDataRegistry.h"
#import "FFOnlineAppNameResolver.h"

// AppData discovery and online-name enrichment are one background lifecycle from
// the user's point of view. Reuse one non-blocking bottom toast so scan and name
// progress never compete for screen space. AppData scanning always has priority.
@interface FFAppDataScanToast : NSObject
@property(nonatomic, strong) UIVisualEffectView *toast;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic) BOOL wasScanning;
@property(nonatomic) BOOL wasNameResolving;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSTimeInterval lastProgressRender;
@end

@implementation FFAppDataScanToast

+ (instancetype)sharedToast
{
    static FFAppDataScanToast *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [FFAppDataScanToast new]; });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(scanChanged:)
            name:FFAppDataScanStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(onlineNameChanged:)
            name:FFOnlineAppNameResolutionStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UIWindow *)activeWindow
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (window.isKeyWindow) return window;
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (CGFloat)bottomClearanceInWindow:(UIWindow *)window
{
    UIViewController *root = window.rootViewController;
    if ([root isKindOfClass:UITabBarController.class]) {
        UITabBarController *tabs = (UITabBarController *)root;
        CGRect tabFrame = [tabs.tabBar convertRect:tabs.tabBar.bounds toView:window];
        if (!CGRectIsEmpty(tabFrame) && CGRectGetMinY(tabFrame) > 0)
            return MAX(10.0, CGRectGetHeight(window.bounds) - CGRectGetMinY(tabFrame) + 10.0);
    }
    return MAX(window.safeAreaInsets.bottom, 12.0) + 12.0;
}

- (void)ensureToast
{
    UIWindow *window = [self activeWindow];
    if (!window) return;
    if (!self.toast) {
        self.toast = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        self.toast.userInteractionEnabled = NO;
        self.toast.layer.cornerRadius = 16.0;
        self.toast.layer.cornerCurve = kCACornerCurveContinuous;
        self.toast.clipsToBounds = YES;
        self.toast.alpha = 0.0;

        self.label = [UILabel new];
        self.label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.label.textAlignment = NSTextAlignmentCenter;
        self.label.textColor = UIColor.labelColor;
        [self.toast.contentView addSubview:self.label];

        self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        self.progressView.trackTintColor = UIColor.tertiarySystemFillColor;
        [self.toast.contentView addSubview:self.progressView];
    }
    if (self.toast.superview != window) {
        [self.toast removeFromSuperview];
        [window addSubview:self.toast];
    }
}

- (void)layoutToast
{
    UIWindow *window = [self activeWindow];
    if (!window || !self.toast) return;
    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 56.0, 320.0);
    CGFloat height = 54.0;
    CGFloat bottom = [self bottomClearanceInWindow:window];
    self.toast.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) * 0.5,
        CGRectGetHeight(window.bounds) - bottom - height, width, height);
    self.label.frame = CGRectMake(14, 7, width - 28, 24);
    self.progressView.frame = CGRectMake(18, 36, width - 36, 3);
}

- (void)showProgressText:(NSString *)text progress:(float)progress
{
    [self ensureToast];
    if (!self.toast) return;
    self.generation++;
    self.label.text = text;
    self.progressView.hidden = NO;
    [self.progressView setProgress:MAX(0.0f, MIN(1.0f, progress)) animated:YES];
    [self layoutToast];
    if (self.toast.alpha < 1.0) {
        [UIView animateWithDuration:0.18 animations:^{ self.toast.alpha = 1.0; }];
    }
}

- (void)showTransientText:(NSString *)text
{
    [self ensureToast];
    if (!self.toast) return;
    self.generation++;
    NSUInteger generation = self.generation;
    self.label.text = text;
    self.progressView.hidden = YES;
    [self layoutToast];
    [UIView animateWithDuration:0.18 animations:^{ self.toast.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            [UIView animateWithDuration:0.20 animations:^{ self.toast.alpha = 0.0; }];
        });
}

- (void)hideSoon
{
    if (!self.toast || self.toast.alpha <= 0.0) return;
    self.generation++;
    NSUInteger generation = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            [UIView animateWithDuration:0.20 animations:^{ self.toast.alpha = 0.0; }];
        });
}

- (void)scanChanged:(NSNotification *)note
{
    NSDictionary *info = note.userInfo ?: @{};
    BOOL scanning = [info[@"Scanning"] boolValue];
    double rawProgress = [info[@"Progress"] doubleValue];

    if (scanning) {
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        // The coordinator may publish many incremental records. Rendering at
        // most ~8 fps is visually smooth while avoiding another main-thread
        // progress-notification storm.
        if (!self.wasScanning || now - self.lastProgressRender >= 0.12 || rawProgress >= 1.0) {
            self.lastProgressRender = now;
            [self showProgressText:@"正在更新 App Data" progress:(float)rawProgress];
        }
    } else if (self.wasScanning) {
        NSUInteger count = FFAppDataRegistry.sharedRegistry.identifiers.count;
        [self showTransientText:[NSString stringWithFormat:@"App Data 已更新 · %lu 个可访问 App",
            (unsigned long)count]];
    }
    self.wasScanning = scanning;
}

- (void)onlineNameChanged:(NSNotification *)note
{
    (void)note;
    // The scan is the authoritative producer of the registry. Never cover its
    // progress with the secondary name-enrichment phase.
    if (FFAppDataScanCoordinator.sharedCoordinator.scanning) return;

    FFOnlineAppNameResolver *resolver = FFOnlineAppNameResolver.sharedResolver;
    FFOnlineAppNameResolutionState state = resolver.state;
    BOOL resolving = state == FFOnlineAppNameResolutionStateResolving;

    if (resolving) {
        NSString *text = [NSString stringWithFormat:@"正在补全 App 名称 · %lu/%lu",
            (unsigned long)resolver.passCompleted, (unsigned long)resolver.passTotal];
        [self showProgressText:text progress:(float)resolver.progress];
    } else if (state == FFOnlineAppNameResolutionStateWaitingForRetry && self.wasNameResolving) {
        [self showTransientText:@"App 名称补全暂停 · 稍后自动重试"];
    } else if (state == FFOnlineAppNameResolutionStateIdle && self.wasNameResolving) {
        [self showTransientText:[NSString stringWithFormat:@"App 名称已更新 · 已识别 %lu/%lu",
            (unsigned long)resolver.namedAppCount, (unsigned long)resolver.userAppTotal]];
    } else if (self.wasNameResolving &&
        (state == FFOnlineAppNameResolutionStateDisabled ||
         state == FFOnlineAppNameResolutionStateWaitingForSystemAccess ||
         state == FFOnlineAppNameResolutionStateWaitingForScan)) {
        [self hideSoon];
    }

    self.wasNameResolving = resolving;
}

@end

__attribute__((constructor)) static void FFInstallAppDataScanToast(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ (void)FFAppDataScanToast.sharedToast; });
}
