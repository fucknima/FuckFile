#import "FFZipExtract.h"

#import "unzip.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

// Extracts a zip-family archive via minizip (third_party/minizip).
// Function signature preserved from the original implementation so the
// task center keeps calling this unchanged.
//
// Safety rules:
//  - entry count cap (100k) and total uncompressed size cap (4 GiB)
//  - entry-name sanitization (".." / absolute paths rejected)
//  - duplicate decoded entry names rejected
//  - symlink / encrypted / unsupported-compression entries rejected
//  - extraction into a sibling temp dir, committed with a rename;
//    failed/cancelled runs clean up, existing destinations are backed
//    up to ".old*" and restored on any failure
//
// Compatibility:
//  - UTF-8 flag bit 11
//  - Info-ZIP Unicode Path extra field 0x7075
//  - UTF-8-without-flag writers
//  - GB18030/GBK Windows ZIP fallback
//  - Latin-1 reversible last-resort display path

#define FFX_MAX_ENTRIES 100000
#define FFX_MAX_TOTAL (4ULL * 1024 * 1024 * 1024)
#define FFX_MAX_NAME_BYTES (64U * 1024U)

static NSError *FFXError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"FFZipExtract" code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"解压失败"}];
}

static void FFXSetError(NSError **error, NSInteger code, NSString *message)
{
    if (error) *error = FFXError(code, message);
}

static uint16_t FFXReadLE16(const uint8_t *bytes)
{
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t FFXReadLE32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] |
        ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) |
        ((uint32_t)bytes[3] << 24);
}

// Info-ZIP Unicode Path extra field (0x7075):
// version[1] + CRC32(raw filename)[4] + UTF-8 path[n].
static NSString *FFXUnicodePathFromExtra(NSData *rawName, NSData *extra)
{
    const uint8_t *bytes = extra.bytes;
    NSUInteger offset = 0;
    while (offset + 4 <= extra.length) {
        uint16_t headerID = FFXReadLE16(bytes + offset);
        uint16_t payloadSize = FFXReadLE16(bytes + offset + 2);
        offset += 4;
        if ((NSUInteger)payloadSize > extra.length - offset) break;

        if (headerID == 0x7075 && payloadSize >= 5) {
            const uint8_t *payload = bytes + offset;
            if (payload[0] == 1) {
                uint32_t expectedCRC = FFXReadLE32(payload + 1);
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

// Decode the current central-directory record exactly like FFArchiveService.
// Also captures its minizip position so extraction can return to the exact raw
// record later. This is essential for Windows ZIPs whose displayed Unicode
// path differs from the GBK/OEM bytes stored in the central directory.
static NSString *FFXCurrentEntryName(unzFile zip, unz_file_info64 *infoOut,
                                     unz64_file_pos *positionOut)
{
    if (!zip) return nil;

    unz_file_info64 info;
    memset(&info, 0, sizeof(info));
    if (unzGetCurrentFileInfo64(zip, &info, NULL, 0, NULL, 0, NULL, 0) != UNZ_OK)
        return nil;
    if (info.size_filename == 0 || info.size_filename > FFX_MAX_NAME_BYTES ||
        info.size_file_extra > FFX_MAX_NAME_BYTES)
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
        name = FFXUnicodePathFromExtra(rawName, extra);
        if (!name.length)
            name = [[NSString alloc] initWithData:rawName encoding:NSUTF8StringEncoding];
        if (!name.length) {
            NSStringEncoding gb18030 = CFStringConvertEncodingToNSStringEncoding(
                kCFStringEncodingGB_18030_2000);
            name = [[NSString alloc] initWithData:rawName encoding:gb18030];
        }
        if (!name.length)
            name = [[NSString alloc] initWithData:rawName encoding:NSISOLatin1StringEncoding];
    }

    if (!name.length) return nil;
    if (positionOut && unzGetFilePos64(zip, positionOut) != UNZ_OK) return nil;
    if (infoOut) *infoOut = info;
    return name;
}

static BOOL FFXSafeEntryName(NSString *name)
{
    if (name.length == 0 || name.length > 1024) return NO;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    if ([name rangeOfString:@".."].location != NSNotFound) return NO;
    return YES;
}

static BOOL FFXEnsureParent(NSString *directory, NSString *relative, NSError **error)
{
    NSString *parent = [directory stringByAppendingPathComponent:relative]
        .stringByDeletingLastPathComponent;
    NSError *mkdirError = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:&mkdirError];
    if (!ok && error) *error = mkdirError ?: FFXError(EIO, @"创建解压目标目录失败");
    return ok;
}

static BOOL FFXWriteAll(int fd, const uint8_t *bytes, size_t length,
                        NSString *destination, NSError **error)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, bytes + offset, length - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        int saved = errno ?: EIO;
        FFXSetError(error, saved,
            [NSString stringWithFormat:@"写入解压文件失败：%@ (%s)",
                destination.lastPathComponent, strerror(saved)]);
        return NO;
    }
    return YES;
}

BOOL FFZipExtract(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  NSError * _Nullable * _Nullable error)
{
    return FFZipExtractWithProgress(archivePath, destDir, entryNames, nil, nil, error);
}

@interface FFXEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned long long uncompressedSize;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) unz64_file_pos position;
@end

@implementation FFXEntry
@end

BOOL FFZipExtractWithProgress(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> **entryNames,
                  void (^progressBlock)(double, NSString *),
                  BOOL (^shouldCancel)(void),
                  NSError **error)
{
    if (entryNames) *entryNames = nil;
    if (error) *error = nil;

    unzFile zip = unzOpen64(archivePath.fileSystemRepresentation);
    if (!zip) {
        FFXSetError(error, EFTYPE, @"无法打开归档（不是有效的 ZIP 或已损坏）");
        return NO;
    }

    // ---- 第一遍：收集条目、累计总量，执行安全与兼容性检查 ----
    NSMutableArray<FFXEntry *> *plan = [NSMutableArray array];
    unsigned long long totalUncompressed = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    int rc = unzGoToFirstFile(zip);
    while (rc == UNZ_OK) {
        unz_file_info64 info;
        unz64_file_pos position;
        memset(&position, 0, sizeof(position));
        NSString *name = FFXCurrentEntryName(zip, &info, &position);
        if (!name.length) {
            unzClose(zip);
            FFXSetError(error, EFTYPE, @"归档包含无法解码的文件名条目");
            return NO;
        }

        BOOL isDirectory = [name hasSuffix:@"/"];
        if (!FFXSafeEntryName(name)) {
            unzClose(zip);
            FFXSetError(error, EFTYPE,
                [NSString stringWithFormat:@"不安全的归档路径，已拒绝解压：%@", name]);
            return NO;
        }

        mode_t unixMode = (mode_t)((info.external_fa >> 16) & 0xFFFF);
        if ((unixMode & S_IFMT) == S_IFLNK && unixMode != 0) {
            unzClose(zip);
            FFXSetError(error, EFTYPE, @"归档包含符号链接条目，已拒绝解压");
            return NO;
        }
        if (info.flag & 0x1) {
            unzClose(zip);
            FFXSetError(error, ENOTSUP, @"加密 ZIP 暂不支持解压");
            return NO;
        }
        if (!isDirectory && info.compression_method != 0 && info.compression_method != 8) {
            unzClose(zip);
            FFXSetError(error, ENOTSUP,
                [NSString stringWithFormat:@"不支持的 ZIP 压缩方式：%lu",
                    (unsigned long)info.compression_method]);
            return NO;
        }
        if ([seen containsObject:name]) {
            unzClose(zip);
            FFXSetError(error, EFTYPE,
                [NSString stringWithFormat:@"归档包含重复路径，已拒绝覆盖：%@", name]);
            return NO;
        }
        [seen addObject:name];

        if (info.uncompressed_size > FFX_MAX_TOTAL ||
            totalUncompressed > FFX_MAX_TOTAL - info.uncompressed_size) {
            unzClose(zip);
            FFXSetError(error, EFBIG, @"归档解压后体积过大（超过 4 GiB）");
            return NO;
        }

        FFXEntry *entry = [FFXEntry new];
        entry.name = name;
        entry.uncompressedSize = info.uncompressed_size;
        entry.isDirectory = isDirectory;
        entry.position = position;
        [plan addObject:entry];
        totalUncompressed += info.uncompressed_size;

        if (plan.count > FFX_MAX_ENTRIES) {
            unzClose(zip);
            FFXSetError(error, EFBIG, @"归档条目过多（超过 100000 个）");
            return NO;
        }
        rc = unzGoToNextFile(zip);
    }

    if (rc != UNZ_END_OF_LIST_OF_FILE && rc != UNZ_OK) {
        unzClose(zip);
        FFXSetError(error, EIO, @"读取归档目录失败（文件可能已损坏）");
        return NO;
    }
    if (plan.count == 0) {
        unzClose(zip);
        FFXSetError(error, EFTYPE, @"归档为空或无法解析任何条目");
        return NO;
    }

    // ---- 提取到兄弟临时目录，成功后 rename 提交 ----
    NSString *tempDir = [[destDir.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.%@.tmp", destDir.lastPathComponent,
                [[[NSUUID UUID] UUIDString] substringToIndex:8]]]
        stringByStandardizingPath];
    NSError *tempError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:tempDir
        withIntermediateDirectories:YES attributes:nil error:&tempError]) {
        unzClose(zip);
        if (error) *error = tempError ?: FFXError(EIO, @"无法创建解压临时目录");
        return NO;
    }

    NSMutableArray<NSString *> *extracted = [NSMutableArray array];
    unsigned long long producedTotal = 0;
    BOOL ok = YES;

    for (FFXEntry *entry in plan) {
        if (shouldCancel && shouldCancel()) {
            FFXSetError(error, NSUserCancelledError, @"解压已取消");
            ok = NO;
            break;
        }

        if (entry.isDirectory) {
            NSError *mkdirError = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:
                [tempDir stringByAppendingPathComponent:entry.name]
                withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
                if (error) *error = mkdirError ?: FFXError(EIO,
                    [NSString stringWithFormat:@"创建目录失败：%@", entry.name]);
                ok = NO;
                break;
            }
            continue;
        }

        if (!FFXEnsureParent(tempDir, entry.name, error)) {
            ok = NO;
            break;
        }
        if (unzGoToFilePos64(zip, &entry.position) != UNZ_OK) {
            FFXSetError(error, EIO,
                [NSString stringWithFormat:@"无法定位归档条目：%@", entry.name]);
            ok = NO;
            break;
        }
        if (unzOpenCurrentFile(zip) != UNZ_OK) {
            FFXSetError(error, EFTYPE,
                [NSString stringWithFormat:@"无法打开归档条目：%@", entry.name]);
            ok = NO;
            break;
        }

        NSString *destination = [tempDir stringByAppendingPathComponent:entry.name];
        int output = open(destination.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (output < 0) {
            int saved = errno;
            unzCloseCurrentFile(zip);
            FFXSetError(error, saved,
                [NSString stringWithFormat:@"创建解压文件失败：%@ (%s)",
                    entry.name, strerror(saved)]);
            ok = NO;
            break;
        }

        static uint8_t buffer[64 * 1024];
        unsigned long long entryProduced = 0;
        for (;;) {
            int bytesRead = unzReadCurrentFile(zip, buffer, sizeof(buffer));
            if (bytesRead == 0) break;
            if (bytesRead < 0) {
                FFXSetError(error, EIO,
                    [NSString stringWithFormat:@"读取压缩数据失败：%@", entry.name]);
                ok = NO;
                break;
            }
            if (!FFXWriteAll(output, buffer, (size_t)bytesRead, destination, error)) {
                ok = NO;
                break;
            }
            entryProduced += (unsigned long long)bytesRead;
            producedTotal += (unsigned long long)bytesRead;
            if (entryProduced > entry.uncompressedSize || producedTotal > FFX_MAX_TOTAL) {
                FFXSetError(error, EFBIG, @"解压数据超出归档声明大小，已中止");
                ok = NO;
                break;
            }
        }
        close(output);

        int closeRC = unzCloseCurrentFile(zip);
        if (ok && closeRC != UNZ_OK) {
            FFXSetError(error, EIO,
                [NSString stringWithFormat:@"CRC 校验失败：%@", entry.name]);
            ok = NO;
        }
        if (ok && entryProduced != entry.uncompressedSize) {
            FFXSetError(error, EIO,
                [NSString stringWithFormat:@"解压后大小与声明不符：%@", entry.name]);
            ok = NO;
        }

        if (!ok) {
            unlink(destination.fileSystemRepresentation);
            break;
        }

        [extracted addObject:entry.name];
        if (progressBlock)
            progressBlock(totalUncompressed > 0 ?
                (double)producedTotal / (double)totalUncompressed : 0.0,
                entry.name);
    }

    unzClose(zip);

    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
        return NO;
    }

    // ---- 提交：备份旧目录 → 放入新目录 → 清理备份；失败恢复原状 ----
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *backupPath = nil;
    if ([manager fileExistsAtPath:destDir]) {
        backupPath = [NSString stringWithFormat:@"%@.old%@", destDir,
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        if (![manager moveItemAtPath:destDir toPath:backupPath error:error]) {
            [manager removeItemAtPath:tempDir error:nil];
            return NO;
        }
    }
    NSError *moveError = nil;
    if (![manager moveItemAtPath:tempDir toPath:destDir error:&moveError]) {
        if (backupPath)
            [manager moveItemAtPath:backupPath toPath:destDir error:nil];
        [manager removeItemAtPath:tempDir error:nil];
        if (error) *error = moveError ?: FFXError(EIO, @"提交解压目录失败");
        return NO;
    }
    if (backupPath)
        [manager removeItemAtPath:backupPath error:nil];

    if (entryNames) *entryNames = extracted;
    return YES;
}
