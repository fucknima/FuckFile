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
    [self promoteToReadyIfUsable];
}

- (void)finalizeLoadingGeneration:(NSUInteger)generation
{
    if (!self.enabled) return;
    [self promoteToReadyIfUsable];

    BOOL shouldFail = NO;
    @synchronized (self) {
        if (_loadGeneration == generation && _state == FFSystemAccessStateLoading &&
            !_loadedThisSession) {
            _loadInFlight = NO;
            _state = FFSystemAccessStateFailed;
            _failureReason = @"高级系统访问已初始化，但等待可用受保护入口超时。";
            shouldFail = YES;
        }
    }
    if (!shouldFail) return;

    FFLogTag(@"SystemAccess", @"advanced system access timeout generation=%lu",
        (unsigned long)generation);
    [self finishPendingCompletions:NO];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];
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

    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self finalizeLoadingGeneration:generation];
        });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFLogTag(@"SystemAccess", @"advanced system access load begin");
        MCMManager *mcm = MCMManager.sharedManager;
        [mcm start];

        BOOL identityOK = [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
        NSUInteger usable = FFUsableManagedEntryCount();
        BOOL loaded = identityOK && mcm.started && usable > 0;
        BOOL hardFailure = !identityOK || !mcm.started;
        NSString *failure = nil;
        if (!identityOK)
            failure = @"当前 App 身份不具备高级系统访问所需的 MCM 调用身份。";
        else if (!mcm.started)
            failure = @"高级系统访问组件未能完成初始化。";
        else if (usable == 0)
            failure = @"高级系统访问已初始化，正在等待受保护入口完成发现。";

        BOOL generationStillCurrent = NO;
        @synchronized (self) {
            generationStillCurrent = (_loadGeneration == generation);
            if (generationStillCurrent) {
                _loadedThisSession = loaded;
                if (!self.enabled) {
                    _state = FFSystemAccessStateDisabled;
                    _failureReason = nil;
                } else if (loaded) {
                    _loadInFlight = NO;
                    _state = FFSystemAccessStateReady;
                    _failureReason = nil;
                } else if (hardFailure) {
                    _loadInFlight = NO;
                    _state = FFSystemAccessStateFailed;
                    _failureReason = [failure copy];
                } else {
                    _state = FFSystemAccessStateLoading;
                    _failureReason = [failure copy];
                }
            }
        }
        FFLogTag(@"SystemAccess", @"advanced system access load end loaded=%d usable=%lu state=%ld reason=%@",
            loaded, (unsigned long)usable, (long)self.state, failure ?: @"(nil)");

        if (!generationStillCurrent) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (loaded || hardFailure)
                [self finishPendingCompletions:loaded];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FFSystemAccessPreferenceDidChangeNotification object:self];
        });
    });
}

@end
