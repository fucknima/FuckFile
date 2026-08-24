#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFSystemAccessPreferenceDidChangeNotification;
FOUNDATION_EXPORT NSString *const FFSystemAccessEnabledPreferenceKey;

typedef NS_ENUM(NSInteger, FFSystemAccessState) {
    FFSystemAccessStateDisabled = 0,
    FFSystemAccessStateIdle,
    FFSystemAccessStateLoading,
    FFSystemAccessStateReady,
    FFSystemAccessStateFailed,
};

@interface FFSystemAccessManager : NSObject

+ (instancetype)sharedManager;

@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isLoadedThisSession) BOOL loadedThisSession;
@property(nonatomic, readonly) FFSystemAccessState state;
@property(nonatomic, copy, readonly, nullable) NSString *failureReason;
@property(nonatomic, readonly, getter=isReady) BOOL ready;

- (void)setEnabled:(BOOL)enabled;
- (void)loadIfEnabledWithCompletion:(void (^ _Nullable)(BOOL loaded))completion;
- (void)loadNowWithCompletion:(void (^ _Nullable)(BOOL loaded))completion;

@end

NS_ASSUME_NONNULL_END
