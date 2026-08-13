#import "FFSettingsViewController.h"
#import "FFLogViewController.h"
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
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.showHiddenFiles = [defaults boolForKey:kFFSettingsShowHiddenFiles];
    self.gridMode = [defaults boolForKey:kFFSettingsGridMode];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 3; // 显示隐藏文件 / 列表与网格 / 关于
        case 1: return 3; // 运行日志 / 清理缓存 / 重新扫描
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"显示";
        case 1: return @"高级 / 调试";
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

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"显示隐藏文件";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.showHiddenFiles;
            [toggle addTarget:self action:@selector(hiddenFilesChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.imageView.image = [UIImage systemImageNamed:@"eye"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"网格视图";
            cell.detailTextLabel.text = @"列表视图（网格即将推出）";
            cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = nil;
        } else {
            cell.textLabel.text = @"关于";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"FuckFile %@（构建 %@）· iOS %@",
                NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                UIDevice.currentDevice.systemVersion];
            cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"运行日志";
            cell.detailTextLabel.text = @"查看、分享、导出诊断信息";
            cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"清理缓存";
            cell.detailTextLabel.text = @"删除缩略图缓存";
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"重新扫描";
            cell.detailTextLabel.text = @"重新扫描 App 数据";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
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
}

- (void)gridModeChanged:(UISwitch *)toggle
{
    self.gridMode = toggle.on;
    [NSUserDefaults.standardUserDefaults setBool:self.gridMode
                                          forKey:kFFSettingsGridMode];
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
