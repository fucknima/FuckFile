#import "FFBookmarksViewController.h"
#import "FFBookmarksService.h"
#import "FFBrowserViewController.h"

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
    [self.tableView reloadData];
}

- (void)clearAll
{
    [[FFRecentService sharedService] clear];
    [self reloadItems];
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
    config.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    config.secondaryText = bookmark.path;
    config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:10
        weight:UIFontWeightRegular];
    config.secondaryTextProperties.numberOfLines = 2;
    config.image = [UIImage systemImageNamed:bookmark.isDirectory ? @"folder" : @"doc"];
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFBookmark *bookmark = self.items[indexPath.row];
    NSString *path = bookmark.isDirectory
        ? bookmark.path : bookmark.path.stringByDeletingLastPathComponent;
    FFBrowserViewController *browser =
        [[FFBrowserViewController alloc] initWithPath:path];
    browser.title = path.lastPathComponent;
    [self.navigationController pushViewController:browser animated:YES];
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
