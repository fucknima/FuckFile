#import "FFFileMetadataService.h"
#import "FFLogger.h"

#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <unistd.h>

NSArray<NSString *> *FFExtendedAttributeSummaries(NSString *path)
{
    ssize_t size = listxattr(path.fileSystemRepresentation, NULL, 0, 0);
    if (size <= 0) return @[];
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)size];
    ssize_t actual = listxattr(path.fileSystemRepresentation, buffer.mutableBytes, size, 0);
    if (actual <= 0) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    const char *cursor = buffer.bytes;
    const char *end = cursor + actual;
    while (cursor < end) {
        NSString *name = [NSString stringWithUTF8String:cursor];
        if (name.length) {
            ssize_t valueSize = getxattr(path.fileSystemRepresentation, cursor, NULL, 0, 0, 0);
            if (valueSize >= 0)
                [result addObject:[NSString stringWithFormat:@"%@（%zd 字节）", name, valueSize]];
            else
                [result addObject:[NSString stringWithFormat:@"%@（读取失败）", name]];
        }
        cursor += strlen(cursor) + 1;
    }
    return result;
}

NSString *FFMimeTypeForPath(NSString *path)
{
    NSString *extension = path.pathExtension.lowercaseString;
    if (!extension.length) return @"application/octet-stream";
    if (@available(iOS 14.0, *)) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        return type.preferredMIMEType ?: @"application/octet-stream";
    }
    return @"application/octet-stream";
}

NSString *FFPermissionString(mode_t mode)
{
    mode_t bits = mode & 0777;
    NSMutableString *result = [NSMutableString stringWithCapacity:9];
    const char *types = "rwx";
    for (int index = 8; index >= 0; index--) {
        mode_t mask = (mode_t)(1 << index);
        [result appendString:(bits & mask) ? [NSString stringWithFormat:@"%c", types[index % 3]]
                                            : @"-"];
    }
    return result;
}

NSString *FFSHA256OfPath(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    ssize_t count = 0;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0)
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    close(fd);
    if (count < 0) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
        [result appendFormat:@"%02x", digest[index]];
    return result;
}

unsigned long long FFDirectorySizeAtPath(NSString *path)
{
    unsigned long long total = 0;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(child.fileSystemRepresentation, &status) != 0) continue;
        if (S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode)) {
            total += FFDirectorySizeAtPath(child);
        } else if (S_ISREG(status.st_mode)) {
            total += (unsigned long long)status.st_size;
        }
    }
    closedir(directory);
    return total;
}

NSUInteger FFItemCountAtPath(NSString *path)
{
    NSUInteger count = 0;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        count++;
    }
    closedir(directory);
    return count;
}
