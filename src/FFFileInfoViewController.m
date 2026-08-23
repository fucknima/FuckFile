#import "FFFileInfoViewController.h"
#import "FFBrowserViewController.h"
#import "FFFileMetadataService.h"

@interface FFFileInfoViewController ()
@property(nonatomic, strong) FFEntry *entry;
@property(nonatomic, strong) NSArray<NSString *> *extendedAttributes;
@property(nonatomic, copy) NSString *mimeType;
@property(nonatomic) NSUInteger itemCount;
@property(nonatomic) BOOL metadataLoaded;
@end

@implementation FFFileInfoViewController

- (instancetype)initWithEntry:(FFEntry *)entry
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _entry = entry;
        self.title = @"信息";
        self.navigationItem.largeTitleDisplayMode =
            UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = weakSelf.entry.path;
        NSArray<NSString *> *attrs = FFExtendedAttributeSummaries(path);
        NSString *mime = FFMimeTypeForPath(path);
        NSUInteger count = weakSelf.entry.isDirectory ? FFItemCountAtPath(path) : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.extendedAttributes = attrs;
            weakSelf.mimeType = mime;
            weakSelf.itemCount = count;
            weakSelf.metadataLoaded = YES;
            [weakSelf.tableView reloadData];
        });
    });
}

#pragma mark - Table view

// 0 头信息 / 1 基本信息 / 2 位置 / 3 时间 / 4 文件系统
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 5;
}

- (NSInteger)numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 1;
        case 1: return self.entry.isDirectory ? 5 : 4; // 类型/大小/扩展名/MIME(+/项目数量)
        case 2: {
            NSInteger rows = 2; // 完整路径 / 复制路径
            if (self.entry.isSymlink && self.entry.linkTarget.length) rows += 2;
            return rows;
        }
        case 3: return 2; // 创建时间 / 修改时间
        case 4: {
            NSInteger rows = 3; // 权限 / UID / GID
            rows += self.extendedAttributes.count;
            if (self.extendedAttributes.count == 0 && self.metadataLoaded) rows += 1;
            return rows;
        }
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 1: return @"基本信息";
        case 2: return @"位置";
        case 3: return @"时间";
        case 4: return @"文件系统";
        default: return nil;
    }
}

- (NSString *)kindText
{
    if (self.entry.isDirectory) return @"文件夹";
    if (self.entry.isSymlink) return @"符号链接";
    NSString *ext = self.entry.name.pathExtension.lowercaseString;
    if (ext.length) return [NSString stringWithFormat:@"%@ 文件", ext.uppercaseString];
    return @"文件";
}

- (NSString *)sizeText:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
        countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSString *)dateText:(NSDate *)date
{
    if (!date) return @"未知";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    return [formatter stringFromDate:date];
}

- (UITableViewCell *)valueCell:(NSString *)title value:(NSString *)value
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Info"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Info"];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = title;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.secondaryText = value;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    config.secondaryTextProperties.numberOfLines = 0;
    config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    cell.contentConfiguration = config;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)actionCell:(NSString *)title
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Action"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Action"];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = title;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.color = [UIColor systemBlueColor];
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Header"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:@"Header"];
        UIListContentConfiguration *config = [cell defaultContentConfiguration];
        config.text = self.entry.displayName.length ? self.entry.displayName : self.entry.name;
        config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        config.secondaryText = [self kindText];
        config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        config.image = [UIImage systemImageNamed:self.entry.isSymlink ? @"link"
            : self.entry.isDirectory ? @"folder.fill" : @"doc"];
        config.imageProperties.maximumSize = CGSizeMake(52, 52);
        config.imageProperties.cornerRadius = 8;
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    NSInteger row = indexPath.row;
    if (indexPath.section == 1) {
        switch (row) {
            case 0: return [self valueCell:@"类型" value:[self kindText]];
            case 1: {
                NSString *size = self.entry.isDirectory
                    ? @"—" : [self sizeText:self.entry.size];
                return [self valueCell:@"大小" value:size];
            }
            case 2: {
                NSString *ext = self.entry.name.pathExtension.lowercaseString;
                return [self valueCell:@"扩展名"
                    value:(ext.length ? [@"." stringByAppendingString:ext] : @"无")];
            }
            case 3: return [self valueCell:@"MIME"
                value:self.mimeType.length ? self.mimeType : @"…"];
            case 4: return [self valueCell:@"项目数量"
                value:self.metadataLoaded
                    ? [NSString stringWithFormat:@"%lu 项", (unsigned long)self.itemCount]
                    : @"…"];
            default: return nil;
        }
    }

    if (indexPath.section == 2) {
        if (row == 0) return [self valueCell:@"完整路径" value:self.entry.path];
        if (row == 1) return [self actionCell:@"复制路径"];
        if (row == 2 && self.entry.linkTarget.length)
            return [self valueCell:@"链接目标" value:self.entry.linkTarget];
        if (row == 3 && self.entry.linkTarget.length)
            return [self actionCell:@"复制链接目标"];
        return nil;
    }

    if (indexPath.section == 3) {
        if (row == 0) return [self valueCell:@"创建时间" value:[self dateText:self.entry.creationDate]];
        return [self valueCell:@"修改时间" value:[self dateText:self.entry.modificationDate]];
    }

    if (indexPath.section == 4) {
        if (row == 0)
            return [self valueCell:@"权限" value:[NSString stringWithFormat:@"%04o · %@",
                (unsigned int)(self.entry.mode & 07777), FFPermissionString(self.entry.mode)]];
        if (row == 1) return [self valueCell:@"UID" value:[NSString stringWithFormat:@"%u", self.entry.uid]];
        if (row == 2) return [self valueCell:@"GID" value:[NSString stringWithFormat:@"%u", self.entry.gid]];
        if (self.extendedAttributes.count == 0)
            return [self valueCell:@"扩展属性" value:@"无"];
        NSString *attr = self.extendedAttributes[row - 3];
        return [self valueCell:@"扩展属性" value:attr];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row == 1) {
        UIPasteboard.generalPasteboard.string = self.entry.path;
        [self flash:@"路径已复制"];
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 3 &&
        self.entry.linkTarget.length) {
        UIPasteboard.generalPasteboard.string = self.entry.linkTarget;
        [self flash:@"链接目标已复制"];
        return;
    }
}

#pragma mark - helpers

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
}

@end
