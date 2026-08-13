#import "FFFileOperationService.h"
#import "FFPathPolicy.h"
#import "FFLogger.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation FFFileOperationService

+ (instancetype)sharedService
{
    static FFFileOperationService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [FFFileOperationService new]; });
    return service;
}

static NSError *FFOperationError(int code, NSString *operation, NSString *path)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 失败：%@ (%s)",
            operation, path, strerror(code)]}];
}

- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    NSString *detail = nil;
    int dirfd = [FFPathPolicy openParentDirectoryForPath:path
                                      isFinalDirectory:YES errorMessage:&detail];
    if (dirfd < 0) {
        if (error) *error = FFOperationError(EPERM, @"创建目录", path);
        return NO;
    }
    if (mkdirat(dirfd, path.lastPathComponent.fileSystemRepresentation, 0700) != 0) {
        int saved = errno;
        close(dirfd);
        if (error) *error = FFOperationError(saved, @"创建目录", path);
        return NO;
    }
    close(dirfd);
    FFLogTag(@"FileOp", @"mkdir %@", path);
    return YES;
}

- (BOOL)createEmptyFileAtPath:(NSString *)path error:(NSError **)error
{
    NSString *detail = nil;
    int dirfd = [FFPathPolicy openParentDirectoryForPath:path
                                      isFinalDirectory:NO errorMessage:&detail];
    if (dirfd < 0) {
        if (error) *error = FFOperationError(EPERM, @"创建文件", path);
        return NO;
    }
    int fd = openat(dirfd, path.lastPathComponent.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) {
        int saved = errno;
        close(dirfd);
        if (error) *error = FFOperationError(saved, @"创建文件", path);
        return NO;
    }
    close(fd);
    close(dirfd);
    FFLogTag(@"FileOp", @"create file %@", path);
    return YES;
}

- (BOOL)renameItemAtPath:(NSString *)path toPath:(NSString *)newPath
                   error:(NSError **)error
{
    // Same-directory rename: validate the shared parent once and use
    // renameat. Cross-directory moves are handled as copy+remove by the
    // task system, not here.
    if (![path.stringByDeletingLastPathComponent
            isEqualToString:newPath.stringByDeletingLastPathComponent]) {
        if (error) *error = FFOperationError(EINVAL, @"重命名", path);
        return NO;
    }
    NSString *detail = nil;
    int dirfd = [FFPathPolicy openParentDirectoryForPath:path
                                      isFinalDirectory:NO errorMessage:&detail];
    if (dirfd < 0) {
        if (error) *error = FFOperationError(EPERM, @"重命名", path);
        return NO;
    }
    if (renameat(dirfd, path.lastPathComponent.fileSystemRepresentation,
                 dirfd, newPath.lastPathComponent.fileSystemRepresentation) != 0) {
        int saved = errno;
        close(dirfd);
        if (error) *error = FFOperationError(saved, @"重命名", path);
        return NO;
    }
    close(dirfd);
    FFLogTag(@"FileOp", @"rename %@ -> %@", path, newPath);
    return YES;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error
{
    NSString *detail = nil;
    int dirfd = [FFPathPolicy openParentDirectoryForPath:path
                                      isFinalDirectory:NO errorMessage:&detail];
    if (dirfd < 0) {
        if (error) *error = FFOperationError(EPERM, @"删除", path);
        return NO;
    }
    // Distinguish file vs directory to pick the right at-call.
    struct stat status = {0};
    if (fstatat(dirfd, path.lastPathComponent.fileSystemRepresentation, &status,
                AT_SYMLINK_NOFOLLOW) != 0) {
        int saved = errno;
        close(dirfd);
        if (error) *error = FFOperationError(saved, @"删除", path);
        return NO;
    }
    int result = S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode)
        ? unlinkat(dirfd, path.lastPathComponent.fileSystemRepresentation, AT_REMOVEDIR)
        : unlinkat(dirfd, path.lastPathComponent.fileSystemRepresentation, 0);
    if (result != 0) {
        int saved = errno;
        close(dirfd);
        if (error) *error = FFOperationError(saved, @"删除", path);
        return NO;
    }
    close(dirfd);
    FFLogTag(@"FileOp", @"delete %@", path);
    return YES;
}

- (NSUInteger)removeItemsAtPaths:(NSArray<NSString *> *)paths
                     firstError:(NSError **)error
{
    NSUInteger removed = 0;
    for (NSString *path in paths) {
        NSError *itemError = nil;
        if ([self removeItemAtPath:path error:&itemError]) {
            removed++;
        } else {
            if (error) *error = itemError;
            break;
        }
    }
    return removed;
}

@end
