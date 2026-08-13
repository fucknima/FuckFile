#import "FFPathPolicy.h"

#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

// Our App Data links live under this folder name in the virtual root.
static NSString *const kFFAppDataFolderName = @"App Data";

@implementation FFPathPolicy

+ (NSString *)documentsRoot
{
    return NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (BOOL)isInsideDocuments:(NSString *)path
{
    return path.length > [[self documentsRoot] length] &&
        [path hasPrefix:[[self documentsRoot] stringByAppendingString:@"/"]];
}

// A link is ours when it is a symlink whose target points into the
// real container tree (/var/... or /private/var/...).
+ (BOOL)isAppLinkPath:(NSString *)path
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0 || !S_ISLNK(status.st_mode))
        return NO;
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
    if (length <= 0) return NO;
    target[length] = '\0';
    NSString *resolved = [NSString stringWithUTF8String:target];
    return [resolved hasPrefix:@"/var/"] || [resolved hasPrefix:@"/private/var/"];
}

// Follows one symlink level if it is one of our App Data links; returns
// the real target path or nil when the path is a foreign/unknown link.
static NSString *FFResolveOwnLink(NSString *path)
{
    if (![FFPathPolicy isAppLinkPath:path]) return nil;
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
    if (length <= 0) return nil;
    target[length] = '\0';
    return [NSString stringWithUTF8String:target];
}

// Opens the parent chain of `path` level by level. Our own App Data
// links are resolved (their target chain is validated instead of the
// link); any other symlink in the chain is rejected so a swapped link
// can never redirect a mutation. Returns a dirfd for the parent, or -1.
+ (int)openParentDirectoryForPath:(NSString *)path
                     isFinalDirectory:(BOOL)isFinalDirectory
                         errorMessage:(NSString * * _Nullable)errorMessage
{
    if (!path.length || ![path hasPrefix:@"/"]) {
        if (errorMessage) *errorMessage = @"路径必须为绝对路径";
        return -1;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSString *last = path.lastPathComponent;
    if (!parent.length || !last.length) {
        if (errorMessage) *errorMessage = @"路径不合法";
        return -1;
    }

    // Walk the parent chain, resolving our own links.
    NSArray<NSString *> *components = parent.pathComponents;
    if (components.count == 0 || ![[components firstObject] isEqualToString:@"/"]) {
        if (errorMessage) *errorMessage = @"父目录不合法";
        return -1;
    }
    NSString *current = @"/";
    int dirfd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) {
        if (errorMessage) *errorMessage = @"无法打开根目录";
        return -1;
    }

    // components: {"/", "var", "mobile", ...} — skip the root marker.
    for (NSUInteger index = 1; index < components.count; index++) {
        NSString *component = components[index];
        NSString *candidate = [current stringByAppendingPathComponent:component];
        // Resolve our own App Data link segments.
        NSString *real = FFResolveOwnLink(candidate);
        if (real) {
            // Re-enter the chain at the resolved target. The target is
            // an absolute /var path; validate it level by level too.
            int realFd = -1;
            NSArray<NSString *> *realComponents = real.pathComponents;
            NSString *realCurrent = @"/";
            int base = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (base < 0) { close(dirfd); if (errorMessage) *errorMessage = @"无法打开根目录"; return -1; }
            BOOL ok = YES;
            for (NSUInteger ri = 1; ri < realComponents.count; ri++) {
                NSString *part = realComponents[ri];
                NSString *nextPath = [realCurrent stringByAppendingPathComponent:part];
                // No nested own-links expected inside the container, but
                // resolve them defensively.
                NSString *nested = FFResolveOwnLink(nextPath);
                NSString *effective = nested ?: nextPath;
                int next = openat(base, effective.lastPathComponent.fileSystemRepresentation,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (next < 0) {
                    ok = NO;
                    if (errorMessage) *errorMessage = [NSString stringWithFormat:
                        @"父目录包含非法链接或不可访问：%@ (%s)", nextPath, strerror(errno)];
                    break;
                }
                close(base);
                base = next;
                realCurrent = effective;
            }
            if (!ok) { close(dirfd); close(base); return -1; }
            close(dirfd);
            dirfd = base;
            current = real;
            continue;
        }
        // Ordinary directory: O_NOFOLLOW rejects foreign symlinks.
        int next = openat(dirfd, component.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"父目录包含符号链接或不可访问：%@ (%s)", candidate, strerror(errno)];
            close(dirfd);
            return -1;
        }
        close(dirfd);
        dirfd = next;
        current = candidate;
    }

    // Final component: validate type relative to the parent fd so a
    // concurrently swapped link cannot redirect us. Missing entries are
    // fine (creation), existing foreign symlinks are rejected.
    struct stat status = {0};
    if (fstatat(dirfd, last.fileSystemRepresentation, &status,
                AT_SYMLINK_NOFOLLOW) == 0) {
        BOOL isLink = S_ISLNK(status.st_mode);
        BOOL isDir = S_ISDIR(status.st_mode);
        if (isLink) {
            // The final entry may be one of our own App Data links for a
            // delete operation; anything else is rejected.
            if (![FFPathPolicy isAppLinkPath:path]) {
                if (errorMessage) *errorMessage = @"目标是指向他处的符号链接";
                close(dirfd);
                return -1;
            }
        } else if (isFinalDirectory && !isDir) {
            if (errorMessage) *errorMessage = @"目标不是目录";
            close(dirfd);
            return -1;
        }
    }
    return dirfd;
}

@end
