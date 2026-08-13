#import "FFLogViewController.h"
#import "FFLogger.h"
#import "BadQueryProbe.h"
#import "MCMManager.h"

@interface FFLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UISegmentedControl *segment;
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

    self.segment = [[UISegmentedControl alloc] initWithItems:@[@"FuckFile", @"探针"]];
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(segmentChanged:)
           forControlEvents:UIControlEventValueChanged];
    self.segment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.segment];

    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.segment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.segment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.segment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.textView.topAnchor constraintEqualToAnchor:self.segment.bottomAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
    ]];

    self.refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemRefresh target:self action:@selector(refreshLog)];
    self.shareItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemAction target:self action:@selector(shareLog)];
    UIBarButtonItem *rerun = [[UIBarButtonItem alloc] initWithTitle:@"重跑探针"
        style:UIBarButtonItemStylePlain target:self action:@selector(rerunProbe)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItems = @[self.shareItem, self.refreshItem, rerun, clear];

    [self refreshLog];
}

- (void)segmentChanged:(__unused UISegmentedControl *)segment
{
    [self refreshLog];
}

- (NSString *)currentLogPath
{
    if (self.segment.selectedSegmentIndex == 0) return FFLogPath();
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[documents stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"BadQuery Probe Log.txt"];
}

- (void)refreshLog
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = [self currentLogPath];
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
    NSString *path = [self currentLogPath];
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.shareItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)rerunProbe
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BadQueryProbeRunAgain();
        BadQueryReconnectEscapedRoots();
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"FFProbeFinished" object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refreshLog];
        });
    });
}

- (void)clearLog
{
    NSString *path = [self currentLogPath];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [self refreshLog];
}

@end
