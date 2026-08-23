#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFTasksViewController.h"
#import "FFSearchViewController.h"
#import "FFBookmarksViewController.h"
#import "FFBookmarksService.h"
#import "FFSettingsViewController.h"
#import "MCMManager.h"
#import "FFFileTaskManager.h"

@interface FFHomeViewController ()
@property(nonatomic) NSUInteger appCount;
@property(nonatomic) BOOL scanInProgress;
@property(nonatomic) double scanProgress;
@property(nonatomic) NSUInteger scanTotal;
@property(nonatomic) NSUInteger scanLinked;
@property(nonatomic, copy) NSDate *lastScanDate;
@property(nonatomic) NSUInteger activeTaskCount;
@property(nonatomic) unsigned long long storageTotalBytes;
@property(nonatomic) unsigned long long storageUsedBytes;
@property(nonatomic, strong) NSArray<FFBookmark *> *recentItems;

@property(nonatomic, strong) UIView *homeHeader;
@property(nonatomic, strong) UILabel *storageSubtitleLabel;
@property(nonatomic, strong) UILabel *storageUsageLabel;
@property(nonatomic, strong) UILabel *storagePercentLabel;
@property(nonatomic, strong) UIProgressView *storageProgressView;
@property(nonatomic, strong) UIButton *taskQuickButton;
@property(nonatomic, strong) UIView *bottomTabBar;
@end

@implementation FFHomeViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"FuckFile";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, 72, 0);

    [self buildHomeHeader];
    [self buildBottomTabBar];

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFProbeFinished"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadStatus]; });
        }];
    [[NSNotificationCenter defaultCenter] addObserverForName:FFMCMAppLinksUpdatedNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSDictionary *info = note.userInfo;
                if ([info[@"Scanning"] isKindOfClass:NSNumber.class]) {
                    weakSelf.scanInProgress = [info[@"Scanning"] boolValue];
                    weakSelf.scanProgress = [info[@"Progress"] isKindOfClass:NSNumber.class]
                        ? [info[@"Progress"] doubleValue] : 0;
                    weakSelf.scanTotal = [info[@"Total"] isKindOfClass:NSNumber.class]
                        ? [info[@"Total"] unsignedIntegerValue] : 0;
                    weakSelf.scanLinked = [info[@"Linked"] isKindOfClass:NSNumber.class]
                        ? [info[@"Linked"] unsignedIntegerValue] : 0;
                    if (!weakSelf.scanInProgress) weakSelf.lastScanDate = NSDate.date;
                }
                [weakSelf reloadStatus];
            });
        }];
    [[NSNotificationCenter defaultCenter] addObserverForName:FFFileTaskManagerDidChangeNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadStatus]; });
        }];
    [self reloadStatus];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // The approved home preview is content-led: FuckFile title/search/storage
    // live in the screen itself instead of a second navigation title bar.
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    self.recentItems = [FFRecentService sharedService].entries;
    [self.tableView reloadData];
    [self reloadStatus];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

#pragma mark - Header

- (UIButton *)quickButtonWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                              tint:(UIColor *)tint
                            action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    UIImage *symbolImage = [UIImage systemImageNamed:symbol];
    if (symbolImage)
        configuration.image = [symbolImage imageWithTintColor:tint ?: UIColor.systemBlueColor
            renderingMode:UIImageRenderingModeAlwaysOriginal];
    configuration.imagePlacement = NSDirectionalRectEdgeTop;
    configuration.imagePadding = 7;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.baseBackgroundColor = UIColor.secondarySystemBackgroundColor;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 6, 10, 6);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildHomeHeader
{
    CGFloat width = MAX(self.tableView.bounds.size.width, UIScreen.mainScreen.bounds.size.width);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 410)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.backgroundColor = UIColor.systemBackgroundColor;
    self.homeHeader = header;
    self.tableView.tableHeaderView = header;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"FuckFile";
    title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    [header addSubview:title];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.translatesAutoresizingMaskIntoConstraints = NO;
    [refresh setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    refresh.tintColor = UIColor.labelColor;
    refresh.accessibilityLabel = @"刷新";
    [refresh addTarget:self action:@selector(reloadStatus)
      forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:refresh];

    UIButton *search = [UIButton buttonWithType:UIButtonTypeSystem];
    search.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *searchConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    searchConfiguration.title = @"搜索文件或文件夹";
    searchConfiguration.image = [UIImage systemImageNamed:@"magnifyingglass"];
    searchConfiguration.imagePadding = 8;
    searchConfiguration.baseForegroundColor = UIColor.secondaryLabelColor;
    searchConfiguration.baseBackgroundColor = UIColor.secondarySystemBackgroundColor;
    searchConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    searchConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(11, 14, 11, 14);
    search.configuration = searchConfiguration;
    search.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [search addTarget:self action:@selector(openSearch)
       forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:search];

    UIControl *storageCard = [UIControl new];
    storageCard.translatesAutoresizingMaskIntoConstraints = NO;
    storageCard.backgroundColor = UIColor.secondarySystemBackgroundColor;
    storageCard.layer.cornerRadius = 12;
    storageCard.layer.masksToBounds = YES;
    [storageCard addTarget:self action:@selector(openDeviceStorage)
          forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:storageCard];

    UILabel *storageTitle = [UILabel new];
    storageTitle.translatesAutoresizingMaskIntoConstraints = NO;
    storageTitle.text = @"设备存储";
    storageTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    storageTitle.textColor = UIColor.labelColor;
    [storageCard addSubview:storageTitle];

    UILabel *storageSubtitle = [UILabel new];
    storageSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    storageSubtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    storageSubtitle.textColor = UIColor.secondaryLabelColor;
    self.storageSubtitleLabel = storageSubtitle;
    [storageCard addSubview:storageSubtitle];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"chevron.right"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = UIColor.tertiaryLabelColor;
    [storageCard addSubview:chevron];

    UIProgressView *progress = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.progressTintColor = UIColor.systemBlueColor;
    progress.trackTintColor = UIColor.tertiarySystemFillColor;
    self.storageProgressView = progress;
    [storageCard addSubview:progress];

    UILabel *usage = [UILabel new];
    usage.translatesAutoresizingMaskIntoConstraints = NO;
    usage.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    usage.textColor = UIColor.secondaryLabelColor;
    self.storageUsageLabel = usage;
    [storageCard addSubview:usage];

    UILabel *percent = [UILabel new];
    percent.translatesAutoresizingMaskIntoConstraints = NO;
    percent.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    percent.textColor = UIColor.secondaryLabelColor;
    percent.textAlignment = NSTextAlignmentRight;
    self.storagePercentLabel = percent;
    [storageCard addSubview:percent];

    UILabel *quickTitle = [UILabel new];
    quickTitle.translatesAutoresizingMaskIntoConstraints = NO;
    quickTitle.text = @"快速访问";
    quickTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    quickTitle.textColor = UIColor.labelColor;
    [header addSubview:quickTitle];

    UIButton *appData = [self quickButtonWithTitle:@"App 数据" symbol:@"app.dashed"
        tint:UIColor.systemBlueColor action:@selector(openAppData)];
    UIButton *imported = [self quickButtonWithTitle:@"导入" symbol:@"tray.and.arrow.down.fill"
        tint:UIColor.systemCyanColor action:@selector(openImported)];
    UIButton *favorites = [self quickButtonWithTitle:@"收藏" symbol:@"star.fill"
        tint:UIColor.systemYellowColor action:@selector(openFavorites)];
    UIButton *recent = [self quickButtonWithTitle:@"最近" symbol:@"clock.fill"
        tint:UIColor.systemOrangeColor action:@selector(openRecents)];
    UIButton *searchTile = [self quickButtonWithTitle:@"搜索" symbol:@"magnifyingglass"
        tint:UIColor.systemTealColor action:@selector(openSearch)];
    UIButton *tasks = [self quickButtonWithTitle:@"任务" symbol:@"clock.arrow.circlepath"
        tint:UIColor.systemPurpleColor action:@selector(openTasks)];
    self.taskQuickButton = tasks;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:
        @[appData, imported, favorites]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.distribution = UIStackViewDistributionFillEqually;
    topRow.spacing = 8;

    UIStackView *bottomRow = [[UIStackView alloc] initWithArrangedSubviews:
        @[recent, searchTile, tasks]];
    bottomRow.axis = UILayoutConstraintAxisHorizontal;
    bottomRow.distribution = UIStackViewDistributionFillEqually;
    bottomRow.spacing = 8;

    UIStackView *quickGrid = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, bottomRow]];
    quickGrid.translatesAutoresizingMaskIntoConstraints = NO;
    quickGrid.axis = UILayoutConstraintAxisVertical;
    quickGrid.distribution = UIStackViewDistributionFillEqually;
    quickGrid.spacing = 8;
    [header addSubview:quickGrid];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [refresh.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [refresh.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [refresh.widthAnchor constraintEqualToConstant:36],
        [refresh.heightAnchor constraintEqualToConstant:36],

        [search.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [search.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [search.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [search.heightAnchor constraintEqualToConstant:44],

        [storageCard.topAnchor constraintEqualToAnchor:search.bottomAnchor constant:12],
        [storageCard.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [storageCard.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [storageCard.heightAnchor constraintEqualToConstant:92],

        [storageTitle.topAnchor constraintEqualToAnchor:storageCard.topAnchor constant:12],
        [storageTitle.leadingAnchor constraintEqualToAnchor:storageCard.leadingAnchor constant:14],
        [storageSubtitle.topAnchor constraintEqualToAnchor:storageTitle.bottomAnchor constant:2],
        [storageSubtitle.leadingAnchor constraintEqualToAnchor:storageTitle.leadingAnchor],
        [storageSubtitle.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [chevron.centerYAnchor constraintEqualToAnchor:storageTitle.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:storageCard.trailingAnchor constant:-14],
        [progress.leadingAnchor constraintEqualToAnchor:storageCard.leadingAnchor constant:14],
        [progress.trailingAnchor constraintEqualToAnchor:storageCard.trailingAnchor constant:-14],
        [progress.topAnchor constraintEqualToAnchor:storageSubtitle.bottomAnchor constant:9],
        [usage.leadingAnchor constraintEqualToAnchor:progress.leadingAnchor],
        [usage.topAnchor constraintEqualToAnchor:progress.bottomAnchor constant:5],
        [percent.trailingAnchor constraintEqualToAnchor:progress.trailingAnchor],
        [percent.centerYAnchor constraintEqualToAnchor:usage.centerYAnchor],

        [quickTitle.topAnchor constraintEqualToAnchor:storageCard.bottomAnchor constant:16],
        [quickTitle.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [quickGrid.topAnchor constraintEqualToAnchor:quickTitle.bottomAnchor constant:10],
        [quickGrid.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [quickGrid.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [quickGrid.heightAnchor constraintEqualToConstant:142],
    ]];
}

#pragma mark - Bottom tabs

- (UIButton *)tabButtonWithTitle:(NSString *)title
                          symbol:(NSString *)symbol
                        selected:(BOOL)selected
                          action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePlacement = NSDirectionalRectEdgeTop;
    configuration.imagePadding = 3;
    configuration.baseForegroundColor = selected ? UIColor.systemBlueColor
                                                  : UIColor.secondaryLabelColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(4, 4, 4, 4);
    button.configuration = configuration;
    if (action) [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildBottomTabBar
{
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    bar.layer.zPosition = 1000;
    [self.tableView addSubview:bar];
    self.bottomTabBar = bar;

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = UIColor.separatorColor;
    [bar addSubview:separator];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self tabButtonWithTitle:@"首页" symbol:@"house.fill" selected:YES action:nil],
        [self tabButtonWithTitle:@"文件" symbol:@"folder" selected:NO action:@selector(openDeviceStorage)],
        [self tabButtonWithTitle:@"书签" symbol:@"star" selected:NO action:@selector(openFavorites)],
        [self tabButtonWithTitle:@"设置" symbol:@"gearshape" selected:NO action:@selector(openSettings)],
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    [bar addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:78],
        [separator.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor constant:4],
        [stack.heightAnchor constraintEqualToConstant:58],
    ]];
}

#pragma mark - Status

- (void)reloadStatus
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *appData = [MCMVirtualRoot() stringByAppendingPathComponent:@"AppData"];
        NSFileManager *manager = NSFileManager.defaultManager;
        NSUInteger count = [[manager contentsOfDirectoryAtPath:appData error:nil] count];
        NSUInteger active = 0;
        for (FFFileTask *task in [FFFileTaskManager sharedManager].tasks)
            if (task.state == FFFileTaskStateRunning || task.state == FFFileTaskStateQueued)
                active++;

        NSDictionary *fs = [manager attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        unsigned long long total = [fs[NSFileSystemSize] unsignedLongLongValue];
        unsigned long long free = [fs[NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long used = total >= free ? total - free : 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.appCount = count;
            self.activeTaskCount = active;
            self.storageTotalBytes = total;
            self.storageUsedBytes = used;
            [self refreshHeaderMetrics];
            [self.tableView reloadData];
        });
    });
}

- (void)refreshHeaderMetrics
{
    if (self.scanInProgress) {
        NSUInteger done = (NSUInteger)(self.scanTotal * self.scanProgress);
        self.storageSubtitleLabel.text = [NSString stringWithFormat:
            @"扫描 App 数据 %lu/%lu · 已发现 %lu",
            (unsigned long)done, (unsigned long)self.scanTotal,
            (unsigned long)self.scanLinked];
    } else {
        self.storageSubtitleLabel.text = [NSString stringWithFormat:
            @"%@ · %lu 个 App", @"Device Storage", (unsigned long)self.appCount];
    }

    double ratio = self.storageTotalBytes > 0
        ? (double)self.storageUsedBytes / (double)self.storageTotalBytes : 0;
    self.storageProgressView.progress = (float)MAX(0, MIN(1, ratio));
    self.storageUsageLabel.text = [NSString stringWithFormat:@"已用 %@ / %@",
        [NSByteCountFormatter stringFromByteCount:(long long)self.storageUsedBytes
            countStyle:NSByteCountFormatterCountStyleFile],
        [NSByteCountFormatter stringFromByteCount:(long long)self.storageTotalBytes
            countStyle:NSByteCountFormatterCountStyleFile]];
    self.storagePercentLabel.text = [NSString stringWithFormat:@"%.1f%%", ratio * 100.0];

    UIButtonConfiguration *taskConfiguration = self.taskQuickButton.configuration;
    taskConfiguration.title = self.activeTaskCount > 0
        ? [NSString stringWithFormat:@"任务 %lu", (unsigned long)self.activeTaskCount]
        : @"任务";
    self.taskQuickButton.configuration = taskConfiguration;
}

#pragma mark - Navigation

- (void)push:(UIViewController *)controller
{
    if (!controller) return;
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openDeviceStorage
{
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:MCMVirtualRoot()];
    browser.title = @"Device Storage";
    [self push:browser];
}

- (void)openAppData
{
    NSString *path = [MCMVirtualRoot() stringByAppendingPathComponent:@"AppData"];
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:path];
    browser.title = @"App Data";
    [self push:browser];
}

- (void)openImported
{
    NSString *path = [MCMVirtualRoot() stringByAppendingPathComponent:@"Imported"];
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无导入文件"
            message:@"从其他 App 分享或在文件浏览器中导入文件后，会显示在这里。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好"
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:path];
    browser.title = @"Imported";
    [self push:browser];
}

- (void)openSearch
{
    [self push:[FFSearchViewController new]];
}

- (void)openFavorites
{
    [self push:[[FFBookmarksViewController alloc] initWithMode:FFBookmarksModeFavorites]];
}

- (void)openRecents
{
    [self push:[[FFBookmarksViewController alloc] initWithMode:FFBookmarksModeRecent]];
}

- (void)openTasks
{
    [self push:[FFTasksViewController new]];
}

- (void)openSettings
{
    [self push:[FFSettingsViewController new]];
}

#pragma mark - Recent list

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.recentItems.count > 0 ? (NSInteger)MIN((NSUInteger)3, self.recentItems.count) : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @"最近访问";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Recent"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Recent"];

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    if (self.recentItems.count == 0) {
        config.text = @"暂无最近访问";
        config.textProperties.color = UIColor.secondaryLabelColor;
        config.image = [UIImage systemImageNamed:@"clock"];
        config.imageProperties.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        FFBookmark *bookmark = self.recentItems[indexPath.row];
        config.text = bookmark.name.length ? bookmark.name : bookmark.path.lastPathComponent;
        config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        config.secondaryText = bookmark.path;
        config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        config.secondaryTextProperties.numberOfLines = 1;
        config.image = [UIImage systemImageNamed:bookmark.isDirectory ? @"folder.fill" : @"doc.fill"];
        config.imageProperties.tintColor = bookmark.isDirectory ? UIColor.systemBlueColor
                                                               : UIColor.secondaryLabelColor;
        config.imageProperties.maximumSize = CGSizeMake(30, 30);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    config.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(9, 20, 9, 18);
    cell.contentConfiguration = config;

    UIBackgroundConfiguration *background = [UIBackgroundConfiguration clearConfiguration];
    background.backgroundColor = UIColor.secondarySystemBackgroundColor;
    background.cornerRadius = 10;
    background.backgroundInsets = NSDirectionalEdgeInsetsMake(3, 12, 3, 12);
    cell.backgroundConfiguration = background;
    cell.backgroundColor = UIColor.clearColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.recentItems.count == 0 || indexPath.row >= self.recentItems.count) return;
    FFBookmark *bookmark = self.recentItems[indexPath.row];
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:MCMVirtualRoot()];
    __weak typeof(self) weakSelf = self;
    [browser openItemAtPath:bookmark.path title:bookmark.name
        navigationController:self.navigationController completion:^(BOOL available) {
            if (available) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件不可用"
                message:@"该项目已不存在。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        }];
}

@end
