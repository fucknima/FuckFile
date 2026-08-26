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

@property(nonatomic, copy) NSString *taskID;
@property(nonatomic) FFFileTaskKind kind;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *detailName;
@property(nonatomic) FFFileTaskState state;
@property(nonatomic) double progress;
@property(nonatomic) double averageBytesPerSecond;
@property(nonatomic) double estimatedRemainingSeconds;
@property(nonatomic) unsigned long long completedBytes;
@property(nonatomic) unsigned long long totalBytes;
@property(nonatomic) NSUInteger succeededCount;
@property(nonatomic) NSUInteger failedCount;
@property(nonatomic) NSUInteger skippedCount;
@property(nonatomic, copy, nullable) NSError *error;

@property(nonatomic, copy) NSArray<NSString *> *sources;
@property(nonatomic, copy) NSString *destination;
@property(nonatomic) BOOL moveSourceRemoval;

// Used by encrypted ZIP extraction only. This is deliberately an in-memory
// field: FFFileTask persistence must never serialize it.
@property(nonatomic, copy, nullable) NSString *archivePassword;

@property(nonatomic) BOOL cancelled;
@property(nonatomic, copy, nullable) FFConflictAction (^conflictHandler)(NSString *name);

@property(nonatomic, readonly) NSString *stateText;
@property(nonatomic, readonly) NSString *kindText;

@end

NS_ASSUME_NONNULL_END
