#import "FFSearchService.h"
#import "FFLogger.h"

#import <dirent.h>
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
    dispatch_async(self.workQueue, ^{
        BOOL finished = [self searchFor:needle underPath:root depth:0
                                   batch:batch];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(finished);
        });
    });
}

- (void)cancel
{
    self.cancelled = YES;
}

- (BOOL)searchFor:(NSString *)needle underPath:(NSString *)path depth:(NSUInteger)depth
            batch:(void (^)(NSArray<FFFoundItem *> *))batch
{
    if (self.cancelled || depth > kFFSearchMaxDepth) return NO;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return YES;

    NSMutableArray<FFFoundItem *> *pending = [NSMutableArray array];
    NSMutableArray<NSString *> *subdirectories = [NSMutableArray array];
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (self.cancelled) break;
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name || [name hasPrefix:@"."]) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(child.fileSystemRepresentation, &status) != 0) continue;
        BOOL isDirectory = S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
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
                if (batch && !self.cancelled) batch(flush);
            });
        }
    }
    closedir(directory);

    // Depth-first into subdirectories (skips symlinked dirs to avoid
    // cycles; MCM link folders are the traversal roots themselves).
    for (NSString *sub in subdirectories) {
        if (self.cancelled) break;
        [self searchFor:needle underPath:sub depth:depth + 1 batch:batch];
    }

    if (pending.count > 0) {
        NSArray *flush = [pending copy];
        [pending removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (batch && !self.cancelled) batch(flush);
        });
    }
    return !self.cancelled;
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
