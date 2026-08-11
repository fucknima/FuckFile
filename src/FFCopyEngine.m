#import "FFCopyEngine.h"

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
    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0) {
        setError(error, errno, @"inspect source", source);
        return NO;
    }
    if (S_ISREG(status.st_mode))
        return [self copyRegularFile:source destination:destination mode:status.st_mode error:error];
    if (S_ISDIR(status.st_mode))
        return [self copyDirectory:source destination:destination mode:status.st_mode error:error];
    if (S_ISLNK(status.st_mode))
        return [self copySymbolicLink:source destination:destination error:error];
    setError(error, ENOTSUP, @"copy unsupported item", source);
    return NO;
}

+ (BOOL)copyRegularFile:(NSString *)source destination:(NSString *)destination
                   mode:(mode_t)mode error:(NSError **)error
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
    }
    if (success) fsync(output);
    close(output);
    close(input);
    if (!success) unlink(destination.fileSystemRepresentation);
    return success;
}

+ (BOOL)copyDirectory:(NSString *)source destination:(NSString *)destination
                 mode:(mode_t)mode error:(NSError **)error
{
    if (mkdir(destination.fileSystemRepresentation, mode & 0777 ?: 0700) != 0) {
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
            toPath:[destination stringByAppendingPathComponent:name] error:error];
    }
    closedir(directory);
    if (!success)
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    return success;
}

+ (BOOL)copySymbolicLink:(NSString *)source destination:(NSString *)destination
                   error:(NSError **)error
{
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

@end
