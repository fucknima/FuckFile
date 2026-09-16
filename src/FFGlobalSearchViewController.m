#import "FFGlobalSearchViewController.h"

#import "FFBrowserViewController.h"
#import "FFFileIconProvider.h"
#import "FFLogger.h"
#import "FFPreviewRouter.h"
#import "FFSearchService.h"
#import "FFStorageEnvironment.h"

static NSString *const kFFGlobalSearchHistoryKey = @"FFGlobalSearchHistory";
static const NSUInteger kFFGlobalSearchHistoryLimit = 20;
static const NSTimeInterval kFFGlobalSearchDebounce = 0.3;

@interface FFGlobalSearchViewController () <UISearchBarDelegate, UITableViewDataSource,
                                            UITableViewDelegate>
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UILabel *placeholderLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) FFSearchService *searchService;
@property(nonatomic, strong) NSMutableArray<FFFoundItem *> *results;
@property(nonatomic, strong) NSMutableArray<NSString *> *history;
@property(nonatomic) BOOL searching;
@property(nonatomic) NSUInteger searchGeneration;
@property(nonatomic, copy) NSString *statusMessage;
@end

@implementation FFGlobalSearchViewController

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"搜索";
        _results = [NSMutableArray array];
        _history = [NSMutableArray array];
        _searchService = [FFSearchService new];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self loadHistory];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索全部文件";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 60;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    self.placeholderLabel = [UILabel new];
    self.placeholderLabel.textColor = UIColor.secondaryLabelColor;
    self.placeholderLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.placeholderLabel.textAlignment = NSTextAlignmentCenter;
    self.placeholderLabel.numberOfLines = 0;
    self.placeholderLabel.frame = CGRectMake(0, 0, 10, 10);
    self.tableView.backgroundView = self.placeholderLabel;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self updatePlaceholder];
    [self updateHistoryButton];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.searchBar becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.searchService cancel];
}

- (void)dealloc
{
    [_searchService cancel];
}

#pragma mark - History

- (void)loadHistory
{
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:kFFGlobalSearchHistoryKey];
    [self.history removeAllObjects];
    if ([stored isKindOfClass:NSArray.class])
        for (id value in stored)
            if ([value isKindOfClass:NSString.class] && [value length]) [self.history addObject:value];
}

- (void)saveHistoryQuery:(NSString *)query
{
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    for (NSString *existing in [self.history copy])
        if ([existing caseInsensitiveCompare:trimmed] == NSOrderedSame)
            [self.history removeObject:existing];
    [self.history insertObject:trimmed atIndex:0];
    while (self.history.count > kFFGlobalSearchHistoryLimit)
        [self.history removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:self.history forKey:kFFGlobalSearchHistoryKey];
}

- (void)clearHistory
{
    [self.history removeAllObjects];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFFGlobalSearchHistoryKey];
    [self.tableView reloadData];
    [self updatePlaceholder];
    [self updateHistoryButton];
}

- (void)updateHistoryButton
{
    BOOL showsHistory = self.searchBar.text.length == 0 && self.history.count > 0;
    self.navigationItem.leftBarButtonItem = showsHistory
        ? [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
            target:self action:@selector(clearHistoryTapped)]
        : nil;
}

- (void)clearHistoryTapped
{
    if (self.history.count == 0) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空搜索历史"
        message:@"将删除全部本地搜索记录。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf clearHistory]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self updateHistoryButton];
    self.searchGeneration += 1;
    NSUInteger generation = self.searchGeneration;
    NSString *query = [searchText stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self.searchService cancel];
    [self.results removeAllObjects];
    self.statusMessage = nil;

    if (!query.length) {
        self.searching = NO;
        [self.spinner stopAnimating];
        [self.tableView reloadData];
        [self updatePlaceholder];
        return;
    }

    self.searching = YES;
    [self.spinner startAnimating];
    [self.tableView reloadData];
    [self updatePlaceholder];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(kFFGlobalSearchDebounce * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.searchGeneration) return;
        [strongSelf runSearch:query generation:generation];
    });
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length) [self saveHistoryQuery:query];
    [searchBar resignFirstResponder];
    [self updateHistoryButton];
}

- (void)runSearch:(NSString *)query generation:(NSUInteger)generation
{
    NSString *root = FFStorageRootPath();
    __weak typeof(self) weakSelf = self;
    [self.searchService startSearch:query underRoot:root
        batch:^(NSArray<FFFoundItem *> *batch) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.searchGeneration) return;
            [strongSelf.results addObjectsFromArray:batch];
            [strongSelf.tableView reloadData];
            [strongSelf updatePlaceholder];
        }
        completion:^(BOOL finished) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.searchGeneration) return;
            strongSelf.searching = NO;
            strongSelf.statusMessage = strongSelf.searchService.statusMessage;
            [strongSelf.spinner stopAnimating];
            [strongSelf.tableView reloadData];
            [strongSelf updatePlaceholder];
            FFLogTag(@"Search", @"global search query=%@ results=%lu finished=%d partial=%@",
                query, (unsigned long)strongSelf.results.count, finished,
                strongSelf.statusMessage ?: @"-");
        }];
}

- (void)updatePlaceholder
{
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) {
        self.placeholderLabel.text = self.history.count
            ? @"输入关键词，或点按下方历史记录" : @"输入关键词搜索全部文件";
    } else if (self.searching) {
        self.placeholderLabel.text = @"正在搜索…";
    } else if (self.results.count == 0) {
        self.placeholderLabel.text = [NSString stringWithFormat:
            @"没有找到“%@”，试试缩短关键词", query];
    } else {
        self.placeholderLabel.text = nil;
    }
    self.tableView.backgroundView = self.placeholderLabel.text.length
        ? self.placeholderLabel : nil;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView
{
    return self.results.count ? 1 : (self.history.count ? 1 : 0);
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)section;
    return self.results.count ? self.results.count : self.history.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)section;
    if (self.results.count) return nil;
    return self.history.count ? @"最近搜索" : nil;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)section;
    if (!self.results.count) return nil;
    NSMutableString *footer = [NSMutableString stringWithFormat:@"%lu 个结果",
        (unsigned long)self.results.count];
    if (self.searching) [footer appendString:@" · 搜索中…"];
    if (self.statusMessage.length) [footer appendFormat:@" · %@", self.statusMessage];
    return footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.results.count) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HistoryCell"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"HistoryCell"];
        cell.textLabel.text = self.history[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
        cell.imageView.tintColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ResultCell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"ResultCell"];
    FFFoundItem *item = self.results[indexPath.row];
    FFEntry *entry = [FFEntry new];
    entry.name = item.name;
    entry.displayName = item.displayName.length ? item.displayName : item.name;
    entry.path = item.path;
    entry.isDirectory = item.isDirectory;
    entry.size = item.size;

    cell.textLabel.text = entry.displayName.length ? entry.displayName : entry.name;
    NSString *root = FFStorageRootPath();
    NSString *relative = [item.path hasPrefix:root]
        ? [item.path substringFromIndex:MIN(root.length + 1, item.path.length)] : item.path;
    NSString *parent = relative.stringByDeletingLastPathComponent;
    cell.detailTextLabel.text = parent.length ? parent : @"根目录";
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [FFFileIconProvider iconForEntry:entry];
    cell.accessoryType = item.isDirectory ? UITableViewCellAccessoryDisclosureIndicator
                                          : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.results.count) {
        NSString *query = self.history[indexPath.row];
        self.searchBar.text = query;
        [self searchBar:self.searchBar textDidChange:query];
        [self saveHistoryQuery:query];
        [self updateHistoryButton];
        return;
    }

    FFFoundItem *item = self.results[indexPath.row];
    [self saveHistoryQuery:self.searchBar.text];
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    if (item.isDirectory) {
        FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:item.path];
        browser.title = item.displayName.length ? item.displayName : item.name;
        [nav pushViewController:browser animated:YES];
        return;
    }

    FFEntry *entry = [FFEntry new];
    entry.name = item.name;
    entry.displayName = item.displayName.length ? item.displayName : item.name;
    entry.path = item.path;
    entry.size = item.size;
    if (![FFPreviewRouter previewItem:entry navigationController:nav])
        [FFPreviewRouter toastOnNav:nav message:@"文件已不存在或无法打开"];
}

@end
