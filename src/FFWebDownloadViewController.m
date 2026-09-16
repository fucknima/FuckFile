#import "FFWebDownloadViewController.h"

#import <WebKit/WebKit.h>

#import "FFLogger.h"

static NSString * const FFWebDownloadTempPrefix = @".ffdownload-";

// WebKit 把「导航变成下载」当成一次策略中断（Frame load interrupted by
// policy change，102）；它代表下载已经开始，不是错误。
static BOOL FFWebDownloadIsBenignNavigationError(NSError *error)
{
    if (!error) return YES;
    if ([error.domain isEqualToString:NSURLErrorDomain] &&
        error.code == NSURLErrorCancelled) return YES;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return YES;
    return NO;
}

@interface FFWebDownloadViewController () <WKNavigationDelegate, WKDownloadDelegate,
                                            UITextFieldDelegate, WKUIDelegate>
@property(nonatomic, copy) NSString *destinationDirectory;
@property(nonatomic, strong, nullable) NSURL *initialURL;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UITextField *addressField;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UIToolbar *bottomBar;
@property(nonatomic, strong) UIBarButtonItem *backItem;
@property(nonatomic, strong) UIBarButtonItem *forwardItem;
@property(nonatomic, strong) UIBarButtonItem *reloadItem;
@property(nonatomic, strong) UIBarButtonItem *safariItem;
// 进行中的下载记录（download/temp/name/directory）。WKDownload 不是
// NSCopying，不能做字典 key，用数组 + 指针比较，量级只有个位数。
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *downloads;
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
        _downloads = [NSMutableArray array];
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

    // 地址栏独占一行（导航栏只留标题与分享），不再和前进/后退挤在一起。
    self.addressField = [[UITextField alloc] init];
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.addressField.placeholder = @"输入网址，登录后下载";
    self.addressField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.addressField.delegate = self;
    UIImageView *globe = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"globe"]];
    globe.tintColor = UIColor.secondaryLabelColor;
    globe.contentMode = UIViewContentModeCenter;
    globe.frame = CGRectMake(0, 0, 30, 22);
    self.addressField.leftView = globe;
    self.addressField.leftViewMode = UITextFieldViewModeAlways;
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.addressField];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressView.progress = 0;
    self.progressView.hidden = YES;
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progressView];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // 共享默认数据存储：登录 Cookie 会持久化，与 Web Viewer 共用同一份。
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    // 浏览器式底部工具条：后退/前进/刷新 + 在 Safari 打开。
    self.bottomBar = [[UIToolbar alloc] init];
    self.bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.backItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.left"]
        style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
    self.backItem.accessibilityLabel = @"后退";
    self.forwardItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"]
        style:UIBarButtonItemStylePlain target:self action:@selector(goForward)];
    self.forwardItem.accessibilityLabel = @"前进";
    self.reloadItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain target:self action:@selector(reloadPage)];
    self.reloadItem.accessibilityLabel = @"刷新";
    self.safariItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"safari"]
        style:UIBarButtonItemStylePlain target:self action:@selector(openInSafari)];
    self.safariItem.accessibilityLabel = @"在 Safari 打开";
    UIBarButtonItem *flexA = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *flexB = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    [self.bottomBar setItems:@[ self.backItem, self.forwardItem, self.reloadItem,
                                flexA, self.safariItem, flexB ] animated:NO];
    [self.view addSubview:self.bottomBar];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
        style:UIBarButtonItemStylePlain target:self action:@selector(shareLink)];

    [NSLayoutConstraint activateConstraints:@[
        [self.addressField.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
            constant:8],
        [self.addressField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
            constant:12],
        [self.addressField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
            constant:-12],
        [self.addressField.heightAnchor constraintEqualToConstant:38],
        [self.progressView.topAnchor constraintEqualToAnchor:self.addressField.bottomAnchor
            constant:6],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.bottomBar.topAnchor],
        [self.bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
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
        for (NSMutableDictionary *record in self.downloads) {
            WKDownload *download = record[@"download"];
            @try {
                [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            } @catch (__unused NSException *exception) {}
        }
        [self.downloads removeAllObjects];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (!self.isMovingFromParentViewController || self.downloads.count == 0) return;
    FFLogTag(@"WebDownload", @"leaving page with %lu active download(s)",
        (unsigned long)self.downloads.count);
    [self.webView stopLoading];
}

// 登录常见于 popup / target=_blank：没有第二窗口，直接在当前 WebView 打开。
- (nullable WKWebView *)webView:(WKWebView *)webView
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

#pragma mark - Address bar

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    if (self.webView.URL.absoluteString.length) textField.text = self.webView.URL.absoluteString;
    [textField selectAll:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    NSString *raw = [textField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!raw.length) return YES;
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

- (void)openInSafari
{
    NSURL *url = self.webView.URL;
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)shareLink
{
    NSURL *url = self.webView.URL;
    if (!url) {
        [self flash:@"先打开一个网页再分享"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)updateNavigationState
{
    self.backItem.enabled = self.webView.canGoBack;
    self.forwardItem.enabled = self.webView.canGoForward;
    self.safariItem.enabled = self.webView.URL != nil;
    if (!self.addressField.isFirstResponder)
        self.addressField.text = self.webView.URL.absoluteString ?: @"";
}

#pragma mark - Progress

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context
{
    (void)context;
    // NSProgress 的 KVO 可能来自后台线程，UI 分支统一回主线程。
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        });
        return;
    }
    if (object == self.webView && [keyPath isEqualToString:@"title"]) {
        NSString *title = change[NSKeyValueChangeNewKey];
        if ([title isKindOfClass:NSString.class] && title.length) self.title = title;
        return;
    }
    if (object == self.webView && [keyPath isEqualToString:@"estimatedProgress"]) {
        CGFloat progress = [change[NSKeyValueChangeNewKey] floatValue];
        self.progressView.hidden = progress >= 1.0;
        [self.progressView setProgress:progress animated:YES];
        return;
    }
    if ([keyPath isEqualToString:@"fractionCompleted"] && [object isKindOfClass:NSProgress.class]) {
        NSProgress *progress = (NSProgress *)object;
        self.progressView.hidden = progress.fractionCompleted >= 1.0;
        [self.progressView setProgress:progress.fractionCompleted animated:YES];
    }
}

#pragma mark - Navigation

- (void)webView:(__unused WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation
{
    [self updateNavigationState];
    self.progressView.hidden = YES;
    [self.progressView setProgress:0 animated:NO];
}

- (void)webView:(__unused WKWebView *)webView
    didFailProvisionalNavigation:(__unused WKNavigation *)navigation
                       withError:(NSError *)error
{
    if (FFWebDownloadIsBenignNavigationError(error)) return;
    FFLogTag(@"WebDownload", @"navigation FAIL %@", error);
    [self updateNavigationState];
    [self flash:[NSString stringWithFormat:@"加载失败：%@",
        error.localizedDescription ?: @"未知错误"]];
}

- (void)webView:(__unused WKWebView *)webView
    didFailNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    if (FFWebDownloadIsBenignNavigationError(error)) return;
    [self updateNavigationState];
}

- (void)webView:(__unused WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                        preferences:(WKWebpagePreferences *)preferences
                    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    decisionHandler(navigationAction.shouldPerformDownload
        ? WKNavigationActionPolicyDownload : WKNavigationActionPolicyAllow, preferences);
}

- (void)webView:(__unused WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    decisionHandler(navigationResponse.canShowMIMEType
        ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}

- (void)webView:(__unused WKWebView *)webView
    navigationAction:(WKNavigationAction *)navigationAction
  didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;
    FFLogTag(@"WebDownload", @"action download %@", navigationAction.request.URL.absoluteString);
}

- (void)webView:(__unused WKWebView *)webView
    navigationResponse:(WKNavigationResponse *)navigationResponse
  didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;
    FFLogTag(@"WebDownload", @"response download %@", navigationResponse.response.URL.absoluteString);
}

#pragma mark - WKDownloadDelegate

- (nullable NSMutableDictionary *)recordForDownload:(WKDownload *)download
{
    for (NSMutableDictionary *record in self.downloads)
        if (record[@"download"] == download) return record;
    return nil;
}

- (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
                 suggestedFilename:(NSString *)suggestedFilename
               completionHandler:(void (^)(NSURL * _Nullable))completionHandler
{
    NSString *name = suggestedFilename.length ? suggestedFilename : @"下载文件";
    NSString *directory = self.destinationDirectory;
    if (!directory.length || ![NSFileManager.defaultManager fileExistsAtPath:directory]) {
        directory = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    }
    // 先写临时文件，完成后才按重名规则 rename 成最终名（原子提交）。
    NSString *tempPath = [directory stringByAppendingPathComponent:
        [FFWebDownloadTempPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"download"] = download;
    record[@"temp"] = tempPath;
    record[@"name"] = name;
    record[@"directory"] = directory;
    @synchronized (self.downloads) { [self.downloads addObject:record]; }
    [download.progress addObserver:self forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionNew context:NULL];
    FFLogTag(@"WebDownload", @"begin name=%@ dir=%@", name, directory.lastPathComponent);
    completionHandler([NSURL fileURLWithPath:tempPath]);
}

- (void)downloadDidFinish:(WKDownload *)download
{
    NSMutableDictionary *record = nil;
    @synchronized (self.downloads) {
        record = [self recordForDownload:download];
        if (record) [self.downloads removeObject:record];
    }
    @try {
        [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (__unused NSException *exception) {}

    NSString *tempPath = record[@"temp"];
    NSString *name = record[@"name"] ?: @"下载文件";
    NSString *directory = record[@"directory"];
    if (!tempPath.length || !directory.length) return;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *destination = [self uniqueDestinationForName:name inDirectory:directory];
    NSError *error = nil;
    if (!destination || ![manager moveItemAtPath:tempPath toPath:destination error:&error]) {
        [manager removeItemAtPath:tempPath error:nil];
        FFLogTag(@"WebDownload", @"commit FAIL %@", error);
        [self flash:[NSString stringWithFormat:@"保存失败：%@",
            error.localizedDescription ?: @"无法写入目标目录"]];
        return;
    }
    FFLogTag(@"WebDownload", @"saved %@", destination.lastPathComponent);
    self.progressView.hidden = YES;
    [self flash:[NSString stringWithFormat:@"已保存：%@", destination.lastPathComponent]];
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error
      resumeData:(nullable NSData *)resumeData
{
    (void)resumeData;
    NSMutableDictionary *record = nil;
    @synchronized (self.downloads) {
        record = [self recordForDownload:download];
        if (record) [self.downloads removeObject:record];
    }
    @try {
        [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (__unused NSException *exception) {}
    NSString *tempPath = record[@"temp"];
    if (tempPath.length) [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
    if (FFWebDownloadIsBenignNavigationError(error)) {
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
