#import "FFAppDataLeaseManager.h"
#import "MCMBridge.h"
#import "FFLogger.h"
#import "FFAppDataScanCoordinator.h"
#import "FFAppDataRegistry.h"
#import "FFStorageEnvironment.h"

#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const FFAppDataLeaseErrorDomain = @"FFAppDataLeaseErrorDomain";
static NSString *const kRequiredIdentifier = @"com.apple.mobile.MobileHouseArrest";
static NSString *const kFFObservedInstalledCountKey = @"FFObservedInstalledBundleCountV1";

@implementation FFAppDataLeaseManager {
    NSMutableDictionary<NSString *, MCMLease *> *_leases;
    NSMutableDictionary<NSString *, dispatch_group_t> *_inFlight;
    NSMutableDictionary<NSString *, NSError *> *_lastErrors;
    dispatch_semaphore_t _activationSlots;
}

+ (instancetype)sharedManager
{
    static FFAppDataLeaseManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [FFAppDataLeaseManager new]; });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _leases = [NSMutableDictionary dictionary];
        _inFlight = [NSMutableDictionary dictionary];
        _lastErrors = [NSMutableDictionary dictionary];
        _activationSlots = dispatch_semaphore_create(4);
    }
    return self;
}

+ (BOOL)safeIdentifier:(NSString *)identifier
{
    if (identifier.length < 3 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier hasPrefix:@"."] && ![identifier hasSuffix:@"."] &&
        ![identifier containsString:@".."] && [identifier containsString:@"."];
}

static BOOL FFLeaseDetailMeansMissing(NSString *detail)
{
    if (!detail.length) return NO;
    return [detail containsString:@"posix=2"] ||
           [detail localizedCaseInsensitiveContainsString:@"No such file"];
}

- (BOOL)rootStillReadable:(NSString *)path
{
    if (!path.length) return NO;
    int fd = open(path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

- (NSString *)currentRootForIdentifier:(NSString *)identifier
{
    if (!identifier.length) return nil;
    @synchronized (self) {
        MCMLease *lease = _leases[identifier];
        if (!lease.rootPath.length) return nil;
        return [self rootStillReadable:lease.rootPath] ? lease.rootPath : nil;
    }
}

- (BOOL)hasLeaseForIdentifier:(NSString *)identifier
{
    return [self currentRootForIdentifier:identifier].length > 0;
}

- (void)invalidateIdentifier:(NSString *)identifier
{
    if (![self.class safeIdentifier:identifier]) return;

    dispatch_group_t inFlight = nil;
    @synchronized (self) { inFlight = _inFlight[identifier]; }
    if (inFlight) dispatch_group_wait(inFlight, DISPATCH_TIME_FOREVER);

    MCMLease *lease = nil;
    @synchronized (self) {
        lease = _leases[identifier];
        [_leases removeObjectForKey:identifier];
        [_lastErrors removeObjectForKey:identifier];
    }
    [lease invalidate];
    FFLogTag(@"AppDataLease", @"invalidated id=%@", identifier);
}

- (NSString *)reacquireIdentifier:(NSString *)identifier error:(NSError **)error
{
    // A readable cached root is not proof that an app is still installed: the
    // old process lease/container may survive briefly after uninstall. Drop it
    // first so the next call must perform a new class-2 ContainerManager lookup.
    [self invalidateIdentifier:identifier];
    return [self acquireIdentifier:identifier error:error];
}

- (NSError *)errorWithDetail:(NSString *)detail code:(NSInteger)code
{
    NSString *message = detail.length ? detail : @"App Data 容器访问失败";
    return [NSError errorWithDomain:FFAppDataLeaseErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (MCMLease *)newUsableLeaseForIdentifier:(NSString *)identifier
                                   detail:(NSString **)detailOut
                        definitiveMissing:(BOOL *)definitiveMissingOut
{
    static NSArray<NSNumber *> *flags;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        flags = @[
            @(0x900000000ULL),
            @(0x800000000ULL),
            @(0x8100000000ULL),
            @(0x080000000ULL),
        ];
    });

    NSString *lastDetail = nil;
    BOOL sawMissingLookup = NO;
    BOOL onlyMissingLookups = YES;
    for (NSNumber *flag in flags) {
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:2 identifier:identifier
            group:NO part:0 flags:flag.unsignedLongLongValue error:&detail];
        if (!lease) {
            BOOL missing = FFLeaseDetailMeansMissing(detail);
            sawMissingLookup |= missing;
            if (!missing) onlyMissingLookups = NO;
            lastDetail = detail;
            continue;
        }

        onlyMissingLookups = NO;
        BOOL activated = [lease activate:&detail];
        int fd = open(lease.rootPath.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (fd >= 0) {
            close(fd);
            if (!activated) {
                FFLogTag(@"AppDataLease", @"token-less usable id=%@ flags=0x%llx root=%@",
                    identifier, flag.unsignedLongLongValue, lease.rootPath);
            } else {
                FFLogTag(@"AppDataLease", @"acquired id=%@ flags=0x%llx root=%@",
                    identifier, flag.unsignedLongLongValue, lease.rootPath);
            }
            if (detailOut) *detailOut = nil;
            if (definitiveMissingOut) *definitiveMissingOut = NO;
            return lease;
        }

        lastDetail = detail.length ? detail : [NSString stringWithFormat:
            @"container root open failed errno=%d", errno];
        [lease invalidate];
    }

    if (detailOut) *detailOut = lastDetail ?: @"class-2 lookup denied (matrix exhausted)";
    if (definitiveMissingOut)
        *definitiveMissingOut = sawMissingLookup && onlyMissingLookups;
    return nil;
}

- (NSString *)acquireIdentifier:(NSString *)identifier error:(NSError **)error
{
    if (![self.class safeIdentifier:identifier]) {
        if (error) *error = [self errorWithDetail:@"Bundle Identifier 格式无效" code:1];
        return nil;
    }
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:kRequiredIdentifier]) {
        if (error) *error = [self errorWithDetail:@"当前 App 身份不是 MobileHouseArrest" code:2];
        return nil;
    }
    if (!MCMBridgeAvailable()) {
        if (error) *error = [self errorWithDetail:@"ContainerManager 接口不可用" code:3];
        return nil;
    }

    dispatch_group_t waitGroup = nil;
    BOOL leader = NO;
    @synchronized (self) {
        MCMLease *cached = _leases[identifier];
        if (cached.rootPath.length && [self rootStillReadable:cached.rootPath])
            return cached.rootPath;

        waitGroup = _inFlight[identifier];
        if (!waitGroup) {
            waitGroup = dispatch_group_create();
            dispatch_group_enter(waitGroup);
            _inFlight[identifier] = waitGroup;
            leader = YES;
        }
    }

    if (!leader) {
        dispatch_group_wait(waitGroup, DISPATCH_TIME_FOREVER);
        @synchronized (self) {
            MCMLease *lease = _leases[identifier];
            if (lease.rootPath.length && [self rootStillReadable:lease.rootPath])
                return lease.rootPath;
            if (error) *error = _lastErrors[identifier] ?: [self errorWithDetail:nil code:4];
            return nil;
        }
    }

    dispatch_semaphore_wait(_activationSlots, DISPATCH_TIME_FOREVER);
    NSString *detail = nil;
    BOOL definitiveMissing = NO;
    MCMLease *lease = [self newUsableLeaseForIdentifier:identifier
        detail:&detail definitiveMissing:&definitiveMissing];
    dispatch_semaphore_signal(_activationSlots);
    NSError *failure = lease ? nil : [self errorWithDetail:detail
        code:definitiveMissing ? ENOENT : 5];

    @synchronized (self) {
        if (lease) {
            _leases[identifier] = lease;
            [_lastErrors removeObjectForKey:identifier];
        } else {
            _lastErrors[identifier] = failure;
        }
        [_inFlight removeObjectForKey:identifier];
    }
    dispatch_group_leave(waitGroup);

    if (!lease && error) *error = failure;
    return lease.rootPath;
}

@end

#pragma mark - App install/uninstall feedback + conservative stale repair

static UIWindow *FFAppChangeForegroundWindow(void)
{
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class])
                continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows)
                if (window.isKeyWindow) return window;
            if (windowScene.windows.count) return windowScene.windows.firstObject;
        }
    }
    for (UIWindow *window in application.windows)
        if (window.isKeyWindow) return window;
    return application.windows.firstObject;
}

static void FFShowAppChangeToast(NSString *message)
{
    if (!message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = FFAppChangeForegroundWindow();
        if (!window) return;

        const NSInteger tag = 0x46465453;
        UIView *old = [window viewWithTag:tag];
        [old removeFromSuperview];

        UIView *card = [UIView new];
        card.tag = tag;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = UIColor.secondarySystemBackgroundColor;
        card.layer.cornerRadius = 13.0;
        card.layer.shadowColor = UIColor.blackColor.CGColor;
        card.layer.shadowOpacity = 0.16;
        card.layer.shadowRadius = 10.0;
        card.layer.shadowOffset = CGSizeMake(0, 4);
        card.alpha = 0.0;

        UIImageView *icon = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.tintColor = UIColor.systemBlueColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;

        UILabel *label = [UILabel new];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        label.textColor = UIColor.labelColor;
        label.numberOfLines = 2;
        label.text = message;

        [card addSubview:icon];
        [card addSubview:label];
        [window addSubview:card];

        UILayoutGuide *safe = window.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [card.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
            [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
            [card.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],
            [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:20],
            [icon.heightAnchor constraintEqualToConstant:20],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
            [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:card.topAnchor constant:11],
            [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11],
        ]];

        [UIView animateWithDuration:0.18 animations:^{ card.alpha = 1.0; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (card.superview) {
                [UIView animateWithDuration:0.22 animations:^{ card.alpha = 0.0; }
                    completion:^(__unused BOOL finished) { [card removeFromSuperview]; }];
            }
        });
    });
}

static void FFRemoveAppDataSessionLink(NSString *identifier)
{
    if (!identifier.length) return;
    NSString *path = [FFAppDataVirtualPath() stringByAppendingPathComponent:identifier];
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
        unlink(path.fileSystemRepresentation);
}

@interface FFAppInstallChangeMonitor : NSObject
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL hasBaseline;
@property(nonatomic) NSUInteger lastInstalledCount;
@property(nonatomic) BOOL wasScanning;
@property(nonatomic) NSInteger pendingDelta;
@property(nonatomic) NSUInteger pendingAppDataBefore;
@property(nonatomic) BOOL cleanupInFlight;
@end

@implementation FFAppInstallChangeMonitor

+ (instancetype)sharedMonitor
{
    static FFAppInstallChangeMonitor *monitor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ monitor = [FFAppInstallChangeMonitor new]; });
    return monitor;
}

+ (void)load
{
    dispatch_async(dispatch_get_main_queue(), ^{ [[self sharedMonitor] start]; });
}

- (void)start
{
    if (self.started) return;
    self.started = YES;
    NSNumber *stored = [NSUserDefaults.standardUserDefaults
        objectForKey:kFFObservedInstalledCountKey];
    if ([stored isKindOfClass:NSNumber.class]) {
        self.hasBaseline = YES;
        self.lastInstalledCount = stored.unsignedIntegerValue;
    }
    self.wasScanning = FFAppDataScanCoordinator.sharedCoordinator.scanning;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(scanStateChanged:)
        name:FFAppDataScanStateDidChangeNotification object:nil];
}

- (void)scanStateChanged:(NSNotification *)note
{
    NSDictionary *info = note.userInfo;
    BOOL scanning = [info[@"Scanning"] boolValue];
    BOOL reliable = [info[@"InstalledCountReliable"] boolValue];
    NSUInteger installed = [info[@"InstalledCount"] unsignedIntegerValue];

    if (reliable) {
        if (!self.hasBaseline) {
            self.hasBaseline = YES;
            self.lastInstalledCount = installed;
            [NSUserDefaults.standardUserDefaults setObject:@(installed)
                forKey:kFFObservedInstalledCountKey];
            FFLogTag(@"AppChange", @"installed-count baseline=%lu",
                (unsigned long)installed);
        } else if (installed != self.lastInstalledCount) {
            NSInteger delta = (NSInteger)installed - (NSInteger)self.lastInstalledCount;
            if (self.pendingDelta == 0)
                self.pendingAppDataBefore = FFAppDataRegistry.sharedRegistry.identifiers.count;
            self.pendingDelta += delta;
            self.lastInstalledCount = installed;
            [NSUserDefaults.standardUserDefaults setObject:@(installed)
                forKey:kFFObservedInstalledCountKey];

            NSString *message = delta > 0
                ? [NSString stringWithFormat:@"检测到 %ld 个 App 已安装，正在同步 AppData…", (long)delta]
                : [NSString stringWithFormat:@"检测到 %ld 个 App 已卸载，正在同步 AppData…", (long)-delta];
            FFShowAppChangeToast(message);
            FFLogTag(@"AppChange", @"installed-count changed delta=%ld now=%lu appDataBefore=%lu",
                (long)delta, (unsigned long)installed,
                (unsigned long)self.pendingAppDataBefore);
        }
    }

    BOOL finished = self.wasScanning && !scanning;
    self.wasScanning = scanning;
    if (!finished || self.pendingDelta == 0) return;

    NSInteger delta = self.pendingDelta;
    NSUInteger before = self.pendingAppDataBefore;
    self.pendingDelta = 0;
    self.pendingAppDataBefore = 0;

    if (delta < 0) {
        [self repairAfterInstalledCountDrop:(NSUInteger)(-delta) appDataBefore:before];
    } else {
        NSUInteger after = FFAppDataRegistry.sharedRegistry.identifiers.count;
        NSInteger appDataDelta = (NSInteger)after - (NSInteger)before;
        NSString *message = appDataDelta > 0
            ? [NSString stringWithFormat:@"同步完成：新增 %ld 个 AppData", (long)appDataDelta]
            : @"App 变动同步完成";
        FFShowAppChangeToast(message);
    }
}

- (NSSet<NSString *> *)freshFailuresForIdentifiers:(NSArray<NSString *> *)identifiers
{
    if (identifiers.count == 0) return [NSSet set];
    NSObject *lock = [NSObject new];
    NSMutableSet<NSString *> *failures = [NSMutableSet set];
    __block NSUInteger next = 0;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    NSUInteger workers = MIN((NSUInteger)4, identifiers.count);

    for (NSUInteger worker = 0; worker < workers; worker++) {
        dispatch_group_async(group, queue, ^{
            while (YES) {
                NSString *identifier = nil;
                @synchronized (lock) {
                    if (next < identifiers.count) identifier = identifiers[next++];
                }
                if (!identifier) break;
                NSError *error = nil;
                NSString *root = [FFAppDataLeaseManager.sharedManager
                    reacquireIdentifier:identifier error:&error];
                if (!root.length) {
                    @synchronized (lock) { [failures addObject:identifier]; }
                    FFLogTag(@"AppChange", @"fresh MCM miss id=%@ error=%@",
                        identifier, error.localizedDescription ?: @"(nil)");
                }
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return failures.copy;
}

- (void)repairAfterInstalledCountDrop:(NSUInteger)expectedDrop
                        appDataBefore:(NSUInteger)appDataBefore
{
    if (self.cleanupInFlight || expectedDrop == 0) return;
    self.cleanupInFlight = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
        NSUInteger current = registry.identifiers.count;
        NSUInteger alreadyRemoved = appDataBefore > current ? appDataBefore - current : 0;
        NSUInteger remainingExpected = expectedDrop > alreadyRemoved
            ? expectedDrop - alreadyRemoved : 0;
        if (remainingExpected == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.cleanupInFlight = NO;
                FFShowAppChangeToast([NSString stringWithFormat:
                    @"同步完成：已清理 %lu 个 AppData", (unsigned long)alreadyRemoved]);
            });
            return;
        }

        NSArray<NSString *> *ids = registry.identifiers;
        NSSet<NSString *> *first = [self freshFailuresForIdentifiers:ids];
        usleep(250000);
        NSSet<NSString *> *second = [self freshFailuresForIdentifiers:first.allObjects];

        // iOS 27 returns "posix=0 unknown" for an uninstalled class-2 container,
        // so ENOENT cannot be the only deletion signal. Bound the repair by the
        // observed LaunchServices count drop and require two fresh MCM failures.
        // A few older stale entries may be repaired at the same time, but a broad
        // permission failure is never allowed to wipe the registry.
        NSUInteger maxSafeFailures = MIN((NSUInteger)4, remainingExpected + 3);
        BOOL safe = second.count >= remainingExpected && second.count <= maxSafeFailures;
        NSUInteger removed = 0;
        if (safe) {
            NSArray<NSString *> *stale = second.allObjects;
            for (NSString *identifier in stale) {
                [FFAppDataLeaseManager.sharedManager invalidateIdentifier:identifier];
                FFRemoveAppDataSessionLink(identifier);
            }
            removed = [registry removeIdentifiers:stale];
        }

        FFLogTag(@"AppChange",
            @"uninstall repair expected=%lu alreadyRemoved=%lu firstMiss=%lu secondMiss=%lu safe=%d removed=%lu registry=%lu",
            (unsigned long)expectedDrop, (unsigned long)alreadyRemoved,
            (unsigned long)first.count, (unsigned long)second.count, safe,
            (unsigned long)removed, (unsigned long)registry.identifiers.count);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.cleanupInFlight = NO;
            if (removed > 0 || alreadyRemoved > 0) {
                FFShowAppChangeToast([NSString stringWithFormat:
                    @"同步完成：已清理 %lu 个失效 AppData",
                    (unsigned long)(removed + alreadyRemoved)]);
            } else if (!safe) {
                FFShowAppChangeToast(@"App 已变动，AppData 校验未能安全确认");
            } else {
                FFShowAppChangeToast(@"App 变动同步完成");
            }
        });
    });
}

@end
