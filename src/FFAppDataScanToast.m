#import <UIKit/UIKit.h>
#import "FFAppDataScanCoordinator.h"
#import "FFAppDataRegistry.h"

// AppData discovery is background state, not navigation state.  Keep its UI
// lightweight and non-blocking so Device Storage remains usable while scanning.
@interface FFAppDataScanToast : NSObject
@property(nonatomic, strong) UIVisualEffectView *toast;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic) BOOL wasScanning;
@property(nonatomic) NSUInteger generation;
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
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(scanChanged:) name:FFAppDataScanStateDidChangeNotification object:nil];
    }
    return self;
}

- (UIWindow *)activeWindow
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (void)ensureToast
{
    UIWindow *window = [self activeWindow];
    if (!window) return;
    if (!self.toast) {
        UIBlurEffectStyle style = UIBlurEffectStyleSystemChromeMaterial;
        self.toast = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
        self.toast.userInteractionEnabled = NO;
        self.toast.layer.cornerRadius = 18.0;
        self.toast.clipsToBounds = YES;
        self.toast.alpha = 0.0;
        self.label = [UILabel new];
        self.label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        self.label.textAlignment = NSTextAlignmentCenter;
        self.label.numberOfLines = 1;
        [self.toast.contentView addSubview:self.label];
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
    CGFloat width = MIN(window.bounds.size.width - 48.0, 330.0);
    CGFloat bottom = MAX(window.safeAreaInsets.bottom, 12.0) + 92.0;
    self.toast.frame = CGRectMake((window.bounds.size.width - width) * 0.5,
        window.bounds.size.height - bottom - 42.0, width, 42.0);
    self.label.frame = CGRectInset(self.toast.bounds, 14.0, 0.0);
}

- (void)showText:(NSString *)text autoHide:(BOOL)autoHide
{
    [self ensureToast];
    if (!self.toast) return;
    self.generation++;
    NSUInteger generation = self.generation;
    self.label.text = text;
    [self layoutToast];
    [UIView animateWithDuration:0.18 animations:^{ self.toast.alpha = 1.0; }];
    if (!autoHide) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.generation) return;
        [UIView animateWithDuration:0.2 animations:^{ self.toast.alpha = 0.0; }];
    });
}

- (void)scanChanged:(NSNotification *)note
{
    NSDictionary *info = note.userInfo ?: @{};
    BOOL scanning = [info[@"Scanning"] boolValue];
    NSUInteger total = [info[@"Total"] unsignedIntegerValue];
    NSUInteger linked = [info[@"Linked"] unsignedIntegerValue];
    double progress = [info[@"Progress"] doubleValue];
    NSUInteger done = total ? MIN(total, (NSUInteger)llround((double)total * progress)) : 0;

    if (scanning) {
        NSString *text = total > 0
            ? [NSString stringWithFormat:@"正在更新 App Data · %lu/%lu",
                (unsigned long)done, (unsigned long)total]
            : @"正在更新 App Data…";
        [self showText:text autoHide:NO];
    } else if (self.wasScanning) {
        NSUInteger count = FFAppDataRegistry.sharedRegistry.identifiers.count;
        if (!count) count = linked;
        [self showText:[NSString stringWithFormat:@"App Data 已更新 · %lu 个 App",
            (unsigned long)count] autoHide:YES];
    }
    self.wasScanning = scanning;
}

@end

__attribute__((constructor)) static void FFInstallAppDataScanToast(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ (void)FFAppDataScanToast.sharedToast; });
}
