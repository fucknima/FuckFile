#import "FFSearchService.h"
#import "FFLogger.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFAppNames.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataVirtualPath.h"

#import <dirent.h>
#import <errno.h>
#import <limits.h>
#import <string.h>
#import <sys/stat.h>

static const NSUInteger kFFSearchBatchSize = 100;
static const NSUInteger kFFSearchMaxDepth = 64;

@implementation FFFoundItem
@end

@interface FFSearchService ()
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(atomic) BOOL cancelled;
@property(atomic) NSUInteger generation;
@property(nonatomic, strong) NSMutableSet<NSString *> *visitedRealPaths;
@property(nonatomic, copy) NSString *resolvedRoot;
@property(atomic, readwrite) FFSearchCompletionStatus completionStatus;
@property(atomic, readwrite) NSUInteger skippedDirectoryCount;
@property(atomic, readwrite) BOOL truncatedByDepth;
@property(atomic, copy, readwrite) NSString *statusMessage;
@end

@implementation FFSearchService

- (instancetype)init
{
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _workQueue = dispatch_queue_create("ff.search", attr);
        _completionStatus = FFSearchCompletionStatusCompleted;
    }
    return self;
}

static BOOL FFSearchTextMatches(NSString *field, NSString *query)
{
    if (!field.length || !query.length) return NO;
    NSStringCompareOptions options = NSCaseInsensitiveSearch |
        NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    return [field rangeOfString:query options:options].location != NSNotFound;
}

static NSString *FFResolvedPath(NSString *path)
{
    if (!path.length) return nil;
    char resolved[PATH_MAX] = {0};
    if (!realpath(path.fileSystemRepresentation, resolved)) return nil;
    return [NSString stringWithUTF8String:resolved];
}

static BOOL FFResolvedPathIsInsideRoot(NSString *path, NSString *root)
{
    if (!path.length || !root.length) return NO;
    if ([path isEqualToString:root]) return YES;
    return [path hasPrefix:[root stringByAppendingString:@"/"]];
}

- (void)resetTraversalStateForRoot:(NSString *)root
{
    self.visitedRealPaths = [NSMutableSet set];
    self.resolvedRoot = FFResolvedPath(root);
    if (self.resolvedRoot.length) [self.visitedRealPaths addObject:self.resolvedRoot];
    self.skippedDirectoryCount = 0;
    self.truncatedByDepth = NO;
    self.statusMessage = nil;
    self.completionStatus = FFSearchCompletionStatusCompleted;
}

- (void)startSearch:(NSString *)query underRoot:(NSString *)root
              batch:(void (^)(NSArray<FFFoundItem *> *))batch
         completion:(void (^)(BOOL))completion
{
    NSString *needle = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (needle.length == 0) {
        self.completionStatus = FFSearchCompletionStatusFailed;
        self.statusMessage = @"搜索关键词为空";
        if (completion) completion(NO);
        return;
    }

    self.cancelled = NO;
    NSUInteger gen = self.generation + 1;
    self.generation = gen;
    NSString *canonicalRoot = FFCanonicalStoragePath(root ?: @"");
    [self resetTraversalStateForRoot:canonicalRoot];

    dispatch_async(self.workQueue, ^{
        BOOL completed = [self searchFor:needle underPath:canonicalRoot depth:0
                              generation:gen batch:batch];

        if (self.cancelled || self.generation != gen) {
            self.completionStatus = FFSearchCompletionStatusCancelled;
            self.statusMessage = @"搜索已取消";
        } else if (!completed && self.completionStatus == FFSearchCompletionStatusCompleted) {
            self.completionStatus = FFSearchCompletionStatusPartial;
        }

        if (self.completionStatus == FFSearchCompletionStatusCompleted) {
            self.statusMessage = nil;
        } else if (self.completionStatus == FFSearchCompletionStatusPartial && !self.statusMessage.length) {
            if (self.truncatedByDepth && self.skippedDirectoryCount > 0)
                self.statusMessage = [NSString stringWithFormat:
                    @"部分目录未搜索：达到深度上限，另有 %lu 个目录不可读取",
                    (unsigned long)self.skippedDirectoryCount];
            else if (self.truncatedByDepth)
                self.statusMessage = @"搜索结果不完整：目录层级超过安全深度上限";
            else
                self.statusMessage = [NSString stringWithFormat:
                    @"搜索结果可能不完整：%lu 个目录不可读取",
                    (unsigned long)self.skippedDirectoryCount];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion && self.generation == gen)
                completion(self.completionStatus == FFSearchCompletionStatusCompleted);
        });
    });
}

- (void)cancel
{
    self.cancelled = YES;
    self.generation = self.generation + 1;
    self.completionStatus = FFSearchCompletionStatusCancelled;
}

- (NSString *)displayNameForEntryName:(NSString *)name path:(NSString *)child parent:(NSString *)parent
{
    if ([parent.stringByStandardizingPath isEqualToString:FFAppDataVirtualPath().stringByStandardizingPath]) {
        NSString *registered = [FFAppDataRegistry.sharedRegistry displayNameForIdentifier:name];
        if (registered.length) return registered;

        NSString *real = FFResolvedPath(child);
        if (real.length) {
            NSString *metadataName = FFAppContainerItemName(real);
            if (metadataName.length) return metadataName;
        }
    }
    return FFAppDisplayName(name);
}

- (void)markPartialWithMessage:(NSString *)message
{
    if (self.completionStatus == FFSearchCompletionStatusCompleted)
        self.completionStatus = FFSearchCompletionStatusPartial;
    if (message.length && !self.statusMessage.length) self.statusMessage = message;
}

- (BOOL)searchFor:(NSString *)needle underPath:(NSString *)path depth:(NSUInteger)depth
        generation:(NSUInteger)generation batch:(void (^)(NSArray<FFFoundItem *> *))batch
{
    if (self.cancelled || self.generation != generation) return NO;
    if (depth > kFFSearchMaxDepth) {
        self.truncatedByDepth = YES;
        [self markPartialWithMessage:nil];
        return NO;
    }

    BOOL advancedReady = FFSystemAccessManager.sharedManager.ready;
    if (advancedReady && FFAppDataIsVirtualRootPath(path)) {
        [FFAppDataRegistry.sharedRegistry prepareVirtualRootAndMigrateLegacyLinks];
        FFAppDataMaterializeKnownForTraversal(4);
    }

    // The visible root may itself be a managed symlink. Resolve it once, but
    // descendants must remain inside that resolved root and directory symlinks
    // are never traversed.
    NSString *realPath = FFResolvedPath(path);
    if (self.resolvedRoot.length && realPath.length &&
        !FFResolvedPathIsInsideRoot(realPath, self.resolvedRoot)) {
        self.skippedDirectoryCount = self.skippedDirectoryCount + 1;
        [self markPartialWithMessage:@"发现指向搜索范围之外的目录，已跳过"];
        return NO;
    }

    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) {
        int saved = errno;
        self.skippedDirectoryCount = self.skippedDirectoryCount + 1;
        NSString *message = [NSString stringWithFormat:@"无法读取目录：%@ (%s)",
            path.lastPathComponent.length ? path.lastPathComponent : path, strerror(saved)];
        if (depth == 0) {
            self.completionStatus = FFSearchCompletionStatusFailed;
            self.statusMessage = message;
        } else {
            [self markPartialWithMessage:message];
        }
        return NO;
    }

    BOOL showHidden = [NSUserDefaults.standardUserDefaults boolForKey:@"FFSettingsShowHiddenFiles"];
    NSMutableArray<FFFoundItem *> *pending = [NSMutableArray array];
    NSMutableArray<NSString *> *subdirectories = [NSMutableArray array];
    BOOL subtreeComplete = YES;
    struct dirent *entry = NULL;

    while ((entry = readdir(directory)) != NULL) {
        if (self.cancelled || self.generation != generation) {
            subtreeComplete = NO;
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name || (!showHidden && [name hasPrefix:@"."])) continue;
        if (FFIsInternalStorageEntry(path, name)) continue;

        NSString *child = [path stringByAppendingPathComponent:name];
        if (!advancedReady && FFPathRequiresSystemAccess(child)) continue;

        struct stat status = {0};
        if (lstat(child.fileSystemRepresentation, &status) != 0) continue;
        BOOL isSymlink = S_ISLNK(status.st_mode);
        BOOL isDirectory = S_ISDIR(status.st_mode);
        NSString *displayName = [self displayNameForEntryName:name path:child parent:path];
        BOOL matches = FFSearchTextMatches(name, needle) ||
            FFSearchTextMatches(displayName, needle);
        if (matches) {
            FFFoundItem *item = [FFFoundItem new];
            item.name = name;
            item.displayName = displayName;
            item.path = child;
            item.isDirectory = isDirectory;
            item.size = S_ISREG(status.st_mode) ? (unsigned long long)status.st_size : 0;
            [pending addObject:item];
        }

        if (isDirectory && !isSymlink) {
            NSString *resolved = FFResolvedPath(child);
            if (!resolved.length) {
                self.skippedDirectoryCount = self.skippedDirectoryCount + 1;
                [self markPartialWithMessage:nil];
            } else if (self.resolvedRoot.length &&
                !FFResolvedPathIsInsideRoot(resolved, self.resolvedRoot)) {
                self.skippedDirectoryCount = self.skippedDirectoryCount + 1;
                [self markPartialWithMessage:@"发现指向搜索范围之外的目录，已跳过"];
            } else if (![self.visitedRealPaths containsObject:resolved]) {
                [self.visitedRealPaths addObject:resolved];
                [subdirectories addObject:child];
            }
        }

        if (pending.count >= kFFSearchBatchSize) {
            NSArray *flush = pending.copy;
            [pending removeAllObjects];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (batch && self.generation == generation) batch(flush);
            });
        }
    }
    closedir(directory);

    if (pending.count > 0) {
        NSArray *flush = pending.copy;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (batch && self.generation == generation) batch(flush);
        });
    }

    for (NSString *sub in subdirectories) {
        if (self.cancelled || self.generation != generation) {
            subtreeComplete = NO;
            break;
        }
        if (!FFSystemAccessManager.sharedManager.ready && FFPathRequiresSystemAccess(sub)) continue;
        BOOL childComplete = [self searchFor:needle underPath:sub depth:depth + 1
                                  generation:generation batch:batch];
        if (!childComplete) subtreeComplete = NO;
    }

    return subtreeComplete && self.completionStatus != FFSearchCompletionStatusFailed;
}

@end