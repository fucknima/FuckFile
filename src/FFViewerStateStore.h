#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Per-file reading state (zoom + scroll, whatever the viewer's JS emits) for
// the app-owned document viewers. Keyed by path plus size/modification date,
// so an edited file starts from the top again instead of restoring a stale
// position. Bounded LRU to keep NSUserDefaults small.
@interface FFViewerStateStore : NSObject

+ (nullable NSDictionary *)stateForFilePath:(NSString *)path;
+ (void)setState:(nullable NSDictionary *)state forFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
