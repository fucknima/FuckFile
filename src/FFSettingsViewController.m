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

@interface FFSettingsViewController ()
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic) BOOL gridMode;
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
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.showHiddenFiles = [defaults boolForKey:kFFSettingsShowHiddenFiles];
    self.gridMode = [defaults boolForKey:kFFSettingsGridMode];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 3; // 显示隐藏文件 / 列表与网格 / 关于
        case 1: return 2; // 文件查看：支持的查看器 / 文件关联
        case 2: return 3; // 运行日志 / 清理缓存 / 重新扫描
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"显示";
        case 1: return @"文件查看";
        case 2: return @"高级 / 调试";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Cell"];

    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSString *title = nil;
    NSString *subtitle = nil;
    NSString *symbol = nil;
    UISwitch *toggle = nil;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            title = @"显示隐藏文件";
            subtitle = @"显示以 . 开头的文件与文件夹";
            symbol = @"eye";
            toggle = [UISwitch new];
            toggle.on = self.showHiddenFiles;
            [toggle addTarget:self action:@selector(hiddenFilesChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            title = @"网格视图";
            subtitle = @"在文件浏览器中使用网格布局";
            symbol = @"square.grid.2x2";
            toggle = [UISwitch new];
            toggle.on = self.gridMode;
            [toggle addTarget:self action:@selector(gridModeChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            title = @"关于";
            subtitle = [NSString stringWithFormat:@"FuckFile %@（构建 %@）· iOS %@",
                NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                UIDevice.currentDevice.systemVersion];
            symbol = @"info.circle";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            title = @"支持的文件查看器";
            subtitle = @"图片、文本、plist、SQLite、Hex、Web 等";
            symbol = @"rectangle.stack";
        } else {
            title = @"文件关联";
            subtitle = @"扩展名 → 查看器映射，修改后立即生效";
            symbol = @"arrow.triangle.branch";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        if (indexPath.row == 0) {
            title = @"运行日志";
            subtitle = @"查看、分享、导出诊断信息";
            symbol = @"doc.text";
        } else if (indexPath.row == 1) {
            title = @"清理缓存";
            subtitle = @"删除缩略图缓存";
            symbol = @"trash";
        } else {
            title = @"重新扫描";
            subtitle = @"重新扫描 App 数据";
            symbol = @"arrow.clockwise";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = title;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.secondaryText = subtitle;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.secondaryTextProperties.numberOfLines = 2;
    config.image = [UIImage systemImageNamed:symbol];
    config.imageProperties.tintColor = UIColor.systemBlueColor;
    config.imageProperties.maximumSize = CGSizeMake(26, 26);
    cell.contentConfiguration = config;
    if (toggle) cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 2) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"关于"
                message:@"FuckFile — iOS 容器文件管理器\n基于 MobileHouseArrest 身份访问技术"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        return;
    }
    if (indexPath.section == 1) {
        UIViewController *page = indexPath.row == 0 ?
            (UIViewController *)[FFSupportedViewersViewController new] :
            (UIViewController *)[FFFileAssociationsViewController new];
        [self.navigationController pushViewController:page animated:YES];
        return;
    }
    switch (indexPath.row) {
        case 0: {
            FFLogViewController *log = [FFLogViewController new];
            [self.navigationController pushViewController:log animated:YES];
            break;
        }
        case 1: {
            unsigned long long size = [[FFThumbnailService sharedService] diskCacheSize];
            [[FFThumbnailService sharedService] clearCaches];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"缓存已清理"
                message:[NSString stringWithFormat:@"释放约 %@。",
                    [NSByteCountFormatter stringFromByteCount:(long long)size
                        countStyle:NSByteCountFormatterCountStyleFile]]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            break;
        }
        case 2: {
            [[MCMManager sharedManager] rescanWithCompletion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成"
                    message:@"App 数据已重新扫描。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }];
            break;
        }
    }
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

- (void)gridModeChanged:(UISwitch *)toggle
{
    self.gridMode = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.gridMode
                                          forKey:kFFSettingsGridMode];
    // 已打开的浏览器页面即时切换网格/列表。
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
