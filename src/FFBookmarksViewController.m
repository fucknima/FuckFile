#import "FFBookmarksViewController.h"
#import "FFBookmarksService.h"
#import "FFBrowserViewController.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFFileMetadataService.h"

@interface FFBookmarksViewController ()
@property(nonatomic) FFBookmarksMode mode;
@property(nonatomic, strong) NSArray<FFBookmark *> *items;
@end

@implementation FFBookmarksViewController

- (instancetype)initWithMode:(FFBookmarksMode)mode
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _mode = mode;
        self.title = mode == FFBookmarksModeFavorites ? @"收藏" : @"最近访问";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58;
    if (self.mode == FFBookmarksModeRecent)
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:@"清空" style:UIBarButtonItemStylePlain
            target:self action:@selector(clearAll)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadItems];
}

- (void)reloadItems
{
    self.items = self.mode == FFBookmarksModeFavorites
        ? [FFFavoritesService sharedService].bookmarks
        : [FFRecentService sharedService].entries;
    [self updateEmptyState];
    [self.tableView reloadData];
}

- (void)updateEmptyState
{
    if (self.items.count > 0) {
        self.tableView.backgroundView = nil;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        return;
    }
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0,
        self.view.bounds.size.width - 80, 120)];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.textColor = UIColor.secondaryLabelColor;
    label.text = self.mode == FFBookmarksModeFavorites
        ? @"还没有收藏\n长按文件或文件夹即可收藏"
        : @"还没有最近访问记录";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.adjustsFontForContentSizeCategory = YES;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        self.view.bounds.size.width, self.view.bounds.size.height)];
    label.center = container.center;
    [container addSubview:label];
    self.tableView.backgroundView = container;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
}

- (void)clearAll
{
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"清空最近记录"
        message:@"将删除全部最近访问记录。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [FFRecentService.sharedService clear];
            [weakSelf reloadItems];
        }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];

    FFBookmark *bookmark = self.items[indexPath.row];
    BOOL gated = FFPathRequiresSystemAccess(bookmark.path) && !FFSystemAccessManager.sharedManager.ready;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = bookmark.name.length ? bookmark.name : bookmark.path.lastPathComponent;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryText = gated
        ? @"需要高级系统访问"
        : FFAbbreviatedDisplayPath(bookmark.path);
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryTextProperties.numberOfLines = 1;
    config.secondaryTextProperties.color = gated ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    config.image = [UIImage systemImageNamed:gated ? @"lock" : (bookmark.isDirectory ? @"folder" : @"doc")];
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFBookmark *bookmark = self.items[indexPath.row];
    if (FFPathRequiresSystemAccess(bookmark.path) && !FFSystemAccessManager.sharedManager.ready) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要高级系统访问"
            message:@"该收藏或最近记录位于 App Data。请先在设置中启用并成功加载高级系统访问。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:FFStorageRootPath()];
    browser.title = bookmark.name;
    [browser openItemAtPath:bookmark.path title:bookmark.name
        navigationController:self.navigationController completion:^(BOOL available) {
        if (!available) [weakSelf presentUnavailable:bookmark];
    }];
}

- (void)presentUnavailable:(FFBookmark *)bookmark
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件不可用"
        message:[NSString stringWithFormat:@"“%@” 已不存在。", bookmark.name]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"移除记录" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            if (weakSelf.mode == FFBookmarksModeFavorites)
                [FFFavoritesService.sharedService removePath:bookmark.path];
            else
                [FFRecentService.sharedService removePath:bookmark.path];
            [weakSelf reloadItems];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    FFBookmark *bookmark = self.items[indexPath.row];
    if (self.mode == FFBookmarksModeFavorites)
        [FFFavoritesService.sharedService removePath:bookmark.path];
    else
        [FFRecentService.sharedService removePath:bookmark.path];
    [self reloadItems];
}

@end
