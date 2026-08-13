#import "FFLogViewController.h"
#import "FFLogger.h"
#import "MCMManager.h"
#import "FFThumbnailService.h"

@interface FFLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UIBarButtonItem *shareItem;
@property(nonatomic, strong) UIBarButtonItem *refreshItem;
@end

@implementation FFLogViewController

- (instancetype)init
{
    self = [super init];
    if (self) self.title = @"运行日志";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
    ]];

    self.refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemRefresh target:self action:@selector(refreshLog)];
    self.shareItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemAction target:self action:@selector(shareLog)];
    UIBarButtonItem *rerun = [[UIBarButtonItem alloc] initWithTitle:@"重新扫描"
        style:UIBarButtonItemStylePlain target:self action:@selector(rerunScan)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    UIBarButtonItem *clearThumbs = [[UIBarButtonItem alloc] initWithTitle:@"清缓存"
        style:UIBarButtonItemStylePlain target:self action:@selector(clearThumbnailCache)];
    self.navigationItem.rightBarButtonItems = @[self.shareItem, self.refreshItem, rerun, clear, clearThumbs];

    [self refreshLog];
}

- (void)refreshLog
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = FFLogPath();
        NSString *text = [NSString stringWithContentsOfFile:path
            encoding:NSUTF8StringEncoding error:nil];
        // Show the tail for readability; the full log is shareable as-is.
        if (text.length > 256 * 1024)
            text = [@"…（仅显示末尾，完整日志见文件）\n\n" stringByAppendingString:
                [text substringFromIndex:text.length - 256 * 1024]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text = text ?: @"（暂无日志）";
            [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
        });
    });
}

- (void)shareLog
{
    NSURL *url = [NSURL fileURLWithPath:FFLogPath()];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.shareItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)rerunScan
{
    __weak typeof(self) weakSelf = self;
    FFLog(@"manual rescan begin");
    [[MCMManager sharedManager] rescanWithCompletion:^{
        FFLog(@"manual rescan done");
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"FFProbeFinished" object:nil];
        [weakSelf refreshLog];
    }];
}

- (void)clearLog
{
    [[NSFileManager defaultManager] removeItemAtPath:FFLogPath() error:nil];
    [self refreshLog];
}

- (void)clearThumbnailCache
{
    unsigned long long size = [[FFThumbnailService sharedService] diskCacheSize];
    [[FFThumbnailService sharedService] clearCaches];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"缩略图缓存已清理"
        message:[NSString stringWithFormat:@"释放约 %@。",
            [NSByteCountFormatter stringFromByteCount:(long long)size
                countStyle:NSByteCountFormatterCountStyleFile]]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
