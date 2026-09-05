#import <Foundation/Foundation.h>
#import "FFConflictPolicy.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFFileTaskKind) {
    FFFileTaskKindCopy = 0,
    FFFileTaskKindMove,
    FFFileTaskKindExtract,
    FFFileTaskKindCompress,
};

typedef NS_ENUM(NSInteger, FFFileTaskState) {
    FFFileTaskStateQueued = 0,
    FFFileTaskStateRunning,
    FFFileTaskStateCompleted,
    FFFileTaskStateFailed,
    FFFileTaskStateCancelled,
};

@interface FFFileTask : NSObject

// Task objects are mutated by the serial worker and observed by UIKit on the
// main thread. Atomic access prevents torn scalar/object reads while keeping the
// public model compatible with existing controllers. Multi-field UI refreshes
// are still synchronized by FFFileTaskManagerDidChangeNotification.
@property(atomic, copy) NSString *taskID;
@property(atomic) FFFileTaskKind kind;
@property(atomic, copy) NSString *displayName;
@property(atomic, copy, nullable) NSString *detailName;
@property(atomic) FFFileTaskState state;
@property(atomic) double progress;
@property(atomic) double averageBytesPerSecond;
@property(atomic) double estimatedRemainingSeconds;
@property(atomic) unsigned long long completedBytes;
@property(atomic) unsigned long long totalBytes;
@property(atomic) NSUInteger succeededCount;
@property(atomic) NSUInteger failedCount;
@property(atomic) NSUInteger skippedCount;
@property(atomic, copy, nullable) NSError *error;

@property(atomic, copy) NSArray<NSString *> *sources;
@property(atomic, copy) NSString *destination;
@property(atomic) BOOL moveSourceRemoval;

// Used by encrypted archive extraction. This is deliberately an in-memory
// field: FFFileTask persistence must never serialize it.
@property(atomic, copy, nullable) NSString *archivePassword;

@property(atomic) BOOL cancelled;
@property(atomic, copy, nullable) FFConflictAction (^conflictHandler)(NSString *name);

@property(nonatomic, readonly) NSString *stateText;
@property(nonatomic, readonly) NSString *kindText;

@end

NS_ASSUME_NONNULL_END
