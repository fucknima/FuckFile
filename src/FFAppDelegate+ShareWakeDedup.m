#import "FFAppDelegate.h"
#import "FFShareBridge.h"
#import "FFLogger.h"
#import "FFAppDataScanCoordinator.h"
#import "FFAppDataRegistry.h"

#import <objc/runtime.h>

static const void *kFFHandledShareTokensKey = &kFFHandledShareTokensKey;
static const NSTimeInterval kFFShareTokenDedupTTL = 60.0;

@interface FFAppDelegate (ShareWakeDedup)
- (void)ff_handleShareWakeURLDeduplicated:(NSURL *)url;
@end

@implementation FFAppDelegate (ShareWakeDedup)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"handleShareWakeURL:"));
        Method replacement = class_getInstanceMethod(self, @selector(ff_handleShareWakeURLDeduplicated:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_handleShareWakeURLDeduplicated:(NSURL *)url
{
    BOOL isShareStream = [[url.scheme lowercaseString] isEqualToString:[FFShareWakeScheme lowercaseString]] &&
        [[url.host lowercaseString] isEqualToString:@"share-stream"];
    if (!isShareStream) { [self ff_handleShareWakeURLDeduplicated:url]; return; }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *token = nil;
    for (NSURLQueryItem *item in components.queryItems ?: @[]) if ([item.name isEqualToString:@"token"]) { token = item.value; break; }
    if (!token.length) { [self ff_handleShareWakeURLDeduplicated:url]; return; }
    @synchronized (self) {
        NSMutableDictionary<NSString *, NSDate *> *handled = objc_getAssociatedObject(self, kFFHandledShareTokensKey);
        if (!handled) { handled = [NSMutableDictionary dictionary]; objc_setAssociatedObject(self, kFFHandledShareTokensKey, handled, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        NSDate *now = NSDate.date; NSMutableArray<NSString *> *expired = [NSMutableArray array];
        for (NSString *key in handled) if ([now timeIntervalSinceDate:handled[key]] >= kFFShareTokenDedupTTL) [expired addObject:key];
        [handled removeObjectsForKeys:expired];
        NSDate *seen = handled[token];
        if (seen && [now timeIntervalSinceDate:seen] < kFFShareTokenDedupTTL) { FFLogTag(@"ShareBridge", @"ignore duplicate share-stream wake token=%@", token); return; }
        handled[token] = now;
    }
    [self ff_handleShareWakeURLDeduplicated:url];
}

@end

#pragma mark - AppData background scan toast

@interface FFAppDataScanToast : NSObject
@property(nonatomic, strong) UIVisualEffectView *toast;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic) BOOL wasScanning;
@property(nonatomic) NSUInteger generation;
@end

@implementation FFAppDataScanToast

+ (instancetype)sharedToast { static FFAppDataScanToast *x; static dispatch_once_t once; dispatch_once(&once, ^{ x = [FFAppDataScanToast new]; }); return x; }

- (instancetype)init
{
    self = [super init];
    if (self) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scanChanged:) name:FFAppDataScanStateDidChangeNotification object:nil];
    return self;
}

- (UIWindow *)activeWindow
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (void)showText:(NSString *)text autoHide:(BOOL)autoHide
{
    UIWindow *window = [self activeWindow]; if (!window) return;
    if (!self.toast) {
        self.toast = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        self.toast.userInteractionEnabled = NO; self.toast.layer.cornerRadius = 18; self.toast.clipsToBounds = YES; self.toast.alpha = 0;
        self.label = [UILabel new]; self.label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; self.label.textAlignment = NSTextAlignmentCenter;
        [self.toast.contentView addSubview:self.label];
    }
    if (self.toast.superview != window) { [self.toast removeFromSuperview]; [window addSubview:self.toast]; }
    CGFloat width = MIN(window.bounds.size.width - 48, 330); CGFloat bottom = MAX(window.safeAreaInsets.bottom, 12) + 92;
    self.toast.frame = CGRectMake((window.bounds.size.width-width)/2, window.bounds.size.height-bottom-42, width, 42);
    self.label.frame = CGRectInset(self.toast.bounds, 14, 0); self.label.text = text;
    self.generation++; NSUInteger generation = self.generation;
    [UIView animateWithDuration:.18 animations:^{ self.toast.alpha = 1; }];
    if (autoHide) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.generation) return; [UIView animateWithDuration:.2 animations:^{ self.toast.alpha = 0; }];
    });
}

- (void)scanChanged:(NSNotification *)note
{
    NSDictionary *info = note.userInfo ?: @{}; BOOL scanning = [info[@"Scanning"] boolValue];
    NSUInteger total = [info[@"Total"] unsignedIntegerValue], linked = [info[@"Linked"] unsignedIntegerValue];
    double progress = [info[@"Progress"] doubleValue]; NSUInteger done = total ? MIN(total, (NSUInteger)llround(total*progress)) : 0;
    if (scanning) [self showText:total ? [NSString stringWithFormat:@"正在更新 App Data · %lu/%lu", (unsigned long)done, (unsigned long)total] : @"正在更新 App Data…" autoHide:NO];
    else if (self.wasScanning) {
        NSUInteger count = FFAppDataRegistry.sharedRegistry.identifiers.count ?: linked;
        [self showText:[NSString stringWithFormat:@"App Data 已更新 · %lu 个 App", (unsigned long)count] autoHide:YES];
    }
    self.wasScanning = scanning;
}
@end

__attribute__((constructor)) static void FFInstallAppDataScanToast(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ (void)FFAppDataScanToast.sharedToast; });
}
