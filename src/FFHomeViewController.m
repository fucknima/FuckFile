#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFProbeViewController.h"
#import "FFGestaltEditorViewController.h"
#import "BadQueryProbe.h"
#import "MCMManager.h"

@interface FFHomeViewController ()
@property(nonatomic) NSUInteger categoryCount;
@property(nonatomic) NSUInteger linkCount;
@property(nonatomic) NSUInteger escapedCount;
@property(nonatomic, copy) NSString *gestaltStatus;
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
        NSString *root = MCMVirtualRoot();
        NSFileManager *manager = NSFileManager.defaultManager;
        NSUInteger categories = 0;
        NSUInteger links = 0;
        for (NSString *name in [manager contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *path = [root stringByAppendingPathComponent:name];
            BOOL isDirectory = NO;
            if ([manager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
                categories++;
                links += [[manager contentsOfDirectoryAtPath:path error:nil] count];
            }
        }
        NSDictionary *report = BadQueryProbeLastReport();
        NSUInteger escaped = 0;
        for (NSDictionary *probe in [report[@"Probes"] isKindOfClass:NSArray.class]
            ? report[@"Probes"] : @[]) {
            if ([probe[@"Status"] isKindOfClass:NSString.class] &&
                [probe[@"Status"] isEqualToString:@"escaped"]) escaped++;
        }
        NSString *error = nil;
        NSString *gestaltPath = [[MCMManager sharedManager] mobileGestaltPath:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.categoryCount = categories;
            self.linkCount = links;
            self.escapedCount = escaped;
            self.gestaltStatus = gestaltPath ? @"Editable" : (error ?: @"Unavailable");
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 1;
        case 1: return 1;
        case 2: return 2;
        case 3: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"存储";
        case 1: return @"bad_query 探针";
        case 2: return @"工具";
        case 3: return @"关于";
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
            cell.textLabel.text = @"设备存储";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%lu 个分类目录，%lu 个有效链接", (unsigned long)self.categoryCount,
                (unsigned long)self.linkCount];
            cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
            break;
        }
        case 1: {
            cell.textLabel.text = @"探针控制台";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%lu 条逃逸路径 — 结果、日志、容器映射（UUID → 包名）",
                (unsigned long)self.escapedCount];
            cell.imageView.image = [UIImage systemImageNamed:@"waveform.path.ecg"];
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"MobileGestalt 编辑器";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"状态：%@",
                    self.gestaltStatus ?: @"检查中…"];
                cell.imageView.image = [UIImage systemImageNamed:@"iphone.gen3"];
            } else {
                cell.textLabel.text = @"壁纸实验室";
                cell.detailTextLabel.text = @"PosterBoard .tendies 导入、检查与回滚";
                cell.imageView.image = [UIImage systemImageNamed:@"photo.on.rectangle.angled"];
            }
            break;
        }
        case 3: {
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
                cell.detailTextLabel.text = @"MCM：FilzaSlop · 逃逸：bad_query · UI 参考：mond";
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
            next = [[FFBrowserViewController alloc] initWithPath:MCMVirtualRoot()];
            break;
        case 1:
            next = [FFProbeViewController new];
            break;
        case 2:
            if (indexPath.row == 0) {
                next = [FFGestaltEditorViewController new];
            } else {
                NSString *lab = [MCMVirtualRoot() stringByAppendingPathComponent:@"[MHA-C2] Wallpaper Lab"];
                next = [[FFBrowserViewController alloc] initWithPath:lab];
            }
            break;
        case 3:
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
        message:@"MCM 身份绕过与壁纸实验室：0xjohnnydev/FilzaSlop\n沙箱逃逸：forcequitOS/bad_query\nMobileGestalt 编辑器参考：rooootdev/mond"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
