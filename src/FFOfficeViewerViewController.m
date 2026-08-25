#import "FFOfficeViewerViewController.h"

#import "FFQuickLookViewController.h"
#import "FFViewerRegistry.h"
#import "FFFileAssociationService.h"
#import "FFPreviewRouter.h"
#import "FFLogger.h"

#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <errno.h>

static NSString * const FFOfficeScheme = @"ffoffice";
static NSString * const FFOfficeHost = @"local";

#pragma mark - Weak JS bridge

@interface FFOfficeWeakScriptHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation FFOfficeWeakScriptHandler
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}
@end

#pragma mark - Offline URL scheme

@interface FFOfficeSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, copy) NSString *sourcePath;
@property(nonatomic, copy) NSString *assetRoot;
@property(nonatomic, strong) dispatch_queue_t ioQueue;
@property(nonatomic, strong) NSMutableSet<NSString *> *cancelled;
@property(nonatomic, strong) NSLock *cancelLock;
- (instancetype)initWithSourcePath:(NSString *)sourcePath;
@end

@implementation FFOfficeSchemeHandler

- (instancetype)initWithSourcePath:(NSString *)sourcePath
{
    self = [super init];
    if (self) {
        _sourcePath = [sourcePath copy];
        _assetRoot = [[NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"OfficeAssets"] stringByStandardizingPath];
        _ioQueue = dispatch_queue_create("ff.office.scheme", DISPATCH_QUEUE_SERIAL);
        _cancelled = [NSMutableSet set];
        _cancelLock = [NSLock new];
    }
    return self;
}

- (NSString *)keyForTask:(id<WKURLSchemeTask>)task
{
    return [NSString stringWithFormat:@"%p", task];
}

- (BOOL)isCancelled:(id<WKURLSchemeTask>)task
{
    [self.cancelLock lock];
    BOOL value = [self.cancelled containsObject:[self keyForTask:task]];
    [self.cancelLock unlock];
    return value;
}

- (void)clearCancelled:(id<WKURLSchemeTask>)task
{
    [self.cancelLock lock];
    [self.cancelled removeObject:[self keyForTask:task]];
    [self.cancelLock unlock];
}

- (NSString *)mimeTypeForPath:(NSString *)path
{
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"html"]) return @"text/html";
    if ([ext isEqualToString:@"css"]) return @"text/css";
    if ([ext isEqualToString:@"js"] || [ext isEqualToString:@"mjs"]) return @"application/javascript";
    if ([ext isEqualToString:@"json"]) return @"application/json";
    if ([ext isEqualToString:@"svg"]) return @"image/svg+xml";
    if ([ext isEqualToString:@"png"]) return @"image/png";
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([ext isEqualToString:@"woff2"]) return @"font/woff2";
    if (@available(iOS 14.0, *)) {
        UTType *type = [UTType typeWithFilenameExtension:ext];
        if (type.preferredMIMEType.length) return type.preferredMIMEType;
    }
    return @"application/octet-stream";
}

- (void)fail:(id<WKURLSchemeTask>)task code:(NSInteger)code text:(NSString *)text
{
    [task didFailWithError:[NSError errorWithDomain:@"FFOfficeScheme" code:code
        userInfo:@{NSLocalizedDescriptionKey:text ?: @"Office resource error"}]];
}

- (void)webView:(__unused WKWebView *)webView
startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    [self clearCancelled:task];
    NSURL *url = task.request.URL;
    if (![url.scheme.lowercaseString isEqualToString:FFOfficeScheme] ||
        ![url.host.lowercaseString isEqualToString:FFOfficeHost]) {
        [self fail:task code:403 text:@"非法 Office 资源请求"];
        return;
    }

    NSString *requestPath = url.path ?: @"";
    NSString *path = nil;
    if ([requestPath isEqualToString:@"/document"]) {
        path = self.sourcePath;
    } else if ([requestPath isEqualToString:@"/"] ||
               [requestPath isEqualToString:@"/index.html"]) {
        path = [self.assetRoot stringByAppendingPathComponent:@"index.html"];
    } else if ([requestPath hasPrefix:@"/assets/"]) {
        NSString *relative = [requestPath substringFromIndex:@"/assets/".length];
        NSString *candidate = [[self.assetRoot stringByAppendingPathComponent:relative]
            stringByStandardizingPath];
        NSString *rootPrefix = [self.assetRoot stringByAppendingString:@"/"];
        if ([candidate hasPrefix:rootPrefix]) path = candidate;
    }

    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [self fail:task code:404 text:@"Office 资源不存在"];
        return;
    }

    dispatch_async(self.ioQueue, ^{
        if ([self isCancelled:task]) return;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        NSString *mime = [self mimeTypeForPath:path];
        NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url
            MIMEType:mime expectedContentLength:(NSInteger)MIN(size, (unsigned long long)NSIntegerMax)
            textEncodingName:[mime hasPrefix:@"text/"] ? @"utf-8" : nil];
        if ([self isCancelled:task]) return;
        [task didReceiveResponse:response];

        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) {
            if (![self isCancelled:task]) [self fail:task code:EIO text:@"无法读取 Office 文件"];
            return;
        }
        @try {
            for (;;) {
                if ([self isCancelled:task]) break;
                NSData *chunk = [handle readDataOfLength:512 * 1024];
                if (chunk.length == 0) break;
                [task didReceiveData:chunk];
            }
            [handle closeFile];
            if (![self isCancelled:task]) [task didFinish];
        } @catch (NSException *exception) {
            [handle closeFile];
            if (![self isCancelled:task]) [self fail:task code:-1 text:exception.reason ?: @"读取 Office 文件失败"];
        }
        [self clearCancelled:task];
    });
}

- (void)webView:(__unused WKWebView *)webView
 stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    [self.cancelLock lock];
    [self.cancelled addObject:[self keyForTask:task]];
    [self.cancelLock unlock];
}
@end

#pragma mark - Office viewer

@interface FFOfficeViewerViewController () <WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, copy) NSString *officeKind;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) FFOfficeSchemeHandler *schemeHandler;
@property(nonatomic, strong) FFOfficeWeakScriptHandler *scriptProxy;
@property(nonatomic) BOOL fullScreen;
@end

@implementation FFOfficeViewerViewController

- (instancetype)initWithFilePath:(NSString *)filePath
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _filePath = [filePath copy];
        _officeKind = [[self class] officeKindForExtension:filePath.pathExtension];
    }
    return self;
}

+ (NSString *)officeKindForExtension:(NSString *)extension
{
    NSString *ext = extension.lowercaseString;
    static NSSet *word, *ppt, *sheet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        word = [NSSet setWithArray:@[@"docx", @"docm", @"dotx", @"dotm"]];
        ppt = [NSSet setWithArray:@[@"pptx", @"pptm", @"ppsx", @"ppsm", @"potx", @"potm"]];
        sheet = [NSSet setWithArray:@[@"xlsx", @"xls", @"xlsm", @"xlsb", @"xltx", @"xltm",
            @"csv", @"tsv", @"ods", @"fods", @"dif", @"dbf", @"slk", @"sylk"]];
    });
    if ([word containsObject:ext]) return @"word";
    if ([ppt containsObject:ext]) return @"ppt";
    if ([sheet containsObject:ext]) return @"sheet";
    return @"unknown";
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    NSString *index = [NSBundle.mainBundle pathForResource:@"index" ofType:@"html"
        inDirectory:@"OfficeAssets"];
    if (!index.length) {
        [self showMissingRuntime];
        return;
    }

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = YES;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;

    self.schemeHandler = [[FFOfficeSchemeHandler alloc] initWithSourcePath:self.filePath];
    [configuration setURLSchemeHandler:self.schemeHandler forURLScheme:FFOfficeScheme];
    WKUserContentController *controller = [WKUserContentController new];
    self.scriptProxy = [FFOfficeWeakScriptHandler new];
    self.scriptProxy.target = self;
    [controller addScriptMessageHandler:self.scriptProxy name:@"ffOffice"];
    configuration.userContentController = controller;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self configureNavigationItems];
    [self loadOfficeDocument];
}

- (void)dealloc
{
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"ffOffice"];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.fullScreen && self.isMovingFromParentViewController) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
        self.fullScreen = NO;
    }
}

- (void)configureNavigationItems
{
    __weak typeof(self) weakSelf = self;
    UIAction *share = [UIAction actionWithTitle:@"分享原文件" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
        identifier:nil handler:^(__unused UIAction *action) { [weakSelf shareFile]; }];
    UIAction *system = [UIAction actionWithTitle:@"系统快速查看" image:[UIImage systemImageNamed:@"eye"]
        identifier:nil handler:^(__unused UIAction *action) { [weakSelf openQuickLook]; }];
    UIAction *full = [UIAction actionWithTitle:@"全屏" image:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"]
        identifier:nil handler:^(__unused UIAction *action) { [weakSelf toggleFullScreen]; }];
    UIAction *reload = [UIAction actionWithTitle:@"重新渲染" image:[UIImage systemImageNamed:@"arrow.clockwise"]
        identifier:nil handler:^(__unused UIAction *action) { [weakSelf loadOfficeDocument]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithTitle:@"" children:@[share, system, full, reload]]];
}

- (void)loadOfficeDocument
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:self.filePath error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = FFOfficeScheme;
    components.host = FFOfficeHost;
    components.path = @"/index.html";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"kind" value:self.officeKind ?: @"unknown"],
        [NSURLQueryItem queryItemWithName:@"name" value:self.filePath.lastPathComponent ?: @"document"],
        [NSURLQueryItem queryItemWithName:@"title" value:self.title ?: self.filePath.lastPathComponent],
        [NSURLQueryItem queryItemWithName:@"bytes" value:[NSString stringWithFormat:@"%llu", size]],
    ];
    FFLogTag(@"Office", @"load kind=%@ path=%@ size=%llu", self.officeKind, self.filePath, size);
    [self.webView loadRequest:[NSURLRequest requestWithURL:components.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0]];
}

- (void)showMissingRuntime
{
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"Office 查看器运行时资源缺失。\n请使用系统快速查看。";
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"系统快速查看" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(openQuickLook) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:label];
    [self.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24],
        [button.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:16],
        [button.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (void)shareFile
{
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.filePath]] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)openQuickLook
{
    if (self.fullScreen) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
        self.fullScreen = NO;
    }
    FFQuickLookViewController *quick = [[FFQuickLookViewController alloc] initWithFilePath:self.filePath];
    quick.title = self.title.length ? self.title : self.filePath.lastPathComponent;
    [self.navigationController pushViewController:quick animated:YES];
}

- (void)toggleFullScreen
{
    self.fullScreen = !self.fullScreen;
    [self.navigationController setNavigationBarHidden:self.fullScreen animated:YES];
}

- (void)userContentController:(__unused WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.name isEqualToString:@"ffOffice"] || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    NSString *type = [body[@"type"] isKindOfClass:NSString.class] ? body[@"type"] : @"";
    if ([type isEqualToString:@"fallback"]) { [self openQuickLook]; return; }
    if ([type isEqualToString:@"share"]) { [self shareFile]; return; }
    if ([type isEqualToString:@"fullscreen"]) { [self toggleFullScreen]; return; }
    if ([type isEqualToString:@"loaded"]) {
        FFLogTag(@"Office", @"rendered kind=%@ path=%@ detail=%@", self.officeKind,
            self.filePath, body[@"detail"] ?: @"");
    } else if ([type isEqualToString:@"error"]) {
        FFLogTag(@"Office", @"render FAIL kind=%@ path=%@ error=%@", self.officeKind,
            self.filePath, body[@"message"] ?: @"unknown");
    }
}

- (void)webView:(__unused WKWebView *)webView
 decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:FFOfficeScheme] || [scheme isEqualToString:@"about"] ||
        [scheme isEqualToString:@"blob"] || [scheme isEqualToString:@"data"] ||
        navigationAction.navigationType == WKNavigationTypeOther) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
         [scheme isEqualToString:@"mailto"] || [scheme isEqualToString:@"tel"]) && url)
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    decisionHandler(WKNavigationActionPolicyCancel);
}
@end

#pragma mark - Association and registry integration

static NSDictionary<NSString *, NSString *> *FFOfficeDefaultAssociations(void)
{
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @"docx":@"office", @"docm":@"office", @"dotx":@"office", @"dotm":@"office",
            @"pptx":@"office", @"pptm":@"office", @"ppsx":@"office", @"ppsm":@"office",
            @"potx":@"office", @"potm":@"office",
            @"xlsx":@"office", @"xls":@"office", @"xlsm":@"office", @"xlsb":@"office",
            @"xltx":@"office", @"xltm":@"office", @"csv":@"office", @"tsv":@"office",
            @"ods":@"office", @"fods":@"office", @"dif":@"office", @"dbf":@"office",
            @"slk":@"office", @"sylk":@"office",
            @"doc":@"quicklook", @"dot":@"quicklook", @"rtf":@"quicklook",
            @"ppt":@"quicklook", @"pps":@"quicklook", @"pot":@"quicklook",
            @"pages":@"quicklook", @"numbers":@"quicklook", @"key":@"quicklook",
            @"odt":@"quicklook", @"odp":@"quicklook",
            @"wps":@"quicklook", @"et":@"quicklook", @"dps":@"quicklook",
        };
    });
    return table;
}

static void FFOfficeSwizzle(Class cls, SEL original, SEL replacement)
{
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

@interface FFFileAssociationService (FFOfficeIntegration)
@end
@implementation FFFileAssociationService (FFOfficeIntegration)
+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFOfficeSwizzle(self, @selector(viewerIDForFileName:), @selector(ff_office_viewerIDForFileName:));
        FFOfficeSwizzle(self, @selector(effectiveViewerIDForExtension:), @selector(ff_office_effectiveViewerIDForExtension:));
        FFOfficeSwizzle(self, @selector(allKnownExtensions), @selector(ff_office_allKnownExtensions));
    });
}
- (NSString *)ff_office_viewerIDForFileName:(NSString *)fileName
{
    NSString *existing = [self ff_office_viewerIDForFileName:fileName];
    if (existing.length || fileName.length == 0) return existing;
    NSString *lower = fileName.lowercaseString;
    for (NSUInteger i = 1; i < lower.length; i++) {
        if ([lower characterAtIndex:i] != '.') continue;
        NSString *viewer = FFOfficeDefaultAssociations()[[lower substringFromIndex:i + 1]];
        if (viewer.length) return viewer;
    }
    return nil;
}
- (NSString *)ff_office_effectiveViewerIDForExtension:(NSString *)extension
{
    NSString *existing = [self ff_office_effectiveViewerIDForExtension:extension];
    if (existing.length) return existing;
    return FFOfficeDefaultAssociations()[[FFFileAssociationService normalizedExtension:extension]];
}
- (NSArray<NSString *> *)ff_office_allKnownExtensions
{
    NSMutableSet *all = [NSMutableSet setWithArray:[self ff_office_allKnownExtensions] ?: @[]];
    [all addObjectsFromArray:FFOfficeDefaultAssociations().allKeys];
    return [all.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
@end

static FFViewerInfo *FFOfficeViewerInfo(void)
{
    static FFViewerInfo *info;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        info = [FFViewerInfo new];
        [info setValue:@"office" forKey:@"viewerID"];
        [info setValue:@"Office 查看器" forKey:@"displayName"];
        [info setValue:@"doc.text.image" forKey:@"iconName"];
        [info setValue:@"离线 DOCX/PPTX/XLS/XLSX/CSV/ODS 查看；老 DOC/PPT/iWork 等自动使用系统快速查看兜底"
              forKey:@"summary"];
    });
    return info;
}

@interface FFViewerRegistry (FFOfficeIntegration)
@end
@implementation FFViewerRegistry (FFOfficeIntegration)
+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFOfficeSwizzle(self, @selector(allViewers), @selector(ff_office_allViewers));
        FFOfficeSwizzle(self, @selector(viewerForID:), @selector(ff_office_viewerForID:));
        FFOfficeSwizzle(self, @selector(openPath:title:viewerID:navigationController:),
            @selector(ff_office_openPath:title:viewerID:navigationController:));
    });
}
- (NSArray<FFViewerInfo *> *)ff_office_allViewers
{
    NSArray *existing = [self ff_office_allViewers] ?: @[];
    for (FFViewerInfo *info in existing)
        if ([info.viewerID isEqualToString:@"office"]) return existing;
    return [existing arrayByAddingObject:FFOfficeViewerInfo()];
}
- (FFViewerInfo *)ff_office_viewerForID:(NSString *)viewerID
{
    if ([viewerID isEqualToString:@"office"]) return FFOfficeViewerInfo();
    return [self ff_office_viewerForID:viewerID];
}
- (BOOL)ff_office_openPath:(NSString *)path title:(NSString *)title viewerID:(NSString *)viewerID
      navigationController:(UINavigationController *)nav
{
    if (![viewerID isEqualToString:@"office"])
        return [self ff_office_openPath:path title:title viewerID:viewerID navigationController:nav];
    NSString *reason = nil;
    if (![self viewerAvailable:viewerID path:path reason:&reason]) {
        [FFPreviewRouter toastOnNav:nav message:reason ?: @"Office 查看器不可用"];
        return NO;
    }
    FFOfficeViewerViewController *viewer = [[FFOfficeViewerViewController alloc] initWithFilePath:path];
    viewer.title = title.length ? title : path.lastPathComponent;
    [nav pushViewController:viewer animated:YES];
    FFLogTag(@"Viewer", @"open viewer=office path=%@", path);
    return YES;
}
@end
