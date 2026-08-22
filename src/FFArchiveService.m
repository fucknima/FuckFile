#import "FFArchiveService.h"

#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/stat.h>
#import <zlib.h>

// Read-only zip access for the archive browser.
//
// Primary backend: EOCD + central directory (store + deflate, CRC-checked,
// ZIP64/symlink/unsafe names rejected). Fallback: when the central
// directory cannot be walked (exotic writers, damaged tail), entries are
// recovered by scanning local file headers (PK\x03\x04); single-entry
// extraction works through the same fallback so 提取 never dead-ends.
//
// tar/gz/7z/rar/xz/bz2 are NOT parseable by this build — callers must
// surface "暂不支持" instead of pretending success. .deb is deliberately
// excluded everywhere.

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

#pragma mark - Local file header scan（中央目录不可用时兜底）

// Scans PK\x03\x04 local file headers across the whole file. Data-
// descriptor entries (bit 3) carry zero sizes in their headers; those
// report size 0 here. Names are sanity-checked so compressed-data false
// positives are mostly rejected; duplicates are dropped.
+ (NSMutableArray<FFArchiveEntry *> *)scanLocalHeaders:(int)fd fileSize:(off_t)size
{
    NSMutableArray<FFArchiveEntry *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    const size_t windowSize = 256 * 1024;
    uint8_t *window = malloc(windowSize);
    if (!window) return results;

    off_t pos = 0;
    while (pos < size && results.count < 100000) {
        ssize_t got = pread(fd, window, windowSize, pos);
        if (got < 30) break;
        off_t nextPos = pos + got - 3; // keep 3-byte overlap for split signatures

        for (ssize_t i = 0; i + 30 <= got; i++) {
            if (window[i] != 0x50 || window[i + 1] != 0x4B ||
                window[i + 2] != 0x03 || window[i + 3] != 0x04) continue;
            uint16_t flags = ArchiveU16(window + i + 6);
            uint32_t csize = ArchiveU32(window + i + 18);
            uint32_t usize = ArchiveU32(window + i + 22);
            uint16_t nameLength = ArchiveU16(window + i + 26);
            uint16_t extraLength = ArchiveU16(window + i + 28);
            if ((uint64_t)i + 30u + nameLength > (uint64_t)got) continue;
            NSString *name = [[NSString alloc] initWithBytes:window + i + 30
                length:nameLength encoding:NSUTF8StringEncoding];
            // Sanity checks: real names are short, non-empty, no control chars.
            if (name.length == 0 || name.length > 512) continue;
            BOOL plausible = YES;
            for (NSUInteger c = 0; c < name.length; c++) {
                unichar ch = [name characterAtIndex:c];
                if (ch < 0x20 && ch != '\n' && ch != '\r' && ch != '\t') {
                    plausible = NO;
                    break;
                }
            }
            if (!plausible) continue;
            if ([seen containsObject:name]) continue;
            [seen addObject:name];

            FFArchiveEntry *entry = [FFArchiveEntry new];
            entry.entryPath = name;
            entry.isDirectory = [name hasSuffix:@"/"];
            entry.size = usize == 0xFFFFFFFF ? 0 : usize;
            entry.compressedSize = csize == 0xFFFFFFFF ? 0 : csize;
            [results addObject:entry];

            // Known-size entries: skip their payload to avoid matching
            // signature bytes inside compressed data.
            if (!(flags & 0x8) && csize > 0 && csize < windowSize) {
                i += 30 + nameLength + extraLength + csize;
            }
        }
        pos = nextPos;
    }
    free(window);
    return results;
}

#pragma mark - Listing

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
    uint8_t tailBuffer[65536 + 22];
    ssize_t got = pread(fd, tailBuffer, tailLength, size - (off_t)tailLength);
    ssize_t eocd = -1;
    for (ssize_t i = got - 22; i >= 0; i--) {
        if (tailBuffer[i] == 0x50 && tailBuffer[i + 1] == 0x4B &&
            tailBuffer[i + 2] == 0x05 && tailBuffer[i + 3] == 0x06) {
            eocd = i;
            break;
        }
    }

    NSMutableArray<FFArchiveEntry *> *entries = [NSMutableArray array];
    BOOL truncated = NO;

    if (eocd >= 0) {
        uint32_t cdOffset = ArchiveU32(tailBuffer + eocd + 16);
        uint32_t cdSize = ArchiveU32(tailBuffer + eocd + 12);
        if (cdSize > 0 && cdSize <= 256 * 1024 * 1024 &&
            cdOffset < (uint64_t)size) {
            uint8_t *directory = malloc(cdSize);
            if (directory && pread(fd, directory, cdSize, cdOffset) == (ssize_t)cdSize) {
                size_t cursor = 0;
                while (cursor + 46 <= cdSize) {
                    const uint8_t *record = directory + cursor;
                    if (ArchiveU32(record) != 0x02014b50) break;
                    uint16_t nameLength = ArchiveU16(record + 28);
                    uint16_t extraLength = ArchiveU16(record + 30);
                    uint16_t commentLength = ArchiveU16(record + 32);
                    if ((uint64_t)cursor + 46u + nameLength + extraLength +
                            commentLength > cdSize) {
                        truncated = YES;
                        break;
                    }
                    NSString *name = [[NSString alloc] initWithBytes:record + 46
                        length:nameLength encoding:NSUTF8StringEncoding];
                    if (!name.length) {
                        cursor += 46 + nameLength + extraLength + commentLength;
                        continue;
                    }
                    uint32_t externalAttrs = ArchiveU32(record + 38);
                    mode_t unixMode = (externalAttrs >> 16) & 0xFFFF;
                    FFArchiveEntry *entry = [FFArchiveEntry new];
                    entry.entryPath = name;
                    entry.isDirectory = [name hasSuffix:@"/"] ||
                        ((unixMode & S_IFMT) == S_IFDIR && !(unixMode & S_IFLNK));
                    entry.size = ArchiveU32(record + 24) == 0xFFFFFFFF ?
                        0 : ArchiveU32(record + 24);
                    entry.compressedSize = ArchiveU32(record + 20) == 0xFFFFFFFF ?
                        0 : ArchiveU32(record + 20);
                    [entries addObject:entry];
                    cursor += 46 + nameLength + extraLength + commentLength;
                }
            } else {
                truncated = YES;
            }
            free(directory);
        } else {
            truncated = YES; // ZIP64 或异常目录尺寸：走本地头兜底
        }
    } else {
        truncated = YES; // 没有 EOCD：走本地头兜底
    }

    // 中央目录解析不出任何条目时，退回本地文件头扫描 —— 真实世界的归档
    // 写入器五花八门，宁可慢一点也不能给用户一个空白列表。
    if (entries.count == 0) {
        NSMutableArray *recovered = [FFArchiveService scanLocalHeaders:fd fileSize:size];
        if (recovered.count == 0) {
            close(fd);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
                userInfo:@{NSLocalizedDescriptionKey:
                    @"无法解析归档条目（不是 ZIP 或目录结构异常）"}];
            return nil;
        }
        [entries addObjectsFromArray:recovered];
    }

    close(fd);
    if (truncated) {
        // 列表可能不完整：如实提示而不是静默截断。
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey:@"归档目录不完整，列表可能被截断"}];
    }
    return entries; // 空归档返回空数组，调用方据此显示"无内容"
}

#pragma mark - Single-entry extraction

// Shared store/deflate extractor: reads one entry's data starting at
// dataOffset and writes it into destinationPath. CRC checked whenever an
// expected value exists; descriptor-style entries (expectedSize 0) are
// extracted by streaming until stream end / EOF.
+ (BOOL)extractData:(int)fd dataOffset:(off_t)dataOffset method:(uint16_t)method
       expectedCrc:(uint32_t)expectedCrc expectedSize:(uint32_t)expectedSize
    compressedSize:(uint32_t)compressedSize
      destinationPath:(NSString *)destinationPath error:(NSError **)error
{
    int output = open(destinationPath.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (output < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"创建临时文件失败：%s", strerror(errno)]}];
        return NO;
    }

    uLong crc = crc32(0L, Z_NULL, 0);
    unsigned long long producedTotal = 0;
    uint32_t remainingCompressed = compressedSize;
    z_stream stream = {0};
    BOOL usingInflate = NO;
    if (method == 8) {
        if (inflateInit2(&stream, -15) != Z_OK) {
            close(output);
            unlink(destinationPath.fileSystemRepresentation);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
                userInfo:@{NSLocalizedDescriptionKey:@"解压初始化失败"}];
            return NO;
        }
        usingInflate = YES;
    }

    uint8_t input[64 * 1024];
    uint8_t outBuffer[64 * 1024];
    BOOL ok = YES;
    NSString *failure = nil;
    off_t cursor = dataOffset;

    while (ok) {
        if (!usingInflate) {
            if (remainingCompressed == 0) break;
            size_t chunk = MIN(sizeof(input), (size_t)remainingCompressed);
            if (pread(fd, input, chunk, cursor) != (ssize_t)chunk) {
                ok = NO; failure = @"读取数据失败"; break;
            }
            cursor += chunk;
            remainingCompressed -= (uint32_t)chunk;
            crc = crc32(crc, input, (uInt)chunk);
            ssize_t written = write(output, input, chunk);
            if (written != (ssize_t)chunk) {
                ok = NO; failure = @"写入失败"; break;
            }
            producedTotal += chunk;
        } else {
            if (remainingCompressed == 0 && stream.avail_in == 0) break;
            if (stream.avail_in == 0) {
                size_t chunk = remainingCompressed > 0
                    ? MIN(sizeof(input), (size_t)remainingCompressed)
                    : sizeof(input);
                ssize_t got = pread(fd, input, chunk, cursor);
                if (got <= 0) break;
                cursor += got;
                if (remainingCompressed >= (uint32_t)got)
                    remainingCompressed -= (uint32_t)got;
                else
                    remainingCompressed = 0;
                stream.next_in = input;
                stream.avail_in = (uInt)got;
            }
            stream.next_out = outBuffer;
            stream.avail_out = sizeof(outBuffer);
            int result = inflate(&stream, Z_NO_FLUSH);
            if (result != Z_OK && result != Z_STREAM_END) {
                ok = NO;
                failure = [NSString stringWithFormat:@"解压失败 (%d)", result];
                break;
            }
            size_t produced = sizeof(outBuffer) - stream.avail_out;
            if (produced > 0) {
                crc = crc32(crc, outBuffer, (uInt)produced);
                ssize_t written = write(output, outBuffer, produced);
                if (written != (ssize_t)produced) {
                    ok = NO; failure = @"写入失败"; break;
                }
                producedTotal += produced;
            }
            if (result == Z_STREAM_END) break;
        }
        // 防御上限：描述符式条目没有可靠长度，超过 4 GiB 视为损坏。
        if (producedTotal > 4ULL * 1024 * 1024 * 1024) {
            ok = NO; failure = @"条目过大或已损坏"; break;
        }
    }

    if (usingInflate) inflateEnd(&stream);
    close(output);

    if (!ok || producedTotal != expectedSize ||
        (expectedCrc && crc != expectedCrc)) {
        unlink(destinationPath.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey:
                failure ?: @"提取失败：数据损坏或不完整（CRC 校验未通过）"}];
        return NO;
    }
    return YES;
}

// Locates one entry's local file header by full-name scan (fallback when
// the central directory has no usable record). Single pass over the file:
// returns the header offset or -1, filling method/CRC/sizes/data offset.
+ (off_t)findLocalHeaderForName:(NSString *)entryName fd:(int)fd
                          fileSize:(off_t)size
                          outMethod:(uint16_t *)outMethod
                             outCrc:(uint32_t *)outCrc
                            outSize:(uint32_t *)outSize
                 outCompressedSize:(uint32_t *)outCompressedSize
                      outDataOffset:(off_t *)outDataOffset
{
    const size_t windowSize = 256 * 1024;
    uint8_t *window = malloc(windowSize);
    if (!window) return -1;

    off_t pos = 0;
    off_t result = -1;
    while (pos < size && result < 0) {
        ssize_t got = pread(fd, window, windowSize, pos);
        if (got < 30) break;
        for (ssize_t i = 0; i + 30 <= got; i++) {
            if (window[i] != 0x50 || window[i + 1] != 0x4B ||
                window[i + 2] != 0x03 || window[i + 3] != 0x04) continue;
            uint16_t nameLength = ArchiveU16(window + i + 26);
            if ((uint64_t)i + 30u + nameLength > (uint64_t)got) continue;
            NSString *name = [[NSString alloc] initWithBytes:window + i + 30
                length:nameLength encoding:NSUTF8StringEncoding];
            if (![name isEqualToString:entryName]) continue;
            uint16_t extraLength = ArchiveU16(window + i + 28);
            if (outMethod) *outMethod = ArchiveU16(window + i + 8);
            if (outCrc) *outCrc = ArchiveU32(window + i + 14);
            if (outSize) *outSize = ArchiveU32(window + i + 22);
            if (outCompressedSize) *outCompressedSize = ArchiveU32(window + i + 18);
            if (outDataOffset) *outDataOffset = pos + i + 30 + nameLength + extraLength;
            result = pos + i;
            break;
        }
        pos += got - 3;
    }
    free(window);
    return result;
}

- (NSString *)extractEntry:(NSString *)entryName fromArchive:(NSString *)archivePath
               toDirectory:(NSString *)destinationDirectory error:(NSError **)error
{
    if (entryName.length == 0 || [entryName hasSuffix:@"/"]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EISDIR
            userInfo:@{NSLocalizedDescriptionKey:@"目录条目无法直接提取为文件"}];
        return nil;
    }

    NSString *base = entryName.lastPathComponent;
    if (base.length == 0) base = @"entry";
    NSString *destination =
        [destinationDirectory stringByAppendingPathComponent:base];

    int fd = open(archivePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:@"无法打开归档"}];
        return nil;
    }

    // 主路径：中央目录精确匹配。
    struct stat status = {0};
    off_t size = (fstat(fd, &status) == 0) ? status.st_size : 0;
    if (size >= 22) {
        size_t tailLength = (size_t)MIN(size, (off_t)(65536 + 22));
        uint8_t tailBuffer[65536 + 22];
        ssize_t got = pread(fd, tailBuffer, tailLength, size - (off_t)tailLength);
        ssize_t eocd = -1;
        for (ssize_t i = got - 22; i >= 0; i--)
            if (tailBuffer[i] == 0x50 && tailBuffer[i + 1] == 0x4B &&
                tailBuffer[i + 2] == 0x05 && tailBuffer[i + 3] == 0x06) { eocd = i; break; }

        if (eocd >= 0) {
            uint32_t cdOffset = ArchiveU32(tailBuffer + eocd + 16);
            uint32_t cdSize = ArchiveU32(tailBuffer + eocd + 12);
            if (cdSize > 0 && cdSize <= 256 * 1024 * 1024 && cdOffset < (uint64_t)size) {
                uint8_t *directory = malloc(cdSize);
                if (directory &&
                    pread(fd, directory, cdSize, cdOffset) == (ssize_t)cdSize) {
                    const uint8_t *match = NULL;
                    size_t scan = 0;
                    while (scan + 46 <= cdSize) {
                        const uint8_t *record = directory + scan;
                        if (ArchiveU32(record) != 0x02014b50) break;
                        uint16_t nameLength = ArchiveU16(record + 28);
                        uint16_t extraLength = ArchiveU16(record + 30);
                        uint16_t commentLength = ArchiveU16(record + 32);
                        if ((uint64_t)scan + 46u + nameLength + extraLength +
                                commentLength > cdSize) break;
                        NSString *name = [[NSString alloc] initWithBytes:record + 46
                            length:nameLength encoding:NSUTF8StringEncoding];
                        if ([name isEqualToString:entryName]) { match = record; break; }
                        scan += 46 + nameLength + extraLength + commentLength;
                    }
                    if (match) {
                        uint16_t method = ArchiveU16(match + 10);
                        uint32_t expectedCrc = ArchiveU32(match + 16);
                        uint32_t expectedSize = ArchiveU32(match + 24);
                        uint32_t compressedSize = ArchiveU32(match + 20);
                        uint32_t localOffset = ArchiveU32(match + 42);
                        free(directory);
                        close(fd);
                        if (compressedSize == 0xFFFFFFFF || expectedSize == 0xFFFFFFFF ||
                            localOffset == 0xFFFFFFFF) {
                            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:EFTYPE userInfo:@{NSLocalizedDescriptionKey:
                                    @"该条目使用 ZIP64 扩展，暂不支持"}];
                            return nil;
                        }
                        if (method != 0 && method != 8) {
                            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:ENOTSUP userInfo:@{NSLocalizedDescriptionKey:
                                    @"该条目使用了不支持的压缩方式"}];
                            return nil;
                        }
                        uint8_t local[30] = {0};
                        if (pread(fd, local, sizeof(local), localOffset) != sizeof(local) ||
                            ArchiveU32(local) != 0x04034b50) {
                            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:EIO userInfo:@{NSLocalizedDescriptionKey:@"归档读取失败"}];
                            return nil;
                        }
                        off_t dataOffset = (off_t)localOffset + 30 +
                            ArchiveU16(local + 26) + ArchiveU16(local + 28);
                        BOOL ok = [FFArchiveService extractData:fd dataOffset:dataOffset
                            method:method expectedCrc:expectedCrc expectedSize:expectedSize
                            compressedSize:compressedSize destinationPath:destination
                            error:error];
                        close(fd);
                        return ok ? destination : nil;
                    }
                    free(directory);
                } else {
                    free(directory);
                }
            }
        }
    }

    // 兜底路径：本地文件头扫描匹配。
    uint16_t method = 0;
    uint32_t expectedCrc = 0, expectedSize = 0, compressedSize = 0;
    off_t dataOffset = 0;
    off_t header = [FFArchiveService findLocalHeaderForName:entryName
                                                          fd:fd fileSize:size
                                                  outMethod:&method outCrc:&expectedCrc
                                                     outSize:&expectedSize
                                          outCompressedSize:&compressedSize
                                               outDataOffset:&dataOffset];
    if (header < 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT
            userInfo:@{NSLocalizedDescriptionKey:@"归档中不存在该条目"}];
        return nil;
    }
    if (method != 0 && method != 8) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP
            userInfo:@{NSLocalizedDescriptionKey:@"该条目使用了不支持的压缩方式"}];
        return nil;
    }
    BOOL ok = [FFArchiveService extractData:fd dataOffset:dataOffset method:method
        expectedCrc:expectedCrc expectedSize:expectedSize
        compressedSize:compressedSize destinationPath:destination error:error];
    close(fd);
    return ok ? destination : nil;
}

@end
