#import "FFArchiveService.h"
#import "FFZipExtract.h"
#import "FFLibArchiveBackend.h"
#import "unzip.h"

#import <CoreFoundation/CoreFoundation.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static const unsigned long long kMaxEntrySize = 2ULL * 1024 * 1024 * 1024;
static const NSUInteger kMaxEntries = 100000;
static const NSUInteger kMaxArchiveNameBytes = 64 * 1024;

static NSError *FFArchiveError(NSString *message)
{
    return [NSError errorWithDomain:@"FFArchive" code:-1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"归档读取失败"}];
}

static NSError *FFArchivePasswordError(FFZipExtractErrorCode code, NSString *message)
{
    return [NSError errorWithDomain:FFZipExtractErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSCache<NSString *, NSString *> *FFArchivePasswordCache(void)
{
    static NSCache<NSString *, NSString *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 8;
    });
    return cache;
}

static NSString *FFArchivePasswordKey(NSString *path)
{
    return path.stringByStandardizingPath ?: @"";
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
    if ((info.flag & (1U << 11)) != 0) {
        name = [[NSString alloc] initWithData:rawName encoding:NSUTF8StringEncoding];
    } else {
        name = FFArchiveUnicodePathFromExtra(rawName, extra);
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
        extensions = [NSSet setWithArray:@[
            @"zip", @"ipa", @"xcarchive", @"appex", @"app",
            @"bundle", @"framework", @"war", @"jar", @"crx", @"xpi",
            @"docx", @"xlsx", @"pptx", @"pages", @"numbers", @"key",
            @"epub", @"apk",
        ]];
    });
    return [extensions containsObject:extension.lowercaseString];
}

+ (BOOL)isGenericArchivePath:(NSString *)archivePath
{
    NSString *lower = archivePath.lastPathComponent.lowercaseString;
    if (!lower.length) return NO;
    static NSArray<NSString *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[
            @".tar.gz", @".tar.bz2", @".tar.xz",
            @".tgz", @".tbz", @".tbz2", @".txz",
            @".tar", @".7z", @".rar", @".gz", @".bz2", @".xz"
        ];
    });
    for (NSString *suffix in suffixes)
        if ([lower hasSuffix:suffix]) return YES;
    return NO;
}

+ (BOOL)genericArchiveBackendAvailable
{
    return FFLibArchiveBackendAvailable();
}

+ (BOOL)isArchivePathSupported:(NSString *)archivePath
{
    if ([self isGenericArchivePath:archivePath])
        return [self genericArchiveBackendAvailable];
    return [self isZipFamilyExtension:archivePath.pathExtension];
}

+ (BOOL)isKnownButUnsupportedExtension:(NSString *)extension
{
    (void)extension;
    return NO;
}

+ (NSString *)archiveStemForPath:(NSString *)archivePath
{
    NSString *name = archivePath.lastPathComponent;
    NSString *lower = name.lowercaseString;
    for (NSString *suffix in @[@".tar.gz", @".tar.bz2", @".tar.xz",
                               @".tgz", @".tbz2", @".tbz", @".txz"]) {
        if ([lower hasSuffix:suffix] && name.length > suffix.length)
            return [name substringToIndex:name.length - suffix.length];
    }
    NSString *stem = name.stringByDeletingPathExtension;
    return stem.length ? stem : @"archive";
}

+ (NSString *)cachedPasswordForArchivePath:(NSString *)archivePath
{
    return archivePath.length ? [FFArchivePasswordCache() objectForKey:FFArchivePasswordKey(archivePath)] : nil;
}

+ (void)cachePassword:(NSString *)password forArchivePath:(NSString *)archivePath
{
    if (!password.length || !archivePath.length) return;
    [FFArchivePasswordCache() setObject:[password copy] forKey:FFArchivePasswordKey(archivePath)];
}

+ (void)clearCachedPasswordForArchivePath:(NSString *)archivePath
{
    if (!archivePath.length) return;
    [FFArchivePasswordCache() removeObjectForKey:FFArchivePasswordKey(archivePath)];
}

+ (BOOL)safeEntryName:(NSString *)name
{
    if (name.length == 0 || name.length > 1024) return NO;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    NSString *slashName = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    for (NSString *component in [slashName componentsSeparatedByString:@"/"])
        if ([component isEqualToString:@".."] || [component isEqualToString:@"."]) return NO;
    return YES;
}

- (NSArray<FFArchiveEntry *> *)listEntries:(NSString *)archivePath error:(NSError **)error
{
    if (error) *error = nil;
    if ([FFArchiveService isGenericArchivePath:archivePath]) {
        NSString *password = [FFArchiveService cachedPasswordForArchivePath:archivePath];
        return FFLibArchiveListEntries(archivePath, password, error);
    }

    unzFile zip = unzOpen64(archivePath.fileSystemRepresentation);
    if (!zip) {
        if (error) *error = FFArchiveError(@"无法打开归档（不是有效的 ZIP 或已损坏）");
        return nil;
    }

    NSMutableArray<FFArchiveEntry *> *entries = [NSMutableArray array];
    int rc = unzGoToFirstFile(zip);
    if (rc == UNZ_END_OF_LIST_OF_FILE) {
        unzClose(zip);
        return entries;
    }
    if (rc != UNZ_OK) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"无法读取归档目录");
        return nil;
    }

    do {
        unz_file_info64 info;
        NSString *name = FFArchiveCurrentEntryName(zip, &info);
        if (!name.length) continue;
        FFArchiveEntry *entry = [FFArchiveEntry new];
        entry.entryPath = name;
        entry.isDirectory = [name hasSuffix:@"/"];
        entry.encrypted = (info.flag & 0x1) != 0;
        entry.size = info.uncompressed_size;
        entry.compressedSize = info.compressed_size;
        [entries addObject:entry];
        if (entries.count >= kMaxEntries) {
            unzClose(zip);
            if (error) *error = FFArchiveError(@"归档条目超过 100000 个，仅列出部分");
            return entries;
        }
    } while ((rc = unzGoToNextFile(zip)) == UNZ_OK);

    if (rc != UNZ_END_OF_LIST_OF_FILE) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"归档中央目录读取失败");
        return nil;
    }
    unzClose(zip);
    return entries;
}

- (NSString *)extractEntry:(NSString *)entryName fromArchive:(NSString *)archivePath
               toDirectory:(NSString *)destinationDirectory error:(NSError **)error
{
    return [self extractEntry:entryName fromArchive:archivePath toDirectory:destinationDirectory
        password:[FFArchiveService cachedPasswordForArchivePath:archivePath] error:error];
}

- (NSString *)extractEntry:(NSString *)entryName fromArchive:(NSString *)archivePath
               toDirectory:(NSString *)destinationDirectory password:(NSString *)password
                      error:(NSError **)error
{
    if (error) *error = nil;
    if ([FFArchiveService isGenericArchivePath:archivePath]) {
        NSString *effectivePassword = password.length ? password :
            [FFArchiveService cachedPasswordForArchivePath:archivePath];
        NSString *result = FFLibArchiveExtractEntry(entryName, archivePath,
            destinationDirectory, effectivePassword, error);
        if (result.length && effectivePassword.length)
            [FFArchiveService cachePassword:effectivePassword forArchivePath:archivePath];
        if (!result.length && error && *error &&
            [(*error).domain isEqualToString:FFZipExtractErrorDomain] &&
            (*error).code == FFZipExtractErrorWrongPassword)
            [FFArchiveService clearCachedPasswordForArchivePath:archivePath];
        return result;
    }
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

    BOOL found = NO;
    unz_file_info64 info;
    memset(&info, 0, sizeof(info));
    int rc = unzGoToFirstFile(zip);
    while (rc == UNZ_OK) {
        unz_file_info64 candidateInfo;
        NSString *candidate = FFArchiveCurrentEntryName(zip, &candidateInfo);
        if (candidate.length && [candidate isEqualToString:entryName]) {
            info = candidateInfo;
            found = YES;
            break;
        }
        rc = unzGoToNextFile(zip);
    }
    if (!found) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"归档中不存在该条目");
        return nil;
    }

    mode_t unixMode = (mode_t)((info.external_fa >> 16) & 0xffff);
    if ((unixMode & S_IFMT) == S_IFLNK && unixMode != 0) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"符号链接条目已拒绝提取");
        return nil;
    }
    BOOL encrypted = (info.flag & 0x1) != 0;
    if (encrypted && password.length == 0) {
        unzClose(zip);
        if (error) *error = FFArchivePasswordError(FFZipExtractErrorPasswordRequired,
            @"该 ZIP 已加密，需要输入密码");
        return nil;
    }
    if (info.uncompressed_size > kMaxEntrySize) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"条目过大（超过 2 GiB），拒绝单独提取");
        return nil;
    }
    if (info.compression_method != 0 && info.compression_method != 8) {
        unzClose(zip);
        if (error) *error = FFArchiveError(@"该条目使用了不支持的压缩方式");
        return nil;
    }

    NSString *base = entryName.lastPathComponent.length ? entryName.lastPathComponent : @"entry";
    NSString *destination = [destinationDirectory stringByAppendingPathComponent:base];
    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (output < 0) {
        int saved = errno;
        unzClose(zip);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                @"创建临时文件失败：%s", strerror(saved)]}];
        return nil;
    }

    int openResult = encrypted ? unzOpenCurrentFilePassword(zip, password.UTF8String)
                               : unzOpenCurrentFile(zip);
    if (openResult != UNZ_OK) {
        close(output);
        unlink(destination.fileSystemRepresentation);
        unzClose(zip);
        if (encrypted) {
            [FFArchiveService clearCachedPasswordForArchivePath:archivePath];
            if (error) *error = FFArchivePasswordError(FFZipExtractErrorWrongPassword,
                @"ZIP 密码错误或加密数据已损坏");
        } else if (error) *error = FFArchiveError(@"打开条目数据失败");
        return nil;
    }

    uint8_t *buffer = malloc(64 * 1024);
    BOOL ok = buffer != NULL;
    NSString *failure = buffer ? nil : @"无法分配解压缓冲区";
    unsigned long long produced = 0;
    while (ok) {
        int bytesRead = unzReadCurrentFile(zip, buffer, 64 * 1024);
        if (bytesRead == 0) break;
        if (bytesRead < 0) {
            ok = NO;
            failure = encrypted ? @"ZIP 密码错误或加密数据已损坏" : @"解压数据读取失败";
            break;
        }
        size_t offset = 0;
        while (offset < (size_t)bytesRead) {
            ssize_t written = write(output, buffer + offset, (size_t)bytesRead - offset);
            if (written > 0) { offset += (size_t)written; continue; }
            if (written < 0 && errno == EINTR) continue;
            ok = NO;
            failure = [NSString stringWithFormat:@"写入临时文件失败：%s", strerror(errno ?: EIO)];
            break;
        }
        produced += (unsigned long long)bytesRead;
        if (produced > info.uncompressed_size || produced > kMaxEntrySize) {
            ok = NO;
            failure = @"解压数据超出声明大小，已中止";
        }
    }
    if (buffer) free(buffer);

    int closeResult = unzCloseCurrentFile(zip);
    if (ok && closeResult != UNZ_OK) {
        ok = NO;
        failure = encrypted ? @"ZIP 密码错误或 CRC 校验失败" : @"CRC 校验失败：数据损坏或不完整";
    }
    if (ok && produced != info.uncompressed_size) {
        ok = NO;
        failure = encrypted ? @"ZIP 密码错误或解压大小不符" : @"解压后大小与声明不符";
    }
    close(output);
    unzClose(zip);

    if (!ok) {
        unlink(destination.fileSystemRepresentation);
        if (encrypted) {
            [FFArchiveService clearCachedPasswordForArchivePath:archivePath];
            if (error) *error = FFArchivePasswordError(FFZipExtractErrorWrongPassword,
                failure ?: @"ZIP 密码错误或加密数据已损坏");
        } else if (error && !*error) *error = FFArchiveError(failure ?: @"提取失败");
        return nil;
    }

    if (encrypted && password.length)
        [FFArchiveService cachePassword:password forArchivePath:archivePath];
    return destination;
}

+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
                 toDirectory:(NSString *)destinationDirectory
                    password:(NSString *)password
                  entryNames:(NSArray<NSString *> **)entryNames
                    progress:(void (^)(double, NSString *))progressBlock
                shouldCancel:(BOOL (^)(void))shouldCancel
                       error:(NSError **)error
{
    if ([self isGenericArchivePath:archivePath]) {
        NSString *effectivePassword = password.length ? password :
            [self cachedPasswordForArchivePath:archivePath];
        BOOL ok = FFLibArchiveExtractAll(archivePath, destinationDirectory,
            effectivePassword, entryNames, progressBlock, shouldCancel, error);
        if (ok && effectivePassword.length)
            [self cachePassword:effectivePassword forArchivePath:archivePath];
        if (!ok && error && *error &&
            [(*error).domain isEqualToString:FFZipExtractErrorDomain] &&
            (*error).code == FFZipExtractErrorWrongPassword)
            [self clearCachedPasswordForArchivePath:archivePath];
        return ok;
    }

    return FFZipExtractWithProgressPassword(archivePath, destinationDirectory,
        password, entryNames, progressBlock, shouldCancel, error);
}


@end
