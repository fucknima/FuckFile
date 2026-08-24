#import "FFSettingsViewController.h"
#import "FFLogViewController.h"
#import "FFSupportedViewersViewController.h"
#import "FFFileAssociationsViewController.h"
#import "FFSystemAccessManager.h"
#import "MCMManager.h"
#import "FFThumbnailService.h"
#import "FFLogger.h"

static NSString *const kFFSettingsShowHiddenFiles = @"FFSettingsShowHiddenFiles";
static NSString *const kFFSettingsGridMode = @"FFSettingsGridMode";
static NSString *const kFFSettingsFoldersFirst = @"FFSettingsFoldersFirst";

@interface FFSettingsViewController ()
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic) BOOL gridMode;
@property(nonatomic) BOOL foldersFirst;
@property(nonatomic) BOOL systemAccessEnabled;
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
    [self reloadPreferences];
    [self.tableView reloadData];
}

- (void)reloadPreferences
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.showHiddenFiles = [defaults boolForKey:kFFSettingsShowHiddenFiles];
    self.gridMode = [defaults boolForKey:kFFSettingsGridMode];
    id foldersFirst = [defaults objectForKey:kFFSettingsFoldersFirst];
    self.foldersFirst = foldersFirst == nil ? YES : [foldersFirst boolValue];
    self.systemAccessEnabled = FFSystemAccessManager.sharedManager.enabled;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 6;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 3;
        case 1: return 2;
        case 2: return 2;
        case 3: return 1;
        case 4: return 2;
        case 5: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"显示";
        case 1: return @"文件查看";
        case 2: return @"存储与缓存";
        case 3: return @"系统访问";
        case 4: return @"高级 / 调试";
        case 5: return @"关于";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != 3) return nil;
    return self.systemAccessEnabled
        ? @"开启后会加载高级系统访问能力。关闭后本次进程已加载的能力不会强行卸载，下次启动将恢复普通文件管理模式。"
        : @"默认关闭。关闭时不初始化高级系统访问组件，FuckFile 按普通文件管理器运行。";
}

- (UIColor *)iconTintForIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0)
        return indexPath.row == 1 ? UIColor.systemTealColor : UIColor.systemBlueColor;
    if (indexPath.section == 1)
        return indexPath.row == 0 ? UIColor.systemBlueColor : UIColor.systemIndigoColor;
    if (indexPath.section == 2)
        return indexPath.row == 0 ? UIColor.systemOrangeColor : UIColor.systemRedColor;
    if (indexPath.section == 3) return UIColor.systemPurpleColor;
    if (indexPath.section == 4)
        return indexPath.row == 0 ? UIColor.systemBlueColor : UIColor.systemGrayColor;
    return UIColor.systemGrayColor;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.numberOfLines = 1;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;
    cell.imageView.tintColor = [self iconTintForIndexPath:indexPath];

    switch (indexPath.section) {
        case 0: {
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
                cell.detailTextLabel.text = @"图片/文本/PDF/plist/SQLite/Hex/Web 等";
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
                unsigned long long size = FFThumbnailService.sharedService.diskCacheSize;
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
            cell.textLabel.text = @"启用高级系统访问";
            cell.detailTextLabel.text = self.systemAccessEnabled
                ? (FFSystemAccessManager.sharedManager.loadedThisSession ? @"本次会话已加载" : @"将在需要时加载")
                : @"普通文件管理模式";
            cell.imageView.image = [UIImage systemImageNamed:@"lock.open"];
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.systemAccessEnabled;
            [toggle addTarget:self action:@selector(systemAccessChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case 4: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"重新扫描 App Data";
                cell.detailTextLabel.text = self.systemAccessEnabled ? @"重新发现可访问的 App 数据" : @"需先启用高级系统访问";
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
                cell.accessoryType = self.systemAccessEnabled
                    ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
                cell.selectionStyle = self.systemAccessEnabled
                    ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
                cell.textLabel.enabled = self.systemAccessEnabled;
                cell.detailTextLabel.enabled = self.systemAccessEnabled;
            } else {
                cell.textLabel.text = @"运行日志";
                cell.detailTextLabel.text = @"查看、分享、导出诊断信息";
                cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;
        }
        case 5: {
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
    if (indexPath.section == 2 && indexPath.row == 1) {
        unsigned long long size = FFThumbnailService.sharedService.diskCacheSize;
        [FFThumbnailService.sharedService clearCaches];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"缓存已清理"
            message:[NSString stringWithFormat:@"释放约 %@。",
                [NSByteCountFormatter stringFromByteCount:(long long)size
                    countStyle:NSByteCountFormatterCountStyleFile]]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self.tableView reloadData];
        return;
    }
    if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            if (!self.systemAccessEnabled) return;
            [FFSystemAccessManager.sharedManager loadNowWithCompletion:^(__unused BOOL loaded) {
                [[MCMManager sharedManager] rescanWithCompletion:^{
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成"
                        message:@"App 数据已重新扫描。" preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                }];
            }];
        } else {
            [self.navigationController pushViewController:[FFLogViewController new] animated:YES];
        }
    }
}

#pragma mark - Default view picker

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
}

#pragma mark - Toggles

- (void)hiddenFilesChanged:(UISwitch *)toggle
{
    self.showHiddenFiles = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.showHiddenFiles forKey:kFFSettingsShowHiddenFiles];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

- (void)foldersFirstChanged:(UISwitch *)toggle
{
    self.foldersFirst = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.foldersFirst forKey:kFFSettingsFoldersFirst];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

- (void)systemAccessChanged:(UISwitch *)toggle
{
    if (!toggle.on) {
        [FFSystemAccessManager.sharedManager setEnabled:NO];
        self.systemAccessEnabled = NO;
        [self.tableView reloadData];
        if (FFSystemAccessManager.sharedManager.loadedThisSession) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下次启动恢复普通模式"
                message:@"本次进程已经加载过高级系统访问组件，不强制热卸载。退出并重新打开 FuckFile 后将完全按普通文件管理器运行。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        return;
    }

    toggle.on = NO;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"启用高级系统访问？"
        message:@"启用后会在本次会话加载系统访问组件，并允许访问 App Data 等受保护位置。普通文件管理功能不依赖此开关。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [FFSystemAccessManager.sharedManager setEnabled:YES];
            weakSelf.systemAccessEnabled = YES;
            [weakSelf.tableView reloadData];
            [FFSystemAccessManager.sharedManager loadNowWithCompletion:^(BOOL loaded) {
                [weakSelf.tableView reloadData];
                if (!loaded) return;
                UIAlertController *ready = [UIAlertController alertControllerWithTitle:@"系统访问已启用"
                    message:@"高级系统访问组件已加载。" preferredStyle:UIAlertControllerStyleAlert];
                [ready addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:ready animated:YES completion:nil];
            }];
        }]];
    [self presentViewController:confirm animated:YES completion:nil];
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
