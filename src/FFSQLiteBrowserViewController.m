#import "FFSQLiteBrowserViewController.h"

#import "FFSQLiteService.h"
#import "FFLogger.h"

static const NSUInteger kSQLitePageRows = 200;

#pragma mark - Private: one-shot query result bridge

// UITableView keeps dataSource/delegate weakly, so the query page owns
// this bridge strongly while its results sheet is visible.
@interface FFSQLiteResultBridge : NSObject <UITableViewDataSource>
+ (instancetype)bridgeWithLines:(NSArray<NSString *> *)lines;
@end

@implementation FFSQLiteResultBridge
{
    NSArray<NSString *> *_lines;
}

+ (instancetype)bridgeWithLines:(NSArray<NSString *> *)lines
{
    FFSQLiteResultBridge *bridge = [FFSQLiteResultBridge new];
    bridge->_lines = lines;
    return bridge;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return (NSInteger)_lines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"QRes"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"QRes"];
    cell.textLabel.text = _lines[(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 4;
    return cell;
}

@end

#pragma mark - Private: table/view data browser

@interface FFSQLiteDataViewController : UITableViewController
- (instancetype)initWithService:(FFSQLiteService *)service objectName:(NSString *)name isView:(BOOL)isView;
@end

@implementation FFSQLiteDataViewController
{
    __weak FFSQLiteService *_service;
    NSString *_objectName;
    BOOL _isView;
    NSArray<NSString *> *_columns;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_rows;
    NSUInteger _offset;
    long long _totalRows;
    UILabel *_status;
    UIBarButtonItem *_nextItem;
    UIBarButtonItem *_prevItem;
}

- (instancetype)initWithService:(FFSQLiteService *)service objectName:(NSString *)name isView:(BOOL)isView
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _service = service;
        _objectName = [name copy];
        _isView = isView;
        _rows = [NSMutableArray array];
        _totalRows = -1;
        self.title = name;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Row"];

    UIBarButtonItem *schema = [[UIBarButtonItem alloc] initWithTitle:@"结构"
        style:UIBarButtonItemStylePlain target:self action:@selector(showSchema)];

    if (_isView) {
        // 视图没有分页：仅保留结构入口。
        self.navigationItem.rightBarButtonItem = schema;
    } else {
        _nextItem = [[UIBarButtonItem alloc] initWithTitle:@"下一页"
            style:UIBarButtonItemStylePlain target:self action:@selector(nextPage)];
        _prevItem = [[UIBarButtonItem alloc] initWithTitle:@"上一页"
            style:UIBarButtonItemStylePlain target:self action:@selector(prevPage)];
        _nextItem.enabled = NO;
        _prevItem.enabled = NO;
        self.navigationItem.rightBarButtonItems = @[schema, _nextItem, _prevItem];

        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 30)];
        status.font = [UIFont systemFontOfSize:11];
        status.textAlignment = NSTextAlignmentCenter;
        status.textColor = UIColor.secondaryLabelColor;
        status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        status.text = @"正在统计行数…";
        _status = status;
        self.tableView.tableHeaderView = status;

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            long long count = [_service rowCountForTable:_objectName];
            dispatch_async(dispatch_get_main_queue(), ^{
                _totalRows = count;
                [self loadOffset:0];
            });
        });
    }
}

- (void)loadOffset:(NSUInteger)offset
{
    NSString *quoted = [_objectName stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\"", quoted];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *columns = nil;
        NSError *error = nil;
        NSArray *rows = [_service rowsForQuery:sql limit:kSQLitePageRows offset:offset
            outColumns:&columns error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!rows) {
                [strongSelf flash:error.localizedDescription ?: @"查询失败"];
                return;
            }
            strongSelf->_columns = columns;
            [strongSelf->_rows removeAllObjects];
            [strongSelf->_rows addObjectsFromArray:rows];
            strongSelf->_offset = offset;
            [strongSelf.tableView reloadData];
            [strongSelf updateStatus];
        });
    });
}

- (void)updateStatus
{
    if (_status)
        _status.text = [NSString stringWithFormat:@"共 %lld 行 · 显示第 %lu–%lu 行",
            _totalRows, (unsigned long)_offset + 1,
            (unsigned long)(_offset + _rows.count)];
    _prevItem.enabled = _offset > 0;
    _nextItem.enabled = _rows.count == kSQLitePageRows &&
        (_totalRows < 0 || (unsigned long long)_offset + kSQLitePageRows <
            (unsigned long long)MAX(_totalRows, 0));
}

- (void)nextPage { [self loadOffset:_offset + kSQLitePageRows]; }
- (void)prevPage
{
    [self loadOffset:_offset > kSQLitePageRows ? _offset - kSQLitePageRows : 0];
}

- (void)showSchema
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *body = [NSMutableString string];
        [body appendString:[_service schemaSQLForObject:_objectName] ?: @"-- 无 schema"];
        for (NSString *index in [_service indexNamesForTable:_objectName]) {
            [body appendFormat:@"\n\n%@\n%@", index,
                [_service schemaSQLForObject:index] ?: @""];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:
                [NSString stringWithFormat:@"%@ 结构", weakSelf->_objectName]
                message:body.length > 2000
                    ? [NSString stringWithFormat:@"%@\n…", [body substringToIndex:2000]]
                    : body
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    UIPasteboard.generalPasteboard.string = body;
                }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

#pragma mark - Table

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return (NSInteger)_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Row"
        forIndexPath:indexPath];
    NSDictionary<NSString *, NSString *> *row = _rows[(NSUInteger)indexPath.row];
    NSMutableString *line = [NSMutableString string];
    for (NSString *column in _columns) {
        if (line.length) [line appendString:@" | "];
        [line appendFormat:@"%@=%@", column, row[column] ?: @""];
    }
    cell.textLabel.text = line;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 3;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Private: SQL console

@interface FFSQLiteQueryViewController : UIViewController <UITextViewDelegate>
@property(nonatomic, strong) FFSQLiteResultBridge *resultBridge;
@end

@implementation FFSQLiteQueryViewController
{
    __weak FFSQLiteService *_service;
    UITextView *_editor;
    UIBarButtonItem *_runItem;
}

- (instancetype)initWithService:(FFSQLiteService *)service
{
    self = [super init];
    if (self) {
        _service = service;
        self.title = @"SQL 查询";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    _editor = [[UITextView alloc] initWithFrame:self.view.bounds];
    _editor.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    _editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _editor.delegate = self;
    _editor.text = @"SELECT name, type\nFROM sqlite_master\nLIMIT 50";
    [self.view addSubview:_editor];

    _runItem = [[UIBarButtonItem alloc] initWithTitle:@"运行"
        style:UIBarButtonItemStyleDone target:self action:@selector(runQuery)];
    self.navigationItem.rightBarButtonItem = _runItem;
}

- (void)textViewDidChange:(__unused UITextView *)textView
{
    _runItem.enabled = textView.text.length > 0;
}

- (void)runQuery
{
    NSString *sql = _editor.text.copy;
    _runItem.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *columns = nil;
        NSError *error = nil;
        NSArray *rows = [_service rowsForQuery:sql limit:500 offset:0
            outColumns:&columns error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_runItem.enabled = YES;
            if (!rows && error) {
                [strongSelf flash:[NSString stringWithFormat:@"查询失败：%@",
                    error.localizedDescription]];
                return;
            }
            if (!columns || !rows) {
                [strongSelf flash:@"语句没有返回结果集（当前只支持 SELECT 查询）"];
                return;
            }
            [strongSelf presentResults:rows columns:columns];
        });
    });
}

- (void)presentResults:(NSArray<NSDictionary<NSString *, NSString *> *> *)rows
               columns:(NSArray<NSString *> *)columns
{
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSMutableString *line = [NSMutableString string];
        for (NSString *column in columns) {
            if (line.length) [line appendString:@" | "];
            [line appendFormat:@"%@=%@", column, row[column] ?: @""];
        }
        [lines addObject:line];
    }

    UITableViewController *results =
        [[UITableViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    results.title = [NSString stringWithFormat:@"%lu 行", (unsigned long)rows.count];
    results.tableView.rowHeight = UITableViewAutomaticDimension;
    results.tableView.estimatedRowHeight = 40;
    [results.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"QRes"];

    self.resultBridge = [FFSQLiteResultBridge bridgeWithLines:lines];
    results.tableView.dataSource = self.resultBridge;

    results.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self
        action:@selector(closePresented)];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:results];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)closePresented
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Root browser

@interface FFSQLiteBrowserViewController ()
@property(nonatomic, strong) FFSQLiteService *service;
@property(nonatomic, strong) NSArray<NSString *> *tables;
@property(nonatomic, strong) NSArray<NSString *> *views;
@property(nonatomic, copy) NSString *summary;
@end

@implementation FFSQLiteBrowserViewController

- (instancetype)initWithDatabasePath:(NSString *)path
{
    NSError *error = nil;
    FFSQLiteService *service =
        [[FFSQLiteService alloc] initWithDatabasePath:path error:&error];
    if (!service) {
        FFLogTag(@"SQLite", @"open FAIL %@ (%@)", path, error.localizedDescription);
        return nil;
    }
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _service = service;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)dealloc
{
    [_service close];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Cell"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *info = weakSelf.service.databaseInfo;
        NSArray *tables = weakSelf.service.tableNames;
        NSArray *views = weakSelf.service.viewNames;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.summary = info[@"summary"];
            strongSelf.tables = tables;
            strongSelf.views = views;
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView
{
    return 4;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 1;
        case 1: return MAX(self.tables.count, (NSUInteger)1);
        case 2: return MAX(self.views.count, (NSUInteger)1);
        case 3: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"数据库";
        case 1: return [NSString stringWithFormat:@"表（%lu）", (unsigned long)self.tables.count];
        case 2: return [NSString stringWithFormat:@"视图（%lu）", (unsigned long)self.views.count];
        case 3: return @"工具";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
        forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.textLabel.numberOfLines = 3;
    switch (indexPath.section) {
        case 0:
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
            cell.textLabel.text = self.summary ?: @"正在读取数据库信息…";
            break;
        case 1:
            cell.textLabel.text = self.tables.count ?
                self.tables[(NSUInteger)indexPath.row] : @"无表";
            cell.accessoryType = self.tables.count ? cell.accessoryType :
                UITableViewCellAccessoryNone;
            break;
        case 2:
            cell.textLabel.text = self.views.count ?
                self.views[(NSUInteger)indexPath.row] : @"无视图";
            cell.accessoryType = self.views.count ? cell.accessoryType :
                UITableViewCellAccessoryNone;
            break;
        default:
            cell.textLabel.text = @"SQL 查询…";
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3) {
        FFSQLiteQueryViewController *query =
            [[FFSQLiteQueryViewController alloc] initWithService:self.service];
        [self.navigationController pushViewController:query animated:YES];
        return;
    }
    BOOL isView = indexPath.section == 2;
    NSArray *list = isView ? self.views : self.tables;
    if ((NSUInteger)indexPath.row >= list.count) return;
    FFSQLiteDataViewController *data = [[FFSQLiteDataViewController alloc]
        initWithService:self.service objectName:list[(NSUInteger)indexPath.row]
                  isView:isView];
    [self.navigationController pushViewController:data animated:YES];
}

@end
