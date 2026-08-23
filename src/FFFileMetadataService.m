#import "FFFileMetadataService.h"

#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation FFFileMetadataService

+ (NSArray<NSString *> *)extendedAttributeLinesForPath:(NSString *)path
{
    ssize_t size = listxattr(path.fileSystemRepresentation, NULL, 0, 0);
    if (size <= 0) return @[];
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)size];
    ssize_t actual = listxattr(path.fileSystemRepresentation, buffer.mutableBytes, size, 0);
    if (actual <= 0) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithObject:@"扩展属性："];
    const char *cursor = buffer.bytes;
    const char *end = cursor + actual;
    while (cursor < end) {
        NSString *name = [NSString stringWithUTF8String:cursor];
        if (name.length) {
            ssize_t valueSize = getxattr(path.fileSystemRepresentation, cursor, NULL, 0, 0, 0);
            if (valueSize >= 0)
                [result addObject:[NSString stringWithFormat:@"  %@ (%zd bytes)", name, valueSize]];
            else
                [result addObject:[NSString stringWithFormat:@"  %@ (errno=%d)", name, errno]];
        }
        cursor += strlen(cursor) + 1;
    }
    return result;
}

// 单次递归遍历：大小 + 文件数 + 目录数。
static void FFStatDirectory(NSString *path, unsigned long long *size,
    NSUInteger *files, NSUInteger *folders)
{
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(child.fileSystemRepresentation, &status) != 0) continue;
        if (S_ISDIR(status.st_mode)) {
            (*folders)++;
            FFStatDirectory(child, size, files, folders);
        } else if (S_ISREG(status.st_mode)) {
            (*files)++;
            *size += (unsigned long long)status.st_size;
        }
    }
    closedir(directory);
}

+ (void)statDirectoryAtPath:(NSString *)path
                 completion:(void (^)(unsigned long long, NSUInteger, NSUInteger))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long size = 0;
        NSUInteger files = 0;
        NSUInteger folders = 0;
        FFStatDirectory(path, &size, &files, &folders);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(size, files, folders);
        });
    });
}

+ (nullable NSString *)sha256OfFile:(NSString *)path
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

+ (nullable NSString *)mimeTypeNameForFilenameExtension:(NSString *)extension
{
    if (!extension.length) return nil;
    UTType *type = [UTType typeWithFilenameExtension:extension.lowercaseString];
    return type.preferredMIMEType;
}

@end
