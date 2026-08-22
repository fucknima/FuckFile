#import "FFArchiveService.h"

#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/stat.h>
#import <zlib.h>

// Central-directory parsing mirrors FFZipExtract's safety rules (EOCD
// scan, ZIP64/symlink/unsafe-name rejection). Kept separate from the
// extract-all path on purpose: that code path is stable and hardened,
// and the browser only ever writes one entry at a time into a temp dir.

static uint16_t ArchiveU16(const uint8_t *b) { return (uint16_t)(b[0] | (b[1] << 8)); }
static uint32_t ArchiveU32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
        ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
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

- (NSArray<FFArchiveEntry *> *)listEntries:(NSString *)archivePath error:(NSError **)error
{
    int fd = open(archivePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"无法打开文件：%s", strerror(errno)]}];
        return nil;
    }
    struct stat status = {0};
    if (fstat(fd, &status) != 0 || status.st_size < 22) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
            userInfo:@{NSLocalizedDescriptionKey:@"不是有效的 ZIP 归档"}];
        return nil;
    }
    off_t size = status.st_size;

    size_t tailLength = (size_t)MIN(size, (off_t)(65536 + 22));
    uint8_t tail[65536 + 22];
    ssize_t got = pread(fd, tail, tailLength, size - (off_t)tailLength);
    ssize_t eocd = -1;
    for (ssize_t i = got - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4B &&
            tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
            userInfo:@{NSLocalizedDescriptionKey:@"找不到 ZIP 目录结尾（可能不是 ZIP）"}];
        return nil;
    }
    uint32_t cdOffset = ArchiveU32(tail + eocd + 16);
    uint32_t cdSize = ArchiveU32(tail + eocd + 12);
    uint16_t entryCount = ArchiveU16(tail + eocd + 10);
    if (cdSize == 0 || cdSize > 256 * 1024 * 1024 || entryCount > 100000) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
            userInfo:@{NSLocalizedDescriptionKey:@"ZIP 目录异常或条目过多"}];
        return nil;
    }

    uint8_t *directory = malloc(cdSize);
    if (!directory || pread(fd, directory, cdSize, cdOffset) != (ssize_t)cdSize) {
        free(directory);
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey:@"读取 ZIP 中央目录失败"}];
        return nil;
    }

    NSMutableArray<FFArchiveEntry *> *entries = [NSMutableArray array];
    size_t cursor = 0;
    BOOL truncated = NO;
    while (cursor + 46 <= cdSize) {
        const uint8_t *record = directory + cursor;
        if (ArchiveU32(record) != 0x02014b50) break;
        uint32_t compressedSize = ArchiveU32(record + 20);
        uint32_t uncompressedSize = ArchiveU32(record + 24);
        uint16_t nameLength = ArchiveU16(record + 28);
        uint16_t extraLength = ArchiveU16(record + 30);
        uint16_t commentLength = ArchiveU16(record + 32);
        uint32_t externalAttrs = ArchiveU32(record + 38);
        mode_t unixMode = (externalAttrs >> 16) & 0xFFFF;
        if (cursor + 46u + nameLength + extraLength + commentLength > cdSize) {
            truncated = YES;
            break;
        }
        NSString *name = [[NSString alloc] initWithBytes:record + 46
            length:nameLength encoding:NSUTF8StringEncoding];
        if (!name.length) { cursor += 46 + nameLength + extraLength + commentLength; continue; }

        FFArchiveEntry *entry = [FFArchiveEntry new];
        entry.entryPath = name;
        entry.isDirectory = [name hasSuffix:@"/"] ||
            ((unixMode & S_IFMT) == S_IFDIR && !(unixMode & S_IFLNK));
        entry.size = uncompressedSize == 0xFFFFFFFF ? 0 : uncompressedSize;
        entry.compressedSize = compressedSize == 0xFFFFFFFF ? 0 : compressedSize;
        [entries addObject:entry];

        cursor += 46 + nameLength + extraLength + commentLength;
    }
    free(directory);
    close(fd);
    if (truncated) {
        // 列表截断比整体失败更诚实：返回已解析的部分并提示。
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey:@"中央目录不完整，列表可能被截断"}];
    }
    return entries; // 空归档返回空数组，调用方据此显示"无内容"
}

- (NSString *)extractEntry:(NSString *)entryName fromArchive:(NSString *)archivePath
               toDirectory:(NSString *)destinationDirectory error:(NSError **)error
{
    int fd = open(archivePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) goto fail_open;

    struct stat status = {0};
    if (fstat(fd, &status) != 0) goto fail_io;

    size_t tailLength = (size_t)MIN(status.st_size, (off_t)(65536 + 22));
    uint8_t tailBuffer[65536 + 22];
    ssize_t got = pread(fd, tailBuffer, tailLength, status.st_size - (off_t)tailLength);
    ssize_t eocd = -1;
    for (ssize_t i = got - 22; i >= 0; i--)
        if (tailBuffer[i] == 0x50 && tailBuffer[i + 1] == 0x4B &&
            tailBuffer[i + 2] == 0x05 && tailBuffer[i + 3] == 0x06) { eocd = i; break; }
    if (eocd < 0) goto fail_type;

    uint32_t cdOffset = ArchiveU32(tailBuffer + eocd + 16);
    uint32_t cdSize = ArchiveU32(tailBuffer + eocd + 12);
    if (cdSize == 0 || cdSize > 256 * 1024 * 1024) goto fail_type;

    uint8_t *directory = malloc(cdSize);
    if (!directory || pread(fd, directory, cdSize, cdOffset) != (ssize_t)cdSize)
        goto fail_read_directory;

    // 定位目标条目（精确匹配名称，拒绝目录条目与 ZIP64）。
    const uint8_t *match = NULL;
    size_t scan = 0;
    while (scan + 46 <= cdSize) {
        const uint8_t *record = directory + scan;
        if (ArchiveU32(record) != 0x02014b50) break;
        uint16_t nameLength = ArchiveU16(record + 28);
        uint16_t extraLength = ArchiveU16(record + 30);
        uint16_t commentLength = ArchiveU16(record + 32);
        if (scan + 46u + nameLength + extraLength + commentLength > cdSize) break;
        NSString *name = [[NSString alloc] initWithBytes:record + 46
            length:nameLength encoding:NSUTF8StringEncoding];
        if ([name isEqualToString:entryName]) { match = record; break; }
        scan += 46 + nameLength + extraLength + commentLength;
    }
    free(directory);
    if (!match) goto fail_not_found;

    uint16_t method = ArchiveU16(match + 10);
    uint32_t expectedCrc = ArchiveU32(match + 16);
    uint32_t expectedSize = ArchiveU32(match + 24);
    uint32_t compressedSize = ArchiveU32(match + 20);
    uint16_t nameLength = ArchiveU16(match + 28);
    uint32_t localOffset = ArchiveU32(match + 42);
    if (compressedSize == 0xFFFFFFFF || expectedSize == 0xFFFFFFFF ||
        localOffset == 0xFFFFFFFF)
        goto fail_zip64;
    if (method != 0 && method != 8) goto fail_method;

    {
        // Local header for the true data offset.
        uint8_t local[30] = {0};
        if (pread(fd, local, sizeof(local), localOffset) != sizeof(local) ||
            ArchiveU32(local) != 0x04034b50)
            goto fail_io;
        off_t dataOffset = (off_t)localOffset + 30 +
            ArchiveU16(local + 26) + ArchiveU16(local + 28);

        NSString *base = entryName.lastPathComponent;
        if (base.length == 0) base = @"entry";
        NSString *destination =
            [destinationDirectory stringByAppendingPathComponent:base];
        int output = open(destination.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (output < 0) {
            close(fd);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"创建临时文件失败：%s", strerror(errno)]}];
            return nil;
        }

        uLong crc = crc32(0L, Z_NULL, 0);
        unsigned long long producedTotal = 0;
        z_stream stream = {0};
        if (method == 8 && inflateInit2(&stream, -15) != Z_OK) {
            close(output);
            unlink(destination.fileSystemRepresentation);
            goto fail_io;
        }

        uint32_t remainingCompressed = compressedSize;
        uint8_t input[64 * 1024];
        uint8_t outBuffer[64 * 1024];
        BOOL ok = YES;
        while (ok) {
            if (method == 0) {
                if (remainingCompressed == 0) break;
                size_t chunk = MIN(sizeof(input), (size_t)remainingCompressed);
                if (pread(fd, input, chunk, dataOffset) != (ssize_t)chunk) { ok = NO; break; }
                dataOffset += chunk;
                remainingCompressed -= (uint32_t)chunk;
                crc = crc32(crc, input, (uInt)chunk);
                ssize_t written = write(output, input, chunk);
                if (written != (ssize_t)chunk) { ok = NO; break; }
                producedTotal += chunk;
            } else {
                if (remainingCompressed == 0 && stream.avail_in == 0) break;
                if (stream.avail_in == 0) {
                    size_t chunk = MIN(sizeof(input), (size_t)remainingCompressed);
                    if (chunk == 0) break;
                    if (pread(fd, input, chunk, dataOffset) != (ssize_t)chunk) { ok = NO; break; }
                    dataOffset += chunk;
                    remainingCompressed -= (uint32_t)chunk;
                    stream.next_in = input;
                    stream.avail_in = (uInt)chunk;
                }
                stream.next_out = outBuffer;
                stream.avail_out = sizeof(outBuffer);
                int result = inflate(&stream, Z_NO_FLUSH);
                if (result != Z_OK && result != Z_STREAM_END) { ok = NO; break; }
                size_t produced = sizeof(outBuffer) - stream.avail_out;
                if (produced > 0) {
                    crc = crc32(crc, outBuffer, (uInt)produced);
                    ssize_t written = write(output, outBuffer, produced);
                    if (written != (ssize_t)produced) { ok = NO; break; }
                    producedTotal += produced;
                }
                if (result == Z_STREAM_END) break;
            }
        }
        inflateEnd(&stream);
        close(output);
        if (!ok || producedTotal != expectedSize || (expectedCrc && crc != expectedCrc)) {
            unlink(destination.fileSystemRepresentation);
            goto fail_crc_or_io;
        }
        close(fd);
        return destination;
    }

fail_open:
    if (fd >= 0) close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno ?: EIO
        userInfo:@{NSLocalizedDescriptionKey:@"无法打开归档"}];
    return nil;
fail_type:
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
        userInfo:@{NSLocalizedDescriptionKey:@"不是有效的 ZIP 归档"}];
    return nil;
fail_read_directory:
    free(directory);
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
        userInfo:@{NSLocalizedDescriptionKey:@"读取 ZIP 中央目录失败"}];
    return nil;
fail_not_found:
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT
        userInfo:@{NSLocalizedDescriptionKey:@"归档中不存在该条目"}];
    return nil;
fail_zip64:
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
        userInfo:@{NSLocalizedDescriptionKey:@"该条目使用 ZIP64 扩展，暂不支持"}];
    return nil;
fail_method:
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP
        userInfo:@{NSLocalizedDescriptionKey:@"该条目使用了不支持的压缩方式"}];
    return nil;
fail_crc_or_io:
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
        userInfo:@{NSLocalizedDescriptionKey:@"提取失败：数据损坏或不完整（CRC 校验未通过）"}];
    return nil;
fail_io:
    close(fd);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
        userInfo:@{NSLocalizedDescriptionKey:@"归档读取失败"}];
    return nil;
}

@end
