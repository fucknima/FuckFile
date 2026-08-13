#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFLogViewController.h"
#import "FFTasksViewController.h"
#import "FFSearchViewController.h"
#import "FFBookmarksViewController.h"
#import "FFSettingsViewController.h"
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
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
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
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self reloadStatus];
}

- (void)reloadStatus
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *appData = [MCMVirtualRoot() stringByAppendingPathComponent:@"App Data"];
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
        case 0: return 1;
        case 1: return 4;
        case 2: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"文件";
        case 1: return @"快捷访问";
        case 2: return nil;
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Home"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Home"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.tintColor = [UIColor systemBlueColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    switch (indexPath.section) {
        case 0: {
            // 主入口：App 数据
            cell.textLabel.text = @"App 数据";
            cell.imageView.image = [UIImage systemImageNamed:@"app.dashed"];
            if (self.scanInProgress) {
                NSUInteger done = (NSUInteger)(self.scanTotal * self.scanProgress);
                cell.detailTextLabel.text = [NSString stringWithFormat:
                    @"正在扫描 %lu/%lu … 已发现 %lu 个 App",
                    (unsigned long)done, (unsigned long)self.scanTotal,
                    (unsigned long)self.scanLinked];
            } else {
                NSMutableString *subtitle = [NSMutableString stringWithFormat:
                    @"%lu 个 App", (unsigned long)self.appCount];
                if (self.lastScanDate) {
                    NSDateFormatter *formatter = [NSDateFormatter new];
                    formatter.dateFormat = @"HH:mm";
                    [subtitle appendFormat:@" · 最近扫描 %@", [formatter stringFromDate:self.lastScanDate]];
                }
                cell.detailTextLabel.text = subtitle;
            }
            break;
        }
        case 1: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"搜索";
                cell.detailTextLabel.text = @"全局搜索 App 数据";
                cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"收藏";
                cell.detailTextLabel.text = @"收藏的文件与文件夹";
                cell.imageView.image = [UIImage systemImageNamed:@"star"];
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"最近访问";
                cell.detailTextLabel.text = @"最近打开的目录与文件";
                cell.imageView.image = [UIImage systemImageNamed:@"clock"];
            } else {
                cell.textLabel.text = @"任务中心";
                cell.detailTextLabel.text = self.activeTaskCount > 0
                    ? [NSString stringWithFormat:@"%lu 个任务进行中", (unsigned long)self.activeTaskCount]
                    : @"复制、移动、解压任务";
                cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
            }
            break;
        }
        case 2: {
            cell.textLabel.text = @"设置";
            cell.detailTextLabel.text = @"显示、排序、高级与调试";
            cell.imageView.image = [UIImage systemImageNamed:@"gearshape"];
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    switch (indexPath.section) {
        case 0:
            next = [[FFBrowserViewController alloc] initWithPath:
                [MCMVirtualRoot() stringByAppendingPathComponent:@"App Data"]];
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
