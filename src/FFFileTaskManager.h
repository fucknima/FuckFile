#import <Foundation/Foundation.h>
#import "FFFileTask.h"
#import "FFConflictPolicy.h"

NS_ASSUME_NONNULL_BEGIN

// Posted (object = manager) whenever a task's state or progress changes.
FOUNDATION_EXPORT NSNotificationName const FFFileTaskManagerDidChangeNotification;

// Serial task queue for copy/move/extract operations. Runs one task at a
// time on a background queue; keeps a bounded history of finished tasks.
@interface FFFileTaskManager : NSObject

+ (instancetype)sharedManager;

// Enqueues the task (state Queued) and starts it as soon as the queue
// is free.
- (void)enqueueTask:(FFFileTask *)task;

// Requests cancellation; the running task stops at the next file
// boundary and enters Cancelled.
- (void)cancelTask:(FFFileTask *)task;

// Active queue + recent history (newest first, capped).
@property(nonatomic, readonly) NSArray<FFFileTask *> *tasks;

// Removes a finished task from the history.
- (void)removeTask:(FFFileTask *)task;

// Conflict policy callback. Called from the worker queue whenever a
// copy/move destination already exists; the callback is expected to
// block until the user decides (see FFBrowserViewController's
// semaphore-based asker). Returns Skip when unset (never overwrite).
@property(nonatomic, copy, nullable) FFConflictAction (^conflictHandler)(NSString *name);

@end

NS_ASSUME_NONNULL_END
