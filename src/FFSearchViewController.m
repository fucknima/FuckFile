#import "FFSearchViewController.h"
#import "FFSearchService.h"
#import "FFBrowserViewController.h"
#import "FFLogger.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFAppNames.h"
#import "FFFileMetadataService.h"

@interface FFSearchViewController () <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSArray<NSString *> *history;
@property(nonatomic, strong) UIView *searchBackdrop;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) NSMutableArray<FFFoundItem *> *results;
@property(nonatomic) BOOL searching;
@property(nonatomic) BOOL finished;
@property(nonatomic, copy) NSString *lastQuery;
@end

@implementation FFSearchViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) self.title = @"搜索";
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
    self.searchController.searchBar.delegate = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = FFSystemAccessManager.sharedManager.ready
        ? @"搜索本地文件与 App Data" : @"搜索本地文件";
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.results = [NSMutableArray array];
    self.history = [[FFSearchService sharedService] history];

    self.searchBackdrop = [[UIView alloc] initWithFrame:self.tableView.bounds];
    self.searchBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.lineBreakMode = NSLineBreakByWordWrapping;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.spinner, self.statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.searchBackdrop addSubview:stack];

    NSLayoutConstraint *preferredWidth =
        [stack.widthAnchor constraintEqualToAnchor:self.searchBackdrop.widthAnchor constant:-64];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.searchBackdrop.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.searchBackdrop.topAnchor constant:60],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.searchBackdrop.leadingAnchor constant:32],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.searchBackdrop.trailingAnchor constant:-32],
        preferredWidth,
        [stack.widthAnchor constraintLessThanOrEqualToConstant:420],
        [self.statusLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"清空历史" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearHistoryTapped)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.searchController.searchBar.placeholder = FFSystemAccessManager.sharedManager.ready
        ? @"搜索本地文件与 App Data" : @"搜索本地文件";
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.searchController.searchBar becomeFirstResponder];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self searchBarTextChanged:searchController.searchBar.text];
}

- (void)searchBarTextChanged:(NSString *)searchText
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(beginSearch:) object:searchText];
    if (searchText.length == 0) {
        [[FFSearchService sharedService] cancel];
        self.searching = NO;
        self.finished = NO;
        self.lastQuery = nil;
        [self.results removeAllObjects];
        [self updateSearchBackground];
        [self.tableView reloadData];
        return;
    }
    [self performSelector:@selector(beginSearch:) withObject:searchText afterDelay:0.3];
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
    } else if (self.finished && self.lastQuery.length && self.results.count == 0) {
        [self.spinner stopAnimating];
        self.statusLabel.text = [NSString stringWithFormat:
            @"没有找到“%@”\n尝试缩短关键词", self.lastQuery];
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
    self.lastQuery = query;
    [self.results removeAllObjects];
    [self updateSearchBackground];
    [self.tableView reloadData];

    NSString *searchRoot = FFStorageRootPath();
    FFLogTag(@"Search", @"begin query=%@ root=%@ advancedReady=%d",
        query, searchRoot, FFSystemAccessManager.sharedManager.ready);
    __weak typeof(self) weakSelf = self;
    [[FFSearchService sharedService] startSearch:query
        underRoot:searchRoot
        batch:^(NSArray<FFFoundItem *> *batch) {
            typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.results addObjectsFromArray:batch];
            [self updateSearchBackground];
            [self.tableView reloadData];
        }
        completion:^(BOOL finished) {
            typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.searching = NO;
            self.finished = finished;
            [self updateSearchBackground];
            [self.tableView reloadData];
            FFLogTag(@"Search", @"done query=%@ finished=%d results=%lu",
                query, finished, (unsigned long)self.results.count);
        }];
}

- (void)clearHistoryTapped
{
    [[FFSearchService sharedService] clearHistory];
    self.history = @[];
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    if (self.searching || self.results.count > 0 || self.finished)
        return (NSInteger)self.results.count;
    return (NSInteger)self.history.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL showingHistory = !self.searching && self.results.count == 0;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    if (showingHistory) {
        NSString *query = self.history[indexPath.row];
        UIListContentConfiguration *config = [cell defaultContentConfiguration];
        config.text = query;
        config.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    FFFoundItem *item = self.results[indexPath.row];
    NSString *displayName = item.displayName.length ? item.displayName : FFAppDisplayName(item.name);
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = displayName;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryText = FFAbbreviatedDisplayPath(item.path);
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
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
    NSString *displayName = item.displayName.length ? item.displayName : item.name;
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:displayName
        message:FFAbbreviatedDisplayPath(item.path)
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) { [weakSelf openFoundItem:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"跳转所在目录" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
        if (FFPathRequiresSystemAccess(item.path) && !FFSystemAccessManager.sharedManager.ready) {
            [weakSelf presentSystemAccessRequired];
            return;
        }
        NSString *parent = item.path.stringByDeletingLastPathComponent;
        [weakSelf.navigationController pushViewController:
            [[FFBrowserViewController alloc] initWithPath:parent] animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentSystemAccessRequired
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要高级系统访问"
        message:@"该位置属于高级系统访问范围。请先在设置中启用并成功加载高级系统访问。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFoundItem:(FFFoundItem *)item
{
    if (FFPathRequiresSystemAccess(item.path) && !FFSystemAccessManager.sharedManager.ready) {
        [self presentSystemAccessRequired];
        return;
    }
    NSString *displayName = item.displayName.length ? item.displayName : item.name;
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:FFStorageRootPath()];
    browser.title = displayName;
    __weak typeof(self) weakSelf = self;
    [browser openItemAtPath:item.path title:displayName
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
