#import "FFFileInfoViewController.h"
#import "FFFileMetadataService.h"

@interface FFFileInfoViewController ()
@property(nonatomic, strong) FFEntry *entry;
@property(nonatomic, strong) UIImage *icon;
@property(nonatomic, copy) NSString *dirSizeText;
@property(nonatomic, copy) NSString *itemCountText;
@property(nonatomic, copy) NSString *xattrText;
@property(nonatomic, copy) NSString *sha256Text;
@end

@implementation FFFileInfoViewController

- (instancetype)initWithEntry:(FFEntry *)entry icon:(UIImage *)icon
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _entry = entry;
        _icon = icon;
        _sha256Text = nil;
        self.title = @"文件信息";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    [self setupHeader];
    [self loadSlowMetadata];
}

- (void)setupHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        self.view.bounds.size.width, 128)];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:self.icon];
    iconView.tintColor = UIColor.systemBlueColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.isAccessibilityElement = NO;
    [header addSubview:iconView];

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = self.entry.displayName.length ? self.entry.displayName : self.entry.name;
    nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    nameLabel.adjustsFontForContentSizeCategory = YES;
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.numberOfLines = 2;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:nameLabel];

    UILabel *kindLabel = [[UILabel alloc] init];
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
        [iconView.heightAnchor constraintEqualToConstant:48],
        [iconView.widthAnchor constraintLessThanOrEqualToConstant:48],
        [nameLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:6],
        [nameLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [nameLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [kindLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [kindLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [kindLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4],
    ]];
    self.tableView.tableHeaderView = header;
}

// 慢数据全部后台加载：目录递归统计 / xattr。
- (void)loadSlowMetadata
{
    __weak typeof(self) weakSelf = self;
    if (self.entry.isDirectory) {
        [FFFileMetadataService statDirectoryAtPath:self.entry.path
            completion:^(unsigned long long size, NSUInteger files, NSUInteger folders) {
                typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.dirSizeText = [FFFileInfoViewController formatSize:size];
                strongSelf.itemCountText = [NSString stringWithFormat:
                    @"%lu 个文件 · %lu 个文件夹",
                    (unsigned long)files, (unsigned long)folders];
                [strongSelf.tableView reloadData];
            }];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *lines = [FFFileMetadataService
            extendedAttributeLinesForPath:weakSelf.entry.path];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || lines.count == 0) return;
            strongSelf.xattrText = [lines componentsJoinedByString:@"\n"];
            [strongSelf.tableView reloadData];
        });
    });
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // 0 基本信息 / 1 位置 / 2 时间 / 3 文件系统
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0:
            return self.entry.isDirectory ? 5 : 5; // 类型/大小/扩展名/MIME/SHA-256(或项目数)
        case 1:
            return self.entry.linkTarget.length ? 2 : 1;
        case 2: return 2;
        case 3:
            return self.xattrText.length ? 3 : 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"基本信息";
        case 1: return @"位置";
        case 2: return @"时间";
        case 3: return @"文件系统";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Info"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"Info"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    NSString *title = @"";
    NSString *value = @"";
    BOOL selectable = NO;

    switch (indexPath.section) {
        case 0: {
            switch (indexPath.row) {
                case 0:
                    title = @"类型";
                    value = [self kindName];
                    break;
                case 1:
                    title = @"大小";
                    value = self.entry.isDirectory
                        ? (self.dirSizeText ?: @"计算中…")
                        : [FFFileInfoViewController formatSize:self.entry.size];
                    break;
                case 2:
                    title = @"扩展名";
                    value = self.entry.name.pathExtension.length
                        ? self.entry.name.pathExtension.uppercaseString : @"（无）";
                    break;
                case 3:
                    title = @"MIME";
                    value = [FFFileMetadataService
                        mimeTypeNameForFilenameExtension:self.entry.name.pathExtension]
                        ?: @"未知";
                    break;
                case 4:
                    if (self.entry.isDirectory) {
                        title = @"项目数";
                        value = self.itemCountText ?: @"计算中…";
                    } else {
                        title = @"SHA-256";
                        value = self.sha256Text ?: @"点按计算";
                        selectable = YES;
                        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                    }
                    break;
            }
            break;
        }
        case 1: {
            if (indexPath.row == 0) {
                title = @"完整路径";
                value = self.entry.path;
                selectable = YES;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else {
                title = @"链接目标";
                value = self.entry.linkTarget;
                selectable = YES;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                title = @"创建时间";
                value = self.entry.creationDate ?
                    [self formatDate:self.entry.creationDate] : @"未知";
            } else {
                title = @"修改时间";
                value = self.entry.modificationDate ?
                    [self formatDate:self.entry.modificationDate] : @"未知";
            }
            break;
        }
        case 3: {
            switch (indexPath.row) {
                case 0:
                    title = @"权限";
                    value = [NSString stringWithFormat:@"%04o",
                        self.entry.mode & 07777];
                    break;
                case 1:
                    title = @"属主";
                    value = [NSString stringWithFormat:@"%u:%u",
                        self.entry.uid, self.entry.gid];
                    break;
                default:
                    title = @"扩展属性";
                    value = self.xattrText;
                    cell.detailTextLabel.numberOfLines = 0;
                    break;
            }
            break;
        }
    }

    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *copyValue = nil;
    if (indexPath.section == 0 && indexPath.row == 4 && !self.entry.isDirectory) {
        if (!self.sha256Text) { [self computeSHA256]; return; }
        copyValue = self.sha256Text;
    } else if (indexPath.section == 1) {
        copyValue = indexPath.row == 0 ? self.entry.path : self.entry.linkTarget;
    }
    if (!copyValue.length) return;
    UIPasteboard.generalPasteboard.string = copyValue;
    [self flash:indexPath.row == 0 && indexPath.section == 1 ? @"已复制路径" : @"已复制"];
}

#pragma mark - Actions

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
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.sha256Text = hash ?: @"计算失败";
            [strongSelf.tableView reloadRowsAtIndexPaths:@[path]
                withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

#pragma mark - Helpers

- (NSString *)kindName
{
    if (self.entry.isDirectory) return @"目录";
    if (self.entry.isSymlink) return @"符号链接";
    NSString *ext = self.entry.name.pathExtension.lowercaseString;
    if (ext.length) return [NSString stringWithFormat:@"%@ 文件", ext.uppercaseString];
    return @"文件";
}

+ (NSString *)formatSize:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
        countStyle:NSByteCountFormatterCountStyleFile];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
}

@end
