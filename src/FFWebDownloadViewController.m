#import "FFWebDownloadViewController.h"

#import <WebKit/WebKit.h>

#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFLogger.h"
#import "FFTasksViewController.h"

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

@interface FFWebDownloadViewController () <WKNavigationDelegate, WKUIDelegate,
                                            UITextFieldDelegate>
@property(nonatomic, copy) NSString *destinationDirectory;
@property(nonatomic, strong, nullable) NSURL *initialURL;
@property(nonatomic, strong, nullable) NSURL *lastPageURL;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UITextField *addressField;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UIView *bottomChrome;
@property(nonatomic, strong) UIButton *backButton;
@property(nonatomic, strong) UIButton *forwardButton;
@property(nonatomic, strong) UIButton *reloadButton;
@property(nonatomic, strong) UIButton *safariButton;
@property(nonatomic, strong) UIButton *downloadBar;
@property(nonatomic, strong) NSLayoutConstraint *downloadBarHeight;
@property(nonatomic, strong) UIBarButtonItem *downloadsItem;
// 只统计本页面发起的下载：任务中心还混着别的任务，状态条不能跟着跑。
@property(nonatomic, strong) NSMutableArray<FFFileTask *> *sessionDownloads;
// 连续崩溃计数：坏页面反复杀死 WebContent 时停止自动重载。
@property(nonatomic) NSInteger webContentCrashCount;
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
        _sessionDownloads = [NSMutableArray array];
        self.title = @"网页下载";
        // 必须 push 前设置：否则根 tab bar（文件/设置）压在下工具条上。
        self.hidesBottomBarWhenPushed = YES;
        if (url) _initialURL = url;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

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

    // 下载提示条：本页面的下载都进任务中心，这行是页内唯一入口。
    self.downloadBar = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadBar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.downloadBar.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.downloadBar.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.downloadBar.clipsToBounds = YES;
    [self.downloadBar addTarget:self action:@selector(openTasks)
        forControlEvents:UIControlEventTouchUpInside];
    self.downloadBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.downloadBar];

    [self buildBottomChrome];

    self.downloadsItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]
        style:UIBarButtonItemStylePlain target:self action:@selector(openTasks)];
    self.downloadsItem.accessibilityLabel = @"下载任务";
    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
        style:UIBarButtonItemStylePlain target:self action:@selector(shareLink)];
    shareItem.accessibilityLabel = @"分享链接";
    self.navigationItem.rightBarButtonItems = @[ self.downloadsItem, shareItem ];

    self.downloadBarHeight = [self.downloadBar.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.progressView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.downloadBar.topAnchor],
        [self.downloadBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.downloadBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.downloadBar.bottomAnchor constraintEqualToAnchor:self.bottomChrome.topAnchor],
        self.downloadBarHeight,
    ]];

    [self.webView addObserver:self forKeyPath:@"estimatedProgress"
        options:NSKeyValueObservingOptionNew context:NULL];
    [self.webView addObserver:self forKeyPath:@"title"
        options:NSKeyValueObservingOptionNew context:NULL];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(taskManagerChanged:)
        name:FFFileTaskManagerDidChangeNotification object:nil];

    if (self.initialURL) {
        [self loadURL:self.initialURL];
    } else {
        [self updateNavigationState];
    }
    [self refreshDownloadBar];
}

- (void)dealloc
{
    [self.webView removeObserver:self forKeyPath:@"estimatedProgress"];
    [self.webView removeObserver:self forKeyPath:@"title"];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
}

// Safari 式底部工具条：地址栏居中，后退/前进/刷新/在 Safari 打开在两侧。
// 自绘而不是用 UIToolbar：系统 bar 会给 customView 装 required 约束，
// 与自定义宽高互斥（真机 #888 就在激活约束时崩过）。自绘完全走 Auto Layout。
- (void)buildBottomChrome
{
    self.bottomChrome = [UIView new];
    self.bottomChrome.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.bottomChrome.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bottomChrome];

    UIView *separator = [UIView new];
    separator.backgroundColor = UIColor.separatorColor;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomChrome addSubview:separator];

    self.addressField = [[UITextField alloc] init];
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.addressField.placeholder = @"输入网址，登录后下载";
    self.addressField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
    self.addressField.delegate = self;
    [self.addressField setContentHuggingPriority:UILayoutPriorityDefaultLow
        forAxis:UILayoutConstraintAxisHorizontal];
    [self.addressField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
        forAxis:UILayoutConstraintAxisHorizontal];
    UIImageView *globe = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"globe"]];
    globe.tintColor = UIColor.secondaryLabelColor;
    globe.contentMode = UIViewContentModeCenter;
    globe.frame = CGRectMake(0, 0, 28, 20);
    self.addressField.leftView = globe;
    self.addressField.leftViewMode = UITextFieldViewModeAlways;

    self.backButton = [self chromeButtonWithSymbol:@"chevron.left" label:@"后退"
        action:@selector(goBack)];
    self.forwardButton = [self chromeButtonWithSymbol:@"chevron.right" label:@"前进"
        action:@selector(goForward)];
    self.reloadButton = [self chromeButtonWithSymbol:@"arrow.clockwise" label:@"刷新"
        action:@selector(reloadPage)];
    self.safariButton = [self chromeButtonWithSymbol:@"safari" label:@"在 Safari 打开"
        action:@selector(openInSafari)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.backButton, self.forwardButton, self.addressField,
        self.reloadButton, self.safariButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    [self.bottomChrome addSubview:stack];

    // 底栏背景钉在屏幕底（键盘弹起时被键盘盖住的部分不可见），内容行
    // 跟随 keyboardLayoutGuide：收起时 guide 顶 = 安全区底（地址栏照旧在
    // Home Indicator 上方），弹起时 guide 顶 = 键盘顶，整行被顶到键盘上
    // 方，输入框不再被挡。不用 usesBottomSafeArea（iOS 17+）：它默认就是
    // true（guide 收起时贴 safeArea 底），正好是这里要的行为。
    [NSLayoutConstraint activateConstraints:@[
        [self.bottomChrome.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomChrome.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomChrome.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.bottomChrome.topAnchor constraintEqualToAnchor:stack.topAnchor constant:-8],
        [separator.topAnchor constraintEqualToAnchor:self.bottomChrome.topAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:self.bottomChrome.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.bottomChrome.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [stack.leadingAnchor constraintEqualToAnchor:self.bottomChrome.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.bottomChrome.trailingAnchor constant:-12],
        [stack.heightAnchor constraintEqualToConstant:40],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor
            constant:-8],
        [self.addressField.heightAnchor constraintEqualToConstant:34],
    ]];
}

- (UIButton *)chromeButtonWithSymbol:(NSString *)symbol
                               label:(NSString *)label
                              action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:40].active = YES;
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    return button;
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
    if (!url && self.addressField.text.length) url = [NSURL URLWithString:self.addressField.text];
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
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)updateNavigationState
{
    self.backButton.enabled = self.webView.canGoBack;
    self.forwardButton.enabled = self.webView.canGoForward;
    self.reloadButton.enabled = self.webView.URL != nil;
    self.safariButton.enabled = self.webView.URL != nil || self.addressField.text.length > 0;
    if (self.webView.URL) self.lastPageURL = self.webView.URL;
    if (!self.addressField.isFirstResponder)
        self.addressField.text = self.webView.URL.absoluteString ?: @"";
}

#pragma mark - Progress

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context
{
    (void)context;
    if (object == self.webView && [keyPath isEqualToString:@"title"]) {
        NSString *title = change[NSKeyValueChangeNewKey];
        if ([title isKindOfClass:NSString.class] && title.length) self.title = title;
        return;
    }
    if (object == self.webView && [keyPath isEqualToString:@"estimatedProgress"]) {
        CGFloat progress = [change[NSKeyValueChangeNewKey] floatValue];
        self.progressView.hidden = progress >= 1.0;
        [self.progressView setProgress:progress animated:YES];
    }
}

#pragma mark - Navigation

- (void)webView:(__unused WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation
{
    [self updateNavigationState];
    self.progressView.hidden = YES;
    [self.progressView setProgress:0 animated:NO];
    self.webContentCrashCount = 0;
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    self.webContentCrashCount += 1;
    FFLogTag(@"WebDownload", @"WebContent process terminated count=%ld",
        (long)self.webContentCrashCount);
    // 页面进程被回收后只会白屏：自动重载，但坏页面反复崩溃要停手。
    if (self.webContentCrashCount > 3) {
        [self flash:@"网页渲染进程反复崩溃，已停止自动重载"];
        return;
    }
    [webView reload];
}

- (void)webView:(__unused WKWebView *)webView
    didFailProvisionalNavigation:(__unused WKNavigation *)navigation
                       withError:(NSError *)error
{
    if (FFWebDownloadIsBenignNavigationError(error)) {
        // 转下载/被策略取消：进度条不能卡在半截。
        self.progressView.hidden = YES;
        [self.progressView setProgress:0 animated:NO];
        return;
    }
    FFLogTag(@"WebDownload", @"navigation FAIL %@", error);
    [self updateNavigationState];
    [self flash:[NSString stringWithFormat:@"加载失败：%@",
        error.localizedDescription ?: @"未知错误"]];
}

- (void)webView:(__unused WKWebView *)webView
    didFailNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    if (FFWebDownloadIsBenignNavigationError(error)) {
        self.progressView.hidden = YES;
        [self.progressView setProgress:0 animated:NO];
        return;
    }
    [self updateNavigationState];
}

// 导航本身要求下载（download 属性）：不让 WebKit 下载，把请求（含
// Cookie/Referer/方法体）交给统一任务系统，任务中心可见。
- (void)webView:(__unused WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                        preferences:(WKWebpagePreferences *)preferences
                    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    if (navigationAction.shouldPerformDownload) {
        decisionHandler(WKNavigationActionPolicyCancel, preferences);
        [self enqueueDownloadForRequest:navigationAction.request];
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow, preferences);
}

// 导航先被放行、响应阶段才发现不可显示：取消展示，用 GET 交给任务系统。
// WKNavigationResponse 没有 shouldPerformDownload（只有 action 有），是否
// 附件要看 Content-Disposition；MIME 不可显示（zip/ipa 等）同样转下载。
- (void)webView:(__unused WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    // 子 frame 的响应同样会走到这里：只有主框架才能整页转下载，
    // 否则 iframe 里的附件会把主页面顶掉。
    if (!navigationResponse.isForMainFrame) {
        decisionHandler(WKNavigationResponsePolicyAllow);
        return;
    }
    if (!navigationResponse.canShowMIMEType ||
        [self responseIsAttachment:navigationResponse.response]) {
        decisionHandler(WKNavigationResponsePolicyCancel);
        NSURL *url = navigationResponse.response.URL;
        if (!url) return;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"GET";
        [self enqueueDownloadForRequest:request];
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (BOOL)responseIsAttachment:(NSURLResponse *)response
{
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return NO;
    NSDictionary *headers = ((NSHTTPURLResponse *)response).allHeaderFields;
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:@"Content-Disposition"] != NSOrderedSame) continue;
        NSString *value = [headers[key] description].lowercaseString;
        return [value containsString:@"attachment"];
    }
    return NO;
}

#pragma mark - Download hand-off

// WebKit 的下载只能在页面活着时进行；统一改由任务系统执行，
// 这样离开页面/切后台下载都继续，且任务中心能取消、重试、断点续传。
- (void)enqueueDownloadForRequest:(NSURLRequest *)request
{
    NSURL *url = request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        [self presentUnsupportedDownloadAlert];
        return;
    }

    NSMutableURLRequest *prepared = [request mutableCopy];
    if (!prepared.HTTPMethod.length) prepared.HTTPMethod = @"GET";
    // body 不可重放的 POST（HTTPBodyStream）降级为 GET：多数附件接口是 GET，
    // 少数失败的会进任务中心，用户可以改用 Safari。
    if ([prepared.HTTPMethod isEqualToString:@"POST"] && !prepared.HTTPBody) {
        FFLogTag(@"WebDownload", @"POST body not replayable, falling back to GET url=%@",
            url.absoluteString);
        prepared.HTTPMethod = @"GET";
    }
    if (![prepared valueForHTTPHeaderField:@"Referer"]) {
        NSURL *referer = self.webView.URL ?: self.lastPageURL;
        if (referer.absoluteString.length)
            [prepared setValue:referer.absoluteString forHTTPHeaderField:@"Referer"];
    }
    if (![prepared valueForHTTPHeaderField:@"User-Agent"] && self.webView.customUserAgent.length)
        [prepared setValue:self.webView.customUserAgent forHTTPHeaderField:@"User-Agent"];

    // Cookie 由 WebKit 网络进程管理，导航请求里不一定带全，统一从共享
    // CookieStore 取一份合并，登录态才能被 NSURLSession 复用。回调线程不
    // 确定，回到主线程再建任务（任务中心的通知也走主线程，状态不跨线程）。
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startDownloadForRequest:prepared cookies:cookies];
        });
    }];
}

- (void)startDownloadForRequest:(NSMutableURLRequest *)request
                        cookies:(NSArray<NSHTTPCookie *> *)cookies
{
    NSURL *url = request.URL;
    if (!url) return;
    NSMutableArray<NSHTTPCookie *> *matched = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies)
        if ([self cookie:cookie matchesURL:url]) [matched addObject:cookie];
    if (matched.count) {
        NSDictionary *fields = [NSHTTPCookie requestHeaderFieldsWithCookies:matched];
        NSString *header = fields[@"Cookie"];
        if (header.length) [request setValue:header forHTTPHeaderField:@"Cookie"];
    }

    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindDownload;
    task.remoteURL = url.absoluteString;
    task.destination = [self.destinationDirectory copy];
    task.requestHeaders = request.allHTTPHeaderFields;
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : url.host;
    task.displayName = name.length ? [NSString stringWithFormat:@"下载 %@", name] : @"下载文件";
    [self.sessionDownloads addObject:task];
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    FFLogTag(@"WebDownload", @"handed to task centre url=%@ headers=%lu",
        url.absoluteString, (unsigned long)task.requestHeaders.count);
    [self refreshDownloadBar];
}

- (BOOL)cookie:(NSHTTPCookie *)cookie matchesURL:(NSURL *)url
{
    if (cookie.isSecure && ![[url.scheme lowercaseString] isEqualToString:@"https"]) return NO;
    NSString *host = url.host.lowercaseString;
    NSString *domain = cookie.domain.lowercaseString;
    if (!host.length || !domain.length) return YES;
    if ([host isEqualToString:domain]) return YES;
    NSString *suffix = [domain hasPrefix:@"."] ? domain : [@"." stringByAppendingString:domain];
    return [host hasSuffix:suffix];
}

- (void)presentUnsupportedDownloadAlert
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法接管这种下载"
        message:@"页面用脚本生成的内容（blob/内联数据）只能在网页里完成。可以在 Safari 里打开本页再下载。"
        preferredStyle:UIAlertControllerStyleAlert];
    NSURL *pageURL = self.webView.URL ?: self.lastPageURL;
    if (pageURL) {
        [alert addAction:[UIAlertAction actionWithTitle:@"在 Safari 打开"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [UIApplication.sharedApplication openURL:pageURL options:@{} completionHandler:nil];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Download status bar

- (void)taskManagerChanged:(NSNotification *)note
{
    (void)note;
    if (NSThread.isMainThread) [self refreshDownloadBar];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self refreshDownloadBar]; });
}

- (void)refreshDownloadBar
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshDownloadBar]; });
        return;
    }
    NSArray<FFFileTask *> *all = [FFFileTaskManager sharedManager].tasks;
    NSUInteger active = 0;
    BOOL unfinished = NO;
    for (FFFileTask *task in self.sessionDownloads) {
        if (![all containsObject:task]) continue;
        if (task.state == FFFileTaskStateQueued || task.state == FFFileTaskStateRunning) active++;
        else if (task.state == FFFileTaskStateFailed) unfinished = YES;
    }

    if (active == 0 && !unfinished) {
        self.downloadBarHeight.constant = 0;
        self.downloadBar.hidden = YES;
    } else {
        self.downloadBar.hidden = NO;
        self.downloadBarHeight.constant = 34;
        NSString *title = active > 0 ? (active == 1 ? @"正在下载… 查看任务"
            : [NSString stringWithFormat:@"正在下载 %lu 项 · 查看任务", (unsigned long)active])
            : @"有下载未完成 · 查看任务";
        [self.downloadBar setTitle:title forState:UIControlStateNormal];
    }
    self.downloadsItem.image = [UIImage systemImageNamed:(active > 0
        ? @"arrow.down.circle.fill" : @"arrow.down.circle")];
}

- (void)openTasks
{
    FFTasksViewController *tasks = [FFTasksViewController new];
    [self.navigationController pushViewController:tasks animated:YES];
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
