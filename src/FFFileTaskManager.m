#import "FFFileTaskManager.h"
#import "FFCopyEngine.h"
#import "FFZipExtract.h"
#import "FFArchiveService.h"
#import "FFZipCreate.h"
#import "FFLogger.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFAppDataVirtualPath.h"

#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FFFileTaskManagerDidChangeNotification =
    @"FFFileTaskManagerDidChangeNotification";

static const NSUInteger kFFTaskHistoryLimit = 50;
static const NSTimeInterval kFFTaskPersistDelay = 1.0;
static const NSTimeInterval kFFTaskPersistTrailingDelay = 0.15;
static const NSTimeInterval kFFTaskProgressNotifyInterval = 0.15;

static NSString *FFTaskHistoryPath(void)
{
    NSString *root = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!root.length)
        root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *directory = [root stringByAppendingPathComponent:@"FuckFile"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return [directory stringByAppendingPathComponent:@"TaskHistory.plist"];
}

static NSArray<NSString *> *FFCanonicalTaskSources(id rawSources)
{
    if (![rawSources isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id value in (NSArray *)rawSources) {
        if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) continue;
        [result addObject:FFCanonicalStoragePath((NSString *)value)];
    }
    return result;
}

static NSDictionary *FFTaskDictionary(FFFileTask *task)
{
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"taskID"] = task.taskID ?: NSUUID.UUID.UUIDString;
    row[@"kind"] = @(task.kind);
    row[@"displayName"] = task.displayName ?: @"文件任务";
    if (task.detailName.length) row[@"detailName"] = task.detailName;
    row[@"state"] = @(task.state);
    row[@"progress"] = @(task.progress);
    row[@"averageBytesPerSecond"] = @(task.averageBytesPerSecond);
    row[@"estimatedRemainingSeconds"] = @(task.estimatedRemainingSeconds);
    row[@"completedBytes"] = @(task.completedBytes);
    row[@"totalBytes"] = @(task.totalBytes);
    row[@"succeededCount"] = @(task.succeededCount);
    row[@"failedCount"] = @(task.failedCount);
    row[@"skippedCount"] = @(task.skippedCount);
    row[@"sources"] = FFCanonicalTaskSources(task.sources);
    row[@"destination"] = FFCanonicalStoragePath(task.destination ?: @"");
    row[@"moveSourceRemoval"] = @(task.moveSourceRemoval);
    if (task.error.localizedDescription.length)
        row[@"errorDescription"] = task.error.localizedDescription;
    if (task.error.domain.length) row[@"errorDomain"] = task.error.domain;
    row[@"errorCode"] = @(task.error.code);
    // SECURITY: archivePassword is intentionally never persisted.
    return row;
}

static FFFileTask *FFTaskFromDictionary(NSDictionary *row)
{
    if (![row isKindOfClass:NSDictionary.class]) return nil;
    NSArray<NSString *> *sources = FFCanonicalTaskSources(row[@"sources"]);
    NSString *destination = [row[@"destination"] isKindOfClass:NSString.class]
        ? FFCanonicalStoragePath(row[@"destination"]) : @"";
    NSString *displayName = [row[@"displayName"] isKindOfClass:NSString.class]
        ? row[@"displayName"] : @"文件任务";
    NSNumber *kindValue = [row[@"kind"] isKindOfClass:NSNumber.class] ? row[@"kind"] : nil;
    if (!kindValue || kindValue.integerValue < FFFileTaskKindCopy ||
        kindValue.integerValue > FFFileTaskKindCompress)
        return nil;

    FFFileTask *task = [FFFileTask new];
    NSString *taskID = [row[@"taskID"] isKindOfClass:NSString.class] ? row[@"taskID"] : nil;
    if (taskID.length) task.taskID = taskID;
    task.kind = kindValue.integerValue;
    task.displayName = displayName;
    task.detailName = [row[@"detailName"] isKindOfClass:NSString.class] ? row[@"detailName"] : nil;
    task.sources = sources;
    task.destination = destination;
    task.moveSourceRemoval = [row[@"moveSourceRemoval"] boolValue];
    task.progress = [row[@"progress"] doubleValue];
    task.averageBytesPerSecond = [row[@"averageBytesPerSecond"] doubleValue];
    task.estimatedRemainingSeconds = [row[@"estimatedRemainingSeconds"] doubleValue];
    task.completedBytes = [row[@"completedBytes"] unsignedLongLongValue];
    task.totalBytes = [row[@"totalBytes"] unsignedLongLongValue];
    task.succeededCount = [row[@"succeededCount"] unsignedIntegerValue];
    task.failedCount = [row[@"failedCount"] unsignedIntegerValue];
    task.skippedCount = [row[@"skippedCount"] unsignedIntegerValue];
    task.archivePassword = nil;
    task.cancelled = NO;

    FFFileTaskState savedState = [row[@"state"] integerValue];
    if (savedState == FFFileTaskStateQueued || savedState == FFFileTaskStateRunning) {
        task.state = FFFileTaskStateFailed;
        task.averageBytesPerSecond = 0;
        task.estimatedRemainingSeconds = 0;
        task.error = [NSError errorWithDomain:@"FFFileTaskPersistence" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"App 上次退出时任务尚未完成，任务已中断，可重试。加密压缩包需要重新输入密码后再发起。"}];
    } else if (savedState >= FFFileTaskStateCompleted && savedState <= FFFileTaskStateCancelled) {
        task.state = savedState;
        NSString *description = [row[@"errorDescription"] isKindOfClass:NSString.class]
            ? row[@"errorDescription"] : nil;
        if (description.length) {
            NSString *domain = [row[@"errorDomain"] isKindOfClass:NSString.class]
                ? row[@"errorDomain"] : @"FFFileTaskHistory";
            task.error = [NSError errorWithDomain:domain code:[row[@"errorCode"] integerValue]
                userInfo:@{NSLocalizedDescriptionKey:description}];
        }
    } else {
        task.state = FFFileTaskStateFailed;
        task.error = [NSError errorWithDomain:@"FFFileTaskPersistence" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"任务历史状态无效，可重新发起任务。"}];
    }
    return task;
}

static BOOL FFExtractErrorIsWriteAccessFailure(NSError *error)
{
    if (!error) return NO;
    if ([error.domain isEqualToString:NSPOSIXErrorDomain] &&
        (error.code == EPERM || error.code == EACCES || error.code == EROFS))
        return YES;
    if ([error.domain isEqualToString:NSCocoaErrorDomain] &&
        (error.code == NSFileWriteNoPermissionError ||
         error.code == NSFileWriteVolumeReadOnlyError))
        return YES;
    NSError *underlying = [error.userInfo[NSUnderlyingErrorKey]
        isKindOfClass:NSError.class] ? error.userInfo[NSUnderlyingErrorKey] : nil;
    return underlying ? FFExtractErrorIsWriteAccessFailure(underlying) : NO;
}

static NSString *FFFallbackExtractDestination(FFFileTask *task)
{
    NSString *archive = [FFArchiveService archiveStemForPath:task.sources.firstObject];
    NSString *root = [FFStorageRootPath() stringByAppendingPathComponent:@"Extracted"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:root
        withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        FFLogTag(@"Tasks", @"extract fallback root unavailable path=%@ error=%@",
            root, directoryError.localizedDescription ?: @"(nil)");
        return nil;
    }
    NSString *suffix = [NSUUID.UUID.UUIDString substringToIndex:8];
    return [root stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@-%@", archive, suffix]];
}

@interface FFFileTaskManager ()
@property(nonatomic, strong) NSMutableArray<FFFileTask *> *taskList;
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, strong) dispatch_queue_t persistenceQueue;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic) NSTimeInterval lastProgressNotify;
@property(nonatomic) BOOL uiNotifyPending;
@property(nonatomic) BOOL persistenceScheduled;
@property(nonatomic) NSUInteger persistenceGeneration;
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
        dispatch_queue_attr_t utility = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _workQueue = dispatch_queue_create("ff.tasks", utility);
        _persistenceQueue = dispatch_queue_create("ff.tasks.persistence", utility);
        _lock = [NSLock new];
        [self restoreTaskHistory];
    }
    return self;
}

- (void)restoreTaskHistory
{
    NSData *data = [NSData dataWithContentsOfFile:FFTaskHistoryPath()];
    if (!data.length) return;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:NSArray.class]) return;
    NSMutableArray<FFFileTask *> *restored = [NSMutableArray array];
    for (NSDictionary *row in (NSArray *)plist) {
        FFFileTask *task = FFTaskFromDictionary(row);
        if (task) [restored addObject:task];
        if (restored.count >= kFFTaskHistoryLimit) break;
    }
    if (restored.count) {
        [self.lock lock];
        [self.taskList addObjectsFromArray:restored];
        [self.lock unlock];
        [self persistTasksNow];
    }
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
    if (self.taskList.count >= kFFTaskHistoryLimit) {
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

- (void)removeTasks:(NSArray<FFFileTask *> *)tasks
{
    [self.lock lock];
    for (FFFileTask *task in tasks) {
        if (task.state == FFFileTaskStateQueued || task.state == FFFileTaskStateRunning)
            continue;
        [self.taskList removeObject:task];
    }
    [self.lock unlock];
    [self notifyChange];
}

#pragma mark - Notifications and persistence

- (BOOL)hasRunningArchiveTask
{
    for (FFFileTask *task in self.tasks) {
        if (task.state != FFFileTaskStateRunning) continue;
        if (task.kind == FFFileTaskKindCompress || task.kind == FFFileTaskKindExtract)
            return YES;
    }
    return NO;
}

- (void)postChangeNotification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFFileTaskManagerDidChangeNotification object:self];
    });
}

- (void)notifyChange
{
    [self markPersistenceDirty];
    if (![self hasRunningArchiveTask]) {
        [self postChangeNotification];
        return;
    }
    @synchronized (self) {
        if (self.uiNotifyPending) return;
        self.uiNotifyPending = YES;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(kFFTaskProgressNotifyInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            @synchronized (strongSelf) { strongSelf.uiNotifyPending = NO; }
            [NSNotificationCenter.defaultCenter
                postNotificationName:FFFileTaskManagerDidChangeNotification object:strongSelf];
        });
}

- (void)notifyChangeThrottled
{
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - self.lastProgressNotify < kFFTaskProgressNotifyInterval) return;
    self.lastProgressNotify = now;
    [self notifyChange];
}

- (void)markPersistenceDirty
{
    BOOL schedule = NO;
    @synchronized (self) {
        self.persistenceGeneration++;
        if (!self.persistenceScheduled) {
            self.persistenceScheduled = YES;
            schedule = YES;
        }
    }
    if (schedule) [self schedulePersistenceAfter:kFFTaskPersistDelay];
}

- (void)schedulePersistenceAfter:(NSTimeInterval)delay
{
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        self.persistenceQueue, ^{
            [weakSelf persistDirtyGeneration];
        });
}

- (void)persistDirtyGeneration
{
    NSUInteger generation = 0;
    @synchronized (self) { generation = self.persistenceGeneration; }
    [self persistTasksNow];

    BOOL repeat = NO;
    @synchronized (self) {
        if (self.persistenceGeneration == generation) {
            self.persistenceScheduled = NO;
        } else {
            repeat = YES;
        }
    }
    if (repeat) [self schedulePersistenceAfter:kFFTaskPersistTrailingDelay];
}

- (void)persistTasksNow
{
    NSArray<FFFileTask *> *tasks = self.tasks;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:MIN(kFFTaskHistoryLimit, tasks.count)];
    NSUInteger limit = MIN(kFFTaskHistoryLimit, tasks.count);
    for (NSUInteger i = 0; i < limit; i++) [rows addObject:FFTaskDictionary(tasks[i])];
    NSError *plistError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:rows
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&plistError];
    if (!data) {
        FFLogTag(@"Tasks", @"persist encode FAIL error=%@", plistError);
        return;
    }
    NSError *writeError = nil;
    if (![data writeToFile:FFTaskHistoryPath() options:NSDataWritingAtomic error:&writeError])
        FFLogTag(@"Tasks", @"persist write FAIL error=%@", writeError);
}

#pragma mark - Execution gates

- (BOOL)taskRequiresSystemAccess:(FFFileTask *)task
{
    if (FFPathRequiresSystemAccess(task.destination)) return YES;
    for (NSString *source in task.sources)
        if (FFPathRequiresSystemAccess(source)) return YES;
    return NO;
}

- (BOOL)prepareVirtualPathsForTask:(FFFileTask *)task
{
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithArray:task.sources ?: @[]];
    if (task.destination.length) [paths addObject:task.destination];
    for (NSString *path in paths) {
        NSError *error = nil;
        if (!FFAppDataEnsureLogicalPathMaterialized(path, &error)) {
            task.error = error ?: [NSError errorWithDomain:@"FFFileTaskErrorDomain" code:452
                userInfo:@{NSLocalizedDescriptionKey:@"无法恢复 App Data 会话访问。"}];
            FFLogTag(@"Tasks", @"virtual path rehydrate FAIL path=%@ error=%@",
                path, task.error.localizedDescription ?: @"(nil)");
            return NO;
        }
    }
    return YES;
}

- (void)executeTask:(FFFileTask *)task
{
    if (task.cancelled || task.state == FFFileTaskStateCancelled) return;

    if ([self taskRequiresSystemAccess:task] && !FFSystemAccessManager.sharedManager.ready) {
        task.state = FFFileTaskStateFailed;
        task.error = [NSError errorWithDomain:@"FFFileTaskErrorDomain" code:451
            userInfo:@{NSLocalizedDescriptionKey:
                @"该任务需要高级系统访问。请先在设置中启用并成功加载高级系统访问，然后重试。"}];
        FFLogTag(@"Tasks", @"blocked by system access gate name=%@", task.displayName);
        [self notifyChange];
        return;
    }

    if (![self prepareVirtualPathsForTask:task]) {
        task.state = FFFileTaskStateFailed;
        [self notifyChange];
        return;
    }

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

#pragma mark - Copy / move

- (NSError *)replacementError:(NSString *)message code:(NSInteger)code underlying:(NSError *)underlying
{
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:(message ?: @"替换目标失败")
        forKey:NSLocalizedDescriptionKey];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:@"FFFileTaskReplacement" code:code userInfo:info];
}

- (BOOL)replaceExistingDestination:(NSString *)destination
                    withItemAtPath:(NSString *)source
                             error:(NSError **)error
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backupPath = [NSString stringWithFormat:@"%@.old%@", destination,
        [NSUUID.UUID.UUIDString substringToIndex:8]];

    NSError *backupError = nil;
    if ([fm fileExistsAtPath:destination] &&
        ![fm moveItemAtPath:destination toPath:backupPath error:&backupError]) {
        if (error) *error = [self replacementError:
            [NSString stringWithFormat:@"无法暂存原目标：%@", destination.lastPathComponent]
            code:20 underlying:backupError];
        return NO;
    }

    NSError *commitError = nil;
    if (![fm moveItemAtPath:source toPath:destination error:&commitError]) {
        NSError *rollbackError = nil;
        BOOL restored = ![fm fileExistsAtPath:backupPath] ||
            [fm moveItemAtPath:backupPath toPath:destination error:&rollbackError];
        if (!restored) {
            NSString *message = [NSString stringWithFormat:
                @"替换失败且回滚失败。原目标仍保存在：%@。提交错误：%@；回滚错误：%@",
                backupPath, commitError.localizedDescription ?: @"未知",
                rollbackError.localizedDescription ?: @"未知"];
            if (error) *error = [self replacementError:message code:22 underlying:rollbackError];
        } else if (error) {
            *error = [self replacementError:
                [NSString stringWithFormat:@"替换目标失败：%@", commitError.localizedDescription ?: @"未知错误"]
                code:21 underlying:commitError];
        }
        return NO;
    }

    NSError *cleanupError = nil;
    if ([fm fileExistsAtPath:backupPath] && ![fm removeItemAtPath:backupPath error:&cleanupError])
        FFLogTag(@"Tasks", @"replacement backup cleanup WARN path=%@ error=%@", backupPath, cleanupError);
    return YES;
}

- (BOOL)commitTemporaryItem:(NSString *)tempDestination
              toDestination:(NSString *)destination
                       error:(NSError **)error
{
    if (rename(tempDestination.fileSystemRepresentation,
               destination.fileSystemRepresentation) == 0)
        return YES;

    int saved = errno;
    if (saved == ENOTEMPTY || saved == EEXIST || saved == EISDIR || saved == ENOTDIR)
        return [self replaceExistingDestination:destination withItemAtPath:tempDestination error:error];

    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"提交目标失败：%@ (%s)", destination, strerror(saved)]}];
    return NO;
}

- (BOOL)tryFastMoveSource:(NSString *)source
            toDestination:(NSString *)destination
                  replacing:(BOOL)replacing
                crossDevice:(BOOL *)crossDevice
                      error:(NSError **)error
{
    if (crossDevice) *crossDevice = NO;
    if (rename(source.fileSystemRepresentation, destination.fileSystemRepresentation) == 0)
        return YES;

    int saved = errno;
    if (saved == EXDEV) {
        if (crossDevice) *crossDevice = YES;
        return NO;
    }

    if (replacing &&
        (saved == ENOTEMPTY || saved == EEXIST || saved == EISDIR || saved == ENOTDIR))
        return [self replaceExistingDestination:destination withItemAtPath:source error:error];

    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"移动失败：%@ → %@ (%s)", source, destination, strerror(saved)]}];
    return NO;
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
        BOOL replacing = NO;
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
                replacing = YES;
            } else {
                destination = [self uniqueDestinationForName:name inDirectory:task.destination];
                if (!destination) {
                    task.failedCount++;
                    task.error = [NSError errorWithDomain:@"FFFileTaskErrorDomain" code:460
                        userInfo:@{NSLocalizedDescriptionKey:@"无法生成不冲突的目标名称"}];
                    continue;
                }
            }
        }

        unsigned long long fileTotal = [FFCopyEngine sizeOfItemAtPath:source];

        // Same-filesystem moves are metadata operations. Try rename first and
        // only pay the copy+delete cost when POSIX explicitly reports EXDEV.
        if (task.kind == FFFileTaskKindMove) {
            BOOL crossDevice = NO;
            NSError *moveError = nil;
            if ([self tryFastMoveSource:source toDestination:destination replacing:replacing
                           crossDevice:&crossDevice error:&moveError]) {
                completed += fileTotal;
                task.completedBytes = completed;
                task.progress = total > 0 ? (double)completed / (double)total : 1.0;
                task.succeededCount++;
                [self notifyChange];
                continue;
            }
            if (!crossDevice) {
                task.failedCount++;
                task.error = moveError;
                FFLogTag(@"Tasks", @"fast move FAIL source=%@ destination=%@ error=%@",
                    source, destination, moveError);
                continue;
            }
            FFLogTag(@"Tasks", @"move EXDEV fallback copy+delete source=%@ destination=%@",
                source, destination);
        }

        NSError *error = nil;
        NSString *tempName = [NSString stringWithFormat:@".%@.%d.tmp",
            destination.lastPathComponent,
            (int)getpid() * 31 + (int)(arc4random() % 100000)];
        NSString *tempDestination = [destination.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:tempName];
        BOOL copied = [FFCopyEngine copyItemAtPath:source toPath:tempDestination
            progress:^(unsigned long long fileCopied, unsigned long long fileAll) {
                (void)fileAll;
                weakTask.completedBytes = completed + fileCopied;
                weakTask.progress = weakTask.totalBytes > 0
                    ? (double)weakTask.completedBytes / (double)weakTask.totalBytes : 0;
                NSTimeInterval elapsed = [NSDate.date timeIntervalSinceDate:taskStart];
                if (elapsed > 0.5 && weakTask.completedBytes > 0) {
                    weakTask.averageBytesPerSecond = (double)weakTask.completedBytes / elapsed;
                    if (weakTask.totalBytes > weakTask.completedBytes)
                        weakTask.estimatedRemainingSeconds =
                            (double)(weakTask.totalBytes - weakTask.completedBytes) /
                            weakTask.averageBytesPerSecond;
                }
                [self notifyChangeThrottled];
            } error:&error];
        if (!copied) {
            [NSFileManager.defaultManager removeItemAtPath:tempDestination error:nil];
            task.failedCount++;
            task.error = error;
            continue;
        }

        if (![self commitTemporaryItem:tempDestination toDestination:destination error:&error]) {
            [NSFileManager.defaultManager removeItemAtPath:tempDestination error:nil];
            task.failedCount++;
            task.error = error;
            continue;
        }

        completed += fileTotal;
        task.completedBytes = completed;
        task.progress = total > 0 ? (double)completed / (double)total : 1.0;
        if (task.kind == FFFileTaskKindMove) {
            NSError *removeError = nil;
            if (![NSFileManager.defaultManager removeItemAtPath:source error:&removeError]) {
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

#pragma mark - Archive tasks

- (BOOL)executeExtractTask:(FFFileTask *)task
{
    __weak FFFileTask *weakTask = task;
    BOOL (^runExtract)(NSString *, NSArray<NSString *> **, NSError **) =
        ^BOOL(NSString *destination, NSArray<NSString *> **entriesOut, NSError **errorOut) {
            return [FFArchiveService extractArchiveAtPath:task.sources.firstObject
                toDirectory:destination password:task.archivePassword entryNames:entriesOut
                progress:
                ^(double progress, NSString *entryName) {
                    weakTask.progress = progress;
                    weakTask.detailName = entryName;
                    [self notifyChange];
                },
                shouldCancel:^BOOL { return weakTask.cancelled; } error:errorOut];
        };

    NSString *initialDestination = FFCanonicalStoragePath(task.destination ?: @"");
    task.destination = initialDestination;
    NSError *error = nil;
    NSArray<NSString *> *entries = nil;
    BOOL ok = runExtract(initialDestination, &entries, &error);

    if (!ok && !task.cancelled && FFPathRequiresSystemAccess(initialDestination) &&
        FFExtractErrorIsWriteAccessFailure(error)) {
        NSString *fallback = FFFallbackExtractDestination(task);
        if (fallback.length) {
            FFLogTag(@"Tasks", @"extract destination denied; retry archive=%@ from=%@ to=%@ error=%@",
                task.sources.firstObject, initialDestination, fallback,
                error.localizedDescription ?: @"(nil)");
            task.destination = fallback;
            task.progress = 0;
            task.detailName = nil;
            [self notifyChange];
            error = nil;
            entries = nil;
            ok = runExtract(fallback, &entries, &error);
        }
    }

    if (ok) {
        task.succeededCount = entries.count;
        task.failedCount = 0;
        task.progress = 1.0;
        task.error = nil;
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