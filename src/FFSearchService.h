#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFFoundItem : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) unsigned long long size;
@end

// Recursive file search over the MHA virtual root (or any readable
// tree). Depth-first, symlink-safe, hidden files skipped, results
// delivered in batches on the main thread, cancellable.
@interface FFSearchService : NSObject

+ (instancetype)sharedService;

// Starts a search. batch is called on the main thread every ~50 hits;
// completion (finished == YES for natural end, NO for cancellation).
- (void)startSearch:(NSString *)query
            underRoot:(NSString *)root
                batch:(void (^)(NSArray<FFFoundItem *> *batch))batch
           completion:(void (^)(BOOL finished))completion;

- (void)cancel;

// Search history (NSUserDefaults, newest first, deduped, capped at 20).
- (NSArray<NSString *> *)history;
- (void)addHistory:(NSString *)query;
- (void)clearHistory;

@end

NS_ASSUME_NONNULL_END
