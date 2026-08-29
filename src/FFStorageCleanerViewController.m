#import "FFStorageCleanerViewController.h"
#import "FFStorageCleaner.h"

@interface FFStorageCleanerViewController ()
@property(nonatomic, strong) FFStorageCleanupSnapshot *snapshot;
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedIdentifiers;
@property(nonatomic, strong) UIBarButtonItem *cleanButton;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, weak) UIButton *selectAllButton;
@property(nonatomic) BOOL scanning;
@property(nonatomic) BOOL cleaning;
@property(nonatomic) BOOL didApplyInitialSelection;
@end

@implementation FFStorageCleanerViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"存储清理";
        self.hidesBottomBarWhenPushed = YES;
        _selectedIdentifiers = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 62;

    self.cleanButton = [[UIBarButtonItem alloc] initWithTitle:@"清理"
        style:UIBarButtonItemStyleDone target:self action:@selector(cleanTapped)];
    self.navigationItem.rightBarButtonItem = self.cleanButton;

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(refreshTriggered:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 58)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.tableView.tableHeaderView = self.statusLabel;

    [self scanNow];
}

#pragma mark - Scan

- (void)refreshTriggered:(__unused UIRefreshControl *)sender
{
    [self scanNow];
}

- (void)scanNow
{
    if (self.scanning || self.cleaning) {
        [self.refreshControl endRefreshing];
        return;
    }
    self.scanning = YES;
    self.cleanButton.enabled = NO;
    [self updateSelectAllButton];
    self.statusLabel.text = @"正在扫描可安全清理的项目…";

    __weak typeof(self) weakSelf = self;
    [FFStorageCleaner.sharedCleaner scanWithProgress:^(NSUInteger completed, NSUInteger total, NSString *appName) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.scanning) return;
        if (total > 0) {
            self.statusLabel.text = [NSString stringWithFormat:@"正在扫描 App 缓存 %lu/%lu\n%@",
                (unsigned long)completed, (unsigned long)total, appName ?: @""];
        }
    } completion:^(FFStorageCleanupSnapshot *snapshot) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.scanning = NO;
        self.snapshot = snapshot;
        [self.refreshControl endRefreshing];
        [self applySelectionForSnapshot:snapshot];
        [self updateSummary];
        [self.tableView reloadData];
        [self updateSelectAllButton];
    }];
}

- (void)applySelectionForSnapshot:(FFStorageCleanupSnapshot *)snapshot
{
    NSMutableSet<NSString *> *valid = [NSMutableSet set];
    for (FFStorageCleanupItem *item in snapshot.items) [valid addObject:item.identifier];
    [self.selectedIdentifiers intersectSet:valid];

    if (!self.didApplyInitialSelection) {
        for (FFStorageCleanupItem *item in snapshot.items) {
            if (item.isRecommended) [self.selectedIdentifiers addObject:item.identifier];
        }
        self.didApplyInitialSelection = YES;
    }
}

- (unsigned long long)selectedBytes
{
    unsigned long long total = 0;
    for (FFStorageCleanupItem *item in self.snapshot.items ?: @[]) {
        if ([self.selectedIdentifiers containsObject:item.identifier]) total += item.bytes;
    }
    return total;
}

- (NSArray<FFStorageCleanupItem *> *)selectedItems
{
    NSMutableArray *items = [NSMutableArray array];
    for (FFStorageCleanupItem *item in self.snapshot.items ?: @[]) {
        if ([self.selectedIdentifiers containsObject:item.identifier]) [items addObject:item];
    }
    return items;
}

- (void)updateSummary
{
    unsigned long long bytes = [self selectedBytes];
    NSString *selected = [NSByteCountFormatter stringFromByteCount:(long long)bytes
        countStyle:NSByteCountFormatterCountStyleFile];
    self.cleanButton.title = bytes > 0 ? [NSString stringWithFormat:@"清理 %@", selected] : @"清理";
    self.cleanButton.enabled = !self.scanning && !self.cleaning && self.selectedIdentifiers.count > 0;

    unsigned long long all = self.snapshot.totalBytes;
    NSString *allText = [NSByteCountFormatter stringFromByteCount:(long long)all
        countStyle:NSByteCountFormatterCountStyleFile];
    self.statusLabel.text = [NSString stringWithFormat:@"发现约 %@ 可清理\n%@",
        allText, self.snapshot.appDataStatusText ?: @""];
    [self updateSelectAllButton];
}

#pragma mark - Sections

- (NSArray<FFStorageCleanupItem *> *)localItems
{
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(FFStorageCleanupItem *item,
        __unused NSDictionary *bindings) {
        return item.kind != FFStorageCleanupItemKindAppData;
    }];
    return [self.snapshot.items filteredArrayUsingPredicate:predicate] ?: @[];
}

- (NSArray<FFStorageCleanupItem *> *)appItems
{
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(FFStorageCleanupItem *item,
        __unused NSDictionary *bindings) {
        return item.kind == FFStorageCleanupItemKindAppData;
    }];
    return [self.snapshot.items filteredArrayUsingPredicate:predicate] ?: @[];
}

- (BOOL)allAppItemsSelected
{
    NSArray<FFStorageCleanupItem *> *items = [self appItems];
    if (!items.count) return NO;
    for (FFStorageCleanupItem *item in items) {
        if (![self.selectedIdentifiers containsObject:item.identifier]) return NO;
    }
    return YES;
}

- (void)updateSelectAllButton
{
    UIButton *button = self.selectAllButton;
    if (!button) return;
    NSArray<FFStorageCleanupItem *> *items = [self appItems];
    BOOL enabled = items.count > 0 && !self.scanning && !self.cleaning;
    button.enabled = enabled;
    [button setTitle:[self allAppItemsSelected] ? @"取消全选" : @"全选" forState:UIControlStateNormal];
}

- (void)selectAllAppsTapped
{
    if (self.scanning || self.cleaning) return;
    NSArray<FFStorageCleanupItem *> *items = [self appItems];
    if (!items.count) return;

    BOOL clear = [self allAppItemsSelected];
    for (FFStorageCleanupItem *item in items) {
        if (clear) [self.selectedIdentifiers removeObject:item.identifier];
        else [self.selectedIdentifiers addObject:item.identifier];
    }
    [self updateSummary];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
        withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 2; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSArray *items = section == 0 ? [self localItems] : [self appItems];
    return MAX((NSInteger)items.count, 1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"FuckFile" : nil;
}

- (UIView *)tableView:(__unused UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != 1) return nil;

    UIView *container = [UIView new];
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"App 数据（手动选择）";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    label.textColor = UIColor.secondaryLabelColor;
    label.adjustsFontForContentSizeCategory = YES;
    [container addSubview:label];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [button addTarget:self action:@selector(selectAllAppsTapped) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:button];
    self.selectAllButton = button;

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:3],
        [button.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:12],
    ]];
    [self updateSelectAllButton];
    return container;
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return section == 1 ? 42.0 : UITableViewAutomaticDimension;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0)
        return @"默认只选择 FuckFile 自己的可重建缓存，以及明确失效的分享残留。";
    return @"第三方 App 仅清空 Library/Caches 和 tmp 的内容，不删除目录本身；不会触碰 Documents、Preferences、Application Support，也不会扫描 com.apple.* 系统 App。建议清理前关闭对应 App。";
}

- (FFStorageCleanupItem *)itemAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<FFStorageCleanupItem *> *items = indexPath.section == 0 ? [self localItems] : [self appItems];
    if ((NSUInteger)indexPath.row >= items.count) return nil;
    return items[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CleanerCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
        reuseIdentifier:@"CleanerCell"];

    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = nil;
    cell.imageView.tintColor = UIColor.systemBlueColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;

    FFStorageCleanupItem *item = [self itemAtIndexPath:indexPath];
    if (!item) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.enabled = NO;
        cell.detailTextLabel.enabled = NO;
        if (indexPath.section == 0) {
            cell.textLabel.text = self.scanning ? @"正在扫描…" : @"没有 FuckFile 垃圾";
            cell.detailTextLabel.text = @"当前没有符合安全规则的本地清理项";
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle"];
        } else if (!self.snapshot.appDataAvailable) {
            cell.textLabel.text = @"App 缓存暂不可扫描";
            cell.detailTextLabel.text = self.snapshot.appDataStatusText ?: @"高级系统访问未就绪";
            cell.imageView.image = [UIImage systemImageNamed:@"lock"];
        } else {
            cell.textLabel.text = @"没有发现第三方 App 缓存";
            cell.detailTextLabel.text = @"下拉可重新扫描";
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle"];
        }
        return cell;
    }

    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)item.bytes
        countStyle:NSByteCountFormatterCountStyleFile];
    cell.textLabel.text = item.title;
    if (item.kind == FFStorageCleanupItemKindAppData) {
        NSString *cache = [NSByteCountFormatter stringFromByteCount:(long long)item.cacheBytes
            countStyle:NSByteCountFormatterCountStyleFile];
        NSString *tmp = [NSByteCountFormatter stringFromByteCount:(long long)item.temporaryBytes
            countStyle:NSByteCountFormatterCountStyleFile];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 缓存 %@ · 临时 %@",
            item.subtitle, cache, tmp];
        cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2.fill"];
        cell.imageView.tintColor = UIColor.systemIndigoColor;
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
            size, item.subtitle ?: @""];
        if (item.kind == FFStorageCleanupItemKindThumbnailCache) {
            cell.imageView.image = [UIImage systemImageNamed:@"photo.stack"];
            cell.imageView.tintColor = UIColor.systemOrangeColor;
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
            cell.imageView.tintColor = UIColor.systemTealColor;
        }
    }
    cell.accessoryType = [self.selectedIdentifiers containsObject:item.identifier]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.scanning || self.cleaning) return;
    FFStorageCleanupItem *item = [self itemAtIndexPath:indexPath];
    if (!item) return;
    if ([self.selectedIdentifiers containsObject:item.identifier])
        [self.selectedIdentifiers removeObject:item.identifier];
    else
        [self.selectedIdentifiers addObject:item.identifier];
    [self updateSummary];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Cleanup

- (void)cleanTapped
{
    if (self.scanning || self.cleaning) return;
    NSArray<FFStorageCleanupItem *> *items = [self selectedItems];
    if (!items.count) return;

    BOOL includesAppData = NO;
    for (FFStorageCleanupItem *item in items) {
        if (item.kind == FFStorageCleanupItemKindAppData) { includesAppData = YES; break; }
    }
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)[self selectedBytes]
        countStyle:NSByteCountFormatterCountStyleFile];
    NSString *message = includesAppData
        ? [NSString stringWithFormat:@"将清理约 %@。第三方 App 只处理 Library/Caches 和 tmp；建议先关闭所选 App。清理后缓存可能会重新生成。", size]
        : [NSString stringWithFormat:@"将清理约 %@ 的 FuckFile 可重建数据。", size];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认清理？"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf beginCleanup:items]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginCleanup:(NSArray<FFStorageCleanupItem *> *)items
{
    if (self.cleaning || !items.count) return;
    self.cleaning = YES;
    self.cleanButton.enabled = NO;
    self.refreshControl.enabled = NO;
    [self updateSelectAllButton];
    self.statusLabel.text = @"正在清理…";

    __weak typeof(self) weakSelf = self;
    [FFStorageCleaner.sharedCleaner cleanItems:items progress:^(NSUInteger completed, NSUInteger total, NSString *title) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.statusLabel.text = [NSString stringWithFormat:@"正在清理 %lu/%lu\n%@",
            (unsigned long)completed, (unsigned long)total, title ?: @""];
    } completion:^(FFStorageCleanupResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.cleaning = NO;
        self.refreshControl.enabled = YES;
        [self.selectedIdentifiers removeAllObjects];
        self.didApplyInitialSelection = YES;

        NSString *freed = [NSByteCountFormatter stringFromByteCount:(long long)result.freedBytes
            countStyle:NSByteCountFormatterCountStyleFile];
        NSString *message = result.errors.count
            ? [NSString stringWithFormat:@"实际释放约 %@。%lu 个项目出现部分失败；未通过安全校验的路径均已跳过。",
                freed, (unsigned long)result.failedItemCount]
            : [NSString stringWithFormat:@"实际释放约 %@。", freed];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"清理完成"
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
        [self scanNow];
    }];
}

@end
