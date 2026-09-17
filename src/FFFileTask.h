#import <Foundation/Foundation.h>
#import "FFConflictPolicy.h"
#import "FFArchiveCreate.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFFileTaskKind) {
    FFFileTaskKindCopy = 0,
    FFFileTaskKindMove,
    FFFileTaskKindExtract,
    FFFileTaskKindCompress,
    FFFileTaskKindDownload,
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
// Download tasks carry their remote HTTPS URL here; sources stay empty.
// Persisted with history (URL only, never credentials).
@property(atomic, copy, nullable) NSString *remoteURL;

// Request headers captured from the in-app browser (Cookie/Referer/UA) so a
// login-protected link can be fetched by the task worker. Memory only: cookie
// values must never reach TaskHistory.plist.
@property(atomic, copy, nullable) NSDictionary<NSString *, NSString *> *requestHeaders;

// Partial-download state produced by NSURLSession. Non-nil lets a failed or
// cancelled download resume with a Range request instead of restarting.
// Memory only; an app relaunch restarts from zero.
@property(atomic, copy, nullable) NSData *resumeData;

// Used by encrypted archive extraction. This is deliberately an in-memory
// field: FFFileTask persistence must never serialize it.
@property(atomic, copy, nullable) NSString *archivePassword;
// Compression-task options. Non-secret options persist with task history;
// archivePassword above is process-memory only.
@property(atomic) FFArchiveCreateFormat archiveFormat;
@property(atomic) FFZipCompressionLevel zipCompression;
@property(atomic) FFZipEncryptionMode archiveEncryption;

@property(atomic) BOOL cancelled;
// 执行代次：入队/重试时自增。worker 领取的任务若代次已过期（取消后又点了
// 「继续」），旧 block 直接退出，避免同一任务被执行两遍。
@property(atomic) NSUInteger executionGeneration;
@property(atomic, copy, nullable) FFConflictAction (^conflictHandler)(NSString *name);

@property(nonatomic, readonly) NSString *stateText;
@property(nonatomic, readonly) NSString *kindText;

@end

NS_ASSUME_NONNULL_END
