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
static NSString *const kFFSettingsFoldersFirst = @"FFSettingsFoldersFirst";

@interface FFSettingsViewController ()
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic) BOOL gridMode;
@property(nonatomic) BOOL foldersFirst;
@end

@implementation FFSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"设置";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self reloadPreferences];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // 缓存大小可能变化，每次进入刷新。
    [self.tableView reloadData];
}

- (void)reloadPreferences
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.showHiddenFiles = [defaults boolForKey:kFFSettingsShowHiddenFiles];
    self.gridMode = [defaults boolForKey:kFFSettingsGridMode];
    id foldersFirst = [defaults objectForKey:kFFSettingsFoldersFirst];
    // 历史行为：浏览器一直文件夹优先，未设置时保持开启。
    self.foldersFirst = foldersFirst == nil ? YES : [foldersFirst boolValue];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 3; // 默认视图 / 显示隐藏文件 / 文件夹优先
        case 1: return 2; // 文件查看
        case 2: return 2; // 存储与缓存
        case 3: return 2; // 高级 / 调试
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
        case 4: return @"关于";
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

    switch (indexPath.section) {
        case 0: {
            if (indexPath.row == 0) {
                // 默认视图只决定新打开目录的初始模式；运行中页面用
                // 浏览器"更多 → 显示方式"局部切换。
                cell.textLabel.text = @"默认视图";
                cell.detailTextLabel.text = self.gridMode ? @"网格" : @"列表";
                cell.imageView.image = [UIImage systemImageNamed:
                    self.gridMode ? @"square.grid.2x2" : @"list.bullet"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"显示隐藏文件";
                cell.detailTextLabel.text = nil;
                UISwitch *toggle = [UISwitch new];
                toggle.on = self.showHiddenFiles;
                [toggle addTarget:self action:@selector(hiddenFilesChanged:)
                 forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                cell.imageView.image = [UIImage systemImageNamed:@"eye"];
            } else {
                cell.textLabel.text = @"文件夹优先";
                cell.detailTextLabel.text = @"排序时目录排在文件前面";
                UISwitch *toggle = [UISwitch new];
                toggle.on = self.foldersFirst;
                [toggle addTarget:self action:@selector(foldersFirstChanged:)
                 forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                cell.imageView.image = [UIImage systemImageNamed:@"folder"];
            }
            break;
        }
        case 1: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"支持的文件查看器";
                cell.detailTextLabel.text = @"图片/文本/plist/SQLite/Hex/Web 等";
                cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else {
                cell.textLabel.text = @"文件关联";
                cell.detailTextLabel.text = @"扩展名 → 查看器映射，立即生效";
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.branch"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"缩略图缓存";
                unsigned long long size = [[FFThumbnailService sharedService] diskCacheSize];
                cell.detailTextLabel.text = [NSByteCountFormatter
                    stringFromByteCount:(long long)size
                    countStyle:NSByteCountFormatterCountStyleFile];
                cell.imageView.image = [UIImage systemImageNamed:@"photo.on.rectangle"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = @"清理缓存";
                cell.detailTextLabel.text = @"删除缩略图缓存";
                cell.imageView.image = [UIImage systemImageNamed:@"trash"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
        }
        case 3: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"重新扫描 App Data";
                cell.detailTextLabel.text = nil;
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else {
                cell.textLabel.text = @"运行日志";
                cell.detailTextLabel.text = @"查看、分享、导出诊断信息";
                cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
        }
        case 4: {
            cell.textLabel.text = @"FuckFile";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"版本 %@（构建 %@）· iOS %@",
                NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                UIDevice.currentDevice.systemVersion];
            cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 0) {
        [self showDefaultViewPicker];
        return;
    }
    if (indexPath.section == 1) {
        UIViewController *page = indexPath.row == 0 ?
            (UIViewController *)[FFSupportedViewersViewController new] :
            (UIViewController *)[FFFileAssociationsViewController new];
        [self.navigationController pushViewController:page animated:YES];
        return;
    }
    switch (indexPath.section) {
        case 2: { // 清理缓存
            unsigned long long size = [[FFThumbnailService sharedService] diskCacheSize];
            [[FFThumbnailService sharedService] clearCaches];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"缓存已清理"
                message:[NSString stringWithFormat:@"释放约 %@。",
                    [NSByteCountFormatter stringFromByteCount:(long long)size
                        countStyle:NSByteCountFormatterCountStyleFile]]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            [self.tableView reloadData];
            break;
        }
        case 3: {
            if (indexPath.row == 0) {
                [[MCMManager sharedManager] rescanWithCompletion:^{
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成"
                        message:@"App 数据已重新扫描。" preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                }];
            } else {
                FFLogViewController *log = [FFLogViewController new];
                [self.navigationController pushViewController:log animated:YES];
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - Default view picker

// iPad 必须给 popover 锚点，否则直接崩溃。
- (void)showDefaultViewPicker
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"默认视图"
        message:@"新打开目录使用的显示方式" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"列表"
        style:self.gridMode ? UIAlertActionStyleDefault : UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { [weakSelf setDefaultGrid:NO]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"网格"
        style:self.gridMode ? UIAlertActionStyleCancel : UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setDefaultGrid:YES]; }]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setDefaultGrid:(BOOL)grid
{
    self.gridMode = grid;
    [NSUserDefaults.standardUserDefaults setBool:grid forKey:kFFSettingsGridMode];
    [self.tableView reloadData];
    // 不广播 FFSettingsChangedNotification：默认值只影响新打开的目录，
    // 运行中页面由其"更多 → 显示方式"自行控制。
}

#pragma mark - Toggles

- (void)hiddenFilesChanged:(UISwitch *)toggle
{
    self.showHiddenFiles = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.showHiddenFiles
                                           forKey:kFFSettingsShowHiddenFiles];
    // 已存在的浏览器页面应即时刷新。
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

- (void)foldersFirstChanged:(UISwitch *)toggle
{
    self.foldersFirst = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.foldersFirst
                                           forKey:kFFSettingsFoldersFirst];
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
