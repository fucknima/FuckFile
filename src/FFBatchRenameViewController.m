#import "FFBatchRenameViewController.h"

#import "FFBatchRename.h"
#import "FFBrowserViewController.h"
#import "FFFileOperationService.h"
#import "FFLogger.h"

typedef NS_ENUM(NSInteger, FFBatchRenameField) {
    FFBatchRenameFieldFind = 0,
    FFBatchRenameFieldReplace,
    FFBatchRenameFieldCase,
    FFBatchRenameFieldPrefix,
    FFBatchRenameFieldSuffix,
    FFBatchRenameFieldSequencePrefix,
    FFBatchRenameFieldStart,
    FFBatchRenameFieldDigits,
};

@interface FFBatchRenameViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UISegmentedControl *modeControl;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UITextField *> *fields;
@property(nonatomic) BOOL caseSensitive;
@property(nonatomic, copy, nullable) NSArray<NSString *> *plannedNames;
@property(nonatomic, copy, nullable) NSString *planError;
@property(nonatomic, copy) NSArray<NSNumber *> *fieldOrder;
@end

@implementation FFBatchRenameViewController

- (instancetype)initWithEntries:(NSArray<FFEntry *> *)entries inDirectory:(NSString *)directory
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _entries = [entries copy];
        _directory = [directory copy];
        _fields = [NSMutableDictionary dictionary];
        _fieldOrder = @[@(FFBatchRenameFieldFind), @(FFBatchRenameFieldReplace), @(FFBatchRenameFieldCase),
                        @(FFBatchRenameFieldPrefix), @(FFBatchRenameFieldSuffix),
                        @(FFBatchRenameFieldSequencePrefix), @(FFBatchRenameFieldStart),
                        @(FFBatchRenameFieldDigits)];
        self.title = [NSString stringWithFormat:@"批量重命名（%lu）", (unsigned long)entries.count];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"查找替换", @"前后缀", @"序号"]];
    self.modeControl.selectedSegmentIndex = 0;
    [self.modeControl addTarget:self action:@selector(modeChanged)
        forControlEvents:UIControlEventValueChanged];

    UIBarButtonItem *apply = [[UIBarButtonItem alloc] initWithTitle:@"应用"
        style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
    self.navigationItem.rightBarButtonItem = apply;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    [self recomputePlan];
}

- (void)cancel
{
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onFinished) self.onFinished(NO);
    }];
}

#pragma mark - Fields

- (UITextField *)fieldForKind:(FFBatchRenameField)kind
{
    UITextField *field = self.fields[@(kind)];
    if (field) return field;
    field = [UITextField new];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.delegate = self;
    field.frame = CGRectMake(0, 0, 190, 36);
    [field addTarget:self action:@selector(fieldChanged)
        forControlEvents:UIControlEventEditingChanged];
    switch (kind) {
        case FFBatchRenameFieldFind: field.placeholder = @"要查找的文字"; break;
        case FFBatchRenameFieldReplace: field.placeholder = @"替换为（可留空）"; break;
        case FFBatchRenameFieldPrefix: field.placeholder = @"前缀（可留空）"; break;
        case FFBatchRenameFieldSuffix: field.placeholder = @"后缀（可留空）"; break;
        case FFBatchRenameFieldSequencePrefix: field.placeholder = @"序号前缀（可留空）"; break;
        case FFBatchRenameFieldStart: field.placeholder = @"起始编号"; field.text = @"1";
            field.keyboardType = UIKeyboardTypeNumberPad; break;
        case FFBatchRenameFieldDigits: field.placeholder = @"位数"; field.text = @"3";
            field.keyboardType = UIKeyboardTypeNumberPad; break;
        default: break;
    }
    self.fields[@(kind)] = field;
    return field;
}

- (void)modeChanged
{
    [self.tableView reloadData];
    [self recomputePlan];
}

- (void)fieldChanged
{
    [self recomputePlan];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)toggleCase:(UISwitch *)sender
{
    self.caseSensitive = sender.on;
    [self recomputePlan];
}

#pragma mark - Plan

- (NSArray<NSNumber *> *)fieldKindsForCurrentMode
{
    switch (self.modeControl.selectedSegmentIndex) {
        case 1: return @[@(FFBatchRenameFieldPrefix), @(FFBatchRenameFieldSuffix)];
        case 2: return @[@(FFBatchRenameFieldSequencePrefix), @(FFBatchRenameFieldStart),
                        @(FFBatchRenameFieldDigits)];
        default: return @[@(FFBatchRenameFieldFind), @(FFBatchRenameFieldReplace), @(FFBatchRenameFieldCase)];
    }
}

- (NSString *)valueForKind:(FFBatchRenameField)kind
{
    return [self fieldForKind:kind].text ?: @"";
}

- (void)recomputePlan
{
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:self.entries.count];
    for (FFEntry *entry in self.entries) [names addObject:entry.name];

    NSString *error = nil;
    NSArray<NSString *> *plan = [FFBatchRename newNamesForNames:names
        mode:(FFBatchRenameMode)self.modeControl.selectedSegmentIndex
        find:[self valueForKind:FFBatchRenameFieldFind]
        replace:[self valueForKind:FFBatchRenameFieldReplace]
        caseSensitive:self.caseSensitive
        prefix:[self valueForKind:FFBatchRenameFieldPrefix]
        suffix:[self valueForKind:FFBatchRenameFieldSuffix]
        sequencePrefix:[self valueForKind:FFBatchRenameFieldSequencePrefix]
        start:[self valueForKind:FFBatchRenameFieldStart].integerValue ?: 1
        digits:[self valueForKind:FFBatchRenameFieldDigits].integerValue ?: 3
        error:&error];

    if (plan) {
        // Collision check against names already in the folder (the batch's own
        // current names are allowed to disappear).
        NSMutableSet<NSString *> *own = [NSMutableSet set];
        for (NSString *name in names) [own addObject:name.lowercaseString];
        NSArray<NSString *> *existing = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:self.directory error:nil] ?: @[];
        for (NSString *name in existing) {
            if ([own containsObject:name.lowercaseString]) continue;
            for (NSString *target in plan) {
                if ([target.lowercaseString isEqualToString:name.lowercaseString]) {
                    error = [NSString stringWithFormat:@"目标名已存在：“%@”。", target];
                    break;
                }
            }
            if (error) break;
        }
    }

    self.plannedNames = error ? nil : plan;
    self.planError = error;
    self.navigationItem.rightBarButtonItem.enabled = (plan != nil);
    [self.tableView reloadData];
}

#pragma mark - Apply

- (void)apply
{
    if (!self.plannedNames.count) return;
    NSUInteger changed = 0;
    NSUInteger failed = 0;
    NSString *firstError = nil;
    for (NSUInteger index = 0; index < self.entries.count; index++) {
        FFEntry *entry = self.entries[index];
        NSString *newName = self.plannedNames[index];
        if ([newName isEqualToString:entry.name]) continue;
        NSString *newPath = [self.directory stringByAppendingPathComponent:newName];
        NSError *error = nil;
        if ([[FFFileOperationService sharedService] renameItemAtPath:entry.path
            toPath:newPath overwrite:NO error:&error]) {
            changed += 1;
        } else {
            failed += 1;
            if (!firstError) firstError = error.localizedDescription;
        }
    }

    NSString *message = [NSString stringWithFormat:@"已重命名 %lu 项", (unsigned long)changed];
    if (failed) message = [message stringByAppendingFormat:@"，%lu 项失败（%@）",
        (unsigned long)failed, firstError ?: @"未知错误"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"批量重命名"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf dismissViewControllerAnimated:YES completion:^{
                if (weakSelf.onFinished) weakSelf.onFinished(changed > 0);
            }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    switch (section) {
        case 0: return @"模式";
        case 1: return @"参数";
        default: return @"预览";
    }
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return self.fieldKindsForCurrentMode.count;
    return self.entries.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
        reuseIdentifier:@"Cell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    if (indexPath.section == 0) {
        cell.accessoryView = self.modeControl;
        cell.textLabel.text = @"重命名方式";
        return cell;
    }

    if (indexPath.section == 1) {
        FFBatchRenameField kind = (FFBatchRenameField)self.fieldKindsForCurrentMode[indexPath.row].integerValue;
        if (kind == FFBatchRenameFieldCase) {
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.caseSensitive;
            [toggle addTarget:self action:@selector(toggleCase:) forControlEvents:UIControlEventValueChanged];
            cell.textLabel.text = @"区分大小写";
            cell.accessoryView = toggle;
            return cell;
        }
        UITextField *field = [self fieldForKind:kind];
        cell.textLabel.text = field.placeholder;
        cell.accessoryView = field;
        return cell;
    }

    FFEntry *entry = indexPath.row < self.entries.count ? self.entries[indexPath.row] : nil;
    if (entry) {
        cell.textLabel.text = entry.name;
        NSString *newName = self.plannedNames.count > indexPath.row
            ? self.plannedNames[indexPath.row] : @"—";
        cell.detailTextLabel.text = newName;
        cell.detailTextLabel.textColor = [newName isEqualToString:entry.name]
            ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
    } else {
        cell.textLabel.text = self.planError ?: @"名称可用";
        cell.textLabel.textColor = self.planError ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    }
    return cell;
}

@end
