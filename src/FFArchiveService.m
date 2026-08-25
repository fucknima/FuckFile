#import "FFArchiveService.h"

#import "unzip.h"

#import <CoreFoundation/CoreFoundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/stat.h>
#import <zlib.h>

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
static const NSUInteger kMaxArchiveNameBytes = 64 * 1024;

static NSError *FFArchiveError(NSString *message)
{
    return [NSError errorWithDomain:@"FFArchive" code:-1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static uint16_t FFArchiveReadLE16(const uint8_t *bytes)
{
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t FFArchiveReadLE32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] |
        ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) |
        ((uint32_t)bytes[3] << 24);
}

// Info-ZIP Unicode Path extra field (0x7075 / "up"):
//   version[1] + CRC32(raw filename)[4] + UTF-8 path[n]
// A large number of Windows-created Chinese ZIPs keep the central-directory
// filename in GBK/OEM bytes with UTF-8 flag bit 11 clear, then put the actual
// Unicode path here. Ignoring this field made every such entry fail UTF-8
// decoding and the archive browser incorrectly reported "空归档".
static NSString *FFArchiveUnicodePathFromExtra(NSData *rawName, NSData *extra)
{
    const uint8_t *bytes = extra.bytes;
    NSUInteger offset = 0;
    while (offset + 4 <= extra.length) {
        uint16_t headerID = FFArchiveReadLE16(bytes + offset);
        uint16_t payloadSize = FFArchiveReadLE16(bytes + offset + 2);
        offset += 4;
        if ((NSUInteger)payloadSize > extra.length - offset) break;

        if (headerID == 0x7075 && payloadSize >= 5) {
            const uint8_t *payload = bytes + offset;
            if (payload[0] == 1) {
                uint32_t expectedCRC = FFArchiveReadLE32(payload + 1);
                uLong actualCRC = crc32(0L, Z_NULL, 0);
                actualCRC = crc32(actualCRC, rawName.bytes, (uInt)rawName.length);
                if ((uint32_t)actualCRC == expectedCRC) {
                    NSString *unicode = [[NSString alloc]
                        initWithBytes:payload + 5
                        length:(NSUInteger)payloadSize - 5
                        encoding:NSUTF8StringEncoding];
                    if (unicode.length) return unicode;
                }
            }
        }
        offset += payloadSize;
    }
    return nil;
}

// Reads the current minizip record without assuming the raw filename is UTF-8.
// `infoOut` describes exactly the same current entry and can be used directly
// by the extraction path after a decoded-name match.
static NSString *FFArchiveCurrentEntryName(unzFile zip, unz_file_info64 *infoOut)
{
    if (!zip) return nil;

    unz_file_info64 info;
    memset(&info, 0, sizeof(info));
    if (unzGetCurrentFileInfo64(zip, &info, NULL, 0, NULL, 0, NULL, 0) != UNZ_OK)
        return nil;
    if (info.size_filename == 0 || info.size_filename > kMaxArchiveNameBytes ||
        info.size_file_extra > kMaxArchiveNameBytes)
        return nil;

    NSMutableData *rawName = [NSMutableData dataWithLength:(NSUInteger)info.size_filename];
    NSMutableData *extra = [NSMutableData dataWithLength:(NSUInteger)info.size_file_extra];
    if (unzGetCurrentFileInfo64(zip, &info,
            rawName.mutableBytes, (uLong)rawName.length,
            extra.length ? extra.mutableBytes : NULL, (uLong)extra.length,
            NULL, 0) != UNZ_OK)
        return nil;

    NSString *name = nil;
    BOOL declaresUTF8 = (info.flag & (1U << 11)) != 0;
    if (declaresUTF8) {
        name = [[NSString alloc] initWithData:rawName encoding:NSUTF8StringEncoding];
    } else {
        // Prefer the standard Unicode path extra when present and CRC-valid.
        name = FFArchiveUnicodePathFromExtra(rawName, extra);
        // Some writers emit UTF-8 bytes but forget bit 11.
        if (!name.length)
            name = [[NSString alloc] initWithData:rawName encoding:NSUTF8StringEncoding];
        // Common Windows Chinese ZIP fallback (GBK is a subset of GB18030).
        if (!name.length) {
            NSStringEncoding gb18030 = CFStringConvertEncodingToNSStringEncoding(
                kCFStringEncodingGB_18030_2000);
            name = [[NSString alloc] initWithData:rawName encoding:gb18030];
        }
        // Last-resort reversible display path: never silently turn a non-empty
        // archive into an empty one merely because its legacy code page is odd.
        if (!name.length)
            name = [[NSString alloc] initWithData:rawName encoding:NSISOLatin1StringEncoding];
    }

    if (infoOut) *infoOut = info;
    return name;
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
        unz_file_info64 info;
        NSString *name = FFArchiveCurrentEntryName(zip, &info);
        if (!name.length) continue; // malformed entry name only; keep scanning

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

    // Do not use unzLocateFile(entryName.fileSystemRepresentation) here.
    // The UI name may come from a 0x7075 Unicode extra field while the central
    // directory stores completely different GBK/OEM bytes. Walk records and
    // compare the same decoded display path used by listEntries instead.
    BOOL found = NO;
    unz_file_info64 info;
    if (unzGoToFirstFile(zip) == UNZ_OK) {
        do {
            unz_file_info64 candidateInfo;
            NSString *candidate = FFArchiveCurrentEntryName(zip, &candidateInfo);
            if (candidate.length && [candidate isEqualToString:entryName]) {
                info = candidateInfo;
                found = YES;
                break;
            }
        } while (unzGoToNextFile(zip) == UNZ_OK);
    }
    if (!found) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"归档中不存在该条目");
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
