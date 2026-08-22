#import "FFLogViewController.h"
#import "FFLogger.h"

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
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItems = @[self.shareItem, self.refreshItem, clear];

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
            if (self.textView.text.length > 0)
                [self.textView scrollRangeToVisible:NSMakeRange(
                    self.textView.text.length - 1, 1)];
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

- (void)clearLog
{
    [[NSFileManager defaultManager] removeItemAtPath:FFLogPath() error:nil];
    [self refreshLog];
}


@end
