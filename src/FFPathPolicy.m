#import "FFPathPolicy.h"

#import <limits.h>
#import <string.h>
#import <sys/stat.h>

// Our App Data links live under this folder name in the virtual root.
static NSString *const kFFAppDataFolderName = @"App Data";

@implementation FFPathPolicy

+ (NSString *)documentsRoot
{
    return NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
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

// Validates that the directory at `path` exists and is a real
// directory (not a symlink). Returns YES when safe.
static BOOL FFIsRealDirectory(NSString *path)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) return NO;
    return S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
}

+ (NSString *)resolveParentForMutation:(NSString *)path
                             finalName:(NSString **)finalName
                         errorMessage:(NSString **)errorMessage
{
    if (!path.length || ![path hasPrefix:@"/"]) {
        if (errorMessage) *errorMessage = @"路径必须为绝对路径";
        return nil;
    }
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSString *last = path.lastPathComponent;
    if (!parent.length || !last.length) {
        if (errorMessage) *errorMessage = @"路径不合法";
        return nil;
    }
    if ([last isEqualToString:@"."] || [last isEqualToString:@".."]) {
        if (errorMessage) *errorMessage = @"路径名不合法";
        return nil;
    }

    // Walk the parent chain, resolving our own App Data links into
    // their /var targets. Every other level must be a real directory.
    NSArray<NSString *> *components = parent.pathComponents;
    if (components.count == 0 || ![[components firstObject] isEqualToString:@"/"]) {
        if (errorMessage) *errorMessage = @"父目录不合法";
        return nil;
    }
    NSString *current = @"/";
    for (NSUInteger index = 1; index < components.count; index++) {
        NSString *component = components[index];
        NSString *candidate = [current stringByAppendingPathComponent:component];
        NSString *real = FFResolveOwnLink(candidate);
        if (real) {
            // Our App Data link: validate the resolved /var target
            // chain level by level (directories only).
            NSArray<NSString *> *realComponents = real.pathComponents;
            NSString *realCurrent = @"/";
            BOOL ok = YES;
            for (NSUInteger ri = 1; ri < realComponents.count; ri++) {
                NSString *part = realComponents[ri];
                NSString *nextPath = [realCurrent stringByAppendingPathComponent:part];
                NSString *nested = FFResolveOwnLink(nextPath);
                NSString *effective = nested ?: nextPath;
                if (!FFIsRealDirectory(effective)) {
                    ok = NO;
                    if (errorMessage) *errorMessage = [NSString stringWithFormat:
                        @"容器路径包含符号链接或不可访问：%@", nextPath];
                    break;
                }
                realCurrent = effective;
            }
            if (!ok) return nil;
            current = real;
            continue;
        }
        // Ordinary path component: must be a real directory. A foreign
        // symlink here could redirect the mutation — reject it.
        if (!FFIsRealDirectory(candidate)) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"父目录包含符号链接或不可访问：%@", candidate];
            return nil;
        }
        current = candidate;
    }

    // Final parent must be a real directory right now (lstat, not open,
    // because the sandbox cannot open system container paths).
    if (!FFIsRealDirectory(current)) {
        if (errorMessage) *errorMessage = @"父目录不可访问";
        return nil;
    }
    if (finalName) *finalName = last;
    return current;
}

@end
