#import "FFDocxViewerViewController.h"
#import "FFQuickLookViewController.h"
#import "FFLogger.h"

#import <WebKit/WebKit.h>

static NSString * const FFDocxScheme = @"ffdocx";

@interface FFDocxSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, copy) NSString *documentPath;
@property(nonatomic, copy) NSString *assetRoot;
@end

@implementation FFDocxSchemeHandler

- (instancetype)initWithDocumentPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _documentPath = [path copy];
        _assetRoot = [[NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"DocxAssets"] stringByStandardizingPath];
    }
    return self;
}

- (NSString *)mime:(NSString *)path
{
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"html"]) return @"text/html";
    if ([extension isEqualToString:@"css"]) return @"text/css";
    if ([extension isEqualToString:@"js"]) return @"application/javascript";
    return @"application/octet-stream";
}

- (void)webView:(__unused WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSURL *url = task.request.URL;
    NSString *path = nil;
    if (![url.scheme.lowercaseString isEqualToString:FFDocxScheme]) {
        [task didFailWithError:[NSError errorWithDomain:@"FFDocx" code:403 userInfo:nil]];
        return;
    }

    if ([url.path isEqualToString:@"/document"]) {
        path = self.documentPath;
    } else {
        NSString *relative = [url.path stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (!relative.length) relative = @"index.html";
        NSString *candidate = [[self.assetRoot stringByAppendingPathComponent:relative]
            stringByStandardizingPath];
        NSString *prefix = [self.assetRoot stringByAppendingString:@"/"];
        if ([candidate isEqualToString:self.assetRoot] || [candidate hasPrefix:prefix])
            path = candidate;
    }

    NSData *data = path.length ? [NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:nil] : nil;
    if (!data) {
        [task didFailWithError:[NSError errorWithDomain:@"FFDocx" code:404 userInfo:nil]];
        return;
    }

    NSString *mime = [self mime:path];
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url MIMEType:mime
        expectedContentLength:(NSInteger)data.length
        textEncodingName:([mime hasPrefix:@"text/"] || [mime containsString:@"javascript"])
            ? @"utf-8" : nil];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(__unused WKWebView *)webView
    stopURLSchemeTask:(__unused id<WKURLSchemeTask>)task {}

@end

@interface FFDocxWeakHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation FFDocxWeakHandler
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface FFDocxViewerViewController () <WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) FFDocxSchemeHandler *schemeHandler;
@property(nonatomic, strong) FFDocxWeakHandler *weakHandler;
@property(nonatomic) BOOL webProcessTerminated;
@property(nonatomic) BOOL needsForegroundRecovery;
@property(nonatomic) BOOL recoveryInFlight;
@property(nonatomic) BOOL documentRendered;
@property(nonatomic) BOOL hasSavedScrollPosition;
@property(nonatomic) CGPoint savedScrollPosition;
@end

@implementation FFDocxViewerViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory)
        return nil;
    self = [super initWithNibName:nil bundle:nil];
    if (self) _filePath = [path copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    NSString *index = [NSBundle.mainBundle pathForResource:@"index" ofType:@"html"
        inDirectory:@"DocxAssets"];
    if (!index.length) {
        [self offerQuickLook:@"DOCX 查看器资源缺失"];
        return;
    }

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.schemeHandler = [[FFDocxSchemeHandler alloc] initWithDocumentPath:self.filePath];
    [configuration setURLSchemeHandler:self.schemeHandler forURLScheme:FFDocxScheme];

    WKUserContentController *contentController = [WKUserContentController new];
    self.weakHandler = [FFDocxWeakHandler new];
    self.weakHandler.target = self;
    [contentController addScriptMessageHandler:self.weakHandler name:@"ffDocx"];
    configuration.userContentController = contentController;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self configureMenu];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationDidEnterBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];

    [self loadDocumentPageForReason:@"initial"];
    FFLogTag(@"DOCX", @"open path=%@", self.filePath);
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.webView.navigationDelegate = nil;
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"ffDocx"];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (self.needsForegroundRecovery &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self recoverWebContentIfVisible];
}

- (void)configureMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *share = [UIAction actionWithTitle:@"分享原文件"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf shareFile]; }];
    UIAction *system = [UIAction actionWithTitle:@"系统快速查看"
        image:[UIImage systemImageNamed:@"eye"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf openQuickLook]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithTitle:@"" children:@[share, system]]];
}

- (void)loadDocumentPageForReason:(NSString *)reason
{
    if (self.recoveryInFlight) return;
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.filePath isDirectory:&directory] || directory) {
        FFLogTag(@"DOCX", @"reload skipped missing path=%@ reason=%@", self.filePath, reason);
        return;
    }

    self.recoveryInFlight = YES;
    self.documentRendered = NO;
    NSURL *url = [NSURL URLWithString:@"ffdocx:///index.html"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    [self.webView loadRequest:request];
    FFLogTag(@"DOCX", @"load reason=%@ path=%@", reason, self.filePath);
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)note
{
    [self captureScrollPosition];
    FFLogTag(@"DOCX", @"background path=%@ rendered=%d", self.filePath,
        self.documentRendered);
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)note
{
    if (self.needsForegroundRecovery) [self recoverWebContentIfVisible];
}

- (void)captureScrollPosition
{
    if (!self.documentRendered || !self.webView) return;
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
    if (!self.hasSavedScrollPosition || !self.webView) return;
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

    self.needsForegroundRecovery = NO;
    self.webProcessTerminated = NO;
    [self loadDocumentPageForReason:@"web-process-recovery"];
}

#pragma mark - WKNavigationDelegate

- (void)webViewWebContentProcessDidTerminate:(__unused WKWebView *)webView
{
    self.webProcessTerminated = YES;
    self.needsForegroundRecovery = YES;
    self.recoveryInFlight = NO;
    self.documentRendered = NO;
    FFLogTag(@"DOCX", @"WebContent process terminated path=%@ state=%ld",
        self.filePath, (long)UIApplication.sharedApplication.applicationState);

    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self recoverWebContentIfVisible];
}

- (void)webView:(__unused WKWebView *)webView
    didFailNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    self.recoveryInFlight = NO;
    FFLogTag(@"DOCX", @"navigation failed path=%@ error=%@", self.filePath,
        error.localizedDescription ?: @"unknown");
}

- (void)webView:(__unused WKWebView *)webView
    didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    self.recoveryInFlight = NO;
    FFLogTag(@"DOCX", @"provisional navigation failed path=%@ error=%@", self.filePath,
        error.localizedDescription ?: @"unknown");
}

#pragma mark - Actions

- (void)shareFile
{
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.filePath]] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)openQuickLook
{
    FFQuickLookViewController *quickLook =
        [[FFQuickLookViewController alloc] initWithFilePath:self.filePath];
    if (!quickLook) return;
    quickLook.title = self.title.length ? self.title : self.filePath.lastPathComponent;
    [self.navigationController pushViewController:quickLook animated:YES];
}

- (void)offerQuickLook:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开 Word 文档"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"系统快速查看"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self openQuickLook];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(__unused WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.name isEqualToString:@"ffDocx"] ||
        ![message.body isKindOfClass:NSDictionary.class]) return;

    NSString *type = message.body[@"type"];
    if ([type isEqualToString:@"loaded"]) {
        self.recoveryInFlight = NO;
        self.webProcessTerminated = NO;
        self.needsForegroundRecovery = NO;
        self.documentRendered = YES;
        [self restoreScrollPositionIfNeeded];
        FFLogTag(@"DOCX", @"rendered path=%@", self.filePath);
    } else if ([type isEqualToString:@"error"]) {
        self.recoveryInFlight = NO;
        self.documentRendered = NO;
        NSString *detail = message.body[@"message"] ?: @"渲染失败";
        FFLogTag(@"DOCX", @"render failed path=%@ error=%@", self.filePath, detail);
        [self offerQuickLook:detail];
    }
}

@end
