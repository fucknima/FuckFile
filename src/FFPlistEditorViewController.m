#import "FFPlistEditorViewController.h"
#import "FFPlistDocument.h"
#import "FFPlistValueEditorViewController.h"
#import "FFLogger.h"

#import <CoreFoundation/CoreFoundation.h>

const unsigned long long FFPlistEditorMaximumEditableBytes = 8ULL * 1024ULL * 1024ULL;

static BOOL FFPlistIsBoolean(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL FFPlistNumberIsReal(NSNumber *value)
{
    const char *type = value.objCType;
    return strcmp(type, @encode(float)) == 0 ||
           strcmp(type, @encode(double)) == 0;
}

static NSString *FFPlistTypeName(id value)
{
    if ([value isKindOfClass:NSDictionary.class]) return @"字典";
    if ([value isKindOfClass:NSArray.class]) return @"数组";
    if ([value isKindOfClass:NSString.class]) return @"字符串";
    if ([value isKindOfClass:NSData.class]) return @"数据";
    if ([value isKindOfClass:NSDate.class]) return @"日期";
    if (FFPlistIsBoolean(value)) return @"布尔";
    if ([value isKindOfClass:NSNumber.class])
        return FFPlistNumberIsReal(value) ? @"实数" : @"整数";
    return @"未知";
}

static NSString *FFPlistSymbolName(id value)
{
    if ([value isKindOfClass:NSDictionary.class]) return @"curlybraces.square";
    if ([value isKindOfClass:NSArray.class]) return @"list.number";
    if ([value isKindOfClass:NSString.class]) return @"textformat";
    if ([value isKindOfClass:NSData.class]) return @"doc.on.doc";
    if ([value isKindOfClass:NSDate.class]) return @"calendar";
    if (FFPlistIsBoolean(value)) return @"switch.2";
    if ([value isKindOfClass:NSNumber.class]) return @"number";
    return @"questionmark.square.dashed";
}

static NSString *FFPlistValueSummary(id value)
{
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"%lu 项", (unsigned long)[value count]];
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"%lu 项", (unsigned long)[value count]];
    if (FFPlistIsBoolean(value)) return [value boolValue] ? @"YES" : @"NO";
    if ([value isKindOfClass:NSString.class]) {
        NSString *oneLine = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" ↵ "];
        if (oneLine.length > 120)
            oneLine = [[oneLine substringToIndex:117] stringByAppendingString:@"…"];
        return oneLine.length ? oneLine : @"空字符串";
    }
    if ([value isKindOfClass:NSData.class])
        return [NSByteCountFormatter stringFromByteCount:(long long)[value length]
            countStyle:NSByteCountFormatterCountStyleMemory];
    if ([value isKindOfClass:NSDate.class]) {
        static NSDateFormatter *formatter;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [NSDateFormatter new];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterMediumStyle;
        });
        return [formatter stringFromDate:value];
    }
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return [value description] ?: @"";
}

static id FFPlistEditableCopy(id object)
{
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithCapacity:[object count]];
        [object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            copy[key] = FFPlistEditableCopy(value);
        }];
        return copy;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *copy = [NSMutableArray arrayWithCapacity:[object count]];
        for (id value in object) [copy addObject:FFPlistEditableCopy(value)];
        return copy;
    }
    return [object conformsToProtocol:@protocol(NSCopying)] ? [object copy] : object;
}

static NSString *FFPlistFormatName(NSPropertyListFormat format)
{
    switch (format) {
        case NSPropertyListBinaryFormat_v1_0: return @"Binary";
        case NSPropertyListOpenStepFormat: return @"OpenStep";
        default: return @"XML";
    }
}

typedef NS_ENUM(NSInteger, FFPlistNewValueType) {
    FFPlistNewValueString = 0,
    FFPlistNewValueBoolean,
    FFPlistNewValueInteger,
    FFPlistNewValueReal,
    FFPlistNewValueDate,
    FFPlistNewValueData,
    FFPlistNewValueDictionary,
    FFPlistNewValueArray,
};

@interface FFPlistEditorViewController () <UISearchResultsUpdating, UIGestureRecognizerDelegate>
@property(nonatomic, strong) FFPlistDocument *document;
@property(nonatomic, copy) NSArray *keyPath;
@property(nonatomic, strong) id scope;
@property(nonatomic, copy) NSArray *rowComponents;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UIBarButtonItem *saveButton;
@property(nonatomic, strong) UIBarButtonItem *addButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) BOOL ownsDocument;
@end

@implementation FFPlistEditorViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _document = [[FFPlistDocument alloc] initWithPath:path];
        _keyPath = @[];
        _ownsDocument = YES;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (instancetype)initWithDocument:(FFPlistDocument *)document
                         keyPath:(NSArray *)keyPath
                           title:(NSString *)title
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _document = document;
        _keyPath = [keyPath copy];
        _ownsDocument = NO;
        self.title = title;
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.navigationController.interactivePopGestureRecognizer.delegate == self)
        self.navigationController.interactivePopGestureRecognizer.delegate = nil;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"搜索 Key 或 Value";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    self.saveButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave
        target:self action:@selector(saveTapped)];
    self.addButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:nil action:nil];
    self.navigationItem.rightBarButtonItems = @[self.saveButton, self.addButton];

    if (self.ownsDocument) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:@"返回" style:UIBarButtonItemStylePlain
            target:self action:@selector(backTapped)];
        self.navigationController.interactivePopGestureRecognizer.delegate = self;
    }

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(documentDidChange:)
        name:FFPlistDocumentDidChangeNotification object:self.document];

    if (self.document.isLoaded) [self refreshScopeAndUI];
    else [self beginLoading];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshScopeAndUI];
}

#pragma mark - Loading / state

- (void)beginLoading
{
    self.saveButton.enabled = NO;
    self.addButton.enabled = NO;
    self.searchController.searchBar.userInteractionEnabled = NO;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;

    FFPlistDocument *document = self.document;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [document loadWithMaximumBytes:FFPlistEditorMaximumEditableBytes error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.tableView.backgroundView = nil;
            self.spinner = nil;
            self.searchController.searchBar.userInteractionEnabled = YES;
            if (!ok) {
                [self showLoadError:error];
                return;
            }
            [self refreshScopeAndUI];
        });
    });
}

- (void)showLoadError:(NSError *)error
{
    NSString *message = error.localizedDescription ?: @"无法打开属性表";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"返回"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentDidChange:(NSNotification *)note
{
    if (note.object != self.document) return;
    [self refreshScopeAndUI];
}

- (id)objectAtKeyPath:(NSArray *)keyPath
{
    id current = self.document.rootObject;
    for (id component in keyPath) {
        if ([component isKindOfClass:NSNumber.class] &&
            [current isKindOfClass:NSArray.class]) {
            NSUInteger index = [component unsignedIntegerValue];
            if (index >= [current count]) return nil;
            current = current[index];
        } else if ([component isKindOfClass:NSString.class] &&
                   [current isKindOfClass:NSDictionary.class]) {
            current = current[component];
        } else {
            return nil;
        }
    }
    return current;
}

- (void)refreshScopeAndUI
{
    if (!self.document.isLoaded) return;
    self.scope = [self objectAtKeyPath:self.keyPath];

    if (!self.scope && self.keyPath.count > 0) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    NSString *query = [self.searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *rows = [NSMutableArray array];

    if ([self.scope isKindOfClass:NSDictionary.class]) {
        NSArray *keys = [[self.scope allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] localizedCaseInsensitiveCompare:[b description]];
        }];
        for (NSString *key in keys) {
            id value = self.scope[key];
            if (query.length == 0 ||
                [key rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [FFPlistValueSummary(value) rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [FFPlistTypeName(value) rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
                [rows addObject:key];
        }
    } else if ([self.scope isKindOfClass:NSArray.class]) {
        for (NSUInteger index = 0; index < [self.scope count]; index++) {
            id value = self.scope[index];
            NSString *indexText = [NSString stringWithFormat:@"#%lu", (unsigned long)index];
            if (query.length == 0 ||
                [indexText rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [FFPlistValueSummary(value) rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [FFPlistTypeName(value) rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
                [rows addObject:@(index)];
        }
    }

    self.rowComponents = rows;
    self.saveButton.enabled = self.document.isDirty;
    self.addButton.enabled = [self.scope isKindOfClass:NSDictionary.class] ||
                             [self.scope isKindOfClass:NSArray.class];
    self.addButton.menu = [self buildAddMenu];

    NSString *format = FFPlistFormatName(self.document.format);
    NSString *dirty = self.document.isDirty ? @" · 已修改" : @"";
    self.navigationItem.prompt = [NSString stringWithFormat:@"%@%@ · %@",
        format, dirty, [self pathDisplayString]];

    [self.tableView reloadData];
    [self updateEmptyState];
}

- (NSString *)pathDisplayString
{
    if (self.keyPath.count == 0) return @"Root";
    NSMutableArray *parts = [NSMutableArray arrayWithObject:@"Root"];
    for (id component in self.keyPath) {
        if ([component isKindOfClass:NSNumber.class])
            [parts addObject:[NSString stringWithFormat:@"[%@]", component]];
        else
            [parts addObject:[component description]];
    }
    return [parts componentsJoinedByString:@" › "];
}

- (void)updateEmptyState
{
    if (!self.document.isLoaded || self.rowComponents.count > 0) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.numberOfLines = 0;
    label.text = self.searchController.searchBar.text.length ?
        @"没有匹配的 Key 或 Value" : @"当前容器为空\n点击右上角 + 添加条目";
    self.tableView.backgroundView = label;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController
{
    [self refreshScopeAndUI];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return (NSInteger)self.rowComponents.count;
}

- (id)valueForComponent:(id)component
{
    if ([self.scope isKindOfClass:NSDictionary.class] &&
        [component isKindOfClass:NSString.class]) return self.scope[component];
    if ([self.scope isKindOfClass:NSArray.class] &&
        [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        return index < [self.scope count] ? self.scope[index] : nil;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"PlistNode";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:identifier];

    id component = self.rowComponents[indexPath.row];
    id value = [self valueForComponent:component];
    BOOL dictionary = [self.scope isKindOfClass:NSDictionary.class];

    cell.textLabel.text = dictionary ? [component description] :
        [NSString stringWithFormat:@"[%@]", component];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        FFPlistTypeName(value), FFPlistValueSummary(value)];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = [UIImage systemImageNamed:FFPlistSymbolName(value)];
    cell.imageView.tintColor = UIColor.systemBlueColor;
    BOOL container = [value isKindOfClass:NSDictionary.class] ||
                     [value isKindOfClass:NSArray.class];
    cell.accessoryType = container ? UITableViewCellAccessoryDisclosureIndicator :
                                     UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openComponent:self.rowComponents[indexPath.row]];
}

- (void)openComponent:(id)component
{
    id value = [self valueForComponent:component];
    if (!value) return;

    if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
        NSString *title = [component isKindOfClass:NSNumber.class]
            ? [NSString stringWithFormat:@"[%@]", component] : [component description];
        FFPlistEditorViewController *next = [[FFPlistEditorViewController alloc]
            initWithDocument:self.document
            keyPath:[self.keyPath arrayByAddingObject:component]
            title:title];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }

    __weak typeof(self) weakSelf = self;
    FFPlistValueEditorViewController *editor =
        [[FFPlistValueEditorViewController alloc] initWithValue:value
            title:[component isKindOfClass:NSNumber.class]
                ? [NSString stringWithFormat:@"[%@]", component] : [component description]
            commitHandler:^(id newValue) {
                [weakSelf replaceComponent:component withValue:newValue];
            }];
    [self.navigationController pushViewController:editor animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    id component = self.rowComponents[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(__unused UIContextualAction *action,
            __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
            [weakSelf confirmDeleteComponent:component completion:completionHandler];
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                      point:(CGPoint)point
{
    (void)tableView; (void)point;
    id component = self.rowComponents[indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
            UIAction *open = [UIAction actionWithTitle:@"打开 / 编辑"
                image:[UIImage systemImageNamed:@"pencil"] identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf openComponent:component]; }];
            UIAction *copyValue = [UIAction actionWithTitle:@"复制值"
                image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf copyValueForComponent:component]; }];
            UIAction *copyPath = [UIAction actionWithTitle:@"复制 Key Path"
                image:[UIImage systemImageNamed:@"point.topleft.down.curvedto.point.bottomright.up"]
                identifier:nil handler:^(__unused UIAction *action) {
                    [UIPasteboard generalPasteboard].string = [weakSelf pathStringForComponent:component];
                }];
            NSMutableArray *children = [NSMutableArray arrayWithObjects:open, copyValue, copyPath, nil];

            if ([weakSelf.scope isKindOfClass:NSDictionary.class]) {
                UIAction *rename = [UIAction actionWithTitle:@"重命名 Key"
                    image:[UIImage systemImageNamed:@"character.cursor.ibeam"] identifier:nil
                    handler:^(__unused UIAction *action) { [weakSelf promptRenameComponent:component]; }];
                [children addObject:rename];
            }

            [children addObject:[UIAction actionWithTitle:@"复制条目"
                image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf duplicateComponent:component]; }]];

            if ([weakSelf.scope isKindOfClass:NSArray.class]) {
                NSUInteger idx = [component unsignedIntegerValue];
                if (idx > 0)
                    [children addObject:[UIAction actionWithTitle:@"上移"
                        image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil
                        handler:^(__unused UIAction *action) { [weakSelf moveArrayComponent:component offset:-1]; }]];
                if (idx + 1 < [weakSelf.scope count])
                    [children addObject:[UIAction actionWithTitle:@"下移"
                        image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil
                        handler:^(__unused UIAction *action) { [weakSelf moveArrayComponent:component offset:1]; }]];
            }

            [children addObject:[weakSelf changeTypeMenuForComponent:component]];
            UIAction *deleteMenuAction = [UIAction actionWithTitle:@"删除"
                image:[UIImage systemImageNamed:@"trash"] identifier:nil
                handler:^(__unused UIAction *action) {
                    [weakSelf confirmDeleteComponent:component completion:nil];
                }];
            [children addObject:deleteMenuAction];
            return [UIMenu menuWithTitle:@"" children:children];
        }];
}

#pragma mark - Mutations

- (void)replaceComponent:(id)component withValue:(id)value
{
    if (!value) return;
    if ([self.scope isKindOfClass:NSDictionary.class] && [component isKindOfClass:NSString.class])
        self.scope[component] = value;
    else if ([self.scope isKindOfClass:NSArray.class] && [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        if (index >= [self.scope count]) return;
        [self.scope replaceObjectAtIndex:index withObject:value];
    } else return;
    [self.document markChanged];
}

- (void)confirmDeleteComponent:(id)component completion:(void (^ _Nullable)(BOOL))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除条目？"
        message:[NSString stringWithFormat:@"将删除 %@。此操作在保存文件前仍可通过放弃修改撤销。",
            [component isKindOfClass:NSNumber.class]
                ? [NSString stringWithFormat:@"[%@]", component] : [component description]]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            BOOL removed = [weakSelf removeComponent:component];
            if (completion) completion(removed);
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)removeComponent:(id)component
{
    if ([self.scope isKindOfClass:NSDictionary.class] && [component isKindOfClass:NSString.class]) {
        if (!self.scope[component]) return NO;
        [self.scope removeObjectForKey:component];
    } else if ([self.scope isKindOfClass:NSArray.class] && [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        if (index >= [self.scope count]) return NO;
        [self.scope removeObjectAtIndex:index];
    } else return NO;
    [self.document markChanged];
    return YES;
}

- (void)promptRenameComponent:(NSString *)component
{
    if (![self.scope isKindOfClass:NSDictionary.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名 Key"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = component;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *newKey = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (newKey.length == 0) { [weakSelf showMessage:@"Key 不能为空" title:@"无法重命名"]; return; }
            if ([newKey isEqualToString:component]) return;
            if (weakSelf.scope[newKey] != nil) {
                [weakSelf showMessage:@"同名 Key 已存在，不会覆盖原值。" title:@"无法重命名"];
                return;
            }
            id value = weakSelf.scope[component];
            if (!value) return;
            weakSelf.scope[newKey] = value;
            [weakSelf.scope removeObjectForKey:component];
            [weakSelf.document markChanged];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)duplicateComponent:(id)component
{
    id value = [self valueForComponent:component];
    if (!value) return;
    id copy = FFPlistEditableCopy(value);
    if ([self.scope isKindOfClass:NSDictionary.class]) {
        NSString *base = [NSString stringWithFormat:@"%@ copy", component];
        NSString *candidate = base;
        NSUInteger n = 2;
        while (self.scope[candidate] != nil)
            candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n++];
        self.scope[candidate] = copy;
    } else if ([self.scope isKindOfClass:NSArray.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        if (index >= [self.scope count]) return;
        [self.scope insertObject:copy atIndex:index + 1];
    }
    [self.document markChanged];
}

- (void)moveArrayComponent:(NSNumber *)component offset:(NSInteger)offset
{
    if (![self.scope isKindOfClass:NSArray.class]) return;
    NSInteger from = component.integerValue, to = from + offset;
    if (from < 0 || to < 0 || from >= (NSInteger)[self.scope count] || to >= (NSInteger)[self.scope count]) return;
    id value = self.scope[(NSUInteger)from];
    [self.scope removeObjectAtIndex:(NSUInteger)from];
    [self.scope insertObject:value atIndex:(NSUInteger)to];
    [self.document markChanged];
}

- (void)copyValueForComponent:(id)component
{
    id value = [self valueForComponent:component];
    NSString *text = nil;
    if ([value isKindOfClass:NSData.class]) text = [value base64EncodedStringWithOptions:0];
    else if ([value isKindOfClass:NSDate.class]) text = [value description];
    else if ([value isKindOfClass:NSString.class]) text = value;
    else if ([value isKindOfClass:NSNumber.class]) text = [value stringValue];
    else text = [value description];
    [UIPasteboard generalPasteboard].string = text ?: @"";
}

- (NSString *)pathStringForComponent:(id)component
{
    NSMutableString *path = [NSMutableString stringWithString:@"Root"];
    for (id part in [self.keyPath arrayByAddingObject:component]) {
        if ([part isKindOfClass:NSNumber.class]) [path appendFormat:@"[%@]", part];
        else [path appendFormat:@".%@", part];
    }
    return path;
}

#pragma mark - Add / type

- (UIMenu *)buildAddMenu
{
    NSMutableArray *actions = [NSMutableArray array];
    NSArray *specs = @[
        @[@(FFPlistNewValueString), @"字符串", @"textformat"],
        @[@(FFPlistNewValueBoolean), @"布尔", @"switch.2"],
        @[@(FFPlistNewValueInteger), @"整数", @"number"],
        @[@(FFPlistNewValueReal), @"实数", @"number"],
        @[@(FFPlistNewValueDate), @"日期", @"calendar"],
        @[@(FFPlistNewValueData), @"数据", @"doc.on.doc"],
        @[@(FFPlistNewValueDictionary), @"字典", @"curlybraces.square"],
        @[@(FFPlistNewValueArray), @"数组", @"list.number"],
    ];
    __weak typeof(self) weakSelf = self;
    for (NSArray *spec in specs) {
        FFPlistNewValueType type = [spec[0] integerValue];
        [actions addObject:[UIAction actionWithTitle:spec[1]
            image:[UIImage systemImageNamed:spec[2]] identifier:nil
            handler:^(__unused UIAction *action) { [weakSelf addValueOfType:type]; }]];
    }
    return [UIMenu menuWithTitle:@"添加条目" children:actions];
}

- (id)defaultValueForType:(FFPlistNewValueType)type
{
    switch (type) {
        case FFPlistNewValueBoolean: return @NO;
        case FFPlistNewValueInteger: return @0;
        case FFPlistNewValueReal: return @0.0;
        case FFPlistNewValueDate: return NSDate.date;
        case FFPlistNewValueData: return NSMutableData.data;
        case FFPlistNewValueDictionary: return [NSMutableDictionary dictionary];
        case FFPlistNewValueArray: return [NSMutableArray array];
        default: return @"";
    }
}

- (NSString *)nameForType:(FFPlistNewValueType)type
{
    switch (type) {
        case FFPlistNewValueBoolean: return @"布尔";
        case FFPlistNewValueInteger: return @"整数";
        case FFPlistNewValueReal: return @"实数";
        case FFPlistNewValueDate: return @"日期";
        case FFPlistNewValueData: return @"数据";
        case FFPlistNewValueDictionary: return @"字典";
        case FFPlistNewValueArray: return @"数组";
        default: return @"字符串";
    }
}

- (void)addValueOfType:(FFPlistNewValueType)type
{
    if ([self.scope isKindOfClass:NSArray.class]) {
        [self.scope addObject:[self defaultValueForType:type]];
        [self.document markChanged];
        return;
    }
    if (![self.scope isKindOfClass:NSDictionary.class]) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"添加%@", [self nameForType:type]]
        message:@"输入新的 Key；已有 Key 不会被覆盖。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Key";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *key = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (key.length == 0) { [weakSelf showMessage:@"Key 不能为空" title:@"无法添加"]; return; }
            if (weakSelf.scope[key] != nil) {
                [weakSelf showMessage:@"同名 Key 已存在，不会覆盖原值。" title:@"无法添加"];
                return;
            }
            weakSelf.scope[key] = [weakSelf defaultValueForType:type];
            [weakSelf.document markChanged];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIMenu *)changeTypeMenuForComponent:(id)component
{
    NSArray *specs = @[
        @[@(FFPlistNewValueString), @"字符串"], @[@(FFPlistNewValueBoolean), @"布尔"],
        @[@(FFPlistNewValueInteger), @"整数"], @[@(FFPlistNewValueReal), @"实数"],
        @[@(FFPlistNewValueDate), @"日期"], @[@(FFPlistNewValueData), @"数据"],
        @[@(FFPlistNewValueDictionary), @"字典"], @[@(FFPlistNewValueArray), @"数组"],
    ];
    NSMutableArray *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSArray *spec in specs) {
        FFPlistNewValueType type = [spec[0] integerValue];
        [actions addObject:[UIAction actionWithTitle:spec[1] image:nil identifier:nil
            handler:^(__unused UIAction *action) { [weakSelf confirmChangeComponent:component toType:type]; }]];
    }
    return [UIMenu menuWithTitle:@"更改类型（重置值）"
        image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil
        options:0 children:actions];
}

- (void)confirmChangeComponent:(id)component toType:(FFPlistNewValueType)type
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"更改类型？"
        message:[NSString stringWithFormat:@"当前值将被重置为新的%@默认值。", [self nameForType:type]]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"更改" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf replaceComponent:component withValue:[weakSelf defaultValueForType:type]];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Save / conflict

- (void)saveTapped { [self attemptSaveWithCompletion:nil]; }

- (void)attemptSaveWithCompletion:(void (^ _Nullable)(BOOL success))completion
{
    NSError *error = nil;
    if ([self.document saveForcingExternalOverwrite:NO error:&error]) {
        [self flash:@"已保存"];
        if (completion) completion(YES);
        return;
    }
    if ([error.domain isEqualToString:FFPlistDocumentErrorDomain] &&
        error.code == FFPlistDocumentErrorExternalModification) {
        [self presentConflict:error completion:completion];
        return;
    }
    FFLogTag(@"PlistEditor", @"save FAIL path=%@ error=%@", self.document.filePath, error);
    [self offerCopyForSaveError:error completion:completion];
}

- (void)presentConflict:(NSError *)error completion:(void (^ _Nullable)(BOOL))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件已在外部修改"
        message:@"打开此 plist 后，磁盘内容发生了变化。为避免覆盖 App 或系统刚写入的数据，请选择处理方式。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重新载入" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf reloadFromDiskDiscardingChanges]; if (completion) completion(NO);
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf saveCopy]; if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"仍然覆盖" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSError *forceError = nil;
            BOOL ok = [weakSelf.document saveForcingExternalOverwrite:YES error:&forceError];
            if (ok) [weakSelf flash:@"已覆盖保存"];
            else [weakSelf showMessage:forceError.localizedDescription ?: @"覆盖保存失败" title:@"保存失败"];
            if (completion) completion(ok);
        }]];
    (void)error;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)offerCopyForSaveError:(NSError *)error completion:(void (^ _Nullable)(BOOL))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法写入原文件"
        message:[NSString stringWithFormat:@"%@\n\n可以保存副本到 FuckFile 文档。",
            error.localizedDescription ?: @"当前位置不可写。"]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf saveCopy]; if (completion) completion(NO); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveCopy
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *folder = [documents stringByAppendingPathComponent:@"Edited Copies"];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) { [self showMessage:directoryError.localizedDescription title:@"副本保存失败"]; return; }

    NSString *name = self.document.filePath.lastPathComponent;
    NSString *stem = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *suffix = [formatter stringFromDate:NSDate.date];
    NSString *copyName = ext.length
        ? [NSString stringWithFormat:@"%@-edited-%@.%@", stem, suffix, ext]
        : [NSString stringWithFormat:@"%@-edited-%@", stem, suffix];
    NSString *copyPath = [folder stringByAppendingPathComponent:copyName];

    NSError *error = nil;
    if ([self.document saveCopyToPath:copyPath error:&error]) [self showMessage:copyPath title:@"副本已保存"];
    else [self showMessage:error.localizedDescription ?: @"副本写入失败" title:@"副本保存失败"];
}

- (FFPlistEditorViewController *)rootEditor
{
    for (UIViewController *controller in self.navigationController.viewControllers) {
        if ([controller isKindOfClass:FFPlistEditorViewController.class]) {
            FFPlistEditorViewController *editor = (FFPlistEditorViewController *)controller;
            if (editor.document == self.document && editor.keyPath.count == 0) return editor;
        }
    }
    return self;
}

- (void)reloadFromDiskDiscardingChanges
{
    FFPlistEditorViewController *root = [self rootEditor];
    if (self != root) [self.navigationController popToViewController:root animated:NO];
    NSError *error = nil;
    if (![self.document loadWithMaximumBytes:FFPlistEditorMaximumEditableBytes error:&error]) {
        [root showMessage:error.localizedDescription ?: @"重新载入失败" title:@"重新载入失败"];
        return;
    }
    [root refreshScopeAndUI];
    [root flash:@"已重新载入磁盘版本"];
}

#pragma mark - Back / unsaved

- (void)backTapped
{
    if (!self.document.isDirty) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未保存的修改"
        message:@"是否保存对此 plist 的修改？" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf attemptSaveWithCompletion:^(BOOL success) {
                if (success) [weakSelf.navigationController popViewControllerAnimated:YES];
            }];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf.navigationController popViewControllerAnimated:YES]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (self.ownsDocument && gestureRecognizer == self.navigationController.interactivePopGestureRecognizer && self.document.isDirty) {
        [self backTapped];
        return NO;
    }
    return YES;
}

#pragma mark - Feedback

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

@end
