#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFLogViewController.h"
#import "FFTasksViewController.h"
#import "FFSearchViewController.h"
#import "FFBookmarksViewController.h"
#import "MCMManager.h"
#import "FFLogger.h"

@interface FFHomeViewController ()
@property(nonatomic) NSUInteger categoryCount;
@property(nonatomic) NSUInteger linkCount;
@property(nonatomic) BOOL scanInProgress;
@property(nonatomic) double scanProgress;
@property(nonatomic) NSUInteger scanTotal;
@property(nonatomic) NSUInteger scanLinked;
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
                }
                [weakSelf reloadStatus];
            });
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
        NSUInteger links = [[manager contentsOfDirectoryAtPath:appData error:nil] count];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.categoryCount = 1;
            self.linkCount = links;
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
        case 0: return 3;
        case 1: return 3;
        case 2: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"存储";
        case 1: return @"工具";
        case 2: return @"关于";
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
            if (indexPath.row == 0) {
                cell.textLabel.text = @"App 数据";
                if (self.scanInProgress) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:
                        @"正在扫描 %lu/%lu … %lu 个 App",
                        (unsigned long)self.scanTotal, (unsigned long)self.scanTotal,
                        (unsigned long)self.scanLinked];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:
                        @"%lu 个 App 容器 · %lu 个已逃逸链接",
                        (unsigned long)self.categoryCount,
                        (unsigned long)self.linkCount];
                }
                cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"收藏";
                cell.detailTextLabel.text = @"收藏的文件夹与文件";
                cell.imageView.image = [UIImage systemImageNamed:@"star"];
            } else {
                cell.textLabel.text = @"最近访问";
                cell.detailTextLabel.text = @"最近打开的目录与文件";
                cell.imageView.image = [UIImage systemImageNamed:@"clock"];
            }
            break;
        }
        case 1: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"任务中心";
                cell.detailTextLabel.text = @"复制 / 移动 / 解压任务与进度";
                cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"搜索";
                cell.detailTextLabel.text = @"全局递归搜索与搜索历史";
                cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
            } else {
                cell.textLabel.text = @"运行日志";
                cell.detailTextLabel.text = @"查看、分享、重跑扫描、清缓存";
                cell.imageView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
            }
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"版本";
                cell.detailTextLabel.text = [NSString stringWithFormat:
                    @"%@（构建 %@）· iOS %@",
                    NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                    NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                    UIDevice.currentDevice.systemVersion];
                cell.imageView.image = [UIImage systemImageNamed:@"info.circle.fill"];
            } else {
                cell.textLabel.text = @"致谢";
                cell.detailTextLabel.text = @"MCM：FilzaSlop · 身份：MobileHouseArrest";
                cell.imageView.image = [UIImage systemImageNamed:@"person.3.fill"];
            }
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
            if (indexPath.row == 0) {
                NSString *appData = [MCMVirtualRoot() stringByAppendingPathComponent:@"App Data"];
                next = [[FFBrowserViewController alloc] initWithPath:appData];
            } else if (indexPath.row == 1) {
                next = [[FFBookmarksViewController alloc] initWithMode:FFBookmarksModeFavorites];
            } else {
                next = [[FFBookmarksViewController alloc] initWithMode:FFBookmarksModeRecent];
            }
            break;
        case 1:
            if (indexPath.row == 0) {
                next = [FFTasksViewController new];
            } else if (indexPath.row == 1) {
                next = [FFSearchViewController new];
            } else {
                next = [FFLogViewController new];
            }
            break;
        case 2:
            if (indexPath.row == 1) {
                [self presentCredits];
                return;
            }
            return;
    }
    if (next) [self.navigationController pushViewController:next animated:YES];
}

- (void)presentCredits
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"致谢"
        message:@"MCM 身份绕过：0xjohnnydev/FilzaSlop"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
