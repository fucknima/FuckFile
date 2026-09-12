#import "FFWebViewerViewController.h"

#import "FFLogger.h"

@interface FFWebViewerViewController () <WKNavigationDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong, nullable) NSURL *lastCommittedURL;
@property(nonatomic) BOOL webProcessTerminated;
@property(nonatomic) BOOL needsForegroundRecovery;
@property(nonatomic) BOOL recoveryInFlight;
@property(nonatomic) BOOL hasSavedScrollPosition;
@property(nonatomic) CGPoint savedScrollPosition;
@end

@implementation FFWebViewerViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory)
        return nil;
    self = [super init];
    if (self) _filePath = [path copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2,
        self.view.bounds.size.height / 2);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationDidEnterBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];

    if (![self loadShortcutOrLocalPage])
        [self showFailure:@"无法解析该网页文件"];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.webView.navigationDelegate = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (self.needsForegroundRecovery &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self recoverWebContentIfVisible];
}

// .url / .webloc resolve to a remote URL; html/htm load as local files
// with read access scoped to the file's own directory (never the whole
// filesystem).
- (BOOL)loadShortcutOrLocalPage
{
    NSString *extension = self.filePath.pathExtension.lowercaseString;
    NSURL *fileURL = [NSURL fileURLWithPath:self.filePath];

    if ([extension isEqualToString:@"webloc"]) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:self.filePath];
        NSString *urlString = plist[@"URL"];
        return [self loadRemoteString:urlString];
    }
    if ([extension isEqualToString:@"url"]) {
        NSError *error = nil;
        NSString *content = [NSString stringWithContentsOfFile:self.filePath
            encoding:NSUTF8StringEncoding error:&error];
        if (!content)
            content = [NSString stringWithContentsOfFile:self.filePath
                encoding:NSISOLatin1StringEncoding error:nil];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
            @"(?i)^\\s*URL\\s*=\\s*(\\S+)"
            options:NSRegularExpressionAnchorsMatchLines error:&error];
        NSString *urlString = nil;
        if (regex) {
            NSTextCheckingResult *match = [regex firstMatchInString:content options:0
                range:NSMakeRange(0, content.length)];
            if (match.numberOfRanges > 1)
                urlString = [content substringWithRange:[match rangeAtIndex:1]];
        }
        return [self loadRemoteString:urlString];
    }

    NSURL *folder = fileURL.URLByDeletingLastPathComponent;
    [self.spinner startAnimating];
    self.recoveryInFlight = YES;
    [self.webView loadFileURL:fileURL allowingReadAccessToURL:folder];
    return YES;
}

- (BOOL)loadRemoteString:(NSString *)urlString
{
    if (urlString.length == 0) {
        FFLogTag(@"Web", @"shortcut has no URL: %@", self.filePath);
        return NO;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !(url.scheme.length || [urlString hasPrefix:@"about:"])) {
        // Shortcuts often omit the scheme; assume https.
        url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@", urlString]];
    }
    if (!url) return NO;
    [self.spinner startAnimating];
    self.recoveryInFlight = YES;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    return YES;
}

#pragma mark - Foreground / WebContent recovery

- (void)applicationDidEnterBackground:(__unused NSNotification *)note
{
    [self captureScrollPosition];
    FFLogTag(@"Web", @"background path=%@ url=%@", self.filePath,
        self.webView.URL.absoluteString ?: @"-");
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)note
{
    if (self.needsForegroundRecovery) [self recoverWebContentIfVisible];
}

- (void)captureScrollPosition
{
    if (!self.webView.URL) return;
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:
        @"({x: window.scrollX || 0, y: window.scrollY || 0})"
        completionHandler:^(id value, NSError *error) {
            if (error || ![value isKindOfClass:NSDictionary.class]) return;
            NSNumber *x = value[@"x"];
            NSNumber *y = value[@"y"];
            if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]) return;
            weakSelf.savedScrollPosition = CGPointMake(x.doubleValue, y.doubleValue);
            weakSelf.hasSavedScrollPosition = YES;
        }];
}

- (void)restoreScrollPositionIfNeeded
{
    if (!self.hasSavedScrollPosition) return;
    CGPoint point = self.savedScrollPosition;
    self.hasSavedScrollPosition = NO;
    NSString *script = [NSString stringWithFormat:@"window.scrollTo(%.3f, %.3f);",
        point.x, point.y];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)recoverWebContentIfVisible
{
    if (!self.needsForegroundRecovery || self.recoveryInFlight) return;
    if (!self.isViewLoaded || !self.view.window ||
        (self.navigationController && self.navigationController.topViewController != self))
        return;

    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.filePath isDirectory:&directory] || directory) {
        self.needsForegroundRecovery = NO;
        FFLogTag(@"Web", @"recovery source missing path=%@", self.filePath);
        [self showFailure:@"原文件已不存在，无法恢复页面。"];
        return;
    }

    self.needsForegroundRecovery = NO;
    self.webProcessTerminated = NO;
    self.recoveryInFlight = YES;
    [self.spinner startAnimating];

    NSURL *url = self.lastCommittedURL;
    if (url.isFileURL) {
        // The source HTML may use sibling CSS/JS/images. Keep the original
        // read-access scope rather than widening it after a process restart.
        NSURL *folder = [NSURL fileURLWithPath:self.filePath].URLByDeletingLastPathComponent;
        [self.webView loadFileURL:url allowingReadAccessToURL:folder];
    } else if (url) {
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    } else {
        self.recoveryInFlight = NO;
        if (![self loadShortcutOrLocalPage]) [self showFailure:@"无法恢复该网页"];
    }
    FFLogTag(@"Web", @"recover WebContent path=%@ url=%@", self.filePath,
        url.absoluteString ?: @"initial");
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    didStartProvisionalNavigation:(__unused WKNavigation *)navigation
{
    [self.spinner startAnimating];
    self.recoveryInFlight = YES;
    FFLogTag(@"Web", @"navigation start path=%@ url=%@", self.filePath,
        webView.URL.absoluteString ?: @"-");
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(__unused WKNavigation *)navigation
{
    [self.spinner stopAnimating];
    self.recoveryInFlight = NO;
    self.webProcessTerminated = NO;
    self.needsForegroundRecovery = NO;
    if (webView.URL) self.lastCommittedURL = webView.URL;
    self.title = webView.title.length ? webView.title : self.filePath.lastPathComponent;
    [self restoreScrollPositionIfNeeded];
    FFLogTag(@"Web", @"navigation finish path=%@ url=%@", self.filePath,
        webView.URL.absoluteString ?: @"-");
}

- (void)webViewWebContentProcessDidTerminate:(__unused WKWebView *)webView
{
    self.webProcessTerminated = YES;
    self.needsForegroundRecovery = YES;
    self.recoveryInFlight = NO;
    [self.spinner stopAnimating];
    FFLogTag(@"Web", @"WebContent process terminated path=%@ state=%ld",
        self.filePath, (long)UIApplication.sharedApplication.applicationState);

    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self recoverWebContentIfVisible];
}

- (void)webView:(__unused WKWebView *)webView
    didFailNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    [self handleNavigationFailure:error phase:@"navigation"];
}

- (void)webView:(__unused WKWebView *)webView
    didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    [self handleNavigationFailure:error phase:@"provisional"];
}

- (void)handleNavigationFailure:(NSError *)error phase:(NSString *)phase
{
    [self.spinner stopAnimating];
    self.recoveryInFlight = NO;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
        return;
    FFLogTag(@"Web", @"%@ FAIL %@: %@", phase, self.filePath, error);
    [self showFailure:error.localizedDescription ?: @"页面加载失败"];
}

- (void)showFailure:(NSString *)message
{
    if (!self.viewIfLoaded.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加载失败"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
