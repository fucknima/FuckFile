#import "FFGestaltEditorViewController.h"
#import "FFBrowserViewController.h"
#import "MCMManager.h"
#import "FFLogger.h"

#import <errno.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>

@interface FFFeature : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *info;
@property(nonatomic, strong) NSArray<NSString *> *keys;
@property(nonatomic, strong) NSArray *onValues; // parallel to keys
@property(nonatomic) BOOL destructive;
@end

@implementation FFFeature
+ (instancetype)featureWithTitle:(NSString *)title info:(NSString *)info
                            keys:(NSArray<NSString *> *)keys
                        onValues:(NSArray *)onValues
                     destructive:(BOOL)destructive
{
    FFFeature *feature = [FFFeature new];
    feature.title = title;
    feature.info = info;
    feature.keys = keys;
    feature.onValues = onValues;
    feature.destructive = destructive;
    return feature;
}
@end

@interface FFGestaltEditorViewController ()
@property(nonatomic, copy) NSString *gestaltPath;
@property(nonatomic, copy) NSString *gestaltDirectory;
@property(nonatomic, copy) NSString *backupPath;
@property(nonatomic, strong) NSMutableDictionary *dictionary;
@property(nonatomic, copy) NSString *errorText;
@property(nonatomic, strong) NSArray<FFFeature *> *features;
@property(nonatomic) NSInteger subtype;
@property(nonatomic) NSInteger originalSubtype;
@property(nonatomic, copy) NSString *deviceName;
@property(nonatomic) BOOL enableDeviceName;
@property(nonatomic, copy) NSString *productType;
@property(nonatomic, copy) NSString *originalProductType;
@end

@implementation FFGestaltEditorViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"MobileGestalt 编辑器";
        _features = [self buildFeatures];
    }
    return self;
}

- (NSArray<FFFeature *> *)buildFeatures
{
    NSMutableArray<FFFeature *> *features = [NSMutableArray array];
    NSArray<NSDictionary *> *definitions = @[
        @{@"Title": @"灵动岛", @"Keys": @[@"YlEtTtHlNesRBMal1CqRaA"]},
        @{@"Title": @"全天候显示", @"Keys": @[@"j8/Omm6s1lsmTDFsXjsBfA", @"2OOJf1VhaM7NxfRok3HbWQ"]},
        @{@"Title": @"息屏显示振动效果", @"Keys": @[@"ykpu7qyhqFweVMKtxNylWA"]},
        @{@"Title": @"充电上限", @"Keys": @[@"37NVydb//GP/GrhuTN+exg"]},
        @{@"Title": @"开机提示音", @"Keys": @[@"QHxt+hGLaBPbQJbXiUJX3w"]},
        @{@"Title": @"Liquid Glass 低电量模式", @"Keys": @[@"SAGvsp6O6kAQ4fEfDJpC4Q"]},
        @{@"Title": @"相机控制", @"Keys": @[@"CwvKxM2cEogD3p+HYgaW0Q", @"oOV1jhJbdV3AddkcCg0AEA"]},
        @{@"Title": @"操作按钮", @"Keys": @[@"cT44WE1EohiwRzhsZ8xEsw"]},
        @{@"Title": @"车祸检测", @"Keys": @[@"HCzWusHQwZDea6nNhaKndw"]},
        @{@"Title": @"轻点唤醒", @"Keys": @[@"yZf3GTRMGTuwSV/lD7Cagw"]},
        @{@"Title": @"PWM 调光", @"Keys": @[@"6IejgN+1Fmu5/QrZFOIeNw"]},
        @{@"Title": @"安全研究设备 UI", @"Keys": @[@"XYlJKKkj2hztRP1NWWnhlw"]},
        @{@"Title": @"关闭区域限制", @"Keys": @[@"h63QSdBCiT/z0WU6rdQv6Q", @"zHeENZu+wbg7PUprwNwBWg"],
          @"OnValues": @[@"US", @"LL/A"], @"Info": @"将区域代码设为 US / LL/A。"},
        @{@"Title": @"Apple Intelligence", @"Keys": @[@"A62OafQ85EJAiiqKn4agtg"]},
        @{@"Title": @"允许安装 iPadOS 应用", @"Keys": @[@"9MZ5AdH43csAUajl/dU+IQ"],
          @"OnValues": @[@[@1, @2]]},
        @{@"Title": @"Apple Pencil 设置", @"Keys": @[@"yhHcB0iH0d1XzPO/CFd3ow"]},
        @{@"Title": @"台前调度", @"Keys": @[@"qeaj75wk3HF4DwQ8qbIi7g"]},
        @{@"Title": @"内部存储", @"Keys": @[@"LBJfwOEzExRxzlAnSuI7eg"]},
        @{@"Title": @"全局 Metal HUD", @"Keys": @[@"EqrsVvjcYDdxHBiQmGhAWw"]},
    ];
    for (NSDictionary *definition in definitions) {
        NSArray *onValues = definition[@"OnValues"] ?: @[];
        if (onValues.count == 0) {
            NSMutableArray *defaultOnValues = [NSMutableArray array];
            for (NSUInteger i = 0; i < [definition[@"Keys"] count]; i++)
                [defaultOnValues addObject:@1];
            onValues = defaultOnValues;
        }
        [features addObject:[FFFeature featureWithTitle:definition[@"Title"]
            info:definition[@"Info"] ?: @"" keys:definition[@"Keys"]
            onValues:onValues destructive:NO]];
    }
    return features;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self loadState];
}

- (void)loadState
{
    NSString *error = nil;
    NSString *path = [[MCMManager sharedManager] mobileGestaltPath:&error];
    if (!path) {
        self.errorText = error ?: @"MobileGestalt.plist is not reachable";
        FFLogTag(@"Gestalt", @"loadState FAIL path=(nil) error=%@", self.errorText);
        [self.tableView reloadData];
        return;
    }
    FFLogTag(@"Gestalt", @"loadState path=%@", path);
    self.gestaltPath = path;
    self.gestaltDirectory = path.stringByDeletingLastPathComponent;

    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![raw isKindOfClass:NSDictionary.class]) {
        self.errorText = @"MobileGestalt.plist is empty or invalid";
        FFLogTag(@"Gestalt", @"loadState FAIL plist invalid path=%@", path);
        [self.tableView reloadData];
        return;
    }
    FFLogTag(@"Gestalt", @"loadState plist OK entries=%lu path=%@",
        (unsigned long)raw.count, path);
    self.dictionary = [raw mutableCopy];
    self.errorText = nil;

    // Keep an immutable first-run backup exactly like mond does.
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *backupDirectory = [documents stringByAppendingPathComponent:@"MobileGestalt Backup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:backupDirectory
        withIntermediateDirectories:YES attributes:nil error:nil];
    self.backupPath = [backupDirectory stringByAppendingPathComponent:@"SavedGestalt.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.backupPath]) {
        BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:path
            toPath:self.backupPath error:nil];
        FFLogTag(@"Gestalt", @"backup copy path=%@ result=%d", self.backupPath, copied);
    } else {
        FFLogTag(@"Gestalt", @"backup exists path=%@", self.backupPath);
    }

    NSMutableDictionary *cacheExtra = [self cacheExtra];
    NSMutableDictionary *artwork = [cacheExtra[@"oPeik/9e8lQWMszEjbPzng"]
        isKindOfClass:NSMutableDictionary.class] ? cacheExtra[@"oPeik/9e8lQWMszEjbPzng"] : nil;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:self.backupPath];
    NSDictionary *savedCacheExtra = [saved[@"CacheExtra"] isKindOfClass:NSDictionary.class]
        ? saved[@"CacheExtra"] : nil;
    NSDictionary *savedArtwork = [savedCacheExtra[@"oPeik/9e8lQWMszEjbPzng"]
        isKindOfClass:NSDictionary.class] ? savedCacheExtra[@"oPeik/9e8lQWMszEjbPzng"] : nil;
    self.originalSubtype = [savedArtwork[@"ArtworkDeviceSubType"] integerValue] ?: 0;
    self.subtype = artwork ? [artwork[@"ArtworkDeviceSubType"] integerValue] : self.originalSubtype;
    NSString *savedName = [savedArtwork[@"ArtworkDeviceProductDescription"]
        isKindOfClass:NSString.class] ? savedArtwork[@"ArtworkDeviceProductDescription"] : @"";
    NSString *currentName = artwork && [artwork[@"ArtworkDeviceProductDescription"]
        isKindOfClass:NSString.class] ? artwork[@"ArtworkDeviceProductDescription"] : savedName;
    self.deviceName = currentName;
    self.enableDeviceName = ![currentName isEqualToString:savedName];
    NSString *savedProduct = [savedCacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"]
        isKindOfClass:NSString.class] ? savedCacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] : @"";
    self.originalProductType = savedProduct;
    self.productType = [cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] isKindOfClass:NSString.class]
        ? cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] : savedProduct;
    [self.tableView reloadData];
}

- (NSMutableDictionary *)cacheExtra
{
    if (![self.dictionary[@"CacheExtra"] isKindOfClass:NSMutableDictionary.class])
        self.dictionary[@"CacheExtra"] = [NSMutableDictionary dictionary];
    return self.dictionary[@"CacheExtra"];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if (self.errorText) return 2; // warning + actions/help
    return 7;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.errorText) return section == 0 ? 1 : 2;
    switch (section) {
        case 0: return 1; // warning
        case 1: return 3; // apply / revert / open location
        case 2: return self.enableDeviceName ? 3 : 2; // subtype + name toggle (+ field)
        case 3: return 6; // software
        case 4: return 5; // hardware
        case 5: return 7; // eligibility + device model
        case 6: return 2; // internal
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.errorText) return section == 0 ? @"MobileGestalt" : @"操作";
    switch (section) {
        case 0: return @"警告";
        case 1: return @"操作";
        case 2: return @"设备外观";
        case 3: return @"软件功能";
        case 4: return @"硬件功能";
        case 5: return @"资格";
        case 6: return @"内部";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.errorText) return section == 0 ? @"在 MobileGestalt.plist 为空或损坏时重启可能导致无法开机。" : nil;
    if (section == 0)
        return @"修改可能破坏功能或导致设备软砖。请保留备份，发现异常时先还原再重启。";
    if (section == 1)
        return @"首次启动时已备份原始 plist。“还原修改”会恢复该备份。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.errorText) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Error"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:@"Error"];
        if (indexPath.section == 0) {
            cell.textLabel.text = @"MobileGestalt 不可用";
            cell.detailTextLabel.text = self.errorText;
            cell.detailTextLabel.numberOfLines = 0;
            cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
            cell.imageView.tintColor = [UIColor systemYellowColor];
        } else {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"重试";
            } else {
                cell.textLabel.text = @"查看日志";
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                       reuseIdentifier:@"Warn"];
        cell.textLabel.text = @"请勿在 plist 为空或损坏时重启";
        cell.detailTextLabel.text = self.gestaltPath;
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        cell.imageView.tintColor = [UIColor systemYellowColor];
        return cell;
    }
    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Action"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"Action"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"应用修改";
            cell.textLabel.textColor = [UIColor systemBlueColor];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"还原修改";
            cell.textLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.textLabel.text = @"打开 plist 所在目录";
            cell.textLabel.textColor = [UIColor labelColor];
        }
        return cell;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Subtype"];
            if (!cell)
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                              reuseIdentifier:@"Subtype"];
            cell.textLabel.text = @"型号子类型";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)self.subtype];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row == 1) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NameToggle"];
            if (!cell)
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:@"NameToggle"];
            cell.textLabel.text = @"自定义设备名";
            UISwitch *toggle = [UISwitch new];
            toggle.on = self.enableDeviceName;
            [toggle addTarget:self action:@selector(nameToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            return cell;
        }
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NameField"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"NameField"];
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 40)];
        field.text = self.deviceName;
        field.placeholder = @"设备名称";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        [field addTarget:self action:@selector(nameFieldChanged:) forControlEvents:UIControlEventEditingChanged];
        cell.accessoryView = field;
        return cell;
    }
    if (indexPath.section == 5 && indexPath.row == 6) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ProductType"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:@"ProductType"];
        cell.textLabel.text = @"设备型号";
        cell.detailTextLabel.text = self.productType.length ? self.productType : @"默认";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    NSArray<FFFeature *> *features = [self featuresForSection:indexPath.section];
    FFFeature *feature = features[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Feature"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Feature"];
    cell.textLabel.text = feature.title;
    cell.detailTextLabel.text = feature.info.length ? feature.info : nil;
    cell.detailTextLabel.numberOfLines = 0;
    UISwitch *toggle = [UISwitch new];
    toggle.on = [self isFeatureOn:feature];
    toggle.tag = [self flatFeatureIndex:feature];
    [toggle addTarget:self action:@selector(featureToggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.errorText) {
        if (indexPath.section == 1 && indexPath.row == 0) [self loadState];
        else if (indexPath.section == 1 && indexPath.row == 1) [self presentLog];
        return;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self applyTweaks];
        else if (indexPath.row == 1) [self confirmRevert];
        else [self openPlistLocation];
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 0) [self chooseSubtype];
    if (indexPath.section == 5 && indexPath.row == 6) [self chooseProductType];
}

- (NSArray<FFFeature *> *)featuresForSection:(NSInteger)section
{
    NSRange range;
    switch (section) {
        case 3: range = NSMakeRange(0, 6); break;
        case 4: range = NSMakeRange(6, 5); break;
        case 5: range = NSMakeRange(11, 6); break;
        case 6: range = NSMakeRange(17, 2); break;
        default: return @[];
    }
    if (NSMaxRange(range) > self.features.count) return @[];
    return [self.features subarrayWithRange:range];
}

- (NSInteger)flatFeatureIndex:(FFFeature *)feature
{
    return [self.features indexOfObject:feature];
}

#pragma mark - Feature toggles

- (BOOL)isFeatureOn:(FFFeature *)feature
{
    NSMutableDictionary *cacheExtra = [self cacheExtra];
    for (NSUInteger i = 0; i < feature.keys.count; i++) {
        id value = cacheExtra[feature.keys[i]];
        if (!value) continue;
        id expected = feature.onValues.count > i ? feature.onValues[i] : @1;
        if ([value isEqual:expected]) return YES;
    }
    return NO;
}

- (void)setFeature:(FFFeature *)feature on:(BOOL)on
{
    NSMutableDictionary *cacheExtra = [self cacheExtra];
    for (NSUInteger i = 0; i < feature.keys.count; i++) {
        if (on) {
            cacheExtra[feature.keys[i]] = feature.onValues.count > i
                ? feature.onValues[i] : @1;
        } else {
            [cacheExtra removeObjectForKey:feature.keys[i]];
        }
    }
}

- (void)featureToggleChanged:(UISwitch *)sender
{
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.features.count) return;
    FFFeature *feature = self.features[index];
    [self setFeature:feature on:sender.on];
    if ([feature.title isEqualToString:@"关闭区域限制"] && sender.on)
        [self flash:@"区域代码已设为 US / LL/A。请勿用于违反当地法律的操作。"];
}

- (void)nameToggleChanged:(UISwitch *)sender
{
    self.enableDeviceName = sender.on;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)nameFieldChanged:(UITextField *)sender
{
    self.deviceName = sender.text;
}

#pragma mark - Actions

- (void)applyTweaks
{
    NSMutableDictionary *cacheExtra = [self cacheExtra];
    NSMutableDictionary *artwork = [cacheExtra[@"oPeik/9e8lQWMszEjbPzng"]
        isKindOfClass:NSMutableDictionary.class] ? cacheExtra[@"oPeik/9e8lQWMszEjbPzng"]
        : [NSMutableDictionary dictionary];
    artwork[@"ArtworkDeviceSubType"] = @(self.subtype);
    if (self.enableDeviceName && self.deviceName.length)
        artwork[@"ArtworkDeviceProductDescription"] = self.deviceName;
    cacheExtra[@"oPeik/9e8lQWMszEjbPzng"] = artwork;
    if (self.productType.length)
        cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] = self.productType;

    NSError *error = nil;
    if (![self writeDictionary:self.dictionary error:&error]) {
        [self showError:error];
        return;
    }
    [self flash:@"已写入 MobileGestalt，重启后生效。"];
}

- (void)confirmRevert
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"还原 MobileGestalt？"
        message:@"恢复首次启动时保存的原始备份。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf revertTweaks];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)revertTweaks
{
    if (!self.backupPath || ![[NSFileManager defaultManager] fileExistsAtPath:self.backupPath]) {
        [self flash:@"未找到备份"];
        return;
    }
    NSDictionary *backup = [NSDictionary dictionaryWithContentsOfFile:self.backupPath];
    if (![backup isKindOfClass:NSDictionary.class]) {
        [self flash:@"备份无效"];
        return;
    }
    NSError *error = nil;
    if (![self writeDictionary:[backup mutableCopy] error:&error]) {
        [self showError:error];
        return;
    }
    [self flash:@"已还原 MobileGestalt，重启后生效。"];
    [self loadState];
}

- (BOOL)writeDictionary:(NSMutableDictionary *)dictionary error:(NSError **)error
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
        format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSString *directory = self.gestaltPath.stringByDeletingLastPathComponent;
    NSString *temp = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".MobileGestalt.%@.tmp", NSUUID.UUID.UUIDString]];
    if (![data writeToFile:temp options:NSDataWritingAtomic error:error]) return NO;
    NSURL *result = nil;
    BOOL replaced = [[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:self.gestaltPath]
        withItemAtURL:[NSURL fileURLWithPath:temp] backupItemName:nil options:0
        resultingItemURL:&result error:error];
    if (!replaced) {
        if (rename(temp.fileSystemRepresentation, self.gestaltPath.fileSystemRepresentation) != 0) {
            if (error && !*error)
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"rename failed: %s",
                        strerror(errno)]}];
            [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];
            return NO;
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];
    return YES;
}

- (void)openPlistLocation
{
    if (!self.gestaltDirectory) return;
    FFBrowserViewController *browser = [[FFBrowserViewController alloc]
        initWithPath:self.gestaltDirectory];
    [self.navigationController pushViewController:browser animated:YES];
}

- (void)presentLog
{
    NSString *logPath = FFLogPath();
    NSString *text = [NSString stringWithContentsOfFile:logPath
        encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) text = @"日志为空，请先运行探针。";
    UIViewController *viewer = [UIViewController new];
    viewer.title = @"FuckFile 日志";
    UITextView *textView = [[UITextView alloc] initWithFrame:viewer.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [UIFont fontWithName:@"Menlo" size:11];
    textView.text = text;
    [viewer.view addSubview:textView];
    [self.navigationController pushViewController:viewer animated:YES];
}

- (void)chooseSubtype
{
    NSArray<NSDictionary *> *presets = @[
        @{@"Name": [NSString stringWithFormat:@"原始值（%ld）", (long)self.originalSubtype],
          @"Value": @(self.originalSubtype)},
        @{@"Name": @"关闭灵动岛", @"Value": @2436},
        @{@"Name": @"iPhone 14 Pro", @"Value": @2436},
        @{@"Name": @"iPhone 14 Pro Max", @"Value": @2796},
        @{@"Name": @"iPhone 15 Pro Max", @"Value": @2976},
        @{@"Name": @"iPhone 16 Pro", @"Value": @2622},
        @{@"Name": @"iPhone 16 Pro Max", @"Value": @2868},
        @{@"Name": @"iPhone Air", @"Value": @2736},
    ];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"型号子类型"
        message:@"设备外观子类型（修改可能导致部分机型灵动岛失效）。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *preset in presets) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:preset[@"Name"]
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                weakSelf.subtype = [preset[@"Value"] integerValue];
                [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                                  withRowAnimation:UITableViewRowAnimationNone];
            }];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseProductType
{
    NSMutableArray<NSDictionary *> *options = [NSMutableArray array];
    if (self.originalProductType.length)
        [options addObject:@{@"Name": [NSString stringWithFormat:@"默认（%@）", self.originalProductType],
            @"Value": self.originalProductType}];
    [options addObjectsFromArray:@[
        @{@"Name": @"iPhone 15 Pro", @"Value": @"iPhone16,1"},
        @{@"Name": @"iPhone 15 Pro Max", @"Value": @"iPhone16,2"},
        @{@"Name": @"iPhone 16", @"Value": @"iPhone17,3"},
        @{@"Name": @"iPhone 16 Plus", @"Value": @"iPhone17,4"},
        @{@"Name": @"iPhone 16 Pro", @"Value": @"iPhone17,1"},
        @{@"Name": @"iPhone 16 Pro Max", @"Value": @"iPhone17,2"},
        @{@"Name": @"iPhone 17", @"Value": @"iPhone18,3"},
        @{@"Name": @"iPhone 17 Pro", @"Value": @"iPhone18,1"},
        @{@"Name": @"iPhone 17 Pro Max", @"Value": @"iPhone18,2"},
        @{@"Name": @"iPhone Air", @"Value": @"iPhone18,4"},
    ]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"伪装设备型号"
        message:@"仅在你需要 Apple Intelligence 资格时使用。可能导致面容 ID 失效。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *option in options) {
        [alert addAction:[UIAlertAction actionWithTitle:option[@"Name"]
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                weakSelf.productType = option[@"Value"];
                [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:5]
                                  withRowAnimation:UITableViewRowAnimationNone];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.view;
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Helpers

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

- (void)showError:(NSError *)error
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MobileGestalt 操作失败"
        message:error.localizedDescription ?: @"未知错误"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
