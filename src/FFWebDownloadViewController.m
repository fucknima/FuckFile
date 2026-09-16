#import "FFWebDownloadViewController.h"

#import <WebKit/WebKit.h>

#import "FFLogger.h"

static NSString * const FFWebDownloadTempPrefix = @".ffdownload-";

@interface FFWebDownloadViewController () <WKNavigationDelegate, WKDownloadDelegate,
                                            UITextFieldDelegate, WKUIDelegate>
@property(nonatomic, copy) NSString *destinationDirectory;
@property(nonatomic, strong, nullable) NSURL *initialURL;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UITextField *addressField;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UIBarButtonItem *backItem;
@property(nonatomic, strong) UIBarButtonItem *forwardItem;
@property(nonatomic, strong) UIBarButtonItem *reloadItem;
// download → {tempPath, suggestedName}，防止并发下载互相覆盖。
@property(nonatomic, strong) NSMutableDictionary<WKDownload *, NSMutableDictionary *> *downloads;
@end

@implementation FFWebDownloadViewController

- (instancetype)initWithDestinationDirectory:(NSString *)directory
{
    return [self initWithURL:nil destinationDirectory:directory];
}

- (instancetype)initWithURL:(NSURL *)url destinationDirectory:(NSString *)directory
{
    self = [super init];
    if (self) {
        _destinationDirectory = [directory copy];
        _downloads = [NSMutableDictionary dictionary];
        self.title = @"网页下载";
        if (url) _initialURL = url;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    // 顶部：地址栏 + 前进/后退/刷新。
    self.addressField = [[UITextField alloc] init];
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.addressField.placeholder = @"输入网址，可直接登录后下载";
    self.addressField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.addressField.delegate = self;
    self.addressField.frame = CGRectMake(0, 0, 240, 32);
    // 直接做导航栏标题视图，省掉一条自绘栏位。
    self.navigationItem.titleView = self.addressField;

    self.backItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.left"]
        style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
    self.forwardItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"]
        style:UIBarButtonItemStylePlain target:self action:@selector(goForward)];
    self.reloadItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain target:self action:@selector(reloadPage)];
    self.navigationItem.leftBarButtonItems = @[ self.backItem, self.forwardItem, self.reloadItem ];
    self.reloadItem.accessibilityLabel = @"刷新";

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:
        UIProgressViewStyleBar];
    self.progressView.progress = 0;
    self.progressView.hidden = YES;
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // 共享默认数据存储：登录 Cookie 会持久化，与 Web Viewer 共用同一份。
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];
    [self.view addSubview:self.progressView];

    [NSLayoutConstraint activateConstraints:@[
        [self.progressView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self.webView addObserver:self forKeyPath:@"estimatedProgress"
        options:NSKeyValueObservingOptionNew context:NULL];
    [self.webView addObserver:self forKeyPath:@"title"
        options:NSKeyValueObservingOptionNew context:NULL];

    if (self.initialURL) {
        [self loadURL:self.initialURL];
    } else {
        [self updateNavigationState];
    }
}

- (void)dealloc
{
    [self.webView removeObserver:self forKeyPath:@"estimatedProgress"];
    [self.webView removeObserver:self forKeyPath:@"title"];
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    // 未完成的下载也要摘掉 KVO，否则 NSProgress 会回调已释放的观察者。
    @synchronized (self.downloads) {
        for (WKDownload *download in self.downloads.allKeys) {
            @try {
                [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            } @catch (__unused NSException *exception) {}
        }
        [self.downloads removeAllObjects];
    }
}

// 登录常见于 popup / target=_blank：没有第二窗口，直接在当前 WebView 打开。
- (nullable WKWebView *)webView:(nullable WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures
{
    (void)configuration;
    (void)windowFeatures;
    if (navigationAction.targetFrame == nil && navigationAction.request.URL)
        [self.webView loadRequest:navigationAction.request];
    return nil;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // 离开页面时未完成的下载会被系统取消（WebView 即将释放），
    // 已明确的临时文件在这里清掉，不留下半成品。
    if (!self.isMovingFromParentViewController || self.downloads.count == 0) return;
    FFLogTag(@"WebDownload", @"leaving page with %lu active download(s)",
        (unsigned long)self.downloads.count);
    [self.webView stopLoading];
}

#pragma mark - Address bar

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    // 编辑时给完整 URL，方便修改路径或参数。
    if (self.webView.URL.absoluteString.length) textField.text = self.webView.URL.absoluteString;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    NSString *raw = [textField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!raw.length) return YES;
    if (!raw.pathExtension.length && ![raw containsString:@"."]) { /* 交给 URL 解析 */ }
    NSURLComponents *components = [NSURLComponents componentsWithString:raw];
    if (!components.scheme.length) components.scheme = @"https";
    NSURL *url = components.URL;
    if (!url) {
        [self flash:@"无法识别的网址"];
        return YES;
    }
    [self loadURL:url];
    return YES;
}

- (void)loadURL:(NSURL *)url
{
    FFLogTag(@"WebDownload", @"load url=%@", url.absoluteString);
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)goBack { if (self.webView.canGoBack) [self.webView goBack]; }
- (void)goForward { if (self.webView.canGoForward) [self.webView goForward]; }
- (void)reloadPage { [self.webView reload]; }

- (void)updateNavigationState
{
    self.backItem.enabled = self.webView.canGoBack;
    self.forwardItem.enabled = self.webView.canGoForward;
    if (!self.addressField.isFirstResponder)
        self.addressField.text = self.webView.URL.absoluteString ?: @"";
}

#pragma mark - Progress

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object == self.webView && [keyPath isEqualToString:@"estimatedProgress"]) {
            CGFloat progress = [change[NSKeyValueChangeNewKey] floatValue];
            [self.progressView setProgress:progress animated:YES];
            self.progressView.hidden = progress >= 1.0;
            return;
        }
        if (object == self.webView && [keyPath isEqualToString:@"title"]) return;
        if ([object isKindOfClass:NSProgress.class]) {
            NSProgress *progress = (NSProgress *)object;
            [self.progressView setProgress:progress.fractionCompleted animated:YES];
            return;
        }
    });
}

#pragma mark - Navigation

- (void)webView:(WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation
{
    [self updateNavigationState];
    [self.progressView setProgress:0 animated:NO];
    self.progressView.hidden = YES;
    if (webView.title.length && ![webView.title isEqualToString:@"网页下载"])
        self.title = webView.title;
}

- (void)webView:(__unused WKWebView *)webView didFailProvisionalNavigation:(__unused WKNavigation *)navigation
      withError:(NSError *)error
{
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    FFLogTag(@"WebDownload", @"navigation FAIL %@", error);
    [self updateNavigationState];
    [self flash:[NSString stringWithFormat:@"加载失败：%@",
        error.localizedDescription ?: @"未知错误"]];
}

- (void)webView:(__unused WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                        preferences:(WKWebpagePreferences *)preferences
                    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    if (navigationAction.shouldPerformDownload) {
        decisionHandler(WKNavigationActionPolicyDownload, preferences);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow, preferences);
}

- (void)webView:(__unused WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    decisionHandler(navigationResponse.canShowMIMEType
        ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}

- (nullable WKDownload *)webView:(__unused WKWebView *)webView
          navigationAction:(WKNavigationAction *)navigationAction
        didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;
    FFLogTag(@"WebDownload", @"action download %@", navigationAction.request.URL.absoluteString);
    return download;
}

- (nullable WKDownload *)webView:(__unused WKWebView *)webView
        navigationResponse:(WKNavigationResponse *)navigationResponse
        didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;
    FFLogTag(@"WebDownload", @"response download %@", navigationResponse.response.URL.absoluteString);
    return download;
}

#pragma mark - WKDownloadDelegate

- (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
                 suggestedFilename:(NSString *)suggestedFilename
               completionHandler:(void (^)(NSURL * _Nullable))completionHandler
{
    NSString *name = suggestedFilename.length ? suggestedFilename : @"下载文件";
    NSString *directory = self.destinationDirectory;
    if (!directory.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:directory]) {
        directory = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    }
    NSString *tempPath = [directory stringByAppendingPathComponent:
        [FFWebDownloadTempPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    // 先写临时文件，完成后才按重名规则 rename 成最终名（原子提交）。
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"temp"] = tempPath;
    record[@"name"] = name;
    record[@"directory"] = directory;
    @synchronized (self.downloads) { self.downloads[download] = record; }

    [download.progress addObserver:self forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionNew context:NULL];
    FFLogTag(@"WebDownload", @"begin name=%@ dir=%@", name, directory.lastPathComponent);
    completionHandler([NSURL fileURLWithPath:tempPath]);
}

- (void)downloadDidFinish:(WKDownload *)download
{
    NSMutableDictionary *record = nil;
    @synchronized (self.downloads) {
        record = self.downloads[download];
        [self.downloads removeObjectForKey:download];
    }
    @try { [download.progress removeObserver:self forKeyPath:@"fractionCompleted"]; } @catch (__unused NSException *exception) {}

    NSString *tempPath = record[@"temp"];
    NSString *name = record[@"name"] ?: @"下载文件";
    NSString *directory = record[@"directory"];
    if (!tempPath.length || !directory.length) return;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *destination = [self uniqueDestinationForName:name inDirectory:directory];
    NSError *error = nil;
    if (!destination ||
        ![manager moveItemAtPath:tempPath toPath:destination error:&error]) {
        [manager removeItemAtPath:tempPath error:nil];
        FFLogTag(@"WebDownload", @"commit FAIL %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self flash:[NSString stringWithFormat:@"保存失败：%@",
                error.localizedDescription ?: @"无法写入目标目录"]];
        });
        return;
    }
    FFLogTag(@"WebDownload", @"saved %@", destination.lastPathComponent);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressView.hidden = YES;
        [self flash:[NSString stringWithFormat:@"已保存：%@",
            destination.lastPathComponent]];
    });
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error
      resumeData:(nullable NSData *)resumeData
{
    (void)resumeData;
    NSMutableDictionary *record = nil;
    @synchronized (self.downloads) {
        record = self.downloads[download];
        [self.downloads removeObjectForKey:download];
    }
    @try { [download.progress removeObserver:self forKeyPath:@"fractionCompleted"]; } @catch (__unused NSException *exception) {}
    NSString *tempPath = record[@"temp"];
    if (tempPath.length) [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
    if (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) {
        FFLogTag(@"WebDownload", @"cancelled");
        return;
    }
    FFLogTag(@"WebDownload", @"download FAIL %@", error);
    [self flash:[NSString stringWithFormat:@"下载失败：%@",
        error.localizedDescription ?: @"未知错误"]];
}

- (NSString *)uniqueDestinationForName:(NSString *)name inDirectory:(NSString *)directory
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![manager fileExistsAtPath:candidate]) return candidate;
    NSString *stem = name.stringByDeletingPathExtension.length
        ? name.stringByDeletingPathExtension : name;
    NSString *extension = name.pathExtension;
    for (NSUInteger index = 2; index < 10000; index++) {
        NSString *indexed = [NSString stringWithFormat:@"%@ (%lu)", stem, (unsigned long)index];
        if (extension.length) indexed = [indexed stringByAppendingPathExtension:extension];
        candidate = [directory stringByAppendingPathComponent:indexed];
        if (![manager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

#pragma mark - Helpers

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
