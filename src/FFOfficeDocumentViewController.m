#import "FFOfficeDocumentViewController.h"

#import "FFLogger.h"
#import "FFQuickLookViewController.h"
#import "FFViewerStateStore.h"

#import <WebKit/WebKit.h>

static NSString * const FFOfficeScheme = @"ffoffice";
static const unsigned long long FFOfficeMaxSourceBytes = 128ULL * 1024 * 1024;

#pragma mark - Private URL scheme

@interface FFOfficeSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, copy) NSString *documentPath;
@property(nonatomic, copy) NSString *assetRoot;
@end

@implementation FFOfficeSchemeHandler

- (instancetype)initWithDocumentPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _documentPath = [path copy];
        _assetRoot = [[NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"OfficeAssets"] stringByStandardizingPath];
    }
    return self;
}

- (NSString *)mimeTypeForPath:(NSString *)path
{
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"html"]) return @"text/html";
    if ([extension isEqualToString:@"css"]) return @"text/css";
    if ([extension isEqualToString:@"js"]) return @"application/javascript";
    if ([extension isEqualToString:@"json"]) return @"application/json";
    if ([extension isEqualToString:@"svg"]) return @"image/svg+xml";
    if ([extension isEqualToString:@"png"]) return @"image/png";
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"])
        return @"image/jpeg";
    if ([extension isEqualToString:@"woff"]) return @"font/woff";
    if ([extension isEqualToString:@"woff2"]) return @"font/woff2";
    if ([extension isEqualToString:@"ttf"]) return @"font/ttf";
    return @"application/octet-stream";
}

- (NSString *)safeAssetPathForURL:(NSURL *)url
{
    NSString *relative = [url.path stringByRemovingPercentEncoding] ?: url.path;
    relative = [relative stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (!relative.length) relative = @"index.html";
    for (NSString *component in relative.pathComponents) {
        if ([component isEqualToString:@".."] || [component containsString:@"\0"])
            return nil;
    }
    NSString *candidate = [[self.assetRoot stringByAppendingPathComponent:relative]
        stringByStandardizingPath];
    NSString *prefix = [self.assetRoot stringByAppendingString:@"/"];
    if (![candidate isEqualToString:self.assetRoot] && ![candidate hasPrefix:prefix])
        return nil;
    return candidate;
}

- (void)webView:(__unused WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSURL *url = task.request.URL;
    if (![url.scheme.lowercaseString isEqualToString:FFOfficeScheme]) {
        [task didFailWithError:[NSError errorWithDomain:@"FFOffice" code:403
            userInfo:@{NSLocalizedDescriptionKey:@"非法办公文档资源地址"}]];
        return;
    }

    NSString *path = nil;
    if ([url.path isEqualToString:@"/document"]) path = self.documentPath;
    else path = [self safeAssetPathForURL:url];

    if (!path.length) {
        [task didFailWithError:[NSError errorWithDomain:@"FFOffice" code:403
            userInfo:@{NSLocalizedDescriptionKey:@"资源路径越界"}]];
        return;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) {
        [task didFailWithError:readError ?: [NSError errorWithDomain:@"FFOffice" code:404
            userInfo:@{NSLocalizedDescriptionKey:@"资源不存在"}]];
        return;
    }

    NSString *mime = [self mimeTypeForPath:path];
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url MIMEType:mime
        expectedContentLength:(NSInteger)data.length
        textEncodingName:([mime hasPrefix:@"text/"] || [mime containsString:@"javascript"] ||
            [mime containsString:@"json"]) ? @"utf-8" : nil];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(__unused WKWebView *)webView
    stopURLSchemeTask:(__unused id<WKURLSchemeTask>)task {}

@end

#pragma mark - Weak script bridge

@interface FFOfficeWeakHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation FFOfficeWeakHandler
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

#pragma mark - Viewer

@interface FFOfficeDocumentViewController () <WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) FFOfficeSchemeHandler *schemeHandler;
@property(nonatomic, strong) FFOfficeWeakHandler *weakHandler;
@property(nonatomic, strong, nullable) NSDictionary *lastState;
@property(nonatomic) BOOL recoveryInFlight;
@property(nonatomic) BOOL documentRendered;
@property(nonatomic) BOOL needsForegroundRecovery;
@property(nonatomic) BOOL webProcessTerminated;
@property(nonatomic) BOOL errorPresented;
@property(nonatomic) BOOL hasBackgroundSignature;
@property(nonatomic) unsigned long long backgroundFileSize;
@property(nonatomic, strong, nullable) NSDate *backgroundModificationDate;
@property(nonatomic, copy, nullable) NSString *pendingFailureMessage;
@property(nonatomic) BOOL pendingFailureAllowsRetry;
@end

@implementation FFOfficeDocumentViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    BOOL directory = NO;
    if (!path.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory)
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
        inDirectory:@"OfficeAssets"];
    NSString *runtime = [NSBundle.mainBundle pathForResource:@"office-host" ofType:@"js"
        inDirectory:@"OfficeAssets"];
    if (!index.length || !runtime.length) {
        [self presentRuntimeFailure:@"办公文档离线运行时缺失。" allowRetry:NO];
        return;
    }

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.filePath
        error:nil];
    unsigned long long sourceSize = [attributes[NSFileSize] unsignedLongLongValue];
    if (sourceSize > FFOfficeMaxSourceBytes) {
        NSString *message = [NSString stringWithFormat:
            @"该文件为 %@，超过当前离线办公文档查看器的 128 MB 安全上限。",
            [NSByteCountFormatter stringFromByteCount:(long long)sourceSize
                countStyle:NSByteCountFormatterCountStyleFile]];
        [self presentRuntimeFailure:message allowRetry:NO];
        return;
    }

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.schemeHandler = [[FFOfficeSchemeHandler alloc] initWithDocumentPath:self.filePath];
    [configuration setURLSchemeHandler:self.schemeHandler forURLScheme:FFOfficeScheme];

    WKUserContentController *contentController = [WKUserContentController new];
    self.weakHandler = [FFOfficeWeakHandler new];
    self.weakHandler.target = self;
    [contentController addScriptMessageHandler:self.weakHandler name:@"ffOffice"];
    configuration.userContentController = contentController;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.navigationDelegate = self;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
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

    // Resume the last reading position for this exact file version, when one
    // was persisted (see applicationDidEnterBackground / viewDidDisappear).
    if (!self.lastState)
        self.lastState = [FFViewerStateStore stateForFilePath:self.filePath];

    [self loadRuntimePageForReason:@"initial"];
    FFLogTag(@"Office", @"open path=%@", self.filePath);
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.webView.navigationDelegate = nil;
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"ffOffice"];
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

#pragma mark - Lifecycle

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

- (void)applicationDidEnterBackground:(__unused NSNotification *)note
{
    [self rememberBackgroundFileSignature];
    __weak typeof(self) weakSelf = self;
    [self captureRuntimeStateWithCompletion:^{
        if (weakSelf.lastState)
            [FFViewerStateStore setState:weakSelf.lastState forFilePath:weakSelf.filePath];
    }];
    // Preserve the exact WebContent instance when iOS keeps it alive. No
    // foreground reload is scheduled simply because the app backgrounded.
    FFLogTag(@"Office", @"background path=%@ rendered=%d", self.filePath,
        self.documentRendered);
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.isMovingFromParentViewController) return;
    __weak typeof(self) weakSelf = self;
    [self captureRuntimeStateWithCompletion:^{
        if (weakSelf.lastState)
            [FFViewerStateStore setState:weakSelf.lastState forFilePath:weakSelf.filePath];
    }];
}

- (void)applicationDidBecomeActive:(__unused NSNotification *)note
{
    if ([self sourceChangedSinceBackground]) {
        self.needsForegroundRecovery = YES;
        FFLogTag(@"Office", @"source changed while backgrounded path=%@", self.filePath);
    }
    self.hasBackgroundSignature = NO;
    if (self.needsForegroundRecovery) [self recoverWebContentIfVisible];
}

- (void)captureRuntimeState
{
    [self captureRuntimeStateWithCompletion:nil];
}

- (void)promptJumpToPage
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跳转到页"
        message:@"输入页码；文档未渲染分页时仅能滚动到可定位的位置。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"页码";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSInteger page = alert.textFields.firstObject.text.integerValue;
            if (page < 1) return;
            NSString *script = [NSString stringWithFormat:
                @"window.FFOffice && window.FFOffice.scrollToPage ? window.FFOffice.scrollToPage(%ld) : null;",
                (long)(page - 1)];
            [weakSelf.webView evaluateJavaScript:script completionHandler:nil];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)captureRuntimeStateWithCompletion:(void (^ _Nullable)(void))completion
{
    if (!self.documentRendered || !self.webView) {
        if (completion) completion();
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:
        @"window.FFOffice && window.FFOffice.captureState ? window.FFOffice.captureState() : null"
        completionHandler:^(id value, NSError *error) {
            if (!error && [value isKindOfClass:NSDictionary.class])
                weakSelf.lastState = value;
            if (completion) completion();
        }];
}

- (void)recoverWebContentIfVisible
{
    if (!self.needsForegroundRecovery || self.recoveryInFlight) return;
    if (!self.isViewLoaded || !self.view.window ||
        (self.navigationController && self.navigationController.topViewController != self))
        return;

    self.needsForegroundRecovery = NO;
    self.webProcessTerminated = NO;
    [self loadRuntimePageForReason:@"foreground-recovery"];
}

#pragma mark - Runtime

- (void)loadRuntimePageForReason:(NSString *)reason
{
    if (self.recoveryInFlight || !self.webView) return;
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:self.filePath isDirectory:&directory] || directory) {
        [self presentRuntimeFailure:@"原办公文档已不存在。" allowRetry:NO];
        return;
    }

    self.recoveryInFlight = YES;
    self.documentRendered = NO;
    self.errorPresented = NO;
    NSURL *url = [NSURL URLWithString:@"ffoffice:///index.html"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    [self.webView loadRequest:request];
    FFLogTag(@"Office", @"runtime load reason=%@ path=%@", reason, self.filePath);
}

- (void)openDocumentInRuntime
{
    if (!self.webView) return;
    NSDictionary *payload = @{
        @"name": self.filePath.lastPathComponent ?: @"办公文档",
        @"state": self.lastState ?: (id)NSNull.null,
    };
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!jsonData) {
        self.recoveryInFlight = NO;
        [self presentRuntimeFailure:jsonError.localizedDescription ?: @"无法建立办公文档加载参数。"
            allowRetry:YES];
        return;
    }
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"window.FFOffice && window.FFOffice.open(%@);", json];
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        (void)result;
        if (!error) return;
        weakSelf.recoveryInFlight = NO;
        [weakSelf presentRuntimeFailure:error.localizedDescription ?: @"无法启动办公文档解析器。"
            allowRetry:YES];
    }];
}

#pragma mark - WKNavigationDelegate

- (void)webViewWebContentProcessDidTerminate:(__unused WKWebView *)webView
{
    self.webProcessTerminated = YES;
    self.needsForegroundRecovery = YES;
    self.recoveryInFlight = NO;
    self.documentRendered = NO;
    FFLogTag(@"Office", @"WebContent process terminated path=%@ state=%ld",
        self.filePath, (long)UIApplication.sharedApplication.applicationState);

    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        [self recoverWebContentIfVisible];
}

- (void)webView:(__unused WKWebView *)webView
    didFailNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    self.recoveryInFlight = NO;
    // -999 is a superseded load (e.g. manual reload while still loading), not
    // a user-visible failure.
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
        return;
    FFLogTag(@"Office", @"navigation failed path=%@ error=%@", self.filePath,
        error.localizedDescription ?: @"unknown");
    [self presentRuntimeFailure:error.localizedDescription ?: @"办公文档页面加载失败。"
        allowRetry:YES];
}

- (void)webView:(__unused WKWebView *)webView
    didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    self.recoveryInFlight = NO;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
        return;
    FFLogTag(@"Office", @"provisional navigation failed path=%@ error=%@", self.filePath,
        error.localizedDescription ?: @"unknown");
    [self presentRuntimeFailure:error.localizedDescription ?: @"办公文档页面加载失败。"
        allowRetry:YES];
}

- (void)webView:(__unused WKWebView *)webView
 decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (!url || [scheme isEqualToString:FFOfficeScheme] || [scheme isEqualToString:@"about"] ||
        [scheme isEqualToString:@"data"] || [scheme isEqualToString:@"blob"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

#pragma mark - JS bridge

- (void)userContentController:(__unused WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.name isEqualToString:@"ffOffice"] ||
        ![message.body isKindOfClass:NSDictionary.class]) return;

    NSDictionary *body = message.body;
    NSString *type = [body[@"type"] isKindOfClass:NSString.class] ? body[@"type"] : @"";
    if ([type isEqualToString:@"ready"]) {
        [self openDocumentInRuntime];
        return;
    }
    if ([type isEqualToString:@"state"]) {
        if ([body[@"state"] isKindOfClass:NSDictionary.class]) self.lastState = body[@"state"];
        return;
    }
    if ([type isEqualToString:@"link"]) {
        NSString *raw = [body[@"url"] isKindOfClass:NSString.class] ? body[@"url"] : nil;
        NSURL *url = raw.length ? [NSURL URLWithString:raw] : nil;
        NSString *scheme = url.scheme.lowercaseString;
        if (url && ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]))
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        return;
    }
    if ([type isEqualToString:@"quicklook"]) {
        [self openQuickLook];
        return;
    }
    if ([type isEqualToString:@"loaded"]) {
        self.recoveryInFlight = NO;
        self.webProcessTerminated = NO;
        self.needsForegroundRecovery = NO;
        self.documentRendered = YES;
        self.errorPresented = NO;
        FFLogTag(@"Office", @"rendered path=%@ mode=%@ ext=%@", self.filePath,
            body[@"mode"] ?: @"?", body[@"extension"] ?: @"?");
        return;
    }
    if ([type isEqualToString:@"error"]) {
        self.recoveryInFlight = NO;
        self.documentRendered = NO;
        NSString *detail = [body[@"message"] isKindOfClass:NSString.class]
            ? body[@"message"] : @"办公文档解析失败。";
        FFLogTag(@"Office", @"render failed path=%@ error=%@", self.filePath, detail);
        [self presentRuntimeFailure:detail allowRetry:YES];
    }
}

#pragma mark - Actions

- (void)configureMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *share = [UIAction actionWithTitle:@"分享原文件"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf shareFile]; }];
    UIAction *pdf = [UIAction actionWithTitle:@"导出 PDF"
        image:[UIImage systemImageNamed:@"doc.richtext"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf exportPDF]; }];
    UIAction *fit = [UIAction actionWithTitle:@"适应宽度"
        image:[UIImage systemImageNamed:@"arrow.left.and.right"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf fitDocumentToWidth]; }];
    UIAction *jump = [UIAction actionWithTitle:@"跳转到页…"
        image:[UIImage systemImageNamed:@"number"]
        identifier:@"office.jump" handler:^(__unused UIAction *action) {
            [weakSelf promptJumpToPage];
        }];
    UIAction *reload = [UIAction actionWithTitle:@"重新载入"
        image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf reloadManually]; }];
    UIAction *system = [UIAction actionWithTitle:@"系统快速查看"
        image:[UIImage systemImageNamed:@"eye"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf openQuickLook]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithTitle:@"" children:@[jump, share, pdf, fit, reload, system]]];
}

- (void)shareFile
{
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.filePath]] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)reloadManually
{
    // Capture first: navigating away can drop a pending evaluateJavaScript,
    // which would silently lose the reading position on reload.
    __weak typeof(self) weakSelf = self;
    [self captureRuntimeStateWithCompletion:^{
        weakSelf.needsForegroundRecovery = YES;
        weakSelf.recoveryInFlight = NO;
        [weakSelf recoverWebContentIfVisible];
    }];
}

- (void)fitDocumentToWidth
{
    if (!self.webView) return;
    [self.webView evaluateJavaScript:
        @"window.FFOffice && window.FFOffice.fit ? window.FFOffice.fit() : null;"
        completionHandler:nil];
}

// Captures the whole document (not just the visible part) as a PDF and hands
// it to the share sheet. WKWebView's print formatter only paginates onscreen
// content, so this uses the dedicated createPDF API over the full content
// rect instead.
- (void)exportPDF
{
    if (!self.webView) return;
    if (!self.documentRendered) {
        [self presentExportFailure:@"文档尚未渲染完成。"];
        return;
    }
    CGSize content = self.webView.scrollView.contentSize;
    CGSize bounds = self.webView.bounds.size;
    WKPDFConfiguration *configuration = [WKPDFConfiguration new];
    configuration.rect = CGRectMake(0, 0,
        MAX(content.width, bounds.width), MAX(content.height, bounds.height));
    __weak typeof(self) weakSelf = self;
    [self.webView createPDFWithConfiguration:configuration
        completionHandler:^(NSData *pdfData, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finishExportPDF:pdfData error:error];
            });
        }];
}

- (void)finishExportPDF:(NSData *)pdf error:(NSError *)error
{
    if (!pdf.length) {
        [self presentExportFailure:error.localizedDescription ?: @"没有可导出的内容。"];
        return;
    }
    NSString *base = self.filePath.lastPathComponent.stringByDeletingPathExtension;
    if (!base.length) base = @"document";
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"pdf"]];
    NSError *writeError = nil;
    if (![pdf writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        [self presentExportFailure:writeError.localizedDescription ?: @"写入 PDF 失败。"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
    FFLogTag(@"Office", @"exported pdf path=%@ bytes=%lu", self.filePath, (unsigned long)pdf.length);
}

- (void)presentExportFailure:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导出 PDF 失败"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开办公文档"
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

@end
