#import "FFZipExtract.h"

#import "unzip.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

NSErrorDomain const FFZipExtractErrorDomain = @"FFZipExtract";

#define FFX_MAX_ENTRIES 100000
#define FFX_MAX_TOTAL (4ULL * 1024 * 1024 * 1024)
#define FFX_MAX_NAME_BYTES (64U * 1024U)

static NSError *FFXError(FFZipExtractErrorCode code, NSString *message)
{
    return [NSError errorWithDomain:FFZipExtractErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"解压失败"}];
}

static void FFXSetError(NSError **error, FFZipExtractErrorCode code, NSString *message)
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
                        initWithBytes:payload + 5 length:(NSUInteger)payloadSize - 5
                        encoding:NSUTF8StringEncoding];
                    if (unicode.length) return unicode;
                }
            }
        }
        offset += payloadSize;
    }
    return nil;
}

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
    if ((info.flag & (1U << 11)) != 0) {
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
    if ([name rangeOfString:@"\0"].location != NSNotFound) return NO;
    NSString *slashName = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    for (NSString *component in [slashName componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@".."] || [component isEqualToString:@"."]) return NO;
    }
    return YES;
}

static BOOL FFXEnsureParent(NSString *directory, NSString *relative, NSError **error)
{
    NSString *parent = [[directory stringByAppendingPathComponent:relative]
        stringByDeletingLastPathComponent];
    NSError *mkdirError = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:&mkdirError];
    if (!ok && error) *error = mkdirError ?: FFXError(FFZipExtractErrorIO,
        @"创建解压目标目录失败");
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
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                @"写入解压文件失败：%@ (%s)", destination.lastPathComponent, strerror(saved)]}];
        return NO;
    }
    return YES;
}

@interface FFXEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned long long uncompressedSize;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) BOOL encrypted;
@property(nonatomic) unz64_file_pos position;
@end
@implementation FFXEntry
@end

BOOL FFZipExtract(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> **entryNames, NSError **error)
{
    return FFZipExtractWithProgressPassword(archivePath, destDir, nil,
        entryNames, nil, nil, error);
}

BOOL FFZipExtractWithProgress(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> **entryNames,
                  void (^progressBlock)(double, NSString *),
                  BOOL (^shouldCancel)(void), NSError **error)
{
    return FFZipExtractWithProgressPassword(archivePath, destDir, nil,
        entryNames, progressBlock, shouldCancel, error);
}

static BOOL FFXCommitTempDirectory(NSString *tempDir, NSString *destDir, NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backup = [NSString stringWithFormat:@"%@.old%@", destDir,
        [NSUUID.UUID.UUIDString substringToIndex:8]];
    BOOL destinationExists = [fm fileExistsAtPath:destDir];
    if (destinationExists) {
        NSError *moveError = nil;
        if (![fm moveItemAtPath:destDir toPath:backup error:&moveError]) {
            if (error) *error = moveError ?: FFXError(FFZipExtractErrorIO,
                @"无法暂存原解压目录");
            return NO;
        }
    }

    NSError *commitError = nil;
    if (![fm moveItemAtPath:tempDir toPath:destDir error:&commitError]) {
        if (destinationExists) [fm moveItemAtPath:backup toPath:destDir error:nil];
        if (error) *error = commitError ?: FFXError(FFZipExtractErrorIO,
            @"提交解压目录失败");
        return NO;
    }
    if (destinationExists) [fm removeItemAtPath:backup error:nil];
    return YES;
}

BOOL FFZipExtractWithProgressPassword(NSString *archivePath, NSString *destDir,
                  NSString *password, NSArray<NSString *> **entryNames,
                  void (^progressBlock)(double, NSString *),
                  BOOL (^shouldCancel)(void), NSError **error)
{
    if (entryNames) *entryNames = nil;
    if (error) *error = nil;
    if (!archivePath.length || !destDir.length) {
        FFXSetError(error, FFZipExtractErrorInvalidArchive, @"归档或目标路径无效");
        return NO;
    }

    unzFile zip = unzOpen64(archivePath.fileSystemRepresentation);
    if (!zip) {
        FFXSetError(error, FFZipExtractErrorInvalidArchive,
            @"无法打开归档（不是有效的 ZIP 或已损坏）");
        return NO;
    }

    NSMutableArray<FFXEntry *> *plan = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    unsigned long long totalUncompressed = 0;
    BOOL containsEncrypted = NO;

    int rc = unzGoToFirstFile(zip);
    while (rc == UNZ_OK) {
        unz_file_info64 info;
        unz64_file_pos position;
        memset(&position, 0, sizeof(position));
        NSString *name = FFXCurrentEntryName(zip, &info, &position);
        if (!name.length) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorInvalidArchive,
                @"归档包含无法解码的文件名条目");
            return NO;
        }
        if (!FFXSafeEntryName(name)) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorUnsafeEntry,
                [NSString stringWithFormat:@"不安全的归档路径，已拒绝解压：%@", name]);
            return NO;
        }

        BOOL directory = [name hasSuffix:@"/"];
        BOOL encrypted = (info.flag & 0x1) != 0;
        containsEncrypted |= encrypted;
        mode_t unixMode = (mode_t)((info.external_fa >> 16) & 0xffff);
        if ((unixMode & S_IFMT) == S_IFLNK && unixMode != 0) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorUnsafeEntry,
                @"归档包含符号链接条目，已拒绝解压");
            return NO;
        }
        if (!directory && info.compression_method != 0 && info.compression_method != 8) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorUnsupportedCompression,
                [NSString stringWithFormat:@"不支持的 ZIP 压缩方式：%lu",
                    (unsigned long)info.compression_method]);
            return NO;
        }
        if ([seen containsObject:name]) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorUnsafeEntry,
                [NSString stringWithFormat:@"归档包含重复路径，已拒绝覆盖：%@", name]);
            return NO;
        }
        [seen addObject:name];

        if (info.uncompressed_size > FFX_MAX_TOTAL ||
            totalUncompressed > FFX_MAX_TOTAL - info.uncompressed_size) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorTooLarge,
                @"归档解压后体积过大（超过 4 GiB 安全上限）");
            return NO;
        }

        FFXEntry *entry = [FFXEntry new];
        entry.name = name;
        entry.uncompressedSize = info.uncompressed_size;
        entry.isDirectory = directory;
        entry.encrypted = encrypted;
        entry.position = position;
        [plan addObject:entry];
        totalUncompressed += info.uncompressed_size;

        if (plan.count > FFX_MAX_ENTRIES) {
            unzClose(zip);
            FFXSetError(error, FFZipExtractErrorTooLarge,
                @"归档条目过多（超过 100000 个）");
            return NO;
        }
        rc = unzGoToNextFile(zip);
    }

    if (rc != UNZ_END_OF_LIST_OF_FILE && rc != UNZ_OK) {
        unzClose(zip);
        FFXSetError(error, FFZipExtractErrorInvalidArchive,
            @"读取归档目录失败（文件可能已损坏）");
        return NO;
    }
    if (plan.count == 0) {
        unzClose(zip);
        FFXSetError(error, FFZipExtractErrorInvalidArchive,
            @"归档为空或无法解析任何条目");
        return NO;
    }
    if (containsEncrypted && password.length == 0) {
        unzClose(zip);
        FFXSetError(error, FFZipExtractErrorPasswordRequired, @"该 ZIP 已加密，需要输入密码");
        return NO;
    }

    NSString *parent = destDir.stringByDeletingLastPathComponent;
    NSError *parentError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:&parentError]) {
        unzClose(zip);
        if (error) *error = parentError;
        return NO;
    }
    NSString *tempDir = [[parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.tmp", destDir.lastPathComponent,
            [NSUUID.UUID.UUIDString substringToIndex:8]]] stringByStandardizingPath];
    NSError *tempError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:tempDir
        withIntermediateDirectories:YES attributes:nil error:&tempError]) {
        unzClose(zip);
        if (error) *error = tempError ?: FFXError(FFZipExtractErrorIO,
            @"无法创建解压临时目录");
        return NO;
    }

    NSMutableArray<NSString *> *extracted = [NSMutableArray array];
    unsigned long long producedTotal = 0;
    BOOL ok = YES;
    uint8_t *buffer = malloc(256 * 1024);
    if (!buffer) {
        if (error) *error = FFXError(FFZipExtractErrorIO, @"无法分配解压缓冲区");
        ok = NO;
    }

    for (FFXEntry *entry in plan) {
        if (!ok) break;
        if (shouldCancel && shouldCancel()) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"解压已取消"}];
            ok = NO;
            break;
        }
        if (entry.isDirectory) {
            NSError *mkdirError = nil;
            if (![NSFileManager.defaultManager createDirectoryAtPath:
                [tempDir stringByAppendingPathComponent:entry.name]
                withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
                if (error) *error = mkdirError;
                ok = NO;
            }
            continue;
        }
        if (!FFXEnsureParent(tempDir, entry.name, error)) {
            ok = NO;
            break;
        }
        unz64_file_pos position = entry.position;
        if (unzGoToFilePos64(zip, &position) != UNZ_OK) {
            FFXSetError(error, FFZipExtractErrorIO,
                [NSString stringWithFormat:@"无法定位归档条目：%@", entry.name]);
            ok = NO;
            break;
        }

        int openResult = entry.encrypted
            ? unzOpenCurrentFilePassword(zip, password.UTF8String)
            : unzOpenCurrentFile(zip);
        if (openResult != UNZ_OK) {
            FFXSetError(error, entry.encrypted ? FFZipExtractErrorWrongPassword : FFZipExtractErrorInvalidArchive,
                entry.encrypted ? @"ZIP 密码错误或加密数据已损坏" :
                    [NSString stringWithFormat:@"无法打开归档条目：%@", entry.name]);
            ok = NO;
            break;
        }

        NSString *destination = [tempDir stringByAppendingPathComponent:entry.name];
        int output = open(destination.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (output < 0) {
            int saved = errno;
            unzCloseCurrentFile(zip);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
                userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                    @"创建解压文件失败：%@ (%s)", entry.name, strerror(saved)]}];
            ok = NO;
            break;
        }

        unsigned long long entryProduced = 0;
        BOOL entryOK = YES;
        for (;;) {
            if (shouldCancel && shouldCancel()) {
                if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                    code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"解压已取消"}];
                entryOK = NO;
                break;
            }
            int bytesRead = unzReadCurrentFile(zip, buffer, 256 * 1024);
            if (bytesRead == 0) break;
            if (bytesRead < 0) {
                FFXSetError(error, entry.encrypted ? FFZipExtractErrorWrongPassword : FFZipExtractErrorIO,
                    entry.encrypted ? @"ZIP 密码错误或加密数据已损坏" :
                        [NSString stringWithFormat:@"读取压缩数据失败：%@", entry.name]);
                entryOK = NO;
                break;
            }
            if (!FFXWriteAll(output, buffer, (size_t)bytesRead, destination, error)) {
                entryOK = NO;
                break;
            }
            entryProduced += (unsigned long long)bytesRead;
            producedTotal += (unsigned long long)bytesRead;
            if (entryProduced > entry.uncompressedSize || producedTotal > FFX_MAX_TOTAL) {
                FFXSetError(error, FFZipExtractErrorTooLarge, @"解压数据超出声明大小，已中止");
                entryOK = NO;
                break;
            }
            if (progressBlock) progressBlock(totalUncompressed
                ? (double)producedTotal / (double)totalUncompressed : 0, entry.name);
        }
        close(output);
        int closeResult = unzCloseCurrentFile(zip);
        if (entryOK && closeResult != UNZ_OK) {
            FFXSetError(error, entry.encrypted ? FFZipExtractErrorWrongPassword : FFZipExtractErrorInvalidArchive,
                entry.encrypted ? @"ZIP 密码错误或 CRC 校验失败" :
                    [NSString stringWithFormat:@"CRC 校验失败：%@", entry.name]);
            entryOK = NO;
        }
        if (entryOK && entryProduced != entry.uncompressedSize) {
            FFXSetError(error, entry.encrypted ? FFZipExtractErrorWrongPassword : FFZipExtractErrorInvalidArchive,
                entry.encrypted ? @"ZIP 密码错误或解压大小不符" :
                    [NSString stringWithFormat:@"解压后大小与声明不符：%@", entry.name]);
            entryOK = NO;
        }
        if (!entryOK) {
            unlink(destination.fileSystemRepresentation);
            ok = NO;
            break;
        }
        [extracted addObject:entry.name];
    }

    if (buffer) free(buffer);
    unzClose(zip);

    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
        return NO;
    }
    if (!FFXCommitTempDirectory(tempDir, destDir, error)) {
        [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
        return NO;
    }

    if (entryNames) *entryNames = [extracted copy];
    if (progressBlock) progressBlock(1.0, @"");
    return YES;
}
