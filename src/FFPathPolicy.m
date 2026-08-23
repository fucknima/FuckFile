#import "FFPathPolicy.h"
#import "FFLogger.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

@implementation FFPathPolicy

+ (NSString *)documentsRoot
{
    return NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// Filza 式写入前置校验：直接以只读目录方式 open 目标父目录一次。
// 容器路径在 MHA profile/extension 的前缀覆盖内即可打开；不依赖
// 逐级 openat（"/" 不在前缀内会 EPERM）也不依赖符号链接链。
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
    // O_NOFOLLOW 防止父目录本身是指向系统位置的符号链接；
    // 中间组件（我们的 App Data 链接）由内核跟随到 /private/var，
    // 命中 MHA 前缀则放行，否则 EPERM。
    int descriptor = open(parent.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        int saved = errno;
        FFLogTag(@"FFPathPolicy", @"open parent FAIL path=%@ errno=%d (%s)",
            parent, saved, strerror(saved));
        if (errorMessage) *errorMessage = [NSString stringWithFormat:
            @"父目录不可访问 errno=%d (%s)", saved, strerror(saved)];
        return nil;
    }
    close(descriptor);
    if (finalName) *finalName = last;
    return parent;
}

@end
