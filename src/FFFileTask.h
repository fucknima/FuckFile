#import <Foundation/Foundation.h>

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

// One long-running file operation. Executed by FFFileTaskManager on a
// background serial queue; progress and state are observable through
// FFFileTaskManagerDidChangeNotification.
@interface FFFileTask : NSObject

@property(nonatomic, copy) NSString *taskID;
@property(nonatomic) FFFileTaskKind kind;
@property(nonatomic, copy) NSString *displayName;   // e.g. 复制 3 个项目
@property(nonatomic, copy) NSString *detailName;    // current file name
@property(nonatomic) FFFileTaskState state;
@property(nonatomic) double progress;               // 0.0 - 1.0
@property(nonatomic) unsigned long long completedBytes;
@property(nonatomic) unsigned long long totalBytes;
@property(nonatomic) NSUInteger succeededCount;
@property(nonatomic) NSUInteger failedCount;
@property(nonatomic) NSUInteger skippedCount;
@property(nonatomic, copy, nullable) NSError *error;

// Execution inputs.
@property(nonatomic, copy) NSArray<NSString *> *sources;
@property(nonatomic, copy) NSString *destination;
@property(nonatomic) BOOL moveSourceRemoval;        // YES for Move kind

// Cancellation flag, checked between files.
@property(nonatomic) BOOL cancelled;

@property(nonatomic, readonly) NSString *stateText;
@property(nonatomic, readonly) NSString *kindText;

@end

NS_ASSUME_NONNULL_END
