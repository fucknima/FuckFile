#import "FFSystemAccessManager.h"
#import "FFAppDataScanCoordinator.h"
#import "FFAppDataRegistry.h"
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
    NSUInteger _loadGeneration;
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

- (void)finishPendingCompletions:(BOOL)loaded
{
    NSArray<void (^)(BOOL)> *callbacks = nil;
    @synchronized (self) {
        callbacks = [_pendingCompletions copy];
        [_pendingCompletions removeAllObjects];
    }
    for (void (^callback)(BOOL) in callbacks) callback(loaded);
}

- (void)setEnabled:(BOOL)enabled
{
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FFSystemAccessEnabledPreferenceKey];
    [NSUserDefaults.standardUserDefaults synchronize];

    BOOL cancelPending = NO;
    @synchronized (self) {
        if (!enabled) {
            _state = FFSystemAccessStateDisabled;
            _failureReason = nil;
            _loadGeneration++;
            _loadInFlight = NO;
            cancelPending = _pendingCompletions.count > 0;
        } else if (_loadedThisSession) {
            _state = FFSystemAccessStateReady;
        } else if (!_loadInFlight) {
            _state = FFSystemAccessStateIdle;
            _failureReason = nil;
        }
    }

    if (cancelPending) [self finishPendingCompletions:NO];
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
    NSUInteger generation = 0;
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
            generation = ++_loadGeneration;
            shouldStart = YES;
        }
    }
    if (!shouldStart) return;

    // Registry is persistent across launches. If it already contains known App
    // identifiers, a cold launch only needs the small capability bootstrap; the
    // virtual AppData browser will acquire each container lease lazily when the
    // user opens it. Re-running the 20k+ LaunchServices fallback on every launch
    // defeats the virtual architecture and wastes several minutes of MCM calls.
    BOOL hadKnownAppData = FFAppDataRegistry.sharedRegistry.identifiers.count > 0;

    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];

    // Readiness is intentionally independent from full App Data discovery.
    // Bootstrap verifies that this process can acquire at least one class-2
    // container lease. Full discovery runs automatically only for a genuinely
    // empty registry (first use / migration); later cold launches reuse the
    // registry and leave deep discovery to the explicit Rescan action.
    [[FFAppDataScanCoordinator sharedCoordinator]
        bootstrapWithCompletion:^(BOOL ready, NSString *failureReason) {
            BOOL current = NO;
            @synchronized (self) {
                current = (_loadGeneration == generation);
                if (!current) return;
                _loadInFlight = NO;
                if (!self.enabled) {
                    _state = FFSystemAccessStateDisabled;
                    _failureReason = nil;
                } else if (ready) {
                    _loadedThisSession = YES;
                    _state = FFSystemAccessStateReady;
                    _failureReason = nil;
                } else {
                    _loadedThisSession = NO;
                    _state = FFSystemAccessStateFailed;
                    _failureReason = [failureReason copy] ?: @"高级系统访问快速探测失败。";
                }
            }

            FFLogTag(@"SystemAccess", @"bootstrap ready=%d generation=%lu knownBefore=%d reason=%@",
                ready, (unsigned long)generation, hadKnownAppData,
                failureReason ?: @"(nil)");
            [self finishPendingCompletions:ready];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];

            if (ready && self.enabled && !hadKnownAppData) {
                FFLogTag(@"SystemAccess", @"empty registry: start one-time full AppData discovery");
                [[FFAppDataScanCoordinator sharedCoordinator]
                    scanWithCompletion:^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:FFSystemAccessPreferenceDidChangeNotification
                                          object:self];
                    }];
            } else if (ready && self.enabled) {
                FFLogTag(@"SystemAccess", @"known registry: skip automatic deep AppData scan count=%lu",
                    (unsigned long)FFAppDataRegistry.sharedRegistry.identifiers.count);
            }
        }];
}

@end
