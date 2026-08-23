#import "FFSearchViewController.h"
#import "FFSearchService.h"
#import "FFBrowserViewController.h"
#import "FFLogger.h"
#import "MCMManager.h"
#import "FFAppNames.h"
#import "FFPathDisplay.h"
#import "FFTypography.h"

@interface FFSearchViewController () <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSArray<NSString *> *history;
@property(nonatomic, strong) UIView *searchBackdrop;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) NSMutableArray<FFFoundItem *> *results;
@property(nonatomic) BOOL searching;
@property(nonatomic) BOOL finished;
@end

@implementation FFSearchViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.title = @"搜索";
        self.navigationItem.largeTitleDisplayMode =
            UINavigationItemLargeTitleDisplayModeNever;
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

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"全局搜索 App 数据";
    self.searchController.searchBar.delegate = self;
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.results = [NSMutableArray array];
    self.history = [[FFSearchService sharedService] history];

    self.searchBackdrop = [[UIView alloc] init];
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.spinner, self.statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.searchBackdrop addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.searchBackdrop.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.searchBackdrop.topAnchor constant:60],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"清空历史" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearHistoryTapped)];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // 历史为空时直接聚焦搜索框；有结果时保持现状。
    if (self.history.count == 0 && self.results.count == 0)
        [self.searchController.searchBar becomeFirstResponder];
}

#pragma mark - Search inputs

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self searchTextChanged:searchController.searchBar.text];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self searchTextChanged:searchText];
}

- (void)searchTextChanged:(NSString *)searchText
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(beginSearch:) object:searchText];
    if (searchText.length == 0) {
        [[FFSearchService sharedService] cancel];
        self.searching = NO;
        self.finished = NO;
        [self.results removeAllObjects];
        [self updateSearchBackground];
        [self.tableView reloadData];
        return;
    }
    [self performSelector:@selector(beginSearch:) withObject:searchText
               afterDelay:0.3];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(beginSearch:) object:searchBar.text];
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length) {
        [[FFSearchService sharedService] addHistory:query];
        self.history = [[FFSearchService sharedService] history];
    }
    [self beginSearch:searchBar.text];
}

- (void)updateSearchBackground
{
    if (self.searching) {
        [self.spinner startAnimating];
        self.statusLabel.text = [NSString stringWithFormat:
            @"搜索中… 已找到 %lu 个结果", (unsigned long)self.results.count];
        self.tableView.backgroundView = self.searchBackdrop;
    } else {
        [self.spinner stopAnimating];
        self.tableView.backgroundView = nil;
    }
}

- (void)beginSearch:(NSString *)query
{
    [[FFSearchService sharedService] cancel];
    query = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) return;
    self.searching = YES;
    self.finished = NO;
    [self.results removeAllObjects];
    [self updateSearchBackground];
    [self.tableView reloadData];
    FFLogTag(@"Search", @"begin query=%@ root=%@", query, MCMVirtualRoot());

    __weak typeof(self) weakSelf = self;
    NSString *searchRoot = [MCMVirtualRoot() stringByAppendingPathComponent:@"AppData"];
    [[FFSearchService sharedService] startSearch:query
        underRoot:searchRoot
        batch:^(NSArray<FFFoundItem *> *batch) {
            [weakSelf.results addObjectsFromArray:batch];
            [weakSelf updateSearchBackground];
            [weakSelf.tableView reloadData];
        }
        completion:^(BOOL finished) {
            weakSelf.searching = NO;
            weakSelf.finished = finished;
            [weakSelf updateSearchBackground];
            [weakSelf.tableView reloadData];
            FFLogTag(@"Search", @"done query=%@ finished=%d results=%lu",
                     query, finished, (unsigned long)weakSelf.results.count);
        }];
}

- (void)clearHistoryTapped
{
    [[FFSearchService sharedService] clearHistory];
    self.history = @[];
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.searching || self.results.count > 0 || self.finished)
        return (NSInteger)self.results.count;
    return (NSInteger)self.history.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL showingHistory = !self.searching && self.results.count == 0;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    }
    if (showingHistory) {
        NSString *query = self.history[indexPath.row];
        UIListContentConfiguration *config = [cell defaultContentConfiguration];
        config.text = query;
        config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        config.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    FFFoundItem *item = self.results[indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = FFAppDisplayName(item.name);
    config.textProperties.font = FFPreferredFont(UIFontTextStyleBody, UIFontWeightMedium);
    config.textProperties.numberOfLines = 2;
    // 列表只显示语义化短路径；完整真实路径只在「文件信息/复制路径」出现。
    config.secondaryText = FFDisplayPathForPath(item.path);
    config.secondaryTextProperties.font = FFPreferredFont(UIFontTextStyleSubheadline, UIFontWeightRegular);
    config.secondaryTextProperties.numberOfLines = 1;
    config.image = [UIImage systemImageNamed:item.isDirectory ? @"folder" : @"doc"];
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BOOL showingHistory = !self.searching && self.results.count == 0;
    if (showingHistory) {
        NSString *query = self.history[indexPath.row];
        self.searchController.searchBar.text = query;
        [[FFSearchService sharedService] addHistory:query];
        self.history = [[FFSearchService sharedService] history];
        [self beginSearch:query];
        return;
    }
    FFFoundItem *item = self.results[indexPath.row];
    // 点击结果弹操作单：打开 / 跳转所在目录 / 取消。
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.name
        message:FFDisplayPathForPath(item.path) preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [weakSelf openFoundItem:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"跳转所在目录"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *parent = item.path.stringByDeletingLastPathComponent;
        FFBrowserViewController *browser =
            [[FFBrowserViewController alloc] initWithPath:parent];
        [weakSelf.navigationController pushViewController:browser animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openFoundItem:(FFFoundItem *)item
{
    // 文件打开预览，文件夹进入目录；不存在则提示。
    FFBrowserViewController *browser = [[FFBrowserViewController alloc]
        initWithPath:MCMVirtualRoot()];
    browser.title = item.name;
    __weak typeof(self) weakSelf = self;
    [browser openItemAtPath:item.path title:item.name
        navigationController:self.navigationController completion:^(BOOL available) {
        if (!available) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件不可用"
                message:@"该文件已不存在。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        }
    }];
}

@end
