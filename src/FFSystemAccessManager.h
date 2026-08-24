#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFSystemAccessPreferenceDidChangeNotification;
FOUNDATION_EXPORT NSString *const FFSystemAccessEnabledPreferenceKey;

@interface FFSystemAccessManager : NSObject

+ (instancetype)sharedManager;

@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isLoadedThisSession) BOOL loadedThisSession;

- (void)setEnabled:(BOOL)enabled;
- (void)loadIfEnabledWithCompletion:(void (^ _Nullable)(BOOL loaded))completion;
- (void)loadNowWithCompletion:(void (^ _Nullable)(BOOL loaded))completion;

@end

NS_ASSUME_NONNULL_END
