#import "FFBookmarksViewController.h"
#import "FFBookmarksService.h"
#import "FFBrowserViewController.h"
#import "MCMManager.h"
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

// 空状态：收藏为空与最近为空分别给明确的引导文案。
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
    label.textColor = [UIColor secondaryLabelColor];
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

// 「清空最近记录」必须有确认：清理的是用户历史，不是可恢复的临时状态。
- (void)clearAll
{
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"清空最近记录"
        message:@"将删除全部最近访问记录。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"清空"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [[FFRecentService sharedService] clear];
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
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    }
    FFBookmark *bookmark = self.items[indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = bookmark.name.length ? bookmark.name : bookmark.path.lastPathComponent;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    // 缩略显示，完整路径在文件信息/复制路径。
    config.secondaryText = FFAbbreviatedDisplayPath(bookmark.path);
    config.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryTextProperties.numberOfLines = 1;
    config.image = [UIImage systemImageNamed:bookmark.isDirectory ? @"folder" : @"doc"];
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFBookmark *bookmark = self.items[indexPath.row];
    __weak typeof(self) weakSelf = self;
    // openItemAtPath 内部处理：目录 push 浏览器，文件打开预览。
    // 用书签页自身作为调用者（其 navigationController 负责 push）。
    FFBrowserViewController *browser = [[FFBrowserViewController alloc]
        initWithPath:MCMVirtualRoot()];
    browser.title = bookmark.name;
    [browser openItemAtPath:bookmark.path title:bookmark.name
        navigationController:self.navigationController completion:^(BOOL available) {
        if (!available) {
            [weakSelf presentUnavailable:bookmark];
        }
        // 文件/目录打开后停留在内容页，不再自动弹回列表。
    }];
}

// 目标已不存在：提示并提供移除记录。
- (void)presentUnavailable:(FFBookmark *)bookmark
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件不可用"
        message:[NSString stringWithFormat:@"“%@” 已不存在。", bookmark.name]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"移除记录" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            if (weakSelf.mode == FFBookmarksModeFavorites)
                [[FFFavoritesService sharedService] removePath:bookmark.path];
            else
                [[FFRecentService sharedService] removePath:bookmark.path];
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
        [[FFFavoritesService sharedService] removePath:bookmark.path];
    else
        [[FFRecentService sharedService] removePath:bookmark.path];
    [self reloadItems];
}

@end
