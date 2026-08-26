#import "FFLogViewController.h"
#import "FFLogger.h"

@interface FFLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UIBarButtonItem *shareItem;
@property(nonatomic, strong) UIBarButtonItem *refreshItem;
@property(nonatomic, strong) UIView *policyCard;
@property(nonatomic, strong) UISwitch *loggingSwitch;
@property(nonatomic, strong) UIButton *ageButton;
@property(nonatomic, strong) UIButton *sizeButton;
@property(nonatomic, strong) UILabel *policySummary;
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
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.policyCard = [UIView new];
    self.policyCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.policyCard.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.policyCard.layer.cornerRadius = 14;
    self.policyCard.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.policyCard];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"文件日志";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.policyCard addSubview:title];

    self.loggingSwitch = [UISwitch new];
    self.loggingSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.loggingSwitch.on = FFLogFileEnabled();
    [self.loggingSwitch addTarget:self action:@selector(loggingSwitchChanged:)
                 forControlEvents:UIControlEventValueChanged];
    [self.policyCard addSubview:self.loggingSwitch];

    self.ageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.ageButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.ageButton.showsMenuAsPrimaryAction = YES;
    self.ageButton.changesSelectionAsPrimaryAction = NO;
    self.ageButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.policyCard addSubview:self.ageButton];

    self.sizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sizeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sizeButton.showsMenuAsPrimaryAction = YES;
    self.sizeButton.changesSelectionAsPrimaryAction = NO;
    self.sizeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.policyCard addSubview:self.sizeButton];

    self.policySummary = [UILabel new];
    self.policySummary.translatesAutoresizingMaskIntoConstraints = NO;
    self.policySummary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.policySummary.textColor = UIColor.secondaryLabelColor;
    self.policySummary.adjustsFontSizeToFitWidth = YES;
    self.policySummary.minimumScaleFactor = 0.8;
    [self.policyCard addSubview:self.policySummary];

    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.textView.backgroundColor = UIColor.systemBackgroundColor;
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.policyCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.policyCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.policyCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.policyCard.heightAnchor constraintEqualToConstant:112],

        [title.topAnchor constraintEqualToAnchor:self.policyCard.topAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:self.policyCard.leadingAnchor constant:14],
        [self.loggingSwitch.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.loggingSwitch.trailingAnchor constraintEqualToAnchor:self.policyCard.trailingAnchor constant:-14],

        [self.ageButton.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.ageButton.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.ageButton.widthAnchor constraintEqualToAnchor:self.policyCard.widthAnchor multiplier:0.45],
        [self.sizeButton.centerYAnchor constraintEqualToAnchor:self.ageButton.centerYAnchor],
        [self.sizeButton.leadingAnchor constraintEqualToAnchor:self.policyCard.centerXAnchor constant:6],
        [self.sizeButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.policyCard.trailingAnchor constant:-14],

        [self.policySummary.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.policySummary.trailingAnchor constraintEqualToAnchor:self.policyCard.trailingAnchor constant:-14],
        [self.policySummary.bottomAnchor constraintEqualToAnchor:self.policyCard.bottomAnchor constant:-10],

        [self.textView.topAnchor constraintEqualToAnchor:self.policyCard.bottomAnchor constant:6],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];

    self.refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemRefresh target:self action:@selector(refreshLog)];
    self.shareItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemAction target:self action:@selector(shareLog)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"清空"
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItems = @[self.shareItem, self.refreshItem, clear];

    [self rebuildPolicyMenus];
    [self refreshLog];
}

- (NSString *)ageTitle:(NSUInteger)days
{
    return days == 0 ? @"保留：不限时间" : [NSString stringWithFormat:@"保留：%lu 天", (unsigned long)days];
}

- (NSString *)sizeTitle:(unsigned long long)bytes
{
    if (bytes == 0) return @"上限：不限大小";
    return [NSString stringWithFormat:@"上限：%@",
        [NSByteCountFormatter stringFromByteCount:(long long)bytes
            countStyle:NSByteCountFormatterCountStyleFile]];
}

- (void)rebuildPolicyMenus
{
    __weak typeof(self) weakSelf = self;
    NSUInteger currentDays = FFLogMaxAgeDays();
    NSMutableArray<UIMenuElement *> *ageItems = [NSMutableArray array];
    for (NSNumber *number in @[@0, @1, @7, @30, @90]) {
        NSUInteger days = number.unsignedIntegerValue;
        UIAction *action = [UIAction actionWithTitle:[self ageTitle:days]
            image:nil identifier:nil handler:^(__kindof UIAction *item) {
                (void)item;
                FFSetLogMaxAgeDays(days);
                [weakSelf rebuildPolicyMenus];
                [weakSelf refreshLog];
            }];
        action.state = currentDays == days ? UIMenuElementStateOn : UIMenuElementStateOff;
        [ageItems addObject:action];
    }
    self.ageButton.menu = [UIMenu menuWithTitle:@"按时间自动清理" children:ageItems];
    [self.ageButton setTitle:[self ageTitle:currentDays] forState:UIControlStateNormal];

    unsigned long long currentBytes = FFLogMaxBytes();
    NSArray<NSNumber *> *sizes = @[@0,
        @(1ULL * 1024ULL * 1024ULL), @(5ULL * 1024ULL * 1024ULL),
        @(10ULL * 1024ULL * 1024ULL), @(25ULL * 1024ULL * 1024ULL),
        @(50ULL * 1024ULL * 1024ULL)];
    NSMutableArray<UIMenuElement *> *sizeItems = [NSMutableArray array];
    for (NSNumber *number in sizes) {
        unsigned long long bytes = number.unsignedLongLongValue;
        UIAction *action = [UIAction actionWithTitle:[self sizeTitle:bytes]
            image:nil identifier:nil handler:^(__kindof UIAction *item) {
                (void)item;
                FFSetLogMaxBytes(bytes);
                [weakSelf rebuildPolicyMenus];
                [weakSelf refreshLog];
            }];
        action.state = currentBytes == bytes ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sizeItems addObject:action];
    }
    self.sizeButton.menu = [UIMenu menuWithTitle:@"按大小自动清理" children:sizeItems];
    [self.sizeButton setTitle:[self sizeTitle:currentBytes] forState:UIControlStateNormal];

    unsigned long long currentSize = FFLogFileSize();
    self.policySummary.text = [NSString stringWithFormat:@"当前 %@ · 时间或大小任一达到上限即清理",
        [NSByteCountFormatter stringFromByteCount:(long long)currentSize
            countStyle:NSByteCountFormatterCountStyleFile]];
}

- (void)loggingSwitchChanged:(UISwitch *)sender
{
    FFSetLogFileEnabled(sender.on);
    [self rebuildPolicyMenus];
    [self refreshLog];
}

- (void)refreshLog
{
    FFPerformLogCleanup();
    [self rebuildPolicyMenus];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = FFLogPath();
        NSString *text = [NSString stringWithContentsOfFile:path
            encoding:NSUTF8StringEncoding error:nil];
        if (text.length > 256 * 1024)
            text = [@"…（仅显示末尾，完整日志可直接分享）\n\n" stringByAppendingString:
                [text substringFromIndex:text.length - 256 * 1024]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text = text ?: (FFLogFileEnabled() ? @"（暂无日志）" : @"（文件日志已关闭）");
            if (self.textView.text.length > 0)
                [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
            [self rebuildPolicyMenus];
        });
    });
}

- (void)shareLog
{
    NSString *path = FFLogPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无日志"
            message:FFLogFileEnabled() ? @"当前还没有可分享的日志。" : @"文件日志已关闭。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.shareItem;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)clearLog
{
    [NSFileManager.defaultManager removeItemAtPath:FFLogPath() error:nil];
    [self refreshLog];
}

@end
