#import "FFPlistEditorViewController.h"
#import "FFLogger.h"

// 深度可变复制：嵌套字典/数组全部转为可变版本。
// 浅层 mutableCopy 会让深层结构保持不可变，编辑时赋值会崩溃。
static id FFDeepMutableCopy(id object)
{
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (id key in object) dict[key] = FFDeepMutableCopy(object[key]);
        return dict;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id item in object) [array addObject:FFDeepMutableCopy(item)];
        return array;
    }
    return object;
}

@interface FFPlistEditorViewController ()
@property(nonatomic, strong) id root;
@property(nonatomic, copy) NSArray *keyPath;
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic) BOOL binary;
@property(nonatomic, strong) id scope;
@property(nonatomic, strong) NSArray<NSString *> *keys;
@end

@implementation FFPlistEditorViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _filePath = path;
        _keyPath = @[];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (instancetype)initWithRoot:(id)root keyPath:(NSArray *)keyPath
                    filePath:(NSString *)filePath binary:(BOOL)binary
                       title:(NSString *)title
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _root = root;
        _keyPath = keyPath;
        _filePath = filePath;
        _binary = binary;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
            target:self action:@selector(save)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
            target:self action:@selector(addEntry)],
    ];

    if (self.root) {
        [self reloadScope];
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *data = [NSData dataWithContentsOfFile:weakSelf.filePath];
            id plist = nil;
            if (data.length > 0 && data.bytes && ((const uint8_t *)data.bytes)[0] == 'b') {
                weakSelf.binary = YES;
            }
            NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
            plist = [NSPropertyListSerialization propertyListWithData:data
                options:NSPropertyListImmutable format:&format error:nil];
            if (![plist isKindOfClass:NSDictionary.class] &&
                ![plist isKindOfClass:NSArray.class]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf flash:@"不是有效的 plist（根不是字典/数组）"];
                });
                return;
            }
            weakSelf.root = FFDeepMutableCopy(plist);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadScope]; });
        });
    }
}

- (void)reloadScope
{
    self.scope = self.root;
    for (id component in self.keyPath) {
        if ([component isKindOfClass:NSNumber.class] && [self.scope isKindOfClass:NSArray.class]) {
            NSUInteger index = [component unsignedIntegerValue];
            self.scope = index < [self.scope count] ? self.scope[index] : nil;
        } else if ([component isKindOfClass:NSString.class] && [self.scope isKindOfClass:NSDictionary.class]) {
            self.scope = self.scope[component];
        } else {
            self.scope = nil;
        }
        if (!self.scope) break;
    }
    if ([self.scope isKindOfClass:NSDictionary.class]) {
        self.keys = [[self.scope allKeys] sortedArrayUsingSelector:@selector(compare:)];
    } else if ([self.scope isKindOfClass:NSArray.class]) {
        NSMutableArray *indexes = [NSMutableArray arrayWithCapacity:[self.scope count]];
        for (NSUInteger index = 0; index < [self.scope count]; index++)
            [indexes addObject:[NSString stringWithFormat:@"[%lu]", (unsigned long)index]];
        self.keys = indexes;
    } else {
        self.keys = @[];
    }
    [self.tableView reloadData];
}

#pragma mark - Description

static NSString *FFPlistTypeName(id value)
{
    if ([value isKindOfClass:NSDictionary.class]) return @"字典";
    if ([value isKindOfClass:NSArray.class]) return @"数组";
    if ([value isKindOfClass:NSString.class]) return @"字符串";
    if ([value isKindOfClass:NSData.class]) return @"数据";
    if ([value isKindOfClass:NSDate.class]) return @"日期";
    if ([value isKindOfClass:NSNumber.class]) {
        if (strcmp([value objCType], @encode(BOOL)) == 0 || strcmp([value objCType], "c") == 0)
            return @"布尔";
        return @"数字";
    }
    return @"未知";
}

static NSString *FFPlistValueSummary(id value)
{
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"{%lu 项}", (unsigned long)[value count]];
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"[%lu 项]", (unsigned long)[value count]];
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSData.class])
        return [NSString stringWithFormat:@"%lu 字节", (unsigned long)[value length]];
    if ([value isKindOfClass:NSDate.class]) return [value description];
    if ([value isKindOfClass:NSNumber.class])
        return [value description];
    return [value description];
}

#pragma mark - Mutation helpers

- (id)objectAtKeyPath:(NSArray *)keyPath
{
    id current = self.root;
    for (id component in keyPath) {
        if ([component isKindOfClass:NSNumber.class] && [current isKindOfClass:NSArray.class]) {
            NSUInteger index = [component unsignedIntegerValue];
            current = index < [current count] ? current[index] : nil;
        } else if ([component isKindOfClass:NSString.class] && [current isKindOfClass:NSDictionary.class]) {
            current = current[component];
        } else {
            current = nil;
        }
        if (!current) return nil;
    }
    return current;
}

- (void)setObject:(id)object atKeyPath:(NSArray *)keyPath
{
    if (keyPath.count == 0) {
        self.root = object;
        return;
    }
    NSArray *parentPath = [keyPath subarrayWithRange:NSMakeRange(0, keyPath.count - 1)];
    id parent = [self objectAtKeyPath:parentPath];
    id last = keyPath.lastObject;
    if ([parent isKindOfClass:NSMutableArray.class] && [last isKindOfClass:NSNumber.class])
        [parent replaceObjectAtIndex:[last unsignedIntegerValue] withObject:object];
    else if ([parent isKindOfClass:NSMutableDictionary.class] && [last isKindOfClass:NSString.class])
        [parent setObject:object forKey:last];
}

- (void)removeLastKeyPathComponent
{
    if (self.keyPath.count == 0) return;
    NSArray *parentPath = [self.keyPath subarrayWithRange:NSMakeRange(0, self.keyPath.count - 1)];
    id parent = [self objectAtKeyPath:parentPath];
    id last = self.keyPath.lastObject;
    if ([parent isKindOfClass:NSMutableArray.class] && [last isKindOfClass:NSNumber.class])
        [parent removeObjectAtIndex:[last unsignedIntegerValue]];
    else if ([parent isKindOfClass:NSMutableDictionary.class] && [last isKindOfClass:NSString.class])
        [parent removeObjectForKey:last];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.keys.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    NSString *key = self.keys[indexPath.row];
    id value = nil;
    if ([self.scope isKindOfClass:NSDictionary.class]) value = self.scope[key];
    else if ([self.scope isKindOfClass:NSArray.class])
        value = self.scope[[[key substringWithRange:NSMakeRange(1, key.length - 2)] integerValue]];

    BOOL container = [value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class];
    cell.textLabel.text = key;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@",
        FFPlistTypeName(value), FFPlistValueSummary(value)];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = container ? UITableViewCellAccessoryDisclosureIndicator
                                   : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = self.keys[indexPath.row];
    id component = nil;
    id value = nil;
    if ([self.scope isKindOfClass:NSDictionary.class]) {
        component = key;
        value = self.scope[key];
    } else if ([self.scope isKindOfClass:NSArray.class]) {
        NSInteger index = [[key substringWithRange:NSMakeRange(1, key.length - 2)] integerValue];
        component = @(index);
        value = self.scope[index];
    }
    if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
        FFPlistEditorViewController *next = [[FFPlistEditorViewController alloc]
            initWithRoot:self.root keyPath:[self.keyPath arrayByAddingObject:component]
            filePath:self.filePath binary:self.binary title:key];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    [self editValue:value atKey:key component:component];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSString *key = self.keys[indexPath.row];
    id component = nil;
    if ([self.scope isKindOfClass:NSDictionary.class]) {
        component = key;
        [self.scope removeObjectForKey:key];
    } else if ([self.scope isKindOfClass:NSArray.class]) {
        NSInteger index = [[key substringWithRange:NSMakeRange(1, key.length - 2)] integerValue];
        component = @(index);
        [self.scope removeObjectAtIndex:(NSUInteger)index];
    }
    [self reloadScope];
    FFLogTag(@"PlistEditor", @"deleted %@ at %@", component, self.keyPath);
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(__unused NSIndexPath *)indexPath
{
    // Scope refreshes after each commit; nothing to do here.
}

#pragma mark - Editing values

- (void)editValue:(id)value atKey:(NSString *)key component:(id)component
{
    if ([value isKindOfClass:NSNumber.class] &&
        (strcmp([value objCType], @encode(BOOL)) == 0 || strcmp([value objCType], "c") == 0)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:key
            message:[NSString stringWithFormat:@"当前：%@", [value boolValue] ? @"YES" : @"NO"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"YES" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [self setValue:@YES atKeyPathComponent:component]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"NO" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [self setValue:@NO atKeyPathComponent:component]; }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *current = [value isKindOfClass:NSDate.class]
        ? [value description] : FFPlistValueSummary(value);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:key
        message:[NSString stringWithFormat:@"类型：%@", FFPlistTypeName(value)]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.font = [UIFont fontWithName:@"Menlo" size:13];
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *text = alert.textFields.firstObject.text ?: @"";
            id newValue = [weakSelf parsedValue:text forOriginal:value];
            [weakSelf setValue:newValue atKeyPathComponent:component];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)parsedValue:(NSString *)text forOriginal:(id)original
{
    if ([original isKindOfClass:NSString.class]) return text;
    if ([original isKindOfClass:NSNumber.class]) {
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        NSNumber *number = [formatter numberFromString:text];
        if (number) return number;
        if ([text.lowercaseString isEqualToString:@"yes"]) return @YES;
        if ([text.lowercaseString isEqualToString:@"no"]) return @NO;
        return @0;
    }
    if ([original isKindOfClass:NSData.class]) {
        NSString *clean = [text stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
        for (NSUInteger index = 0; index + 1 < clean.length; index += 2) {
            unsigned int byte = 0;
            NSScanner *scanner = [NSScanner scannerWithString:
                [clean substringWithRange:NSMakeRange(index, 2)]];
            [scanner scanHexInt:&byte];
            uint8_t value = (uint8_t)byte;
            [data appendBytes:&value length:1];
        }
        return data;
    }
    return text;
}

- (void)setValue:(id)value atKeyPathComponent:(id)component
{
    if ([self.scope isKindOfClass:NSDictionary.class])
        self.scope[component] = value;
    else if ([self.scope isKindOfClass:NSArray.class])
        [self.scope replaceObjectAtIndex:[component unsignedIntegerValue] withObject:value];
    FFLogTag(@"PlistEditor", @"edited %@ at %@ -> %@", component, self.keyPath,
        FFPlistValueSummary(value));
    [self reloadScope];
}

#pragma mark - Add

- (void)addEntry
{
    if ([self.scope isKindOfClass:NSDictionary.class]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加键值"
            message:@"新字符串条目" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"键名";
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"字符串值";
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                NSString *key = alert.textFields[0].text ?: @"";
                if (key.length == 0) return;
                weakSelf.scope[key] = alert.textFields[1].text ?: @"";
                [weakSelf reloadScope];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if ([self.scope isKindOfClass:NSArray.class]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加元素"
            message:@"新字符串元素" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"字符串值";
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                [weakSelf.scope addObject:alert.textFields.firstObject.text ?: @""];
                [weakSelf reloadScope];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self flash:@"当前作用域不是容器"];
    }
}

#pragma mark - Save

- (void)save
{
    NSPropertyListFormat format = self.binary
        ? NSPropertyListBinaryFormat_v1_0 : NSPropertyListXMLFormat_v1_0;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.root
        format:format options:0 error:&error];
    if (!data) {
        [self flash:[NSString stringWithFormat:@"序列化失败：%@", error.localizedDescription]];
        return;
    }
    if ([data writeToFile:self.filePath options:NSDataWritingAtomic error:&error]) {
        [self flash:@"已保存"];
        FFLogTag(@"PlistEditor", @"saved %@ (%lu bytes)", self.filePath,
            (unsigned long)data.length);
        return;
    }
    FFLogTag(@"PlistEditor", @"save FAIL path=%@ error=%@", self.filePath, error);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法写入"
        message:@"该位置不可写（沙盒只读扩展）。\n保存副本到 FuckFile 文档？"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *documents = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *folder = [documents stringByAppendingPathComponent:@"Edited Copies"];
            [[NSFileManager defaultManager] createDirectoryAtPath:folder
                withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *copyPath = [folder stringByAppendingPathComponent:
                weakSelf.filePath.lastPathComponent];
            if ([data writeToFile:copyPath options:NSDataWritingAtomic error:nil])
                [weakSelf flash:[NSString stringWithFormat:@"已保存副本：\n%@", copyPath]];
            else
                [weakSelf flash:@"副本保存失败"];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentOnTop:alert];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
}

// UIKit silently drops presentViewController when an alert is already
// up, which made button taps look dead right after a flash. Dismiss whatever
// is on top first.
- (void)presentOnTop:(UIViewController *)controller
{
    if (self.presentedViewController) {
        UIViewController *presented = self.presentedViewController;
        [presented dismissViewControllerAnimated:NO completion:^{
            [self presentViewController:controller animated:YES completion:nil];
        }];
    } else {
        [self presentViewController:controller animated:YES completion:nil];
    }
}

@end
