#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFFoundItem : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy, nullable) NSString *displayName;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) unsigned long long size;
@end

typedef NS_ENUM(NSInteger, FFSearchCompletionStatus) {
    FFSearchCompletionStatusCompleted = 0,
    FFSearchCompletionStatusCancelled,
    FFSearchCompletionStatusPartial,
    FFSearchCompletionStatusFailed,
};

// Recursive search used by a browser directory. It deliberately does not follow
// directory symlinks, never escapes the resolved search root, follows the same
// Unicode matching rules as immediate Browser results, and reports partial
// traversal instead of silently treating unreadable/depth-limited trees as done.
@interface FFSearchService : NSObject

- (void)startSearch:(NSString *)query
          underRoot:(NSString *)root
              batch:(void (^)(NSArray<FFFoundItem *> *batch))batch
         completion:(void (^)(BOOL finished))completion;

- (void)cancel;

@property(atomic, readonly) FFSearchCompletionStatus completionStatus;
@property(atomic, readonly) NSUInteger skippedDirectoryCount;
@property(atomic, readonly) BOOL truncatedByDepth;
@property(atomic, copy, readonly, nullable) NSString *statusMessage;

@end

NS_ASSUME_NONNULL_END