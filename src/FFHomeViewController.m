#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFLogViewController.h"
#import "FFTasksViewController.h"
#import "FFSearchViewController.h"
#import "FFBookmarksViewController.h"
#import "FFSettingsViewController.h"
#import "FFSystemAccessManager.h"
#import "FFAppDataScanCoordinator.h"
#import "FFStorageEnvironment.h"
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

    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
    self.scanInProgress = scan.scanning;
    self.scanProgress = scan.progress;
    self.scanTotal = scan.total;
    self.scanLinked = scan.linked;

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFProbeFinished"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadStatus]; });
        }];
    [[NSNotificationCenter defaultCenter] addObserverForName:FFSystemAccessPreferenceDidChangeNotification
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
    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
    self.scanInProgress = scan.scanning;
    self.scanProgress = scan.progress;
    self.scanTotal = scan.total;
    self.scanLinked = scan.linked;
    [self reloadStatus];
}

- (void)refreshTapped
{
    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;

    // Refresh is deliberately inert while enabling or scanning. The previous
    // implementation queued another full rescan while the first async LS pass
    // was still running, causing duplicate ContainerManager traffic and UI
    // stalls. There must be at most one discovery pass in flight.
    if (!access.enabled || !access.ready || access.state == FFSystemAccessStateLoading ||
        scan.scanning || self.scanInProgress) {
        [self reloadStatus];
        return;
    }

    self.scanInProgress = YES;
    [self reloadStatus];
    __weak typeof(self) weakSelf = self;
    [scan scanWithCompletion:^{
        [weakSelf reloadStatus];
    }];
}

- (void)reloadStatus
{
    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
    BOOL ready = access.ready;
    self.scanInProgress = scan.scanning;

    if (access.enabled) {
        UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
            target:self action:@selector(refreshTapped)];
        refresh.enabled = ready && !scan.scanning && access.state != FFSystemAccessStateLoading;
        refresh.accessibilityHint = refresh.enabled ? @"重新扫描 App Data" : @"扫描进行中";
        self.navigationItem.rightBarButtonItem = refresh;
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSUInteger count = ready
            ? [[NSFileManager.defaultManager contentsOfDirectoryAtPath:FFAppDataVirtualPath() error:nil] count]
            : 0;
        NSUInteger active = 0;
        for (FFFileTask *task in FFFileTaskManager.sharedManager.tasks)
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
        case 0: return @"位置";
        case 1: return @"快捷访问";
        case 2: return @"设置";
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
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    BOOL ready = access.ready;
    switch (indexPath.section) {
        case 0: {
            cell.textLabel.text = @"设备存储";
            cell.imageView.image = [UIImage systemImageNamed:ready ? @"internaldrive" : @"folder"];
            cell.imageView.tintColor = UIColor.systemBlueColor;
            if (ready) {
                if (self.scanInProgress) {
                    NSUInteger done = self.scanTotal > 0
                        ? MIN(self.scanTotal, (NSUInteger)(self.scanTotal * self.scanProgress)) : 0;
                    cell.detailTextLabel.text = self.scanTotal > 0
                        ? [NSString stringWithFormat:@"高级访问已就绪 · 后台扫描 %lu/%lu · 已发现 %lu 个 App",
                            (unsigned long)done, (unsigned long)self.scanTotal,
                            (unsigned long)self.scanLinked]
                        : @"高级访问已就绪 · 正在后台发现 App Data…";
                } else {
                    NSMutableString *subtitle = [NSMutableString stringWithFormat:
                        @"本地文件 + %lu 个 App Data", (unsigned long)self.appCount];
                    if (self.lastScanDate) {
                        NSDateFormatter *formatter = [NSDateFormatter new];
                        formatter.dateFormat = @"HH:mm";
                        [subtitle appendFormat:@" · 最近扫描 %@", [formatter stringFromDate:self.lastScanDate]];
                    }
                    cell.detailTextLabel.text = subtitle;
                }
            } else if (access.state == FFSystemAccessStateLoading) {
                cell.detailTextLabel.text = @"本地文件可用 · 正在快速启用高级系统访问…";
            } else if (access.state == FFSystemAccessStateFailed) {
                cell.detailTextLabel.text = @"本地文件可用 · 高级系统访问启用失败";
            } else {
                cell.detailTextLabel.text = @"普通文件管理模式";
            }
            break;
        }
        case 1: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"搜索";
                cell.detailTextLabel.text = ready ? @"搜索本地文件与 App Data" : @"搜索本地文件";
                cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
                cell.imageView.tintColor = UIColor.systemBlueColor;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"收藏";
                cell.detailTextLabel.text = @"收藏的文件与文件夹";
                cell.imageView.image = [UIImage systemImageNamed:@"star"];
                cell.imageView.tintColor = UIColor.systemYellowColor;
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"最近访问";
                cell.detailTextLabel.text = @"最近打开的目录与文件";
                cell.imageView.image = [UIImage systemImageNamed:@"clock"];
                cell.imageView.tintColor = UIColor.systemTealColor;
            } else {
                cell.textLabel.text = @"任务中心";
                cell.detailTextLabel.text = self.activeTaskCount > 0
                    ? [NSString stringWithFormat:@"%lu 个任务进行中", (unsigned long)self.activeTaskCount]
                    : @"复制、移动、解压任务";
                cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
                cell.imageView.tintColor = UIColor.systemIndigoColor;
            }
            break;
        }
        case 2: {
            cell.textLabel.text = @"设置";
            cell.detailTextLabel.text = @"显示、查看器、系统访问与调试";
            cell.imageView.image = [UIImage systemImageNamed:@"gearshape"];
            cell.imageView.tintColor = UIColor.systemGrayColor;
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
            next = [[FFBrowserViewController alloc] initWithPath:FFStorageRootPath()];
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
