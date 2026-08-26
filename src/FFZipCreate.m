#import "FFZipCreate.h"

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static const NSUInteger kFFZipMaxEntries = 100000;
static const size_t kFFZipIOBufferSize = 256 * 1024;

static NSError *FFZipError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"FFZipCreate" code:code userInfo:@{
        NSLocalizedDescriptionKey: message ?: @"压缩失败"
    }];
}

static void FFZipSetError(NSError **error, NSInteger code, NSString *message)
{
    if (error) *error = FFZipError(code, message);
}

static BOOL FFZipWriteBytes(FILE *file, const void *bytes, size_t length)
{
    return length == 0 || fwrite(bytes, 1, length, file) == length;
}

static BOOL FFZipWriteU16(FILE *file, uint16_t value)
{
    uint8_t bytes[2] = { (uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff) };
    return FFZipWriteBytes(file, bytes, sizeof(bytes));
}

static BOOL FFZipWriteU32(FILE *file, uint32_t value)
{
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff),
        (uint8_t)((value >> 16) & 0xff), (uint8_t)((value >> 24) & 0xff)
    };
    return FFZipWriteBytes(file, bytes, sizeof(bytes));
}

static BOOL FFZipWriteU64(FILE *file, uint64_t value)
{
    uint8_t bytes[8];
    for (NSUInteger i = 0; i < 8; i++) bytes[i] = (uint8_t)((value >> (8 * i)) & 0xff);
    return FFZipWriteBytes(file, bytes, sizeof(bytes));
}

static BOOL FFZipNameIsStorable(NSString *name)
{
    NSString *ext = name.pathExtension.lowercaseString;
    static NSSet<NSString *> *storable;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        storable = [NSSet setWithArray:@[
            @"zip", @"ipa", @"deb", @"7z", @"rar", @"gz", @"xz", @"bz2",
            @"jpg", @"jpeg", @"png", @"gif", @"heic", @"webp", @"tiff",
            @"mp3", @"m4a", @"aac", @"flac", @"mp4", @"mov", @"m4v",
        ]];
    });
    return [storable containsObject:ext];
}

@interface FFZipPlanEntry : NSObject
@property(nonatomic, copy) NSString *relativeName;
@property(nonatomic, copy) NSString *absolutePath;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) uint64_t size;
@property(nonatomic) mode_t mode;
@property(nonatomic) time_t modifiedTime;
@end
@implementation FFZipPlanEntry
@end

@interface FFZipWrittenEntry : NSObject
@property(nonatomic, strong) FFZipPlanEntry *plan;
@property(nonatomic) uint64_t localOffset;
@property(nonatomic) uint64_t compressedSize;
@property(nonatomic) uint64_t uncompressedSize;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint16_t method;
@property(nonatomic) uint16_t dosTime;
@property(nonatomic) uint16_t dosDate;
@property(nonatomic) BOOL zip64Sizes;
@end
@implementation FFZipWrittenEntry
@end

static BOOL FFZipCollectEntries(NSString *absolutePath, NSString *prefix,
                                NSMutableArray<FFZipPlanEntry *> *entries,
                                NSMutableSet<NSString *> *names,
                                NSError **error)
{
    if (entries.count >= kFFZipMaxEntries) {
        FFZipSetError(error, EFBIG, @"归档条目过多（超过 100000 个）");
        return NO;
    }

    struct stat status = {0};
    if (lstat(absolutePath.fileSystemRepresentation, &status) != 0) {
        int saved = errno;
        FFZipSetError(error, saved, [NSString stringWithFormat:@"读取源文件失败：%@ (%s)",
            absolutePath.lastPathComponent, strerror(saved)]);
        return NO;
    }
    if (S_ISLNK(status.st_mode)) return YES;
    if (!S_ISREG(status.st_mode) && !S_ISDIR(status.st_mode)) return YES;

    NSString *name = absolutePath.lastPathComponent;
    NSString *relative = prefix.length ? [prefix stringByAppendingPathComponent:name] : name;
    if (relative.length == 0 || [relative hasPrefix:@"/"]) {
        FFZipSetError(error, EINVAL, @"源文件包含不安全的归档路径");
        return NO;
    }

    BOOL directory = S_ISDIR(status.st_mode);
    NSString *archiveName = directory ? [relative stringByAppendingString:@"/"] : relative;
    NSData *nameData = [archiveName dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameData.length || nameData.length > UINT16_MAX) {
        FFZipSetError(error, ENAMETOOLONG, [NSString stringWithFormat:@"归档路径过长：%@", archiveName]);
        return NO;
    }
    if ([names containsObject:archiveName]) {
        FFZipSetError(error, EEXIST, [NSString stringWithFormat:@"归档中出现重复路径：%@", archiveName]);
        return NO;
    }
    [names addObject:archiveName];

    FFZipPlanEntry *entry = [FFZipPlanEntry new];
    entry.relativeName = archiveName;
    entry.absolutePath = absolutePath;
    entry.isDirectory = directory;
    entry.size = directory ? 0 : (uint64_t)MAX((off_t)0, status.st_size);
    entry.mode = status.st_mode;
#if defined(__APPLE__)
    entry.modifiedTime = status.st_mtimespec.tv_sec;
#else
    entry.modifiedTime = status.st_mtime;
#endif
    [entries addObject:entry];

    if (!directory) return YES;

    NSError *listError = nil;
    NSArray<NSString *> *children = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:absolutePath error:&listError];
    if (!children) {
        if (error) *error = listError ?: FFZipError(EIO, @"读取源目录失败");
        return NO;
    }
    children = [children sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *child in children) {
        if (![FFZipCollectEntries([absolutePath stringByAppendingPathComponent:child],
            relative, entries, names, error)]) return NO;
    }
    return YES;
}

static void FFZipDOSTime(time_t epoch, uint16_t *dosTime, uint16_t *dosDate)
{
    struct tm local = {0};
    if (!localtime_r(&epoch, &local)) {
        *dosTime = 0;
        *dosDate = 0x0021;
        return;
    }
    int year = local.tm_year + 1900;
    if (year < 1980) year = 1980;
    if (year > 2107) year = 2107;
    *dosTime = (uint16_t)(((local.tm_hour & 31) << 11) |
        ((local.tm_min & 63) << 5) | ((local.tm_sec / 2) & 31));
    *dosDate = (uint16_t)(((year - 1980) << 9) |
        (((local.tm_mon + 1) & 15) << 5) | (local.tm_mday & 31));
}

static BOOL FFZipPatchLocalHeader(FILE *file, FFZipWrittenEntry *written,
                                  NSUInteger nameLength, NSError **error)
{
    off_t end = ftello(file);
    if (end < 0 || fseeko(file, (off_t)written.localOffset + 14, SEEK_SET) != 0) {
        FFZipSetError(error, errno ?: EIO, @"更新 ZIP 本地文件头失败");
        return NO;
    }
    if (!FFZipWriteU32(file, written.crc)) goto io_error;
    if (written.zip64Sizes) {
        if (!FFZipWriteU32(file, UINT32_MAX) || !FFZipWriteU32(file, UINT32_MAX)) goto io_error;
        off_t zip64Values = (off_t)written.localOffset + 30 + (off_t)nameLength + 4;
        if (fseeko(file, zip64Values, SEEK_SET) != 0 ||
            !FFZipWriteU64(file, written.uncompressedSize) ||
            !FFZipWriteU64(file, written.compressedSize)) goto io_error;
    } else {
        if (written.compressedSize >= UINT32_MAX || written.uncompressedSize >= UINT32_MAX) {
            FFZipSetError(error, EFBIG, @"ZIP64 预留不足，已中止以避免生成损坏归档");
            return NO;
        }
        if (!FFZipWriteU32(file, (uint32_t)written.compressedSize) ||
            !FFZipWriteU32(file, (uint32_t)written.uncompressedSize)) goto io_error;
    }
    if (fseeko(file, end, SEEK_SET) != 0) goto io_error;
    return YES;

io_error:
    FFZipSetError(error, errno ?: EIO, @"更新 ZIP 本地文件头失败");
    return NO;
}

static BOOL FFZipStreamStored(FILE *output, int input, FFZipWrittenEntry *written,
                              uint8_t *inputBuffer, uint64_t *completed,
                              uint64_t totalBytes,
                              void (^progressBlock)(double, NSString *),
                              BOOL (^shouldCancel)(void), NSError **error)
{
    for (;;) {
        if (shouldCancel && shouldCancel()) {
            FFZipSetError(error, NSUserCancelledError, @"压缩已取消");
            return NO;
        }
        ssize_t count = read(input, inputBuffer, kFFZipIOBufferSize);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            int saved = errno;
            FFZipSetError(error, saved, [NSString stringWithFormat:@"读取源文件失败：%@ (%s)",
                written.plan.relativeName, strerror(saved)]);
            return NO;
        }
        if (count == 0) break;
        written.crc = (uint32_t)crc32(written.crc, inputBuffer, (uInt)count);
        if (!FFZipWriteBytes(output, inputBuffer, (size_t)count)) {
            FFZipSetError(error, errno ?: EIO, @"写入 ZIP 数据失败");
            return NO;
        }
        written.uncompressedSize += (uint64_t)count;
        written.compressedSize += (uint64_t)count;
        *completed += (uint64_t)count;
        if (progressBlock) progressBlock(totalBytes ? (double)*completed / (double)totalBytes : 0,
            written.plan.relativeName);
    }
    return YES;
}

static BOOL FFZipStreamDeflated(FILE *output, int input, FFZipWrittenEntry *written,
                                uint8_t *inputBuffer, uint8_t *outputBuffer,
                                uint64_t *completed, uint64_t totalBytes,
                                void (^progressBlock)(double, NSString *),
                                BOOL (^shouldCancel)(void), NSError **error)
{
    z_stream stream = {0};
    int zr = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                          Z_DEFAULT_STRATEGY);
    if (zr != Z_OK) {
        FFZipSetError(error, EIO, @"初始化压缩器失败");
        return NO;
    }

    BOOL ok = YES;
    BOOL eof = NO;
    while (!eof && ok) {
        if (shouldCancel && shouldCancel()) {
            FFZipSetError(error, NSUserCancelledError, @"压缩已取消");
            ok = NO;
            break;
        }
        ssize_t count;
        do { count = read(input, inputBuffer, kFFZipIOBufferSize); }
        while (count < 0 && errno == EINTR);
        if (count < 0) {
            int saved = errno;
            FFZipSetError(error, saved, [NSString stringWithFormat:@"读取源文件失败：%@ (%s)",
                written.plan.relativeName, strerror(saved)]);
            ok = NO;
            break;
        }
        eof = count == 0;
        if (count > 0) {
            written.crc = (uint32_t)crc32(written.crc, inputBuffer, (uInt)count);
            written.uncompressedSize += (uint64_t)count;
            *completed += (uint64_t)count;
        }
        stream.next_in = inputBuffer;
        stream.avail_in = (uInt)MAX((ssize_t)0, count);
        int flush = eof ? Z_FINISH : Z_NO_FLUSH;
        do {
            stream.next_out = outputBuffer;
            stream.avail_out = (uInt)kFFZipIOBufferSize;
            zr = deflate(&stream, flush);
            if (zr != Z_OK && zr != Z_STREAM_END) {
                FFZipSetError(error, EIO, @"压缩数据失败");
                ok = NO;
                break;
            }
            size_t produced = kFFZipIOBufferSize - stream.avail_out;
            if (produced && !FFZipWriteBytes(output, outputBuffer, produced)) {
                FFZipSetError(error, errno ?: EIO, @"写入 ZIP 数据失败");
                ok = NO;
                break;
            }
            written.compressedSize += produced;
        } while (ok && (stream.avail_in > 0 || (flush == Z_FINISH && zr != Z_STREAM_END)));

        if (count > 0 && progressBlock)
            progressBlock(totalBytes ? (double)*completed / (double)totalBytes : 0,
                written.plan.relativeName);
    }
    deflateEnd(&stream);
    return ok && zr == Z_STREAM_END;
}

static BOOL FFZipWriteLocalEntry(FILE *file, FFZipPlanEntry *plan,
                                 FFZipWrittenEntry **writtenOut,
                                 uint8_t *inputBuffer, uint8_t *outputBuffer,
                                 uint64_t *completed, uint64_t totalBytes,
                                 BOOL forceZip64,
                                 void (^progressBlock)(double, NSString *),
                                 BOOL (^shouldCancel)(void), NSError **error)
{
    NSData *nameData = [plan.relativeName dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t nameLength = (uint16_t)nameData.length;
    off_t localOffsetSigned = ftello(file);
    if (localOffsetSigned < 0) {
        FFZipSetError(error, errno ?: EIO, @"读取 ZIP 写入位置失败");
        return NO;
    }

    FFZipWrittenEntry *written = [FFZipWrittenEntry new];
    written.plan = plan;
    written.localOffset = (uint64_t)localOffsetSigned;
    written.uncompressedSize = 0;
    written.compressedSize = 0;
    written.crc = (uint32_t)crc32(0L, Z_NULL, 0);
    written.method = (plan.isDirectory || plan.size < 128 || FFZipNameIsStorable(plan.relativeName))
        ? 0 : Z_DEFLATED;
    uint16_t dosTime = 0, dosDate = 0;
    FFZipDOSTime(plan.modifiedTime, &dosTime, &dosDate);
    written.dosTime = dosTime;
    written.dosDate = dosDate;

    uint64_t bound = plan.size;
    if (written.method == Z_DEFLATED && plan.size <= (uint64_t)ULONG_MAX)
        bound = (uint64_t)compressBound((uLong)plan.size);
    written.zip64Sizes = forceZip64 || plan.size >= UINT32_MAX || bound >= UINT32_MAX;
    uint16_t extraLength = written.zip64Sizes ? 20 : 0;
    uint16_t versionNeeded = written.zip64Sizes ? 45 : 20;

    if (!FFZipWriteU32(file, 0x04034b50) || !FFZipWriteU16(file, versionNeeded) ||
        !FFZipWriteU16(file, 0x0800) || !FFZipWriteU16(file, written.method) ||
        !FFZipWriteU16(file, written.dosTime) || !FFZipWriteU16(file, written.dosDate) ||
        !FFZipWriteU32(file, 0) ||
        !FFZipWriteU32(file, written.zip64Sizes ? UINT32_MAX : 0) ||
        !FFZipWriteU32(file, written.zip64Sizes ? UINT32_MAX : 0) ||
        !FFZipWriteU16(file, nameLength) || !FFZipWriteU16(file, extraLength) ||
        !FFZipWriteBytes(file, nameData.bytes, nameData.length)) {
        FFZipSetError(error, errno ?: EIO, @"写入 ZIP 本地文件头失败");
        return NO;
    }
    if (written.zip64Sizes) {
        if (!FFZipWriteU16(file, 0x0001) || !FFZipWriteU16(file, 16) ||
            !FFZipWriteU64(file, 0) || !FFZipWriteU64(file, 0)) {
            FFZipSetError(error, errno ?: EIO, @"写入 ZIP64 扩展字段失败");
            return NO;
        }
    }

    if (!plan.isDirectory) {
        int input = open(plan.absolutePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (input < 0) {
            int saved = errno;
            FFZipSetError(error, saved, [NSString stringWithFormat:@"打开源文件失败：%@ (%s)",
                plan.relativeName, strerror(saved)]);
            return NO;
        }
        BOOL ok = written.method == 0
            ? FFZipStreamStored(file, input, written, inputBuffer, completed, totalBytes,
                progressBlock, shouldCancel, error)
            : FFZipStreamDeflated(file, input, written, inputBuffer, outputBuffer, completed,
                totalBytes, progressBlock, shouldCancel, error);
        close(input);
        if (!ok) return NO;
        if (written.uncompressedSize != plan.size) {
            FFZipSetError(error, EIO, [NSString stringWithFormat:@"压缩期间源文件大小发生变化：%@",
                plan.relativeName]);
            return NO;
        }
    }

    if (!FFZipPatchLocalHeader(file, written, nameLength, error)) return NO;
    if (writtenOut) *writtenOut = written;
    return YES;
}

static BOOL FFZipWriteCentralEntry(FILE *file, FFZipWrittenEntry *entry,
                                   BOOL forceZip64, BOOL *usedZip64, NSError **error)
{
    NSData *nameData = [entry.plan.relativeName dataUsingEncoding:NSUTF8StringEncoding];
    BOOL size64 = forceZip64 || entry.uncompressedSize >= UINT32_MAX ||
        entry.compressedSize >= UINT32_MAX;
    BOOL offset64 = forceZip64 || entry.localOffset >= UINT32_MAX;
    uint16_t extraPayload = (uint16_t)((size64 ? 16 : 0) + (offset64 ? 8 : 0));
    uint16_t extraLength = extraPayload ? (uint16_t)(4 + extraPayload) : 0;
    BOOL zip64 = size64 || offset64;
    if (zip64 && usedZip64) *usedZip64 = YES;

    uint16_t versionNeeded = zip64 || entry.zip64Sizes ? 45 : 20;
    uint16_t versionMade = (uint16_t)((3 << 8) | versionNeeded);
    uint32_t external = ((uint32_t)(entry.plan.mode & 0xffff) << 16) |
        (entry.plan.isDirectory ? 0x10 : 0);

    if (!FFZipWriteU32(file, 0x02014b50) || !FFZipWriteU16(file, versionMade) ||
        !FFZipWriteU16(file, versionNeeded) || !FFZipWriteU16(file, 0x0800) ||
        !FFZipWriteU16(file, entry.method) || !FFZipWriteU16(file, entry.dosTime) ||
        !FFZipWriteU16(file, entry.dosDate) || !FFZipWriteU32(file, entry.crc) ||
        !FFZipWriteU32(file, size64 ? UINT32_MAX : (uint32_t)entry.compressedSize) ||
        !FFZipWriteU32(file, size64 ? UINT32_MAX : (uint32_t)entry.uncompressedSize) ||
        !FFZipWriteU16(file, (uint16_t)nameData.length) || !FFZipWriteU16(file, extraLength) ||
        !FFZipWriteU16(file, 0) || !FFZipWriteU16(file, 0) || !FFZipWriteU16(file, 0) ||
        !FFZipWriteU32(file, external) ||
        !FFZipWriteU32(file, offset64 ? UINT32_MAX : (uint32_t)entry.localOffset) ||
        !FFZipWriteBytes(file, nameData.bytes, nameData.length)) {
        FFZipSetError(error, errno ?: EIO, @"写入 ZIP 中央目录失败");
        return NO;
    }

    if (extraPayload) {
        if (!FFZipWriteU16(file, 0x0001) || !FFZipWriteU16(file, extraPayload)) goto io_error;
        if (size64 && (!FFZipWriteU64(file, entry.uncompressedSize) ||
                       !FFZipWriteU64(file, entry.compressedSize))) goto io_error;
        if (offset64 && !FFZipWriteU64(file, entry.localOffset)) goto io_error;
    }
    return YES;

io_error:
    FFZipSetError(error, errno ?: EIO, @"写入 ZIP64 中央目录失败");
    return NO;
}

static BOOL FFZipWriteEndRecords(FILE *file, uint64_t count, uint64_t cdOffset,
                                 uint64_t cdSize, BOOL forceZip64,
                                 BOOL entryZip64, NSError **error)
{
    BOOL needsZip64 = forceZip64 || entryZip64 || count >= UINT16_MAX ||
        cdOffset >= UINT32_MAX || cdSize >= UINT32_MAX;
    if (needsZip64) {
        off_t zip64OffsetSigned = ftello(file);
        if (zip64OffsetSigned < 0) goto io_error;
        uint64_t zip64Offset = (uint64_t)zip64OffsetSigned;
        if (!FFZipWriteU32(file, 0x06064b50) || !FFZipWriteU64(file, 44) ||
            !FFZipWriteU16(file, (uint16_t)((3 << 8) | 45)) || !FFZipWriteU16(file, 45) ||
            !FFZipWriteU32(file, 0) || !FFZipWriteU32(file, 0) ||
            !FFZipWriteU64(file, count) || !FFZipWriteU64(file, count) ||
            !FFZipWriteU64(file, cdSize) || !FFZipWriteU64(file, cdOffset) ||
            !FFZipWriteU32(file, 0x07064b50) || !FFZipWriteU32(file, 0) ||
            !FFZipWriteU64(file, zip64Offset) || !FFZipWriteU32(file, 1)) goto io_error;
    }

    uint16_t count16 = needsZip64 ? UINT16_MAX : (uint16_t)count;
    uint32_t size32 = needsZip64 ? UINT32_MAX : (uint32_t)cdSize;
    uint32_t offset32 = needsZip64 ? UINT32_MAX : (uint32_t)cdOffset;
    if (!FFZipWriteU32(file, 0x06054b50) || !FFZipWriteU16(file, 0) ||
        !FFZipWriteU16(file, 0) || !FFZipWriteU16(file, count16) ||
        !FFZipWriteU16(file, count16) || !FFZipWriteU32(file, size32) ||
        !FFZipWriteU32(file, offset32) || !FFZipWriteU16(file, 0)) goto io_error;
    return YES;

io_error:
    FFZipSetError(error, errno ?: EIO, @"写入 ZIP 结束记录失败");
    return NO;
}

BOOL FFCreateZipArchive(NSArray<NSString *> *sourcePaths,
                        NSString *destinationPath,
                        void (^progressBlock)(double, NSString *),
                        BOOL (^shouldCancel)(void),
                        NSError **error)
{
    if (error) *error = nil;
    if (sourcePaths.count == 0 || destinationPath.length == 0) {
        FFZipSetError(error, EINVAL, @"没有要压缩的文件");
        return NO;
    }

    NSString *standardDestination = destinationPath.stringByStandardizingPath;
    for (NSString *source in sourcePaths) {
        if ([source.stringByStandardizingPath isEqualToString:standardDestination]) {
            FFZipSetError(error, EINVAL, @"压缩目标不能是源文件本身");
            return NO;
        }
    }

    NSMutableArray<FFZipPlanEntry *> *plan = [NSMutableArray array];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (NSString *source in sourcePaths) {
        if (!FFZipCollectEntries(source, @"", plan, names, error)) return NO;
    }
    if (plan.count == 0) {
        FFZipSetError(error, ENOENT, @"没有可压缩的文件");
        return NO;
    }

    NSString *targetName = destinationPath.lastPathComponent;
    for (FFZipPlanEntry *entry in plan) {
        if ([entry.relativeName isEqualToString:targetName]) {
            FFZipSetError(error, EINVAL, @"压缩目标与源文件同名");
            return NO;
        }
    }

    uint64_t totalBytes = 0;
    for (FFZipPlanEntry *entry in plan) {
        if (UINT64_MAX - totalBytes < entry.size) {
            FFZipSetError(error, EFBIG, @"源文件总大小超出支持范围");
            return NO;
        }
        totalBytes += entry.size;
    }

    NSString *tempName = [NSString stringWithFormat:@".%@.%@.tmp",
        destinationPath.lastPathComponent, [NSUUID.UUID.UUIDString substringToIndex:8]];
    NSString *tempPath = [destinationPath.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:tempName];
    FILE *file = fopen(tempPath.fileSystemRepresentation, "w+b");
    if (!file) {
        int saved = errno;
        FFZipSetError(error, saved, [NSString stringWithFormat:@"创建压缩临时文件失败：%s", strerror(saved)]);
        return NO;
    }

    BOOL forceZip64 = [[[NSProcessInfo processInfo] environment][@"FF_ZIP_FORCE64"] boolValue];
    NSMutableArray<FFZipWrittenEntry *> *written = [NSMutableArray arrayWithCapacity:plan.count];
    uint8_t *inputBuffer = malloc(kFFZipIOBufferSize);
    uint8_t *outputBuffer = malloc(kFFZipIOBufferSize);
    BOOL ok = inputBuffer && outputBuffer;
    if (!ok) FFZipSetError(error, ENOMEM, @"无法分配压缩缓冲区");
    uint64_t completed = 0;

    for (FFZipPlanEntry *entry in plan) {
        if (!ok) break;
        if (shouldCancel && shouldCancel()) {
            FFZipSetError(error, NSUserCancelledError, @"压缩已取消");
            ok = NO;
            break;
        }
        if (progressBlock)
            progressBlock(totalBytes ? (double)completed / (double)totalBytes : 0,
                entry.relativeName);
        FFZipWrittenEntry *record = nil;
        ok = FFZipWriteLocalEntry(file, entry, &record, inputBuffer, outputBuffer,
            &completed, totalBytes, forceZip64, progressBlock, shouldCancel, error);
        if (ok && record) [written addObject:record];
    }

    if (inputBuffer) free(inputBuffer);
    if (outputBuffer) free(outputBuffer);

    uint64_t cdOffset = 0, cdSize = 0;
    BOOL entryZip64 = NO;
    if (ok) {
        off_t value = ftello(file);
        if (value < 0) {
            FFZipSetError(error, errno ?: EIO, @"读取 ZIP 中央目录位置失败");
            ok = NO;
        } else cdOffset = (uint64_t)value;
    }
    for (FFZipWrittenEntry *entry in written) {
        if (!ok) break;
        ok = FFZipWriteCentralEntry(file, entry, forceZip64, &entryZip64, error);
    }
    if (ok) {
        off_t end = ftello(file);
        if (end < 0 || (uint64_t)end < cdOffset) {
            FFZipSetError(error, EIO, @"ZIP 中央目录大小无效");
            ok = NO;
        } else {
            cdSize = (uint64_t)end - cdOffset;
            ok = FFZipWriteEndRecords(file, written.count, cdOffset, cdSize,
                forceZip64, entryZip64, error);
        }
    }

    if (ok && fflush(file) != 0) {
        FFZipSetError(error, errno ?: EIO, @"刷新压缩文件失败");
        ok = NO;
    }
    if (ok && fsync(fileno(file)) != 0) {
        FFZipSetError(error, errno ?: EIO, @"同步压缩文件失败");
        ok = NO;
    }
    if (fclose(file) != 0 && ok) {
        FFZipSetError(error, errno ?: EIO, @"关闭压缩文件失败");
        ok = NO;
    }

    if (!ok) {
        unlink(tempPath.fileSystemRepresentation);
        return NO;
    }

    if (rename(tempPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation) != 0) {
        int saved = errno;
        unlink(tempPath.fileSystemRepresentation);
        FFZipSetError(error, saved, [NSString stringWithFormat:@"替换压缩目标失败：%@ (%s)",
            destinationPath.lastPathComponent, strerror(saved)]);
        return NO;
    }

    if (progressBlock) progressBlock(1.0, @"");
    return YES;
}
