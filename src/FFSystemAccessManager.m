#import "FFSystemAccessManager.h"
#import "MCMManager.h"
#import "FFLogger.h"

NSNotificationName const FFSystemAccessPreferenceDidChangeNotification =
    @"FFSystemAccessPreferenceDidChangeNotification";
NSString *const FFSystemAccessEnabledPreferenceKey = @"FFSystemAccessEnabled";

@implementation FFSystemAccessManager {
    BOOL _loadedThisSession;
    BOOL _loadInFlight;
    FFSystemAccessState _state;
    NSString *_failureReason;
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
    if (self) {
        _pendingCompletions = [NSMutableArray array];
        _state = [NSUserDefaults.standardUserDefaults boolForKey:FFSystemAccessEnabledPreferenceKey]
            ? FFSystemAccessStateIdle : FFSystemAccessStateDisabled;
    }
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

- (BOOL)isReady
{
    @synchronized (self) { return _state == FFSystemAccessStateReady; }
}

- (FFSystemAccessState)state
{
    @synchronized (self) { return _state; }
}

- (NSString *)failureReason
{
    @synchronized (self) { return [_failureReason copy]; }
}

- (void)setEnabled:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FFSystemAccessEnabledPreferenceKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    @synchronized (self) {
        if (!enabled) {
            _state = FFSystemAccessStateDisabled;
            _failureReason = nil;
        } else if (_loadedThisSession) {
            _state = FFSystemAccessStateReady;
        } else if (!_loadInFlight) {
            _state = FFSystemAccessStateIdle;
            _failureReason = nil;
        }
    }
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
    if (!self.enabled) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }

    BOOL shouldStart = NO;
    @synchronized (self) {
        if (_state == FFSystemAccessStateReady && _loadedThisSession) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            return;
        }
        if (completion) [_pendingCompletions addObject:[completion copy]];
        if (!_loadInFlight) {
            _loadInFlight = YES;
            _state = FFSystemAccessStateLoading;
            _failureReason = nil;
            shouldStart = YES;
        }
    }
    if (!shouldStart) return;

    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFLogTag(@"SystemAccess", @"advanced system access load begin");
        MCMManager *mcm = MCMManager.sharedManager;
        [mcm start];

        NSUInteger linked = 0;
        for (NSDictionary *links in mcm.categoryLinks.allValues)
            linked += links.count;
        BOOL identityOK = [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
        BOOL loaded = identityOK && mcm.started && linked > 0;
        NSString *failure = nil;
        if (!identityOK)
            failure = @"当前 App 身份不具备高级系统访问所需的 MCM 调用身份。";
        else if (!mcm.started)
            failure = @"高级系统访问组件未能完成初始化。";
        else if (linked == 0)
            failure = @"未获得任何可用的 App Data 访问链接。";

        @synchronized (self) {
            _loadedThisSession = loaded;
            _loadInFlight = NO;
            if (!self.enabled) {
                _state = FFSystemAccessStateDisabled;
                _failureReason = nil;
            } else if (loaded) {
                _state = FFSystemAccessStateReady;
                _failureReason = nil;
            } else {
                _state = FFSystemAccessStateFailed;
                _failureReason = [failure copy];
            }
        }
        FFLogTag(@"SystemAccess", @"advanced system access load end loaded=%d linked=%lu reason=%@",
            loaded, (unsigned long)linked, failure ?: @"(nil)");

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
