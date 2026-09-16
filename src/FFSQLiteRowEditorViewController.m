#import "FFSQLiteRowEditorViewController.h"

#import "FFLogger.h"
#import "FFSQLiteService.h"

static NSString *FFSQLiteQuoteIdentifier(NSString *name)
{
    return [NSString stringWithFormat:@"\"%@\"",
        [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

static NSString *FFSQLiteQuoteValue(NSString *value)
{
    return [NSString stringWithFormat:@"'%@'",
        [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

@interface FFSQLiteRowEditorViewController ()
@property(nonatomic, strong) FFSQLiteService *service;
@property(nonatomic, copy) NSString *table;
@property(nonatomic) long long rowID;
@property(nonatomic, copy) NSArray<NSString *> *columns;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *originalValues;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *editedValues;
@property(nonatomic, strong) NSMutableSet<NSString *> *nullColumns;
@property(nonatomic, copy) void (^completion)(BOOL saved);
@property(nonatomic, strong) UIBarButtonItem *saveItem;
@end

@implementation FFSQLiteRowEditorViewController

- (instancetype)initWithService:(FFSQLiteService *)service
                          table:(NSString *)table
                          rowID:(long long)rowID
                        columns:(NSArray<NSString *> *)columns
                         values:(NSDictionary<NSString *, NSString *> *)values
                     completion:(void (^)(BOOL))completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _service = service;
        _table = [table copy];
        _rowID = rowID;
        _columns = [columns copy];
        _originalValues = [values copy];
        _editedValues = [NSMutableDictionary dictionary];
        _nullColumns = [NSMutableSet set];
        _completion = [completion copy];
        self.title = [NSString stringWithFormat:@"第 %lld 行", rowID];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.saveItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.saveItem.enabled = NO;
    self.navigationItem.rightBarButtonItem = self.saveItem;
}

- (BOOL)hasChanges
{
    return self.editedValues.count > 0 || self.nullColumns.count > 0;
}

- (void)refreshSaveItem
{
    self.saveItem.enabled = self.hasChanges;
}

#pragma mark - Table

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return (NSInteger)self.columns.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section
{
    return self.table;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section
{
    return @"只提交修改过的列；写入在一个事务内完成，失败自动回滚。NULL 与空字符串是两种不同取值。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSString *column = self.columns[(NSUInteger)indexPath.row];
    BOOL isNull = [self.nullColumns containsObject:column];
    NSString *edited = self.editedValues[column];
    BOOL changed = isNull || edited != nil;

    cell.textLabel.text = column;
    cell.textLabel.font = changed
        ? [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold]
        : [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    cell.detailTextLabel.text = isNull ? @"NULL" : (edited ?: self.originalValues[column] ?: @"");
    cell.detailTextLabel.textColor = changed ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.detailTextLabel.numberOfLines = 1;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *column = self.columns[(NSUInteger)indexPath.row];
    NSString *current = [self.nullColumns containsObject:column]
        ? nil : (self.editedValues[column] ?: self.originalValues[column]);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:column
        message:@"修改该列的值" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = current;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"设为 NULL" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf.editedValues removeObjectForKey:column];
            [weakSelf.nullColumns addObject:column];
            [weakSelf refreshSaveItem];
            [weakSelf.tableView reloadData];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *value = alert.textFields.firstObject.text ?: @"";
            [weakSelf.nullColumns removeObject:column];
            if ([value isEqualToString:weakSelf.originalValues[column] ?: @""]) {
                [weakSelf.editedValues removeObjectForKey:column];
            } else {
                weakSelf.editedValues[column] = value;
            }
            [weakSelf refreshSaveItem];
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Save

- (void)save
{
    if (!self.hasChanges) return;
    NSMutableArray<NSString *> *assignments = [NSMutableArray array];
    for (NSString *column in self.editedValues) {
        [assignments addObject:[NSString stringWithFormat:@"%@ = %@",
            FFSQLiteQuoteIdentifier(column),
            FFSQLiteQuoteValue(self.editedValues[column])]];
    }
    for (NSString *column in self.nullColumns) {
        [assignments addObject:[NSString stringWithFormat:@"%@ = NULL",
            FFSQLiteQuoteIdentifier(column)]];
    }
    if (!assignments.count) return;

    NSString *statement = [NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE rowid = %lld",
        FFSQLiteQuoteIdentifier(self.table), [assignments componentsJoinedByString:@", "],
        self.rowID];
    self.saveItem.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSInteger changed = 0;
        BOOL ok = [weakSelf.service applyStatementsInTransaction:@[statement]
            changedRows:&changed error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!ok) {
                strongSelf.saveItem.enabled = YES;
                [strongSelf presentError:error.localizedDescription ?: @"写入失败"];
                return;
            }
            FFLogTag(@"SQLite", @"row updated table=%@ rowid=%lld changed=%ld",
                strongSelf.table, strongSelf.rowID, (long)changed);
            if (changed == 0) {
                [strongSelf presentError:@"没有匹配的行，可能已被其他操作删除"];
                return;
            }
            if (strongSelf.completion) strongSelf.completion(YES);
            [strongSelf.navigationController popViewControllerAnimated:YES];
        });
    });
}

- (void)presentError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"写入失败"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
