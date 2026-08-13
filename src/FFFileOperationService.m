#import "FFFileOperationService.h"
#import "FFPathPolicy.h"
#import "FFLogger.h"

#import <dirent.h>
#import <errno.h>
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
    NSString *finalName = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:path
        finalName:&finalName errorMessage:&detail];
    if (!parent) {
        if (error) *error = FFOperationError(EPERM, @"创建目录", path);
        return NO;
    }
    NSString *target = [parent stringByAppendingPathComponent:finalName];
    if (mkdir(target.fileSystemRepresentation, 0700) != 0) {
        int saved = errno;
        if (error) *error = FFOperationError(saved, @"创建目录", path);
        return NO;
    }
    FFLogTag(@"FileOp", @"mkdir %@", target);
    return YES;
}

- (BOOL)createEmptyFileAtPath:(NSString *)path error:(NSError **)error
{
    NSString *detail = nil;
    NSString *finalName = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:path
        finalName:&finalName errorMessage:&detail];
    if (!parent) {
        if (error) *error = FFOperationError(EPERM, @"创建文件", path);
        return NO;
    }
    NSString *target = [parent stringByAppendingPathComponent:finalName];
    int fd = open(target.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) {
        int saved = errno;
        if (error) *error = FFOperationError(saved, @"创建文件", path);
        return NO;
    }
    close(fd);
    FFLogTag(@"FileOp", @"create file %@", target);
    return YES;
}

- (BOOL)renameItemAtPath:(NSString *)path toPath:(NSString *)newPath
                   error:(NSError **)error
{
    return [self renameItemAtPath:path toPath:newPath overwrite:NO error:error];
}

- (BOOL)renameItemAtPath:(NSString *)path toPath:(NSString *)newPath
               overwrite:(BOOL)overwrite
                   error:(NSError **)error
{
    // 同目录重命名：校验共享父目录后使用 rename（原子）。
    if (![path.stringByDeletingLastPathComponent
            isEqualToString:newPath.stringByDeletingLastPathComponent]) {
        if (error) *error = FFOperationError(EINVAL, @"重命名", path);
        return NO;
    }
    // 默认禁止覆盖。
    struct stat targetStatus = {0};
    if (lstat(newPath.fileSystemRepresentation, &targetStatus) == 0 && !overwrite) {
        if (error) *error = FFOperationError(EEXIST, @"重命名", newPath);
        return NO;
    }
    NSString *detail = nil;
    NSString *finalName = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:path
        finalName:&finalName errorMessage:&detail];
    if (!parent) {
        if (error) *error = FFOperationError(EPERM, @"重命名", path);
        return NO;
    }
    if (rename(path.fileSystemRepresentation, newPath.fileSystemRepresentation) != 0) {
        int saved = errno;
        if (error) *error = FFOperationError(saved, @"重命名", path);
        return NO;
    }
    FFLogTag(@"FileOp", @"rename %@ -> %@", path, newPath);
    return YES;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error
{
    NSString *detail = nil;
    NSString *finalName = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:path
        finalName:&finalName errorMessage:&detail];
    if (!parent) {
        if (error) *error = FFOperationError(EPERM, @"删除", path);
        return NO;
    }
    return [self removeRecursivelyAtPath:path error:error];
}

// 递归删除：lstat 逐项判断（不跟随符号链接），目录内容删除后 rmdir。
- (BOOL)removeRecursivelyAtPath:(NSString *)path error:(NSError **)error
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) {
        int saved = errno;
        if (error) *error = FFOperationError(saved, @"删除", path);
        return NO;
    }
    if (S_ISLNK(status.st_mode) || !S_ISDIR(status.st_mode)) {
        if (unlink(path.fileSystemRepresentation) != 0) {
            int saved = errno;
            if (error) *error = FFOperationError(saved, @"删除", path);
            return NO;
        }
        return YES;
    }
    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) {
        int saved = errno;
        if (error) *error = FFOperationError(saved, @"删除", path);
        return NO;
    }
    struct dirent *entry = NULL;
    BOOL ok = YES;
    while (ok && (entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        ok = [self removeRecursivelyAtPath:
            [path stringByAppendingPathComponent:name] error:error];
    }
    closedir(dir);
    if (!ok) return NO;
    if (rmdir(path.fileSystemRepresentation) != 0) {
        int saved = errno;
        if (error) *error = FFOperationError(saved, @"删除", path);
        return NO;
    }
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
