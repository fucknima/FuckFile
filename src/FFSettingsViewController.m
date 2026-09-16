#import "FFSettingsViewController.h"
#import "FFLogViewController.h"
#import "FFSupportedViewersViewController.h"
#import "FFFileAssociationsViewController.h"
#import "FFWebDAVSettingsViewController.h"
#import "FFStorageAnalysisViewController.h"
#import "FFWebDAVServer.h"
#import "FFLogger.h"

static NSString *const kFFSettingsShowHiddenFiles = @"FFSettingsShowHiddenFiles";
static NSString *const kFFSettingsGridMode = @"FFSettingsGridMode";
static NSString *const kFFSettingsFoldersFirst = @"FFSettingsFoldersFirst";
static NSString *const kFFSettingsShowExtensions = @"FFSettingsShowExtensions";
static NSString *const kFFTrashRetentionDays = @"FFTrashRetentionDays";

@interface FFSettingsViewController ()
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic) BOOL gridMode;
@property(nonatomic) BOOL foldersFirst;
@property(nonatomic) BOOL showExtensions;
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
    id showExtensions = [defaults objectForKey:kFFSettingsShowExtensions];
    self.showExtensions = showExtensions == nil ? YES : [showExtensions boolValue];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 4;
        case 1: return 2;
        case 2: return 3;
        case 3: return 1;
        case 4: return 1;
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

- (UIColor *)iconTintForIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0)
        return indexPath.row == 1 ? UIColor.systemTealColor : UIColor.systemBlueColor;
    if (indexPath.section == 1)
        return indexPath.row == 0 ? UIColor.systemBlueColor : UIColor.systemIndigoColor;
    if (indexPath.section == 2)
        return UIColor.systemTealColor;
    if (indexPath.section == 3)
        return UIColor.systemBlueColor;
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
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"显示扩展名";
                cell.detailTextLabel.text = @"关闭后列表隐藏文件的扩展名";
                UISwitch *toggle = [UISwitch new];
                toggle.on = self.showExtensions;
                [toggle addTarget:self action:@selector(showExtensionsChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
                cell.imageView.image = [UIImage systemImageNamed:@"textformat"];
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
                cell.textLabel.text = @"存储空间";
                cell.detailTextLabel.text = @"设备空间 · 分类占用 · 清理缓存";
                cell.imageView.image = [UIImage systemImageNamed:@"internaldrive"];
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"回收站自动清理";
                cell.detailTextLabel.text = [self trashRetentionDescription];
                cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            } else {
                FFWebDAVServer *server = FFWebDAVServer.sharedServer;
                cell.textLabel.text = @"局域网文件共享";
                cell.detailTextLabel.text = server.running && server.addressString.length
                    ? server.addressString : @"浏览器 + WebDAV · 仅 Wi‑Fi";
                cell.imageView.image = [UIImage systemImageNamed:@"network"];
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case 3: {
            cell.textLabel.text = @"运行日志";
            cell.detailTextLabel.text = @"查看、分享、导出诊断信息";
            cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case 4: {
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
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self.navigationController pushViewController:[FFStorageAnalysisViewController new]
                animated:YES];
        } else if (indexPath.row == 1) {
            [self showTrashRetentionPicker];
        } else {
            [self.navigationController pushViewController:[FFWebDAVSettingsViewController new] animated:YES];
        }
        return;
    }
    if (indexPath.section == 3) {
        [self.navigationController pushViewController:[FFLogViewController new] animated:YES];
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

#pragma mark - Trash retention

- (NSInteger)trashRetentionDays
{
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kFFTrashRetentionDays];
    return stored == nil ? 30 : [stored integerValue];
}

- (NSString *)trashRetentionDescription
{
    NSInteger days = [self trashRetentionDays];
    if (days <= 0) return @"关闭（只手动清空）";
    return [NSString stringWithFormat:@"删除超过 %ld 天后自动清除", (long)days];
}

- (void)showTrashRetentionPicker
{
    NSInteger current = [self trashRetentionDays];
    NSArray<NSNumber *> *values = @[@0, @7, @30, @90];
    NSArray<NSString *> *titles = @[@"关闭", @"7 天", @"30 天", @"90 天"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"回收站自动清理"
        message:@"删除进回收站的项目超过保留期限后自动永久删除"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [values enumerateObjectsUsingBlock:^(NSNumber *value, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSInteger days = value.integerValue;
        UIAlertActionStyle style = days == current ? UIAlertActionStyleCancel : UIAlertActionStyleDefault;
        [sheet addAction:[UIAlertAction actionWithTitle:titles[index] style:style
            handler:^(__unused UIAlertAction *action) {
                [NSUserDefaults.standardUserDefaults setInteger:days forKey:kFFTrashRetentionDays];
                [weakSelf.tableView reloadData];
            }]];
    }];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
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

- (void)showExtensionsChanged:(UISwitch *)toggle
{
    self.showExtensions = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.showExtensions forKey:kFFSettingsShowExtensions];
    [NSNotificationCenter.defaultCenter postNotificationName:@"FFSettingsChangedNotification" object:nil];
}

+ (BOOL)showsHiddenFilesByDefault
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kFFSettingsShowHiddenFiles];
}

+ (BOOL)gridModeEnabled
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kFFSettingsGridMode];
}

+ (BOOL)showsExtensionsByDefault
{
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kFFSettingsShowExtensions];
    return stored == nil ? YES : [stored boolValue];
}

@end
