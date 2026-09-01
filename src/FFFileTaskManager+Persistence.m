#import "FFFileTaskManager.h"
#import "FFLogger.h"
#import "FFStorageEnvironment.h"
#import "FFZipExtract.h"

#import <errno.h>
#import <objc/runtime.h>

static const void *kFFTaskPersistPendingKey = &kFFTaskPersistPendingKey;

@interface FFFileTaskManager (FFPersistencePrivate)
- (void)notifyChange;
- (BOOL)executeExtractTask:(FFFileTask *)task;
@end

static NSString *FFTaskHistoryPath(void)
{
    NSString *root = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
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
    // SECURITY: archivePassword is intentionally absent.
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
                @"App 上次退出时任务尚未完成，任务已中断，可重试。加密 ZIP 需要重新输入密码后再发起。"}];
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

static void FFPersistTasks(FFFileTaskManager *manager)
{
    NSArray<FFFileTask *> *tasks = manager.tasks;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:MIN((NSUInteger)50, tasks.count)];
    NSUInteger limit = MIN((NSUInteger)50, tasks.count);
    for (NSUInteger i = 0; i < limit; i++) [rows addObject:FFTaskDictionary(tasks[i])];
    NSError *plistError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:rows
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&plistError];
    if (!data) return;
    [data writeToFile:FFTaskHistoryPath() options:NSDataWritingAtomic error:nil];
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
    NSString *archive = task.sources.firstObject.lastPathComponent.stringByDeletingPathExtension;
    if (!archive.length) archive = @"archive";
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

@implementation FFFileTaskManager (Persistence)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;
        Method initOriginal = class_getInstanceMethod(cls, @selector(init));
        Method initReplacement = class_getInstanceMethod(cls, @selector(ff_persist_init));
        Method notifyOriginal = class_getInstanceMethod(cls, @selector(notifyChange));
        Method notifyReplacement = class_getInstanceMethod(cls, @selector(ff_persist_notifyChange));
        Method extractOriginal = class_getInstanceMethod(cls, @selector(executeExtractTask:));
        Method extractReplacement = class_getInstanceMethod(cls, @selector(ff_password_executeExtractTask:));
        if (initOriginal && initReplacement) method_exchangeImplementations(initOriginal, initReplacement);
        if (notifyOriginal && notifyReplacement) method_exchangeImplementations(notifyOriginal, notifyReplacement);
        if (extractOriginal && extractReplacement) method_exchangeImplementations(extractOriginal, extractReplacement);
    });
}

- (instancetype)ff_persist_init
{
    FFFileTaskManager *manager = [self ff_persist_init];
    if (!manager) return nil;

    NSData *data = [NSData dataWithContentsOfFile:FFTaskHistoryPath()];
    if (!data.length) return manager;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:NSArray.class]) return manager;

    NSMutableArray<FFFileTask *> *restored = [NSMutableArray array];
    for (NSDictionary *row in (NSArray *)plist) {
        FFFileTask *task = FFTaskFromDictionary(row);
        if (task) [restored addObject:task];
        if (restored.count >= 50) break;
    }
    if (restored.count) {
        // taskList is private to the manager; KVC keeps persistence isolated from
        // the execution API and avoids turning history storage into UI state.
        [manager setValue:restored forKey:@"taskList"];
        FFPersistTasks(manager); // convert stale states + legacy paths on disk now
    }
    return manager;
}

- (void)ff_persist_notifyChange
{
    [self ff_persist_notifyChange];
    @synchronized (self) {
        if ([objc_getAssociatedObject(self, kFFTaskPersistPendingKey) boolValue]) return;
        objc_setAssociatedObject(self, kFFTaskPersistPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    __weak FFFileTaskManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            FFFileTaskManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            FFPersistTasks(strongSelf);
            @synchronized (strongSelf) {
                objc_setAssociatedObject(strongSelf, kFFTaskPersistPendingKey, @NO,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
}

- (BOOL)ff_password_executeExtractTask:(FFFileTask *)task
{
    __weak FFFileTask *weakTask = task;
    BOOL (^runExtract)(NSString *, NSArray<NSString *> **, NSError **) =
        ^BOOL(NSString *destination, NSArray<NSString *> **entriesOut, NSError **errorOut) {
            return FFZipExtractWithProgressPassword(task.sources.firstObject, destination,
                task.archivePassword, entriesOut,
                ^(double progress, NSString *entryName) {
                    weakTask.progress = progress;
                    weakTask.detailName = entryName;
                    [self notifyChange];
                },
                ^BOOL { return weakTask.cancelled; }, errorOut);
        };

    NSString *initialDestination = FFCanonicalStoragePath(task.destination ?: @"");
    task.destination = initialDestination;
    NSError *error = nil;
    NSArray<NSString *> *entries = nil;
    BOOL ok = runExtract(initialDestination, &entries, &error);

    // AppData and other managed system locations may be readable yet reject
    // writes on a particular OS build. For a write-permission failure only,
    // retry once in Documents/Extracted. Corrupt archives, wrong passwords,
    // cancellation, ENOSPC, etc. are never masked by a fallback retry.
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

@end
