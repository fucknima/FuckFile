#import "FFImportService.h"
#import "FFCopyEngine.h"
#import "FFLogger.h"
#import "MCMManager.h"

#import <errno.h>

static NSErrorDomain const FFImportErrorDomain = @"FFImportErrorDomain";

typedef NS_ENUM(NSInteger, FFImportErrorCode) {
    FFImportErrorInvalidInput = 1,
    FFImportErrorCopyFailed = 2,
    FFImportErrorCommitFailed = 3,
    FFImportErrorNoDestinationName = 4,
    FFImportErrorCoordinationFailed = 5,
};

static NSString *FFImportDistinctDestination(NSString *name, NSString *directory)
{
    NSString *safeName = name.lastPathComponent.length ? name.lastPathComponent : @"imported";
    NSString *candidate = [directory stringByAppendingPathComponent:safeName];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;

    NSString *base = safeName.stringByDeletingPathExtension;
    NSString *extension = safeName.pathExtension.length
        ? [@"." stringByAppendingString:safeName.pathExtension] : @"";
    for (NSInteger index = 2; index < 10000; index++) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ (%ld)%@", base, (long)index, extension]];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static BOOL FFImportPathInsideRoot(NSString *path, NSString *root)
{
    if (!path.length || !root.length) return NO;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *base = root.stringByStandardizingPath;
    if ([candidate isEqualToString:base]) return YES;
    return [candidate hasPrefix:[base stringByAppendingString:@"/"]];
}

@interface FFImportResult ()
@property(nonatomic) BOOL success;
@property(nonatomic, copy) NSString *sourcePath;
@property(nonatomic, copy, nullable) NSString *destinationPath;
@property(nonatomic, copy, nullable) NSError *error;
@property(nonatomic) BOOL usedSecurityScope;
@property(nonatomic) BOOL coordinated;
@end

@implementation FFImportResult
@end

@implementation FFImportService

+ (FFImportResult *)importURL:(NSURL *)url
                 displayName:(NSString *)displayName
                 toDirectory:(NSString *)directory
{
    FFImportResult *result = [FFImportResult new];
    result.sourcePath = url.path ?: @"";

    if (!url || !url.isFileURL || !url.path.length || !directory.length) {
        result.error = [NSError errorWithDomain:FFImportErrorDomain
            code:FFImportErrorInvalidInput userInfo:@{
                NSLocalizedDescriptionKey: @"导入参数无效"}];
        return result;
    }

    NSString *name = displayName.lastPathComponent.length
        ? displayName.lastPathComponent
        : (url.lastPathComponent.length ? url.lastPathComponent : @"imported");
    NSString *staging = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".ffimport-%@", NSUUID.UUID.UUIDString]];

    NSString *home = NSHomeDirectory();
    BOOL stableLocalSource = FFImportPathInsideRoot(url.path, home) ||
        [[MCMManager sharedManager] hasActiveLeaseForPath:url.path];

    __block BOOL copied = NO;
    __block NSError *copyError = nil;

    if (stableLocalSource) {
        FFLogTag(@"Import", @"COPY direct src=%@ staging=%@", url.path, staging);
        copied = [FFCopyEngine copyItemAtPath:url.path toPath:staging error:&copyError];
    } else {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        result.usedSecurityScope = scoped;
        FFLogTag(@"Import", @"COPY external scope=%d src=%@", scoped, url.path);

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError = nil;
        __block BOOL accessorEntered = NO;
        [coordinator coordinateReadingItemAtURL:url
            options:NSFileCoordinatorReadingWithoutChanges
            error:&coordinationError
            byAccessor:^(NSURL *coordinatedURL) {
                accessorEntered = YES;
                result.coordinated = YES;
                FFLogTag(@"Import", @"COORDINATED COPY src=%@ staging=%@",
                    coordinatedURL.path, staging);
                copied = [FFCopyEngine copyItemAtPath:coordinatedURL.path
                    toPath:staging error:&copyError];
            }];

        if (scoped) [url stopAccessingSecurityScopedResource];

        if (coordinationError && !copied) {
            result.error = [NSError errorWithDomain:FFImportErrorDomain
                code:FFImportErrorCoordinationFailed userInfo:@{
                    NSLocalizedDescriptionKey: coordinationError.localizedDescription
                        ?: @"文件协调失败",
                    NSUnderlyingErrorKey: coordinationError}];
        } else if (!accessorEntered && !copied) {
            result.error = [NSError errorWithDomain:FFImportErrorDomain
                code:FFImportErrorCoordinationFailed userInfo:@{
                    NSLocalizedDescriptionKey: @"系统没有提供可读取的文件 URL"}];
        }
    }

    if (!copied) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        if (!result.error) {
            result.error = [NSError errorWithDomain:FFImportErrorDomain
                code:FFImportErrorCopyFailed userInfo:
                    copyError ? @{NSLocalizedDescriptionKey: copyError.localizedDescription
                        ?: @"复制来源文件失败", NSUnderlyingErrorKey: copyError}
                              : @{NSLocalizedDescriptionKey: @"复制来源文件失败"}];
        }
        FFLogTag(@"Import", @"COPY FAIL src=%@ error=%@", url.path,
            copyError ?: result.error);
        return result;
    }

    NSString *destination = FFImportDistinctDestination(name, directory);
    if (!destination.length) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        result.error = [NSError errorWithDomain:FFImportErrorDomain
            code:FFImportErrorNoDestinationName userInfo:@{
                NSLocalizedDescriptionKey: @"无法生成不冲突的目标文件名"}];
        return result;
    }

    NSError *commitError = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:staging
        toPath:destination error:&commitError]) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        result.error = [NSError errorWithDomain:FFImportErrorDomain
            code:FFImportErrorCommitFailed userInfo:
                commitError ? @{NSLocalizedDescriptionKey: commitError.localizedDescription
                    ?: @"提交导入文件失败", NSUnderlyingErrorKey: commitError}
                            : @{NSLocalizedDescriptionKey: @"提交导入文件失败"}];
        FFLogTag(@"Import", @"COMMIT FAIL staging=%@ dest=%@ error=%@",
            staging, destination, commitError);
        return result;
    }

    result.success = YES;
    result.destinationPath = destination;
    FFLogTag(@"Import", @"OK src=%@ dest=%@ scope=%d coordinated=%d",
        url.path, destination, result.usedSecurityScope, result.coordinated);
    return result;
}

+ (NSArray<FFImportResult *> *)importURLs:(NSArray<NSURL *> *)urls
                             toDirectory:(NSString *)directory
{
    NSMutableArray<FFImportResult *> *results = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [results addObject:[self importURL:url displayName:nil toDirectory:directory]];
    }
    return results;
}

@end
