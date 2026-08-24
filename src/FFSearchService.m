#import "FFSearchService.h"
#import "FFLogger.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"

#import <dirent.h>
#import <limits.h>
#import <string.h>
#import <sys/stat.h>

static NSString *const kFFSearchHistoryKey = @"FFSearchHistory";
static const NSUInteger kFFSearchHistoryLimit = 20;
static const NSUInteger kFFSearchBatchSize = 50;
static const NSUInteger kFFSearchMaxDepth = 16;

@implementation FFFoundItem
@end

@interface FFSearchService ()
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSMutableSet<NSString *> *visitedRealPaths;
@end

@implementation FFSearchService

+ (instancetype)sharedService
{
    static FFSearchService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [FFSearchService new]; });
    return service;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("ff.search", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startSearch:(NSString *)query
          underRoot:(NSString *)root
              batch:(void (^)(NSArray<FFFoundItem *> *))batch
         completion:(void (^)(BOOL))completion
{
    NSString *needle = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (needle.length == 0) {
        if (completion) completion(NO);
        return;
    }
    self.cancelled = NO;
    self.generation++;
    NSUInteger gen = self.generation;
    self.visitedRealPaths = [NSMutableSet set];
    dispatch_async(self.workQueue, ^{
        BOOL finished = [self searchFor:needle underPath:root depth:0
                                   generation:gen batch:batch];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion && self.generation == gen) completion(finished);
        });
    });
}

- (void)cancel
{
    self.cancelled = YES;
    self.generation++;
}

- (BOOL)searchFor:(NSString *)needle underPath:(NSString *)path depth:(NSUInteger)depth
            generation:(NSUInteger)generation
              batch:(void (^)(NSArray<FFFoundItem *> *))batch
{
    if (self.cancelled || self.generation != generation || depth > kFFSearchMaxDepth)
        return NO;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return YES;

    BOOL advancedReady = FFSystemAccessManager.sharedManager.ready;
    NSMutableArray<FFFoundItem *> *pending = [NSMutableArray array];
    NSMutableArray<NSString *> *subdirectories = [NSMutableArray array];
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (self.cancelled || self.generation != generation) break;
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name || [name hasPrefix:@"."]) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        if (!advancedReady && FFPathRequiresSystemAccess(child)) continue;

        struct stat status = {0};
        if (stat(child.fileSystemRepresentation, &status) != 0) continue;
        BOOL isDirectory = S_ISDIR(status.st_mode);
        BOOL matches = [name.lowercaseString containsString:needle];
        if (matches) {
            FFFoundItem *item = [FFFoundItem new];
            item.name = name;
            item.path = child;
            item.isDirectory = isDirectory;
            item.size = S_ISREG(status.st_mode) ? (unsigned long long)status.st_size : 0;
            [pending addObject:item];
        }
        if (isDirectory) [subdirectories addObject:child];
        if (pending.count >= kFFSearchBatchSize) {
            NSArray *flush = [pending copy];
            [pending removeAllObjects];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (batch && self.generation == generation) batch(flush);
            });
        }
    }
    closedir(directory);

    for (NSString *sub in subdirectories) {
        if (self.cancelled || self.generation != generation) break;
        if (!FFSystemAccessManager.sharedManager.ready && FFPathRequiresSystemAccess(sub)) continue;
        char resolved[PATH_MAX] = {0};
        if (!realpath(sub.fileSystemRepresentation, resolved)) continue;
        NSString *key = [NSString stringWithUTF8String:resolved];
        if ([self.visitedRealPaths containsObject:key]) continue;
        [self.visitedRealPaths addObject:key];
        [self searchFor:needle underPath:sub depth:depth + 1
              generation:generation batch:batch];
    }

    if (pending.count > 0) {
        NSArray *flush = [pending copy];
        [pending removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (batch && self.generation == generation) batch(flush);
        });
    }
    return !self.cancelled && self.generation == generation;
}

- (NSArray<NSString *> *)history
{
    NSArray *history = [NSUserDefaults.standardUserDefaults
        arrayForKey:kFFSearchHistoryKey];
    return [history isKindOfClass:NSArray.class] ? history : @[];
}

- (void)addHistory:(NSString *)query
{
    query = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) return;
    NSMutableArray *history = [self.history mutableCopy];
    [history removeObject:query];
    [history insertObject:query atIndex:0];
    while (history.count > kFFSearchHistoryLimit) [history removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:history forKey:kFFSearchHistoryKey];
}

- (void)clearHistory
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFFSearchHistoryKey];
}

@end
