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
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:FFSystemAccessPreferenceDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            [weakSelf reloadPreferences];
            [weakSelf.tableView reloadData];
        }];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }

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
    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    if (access.state == FFSystemAccessStateFailed && access.failureReason.length)
        return [NSString stringWithFormat:@"高级系统访问启用失败：%@\n本地文件管理仍可正常使用。", access.failureReason];
    if (self.systemAccessEnabled)
        return @"高级系统访问只增加 App Data 等受保护位置；本地文件始终使用同一个“设备存储”目录。关闭后本次进程已加载的能力不会强行卸载，下次启动恢复普通模式。";
    return @"默认关闭。关闭时不初始化高级系统访问组件，本地文件、搜索、收藏、最近访问等普通功能保持可用。";
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
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
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
                cell.imageView.image = [UIImage systemImageNamed:self.gridMode ? @"square.grid.2x2" : @"list.bullet"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"显示隐藏文件";
                UISwitch *toggle = [UISwitch new];
                toggle.on = self.showHiddenFiles;
                [toggle addTarget:self action:@selector(hiddenFilesChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                cell.imageView.image = [UIImage systemImageNamed:@"eye"];
            } else {
                cell.textLabel.text = @"文件夹优先";
                cell.detailTextLabel.text = @"排序时目录排在文件前面";
                UISwitch *toggle = [UISwitch new];
                toggle.on = self.foldersFirst;
                [toggle addTarget:self action:@selector(foldersFirstChanged:) forControlEvents:UIControlEventValueChanged];
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
            } else {
                cell.textLabel.text = @"文件关联";
                cell.detailTextLabel.text = @"扩展名 → 查看器映射，立即生效";
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.branch"];
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"缩略图缓存";
                unsigned long long size = FFThumbnailService.sharedService.diskCacheSize;
                cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:(long long)size
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
            FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
            cell.textLabel.text = @"启用高级系统访问";
            switch (access.state) {
                case FFSystemAccessStateLoading: cell.detailTextLabel.text = @"正在加载…"; break;
                case FFSystemAccessStateReady: cell.detailTextLabel.text = @"本次会话已就绪"; break;
                case FFSystemAccessStateFailed: cell.detailTextLabel.text = @"启用失败，本地文件仍可用"; break;
                case FFSystemAccessStateIdle: cell.detailTextLabel.text = @"等待加载"; break;
                default: cell.detailTextLabel.text = @"普通文件管理模式"; break;
            }
            cell.imageView.image = [UIImage systemImageNamed:access.ready ? @"lock.open.fill" : @"lock.open"];
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.systemAccessEnabled;
            toggle.enabled = access.state != FFSystemAccessStateLoading;
            [toggle addTarget:self action:@selector(systemAccessChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case 4: {
            if (indexPath.row == 0) {
                BOOL ready = FFSystemAccessManager.sharedManager.ready;
                cell.textLabel.text = @"重新扫描 App Data";
                cell.detailTextLabel.text = ready ? @"重新发现可访问的 App 数据" : @"高级系统访问就绪后可用";
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
                cell.accessoryType = ready ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
                cell.selectionStyle = ready ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
                cell.textLabel.enabled = ready;
                cell.detailTextLabel.enabled = ready;
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
            cell.detailTextLabel.text = [NSString stringWithFormat:@"版本 %@（构建 %@）· iOS %@",
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
            if (!FFSystemAccessManager.sharedManager.ready) return;
            [[MCMManager sharedManager] rescanWithCompletion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成"
                    message:@"App 数据已重新扫描。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
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
    [NSNotificationCenter.defaultCenter postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

- (void)foldersFirstChanged:(UISwitch *)toggle
{
    self.foldersFirst = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.foldersFirst forKey:kFFSettingsFoldersFirst];
    [NSNotificationCenter.defaultCenter postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

- (void)systemAccessChanged:(UISwitch *)toggle
{
    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    if (!toggle.on) {
        BOOL wasLoaded = access.loadedThisSession;
        [access setEnabled:NO];
        self.systemAccessEnabled = NO;
        [self.tableView reloadData];
        if (wasLoaded) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下次启动完全恢复普通模式"
                message:@"本次进程已经加载过高级系统访问组件，不强制热卸载。当前本地文件仍可继续使用；退出并重新打开 FuckFile 后将清理生成的虚拟入口。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        return;
    }

    toggle.on = NO;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"启用高级系统访问？"
        message:@"启用后只会在“设备存储”中增加 App Data 等高级入口；本地文件目录不会切换。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [access setEnabled:YES];
            weakSelf.systemAccessEnabled = YES;
            [weakSelf.tableView reloadData];
            [access loadNowWithCompletion:^(BOOL loaded) {
                [weakSelf reloadPreferences];
                [weakSelf.tableView reloadData];
                NSString *title = loaded ? @"系统访问已启用" : @"系统访问启用失败";
                NSString *message = loaded ? @"App Data 等高级入口已经可用。"
                    : (access.failureReason ?: @"未能获得高级系统访问能力。本地文件管理不受影响。");
                UIAlertController *result = [UIAlertController alertControllerWithTitle:title
                    message:message preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:result animated:YES completion:nil];
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