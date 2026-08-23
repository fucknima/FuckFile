#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFLogViewController.h"
#import "FFTasksViewController.h"
#import "FFSearchViewController.h"
#import "FFBookmarksViewController.h"
#import "FFSettingsViewController.h"
#import "FFPathPolicy.h"
#import "MCMManager.h"
#import "FFFileTaskManager.h"
#import "FFLogger.h"

@interface FFHomeViewController ()
@property(nonatomic) NSUInteger appCount;
@property(nonatomic) BOOL scanInProgress;
@property(nonatomic) double scanProgress;
@property(nonatomic) NSUInteger scanTotal;
@property(nonatomic) NSUInteger scanLinked;
@property(nonatomic, copy) NSDate *lastScanDate;
@property(nonatomic) NSUInteger activeTaskCount;
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
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self
        action:@selector(reloadStatus)];

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
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self reloadStatus];
}

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
        dispatch_async(dispatch_get_main_queue(), ^{
            self.appCount = count;
            self.activeTaskCount = active;
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 2;
        case 1: return 4;
        case 2: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"位置";
        case 1: return @"快捷访问";
        case 2: return nil;
        default: return nil;
    }
}

- (NSString *)deviceStorageSubtitle
{
    if (self.scanInProgress) {
        NSUInteger done = (NSUInteger)(self.scanTotal * self.scanProgress);
        return [NSString stringWithFormat:@"正在扫描 %lu/%lu · 已发现 %lu 个 App",
            (unsigned long)done, (unsigned long)self.scanTotal,
            (unsigned long)self.scanLinked];
    }
    NSMutableString *subtitle = [NSMutableString stringWithFormat:
        @"%lu 个 App", (unsigned long)self.appCount];
    if (self.lastScanDate) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm";
        [subtitle appendFormat:@" · 最近扫描 %@", [formatter stringFromDate:self.lastScanDate]];
    }
    return subtitle;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Home"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Home"];

    NSString *title = nil;
    NSString *subtitle = nil;
    NSString *symbol = nil;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            title = @"设备存储";
            subtitle = [self deviceStorageSubtitle];
            symbol = @"internaldrive";
        } else {
            title = @"导入";
            subtitle = @"外部应用分享与手动导入的文件";
            symbol = @"tray.and.arrow.down";
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            title = @"搜索";
            subtitle = @"全局搜索 App 数据";
            symbol = @"magnifyingglass";
        } else if (indexPath.row == 1) {
            title = @"收藏";
            subtitle = @"收藏的文件与文件夹";
            symbol = @"star";
        } else if (indexPath.row == 2) {
            title = @"最近访问";
            subtitle = @"最近打开的目录与文件";
            symbol = @"clock";
        } else {
            title = @"任务中心";
            subtitle = self.activeTaskCount > 0
                ? [NSString stringWithFormat:@"%lu 个任务进行中", (unsigned long)self.activeTaskCount]
                : @"复制、移动、解压任务";
            symbol = @"clock.arrow.circlepath";
        }
    } else {
        title = @"设置";
        subtitle = @"显示、文件查看、高级与调试";
        symbol = @"gearshape";
    }

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = title;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.secondaryText = subtitle;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.secondaryTextProperties.numberOfLines = 1;
    config.image = [UIImage systemImageNamed:symbol];
    config.imageProperties.tintColor = UIColor.systemBlueColor;
    config.imageProperties.maximumSize = CGSizeMake(28, 28);
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // 保持原主入口语义：进入虚拟根，展示 AppData / Imported /
                // 诊断文件等 Device Storage 内容。
                next = [[FFBrowserViewController alloc] initWithPath:MCMVirtualRoot()];
            } else {
                NSString *imported = [MCMVirtualRoot() stringByAppendingPathComponent:@"Imported"];
                next = [[FFBrowserViewController alloc] initWithPath:imported];
                next.title = @"Imported";
            }
            break;
        case 1:
            if (indexPath.row == 0) next = [FFSearchViewController new];
            else if (indexPath.row == 1) next = [[FFBookmarksViewController alloc]
                initWithMode:FFBookmarksModeFavorites];
            else if (indexPath.row == 2) next = [[FFBookmarksViewController alloc]
                initWithMode:FFBookmarksModeRecent];
            else next = [FFTasksViewController new];
            break;
        case 2:
            next = [FFSettingsViewController new];
            break;
    }
    if (next) [self.navigationController pushViewController:next animated:YES];
}

@end
