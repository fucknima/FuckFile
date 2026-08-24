#import "FFSystemAccessManager.h"
#import "MCMManager.h"
#import "FFLogger.h"

#import <sys/stat.h>

NSNotificationName const FFSystemAccessPreferenceDidChangeNotification =
    @"FFSystemAccessPreferenceDidChangeNotification";
NSString *const FFSystemAccessEnabledPreferenceKey = @"FFSystemAccessEnabled";

static NSUInteger FFUsableManagedEntryCount(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = MCMVirtualRoot();
    if (!root.length) return 0;

    NSUInteger count = 0;
    NSString *apps = [root stringByAppendingPathComponent:@"AppData"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
        NSString *path = [apps stringByAppendingPathComponent:name];
        struct stat linkStatus = {0};
        struct stat targetStatus = {0};
        if (lstat(path.fileSystemRepresentation, &linkStatus) == 0 &&
            S_ISLNK(linkStatus.st_mode) &&
            stat(path.fileSystemRepresentation, &targetStatus) == 0 &&
            S_ISDIR(targetStatus.st_mode)) {
            count++;
        }
    }

    // Advanced probes such as the MobileGestalt channel live directly under
    // the virtual root. They are also proof that the MCM path is operational.
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        if (![name hasPrefix:@"[MHA-"]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat linkStatus = {0};
        struct stat targetStatus = {0};
        if (lstat(path.fileSystemRepresentation, &linkStatus) == 0 &&
            S_ISLNK(linkStatus.st_mode) &&
            stat(path.fileSystemRepresentation, &targetStatus) == 0 &&
            S_ISDIR(targetStatus.st_mode)) {
            count++;
        }
    }
    return count;
}

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

        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(mcmLinksUpdated:)
            name:FFMCMAppLinksUpdatedNotification object:nil];
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

- (void)finishPendingCompletions:(BOOL)loaded
{
    NSArray<void (^)(BOOL)> *callbacks = nil;
    @synchronized (self) {
        callbacks = [_pendingCompletions copy];
        [_pendingCompletions removeAllObjects];
    }
    for (void (^callback)(BOOL) in callbacks) callback(loaded);
}

- (void)promoteToReadyIfUsable
{
    if (!self.enabled) return;
    MCMManager *mcm = MCMManager.sharedManager;
    BOOL identityOK = [NSBundle.mainBundle.bundleIdentifier
        isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
    NSUInteger usable = FFUsableManagedEntryCount();
    if (!identityOK || !mcm.started || usable == 0) return;

    BOOL changed = NO;
    @synchronized (self) {
        if (_state != FFSystemAccessStateReady || !_loadedThisSession) {
            _loadedThisSession = YES;
            _loadInFlight = NO;
            _state = FFSystemAccessStateReady;
            _failureReason = nil;
            changed = YES;
        }
    }
    if (!changed) return;

    FFLogTag(@"SystemAccess", @"advanced system access promoted ready usable=%lu",
        (unsigned long)usable);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishPendingCompletions:YES];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];
    });
}

- (void)mcmLinksUpdated:(NSNotification *)note
{
    // MCM may add more App Data links after -start returns (LaunchServices
    // confirmation is asynchronous). A failed/empty first snapshot therefore
    // must not permanently poison the session state.
    [self promoteToReadyIfUsable];
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

        BOOL identityOK = [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
        NSUInteger usable = FFUsableManagedEntryCount();
        BOOL loaded = identityOK && mcm.started && usable > 0;
        NSString *failure = nil;
        if (!identityOK)
            failure = @"当前 App 身份不具备高级系统访问所需的 MCM 调用身份。";
        else if (!mcm.started)
            failure = @"高级系统访问组件未能完成初始化。";
        else if (usable == 0)
            failure = @"高级系统访问已初始化，但暂未发现可用的受保护入口。";

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
                // Do not permanently mark the session failed just because the
                // async LaunchServices confirmation has not produced links yet.
                _state = (identityOK && mcm.started)
                    ? FFSystemAccessStateLoading : FFSystemAccessStateFailed;
                _failureReason = [failure copy];
            }
        }
        FFLogTag(@"SystemAccess", @"advanced system access load end loaded=%d usable=%lu state=%ld reason=%@",
            loaded, (unsigned long)usable, (long)self.state, failure ?: @"(nil)");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (loaded || self.state == FFSystemAccessStateFailed)
                [self finishPendingCompletions:loaded];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];
        });
    });
}

@end
