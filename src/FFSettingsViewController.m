#import "FFSettingsViewController.h"
#import "FFLogViewController.h"
#import "FFSupportedViewersViewController.h"
#import "FFFileAssociationsViewController.h"
#import "FFWebDAVSettingsViewController.h"
#import "FFWebDAVServer.h"
#import "FFStorageAnalysisViewController.h"
#import "FFLogger.h"

static NSString *const kFFSettingsShowHiddenFiles = @"FFSettingsShowHiddenFiles";
static NSString *const kFFSettingsGridMode = @"FFSettingsGridMode";
static NSString *const kFFSettingsFoldersFirst = @"FFSettingsFoldersFirst";
static NSString *const kFFSettingsShowExtensions = @"FFSettingsShowExtensions";
static NSString *const kFFTrashRetentionDays = @"FFTrashRetentionDays";

// 设置项用显式枚举编址：展开/收起（默认视图、回收站保留期）会动态插入
// 行，索引算术在这里是 bug 温床。iOS 26 的 action sheet 曾出现定位异常，
// 因此选择项改成内联展开而不是弹窗。
typedef NS_ENUM(NSInteger, FFSettingsItem) {
    FFSettingsItemDefaultView = 0,
    FFSettingsItemViewModeList,
    FFSettingsItemViewModeGrid,
    FFSettingsItemShowHidden,
    FFSettingsItemShowExtensions,
    FFSettingsItemFoldersFirst,
    FFSettingsItemViewers,
    FFSettingsItemAssociations,
    FFSettingsItemStorage,
    FFSettingsItemTrashRetention,
    FFSettingsItemTrashRetentionOff,
    FFSettingsItemTrashRetention7,
    FFSettingsItemTrashRetention30,
    FFSettingsItemTrashRetention90,
    FFSettingsItemWebDAV,
    FFSettingsItemLog,
    FFSettingsItemAbout,
};

@interface FFSettingsViewController ()
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic) BOOL gridMode;
@property(nonatomic) BOOL foldersFirst;
@property(nonatomic) BOOL showExtensions;
@property(nonatomic) BOOL viewModeExpanded;
@property(nonatomic) BOOL retentionExpanded;
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

#pragma mark - Item mapping

- (NSArray<NSNumber *> *)itemsForSection:(NSInteger)section
{
    switch (section) {
        case 0: {
            NSMutableArray *items = [NSMutableArray arrayWithObject:@(FFSettingsItemDefaultView)];
            if (self.viewModeExpanded)
                [items addObjectsFromArray:@[@(FFSettingsItemViewModeList),
                                             @(FFSettingsItemViewModeGrid)]];
            [items addObjectsFromArray:@[@(FFSettingsItemShowHidden),
                                         @(FFSettingsItemShowExtensions),
                                         @(FFSettingsItemFoldersFirst)]];
            return items;
        }
        case 1:
            return @[@(FFSettingsItemViewers), @(FFSettingsItemAssociations)];
        case 2: {
            NSMutableArray *items = [NSMutableArray arrayWithObjects:@(FFSettingsItemStorage),
                                     @(FFSettingsItemTrashRetention), nil];
            if (self.retentionExpanded)
                [items addObjectsFromArray:@[@(FFSettingsItemTrashRetentionOff),
                                             @(FFSettingsItemTrashRetention7),
                                             @(FFSettingsItemTrashRetention30),
                                             @(FFSettingsItemTrashRetention90)]];
            [items addObject:@(FFSettingsItemWebDAV)];
            return items;
        }
        case 3: return @[@(FFSettingsItemLog)];
        case 4: return @[@(FFSettingsItemAbout)];
    }
    return @[];
}

- (FFSettingsItem)itemAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<NSNumber *> *items = [self itemsForSection:indexPath.section];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= items.count)
        return FFSettingsItemAbout;
    return (FFSettingsItem)items[(NSUInteger)indexPath.row].integerValue;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 5; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)[self itemsForSection:section].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
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

- (UIColor *)iconTintForItem:(FFSettingsItem)item
{
    switch (item) {
        case FFSettingsItemShowHidden: return UIColor.systemTealColor;
        case FFSettingsItemShowExtensions: return UIColor.systemTealColor;
        case FFSettingsItemViewers: return UIColor.systemBlueColor;
        case FFSettingsItemAssociations: return UIColor.systemIndigoColor;
        case FFSettingsItemStorage: return UIColor.systemTealColor;
        case FFSettingsItemTrashRetention: return UIColor.systemOrangeColor;
        case FFSettingsItemLog: return UIColor.systemBlueColor;
        case FFSettingsItemAbout: return UIColor.systemGrayColor;
        default: return UIColor.systemBlueColor;
    }
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
    cell.imageView.image = nil;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;

    FFSettingsItem item = [self itemAtIndexPath:indexPath];
    cell.imageView.tintColor = [self iconTintForItem:item];

    switch (item) {
        case FFSettingsItemDefaultView:
            cell.textLabel.text = @"默认视图";
            cell.detailTextLabel.text = self.gridMode ? @"网格" : @"列表";
            cell.imageView.image = [UIImage systemImageNamed:self.gridMode ? @"square.grid.2x2" : @"list.bullet"];
            cell.accessoryType = self.viewModeExpanded
                ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FFSettingsItemViewModeList:
            cell.textLabel.text = @"列表";
            cell.imageView.image = [UIImage systemImageNamed:@"list.bullet"];
            cell.accessoryType = self.gridMode ? UITableViewCellAccessoryNone
                                               : UITableViewCellAccessoryCheckmark;
            break;
        case FFSettingsItemViewModeGrid:
            cell.textLabel.text = @"网格";
            cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
            cell.accessoryType = self.gridMode ? UITableViewCellAccessoryCheckmark
                                               : UITableViewCellAccessoryNone;
            break;
        case FFSettingsItemShowHidden: {
            cell.textLabel.text = @"显示隐藏文件";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.showHiddenFiles;
            [toggle addTarget:self action:@selector(hiddenFilesChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.imageView.image = [UIImage systemImageNamed:@"eye"];
            break;
        }
        case FFSettingsItemShowExtensions: {
            cell.textLabel.text = @"显示扩展名";
            cell.detailTextLabel.text = @"关闭后列表隐藏文件的扩展名";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.showExtensions;
            [toggle addTarget:self action:@selector(showExtensionsChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.imageView.image = [UIImage systemImageNamed:@"textformat"];
            break;
        }
        case FFSettingsItemFoldersFirst: {
            cell.textLabel.text = @"文件夹优先";
            cell.detailTextLabel.text = @"排序时目录排在文件前面";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.foldersFirst;
            [toggle addTarget:self action:@selector(foldersFirstChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.imageView.image = [UIImage systemImageNamed:@"folder"];
            break;
        }
        case FFSettingsItemViewers:
            cell.textLabel.text = @"支持的文件查看器";
            cell.detailTextLabel.text = @"图片/文本/PDF/plist/SQLite/Hex/Web 等";
            cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FFSettingsItemAssociations:
            cell.textLabel.text = @"文件关联";
            cell.detailTextLabel.text = @"扩展名 → 查看器映射，立即生效";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.branch"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FFSettingsItemStorage:
            cell.textLabel.text = @"存储空间";
            cell.detailTextLabel.text = @"设备空间 · 分类占用 · 清理缓存";
            cell.imageView.image = [UIImage systemImageNamed:@"internaldrive"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FFSettingsItemTrashRetention:
            cell.textLabel.text = @"回收站自动清理";
            cell.detailTextLabel.text = [self trashRetentionDescription];
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.accessoryType = self.retentionExpanded
                ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FFSettingsItemTrashRetentionOff:
            [self configureRetentionCell:cell days:0 title:@"关闭"];
            break;
        case FFSettingsItemTrashRetention7:
            [self configureRetentionCell:cell days:7 title:@"7 天"];
            break;
        case FFSettingsItemTrashRetention30:
            [self configureRetentionCell:cell days:30 title:@"30 天"];
            break;
        case FFSettingsItemTrashRetention90:
            [self configureRetentionCell:cell days:90 title:@"90 天"];
            break;
        case FFSettingsItemWebDAV: {
            FFWebDAVServer *server = FFWebDAVServer.sharedServer;
            cell.textLabel.text = @"局域网文件共享";
            cell.detailTextLabel.text = server.running && server.addressString.length
                ? server.addressString : @"浏览器 + WebDAV · 仅 Wi‑Fi";
            cell.imageView.image = [UIImage systemImageNamed:@"network"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case FFSettingsItemLog:
            cell.textLabel.text = @"运行日志";
            cell.detailTextLabel.text = @"查看、分享、导出诊断信息";
            cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FFSettingsItemAbout:
            cell.textLabel.text = @"FuckFile";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"版本 %@（构建 %@）· iOS %@",
                NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                UIDevice.currentDevice.systemVersion];
            cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
            break;
    }
    return cell;
}

- (void)configureRetentionCell:(UITableViewCell *)cell days:(NSInteger)days title:(NSString *)title
{
    cell.textLabel.text = title;
    cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
    cell.imageView.tintColor = UIColor.secondaryLabelColor;
    cell.accessoryType = [self trashRetentionDays] == days
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFSettingsItem item = [self itemAtIndexPath:indexPath];
    switch (item) {
        case FFSettingsItemDefaultView: {
            self.viewModeExpanded = !self.viewModeExpanded;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                withRowAnimation:UITableViewRowAnimationAutomatic];
            break;
        }
        case FFSettingsItemViewModeList:
            [self setDefaultGrid:NO];
            break;
        case FFSettingsItemViewModeGrid:
            [self setDefaultGrid:YES];
            break;
        case FFSettingsItemViewers:
            [self.navigationController pushViewController:[FFSupportedViewersViewController new]
                animated:YES];
            break;
        case FFSettingsItemAssociations:
            [self.navigationController pushViewController:[FFFileAssociationsViewController new]
                animated:YES];
            break;
        case FFSettingsItemStorage:
            [self.navigationController pushViewController:[FFStorageAnalysisViewController new]
                animated:YES];
            break;
        case FFSettingsItemTrashRetention:
            self.retentionExpanded = !self.retentionExpanded;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                withRowAnimation:UITableViewRowAnimationAutomatic];
            break;
        case FFSettingsItemTrashRetentionOff:
            [self setTrashRetentionDays:0];
            break;
        case FFSettingsItemTrashRetention7:
            [self setTrashRetentionDays:7];
            break;
        case FFSettingsItemTrashRetention30:
            [self setTrashRetentionDays:30];
            break;
        case FFSettingsItemTrashRetention90:
            [self setTrashRetentionDays:90];
            break;
        case FFSettingsItemWebDAV:
            [self.navigationController pushViewController:[FFWebDAVSettingsViewController new]
                animated:YES];
            break;
        case FFSettingsItemLog:
            [self.navigationController pushViewController:[FFLogViewController new] animated:YES];
            break;
        case FFSettingsItemAbout:
            break;
    }
}

#pragma mark - Default view

- (void)setDefaultGrid:(BOOL)grid
{
    self.gridMode = grid;
    [NSUserDefaults.standardUserDefaults setBool:grid forKey:kFFSettingsGridMode];
    self.viewModeExpanded = NO;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
        withRowAnimation:UITableViewRowAnimationAutomatic];
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

- (void)setTrashRetentionDays:(NSInteger)days
{
    [NSUserDefaults.standardUserDefaults setInteger:days forKey:kFFTrashRetentionDays];
    self.retentionExpanded = NO;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
        withRowAnimation:UITableViewRowAnimationAutomatic];
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
