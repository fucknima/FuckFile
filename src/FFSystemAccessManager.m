#import "FFSystemAccessManager.h"
#import "FFAppDataScanCoordinator.h"
#import "FFAppDataRegistry.h"
#import "FFLogger.h"

#import <UIKit/UIKit.h>

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
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(applicationDidBecomeActive:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)applicationDidBecomeActive:(NSNotification *)note
{
    (void)note;
    // This is metadata-only unless LaunchServices changed. It lets installs and
    // uninstalls performed while FuckFile was backgrounded reconcile as soon as
    // the app returns, without restoring the old every-launch 20k scan.
    if (!self.enabled || !self.ready) return;
    [FFAppDataScanCoordinator.sharedCoordinator checkForInstalledAppChanges];
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
    // virtual AppData browser acquires individual container leases lazily.
    BOOL hadKnownAppData = FFAppDataRegistry.sharedRegistry.identifiers.count > 0;

    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];

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

            if (!ready || !self.enabled) return;

            if (!hadKnownAppData) {
                FFLogTag(@"SystemAccess", @"empty registry: start one-time full AppData discovery");
                [[FFAppDataScanCoordinator sharedCoordinator]
                    scanWithCompletion:^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:FFSystemAccessPreferenceDidChangeNotification
                                          object:self];
                    }];
            } else {
                FFLogTag(@"SystemAccess", @"known registry: cheap LS change check count=%lu",
                    (unsigned long)FFAppDataRegistry.sharedRegistry.identifiers.count);
                [FFAppDataScanCoordinator.sharedCoordinator checkForInstalledAppChanges];
            }
        }];
}

@end
