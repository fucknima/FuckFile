#import "FFSettingsViewController.h"
#import "FFLogViewController.h"
#import "FFSupportedViewersViewController.h"
#import "FFFileAssociationsViewController.h"
#import "MCMManager.h"
#import "FFThumbnailService.h"
#import "FFLogger.h"

// Display preferences, persisted in NSUserDefaults.
static NSString *const kFFSettingsShowHiddenFiles = @"FFSettingsShowHiddenFiles";
static NSString *const kFFSettingsGridMode = @"FFSettingsGridMode";
static NSString *const kFFFoldersFirst = @"FFFoldersFirst";

@interface FFSettingsViewController ()
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic) BOOL gridMode;
@property(nonatomic) BOOL foldersFirst;
@property(nonatomic, copy) NSString *thumbnailCacheSize;
@end

@implementation FFSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"设置";
        self.navigationItem.largeTitleDisplayMode =
            UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.showHiddenFiles = [defaults boolForKey:kFFSettingsShowHiddenFiles];
    self.gridMode = [defaults boolForKey:kFFSettingsGridMode];
    if (![defaults objectForKey:kFFFoldersFirst])
        self.foldersFirst = YES;
    else
        self.foldersFirst = [defaults boolForKey:kFFFoldersFirst];
    [self reloadCacheSize];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadCacheSize];
}

- (void)reloadCacheSize
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long size = [[FFThumbnailService sharedService] diskCacheSize];
        NSString *text = [NSByteCountFormatter stringFromByteCount:(long long)size
            countStyle:NSByteCountFormatterCountStyleFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.thumbnailCacheSize = text;
            [weakSelf.tableView reloadData];
        });
    });
}

#pragma mark - Table view

// 0 显示 / 1 文件查看 / 2 存储与缓存 / 3 高级与调试 / 4 关于
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 3; // 默认视图 / 显示隐藏文件 / 文件夹优先
        case 1: return 2; // 支持的文件查看器 / 文件关联
        case 2: return 2; // 缩略图缓存 / 清理缓存
        case 3: return 2; // 重新扫描 App 数据 / 运行日志
        case 4: return 1; // 关于
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"显示";
        case 1: return @"文件查看";
        case 2: return @"存储与缓存";
        case 3: return @"高级 / 调试";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    cell.imageView.tintColor = [UIColor systemBlueColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"默认视图";
            cell.detailTextLabel.text = self.gridMode ? @"网格" : @"列表";
            cell.imageView.image = [UIImage systemImageNamed:
                self.gridMode ? @"square.grid.2x2" : @"list.bullet"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"显示隐藏文件";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.showHiddenFiles;
            [toggle addTarget:self action:@selector(hiddenFilesChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.imageView.image = [UIImage systemImageNamed:@"eye"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"文件夹优先";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.foldersFirst;
            [toggle addTarget:self action:@selector(foldersFirstChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.imageView.image = [UIImage systemImageNamed:@"folder"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"支持的文件查看器";
            cell.detailTextLabel.text = @"图片/文本/plist/SQLite/Hex/Web 等";
            cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
        } else {
            cell.textLabel.text = @"文件关联";
            cell.detailTextLabel.text = @"扩展名 → 查看器映射，立即生效";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.branch"];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"缩略图缓存";
            cell.detailTextLabel.text = self.thumbnailCacheSize ?: @"…";
            cell.imageView.image = [UIImage systemImageNamed:@"photo.on.rectangle.angled"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"清理缓存";
            cell.detailTextLabel.text = @"删除缩略图缓存";
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"重新扫描 App 数据";
            cell.detailTextLabel.text = @"重新发现 App 容器并建链";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
        } else {
            cell.textLabel.text = @"运行日志";
            cell.detailTextLabel.text = @"查看、分享、导出诊断信息";
            cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    // 关于
    cell.textLabel.text = @"FuckFile";
    cell.detailTextLabel.text = [NSString stringWithFormat:
        @"Version %@ · Build %@ · iOS %@",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
        UIDevice.currentDevice.systemVersion];
    cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self chooseDefaultView];
        return;
    }
    if (indexPath.section == 1) {
        UIViewController *page = indexPath.row == 0 ?
            (UIViewController *)[FFSupportedViewersViewController new] :
            (UIViewController *)[FFFileAssociationsViewController new];
        [self.navigationController pushViewController:page animated:YES];
        return;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 1) [self clearCaches];
        return;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 0) [self rescanAppData];
        else [self.navigationController pushViewController:[FFLogViewController new] animated:YES];
        return;
    }
    if (indexPath.section == 4) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"关于"
            message:@"FuckFile — iOS 容器文件管理器\n基于 MobileHouseArrest 身份访问技术"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// 默认视图：控制新打开目录的列表/网格模式（浏览器内可随时切换）。
- (void)chooseDefaultView
{
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"默认视图"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"列表"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf setDefaultGrid:NO];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"网格"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf setDefaultGrid:YES];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setDefaultGrid:(BOOL)grid
{
    self.gridMode = grid;
    [NSUserDefaults.standardUserDefaults setBool:grid forKey:kFFSettingsGridMode];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FFSettingsChangedNotification" object:nil];
    [self.tableView reloadData];
}

- (void)clearCaches
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long size = [[FFThumbnailService sharedService] diskCacheSize];
        [[FFThumbnailService sharedService] clearCaches];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf reloadCacheSize];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"缓存已清理"
                message:[NSString stringWithFormat:@"释放约 %@。",
                    [NSByteCountFormatter stringFromByteCount:(long long)size
                        countStyle:NSByteCountFormatterCountStyleFile]]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (void)rescanAppData
{
    __weak typeof(self) weakSelf = self;
    [[MCMManager sharedManager] rescanWithCompletion:^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成"
            message:@"App 数据已重新扫描。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
}

#pragma mark - Toggles

- (void)hiddenFilesChanged:(UISwitch *)toggle
{
    self.showHiddenFiles = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.showHiddenFiles
                                           forKey:kFFSettingsShowHiddenFiles];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

- (void)foldersFirstChanged:(UISwitch *)toggle
{
    self.foldersFirst = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.foldersFirst
                                           forKey:kFFFoldersFirst];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

+ (BOOL)showsHiddenFilesByDefault
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kFFSettingsShowHiddenFiles];
}

+ (BOOL)gridModeEnabled
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kFFSettingsGridMode];
}

@end
