#import "FFZipCreate.h"
#import "FFCopyEngine.h"

#import <dirent.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>
#import <zlib.h>

static NSError *FFZipError(NSString *message)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{
        NSLocalizedDescriptionKey: message}];
}

static void FFZipWriteU16(FILE *file, uint16_t value)
{
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)(value >> 8) };
    fwrite(bytes, 1, 2, file);
}

static void FFZipWriteU32(FILE *file, uint32_t value)
{
    uint8_t bytes[4] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF) };
    fwrite(bytes, 1, 4, file);
}

static void FFZipWriteU16ToData(NSMutableData *data, uint16_t value)
{
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)(value >> 8) };
    [data appendBytes:bytes length:2];
}

static void FFZipWriteU32ToData(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[4] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF) };
    [data appendBytes:bytes length:4];
}


// DOS date/time from the current epoch.
static void FFZipDOSTime(uint16_t *dosTime, uint16_t *dosDate)
{
    time_t now = time(NULL);
    struct tm *local = localtime(&now);
    if (!local) {
        *dosTime = 0;
        *dosDate = 0x0021; // 1980-01-01
        return;
    }
    *dosTime = (uint16_t)((local->tm_hour << 11) | (local->tm_min << 5) |
        (local->tm_sec >> 1));
    *dosDate = (uint16_t)(((local->tm_year - 80) << 9) | ((local->tm_mon + 1) << 5) |
        local->tm_mday);
}

typedef struct {
    NSString *relativeName;   // archive entry name, "/"-suffixed for dirs
    NSString *absolutePath;
    BOOL isDirectory;
    unsigned long long size;  // 0 for directories
} FFZipEntry;

static void FFZipCollectEntries(NSString *absolutePath, NSString *prefix,
                                NSMutableArray<NSValue *> *entriesOut)
{
    struct stat status = {0};
    if (lstat(absolutePath.fileSystemRepresentation, &status) != 0) return;
    BOOL isDirectory = S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
    if (S_ISLNK(status.st_mode)) return; // never follow symlinks

    NSString *name = absolutePath.lastPathComponent;
    NSString *relative = prefix.length ? [prefix stringByAppendingPathComponent:name] : name;
    FFZipEntry entry = {
        .relativeName = isDirectory ? [relative stringByAppendingString:@"/"] : relative,
        .absolutePath = absolutePath,
        .isDirectory = isDirectory,
        .size = isDirectory ? 0 : (unsigned long long)status.st_size,
    };
    [entriesOut addObject:[NSValue valueWithBytes:&entry objCType:@encode(FFZipEntry)]];

    if (!isDirectory) return;
    DIR *dir = opendir(absolutePath.fileSystemRepresentation);
    if (!dir) return;
    struct dirent *child = NULL;
    while ((child = readdir(dir)) != NULL) {
        if (!strcmp(child->d_name, ".") || !strcmp(child->d_name, "..")) continue;
        NSString *childName = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:child->d_name length:strlen(child->d_name)];
        if (!childName) continue;
        FFZipCollectEntries([absolutePath stringByAppendingPathComponent:childName],
                            relative, entriesOut);
    }
    closedir(dir);
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

static BOOL FFZipDeflateData(NSData *input, NSMutableData *output, NSError **error)
{
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        if (error) *error = FFZipError(@"deflate init failed");
        return NO;
    }
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    uint8_t buffer[64 * 1024];
    int result = Z_OK;
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        result = deflate(&stream, Z_FINISH);
        if (result != Z_OK && result != Z_STREAM_END) {
            deflateEnd(&stream);
            if (error) *error = FFZipError(@"deflate failed");
            return NO;
        }
        [output appendBytes:buffer length:sizeof(buffer) - stream.avail_out];
    } while (result != Z_STREAM_END);
    deflateEnd(&stream);
    return YES;
}

BOOL FFCreateZipArchive(NSArray<NSString *> *sourcePaths,
                        NSString *destinationPath,
                        void (^progressBlock)(double, NSString *),
                        BOOL (^shouldCancel)(void),
                        NSError **error)
{
    if (sourcePaths.count == 0) {
        if (error) *error = FFZipError(@"没有要压缩的文件");
        return NO;
    }

    // Collect entries up front (needed for progress totals).
    NSMutableArray<NSValue *> *values = [NSMutableArray array];
    for (NSString *source in sourcePaths)
        FFZipCollectEntries(source, @"", values);
    if (values.count == 0) {
        if (error) *error = FFZipError(@"没有可压缩的文件");
        return NO;
    }
    unsigned long long totalBytes = 0;
    for (NSValue *value in values) {
        FFZipEntry entry;
        [value getValue:&entry];
        totalBytes += entry.size;
    }

    FILE *file = fopen(destinationPath.fileSystemRepresentation, "wb");
    if (!file) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"create %@: %s",
                destinationPath, strerror(errno)]}];
        return NO;
    }

    uint16_t dosTime = 0;
    uint16_t dosDate = 0;
    FFZipDOSTime(&dosTime, &dosDate);

    // Central directory entries, built as we write local headers.
    NSMutableData *central = [NSMutableData data];
    uint32_t entryCount = 0;
    unsigned long long completedBytes = 0;
    BOOL ok = YES;

    for (NSValue *value in values) {
        if (shouldCancel && shouldCancel()) {
            ok = NO;
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSUserCancelledError userInfo:@{
                    NSLocalizedDescriptionKey: @"压缩已取消"}];
            break;
        }
        FFZipEntry entry;
        [value getValue:&entry];

        if (progressBlock)
            progressBlock(totalBytes > 0 ? (double)completedBytes / (double)totalBytes : 0,
                          entry.relativeName);

        const char *nameBytes = entry.relativeName.UTF8String;
        size_t nameLength = strlen(nameBytes);
        long localOffset = ftell(file);

        uint32_t crc = 0;
        uint32_t compressedSize = 0;
        uint32_t uncompressedSize = 0;
        uint16_t method = 8;
        NSData *fileData = nil;
        NSMutableData *deflated = nil;

        if (entry.isDirectory) {
            method = 0;
            crc = 0;
        } else {
            NSError *readError = nil;
            fileData = [NSData dataWithContentsOfFile:entry.absolutePath
                options:NSDataReadingMappedIfSafe error:&readError];
            if (!fileData) {
                ok = NO;
                if (error) *error = readError;
                break;
            }
            crc = (uint32_t)crc32(0L, Z_NULL, 0);
            crc = (uint32_t)crc32(crc, fileData.bytes, (uInt)fileData.length);
            uncompressedSize = (uint32_t)fileData.length;
            if (fileData.length < 128 || FFZipNameIsStorable(entry.relativeName)) {
                method = 0;
                compressedSize = uncompressedSize;
            } else {
                deflated = [NSMutableData data];
                if (!FFZipDeflateData(fileData, deflated, error)) {
                    ok = NO;
                    break;
                }
                compressedSize = (uint32_t)deflated.length;
                // Store the smaller representation.
                if (deflated.length >= fileData.length) {
                    method = 0;
                    compressedSize = uncompressedSize;
                    deflated = nil;
                }
            }
        }

        // Local file header.
        fwrite("PK\x03\x04", 1, 4, file);
        FFZipWriteU16(file, 20);             // version needed
        FFZipWriteU16(file, 0x0800);         // UTF-8 names
        FFZipWriteU16(file, method);
        FFZipWriteU16(file, dosTime);
        FFZipWriteU16(file, dosDate);
        FFZipWriteU32(file, crc);
        FFZipWriteU32(file, compressedSize);
        FFZipWriteU32(file, uncompressedSize);
        FFZipWriteU16(file, (uint16_t)nameLength);
        FFZipWriteU16(file, 0);              // extra length
        fwrite(nameBytes, 1, nameLength, file);

        if (!entry.isDirectory) {
            if (method == 0) {
                fwrite(fileData.bytes, 1, fileData.length, file);
            } else {
                fwrite(deflated.bytes, 1, deflated.length, file);
            }
            completedBytes += entry.size;
        }

        // Central directory record.
        NSMutableData *record = [NSMutableData data];
        uint8_t header[4] = { 'P', 'K', 0x01, 0x02 };
        [record appendBytes:header length:4];
        uint16_t versionMade = (3 << 8) | 20;
        FFZipWriteU16ToData(record, versionMade);
        FFZipWriteU16ToData(record, 20);
        FFZipWriteU16ToData(record, 0x0800);
        FFZipWriteU16ToData(record, method);
        FFZipWriteU16ToData(record, dosTime);
        FFZipWriteU16ToData(record, dosDate);
        FFZipWriteU32ToData(record, crc);
        FFZipWriteU32ToData(record, compressedSize);
        FFZipWriteU32ToData(record, uncompressedSize);
        FFZipWriteU16ToData(record, (uint16_t)nameLength);
        FFZipWriteU16ToData(record, 0);      // extra
        FFZipWriteU16ToData(record, 0);      // comment
        FFZipWriteU16ToData(record, 0);      // disk
        FFZipWriteU16ToData(record, 0);      // internal attrs
        uint32_t externalAttrs = entry.isDirectory ? 0x10 : 0;
        FFZipWriteU32ToData(record, externalAttrs);
        FFZipWriteU32ToData(record, (uint32_t)localOffset);
        [record appendBytes:nameBytes length:nameLength];
        [central appendData:record];
        entryCount++;
    }

    if (ok) {
        long cdOffset = ftell(file);
        fwrite(central.bytes, 1, central.length, file);
        long cdSize = ftell(file) - cdOffset;

        fwrite("PK\x05\x06", 1, 4, file);
        FFZipWriteU16(file, 0);
        FFZipWriteU16(file, 0);
        FFZipWriteU16(file, (uint16_t)entryCount);
        FFZipWriteU16(file, (uint16_t)entryCount);
        FFZipWriteU32(file, (uint32_t)cdSize);
        FFZipWriteU32(file, (uint32_t)cdOffset);
        FFZipWriteU16(file, 0);
    }
    fclose(file);
    if (!ok)
        unlink(destinationPath.fileSystemRepresentation);
    return ok;
}
