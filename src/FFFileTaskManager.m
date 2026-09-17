#import "FFFileTaskManager.h"
#import "FFCopyEngine.h"
#import "FFZipExtract.h"
#import "FFArchiveService.h"
#import "FFZipCreate.h"
#import "FFArchiveCreate.h"
#import "FFImportService.h"
#import "FFLogger.h"
#import "FFStorageEnvironment.h"

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
    row[@"archiveFormat"] = @(task.archiveFormat);
    row[@"zipCompression"] = @(task.zipCompression);
    row[@"archiveEncryption"] = @(task.archiveEncryption);
    if (task.remoteURL.length) row[@"remoteURL"] = task.remoteURL;
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
        kindValue.integerValue > FFFileTaskKindDownload)
        return nil;
    NSString *remoteURL = [row[@"remoteURL"] isKindOfClass:NSString.class] ? row[@"remoteURL"] : nil;
    if (kindValue.integerValue == FFFileTaskKindDownload) {
        NSURL *url = [NSURL URLWithString:remoteURL ?: @""];
        NSString *scheme = url.scheme.lowercaseString;
        if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    }

    FFFileTask *task = [FFFileTask new];
    NSString *taskID = [row[@"taskID"] isKindOfClass:NSString.class] ? row[@"taskID"] : nil;
    if (taskID.length) task.taskID = taskID;
    task.kind = kindValue.integerValue;
    task.displayName = displayName;
    task.detailName = [row[@"detailName"] isKindOfClass:NSString.class] ? row[@"detailName"] : nil;
    task.sources = sources;
    task.destination = destination;
    task.remoteURL = remoteURL;
    task.moveSourceRemoval = [row[@"moveSourceRemoval"] boolValue];
    task.archiveFormat = [row[@"archiveFormat"] isKindOfClass:NSNumber.class]
        ? [row[@"archiveFormat"] integerValue] : FFArchiveCreateFormatZIP;
    task.zipCompression = [row[@"zipCompression"] isKindOfClass:NSNumber.class]
        ? [row[@"zipCompression"] integerValue] : FFZipCompressionLevelBalanced;
    task.archiveEncryption = [row[@"archiveEncryption"] isKindOfClass:NSNumber.class]
        ? [row[@"archiveEncryption"] integerValue] : FFZipEncryptionModeNone;
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

// Progress/completion plumbing for HTTPS downloads. The worker thread blocks
// on a semaphore, so the session must use its own delegate queue.
@interface FFDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy, nullable) void (^progressBlock)(int64_t written, int64_t expected);
@property(nonatomic, copy, nullable) void (^finishBlock)(NSURL * _Nullable tempURL,
                                                         NSURLResponse * _Nullable response,
                                                         NSError * _Nullable error);
@end

@implementation FFDownloadDelegate

- (void)URLSession:(__unused NSURLSession *)session downloadTask:(__unused NSURLSessionDownloadTask *)downloadTask
      didWriteData:(__unused int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (self.progressBlock) self.progressBlock(totalBytesWritten, totalBytesExpectedToWrite);
}

- (void)URLSession:(__unused NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location
{
    // `location` is only valid inside this callback: move it to a stable path.
    NSURL *stable = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"ffdownload-%@", NSUUID.UUID.UUIDString]]];
    NSError *moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:stable error:&moveError]) {
        if (self.finishBlock) self.finishBlock(nil, downloadTask.response, moveError);
        return;
    }
    if (self.finishBlock) self.finishBlock(stable, downloadTask.response, nil);
}

- (void)URLSession:(__unused NSURLSession *)session task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error
{
    if (error && self.finishBlock) self.finishBlock(nil, task.response, error);
}

@end

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
    NSUInteger generation = ++task.executionGeneration;
    dispatch_async(self.workQueue, ^{ [self executeTask:task generation:generation]; });
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
    NSUInteger generation = ++task.executionGeneration;
    dispatch_async(self.workQueue, ^{ [self executeTask:task generation:generation]; });
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

- (void)executeTask:(FFFileTask *)task generation:(NSUInteger)generation
{
    if (task.cancelled || task.state == FFFileTaskStateCancelled) return;
    // 取消→「继续」会留下两个已入队的 block：代次过期的那个直接退出，
    // 否则第一个跑完后第二个还会把任务再执行一遍。
    if (generation != task.executionGeneration) return;
    if (task.state == FFFileTaskStateCompleted) return;

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
        case FFFileTaskKindDownload:
            ok = [self executeDownloadTask:task];
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
            if (action == FFConflictActionReplaceAll || action == FFConflictActionKeepBothAll)
                applyAll = action;
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
                }
                shouldCancel:^BOOL { return weakTask.cancelled; }
                error:errorOut];
        };

    NSString *initialDestination = FFCanonicalStoragePath(task.destination ?: @"");
    task.destination = initialDestination;
    NSError *error = nil;
    NSArray<NSString *> *entries = nil;
    BOOL ok = runExtract(initialDestination, &entries, &error);

    if (!ok && !task.cancelled && FFExtractErrorIsWriteAccessFailure(error)) {
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

    if (task.archiveEncryption != FFZipEncryptionModeNone &&
        !task.archivePassword.length) {
        task.failedCount = 1;
        task.error = [NSError errorWithDomain:@"FFArchiveCreate" code:401
            userInfo:@{NSLocalizedDescriptionKey:
                @"该任务需要压缩密码。密码不会写入任务历史，请重新发起加密压缩。"}];
        return NO;
    }

    FFArchiveCreateOptions *options = [FFArchiveCreateOptions new];
    options.format = task.archiveFormat;
    options.zipCompression = task.zipCompression;
    options.zipEncryption = task.archiveEncryption;
    options.password = task.archivePassword;

    BOOL ok = FFCreateArchive(task.sources, task.destination, options,
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

#pragma mark - Download

- (BOOL)executeDownloadTask:(FFFileTask *)task
{
    NSURL *url = [NSURL URLWithString:task.remoteURL ?: @""];
    NSString *scheme = url.scheme.lowercaseString;
    // 网页下载浏览器允许 http/https（Info.plist 已配 ATS 例外）：两边策略一致，
    // 否则浏览器里成功入队的 http 任务一到执行就必失败。
    if (!url || (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"])) {
        task.failedCount = 1;
        task.error = [NSError errorWithDomain:@"FFFileTaskErrorDomain" code:470
            userInfo:@{NSLocalizedDescriptionKey: @"下载地址无效（仅支持 http/https）"}];
        return NO;
    }
    if (!task.destination.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:task.destination]) {
        task.failedCount = 1;
        task.error = [NSError errorWithDomain:@"FFFileTaskErrorDomain" code:471
            userInfo:@{NSLocalizedDescriptionKey: @"下载目录不存在"}];
        return NO;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    [task.requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        if (field.length && value.length) [request setValue:value forHTTPHeaderField:field];
    }];
    task.detailName = url.lastPathComponent.length ? url.lastPathComponent : url.host;
    [self notifyChange];

    // 最多两次：先带 resumeData 续传，若服务器/文件已变化导致断点失效，
    // 清掉断点后全量重来一次。取消不重试，断点保留给用户点「继续」。
    NSLock *cancelLock = [NSLock new];
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSData *resumeData = task.resumeData;
        BOOL usedResumeData = resumeData.length > 0;
        __block NSData *cancelResumeData = nil;
        __block BOOL cancelResumeDataReady = NO;
        __block BOOL cancelRequested = NO;
        __block NSURL *tempURL = nil;
        __block NSURLResponse *response = nil;
        __block NSError *downloadError = nil;
        NSDate *startedAt = NSDate.date;

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        FFDownloadDelegate *delegate = [FFDownloadDelegate new];
        delegate.progressBlock = ^(int64_t written, int64_t expected) {
            task.completedBytes = written > 0 ? (unsigned long long)written : 0;
            task.totalBytes = expected > 0 ? (unsigned long long)expected : 0;
            task.progress = expected > 0 ? MIN(1.0, (double)written / (double)expected) : 0;
            NSTimeInterval elapsed = [NSDate.date timeIntervalSinceDate:startedAt];
            if (elapsed > 0.5 && written > 0) {
                task.averageBytesPerSecond = (double)written / elapsed;
                if (expected > written && task.averageBytesPerSecond > 0)
                    task.estimatedRemainingSeconds = (double)(expected - written) / task.averageBytesPerSecond;
            }
            [self notifyChangeThrottled];
        };
        delegate.finishBlock = ^(NSURL *location, NSURLResponse *finishedResponse, NSError *error) {
            tempURL = location;
            response = finishedResponse;
            downloadError = error;
            dispatch_semaphore_signal(semaphore);
        };

        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30;
        configuration.timeoutIntervalForResource = 60 * 60;
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.maxConcurrentOperationCount = 1;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
            delegate:delegate delegateQueue:delegateQueue];
        NSURLSessionDownloadTask *download = usedResumeData
            ? [session downloadTaskWithResumeData:resumeData]
            : [session downloadTaskWithRequest:request];
        [download resume];

        // Poll the semaphore so a cancel request is honored even when the server
        // sends no progress callbacks (the session would otherwise block forever).
        while (dispatch_semaphore_wait(semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC))) != 0) {
            if (!task.cancelled || cancelRequested) continue;
            cancelRequested = YES;
            dispatch_semaphore_t resumeSemaphore = dispatch_semaphore_create(0);
            [download cancelByProducingResumeData:^(NSData *data) {
                [cancelLock lock];
                cancelResumeData = data;
                cancelResumeDataReady = YES;
                [cancelLock unlock];
                dispatch_semaphore_signal(resumeSemaphore);
            }];
            if (dispatch_semaphore_wait(resumeSemaphore,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC))) != 0)
                FFLogTag(@"Tasks", @"cancel resume data timed out, falling back");
        }
        [session finishTasksAndInvalidate];
        delegate.progressBlock = nil;
        delegate.finishBlock = nil;

        if (cancelRequested || task.cancelled) {
            [cancelLock lock];
            NSData *resume = cancelResumeDataReady ? cancelResumeData : nil;
            [cancelLock unlock];
            if (!resume.length) resume = downloadError.userInfo[NSURLSessionDownloadTaskResumeData];
            if ([resume isKindOfClass:NSData.class] && resume.length) task.resumeData = resume;
            else if (!task.resumeData.length) task.resumeData = usedResumeData ? resumeData : nil;
            // 取消与下载完成撞车时，临时文件不再导入，及时清掉避免留在 tmp。
            if (tempURL) [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
            FFLogTag(@"Tasks", @"download cancelled resume=%lu",
                (unsigned long)task.resumeData.length);
            return NO;
        }

        if (!downloadError && tempURL) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 200;
            if (status >= 400) {
                [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
                task.resumeData = nil;
                task.failedCount = 1;
                task.error = [NSError errorWithDomain:@"FFFileTaskErrorDomain" code:473
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"服务器返回 HTTP %ld", (long)status]}];
                return NO;
            }

            NSString *name = response.suggestedFilename;
            if (!name.length) name = url.lastPathComponent;
            if (!name.length) name = @"下载文件";
            FFImportResult *result = [FFImportService importURL:tempURL
                displayName:name toDirectory:task.destination];
            [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];

            if (result.success) {
                task.succeededCount = 1;
                task.progress = 1.0;
                task.resumeData = nil;
                if (task.totalBytes > 0) task.completedBytes = task.totalBytes;
                if (result.destinationPath.lastPathComponent.length)
                    task.detailName = result.destinationPath.lastPathComponent;
                FFLogTag(@"Tasks", @"download ok name=%@ bytes=%llu", name, task.completedBytes);
                return YES;
            }
            task.resumeData = nil;
            task.failedCount = 1;
            task.error = result.error;
            return NO;
        }

        // 失败：NSURLSession 会顺带给出新的断点数据（网络中断时）。
        NSData *errorResumeData = downloadError.userInfo[NSURLSessionDownloadTaskResumeData];
        BOOL hasFreshResumeData = [errorResumeData isKindOfClass:NSData.class] &&
            errorResumeData.length > 0;
        task.resumeData = hasFreshResumeData ? errorResumeData : nil;

        // 本次是续传且断点被拒（服务器换了文件 / 不支持 Range）：清掉断点，
        // 全量重新下载一次，而不是直接把任务判失败。
        if (usedResumeData && !hasFreshResumeData && attempt == 0) {
            task.progress = 0;
            task.completedBytes = 0;
            task.totalBytes = 0;
            task.averageBytesPerSecond = 0;
            task.estimatedRemainingSeconds = 0;
            FFLogTag(@"Tasks", @"download resume rejected, restarting from scratch");
            [self notifyChange];
            continue;
        }

        task.failedCount = 1;
        task.error = downloadError ?: [NSError errorWithDomain:@"FFFileTaskErrorDomain"
            code:472 userInfo:@{NSLocalizedDescriptionKey: @"下载失败：服务器未返回文件"}];
        return NO;
    }
    return NO;
}

@end