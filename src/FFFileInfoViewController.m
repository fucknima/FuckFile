#import "FFFileInfoViewController.h"
#import "FFFileMetadataService.h"
#import "FFIPAMetadataService.h"
#import "FFThumbnailService.h"

#import <objc/runtime.h>

@interface FFInfoShareTarget : NSObject
@property(nonatomic, copy) NSURL *fileURL;
@property(nonatomic, weak) UINavigationController *nav;
- (void)share:(UIBarButtonItem *)sender;
@end

@implementation FFInfoShareTarget
- (void)share:(UIBarButtonItem *)sender
{
    if (!self.fileURL) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.fileURL] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    UIViewController *presenter = self.nav.topViewController;
    if (presenter) [presenter presentViewController:activity animated:YES completion:nil];
}
@end

@interface FFFileInfoViewController ()
@property(nonatomic, strong) FFEntry *entry;
@property(nonatomic, strong) UIImage *icon;
@property(nonatomic, strong) UIImageView *headerIconView;
@property(nonatomic, copy) NSString *dirSizeText;
@property(nonatomic, copy) NSString *itemCountText;
@property(nonatomic, copy) NSString *xattrText;
@property(nonatomic, copy) NSString *sha256Text;
@property(nonatomic, strong) FFIPAMetadata *ipaMetadata;
@property(nonatomic, copy) NSString *ipaError;
@end

@implementation FFFileInfoViewController

- (instancetype)initWithEntry:(FFEntry *)entry icon:(UIImage *)icon
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _entry = entry;
        _icon = icon;
        self.title = @"文件信息";
    }
    return self;
}

- (BOOL)isIPA
{
    return !self.entry.isDirectory &&
        [self.entry.name.pathExtension.lowercaseString isEqualToString:@"ipa"];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    [self setupHeader];
    [self loadSlowMetadata];
    [self loadRichPreviewIfNeeded];

    FFInfoShareTarget *target = [FFInfoShareTarget new];
    target.fileURL = [NSURL fileURLWithPath:self.entry.path];
    target.nav = self.navigationController;
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:target action:@selector(share:)];
    objc_setAssociatedObject(share, "ffInfoShareTarget", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.navigationItem.rightBarButtonItem = share;
}

- (void)setupHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 136)];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:self.icon];
    iconView.tintColor = UIColor.systemBlueColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.isAccessibilityElement = NO;
    if ([self isIPA]) {
        iconView.layer.cornerRadius = 11;
        iconView.layer.masksToBounds = YES;
    }
    self.headerIconView = iconView;
    [header addSubview:iconView];

    UILabel *nameLabel = [UILabel new];
    nameLabel.text = self.entry.displayName.length ? self.entry.displayName : self.entry.name;
    nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    nameLabel.adjustsFontForContentSizeCategory = YES;
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.numberOfLines = 2;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:nameLabel];

    UILabel *kindLabel = [UILabel new];
    kindLabel.text = [self kindName];
    kindLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    kindLabel.adjustsFontForContentSizeCategory = YES;
    kindLabel.textColor = UIColor.secondaryLabelColor;
    kindLabel.textAlignment = NSTextAlignmentCenter;
    kindLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:kindLabel];

    UILayoutGuide *guide = header.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [iconView.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [iconView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [iconView.heightAnchor constraintEqualToConstant:56],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [nameLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:6],
        [nameLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [nameLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [kindLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [kindLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [kindLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4],
    ]];
    self.tableView.tableHeaderView = header;
}

- (void)loadRichPreviewIfNeeded
{
    if ([self isIPA]) {
        __weak typeof(self) weakSelf = self;
        [[FFIPAMetadataService sharedService] metadataForIPAAtPath:self.entry.path
            completion:^(FFIPAMetadata *metadata, NSError *error) {
                typeof(weakSelf) self = weakSelf;
                if (!self) return;
                self.ipaMetadata = metadata;
                self.ipaError = metadata ? nil : (error.localizedDescription ?: @"无法解析 IPA");
                if (metadata.icon) {
                    self.icon = metadata.icon;
                    self.headerIconView.image = metadata.icon;
                    self.headerIconView.tintColor = nil;
                }
                [self.tableView reloadData];
            }];
        return;
    }

    if (!self.icon && !self.entry.isDirectory) {
        __weak typeof(self) weakSelf = self;
        [[FFThumbnailService sharedService] thumbnailForPath:self.entry.path size:CGSizeMake(64, 64)
            completion:^(UIImage *image) {
                if (!image) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(weakSelf) self = weakSelf;
                    if (!self) return;
                    self.icon = image;
                    self.headerIconView.image = image;
                    self.headerIconView.tintColor = nil;
                });
            }];
    }
}

- (void)loadSlowMetadata
{
    __weak typeof(self) weakSelf = self;
    if (self.entry.isDirectory) {
        [FFFileMetadataService statDirectoryAtPath:self.entry.path
            completion:^(unsigned long long size, NSUInteger files, NSUInteger folders) {
                typeof(weakSelf) self = weakSelf;
                if (!self) return;
                self.dirSizeText = [FFFileInfoViewController formatSize:size];
                self.itemCountText = [NSString stringWithFormat:@"%lu 个文件 · %lu 个文件夹",
                    (unsigned long)files, (unsigned long)folders];
                [self.tableView reloadData];
            }];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *lines = [FFFileMetadataService extendedAttributeLinesForPath:weakSelf.entry.path];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) self = weakSelf;
            if (!self || lines.count == 0) return;
            self.xattrText = [lines componentsJoinedByString:@"\n"];
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView
{
    return [self isIPA] ? 5 : 4;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self isIPA] && section == 1) return self.ipaError.length ? 1 : 5;
    NSInteger s = [self logicalSection:section];
    switch (s) {
        case 0: return 5;
        case 1: return self.entry.linkTarget.length ? 2 : 1;
        case 2: return 2;
        case 3: return self.xattrText.length ? 3 : 2;
        default: return 0;
    }
}

- (NSInteger)logicalSection:(NSInteger)section
{
    if ([self isIPA] && section > 1) return section - 1;
    return section;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if ([self isIPA] && section == 1) return @"应用信息";
    switch ([self logicalSection:section]) {
        case 0: return @"基本信息";
        case 1: return @"位置";
        case 2: return @"时间";
        case 3: return @"文件系统";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Info"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Info"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 1;

    if ([self isIPA] && indexPath.section == 1) {
        if (self.ipaError.length) {
            cell.textLabel.text = @"解析失败";
            cell.detailTextLabel.text = self.ipaError;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
            return cell;
        }
        FFIPAMetadata *m = self.ipaMetadata;
        NSArray *titles = @[@"应用名称", @"Bundle ID", @"版本", @"Build", @"最低系统"];
        NSArray *values = @[
            m.displayName ?: @"解析中…", m.bundleIdentifier ?: @"解析中…",
            m.version ?: @"解析中…", m.build ?: @"解析中…", m.minimumOS ?: @"解析中…"
        ];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = values[indexPath.row];
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        if (indexPath.row == 1 && m.bundleIdentifier.length)
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    NSInteger section = [self logicalSection:indexPath.section];
    NSString *title = @"";
    NSString *value = @"";
    switch (section) {
        case 0:
            switch (indexPath.row) {
                case 0: title = @"类型"; value = [self kindName]; break;
                case 1: title = @"大小"; value = self.entry.isDirectory ? (self.dirSizeText ?: @"计算中…") : [FFFileInfoViewController formatSize:self.entry.size]; break;
                case 2: title = @"扩展名"; value = self.entry.name.pathExtension.length ? self.entry.name.pathExtension.uppercaseString : @"（无）"; break;
                case 3: title = @"MIME"; value = [FFFileMetadataService mimeTypeNameForFilenameExtension:self.entry.name.pathExtension] ?: @"未知"; break;
                default:
                    if (self.entry.isDirectory) { title = @"项目数"; value = self.itemCountText ?: @"计算中…"; }
                    else { title = @"SHA-256"; value = self.sha256Text ?: @"点按计算"; cell.selectionStyle = UITableViewCellSelectionStyleDefault; }
                    break;
            }
            break;
        case 1:
            if (indexPath.row == 0) { title = @"完整路径"; value = self.entry.path; }
            else { title = @"链接目标"; value = self.entry.linkTarget; }
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case 2:
            if (indexPath.row == 0) { title = @"创建时间"; value = self.entry.creationDate ? [self formatDate:self.entry.creationDate] : @"未知"; }
            else { title = @"修改时间"; value = self.entry.modificationDate ? [self formatDate:self.entry.modificationDate] : @"未知"; }
            break;
        case 3:
            if (indexPath.row == 0) { title = @"权限"; value = [NSString stringWithFormat:@"%04o", self.entry.mode & 07777]; }
            else if (indexPath.row == 1) { title = @"属主"; value = [NSString stringWithFormat:@"%u:%u", self.entry.uid, self.entry.gid]; }
            else { title = @"扩展属性"; value = self.xattrText; cell.detailTextLabel.numberOfLines = 0; }
            break;
    }
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isIPA] && indexPath.section == 1 && indexPath.row == 1 && self.ipaMetadata.bundleIdentifier.length) {
        UIPasteboard.generalPasteboard.string = self.ipaMetadata.bundleIdentifier;
        [self flash:@"已复制 Bundle ID"];
        return;
    }
    NSInteger section = [self logicalSection:indexPath.section];
    NSString *copyValue = nil;
    if (section == 0 && indexPath.row == 4 && !self.entry.isDirectory) {
        if (!self.sha256Text) { [self computeSHA256]; return; }
        copyValue = self.sha256Text;
    } else if (section == 1) {
        copyValue = indexPath.row == 0 ? self.entry.path : self.entry.linkTarget;
    }
    if (!copyValue.length) return;
    UIPasteboard.generalPasteboard.string = copyValue;
    [self flash:(indexPath.row == 0 && section == 1) ? @"已复制路径" : @"已复制"];
}

- (void)computeSHA256
{
    if (self.entry.isDirectory || self.entry.isSymlink) return;
    self.sha256Text = @"计算中…";
    NSIndexPath *path = [NSIndexPath indexPathForRow:4 inSection:0];
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
    __weak typeof(self) weakSelf = self;
    NSString *file = self.entry.path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *hash = [FFFileMetadataService sha256OfFile:file];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.sha256Text = hash ?: @"计算失败";
            [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (NSString *)kindName
{
    if (self.entry.isDirectory) return @"目录";
    if (self.entry.isSymlink) return @"符号链接";
    NSString *ext = self.entry.name.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ipa"]) return @"iOS 应用安装包";
    if (ext.length) return [NSString stringWithFormat:@"%@ 文件", ext.uppercaseString];
    return @"文件";
}

+ (NSString *)formatSize:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSString *)formatDate:(NSDate *)date
{
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return [formatter stringFromDate:date];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

@end
