#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Conflict handling for copy/move when the destination already exists.
// Ask is the initial state; the other values are user decisions.
typedef NS_ENUM(NSInteger, FFConflictAction) {
    FFConflictActionAsk = 0,
    FFConflictActionReplace,
    FFConflictActionSkip,
    FFConflictActionKeepBoth,
    FFConflictActionReplaceAll,
    FFConflictActionSkipAll,
};

NS_ASSUME_NONNULL_END
