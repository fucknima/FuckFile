#import "FFZipExtract.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static BOOL FFZipReadAt(int fd, off_t offset, void *buffer, size_t length)
{
    ssize_t done = pread(fd, buffer, length, offset);
    return done == (ssize_t)length;
}

static uint16_t FFZipU16(const uint8_t *bytes) { return (uint16_t)(bytes[0] | (bytes[1] << 8)); }
static uint32_t FFZipU32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static BOOL FFZipSafeEntryName(NSString *name)
{
    if (name.length == 0 || name.length > 1024) return NO;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    if ([name rangeOfString:@".."].location != NSNotFound) return NO;
    return YES;
}

static BOOL FFZipEnsureParent(NSString *directory, NSString *relative)
{
    NSString *parent = [directory stringByAppendingPathComponent:relative]
        .stringByDeletingLastPathComponent;
    return [[NSFileManager defaultManager] createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:nil];
}

BOOL FFZipExtract(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> **entryNames, NSError **error)
{
    return FFZipExtractWithProgress(archivePath, destDir, entryNames, nil, nil, error);
}

BOOL FFZipExtractWithProgress(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> **entryNames,
                  void (^progressBlock)(double, NSString *),
                  BOOL (^shouldCancel)(void),
                  NSError **error)
{
    if (entryNames) *entryNames = nil;
    int fd = open(archivePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"open archive: %s", strerror(errno)]}];
        return NO;
    }
    struct stat status = {0};
    if (fstat(fd, &status) != 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
            NSLocalizedDescriptionKey: @"fstat archive failed"}];
        return NO;
    }
    off_t size = status.st_size;

    // Locate the End Of Central Directory record (last 64 KiB + 22 bytes).
    size_t tailLength = (size_t)MIN(size, (off_t)(65536 + 22));
    uint8_t *tail = malloc(tailLength);
    if (!tail || !FFZipReadAt(fd, size - (off_t)tailLength, tail, tailLength)) {
        free(tail);
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
            NSLocalizedDescriptionKey: @"failed to read archive tail"}];
        return NO;
    }
    ssize_t eocd = -1;
    for (ssize_t index = (ssize_t)tailLength - 22; index >= 0; index--) {
        if (tail[index] == 0x50 && tail[index + 1] == 0x4b &&
            tail[index + 2] == 0x05 && tail[index + 3] == 0x06) {
            eocd = index;
            break;
        }
    }
    if (eocd < 0) {
        free(tail);
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE userInfo:@{
            NSLocalizedDescriptionKey: @"not a zip archive (EOCD not found)"}];
        return NO;
    }
    const uint8_t *record = tail + eocd;
    uint32_t cdOffset = FFZipU32(record + 16);
    uint32_t cdSize = FFZipU32(record + 12);
    free(tail);
    if (cdSize == 0 || cdSize > 256 * 1024 * 1024) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE userInfo:@{
            NSLocalizedDescriptionKey: @"invalid central directory size"}];
        return NO;
    }

    uint8_t *directory = malloc(cdSize);
    if (!directory || !FFZipReadAt(fd, cdOffset, directory, cdSize)) {
        free(directory);
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
            NSLocalizedDescriptionKey: @"failed to read central directory"}];
        return NO;
    }

    // First pass: aggregate compressed bytes for progress and — as a
    // ZIP-bomb guard — the total uncompressed size and entry count.
    unsigned long long totalCompressed = 0;
    unsigned long long totalUncompressed = 0;
    NSUInteger totalEntries = 0;
    {
        size_t scan = 0;
        while (scan + 46 <= cdSize) {
            const uint8_t *record = directory + scan;
            if (FFZipU32(record) != 0x02014b50) break;
            totalCompressed += FFZipU32(record + 20);
            totalUncompressed += FFZipU32(record + 24);
            totalEntries++;
            uint16_t nLen = FFZipU16(record + 28);
            uint16_t eLen = FFZipU16(record + 30);
            uint16_t cLen = FFZipU16(record + 32);
            scan += 46 + nLen + eLen + cLen;
        }
    }
    // Hard limits: 100k entries or 4 GiB expanded — well beyond any
    // legitimate archive we should handle inside a sandboxed app.
    if (totalEntries > 100000 || totalUncompressed > 4ULL * 1024 * 1024 * 1024) {
        free(directory);
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFBIG userInfo:@{
            NSLocalizedDescriptionKey: @"归档条目过多或解压后体积过大（疑似 ZIP 炸弹）"}];
        return NO;
    }

    // Extract into a sibling temporary directory, then commit with a
    // rename so a failed or cancelled run never leaves a half-written
    // archive at the destination.
    NSString *tempDir = [NSString stringWithFormat:@"%@.%@.tmp", destDir,
        [[[NSUUID UUID] UUIDString] substringToIndex:8]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString *> *entries = [NSMutableArray array];

    size_t cursor = 0;
    BOOL ok = YES;
    unsigned long long extractedCompressed = 0;
    while (cursor + 46 <= cdSize) {
        const uint8_t *entry = directory + cursor;
        if (FFZipU32(entry) != 0x02014b50) break; // end of directory / corruption
        uint16_t method = FFZipU16(entry + 10);
        uint32_t expectedCrc = FFZipU32(entry + 16);
        uint32_t expectedSize = FFZipU32(entry + 24);
        uint32_t compressedSize = FFZipU32(entry + 20);
        uint16_t nameLength = FFZipU16(entry + 28);
        uint16_t extraLength = FFZipU16(entry + 30);
        uint16_t commentLength = FFZipU16(entry + 32);
        uint32_t localOffset = FFZipU32(entry + 42);
        if (cursor + 46 + nameLength + extraLength + commentLength > cdSize) {
            ok = NO;
            break;
        }
        NSString *name = [[NSString alloc] initWithBytes:entry + 46
            length:nameLength encoding:NSUTF8StringEncoding];
        cursor += 46 + nameLength + extraLength + commentLength;
        if (!name.length) continue;
        if ([name hasSuffix:@"/"]) {
            if (!FFZipSafeEntryName(name)) { ok = NO; break; }
            NSString *dir = [tempDir stringByAppendingPathComponent:name];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        if (!FFZipSafeEntryName(name)) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"unsafe entry name: %@", name]}];
            ok = NO;
            break;
        }

        // Local file header for the actual data offset.
        uint8_t local[30] = {0};
        if (!FFZipReadAt(fd, localOffset, local, sizeof(local)) ||
            FFZipU32(local) != 0x04034b50) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"bad local header for %@", name]}];
            ok = NO;
            break;
        }
        uint16_t localName = FFZipU16(local + 26);
        uint16_t localExtra = FFZipU16(local + 28);
        off_t dataOffset = (off_t)localOffset + 30 + localName + localExtra;
        if (method != 0 && method != 8) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"unsupported compression method %u for %@", method, name]}];
            ok = NO;
            break;
        }

        if (!FFZipEnsureParent(tempDir, name)) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"mkdir parent: %s", strerror(errno)]}];
            ok = NO;
            break;
        }
        NSString *destination = [tempDir stringByAppendingPathComponent:name];
        int output = open(destination.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        uLong fileCrc = crc32(0L, Z_NULL, 0);
        if (output < 0) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"create %@: %s", name, strerror(errno)]}];
            ok = NO;
            break;
        }

        if (method == 0) {
            uint8_t buffer[64 * 1024];
            uint32_t remaining = compressedSize;
            while (remaining > 0) {
                size_t chunk = MIN(sizeof(buffer), (size_t)remaining);
                if (!FFZipReadAt(fd, dataOffset, buffer, chunk)) {
                    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"read %@ failed", name]}];
                    ok = NO;
                    break;
                }
                ssize_t written = write(output, buffer, chunk);
                if (written != (ssize_t)chunk) {
                    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"write %@: %s", name, strerror(errno)]}];
                    ok = NO;
                    break;
                }
                dataOffset += (off_t)chunk;
                remaining -= (uint32_t)chunk;
                fileCrc = crc32(fileCrc, buffer, (uInt)chunk);
            }
        } else {
            z_stream stream = {0};
            if (inflateInit2(&stream, -15) != Z_OK) {
                close(output);
                ok = NO;
                break;
            }
            uint8_t input[64 * 1024];
            uint8_t outputBuffer[64 * 1024];
            uint32_t remaining = compressedSize;
            while (ok) {
                size_t chunk = MIN(sizeof(input), (size_t)remaining);
                if (chunk == 0) break;
                if (!FFZipReadAt(fd, dataOffset, input, chunk)) {
                    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
                        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"read %@ failed", name]}];
                    ok = NO;
                    break;
                }
                dataOffset += (off_t)chunk;
                remaining -= (uint32_t)chunk;
                stream.next_in = input;
                stream.avail_in = (uInt)chunk;
                while (stream.avail_in > 0) {
                    stream.next_out = outputBuffer;
                    stream.avail_out = sizeof(outputBuffer);
                    int result = inflate(&stream, Z_NO_FLUSH);
                    if (result != Z_OK && result != Z_STREAM_END) {
                        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
                            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"inflate %@ failed (%d)", name, result]}];
                        ok = NO;
                        break;
                    }
                    size_t produced = sizeof(outputBuffer) - stream.avail_out;
                    if (produced > 0) {
                        fileCrc = crc32(fileCrc, outputBuffer, (uInt)produced);
                        ssize_t written = write(output, outputBuffer, produced);
                        if (written != (ssize_t)produced) {
                            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"write %@: %s", name, strerror(errno)]}];
                            ok = NO;
                            break;
                        }
                    }
                    if (result == Z_STREAM_END) break;
                }
            }
            inflateEnd(&stream);
        }
        close(output);
        extractedCompressed += compressedSize;
        if (!ok) {
            unlink(destination.fileSystemRepresentation);
            break;
        }
        if (expectedCrc && fileCrc != expectedCrc) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"CRC 校验失败：%@（归档可能损坏）", name]}];
            unlink(destination.fileSystemRepresentation);
            ok = NO;
            break;
        }
        [entries addObject:name];
        if (progressBlock && totalCompressed > 0)
            progressBlock((double)extractedCompressed / (double)totalCompressed, name);
        if (shouldCancel && shouldCancel()) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSUserCancelledError userInfo:@{
                    NSLocalizedDescriptionKey: @"解压已取消"}];
            ok = NO;
            break;
        }
    }

    free(directory);
    close(fd);
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
        return NO;
    }
    // Commit: remove a stale destination first (extract target) then
    // atomically move the fully-written temp dir into place.
    if ([[NSFileManager defaultManager] fileExistsAtPath:destDir]) {
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:destDir error:&removeError]) {
            [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
            if (error) *error = removeError;
            return NO;
        }
    }
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:tempDir toPath:destDir
        error:&moveError]) {
        [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
        if (error) *error = moveError;
        return NO;
    }
    if (entryNames) *entryNames = entries;
    return YES;
}
