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
- (instancetype)initWithDocumentPath:(NSString *)path {
    if ((self=[super init])) {
        _documentPath=[path copy];
        _assetRoot=[[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"DocxAssets"] stringByStandardizingPath];
    }
    return self;
}
- (NSString *)mime:(NSString *)path {
    NSString *e=path.pathExtension.lowercaseString;
    if ([e isEqualToString:@"html"]) return @"text/html";
    if ([e isEqualToString:@"css"]) return @"text/css";
    if ([e isEqualToString:@"js"]) return @"application/javascript";
    return @"application/octet-stream";
}
- (void)webView:(__unused WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *url=task.request.URL;
    NSString *path=nil;
    if (![url.scheme.lowercaseString isEqualToString:FFDocxScheme]) {
        [task didFailWithError:[NSError errorWithDomain:@"FFDocx" code:403 userInfo:nil]]; return;
    }
    if ([url.path isEqualToString:@"/document"]) path=self.documentPath;
    else {
        NSString *rel=[url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (!rel.length) rel=@"index.html";
        NSString *candidate=[[self.assetRoot stringByAppendingPathComponent:rel] stringByStandardizingPath];
        NSString *prefix=[self.assetRoot stringByAppendingString:@"/"];
        if ([candidate isEqualToString:self.assetRoot] || [candidate hasPrefix:prefix]) path=candidate;
    }
    NSData *data=path.length ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
    if (!data) { [task didFailWithError:[NSError errorWithDomain:@"FFDocx" code:404 userInfo:nil]]; return; }
    NSURLResponse *response=[[NSURLResponse alloc] initWithURL:url MIMEType:[self mime:path]
        expectedContentLength:(NSInteger)data.length textEncodingName:[[self mime:path] hasPrefix:@"text/"]||[[self mime:path] containsString:@"javascript"]?@"utf-8":nil];
    [task didReceiveResponse:response]; [task didReceiveData:data]; [task didFinish];
}
- (void)webView:(__unused WKWebView *)webView stopURLSchemeTask:(__unused id<WKURLSchemeTask>)task {}
@end

@interface FFDocxWeakHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
@end
@implementation FFDocxWeakHandler
- (void)userContentController:(WKUserContentController *)u didReceiveScriptMessage:(WKScriptMessage *)m { [self.target userContentController:u didReceiveScriptMessage:m]; }
@end

@interface FFDocxViewerViewController () <WKScriptMessageHandler>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) FFDocxSchemeHandler *schemeHandler;
@property(nonatomic, strong) FFDocxWeakHandler *weakHandler;
@end

@implementation FFDocxViewerViewController
- (instancetype)initWithFilePath:(NSString *)path {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    if ((self=[super initWithNibName:nil bundle:nil])) _filePath=[path copy];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    NSString *index=[NSBundle.mainBundle pathForResource:@"index" ofType:@"html" inDirectory:@"DocxAssets"];
    if (!index.length) { [self offerQuickLook:@"DOCX 查看器资源缺失"]; return; }
    WKWebViewConfiguration *cfg=[WKWebViewConfiguration new];
    cfg.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    self.schemeHandler=[[FFDocxSchemeHandler alloc] initWithDocumentPath:self.filePath];
    [cfg setURLSchemeHandler:self.schemeHandler forURLScheme:FFDocxScheme];
    WKUserContentController *uc=[WKUserContentController new];
    self.weakHandler=[FFDocxWeakHandler new]; self.weakHandler.target=self;
    [uc addScriptMessageHandler:self.weakHandler name:@"ffDocx"]; cfg.userContentController=uc;
    self.webView=[[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.webView.translatesAutoresizingMaskIntoConstraints=NO; self.webView.opaque=NO;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[[self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [self configureMenu];
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"ffdocx:///index.html"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60]];
    FFLogTag(@"DOCX", @"open path=%@", self.filePath);
}
- (void)dealloc { [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"ffDocx"]; }
- (void)configureMenu {
    __weak typeof(self) w=self;
    UIAction *share=[UIAction actionWithTitle:@"分享原文件" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction *a){[w shareFile];}];
    UIAction *system=[UIAction actionWithTitle:@"系统快速查看" image:[UIImage systemImageNamed:@"eye"] identifier:nil handler:^(__unused UIAction *a){[w openQuickLook];}];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"" children:@[share,system]]];
}
- (void)shareFile {
    UIActivityViewController *a=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:self.filePath]] applicationActivities:nil];
    a.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}
- (void)openQuickLook {
    FFQuickLookViewController *q=[[FFQuickLookViewController alloc] initWithFilePath:self.filePath];
    q.title=self.title.length?self.title:self.filePath.lastPathComponent;
    [self.navigationController pushViewController:q animated:YES];
}
- (void)offerQuickLook:(NSString *)message {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"无法打开 Word 文档" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"系统快速查看" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){[self openQuickLook];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)userContentController:(__unused WKUserContentController *)u didReceiveScriptMessage:(WKScriptMessage *)m {
    if (![m.name isEqualToString:@"ffDocx"]||![m.body isKindOfClass:NSDictionary.class]) return;
    NSString *type=m.body[@"type"];
    if ([type isEqualToString:@"loaded"]) FFLogTag(@"DOCX", @"rendered path=%@", self.filePath);
    else if ([type isEqualToString:@"error"]) { FFLogTag(@"DOCX", @"render failed path=%@ error=%@",self.filePath,m.body[@"message"]?:@"?"); [self offerQuickLook:m.body[@"message"]?:@"渲染失败"]; }
}
@end
