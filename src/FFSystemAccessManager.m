#import "FFSystemAccessManager.h"
#import "MCMManager.h"
#import "FFLogger.h"

NSNotificationName const FFSystemAccessPreferenceDidChangeNotification =
    @"FFSystemAccessPreferenceDidChangeNotification";
NSString *const FFSystemAccessEnabledPreferenceKey = @"FFSystemAccessEnabled";

@implementation FFSystemAccessManager {
    BOOL _loadedThisSession;
    BOOL _loadInFlight;
    NSMutableArray<void (^)(BOOL)> *_pendingCompletions;
}

+ (instancetype)sharedManager
{
    static FFSystemAccessManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [FFSystemAccessManager new]; });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) _pendingCompletions = [NSMutableArray array];
    return self;
}

- (BOOL)isEnabled
{
    return [NSUserDefaults.standardUserDefaults boolForKey:FFSystemAccessEnabledPreferenceKey];
}

- (BOOL)isLoadedThisSession
{
    @synchronized (self) { return _loadedThisSession; }
}

- (void)setEnabled:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FFSystemAccessEnabledPreferenceKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];
}

- (void)loadIfEnabledWithCompletion:(void (^)(BOOL))completion
{
    if (!self.enabled) {
        if (completion) completion(NO);
        return;
    }
    [self loadNowWithCompletion:completion];
}

- (void)loadNowWithCompletion:(void (^)(BOOL))completion
{
    BOOL shouldStart = NO;
    @synchronized (self) {
        if (_loadedThisSession) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            return;
        }
        if (completion) [_pendingCompletions addObject:[completion copy]];
        if (!_loadInFlight) {
            _loadInFlight = YES;
            shouldStart = YES;
        }
    }
    if (!shouldStart) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFLogTag(@"SystemAccess", @"advanced system access load begin");
        [[MCMManager sharedManager] start];
        BOOL loaded = YES;
        @synchronized (self) {
            _loadedThisSession = loaded;
            _loadInFlight = NO;
        }
        FFLogTag(@"SystemAccess", @"advanced system access load end loaded=%d", loaded);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<void (^)(BOOL)> *callbacks = nil;
            @synchronized (self) {
                callbacks = [_pendingCompletions copy];
                [_pendingCompletions removeAllObjects];
            }
            for (void (^callback)(BOOL) in callbacks) callback(loaded);
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];
        });
    });
}

@end
