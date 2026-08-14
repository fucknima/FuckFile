#import "FFSearchViewController.h"
#import "FFSearchService.h"
#import "FFBrowserViewController.h"
#import "FFLogger.h"
#import "MCMManager.h"
#import "FFAppNames.h"

@interface FFSearchViewController () <UISearchBarDelegate>
@property(nonatomic, strong) UISearchBar *searchBar;
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

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    self.searchBar.placeholder = @"搜索文件名（Device Storage 全局）";
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.tableView.tableHeaderView = self.searchBar;

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
    [self.searchBar becomeFirstResponder];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
        selector:@selector(beginSearch:) object:searchText];
    if (searchText.length == 0) {
        [[FFSearchService sharedService] cancel];
        self.searching = NO;
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
        config.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    FFFoundItem *item = self.results[indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = FFAppDisplayName(item.name);
    config.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    config.secondaryText = item.path;
    config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:10
        weight:UIFontWeightRegular];
    config.secondaryTextProperties.numberOfLines = 2;
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
        self.searchBar.text = query;
        [[FFSearchService sharedService] addHistory:query];
        self.history = [[FFSearchService sharedService] history];
        [self beginSearch:query];
        return;
    }
    FFFoundItem *item = self.results[indexPath.row];
    // 文件直接打开预览，文件夹进入目录；不存在则提示。
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
