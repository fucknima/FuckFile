#import "FFAppDataVirtualPath.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataLeaseManager.h"
#import "FFStorageEnvironment.h"
#import "FFAppNames.h"
#import "FFLogger.h"

#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *FFStandardPath(NSString *path)
{
    return path.stringByStandardizingPath ?: path;
}

BOOL FFAppDataIsVirtualRootPath(NSString *path)
{
    if (!path.length) return NO;
    return [FFStandardPath(path) isEqualToString:FFStandardPath(FFAppDataVirtualPath())];
}

BOOL FFAppDataExtractLogicalIdentifier(NSString *path,
                                       NSString **identifierOut,
                                       NSString **relativePathOut)
{
    if (identifierOut) *identifierOut = nil;
    if (relativePathOut) *relativePathOut = nil;
    if (!path.length) return NO;

    NSString *root = FFStandardPath(FFAppDataVirtualPath());
    NSString *candidate = FFStandardPath(path);
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (![candidate hasPrefix:prefix]) return NO;

    NSString *relative = [candidate substringFromIndex:prefix.length];
    NSArray<NSString *> *parts = relative.pathComponents;
    if (parts.count == 0) return NO;
    NSString *identifier = parts.firstObject;
    if (!identifier.length || [identifier isEqualToString:@"/"]) return NO;

    NSString *tail = @"";
    if (parts.count > 1) {
        NSArray<NSString *> *rest = [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)];
        tail = [NSString pathWithComponents:rest];
        if ([tail isEqualToString:@"/"]) tail = @"";
    }
    if (identifierOut) *identifierOut = identifier;
    if (relativePathOut) *relativePathOut = tail;
    return YES;
}

static BOOL FFMaterializeSessionLink(NSString *identifier, NSString *target, NSError **error)
{
    NSString *root = FFAppDataVirtualPath();
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];

    NSString *link = [root stringByAppendingPathComponent:identifier];
    struct stat st = {0};
    if (lstat(link.fileSystemRepresentation, &st) == 0 && !S_ISLNK(st.st_mode)) {
        if (error) {
            *error = [NSError errorWithDomain:@"FFAppDataVirtualPath" code:20
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"AppData/%@ 被真实文件或目录占用，拒绝覆盖", identifier]}];
        }
        return NO;
    }

    if (S_ISLNK(st.st_mode)) {
        char current[PATH_MAX] = {0};
        ssize_t length = readlink(link.fileSystemRepresentation, current, sizeof(current) - 1);
        if (length > 0) {
            current[length] = '\0';
            NSString *existing = [NSString stringWithUTF8String:current];
            if ([existing isEqualToString:target]) return YES;
        }
    }

    NSString *temp = [root stringByAppendingPathComponent:
        [NSString stringWithFormat:@".ff-appdata-link-%@", NSUUID.UUID.UUIDString]];
    if (symlink(target.fileSystemRepresentation, temp.fileSystemRepresentation) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"创建 AppData 会话映射失败 errno=%d", errno]}];
        }
        return NO;
    }

    // rename(2) atomically replaces an existing symlink, so a reinstall that
    // changes the container UUID never exposes a half-updated mapping.
    if (rename(temp.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
        int saved = errno;
        unlink(temp.fileSystemRepresentation);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"更新 AppData 会话映射失败 errno=%d", saved]}];
        }
        return NO;
    }
    return YES;
}

BOOL FFAppDataEnsureLogicalPathMaterialized(NSString *logicalPath, NSError **error)
{
    NSString *identifier = nil;
    if (!FFAppDataExtractLogicalIdentifier(logicalPath, &identifier, NULL)) return YES;

    FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
    [registry prepareVirtualRootAndMigrateLegacyLinks];

    NSError *leaseError = nil;
    NSString *target = [FFAppDataLeaseManager.sharedManager
        acquireIdentifier:identifier error:&leaseError];
    if (!target.length) {
        if (error) *error = leaseError;
        return NO;
    }

    NSString *displayName = FFAppContainerItemName(target);
    if (!displayName.length) displayName = FFAppDisplayName(identifier);
    [registry registerIdentifier:identifier displayName:displayName];

    NSError *linkError = nil;
    BOOL ok = FFMaterializeSessionLink(identifier, target, &linkError);
    if (!ok && error) *error = linkError;
    if (ok) {
        FFLogTag(@"AppDataVirtual", @"materialized id=%@ target=%@", identifier, target);
    }
    return ok;
}

NSString *FFAppDataResolveLogicalPath(NSString *logicalPath, NSError **error)
{
    if (!logicalPath.length) return nil;
    NSString *identifier = nil;
    NSString *relative = nil;
    if (!FFAppDataExtractLogicalIdentifier(logicalPath, &identifier, &relative))
        return logicalPath;

    NSError *leaseError = nil;
    NSString *target = [FFAppDataLeaseManager.sharedManager
        acquireIdentifier:identifier error:&leaseError];
    if (!target.length) {
        if (error) *error = leaseError;
        return nil;
    }

    NSString *displayName = FFAppContainerItemName(target);
    if (!displayName.length) displayName = FFAppDisplayName(identifier);
    [FFAppDataRegistry.sharedRegistry registerIdentifier:identifier displayName:displayName];

    if (!relative.length) return target;
    return [target stringByAppendingPathComponent:relative];
}

void FFAppDataMaterializeKnownForTraversal(NSUInteger maxConcurrency)
{
    NSArray<NSString *> *identifiers = FFAppDataRegistry.sharedRegistry.identifiers;
    if (identifiers.count == 0) return;
    NSUInteger workers = MAX((NSUInteger)1, MIN(maxConcurrency ?: 1, (NSUInteger)8));
    workers = MIN(workers, identifiers.count);

    NSObject *indexLock = [NSObject new];
    __block NSUInteger next = 0;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    for (NSUInteger worker = 0; worker < workers; worker++) {
        dispatch_group_async(group, queue, ^{
            while (YES) {
                NSString *identifier = nil;
                @synchronized (indexLock) {
                    if (next < identifiers.count) identifier = identifiers[next++];
                }
                if (!identifier) break;
                NSString *logical = [FFAppDataVirtualPath() stringByAppendingPathComponent:identifier];
                NSError *error = nil;
                if (!FFAppDataEnsureLogicalPathMaterialized(logical, &error)) {
                    FFLogTag(@"AppDataVirtual", @"search prewarm failed id=%@ error=%@",
                        identifier, error.localizedDescription ?: @"(nil)");
                }
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}
