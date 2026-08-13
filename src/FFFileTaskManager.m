#import "FFFileTaskManager.h"
#import "FFCopyEngine.h"
#import "FFZipExtract.h"
#import "FFLogger.h"

NSNotificationName const FFFileTaskManagerDidChangeNotification =
    @"FFFileTaskManagerDidChangeNotification";

@interface FFFileTaskManager ()
@property(nonatomic, strong) NSMutableArray<FFFileTask *> *taskList;
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, strong) NSLock *lock;
@end

@implementation FFFileTaskManager

+ (instancetype)sharedManager
{
    static FFFileTaskManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [FFFileTaskManager new]; });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _taskList = [NSMutableArray array];
        _workQueue = dispatch_queue_create("ff.tasks", DISPATCH_QUEUE_SERIAL);
        _lock = [NSLock new];
    }
    return self;
}

- (NSArray<FFFileTask *> *)tasks
{
    [self.lock lock];
    NSArray *copy = [self.taskList copy];
    [self.lock unlock];
    return copy;
}

- (void)enqueueTask:(FFFileTask *)task
{
    [self.lock lock];
    if (self.taskList.count >= 50) {
        // Drop the oldest finished tasks to bound the history.
        NSMutableArray *trimmed = [NSMutableArray array];
        for (FFFileTask *existing in self.taskList)
            if (existing.state == FFFileTaskStateQueued || existing.state == FFFileTaskStateRunning)
                [trimmed addObject:existing];
        [self.taskList removeAllObjects];
        [self.taskList addObjectsFromArray:trimmed];
    }
    [self.taskList insertObject:task atIndex:0];
    [self.lock unlock];
    [self notifyChange];

    dispatch_async(self.workQueue, ^{ [self executeTask:task]; });
}

- (void)cancelTask:(FFFileTask *)task
{
    task.cancelled = YES;
    if (task.state == FFFileTaskStateQueued)
        task.state = FFFileTaskStateCancelled;
    [self notifyChange];
}

- (void)removeTask:(FFFileTask *)task
{
    if (task.state == FFFileTaskStateQueued || task.state == FFFileTaskStateRunning)
        return;
    [self.lock lock];
    [self.taskList removeObject:task];
    [self.lock unlock];
    [self notifyChange];
}

- (void)notifyChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFFileTaskManagerDidChangeNotification object:self];
    });
}

- (void)executeTask:(FFFileTask *)task
{
    if (task.cancelled || task.state == FFFileTaskStateCancelled) return;
    task.state = FFFileTaskStateRunning;
    [self notifyChange];
    FFLogTag(@"Tasks", @"begin kind=%ld name=%@ sources=%lu",
             (long)task.kind, task.displayName, (unsigned long)task.sources.count);

    BOOL ok = YES;
    switch (task.kind) {
        case FFFileTaskKindCopy:
        case FFFileTaskKindMove:
            ok = [self executeCopyLikeTask:task];
            break;
        case FFFileTaskKindExtract:
            ok = [self executeExtractTask:task];
            break;
    }

    if (task.cancelled) {
        task.state = FFFileTaskStateCancelled;
        FFLogTag(@"Tasks", @"cancelled %@", task.displayName);
    } else if (ok) {
        task.state = FFFileTaskStateCompleted;
        FFLogTag(@"Tasks", @"completed %@ ok=%lu fail=%lu skip=%lu",
                 task.displayName, (unsigned long)task.succeededCount,
                 (unsigned long)task.failedCount, (unsigned long)task.skippedCount);
    } else {
        task.state = FFFileTaskStateFailed;
        FFLogTag(@"Tasks", @"failed %@ error=%@", task.displayName, task.error);
    }
    [self notifyChange];
}

- (BOOL)executeCopyLikeTask:(FFFileTask *)task
{
    FFConflictAction applyAll = FFConflictActionAsk;
    unsigned long long total = 0;
    for (NSString *source in task.sources)
        total += [FFCopyEngine sizeOfItemAtPath:source];
    task.totalBytes = total;
    unsigned long long completed = 0;
    __weak FFFileTask *weakTask = task;

    for (NSString *source in task.sources) {
        if (task.cancelled) return NO;
        NSString *name = source.lastPathComponent;
        task.detailName = name;
        [self notifyChange];
        NSString *destination = [task.destination stringByAppendingPathComponent:name];
        struct stat existing = {0};
        BOOL conflict = lstat(destination.fileSystemRepresentation, &existing) == 0;
        if (conflict) {
            FFConflictAction action = applyAll != FFConflictActionAsk
                ? applyAll
                : (self.conflictHandler ? self.conflictHandler(name) : FFConflictActionSkip);
            if (action == FFConflictActionSkip || action == FFConflictActionSkipAll) {
                if (action == FFConflictActionSkipAll) applyAll = action;
                task.skippedCount++;
                continue;
            }
            if (action == FFConflictActionReplaceAll) applyAll = action;
            if (action == FFConflictActionReplace || action == FFConflictActionReplaceAll) {
                NSError *removeError = nil;
                if (![[NSFileManager defaultManager] removeItemAtPath:destination error:&removeError]) {
                    task.failedCount++;
                    task.error = removeError;
                    continue;
                }
            } else {
                destination = [self uniqueDestinationForName:name inDirectory:task.destination];
                if (!destination) {
                    task.failedCount++;
                    continue;
                }
            }
        }
        unsigned long long fileTotal = [FFCopyEngine sizeOfItemAtPath:source];
        NSError *error = nil;
        BOOL copied = [FFCopyEngine copyItemAtPath:source toPath:destination
            progress:^(unsigned long long fileCopied, unsigned long long fileAll) {
                weakTask.completedBytes = completed + fileCopied;
                weakTask.progress = weakTask.totalBytes > 0
                    ? (double)weakTask.completedBytes / (double)weakTask.totalBytes : 0;
                [self notifyChange];
            } error:&error];
        if (!copied) {
            task.failedCount++;
            task.error = error;
            continue;
        }
        completed += fileTotal;
        task.completedBytes = completed;
        task.progress = task.totalBytes > 0 ? (double)completed / (double)total : 1.0;
        if (task.kind == FFFileTaskKindMove) {
            NSError *removeError = nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:source error:&removeError]) {
                task.failedCount++;
                task.error = removeError;
                continue;
            }
        }
        task.succeededCount++;
        [self notifyChange];
    }
    task.progress = 1.0;
    return task.failedCount == 0;
}

- (NSString *)uniqueDestinationForName:(NSString *)name inDirectory:(NSString *)directory
{
    if (name.length == 0) return nil;
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
        return candidate;
    NSString *extension = name.pathExtension;
    NSString *stem = extension.length ? name.stringByDeletingPathExtension : name;
    for (NSUInteger index = 1; index <= 999; index++) {
        NSString *suffix = index == 1 ? @" 2" : [NSString stringWithFormat:@" %lu", (unsigned long)(index + 1)];
        NSString *copyName = [stem stringByAppendingString:suffix];
        if (extension.length) copyName = [copyName stringByAppendingPathExtension:extension];
        candidate = [directory stringByAppendingPathComponent:copyName];
        if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
            return candidate;
    }
    return nil;
}

- (BOOL)executeExtractTask:(FFFileTask *)task
{
    __weak FFFileTask *weakTask = task;
    NSError *error = nil;
    NSArray<NSString *> *entries = nil;
    BOOL ok = FFZipExtractWithProgress(task.sources.firstObject, task.destination,
        &entries,
        ^(double progress, NSString *entryName) {
            weakTask.progress = progress;
            weakTask.detailName = entryName;
            [self notifyChange];
        },
        ^BOOL { return weakTask.cancelled; },
        &error);
    if (ok) {
        task.succeededCount = entries.count;
        task.progress = 1.0;
    } else if (!task.cancelled) {
        task.failedCount = 1;
        task.error = error;
    }
    return ok;
}

@end
