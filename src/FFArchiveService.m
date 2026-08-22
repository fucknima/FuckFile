#import "FFArchiveService.h"

#import "minizip/unzip.h"

#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/stat.h>

// Built on minizip (third_party/minizip) instead of a hand-written
// central-directory parser: real-world archives (Actions artifacts,
// Windows tools, data-descriptor zips, ZIP64) all work through the
// battle-tested code path. Safety rules preserved on top of it:
//  - entry count cap and per-entry uncompressed size cap
//  - entry-name sanitization before anything touches the filesystem
//  - symlink entries rejected on extraction
//  - CRC verified by minizip on unzCloseCurrentFile

static const unsigned long long kMaxEntrySize = 2ULL * 1024 * 1024 * 1024; // 单条目 2 GiB
static const NSUInteger kMaxEntries = 100000;

static NSError *FFArchiveError(NSString *message)
{
    return [NSError errorWithDomain:@"FFArchive" code:-1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation FFArchiveEntry
@end

@implementation FFArchiveService

+ (BOOL)isZipFamilyExtension:(NSString *)extension
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 与 Browser 的 isArchiveEntry 集合一致：真实 zip 容器家族。
        extensions = [NSSet setWithArray:@[
            @"zip", @"ipa", @"xcarchive", @"appex", @"app",
            @"bundle", @"framework", @"war", @"jar", @"crx", @"xpi",
            @"docx", @"xlsx", @"pptx", @"pages", @"numbers", @"key",
            @"epub", @"apk",
        ]];
    });
    return [extensions containsObject:extension.lowercaseString];
}

+ (BOOL)isKnownButUnsupportedExtension:(NSString *)extension
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:
            @[ @"tar", @"tar.gz", @"gz", @"7z", @"rar", @"xz", @"bz2" ]];
    });
    return [extensions containsObject:extension.lowercaseString];
}

// 条目名消毒：拒绝绝对路径、路径穿越与超长名。列表允许展示，但提取前
// 必须通过本检查（与 FFZipExtract 的历史规则一致）。
+ (BOOL)safeEntryName:(NSString *)name
{
    if (name.length == 0 || name.length > 1024) return NO;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    if ([name rangeOfString:@".."].location != NSNotFound) return NO;
    return YES;
}

#pragma mark - Listing

- (NSArray<FFArchiveEntry *> *)listEntries:(NSString *)archivePath error:(NSError **)error
{
    unzFile zip = unzOpen64(archivePath.fileSystemRepresentation);
    if (!zip) {
        if (error) *error = FFArchiveError(@"无法打开归档（不是有效的 ZIP 或已损坏）");
        return nil;
    }

    NSMutableArray<FFArchiveEntry *> *entries = [NSMutableArray array];
    if (unzGoToFirstFile(zip) != UNZ_OK) {
        // 空归档是合法状态。
        unzClose(zip);
        return entries;
    }

    NSUInteger count = 0;
    do {
        char nameBuffer[2048];
        unz_file_info64 info;
        if (unzGetCurrentFileInfo64(zip, &info, nameBuffer, sizeof(nameBuffer),
                                    NULL, 0, NULL, 0) != UNZ_OK) break;

        NSString *name = [[NSString alloc] initWithBytes:nameBuffer
            length:strlen(nameBuffer) encoding:NSUTF8StringEncoding];
        if (!name.length) continue; // 无法解码的名字跳过

        FFArchiveEntry *entry = [FFArchiveEntry new];
        entry.entryPath = name;
        entry.isDirectory = [name hasSuffix:@"/"];
        entry.size = info.uncompressed_size;
        entry.compressedSize = info.compressed_size;
        [entries addObject:entry];

        if (++count >= kMaxEntries) {
            unzClose(zip);
            if (error) *error = FFArchiveError(
                [NSString stringWithFormat:@"归档条目超过 %lu 个，仅列出部分",
                    (unsigned long)kMaxEntries]);
            return entries;
        }
    } while (unzGoToNextFile(zip) == UNZ_OK);

    unzClose(zip);
    return entries;
}

#pragma mark - Single-entry extraction

- (NSString *)extractEntry:(NSString *)entryName fromArchive:(NSString *)archivePath
               toDirectory:(NSString *)destinationDirectory error:(NSError **)error
{
    if ([entryName hasSuffix:@"/"]) {
        if (error) *error = FFArchiveError(@"目录条目无法直接提取为文件");
        return nil;
    }
    if (![FFArchiveService safeEntryName:entryName]) {
        if (error) *error = FFArchiveError(@"不安全的条目名，已拒绝提取");
        return nil;
    }

    unzFile zip = unzOpen64(archivePath.fileSystemRepresentation);
    if (!zip) {
        if (error) *error = FFArchiveError(@"无法打开归档");
        return nil;
    }

    if (unzLocateFile(zip, entryName.fileSystemRepresentation, 1) != UNZ_OK &&
        unzLocateFile(zip, entryName.fileSystemRepresentation, 2) != UNZ_OK) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"归档中不存在该条目");
        return nil;
    }

    char located[2048];
    unz_file_info64 info;
    if (unzGetCurrentFileInfo64(zip, &info, located, sizeof(located),
                                NULL, 0, NULL, 0) != UNZ_OK) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"读取条目信息失败");
        return nil;
    }

    // 符号链接条目拒绝提取（external attrs 高 16 位为 unix mode）。
    mode_t unixMode = (mode_t)((info.external_fa >> 16) & 0xFFFF);
    if ((unixMode & S_IFMT) == S_IFLNK) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"符号链接条目已拒绝提取");
        return nil;
    }
    // 加密条目明确拒绝（flag bit 0）。
    if (info.flag & 0x1) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"加密条目暂不支持提取");
        return nil;
    }
    if (info.uncompressed_size > kMaxEntrySize) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"条目过大（超过 2 GiB），拒绝提取");
        return nil;
    }
    if (info.compression_method != 0 && info.compression_method != 8) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"该条目使用了不支持的压缩方式");
        return nil;
    }

    NSString *base = entryName.lastPathComponent;
    if (base.length == 0) base = @"entry";
    NSString *destination =
        [destinationDirectory stringByAppendingPathComponent:base];

    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (output < 0) {
        unzClose(zip);
        if (error) *error = FFArchiveError(
            [NSString stringWithFormat:@"创建临时文件失败：%s", strerror(errno)]);
        return nil;
    }

    if (unzOpenCurrentFile(zip) != UNZ_OK) {
        close(output);
        unlink(destination.fileSystemRepresentation);
        unzClose(zip);
        if (error) *error = FFArchiveError(@"打开条目数据失败（可能使用了不支持的格式）");
        return nil;
    }

    static uint8_t readBuffer[64 * 1024];
    unsigned long long producedTotal = 0;
    BOOL ok = YES;
    NSString *failure = nil;
    for (;;) {
        int bytesRead = unzReadCurrentFile(zip, readBuffer, sizeof(readBuffer));
        if (bytesRead == 0) break; // EOF
        if (bytesRead < 0) {
            ok = NO;
            failure = @"解压数据读取失败";
            break;
        }
        ssize_t written = write(output, readBuffer, (size_t)bytesRead);
        if (written != bytesRead) {
            ok = NO;
            failure = [NSString stringWithFormat:@"写入临时文件失败：%s", strerror(errno)];
            break;
        }
        producedTotal += (unsigned long long)bytesRead;
        if (producedTotal > kMaxEntrySize + (1ULL << 20)) { // 容差 1 MiB
            ok = NO;
            failure = @"解压数据超出预期大小，已中止";
            break;
        }
    }

    // minizip 在关闭当前文件时校验 CRC：UNZ_CRCERROR 表示数据损坏。
    if (ok && unzCloseCurrentFile(zip) != UNZ_OK) {
        ok = NO;
        failure = @"CRC 校验失败：数据损坏或不完整";
    }
    if (ok && producedTotal != info.uncompressed_size) {
        ok = NO;
        failure = @"解压后大小与声明不符";
    }

    close(output);
    unzClose(zip);

    if (!ok) {
        unlink(destination.fileSystemRepresentation);
        if (error) *error = FFArchiveError(failure ?: @"提取失败");
        return nil;
    }
    return destination;
}

@end
