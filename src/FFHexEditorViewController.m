#import "FFHexEditorViewController.h"

#import "FFPathPolicy.h"
#import "FFLogger.h"

#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <sys/stat.h>
#import <inttypes.h>

// 16 bytes per row, 64 KiB per page → 4096 rows/page. Constant page size
// keeps memory bounded regardless of file size.
static const NSUInteger kBytesPerRow = 16;
static const NSUInteger kPageSize = 64 * 1024;

@interface FFHexEditorViewController ()
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic) int fd;                    // open for the VC lifetime
@property(nonatomic) unsigned long long fileSize;
@property(nonatomic) dev_t deviceID;
@property(nonatomic) ino_t inodeID;
@property(nonatomic) unsigned long long pageIndex;   // current page
@property(nonatomic) unsigned long long pageCount;
// Absolute offset -> @(newByte). Original bytes are kept alongside so a
// failed save can roll back what it already wrote.
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *patches;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *originals;
@property(nonatomic, strong) NSData *pageCache; // current 64 KiB page
@property(nonatomic) unsigned long long cachedPageIndex;
@end

@implementation FFHexEditorViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat status = {0};
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode)) {
        close(fd);
        return nil;
    }
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _filePath = [path copy];
        _fd = fd;
        _fileSize = (unsigned long long)status.st_size;
        _deviceID = status.st_dev;
        _inodeID = status.st_ino;
        _pageCount = MAX(1ULL,
            ((uint64_t)_fileSize + kPageSize - 1) / kPageSize);
        _patches = [NSMutableDictionary dictionary];
        _originals = [NSMutableDictionary dictionary];
        _title = path.lastPathComponent;
    }
    return self;
}

- (void)dealloc
{
    if (_fd >= 0) close(_fd);
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    UIBarButtonItem *jump = [[UIBarButtonItem alloc] initWithTitle:@"跳转"
        style:UIBarButtonItemStylePlain target:self action:@selector(jumpTapped)];
    UIBarButtonItem *discard = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                             action:@selector(discardPatches)];
    UIBarButtonItem *save = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self
                             action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItems = @[save, jump, discard];
    [self updateBarState];

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 36)];
    header.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    header.textAlignment = NSTextAlignmentCenter;
    header.textColor = UIColor.secondaryLabelColor;
    header.tag = 4471;
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = header;

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 22;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Hex"];
    [self refreshHeader];
}

#pragma mark - Header / bar state

- (void)refreshHeader
{
    UILabel *header = (UILabel *)[self.view viewWithTag:4471];
    if (!header) return;
    unsigned long long start = self.pageIndex * kPageSize;
    unsigned long long end = MIN(start + kPageSize, self.fileSize);
    header.text = [NSString stringWithFormat:
        @"页 %llu/%llu · 偏移 0x%llX–0x%llX · 共 %llu 字节 · 待保存修改 %lu",
        self.pageIndex + 1, self.pageCount, start, end, self.fileSize,
        (unsigned long)self.patches.count];
}

- (void)updateBarState
{
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
        item.enabled = YES; // 跳转始终可用
    // Save enabled only with pending patches.
    self.navigationItem.rightBarButtonItems.firstObject.enabled =
        self.patches.count > 0;
}

#pragma mark - Page reading

// Returns the current page's bytes (single pread, cached until the page
// changes) so rendering 4096 rows doesn't re-read the file per row.
- (NSData *)currentPageData
{
    if (self.pageCache && self.cachedPageIndex == self.pageIndex)
        return self.pageCache;
    off_t offset = (off_t)(self.pageIndex * kPageSize);
    size_t want = (size_t)MIN((uint64_t)kPageSize,
        self.fileSize - MIN((uint64_t)offset, self.fileSize));
    NSMutableData *data = [NSMutableData dataWithLength:want];
    uint8_t *buffer = data.mutableBytes;
    size_t done = 0;
    while (buffer && done < want) {
        ssize_t count = pread(self.fd, buffer + done, want - done,
            offset + (off_t)done);
        if (count <= 0) break;
        done += (size_t)count;
    }
    if (done < want) data.length = done;
    self.pageCache = data;
    self.cachedPageIndex = self.pageIndex;
    return data;
}

#pragma mark - Table source

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    off_t offset = (off_t)(self.pageIndex * kPageSize);
    unsigned long long remaining =
        self.fileSize - MIN((unsigned long long)offset, self.fileSize);
    return (NSInteger)((remaining + kBytesPerRow - 1) / kBytesPerRow);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Hex"
        forIndexPath:indexPath];
    NSData *page = [self currentPageData];
    const uint8_t *bytes = page.bytes;

    NSUInteger row = (NSUInteger)indexPath.row;
    NSUInteger lineStart = row * kBytesPerRow;
    NSUInteger lineLength = MIN(kBytesPerRow, page.length - lineStart);

    unsigned long long absolute = self.pageIndex * kPageSize + lineStart;
    NSMutableString *hex = [NSMutableString string];
    NSMutableString *ascii = [NSMutableString string];
    BOOL modified = NO;
    for (NSUInteger i = 0; i < lineLength; i++) {
        NSNumber *patched = self.patches[@(absolute + i)];
        uint8_t byte = patched ? (uint8_t)patched.unsignedCharValue : bytes[lineStart + i];
        [hex appendFormat:@"%02x ", byte];
        if (i == 7) [hex appendString:@" "];
        [ascii appendFormat:@"%c", (byte >= 0x20 && byte != 0x7F) ? byte : '.'];
        modified |= patched != nil;
    }
    cell.textLabel.text = [NSString stringWithFormat:@"%08llX  %@| %@",
        absolute, hex, ascii];
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    cell.textLabel.adjustsFontSizeToFitWidth = NO;
    cell.textLabel.numberOfLines = 1;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = modified ? UIColor.systemRedColor : UIColor.labelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

#pragma mark - Editing

// Tap a row to edit its bytes: the alert pre-fills the current hex pairs
// and any changed pairs become in-memory patches until explicit save.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSData *page = [self currentPageData];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row * kBytesPerRow >= page.length) return;
    NSUInteger lineLength = MIN(kBytesPerRow, page.length - row * kBytesPerRow);
    const uint8_t *bytes = page.bytes;

    unsigned long long base = self.pageIndex * kPageSize + row * kBytesPerRow;
    NSMutableString *current = [NSMutableString string];
    for (NSUInteger i = 0; i < lineLength; i++) {
        NSNumber *patched = self.patches[@(base + i)];
        uint8_t byte = patched ? (uint8_t)patched.unsignedCharValue : bytes[row * kBytesPerRow + i];
        [current appendFormat:@"%02x", byte];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"编辑偏移 0x%08llX（%lu 字节）", base,
            (unsigned long)lineLength]
        message:@"输入新的十六进制字节（每字节两位，必须保持本行长度）"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        field.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"应用"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *input = alert.textFields.firstObject.text ?: @"";
            if (![weakSelf hexInputValid:input]) {
                [weakSelf flash:@"格式无效：需要偶数位十六进制字符"];
                return;
            }
            [weakSelf applyHex:input toLineBase:base lineLength:lineLength];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)hexInputValid:(NSString *)input
{
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
            @"^[0-9a-fA-F]+$" options:0 error:nil];
    });
    return input.length % 2 == 0 && input.length > 0 && input.length <= 32 &&
        [regex numberOfMatchesInString:input options:0
            range:NSMakeRange(0, input.length)] == 1;
}

- (void)applyHex:(NSString *)hex toLineBase:(unsigned long long)base lineLength:(NSUInteger)lineLength
{
    if (hex.length / 2 != lineLength) {
        [self flash:[NSString stringWithFormat:
            @"长度不符：本行固定 %lu 字节", (unsigned long)lineLength]];
        return;
    }
    const char *bytes = hex.UTF8String;
    for (NSUInteger i = 0; i < lineLength; i++) {
        unsigned value = 0;
        sscanf(bytes + i * 2, "%2x", &value);
        NSNumber *offset = @(base + i);
        if (!self.patches[offset] && !self.originals[offset]) {
            // Cache the on-disk original once per offset for rollback.
            uint8_t original = 0;
            pread(self.fd, &original, 1, (off_t)(base + i));
            self.originals[offset] = @(original);
        }
        self.patches[offset] = @(value);
    }
    [self.tableView reloadData];
    [self refreshHeader];
    [self updateBarState];
}

#pragma mark - Jump / discard / save

- (void)jumpTapped
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跳转到偏移"
        message:@"支持十进制（1048576）或十六进制（0x100000）" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(__unused UITextField *field) {}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *text = (alert.textFields.firstObject.text ?: @"").lowercaseString;
            unsigned long long target = 0;
            BOOL ok = NO;
            if ([text hasPrefix:@"0x"] && text.length > 2) {
                ok = [[NSScanner scannerWithString:[text substringFromIndex:2]]
                    scanHexLongLong:&target];
            } else if (text.length > 0) {
                NSScanner *scanner = [NSScanner scannerWithString:text];
                ok = [scanner scanUnsignedLongLong:&target] && [scanner isAtEnd];
            }
            if (!ok) { [weakSelf flash:@"无法识别的偏移"]; return; }
            [weakSelf jumpToOffset:target];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)jumpToOffset:(unsigned long long)target
{
    if (target >= self.fileSize) {
        [self flash:[NSString stringWithFormat:
            @"超出文件范围（最大 0x%llX）", self.fileSize ? self.fileSize - 1 : 0]];
        return;
    }
    self.pageIndex = target / kPageSize;
    [self.tableView reloadData];
    [self refreshHeader];
    NSIndexPath *top = [NSIndexPath indexPathForRow:(NSInteger)((target % kPageSize) / kBytesPerRow)
                                          inSection:0];
    [self.tableView scrollToRowAtIndexPath:top
        atScrollPosition:UITableViewScrollPositionTop animated:NO];
}

- (void)discardPatches
{
    if (self.patches.count == 0) return;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"放弃修改"
        message:[NSString stringWithFormat:@"将丢弃 %lu 处未保存的字节修改。",
            (unsigned long)self.patches.count]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"继续编辑"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"放弃"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [weakSelf.patches removeAllObjects];
            [weakSelf.originals removeAllObjects];
            [weakSelf.tableView reloadData];
            [weakSelf refreshHeader];
            [weakSelf updateBarState];
        }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)saveTapped
{
    if (self.patches.count == 0) return;
    NSString *detail = nil;
    NSString *finalName = nil;
    // 与文本/属性表编辑器相同的路径安全策略：先解析并验证父链。
    NSString *parent = [FFPathPolicy resolveParentForMutation:self.filePath
        finalName:&finalName errorMessage:&detail];
    if (!parent) {
        FFLogTag(@"HexEditor", @"save REJECT path=%@ reason=%@", self.filePath, detail ?: @"?");
        [self flash:[NSString stringWithFormat:@"无法保存：%@", detail ?: @"路径不合法"]];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSUInteger applied = [self applyPatchesToParent:parent name:finalName error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (applied == NSNotFound) {
                [self flash:[NSString stringWithFormat:@"保存失败：%@",
                    error.localizedDescription ?: @"未知错误"]];
                return;
            }
            FFLogTag(@"HexEditor", @"saved path=%@ patches=%lu",
                self.filePath, (unsigned long)applied);
            [self.patches removeAllObjects];
            [self.originals removeAllObjects];
            [self.tableView reloadData];
            [self refreshHeader];
            [self updateBarState];
            [self flash:[NSString stringWithFormat:@"已写入 %lu 处修改", (unsigned long)applied]];
        });
    });
}

// Applies every patch via pwrite on the validated target. Returns the
// number of patches written, or NSNotFound after rolling back partial
// writes from the cached originals — the file is never left half-modified.
- (NSUInteger)applyPatchesToParent:(NSString *)parent name:(NSString *)name error:(NSError **)error
{
    NSString *target = [parent stringByAppendingPathComponent:name];
    int fd = open(target.fileSystemRepresentation,
        O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"打开文件失败：%s", strerror(errno)]}];
        return NSNotFound;
    }
    struct stat status = {0};
    if (fstat(fd, &status) != 0 || status.st_dev != self.deviceID ||
        status.st_ino != self.inodeID) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIDRM
            userInfo:@{NSLocalizedDescriptionKey:@"目标文件已被替换，拒绝写入"}];
        return NSNotFound;
    }
    NSMutableArray<NSNumber *> *written = [NSMutableArray array];
    BOOL ok = YES;
    NSString *failure = nil;
    for (NSNumber *offsetNumber in self.patches) {
        unsigned long long offset = offsetNumber.unsignedLongLongValue;
        if (offset >= self.fileSize) continue; // stale patch beyond EOF
        uint8_t byte = (uint8_t)self.patches[offsetNumber].unsignedCharValue;
        ssize_t result = pwrite(fd, &byte, 1, (off_t)offset);
        if (result != 1) {
            ok = NO;
            failure = [NSString stringWithFormat:@"写入 0x%llX 失败：%s",
                offset, strerror(errno)];
            break;
        }
        [written addObject:offsetNumber];
    }
    if (ok && fsync(fd) != 0) {
        ok = NO;
        failure = [NSString stringWithFormat:@"fsync 失败：%s", strerror(errno)];
    }
    if (!ok) {
        // Roll back everything already written so no half state remains.
        for (NSNumber *offsetNumber in written) {
            NSNumber *original = self.originals[offsetNumber];
            if (!original) continue;
            uint8_t byte = (uint8_t)original.unsignedCharValue;
            pwrite(fd, &byte, 1, (off_t)offsetNumber.unsignedLongLongValue);
        }
        fsync(fd);
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey:
                failure ?: @"写入中断，已回滚"}];
        return NSNotFound;
    }
    close(fd);
    return written.count;
}

- (void)flash:(NSString *)message
{
    UINavigationController *nav = self.navigationController;
    UIViewController *top = nav.topViewController ?: self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [top presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

@end
