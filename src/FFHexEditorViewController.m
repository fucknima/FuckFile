#import "FFHexEditorViewController.h"
#import "FFViewerActions.h"

#import <string.h>

#import "FFPathPolicy.h"
#import "FFLogger.h"

#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <sys/stat.h>
#import <inttypes.h>
#import <zlib.h>
#import <CommonCrypto/CommonDigest.h>

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
@property(nonatomic) BOOL saving; // 保存进行中：禁止再次提交/编辑/丢弃
@property(nonatomic, strong) NSData *pageCache; // current 64 KiB page
@property(nonatomic, strong) NSArray<NSNumber *> *searchMatches;
@property(nonatomic) NSUInteger searchIndex;
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
        self.title = path.lastPathComponent;
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
    UIBarButtonItem *checksum = [[UIBarButtonItem alloc] initWithTitle:@"校验"
        style:UIBarButtonItemStylePlain target:self action:@selector(checksumTapped)];
    UIBarButtonItem *discard = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                             action:@selector(discardPatches)];
    UIBarButtonItem *save = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self
                             action:@selector(saveTapped)];
    UIBarButtonItem *find = [[UIBarButtonItem alloc] initWithTitle:@"查找"
        style:UIBarButtonItemStylePlain target:self action:@selector(findTapped)];
    UIBarButtonItem *share = [FFViewerActions shareItemForPath:self.filePath presenter:self];
    self.navigationItem.rightBarButtonItems = @[save, checksum, jump, find, share, discard];
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
    // Save/discard enabled only with pending patches, and never while a save
    // is in flight (avoid double-submit and concurrent patch mutation).
    BOOL hasPending = self.patches.count > 0 && !self.saving;
    self.navigationItem.rightBarButtonItems.firstObject.enabled = hasPending;
    // 「取消修改」同样只在有未保存修改时可点（避免点了没反应）。
    self.navigationItem.rightBarButtonItems.lastObject.enabled = hasPending;
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
    if (self.saving) return;

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
    if (self.saving) return;
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

// CRC32 + SHA-256 全文件流式计算（64KB 分块，不整读大文件）。
- (void)checksumTapped
{
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:nil
        message:@"正在计算校验和…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uLong crc = crc32(0L, Z_NULL, 0);
        CC_SHA256_CTX sha;
        CC_SHA256_Init(&sha);
        int fd = open(self.filePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        uint8_t buffer[64 * 1024];
        ssize_t count;
        off_t offset = 0;
        if (fd >= 0) {
            while ((count = pread(fd, buffer, sizeof(buffer), offset)) > 0) {
                crc = crc32(crc, buffer, (uInt)count);
                CC_SHA256_Update(&sha, buffer, (CC_LONG)count);
                offset += count;
            }
            close(fd);
        }
        NSMutableString *shaHex = [NSMutableString stringWithCapacity:64];
        uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {0};
        CC_SHA256_Final(digest, &sha);
        for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
            [shaHex appendFormat:@"%02x", digest[i]];

        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"校验和"
                    message:[NSString stringWithFormat:
                        @"CRC32   %08lX\nSHA-256 %@\n\n大小 %llu 字节",
                        (unsigned long)crc, shaHex, self.fileSize]
                    preferredStyle:UIAlertControllerStyleAlert];
                __weak typeof(self) weakSelf = self;
                [alert addAction:[UIAlertAction actionWithTitle:@"复制"
                    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                        UIPasteboard.generalPasteboard.string =
                            [NSString stringWithFormat:@"CRC32 %08lX\nSHA-256 %@",
                                (unsigned long)crc, shaHex];
                        [weakSelf flash:@"已复制"];
                    }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"好"
                    style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }];
        });
    });
}

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

#pragma mark - Search

// 十六进制输入判定：以 0x 开头或含空格的纯十六进制串；否则按 UTF-8 文本。
static NSData *FFHexSearchNeedle(NSString *query)
{
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSString *lower = trimmed.lowercaseString;
    BOOL hexish = [lower hasPrefix:@"0x"] || [trimmed containsString:@" "];
    if (hexish) {
        NSString *compact = [[trimmed componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
        if ([compact.lowercaseString hasPrefix:@"0x"])
            compact = [compact substringFromIndex:2];
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"0123456789abcdefABCDEF"];
        if (compact.length && compact.length % 2 == 0 &&
            [compact rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound) {
            NSMutableData *data = [NSMutableData data];
            for (NSUInteger index = 0; index + 1 < compact.length; index += 2) {
                unsigned int byte = 0;
                if (![[NSScanner scannerWithString:
                    [compact substringWithRange:NSMakeRange(index, 2)]] scanHexInt:&byte])
                    return nil;
                uint8_t value = (uint8_t)byte;
                [data appendBytes:&value length:1];
            }
            if (data.length) return data;
        }
    }
    NSData *utf8 = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    return utf8.length ? utf8 : nil;
}

- (void)findTapped
{
    BOOL hasMatches = self.searchMatches.count > 0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"查找"
        message:hasMatches
            ? [NSString stringWithFormat:@"已找到 %lu 处，当前第 %lu 处",
                (unsigned long)self.searchMatches.count, (unsigned long)(self.searchIndex + 1)]
            : @"输入文本，或十六进制字节（如 1F 8B / 0x1F8B）"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = hasMatches ? @"新关键词" : @"查找内容";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (hasMatches) {
        [alert addAction:[UIAlertAction actionWithTitle:@"下一处" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf showNextMatch]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"查找" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf beginSearchWithQuery:alert.textFields.firstObject.text ?: @""];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginSearchWithQuery:(NSString *)query
{
    NSData *needle = FFHexSearchNeedle(query);
    if (!needle.length) {
        [self flash:@"请输入查找内容"];
        return;
    }
    NSString *path = self.filePath;
    unsigned long long fileSize = self.fileSize;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const size_t chunk = 256 * 1024;
        const size_t needleLength = needle.length;
        uint8_t *buffer = malloc(chunk + MAX(needleLength, (size_t)1));
        NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
        int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (fd >= 0 && buffer) {
            unsigned long long offset = 0;
            size_t carry = 0;
            const uint8_t *needleBytes = needle.bytes;
            while (matches.count < 500 && offset < fileSize) {
                ssize_t count = pread(fd, buffer + carry, chunk, (off_t)offset);
                if (count <= 0) break;
                size_t total = carry + (size_t)count;
                for (size_t index = 0; index + needleLength <= total; index++) {
                    if (memcmp(buffer + index, needleBytes, needleLength) == 0) {
                        [matches addObject:@(offset - carry + index)];
                        if (matches.count >= 500) break;
                    }
                }
                if (needleLength > 1) {
                    carry = MIN(needleLength - 1, total);
                    memmove(buffer, buffer + total - carry, carry);
                } else {
                    carry = 0;
                }
                offset += (unsigned long long)count;
            }
            close(fd);
        }
        free(buffer);

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = self;
            if (!strongSelf) return;
            strongSelf.searchMatches = matches;
            strongSelf.searchIndex = 0;
            if (!matches.count) {
                [strongSelf flash:@"未找到匹配内容"];
                return;
            }
            [strongSelf jumpToOffset:matches.firstObject.unsignedLongLongValue];
            [strongSelf flash:[NSString stringWithFormat:@"第 1 / %lu 处，偏移 0x%llX",
                (unsigned long)matches.count,
                matches.firstObject.unsignedLongLongValue]];
        });
    });
}

- (void)showNextMatch
{
    if (!self.searchMatches.count) return;
    self.searchIndex = (self.searchIndex + 1) % self.searchMatches.count;
    unsigned long long offset = self.searchMatches[self.searchIndex].unsignedLongLongValue;
    [self jumpToOffset:offset];
    [self flash:[NSString stringWithFormat:@"第 %lu / %lu 处，偏移 0x%llX",
        (unsigned long)(self.searchIndex + 1),
        (unsigned long)self.searchMatches.count, offset]];
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
    if (self.saving) return;
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
    if (self.saving) return;
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
    self.saving = YES;
    [self updateBarState];
    // 快照：保存期间仍可能产生新编辑，后台不能枚举会变的字典。
    NSDictionary<NSNumber *, NSNumber *> *patches = [self.patches copy];
    unsigned long long fileSize = self.fileSize;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSUInteger applied = [self applyPatches:patches fileSize:fileSize
            toParent:parent name:finalName error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.saving = NO;
            if (applied == NSNotFound) {
                [self updateBarState];
                [self flash:[NSString stringWithFormat:@"保存失败：%@",
                    error.localizedDescription ?: @"未知错误"]];
                return;
            }
            // rename 后旧 fd 指向已被替换的 inode，必须重新打开才能读到新内容。
            if (![self reopenTargetAfterSave])
                [self flash:@"已保存，但重新打开文件失败，请退出后重进"];
            // 只清掉真正写盘的补丁；保存期间新产生的编辑保持待保存状态。
            for (NSNumber *offset in patches) {
                if ([self.patches[offset] isEqualToNumber:patches[offset]]) {
                    [self.patches removeObjectForKey:offset];
                    [self.originals removeObjectForKey:offset];
                }
            }
            FFLogTag(@"HexEditor", @"saved path=%@ patches=%lu",
                self.filePath, (unsigned long)applied);
            self.pageCache = nil;
            [self.tableView reloadData];
            [self refreshHeader];
            [self updateBarState];
            [self flash:[NSString stringWithFormat:@"已写入 %lu 处修改", (unsigned long)applied]];
        });
    });
}

- (BOOL)reopenTargetAfterSave
{
    int fd = open(self.filePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat status = {0};
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode)) {
        close(fd);
        return NO;
    }
    if (self.fd >= 0) close(self.fd);
    self.fd = fd;
    self.fileSize = (unsigned long long)status.st_size;
    self.deviceID = status.st_dev;
    self.inodeID = status.st_ino;
    self.pageCount = MAX(1ULL, ((uint64_t)self.fileSize + kPageSize - 1) / kPageSize);
    if (self.pageIndex >= self.pageCount) self.pageIndex = self.pageCount - 1;
    return YES;
}

// 原子保存：先把原文件整份复制成同目录临时文件，在临时文件上打补丁并
// fsync，确认原文件未被替换后 rename 覆盖。中途失败/断电只会留下原文件
// 和一个已清理的临时文件，不会出现半修改状态。
- (NSUInteger)applyPatches:(NSDictionary<NSNumber *, NSNumber *> *)patches
                  fileSize:(unsigned long long)fileSize
                  toParent:(NSString *)parent
                      name:(NSString *)name
                     error:(NSError **)error
{
    NSString *target = [parent stringByAppendingPathComponent:name];
    NSString *tempPath = [parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.ffhex-%@.tmp", name,
            [NSUUID.UUID.UUIDString substringToIndex:8]]];
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager copyItemAtPath:target toPath:tempPath error:error]) return NSNotFound;

    NSError *failure = nil;
    NSUInteger applied = 0;
    int fd = open(tempPath.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"打开临时文件失败：%s", strerror(errno)]}];
    } else {
        BOOL ok = YES;
        for (NSNumber *offsetNumber in patches) {
            unsigned long long offset = offsetNumber.unsignedLongLongValue;
            if (offset >= fileSize) continue; // stale patch beyond EOF
            uint8_t byte = (uint8_t)patches[offsetNumber].unsignedCharValue;
            if (pwrite(fd, &byte, 1, (off_t)offset) != 1) {
                ok = NO;
                failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"写入 0x%llX 失败：%s",
                            offset, strerror(errno)]}];
                break;
            }
            applied++;
        }
        if (ok && fsync(fd) != 0) {
            ok = NO;
            failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"fsync 失败：%s", strerror(errno)]}];
        }
        close(fd);
        if (ok) {
            // 目标被别的进程替换过就放弃，避免覆盖别人的新内容。
            struct stat current = {0};
            if (lstat(target.fileSystemRepresentation, &current) != 0 ||
                current.st_dev != self.deviceID || current.st_ino != self.inodeID) {
                ok = NO;
                failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIDRM
                    userInfo:@{NSLocalizedDescriptionKey:@"目标文件已被替换，拒绝写入"}];
            }
        }
        if (ok && rename(tempPath.fileSystemRepresentation,
                         target.fileSystemRepresentation) != 0) {
            ok = NO;
            failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"替换原文件失败：%s", strerror(errno)]}];
        }
        if (ok) return applied;
    }
    [manager removeItemAtPath:tempPath error:nil];
    if (error) *error = failure ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
        userInfo:@{NSLocalizedDescriptionKey:@"写入中断，原文件未改动"}];
    return NSNotFound;
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
