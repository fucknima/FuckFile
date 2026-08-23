#import "FFWebViewerViewController.h"

#import "FFLogger.h"

@interface FFWebViewerViewController () <WKNavigationDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation FFWebViewerViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
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

    if (![self loadShortcutOrLocalPage])
        [self showFailure:@"无法解析该网页文件"];
}

// .url / .webloc resolve to a remote URL; html/htm load as local files
// with read access scoped to the file's own directory (never the whole
// filesystem).
- (BOOL)loadShortcutOrLocalPage
{
    NSString *ext = self.filePath.pathExtension.lowercaseString;
    NSURL *fileURL = [NSURL fileURLWithPath:self.filePath];

    if ([ext isEqualToString:@"webloc"]) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:self.filePath];
        NSString *urlString = plist[@"URL"];
        return [self loadRemoteString:urlString];
    }
    if ([ext isEqualToString:@"url"]) {
        NSError *error = nil;
        NSString *content = [NSString stringWithContentsOfFile:self.filePath
            encoding:NSUTF8StringEncoding error:&error];
        if (!content)
            content = [NSString stringWithContentsOfFile:self.filePath
                encoding:NSISOLatin1StringEncoding error:nil];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
            @"(?i)^\\s*URL\\s*=\\s*(\\S+)" options:NSRegularExpressionAnchorsMatchLines error:&error];
        NSString *urlString = nil;
        if (regex) {
            NSTextCheckingResult *match = [regex firstMatchInString:content options:0
                range:NSMakeRange(0, content.length)];
            if (match.numberOfRanges > 1)
                urlString = [content substringWithRange:[match rangeAtIndex:1]];
        }
        return [self loadRemoteString:urlString];
    }

    // Local HTML: read-access root is the containing folder so sibling
    // resources (css/js/images) still load, but nothing above it.
    NSURL *folder = fileURL.URLByDeletingLastPathComponent;
    [self.spinner startAnimating];
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
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    return YES;
}

#pragma mark - Navigation feedback

- (void)webView:(__unused WKWebView *)webView didStartProvisioningNavigation:(__unused WKNavigation *)navigation
{
    [self.spinner startAnimating];
}

- (void)webView:(__unused WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation
{
    [self.spinner stopAnimating];
    self.title = self.webView.title ?: self.filePath.lastPathComponent;
}

- (void)webView:(__unused WKWebView *)webView didFailNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    [self.spinner stopAnimating];
    FFLogTag(@"Web", @"load FAIL %@: %@", self.filePath, error);
    [self showFailure:error.localizedDescription ?: @"页面加载失败"];
}

- (void)webView:(__unused WKWebView *)webView didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
    [self.spinner stopAnimating];
    FFLogTag(@"Web", @"provision FAIL %@: %@", self.filePath, error);
    [self showFailure:error.localizedDescription ?: @"页面加载失败"];
}

- (void)showFailure:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加载失败"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
