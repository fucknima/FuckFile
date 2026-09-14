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
        NSString *relative = [url.path stringByRemovingPercentEncoding] ?: url.path;
        relative = [relative stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (!relative.length) relative = @"index.html";
        for (NSString *component in relative.pathComponents) {
            if ([component isEqualToString:@".."] || [component containsString:@"\0"]) {
                relative = nil;
                break;
            }
        }
        if (relative.length) {
            NSString *candidate = [[self.assetRoot stringByAppendingPathComponent:relative]
                stringByStandardizingPath];
            NSString *prefix = [self.assetRoot stringByAppendingString:@"/"];
            if ([candidate isEqualToString:self.assetRoot] || [candidate hasPrefix:prefix])
                path = candidate;
        }
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
@property(nonatomic, strong, nullable) NSDictionary *lastState;
@property(nonatomic) BOOL webProcessTerminated;
@property(nonatomic) BOOL needsForegroundRecovery;
@property(nonatomic) BOOL recoveryInFlight;
@property(nonatomic) BOOL documentRendered;
@property(nonatomic) BOOL hasBackgroundSignature;
@property(nonatomic) unsigned long long backgroundFileSize;
@property(nonatomic, strong, nullable) NSDate *backgroundModificationDate;
@property(nonatomic) BOOL errorPresented;
@property(nonatomic, copy, nullable) NSString *pendingFailureMessage;
@property(nonatomic) BOOL pendingFailureAllowsRetry;
@end

@implementation FFDocxViewerViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory)
        return nil;
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _filePath = [path copy];
        self.title = path.lastPathComponent;
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    NSString *index = [NSBundle.mainBundle pathForResource:@"index" ofType:@"html"
        inDirectory:@"DocxAssets"];
    if (!index.length) {
        [self presentRuntimeFailure:@"DOCX 查看器资源缺失。" allowRetry:NO];
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
    self.webView.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
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

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.pendingFailureMessage.length) {
        NSString *message = self.pendingFailureMessage;
        BOOL retry = self.pendingFailureAllowsRetry;
        self.pendingFailureMessage = nil;
        [self presentRuntimeFailure:message allowRetry:retry];
    }
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
    UIAction *reload = [UIAction actionWithTitle:@"重新载入"
        image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf reloadManually]; }];
    UIAction *system = [UIAction actionWithTitle:@"系统快速查看"
        image:[UIImage systemImageNamed:@"eye"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf openQuickLook]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithTitle:@"" children:@[share, reload, system]]];
}

#pragma mark - Lifecycle and lossless foreground retention

- (NSDictionary *)fileAttributes
{
    return [NSFileManager.defaultManager attributesOfItemAtPath:self.filePath error:nil] ?: @{};
}

- (void)rememberBackgroundFileSignature
{
    NSDictionary *attributes = [self fileAttributes];
    self.backgroundFileSize = [attributes[NSFileSize] unsignedLongLongValue];
    self.backgroundModificationDate = [attributes[NSFileModificationDate]
        isKindOfClass:NSDate.class] ? attributes[NSFileModificationDate] : nil;
    self.hasBackgroundSignature = attributes.count > 0;
}

- (BOOL)sourceChangedSinceBackground
{
    if (!self.hasBackgroundSignature) return NO;
    NSDictionary *attributes = [self fileAttributes];
    if (!attributes.count) return YES;
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSDate *modified = [attributes[NSFileModificationDate]
        isKindOfClass:NSDate.class] ? attributes[NSFileModificationDate] : nil;
    if (size != self.backgroundFileSize) return YES;
    if ((modified == nil) != (self.backgroundModificationDate == nil)) return YES;
    return modified && ![modified isEqualToDate:self.backgroundModificationDate];
}

- (void)loadDocumentPageForReason:(NSString *)reason
{
    if (self.recoveryInFlight || !self.webView) return;
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.filePath isDirectory:&directory] || directory) {
        self.recoveryInFlight = NO;
        [self presentRuntimeFailure:@"原 Word 文档已不存在。" allowRetry:NO];
        FFLogTag(@"DOCX", @"reload skipped missing path=%@ reason=%@", self.filePath, reason);
        return;
    }

    self.recoveryInFlight = YES;
    self.documentRendered = NO;
    self.errorPresented = NO;
    NSURL *url = [NSURL URLWithString:@"ffdocx:///index.html"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    [self.webView loadRequest:request];
    FFLogTag(@"DOCX", @"load reason=%@ path=%@", reason, self.filePath);
}

- (void)applicationDidEnterBackground:(__unused NSNotification *)note
{
    [self rememberBackgroundFileSignature];
    [self captureRuntimeState];
    FFLogTag(@"DOCX", @"background path=%@ rendered=%d", self.filePath,
        self.documentRendered);
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)note
{
    if ([self sourceChangedSinceBackground]) {
        self.needsForegroundRecovery = YES;
        FFLogTag(@"DOCX", @"source changed while backgrounded path=%@", self.filePath);
    }
    self.hasBackgroundSignature = NO;
    if (self.needsForegroundRecovery) [self recoverWebContentIfVisible];
}

- (void)captureRuntimeState
{
    if (!self.documentRendered || !self.webView) return;
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:
        @"window.FFDocx && window.FFDocx.captureState ? window.FFDocx.captureState() : null"
        completionHandler:^(id value, NSError *error) {
            if (!error && [value isKindOfClass:NSDictionary.class])
                weakSelf.lastState = value;
        }];
}

- (void)restoreRuntimeStateIfNeeded
{
    if (!self.lastState || !self.webView) return;
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.lastState options:0 error:&jsonError];
    if (!data) {
        FFLogTag(@"DOCX", @"state encode failed path=%@ error=%@", self.filePath,
            jsonError.localizedDescription ?: @"unknown");
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"window.FFDocx && window.FFDocx.restoreState ? window.FFDocx.restoreState(%@) : null;", json];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

// First open of a document: fit the page width so nothing is clipped
// horizontally, matching Quick Look's initial scale. Re-opens restore the
// state captured in restoreRuntimeStateIfNeeded instead.
- (void)fitDocumentToWidth
{
    if (!self.webView) return;
    [self.webView evaluateJavaScript:
        @"window.FFDocx && window.FFDocx.fitToWidth ? window.FFDocx.fitToWidth() : null;"
        completionHandler:nil];
}

- (void)recoverWebContentIfVisible
{
    if (!self.needsForegroundRecovery || self.recoveryInFlight) return;
    if (!self.isViewLoaded || !self.view.window ||
        (self.navigationController && self.navigationController.topViewController != self))
        return;

    self.needsForegroundRecovery = NO;
    self.webProcessTerminated = NO;
    [self loadDocumentPageForReason:@"foreground-recovery"];
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
    [self presentRuntimeFailure:error.localizedDescription ?: @"Word 文档页面加载失败。"
        allowRetry:YES];
}

- (void)webView:(__unused WKWebView *)webView
    didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    self.recoveryInFlight = NO;
    FFLogTag(@"DOCX", @"provisional navigation failed path=%@ error=%@", self.filePath,
        error.localizedDescription ?: @"unknown");
    [self presentRuntimeFailure:error.localizedDescription ?: @"Word 文档页面加载失败。"
        allowRetry:YES];
}

#pragma mark - Actions

- (void)shareFile
{
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.filePath]] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)reloadManually
{
    [self captureRuntimeState];
    self.needsForegroundRecovery = YES;
    self.recoveryInFlight = NO;
    [self recoverWebContentIfVisible];
}

- (void)openQuickLook
{
    FFQuickLookViewController *quickLook =
        [[FFQuickLookViewController alloc] initWithFilePath:self.filePath];
    if (!quickLook) return;
    quickLook.title = self.title.length ? self.title : self.filePath.lastPathComponent;
    quickLook.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:quickLook animated:YES];
}

- (void)presentRuntimeFailure:(NSString *)message allowRetry:(BOOL)allowRetry
{
    if (!message.length) message = @"未知错误";
    if (!self.isViewLoaded || !self.view.window) {
        self.pendingFailureMessage = message;
        self.pendingFailureAllowsRetry = allowRetry;
        return;
    }
    if (self.errorPresented) return;
    self.errorPresented = YES;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开 Word 文档"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (allowRetry) {
        [alert addAction:[UIAlertAction actionWithTitle:@"重试"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                weakSelf.errorPresented = NO;
                weakSelf.recoveryInFlight = NO;
                weakSelf.needsForegroundRecovery = YES;
                [weakSelf recoverWebContentIfVisible];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"系统快速查看"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            weakSelf.errorPresented = NO;
            [weakSelf openQuickLook];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            weakSelf.errorPresented = NO;
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(__unused WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.name isEqualToString:@"ffDocx"] ||
        ![message.body isKindOfClass:NSDictionary.class]) return;

    NSString *type = message.body[@"type"];
    if ([type isEqualToString:@"state"]) {
        if ([message.body[@"state"] isKindOfClass:NSDictionary.class])
            self.lastState = message.body[@"state"];
        return;
    }
    if ([type isEqualToString:@"loaded"]) {
        self.recoveryInFlight = NO;
        self.webProcessTerminated = NO;
        self.needsForegroundRecovery = NO;
        self.documentRendered = YES;
        self.errorPresented = NO;
        if (self.lastState) [self restoreRuntimeStateIfNeeded];
        else [self fitDocumentToWidth];
        FFLogTag(@"DOCX", @"rendered path=%@", self.filePath);
    } else if ([type isEqualToString:@"error"]) {
        self.recoveryInFlight = NO;
        self.documentRendered = NO;
        NSString *detail = [message.body[@"message"] isKindOfClass:NSString.class]
            ? message.body[@"message"] : @"渲染失败";
        FFLogTag(@"DOCX", @"render failed path=%@ error=%@", self.filePath, detail);
        [self presentRuntimeFailure:detail allowRetry:YES];
    }
}

@end
