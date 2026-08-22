#import "FFFileTaskManager.h"
#import "FFCopyEngine.h"
#import "FFZipExtract.h"
#import "FFZipCreate.h"
#import "FFLogger.h"

#import <errno.h>
#import <sys/stat.h>

NSNotificationName const FFFileTaskManagerDidChangeNotification =
    @"FFFileTaskManagerDidChangeNotification";

@interface FFFileTaskManager ()
@property(nonatomic, strong) NSMutableArray<FFFileTask *> *taskList;
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic) NSTimeInterval lastProgressNotify;
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

- (void)retryTask:(FFFileTask *)task
{
    task.state = FFFileTaskStateQueued;
    task.cancelled = NO;
    task.error = nil;
    task.progress = 0;
    task.completedBytes = 0;
    task.totalBytes = 0;
    task.averageBytesPerSecond = 0;
    task.estimatedRemainingSeconds = 0;
    task.succeededCount = 0;
    task.failedCount = 0;
    task.skippedCount = 0;
    task.detailName = nil;
    [self notifyChange];
    dispatch_async(self.workQueue, ^{ [self executeTask:task]; });
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

// 进度通知限频：每 0.15 秒最多一次，避免 64KB 块级通知刷爆主线程。
- (void)notifyChangeThrottled
{
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (now - self.lastProgressNotify < 0.15) return;
    self.lastProgressNotify = now;
    [self notifyChange];
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
        case FFFileTaskKindCompress:
            ok = [self executeCompressTask:task];
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
    NSDate *taskStart = NSDate.date;

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
                : (task.conflictHandler ? task.conflictHandler(name)
                   : (self.conflictHandler ? self.conflictHandler(name)
                      : FFConflictActionSkip));
            if (action == FFConflictActionSkip || action == FFConflictActionSkipAll) {
                if (action == FFConflictActionSkipAll) applyAll = action;
                task.skippedCount++;
                continue;
            }
            if (action == FFConflictActionReplaceAll) applyAll = action;
            if (action == FFConflictActionReplace || action == FFConflictActionReplaceAll) {
                // 目标保留：文件走 temp+rename 原子覆盖；目录由下方
                // 备份-替换机制处理。这里不做删除。
                if (!S_ISDIR(existing.st_mode) || S_ISLNK(existing.st_mode)) {
                    // 文件/链接：留给 temp+rename 覆盖。
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
        // 复制到同目录临时文件，成功后原子替换目标。
        // 这避免了“先删目标再复制”的窗口，也避免 O_EXCL 与已有目标冲突。
        NSString *tempDestination = [destination stringByAppendingFormat:@".%d.tmp",
            (int)getpid() * 31 + (int)(arc4random() % 100000)];
        BOOL copied = [FFCopyEngine copyItemAtPath:source toPath:tempDestination
            progress:^(unsigned long long fileCopied, unsigned long long fileAll) {
                weakTask.completedBytes = completed + fileCopied;
                weakTask.progress = weakTask.totalBytes > 0
                    ? (double)weakTask.completedBytes / (double)weakTask.totalBytes : 0;
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:taskStart];
                if (elapsed > 0.5 && weakTask.completedBytes > 0) {
                    weakTask.averageBytesPerSecond =
                        (double)weakTask.completedBytes / elapsed;
                    if (weakTask.totalBytes > weakTask.completedBytes)
                        weakTask.estimatedRemainingSeconds =
                            (double)(weakTask.totalBytes - weakTask.completedBytes) /
                            weakTask.averageBytesPerSecond;
                }
                [self notifyChangeThrottled];
            } error:&error];
        if (!copied) {
            // 失败：清理临时文件，目标保持原样。
            [[NSFileManager defaultManager] removeItemAtPath:tempDestination error:nil];
            task.failedCount++;
            task.error = error;
            continue;
        }
        // 原子替换：rename 覆盖已有目标（同目录，原子）。
        if (rename(tempDestination.fileSystemRepresentation,
                   destination.fileSystemRepresentation) != 0) {
            int saved = errno;
            // 目录替换：rename 无法覆盖非空目录，改用备份-替换-清理。
            BOOL handled = NO;
            if ((saved == ENOTEMPTY || saved == EEXIST || saved == EISDIR) &&
                [self replaceDirectoryBackup:tempDestination destination:destination]) {
                handled = YES;
            }
            if (!handled) {
                [[NSFileManager defaultManager] removeItemAtPath:tempDestination error:nil];
                task.failedCount++;
                task.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"替换目标失败：%@ (%s)", destination, strerror(saved)]}];
                continue;
            }
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

// 目录原子替换：把旧目录备份到 .old，放入新目录，成功后清理备份；
// 失败时恢复备份。任何一步失败都不破坏原数据。
- (BOOL)replaceDirectoryBackup:(NSString *)tempDestination
                   destination:(NSString *)destination
{
    NSString *backupPath = [NSString stringWithFormat:@"%@.old%@", destination,
        [[[NSUUID UUID] UUIDString] substringToIndex:8]];
    NSFileManager *fm = NSFileManager.defaultManager;

    // 1. 备份旧目录（rename 原子）。
    if ([fm fileExistsAtPath:destination]) {
        if (![fm moveItemAtPath:destination toPath:backupPath error:nil]) return NO;
    }
    // 2. 放入新目录。
    if (![fm moveItemAtPath:tempDestination toPath:destination error:nil]) {
        // 失败：恢复备份。
        if ([fm fileExistsAtPath:backupPath])
            [fm moveItemAtPath:backupPath toPath:destination error:nil];
        return NO;
    }
    // 3. 清理备份（失败仅产生垃圾目录，不影响结果）。
    if ([fm fileExistsAtPath:backupPath])
        [fm removeItemAtPath:backupPath error:nil];
    return YES;
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

- (BOOL)executeCompressTask:(FFFileTask *)task
{
    __weak FFFileTask *weakTask = task;
    NSError *error = nil;
    BOOL ok = FFCreateZipArchive(task.sources, task.destination,
        ^(double progress, NSString *entryName) {
            weakTask.progress = progress;
            weakTask.detailName = entryName;
            [self notifyChange];
        },
        ^BOOL { return weakTask.cancelled; },
        &error);
    if (ok) {
        task.succeededCount = 1;
        task.progress = 1.0;
    } else if (!task.cancelled) {
        task.failedCount = 1;
        task.error = error;
    }
    return ok;
}

@end
