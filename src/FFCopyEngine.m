#import "FFCopyEngine.h"
#import "FFPathPolicy.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static void setError(NSError **error, int code, NSString *operation, NSString *path)
{
    if (!error) return;
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ failed for %@: %s",
            operation, path, strerror(code)]}];
}

@implementation FFCopyEngine

+ (BOOL)copyItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 error:(NSError **)error
{
    return [self copyItemAtPath:source toPath:destination progress:nil error:error];
}

+ (BOOL)copyItemAtPath:(NSString *)source
                toPath:(NSString *)destination
              progress:(void (^)(unsigned long long, unsigned long long))progress
                 error:(NSError **)error
{
    // 目标位置必须通过统一路径校验（父链合法、无未知符号链接）。
    NSString *detail = nil;
    NSString *finalName = nil;
    if (![FFPathPolicy resolveParentForMutation:destination
        finalName:&finalName errorMessage:&detail]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"复制目标不合法：%@",
                detail ?: destination]}];
        return NO;
    }
    unsigned long long total = [self sizeOfItemAtPath:source];
    return [self copyItemAtPath:source toPath:destination
                          total:total copied:0 progress:progress error:error];
}

static BOOL FFEntryIsDirectory(const char *path)
{
    struct stat status = {0};
    return lstat(path, &status) == 0 && S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
}

+ (BOOL)copyItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 total:(unsigned long long)total
                copied:(unsigned long long)copied
              progress:(void (^)(unsigned long long, unsigned long long))progress
                 error:(NSError **)error
{
    unsigned long long current = copied;
    void (^report)(unsigned long long) = ^(unsigned long long bytes) {
        if (progress) progress(bytes, total);
    };

    if (FFEntryIsDirectory(source.fileSystemRepresentation)) {
        struct stat status = {0};
        lstat(source.fileSystemRepresentation, &status);
        if (mkdir(destination.fileSystemRepresentation, status.st_mode & 0777 ?: 0700) != 0) {
            setError(error, errno, @"create directory", destination);
            return NO;
        }
        DIR *directory = opendir(source.fileSystemRepresentation);
        if (!directory) {
            int saved = errno;
            rmdir(destination.fileSystemRepresentation);
            setError(error, saved, @"open directory", source);
            return NO;
        }
        BOOL success = YES;
        struct dirent *entry = NULL;
        while (success && (entry = readdir(directory)) != NULL) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            NSString *name = [NSFileManager.defaultManager
                stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
            if (!name) {
                setError(error, EILSEQ, @"decode filename", source);
                success = NO;
                break;
            }
            success = [self copyItemAtPath:[source stringByAppendingPathComponent:name]
                toPath:[destination stringByAppendingPathComponent:name]
                total:total copied:current progress:progress error:error];
            struct stat childStatus = {0};
            if (lstat([destination stringByAppendingPathComponent:name].fileSystemRepresentation,
                      &childStatus) == 0 && S_ISREG(childStatus.st_mode))
                current += (unsigned long long)childStatus.st_size;
            report(current);
        }
        closedir(directory);
        if (!success)
            [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
        return success;
    }

    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0) {
        setError(error, errno, @"inspect source", source);
        return NO;
    }
    if (S_ISLNK(status.st_mode)) {
        char target[PATH_MAX] = {0};
        ssize_t length = readlink(source.fileSystemRepresentation, target, sizeof(target) - 1);
        if (length < 0) {
            setError(error, errno, @"read symbolic link", source);
            return NO;
        }
        target[length] = '\0';
        if (symlink(target, destination.fileSystemRepresentation) != 0) {
            setError(error, errno, @"create symbolic link", destination);
            return NO;
        }
        return YES;
    }
    if (!S_ISREG(status.st_mode)) {
        setError(error, ENOTSUP, @"copy unsupported item", source);
        return NO;
    }
    return [self copyRegularFile:source destination:destination mode:status.st_mode
                          copied:current total:total progress:report error:error];
}

+ (BOOL)copyRegularFile:(NSString *)source destination:(NSString *)destination
                   mode:(mode_t)mode copied:(unsigned long long)copied
                  total:(unsigned long long)total
              progress:(void (^)(unsigned long long))report error:(NSError **)error
{
    int input = open(source.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) {
        setError(error, errno, @"open source", source);
        return NO;
    }
    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode & 0777 ?: 0600);
    if (output < 0) {
        int saved = errno;
        close(input);
        setError(error, saved, @"create destination", destination);
        return NO;
    }
    BOOL success = YES;
    unsigned long long current = copied;
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            setError(error, errno, @"read", source);
            success = NO;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                setError(error, written < 0 ? errno : EIO, @"write", destination);
                success = NO;
                break;
            }
            offset += written;
        }
        current += (unsigned long long)count;
        if (report) report(current);
    }
    if (success) fsync(output);
    close(output);
    close(input);
    if (!success) unlink(destination.fileSystemRepresentation);
    return success;
}

+ (unsigned long long)sizeOfItemAtPath:(NSString *)path
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) return 0;
    if (S_ISREG(status.st_mode)) return (unsigned long long)status.st_size;
    if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) return 0;
    unsigned long long total = 0;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        total += [self sizeOfItemAtPath:[path stringByAppendingPathComponent:name]];
    }
    closedir(directory);
    return total;
}

@end
