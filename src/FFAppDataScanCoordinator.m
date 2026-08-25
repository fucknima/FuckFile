#import "FFAppDataScanCoordinator.h"
#import "FFStorageEnvironment.h"
#import "FFLSDiscovery.h"
#import "MCMManager.h"
#import "MCMBridge.h"
#import "FFLogger.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataLeaseManager.h"
#import "FFAppNames.h"

#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FFAppDataScanStateDidChangeNotification =
    @"FFAppDataScanStateDidChangeNotification";

static NSString *const kFFAppDataLSFingerprintKey =
    @"FFAppDataLastLaunchServicesFingerprintV1";

@interface MCMManager (FFScanCoordinatorPrivate)
- (nullable NSString *)activate:(uint64_t)containerClass
                     identifier:(NSString *)identifier
                          group:(BOOL)group
                          error:(NSString * _Nullable * _Nullable)error;
- (void)runMobileGestaltProbe:(NSString *)root;
- (void)writeAccessMap:(NSString *)root;
@end

@interface FFAppDataScanCoordinator ()
@property(nonatomic) BOOL scanning;
@property(nonatomic) double progress;
@property(nonatomic) NSUInteger total;
@property(nonatomic) NSUInteger linked;
@property(nonatomic) NSUInteger installedCount;
@property(nonatomic) BOOL installedCountReliable;
@end

@implementation FFAppDataScanCoordinator {
    dispatch_queue_t _queue;
    NSMutableArray<void (^)(void)> *_pendingScanCompletions;
    NSTimeInterval _lastFingerprintCheck;
}

+ (instancetype)sharedCoordinator
{
    static FFAppDataScanCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ coordinator = [FFAppDataScanCoordinator new]; });
    return coordinator;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _queue = dispatch_queue_create("ff.appdata.scan", attr);
        _pendingScanCompletions = [NSMutableArray array];
    }
    return self;
}

static BOOL FFSafeIdentifier(NSString *identifier)
{
    if (identifier.length < 3 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier hasPrefix:@"."] && ![identifier hasSuffix:@"."] &&
        ![identifier containsString:@".."] && [identifier containsString:@"."];
}

static void FFRemoveSessionMaterialization(NSString *identifier)
{
    if (!FFSafeIdentifier(identifier)) return;
    NSString *path = [FFAppDataVirtualPath() stringByAppendingPathComponent:identifier];
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISLNK(st.st_mode)) return;
    if (unlink(path.fileSystemRepresentation) == 0)
        FFLogTag(@"AppDataSync", @"removed session materialization id=%@", identifier);
}

static NSArray<NSString *> *FFResearchIdentifiers(void)
{
    return @[
        @"com.apple.mobilesafari", @"com.apple.mobilenotes", @"com.apple.Maps",
        @"com.apple.facetime", @"com.apple.iBooks", @"com.apple.podcasts",
        @"com.apple.PosterBoard", @"com.apple.mobilemail", @"com.apple.weather",
        @"com.apple.camera", @"com.apple.Health", @"com.apple.Fitness",
        @"com.apple.tips", @"com.apple.Passbook", @"com.apple.reminders",
        @"com.apple.stocks", @"com.apple.news", @"com.apple.Home", @"com.apple.tv",
        @"com.apple.shortcuts", @"com.apple.freeform", @"com.apple.calculator",
        @"com.apple.MobileSMS", @"com.apple.InCallService", @"com.apple.Preferences",
        @"com.apple.springboard", @"com.apple.Photos", @"com.apple.AppStore",
        @"com.apple.Music", @"com.apple.Bridge", @"com.apple.Clock",
        @"com.apple.VoiceMemos", @"com.apple.Translate", @"com.apple.measure",
        @"com.apple.compass", @"com.apple.Magnifier", @"com.apple.DocumentsApp",
    ];
}

static NSArray<NSString *> *FFCustomIdentifiers(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *customPath = [documents stringByAppendingPathComponent:@"MCMIdentifiers.plist"];
    NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"MCMIdentifiers" ofType:@"plist"];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (NSString *path in @[bundlePath ?: @"", customPath]) {
        NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:path];
        NSArray *values = [dictionary[@"AppData"] isKindOfClass:NSArray.class]
            ? dictionary[@"AppData"] : @[];
        for (id value in values)
            if ([value isKindOfClass:NSString.class] && FFSafeIdentifier(value))
                [result addObject:value];
    }
    return result.array;
}

- (void)publishScanning:(BOOL)scanning progress:(double)progress
                 linked:(NSUInteger)linked total:(NSUInteger)total
{
    NSUInteger installed = 0;
    BOOL reliableInstalled = NO;
    @synchronized (self) {
        _scanning = scanning;
        _progress = progress;
        _linked = linked;
        _total = total;
        installed = _installedCount;
        reliableInstalled = _installedCountReliable;
    }
    NSDictionary *info = @{
        @"Scanning": @(scanning), @"Progress": @(progress),
        @"Linked": @(linked), @"Total": @(total),
        @"InstalledCount": @(installed),
        @"InstalledCountReliable": @(reliableInstalled),
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFAppDataScanStateDidChangeNotification
                          object:self userInfo:info];
    });
}

- (void)updateInstalledCountFromLSDRoot:(NSString *)lsdRoot
{
    if (!lsdRoot.length) return;
    NSUInteger count = FFLSBundleRecordCount(lsdRoot);
    if (count == NSNotFound) return;
    @synchronized (self) {
        _installedCount = count;
        _installedCountReliable = YES;
    }
    FFLogTag(@"LSInventory", @"installed Bundle records=%lu AppData=%lu",
        (unsigned long)count,
        (unsigned long)FFAppDataRegistry.sharedRegistry.identifiers.count);
}

- (BOOL)isScanning { @synchronized (self) { return _scanning; } }
- (double)progress { @synchronized (self) { return _progress; } }
- (NSUInteger)total { @synchronized (self) { return _total; } }
- (NSUInteger)linked { @synchronized (self) { return _linked; } }
- (NSUInteger)installedCount { @synchronized (self) { return _installedCount; } }
- (BOOL)installedCountReliable { @synchronized (self) { return _installedCountReliable; } }

- (void)bootstrapWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion
{
    dispatch_async(_queue, ^{
        if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.mobile.MobileHouseArrest"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"当前 App 身份不是 MobileHouseArrest。");
            });
            return;
        }
        if (!MCMBridgeAvailable()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"ContainerManager 接口不可用。");
            });
            return;
        }

        FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
        [registry prepareVirtualRootAndMigrateLegacyLinks];

        NSMutableOrderedSet<NSString *> *probes = [NSMutableOrderedSet orderedSet];
        NSArray<NSString *> *known = registry.identifiers;
        NSUInteger knownLimit = MIN((NSUInteger)8, known.count);
        if (knownLimit) [probes addObjectsFromArray:[known subarrayWithRange:NSMakeRange(0, knownLimit)]];
        [probes addObjectsFromArray:@[
            @"com.apple.mobilesafari", @"com.apple.mobilenotes",
            @"com.apple.Maps", @"com.apple.mobilemail"
        ]];

        NSError *lastError = nil;
        for (NSString *identifier in probes) {
            NSString *target = [FFAppDataLeaseManager.sharedManager
                acquireIdentifier:identifier error:&lastError];
            if (!target.length) continue;
            NSString *name = FFAppContainerItemName(target);
            if (!name.length) name = FFAppDisplayName(identifier);
            [registry registerIdentifier:identifier displayName:name];
            FFLogTag(@"SystemAccess", @"virtual bootstrap OK id=%@", identifier);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
            return;
        }

        NSString *reason = lastError.localizedDescription.length
            ? [NSString stringWithFormat:@"快速能力探测失败：%@", lastError.localizedDescription]
            : @"快速能力探测没有获得可用 App Data 容器。";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, reason); });
    });
}

- (void)checkForInstalledAppChanges
{
    dispatch_async(_queue, ^{
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (now - self->_lastFingerprintCheck < 2.0) return;
        self->_lastFingerprintCheck = now;

        if (self.scanning) return;

        NSString *lsdError = nil;
        NSString *lsdRoot = [MCMManager.sharedManager activate:10
            identifier:@"com.apple.lsd" group:NO error:&lsdError];
        if (!lsdRoot.length) {
            FFLogTag(@"AppDataSync", @"change check skipped: lsd unavailable detail=%@",
                lsdError ?: @"(nil)");
            return;
        }

        [self updateInstalledCountFromLSDRoot:lsdRoot];
        [self publishScanning:self.scanning progress:self.progress
                       linked:FFAppDataRegistry.sharedRegistry.identifiers.count
                        total:self.total];

        NSString *current = FFLSStoreFingerprint(lsdRoot);
        if (!current.length) {
            FFLogTag(@"AppDataSync", @"change check skipped: no LS fingerprint");
            return;
        }

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *previous = [defaults stringForKey:kFFAppDataLSFingerprintKey];
        if (!previous.length) {
            // Existing registries upgrade without a surprise 20k scan. This
            // establishes the baseline; any later install/uninstall changes it.
            [defaults setObject:current forKey:kFFAppDataLSFingerprintKey];
            FFLogTag(@"AppDataSync", @"established LS fingerprint baseline known=%lu",
                (unsigned long)FFAppDataRegistry.sharedRegistry.identifiers.count);
            return;
        }
        if ([previous isEqualToString:current]) {
            FFLogTag(@"AppDataSync", @"LS fingerprint unchanged; no rescan");
            return;
        }

        FFLogTag(@"AppDataSync", @"LS fingerprint changed; schedule reconciliation");
        [self scanWithCompletion:nil];
    });
}

- (void)scanWithCompletion:(void (^)(void))completion
{
    @synchronized (self) {
        if (completion) [_pendingScanCompletions addObject:[completion copy]];
        if (_scanning) return;
        _scanning = YES;
    }

    FFAppDataRegistry *sharedRegistry = FFAppDataRegistry.sharedRegistry;
    [self publishScanning:YES progress:0 linked:sharedRegistry.identifiers.count total:0];
    dispatch_async(_queue, ^{
        NSString *root = FFStorageRootPath();
        FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
        [registry prepareVirtualRootAndMigrateLegacyLinks];
        NSArray<NSString *> *registryBefore = registry.identifiers;
        NSSet<NSString *> *registryBeforeSet = [NSSet setWithArray:registryBefore];

        NSArray<NSString *> *structured = FFLSStructuredInstalledApplicationIdentifiers();
        MCMManager *mcm = MCMManager.sharedManager;
        NSString *lsdError = nil;
        NSString *lsdRoot = [mcm activate:10 identifier:@"com.apple.lsd" group:NO error:&lsdError];
        NSUInteger bundleRecordCount = NSNotFound;
        if (lsdRoot.length) {
            bundleRecordCount = FFLSBundleRecordCount(lsdRoot);
            if (bundleRecordCount != NSNotFound) {
                @synchronized (self) {
                    self->_installedCount = bundleRecordCount;
                    self->_installedCountReliable = YES;
                }
            }
        }

        // Only treat LSApplicationWorkspace as authoritative when its unique
        // installed identifiers exactly match the structural Bundle-table count.
        // Otherwise a private API filter could make a partial list look complete
        // and cause destructive registry eviction.
        BOOL structuredComplete = bundleRecordCount != NSNotFound &&
            structured.count > 0 && structured.count == bundleRecordCount;

        NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
        NSArray<NSString *> *dynamic = @[];
        NSString *enumerationError = nil;
        BOOL usedRawFallback = NO;
        NSUInteger authoritativeRemoved = 0;

        if (structuredComplete) {
            NSSet<NSString *> *installedSet = [NSSet setWithArray:structured];
            NSMutableArray<NSString *> *stale = [NSMutableArray array];
            for (NSString *identifier in registryBefore) {
                if (![installedSet containsObject:identifier]) [stale addObject:identifier];
            }

            // LaunchServices answers the installed/uninstalled question. Do not
            // let a readable process-local cached MCM lease resurrect an app that
            // LS has already removed.
            for (NSString *identifier in stale) {
                [FFAppDataLeaseManager.sharedManager invalidateIdentifier:identifier];
                FFRemoveSessionMaterialization(identifier);
            }
            authoritativeRemoved = [registry removeIdentifiers:stale];
            [candidates addObjectsFromArray:structured];

            FFLogTag(@"AppDataSync",
                @"authoritative LS inventory installed=%lu registryBefore=%lu removed=%lu",
                (unsigned long)structured.count, (unsigned long)registryBefore.count,
                (unsigned long)authoritativeRemoved);
            FFLogTag(@"LSInventory", @"structured inventory complete=%lu; skip raw csstore candidates",
                (unsigned long)structured.count);
        } else {
            // Conservative fallback: preserve every previously known AppData id,
            // add all discoverable sources, and only evict on two direct MCM
            // ENOENT observations. This is intentionally non-destructive when LS
            // structured enumeration is incomplete on a particular iOS build.
            [candidates addObjectsFromArray:registryBefore];
            dynamic = MCMEnumerateIdentifiersForClass(2, 1024, &enumerationError);
            for (NSString *identifier in dynamic ?: @[])
                if (FFSafeIdentifier(identifier)) [candidates addObject:identifier];
            [candidates addObjectsFromArray:structured];
            [candidates addObjectsFromArray:FFResearchIdentifiers()];
            [candidates addObjectsFromArray:FFCustomIdentifiers()];

            if (lsdRoot.length) {
                NSArray<NSString *> *raw = FFLSDiscoverInstalledIdentifiers(lsdRoot, 65536);
                for (NSString *identifier in raw)
                    if (FFSafeIdentifier(identifier)) [candidates addObject:identifier];
                usedRawFallback = YES;
                FFLogTag(@"LSInventory", @"structured=%lu BundleRecords=%@; raw fallback=%lu",
                    (unsigned long)structured.count,
                    bundleRecordCount == NSNotFound ? @"unknown" : [NSString stringWithFormat:@"%lu", (unsigned long)bundleRecordCount],
                    (unsigned long)raw.count);
            } else {
                FFLogTag(@"MCM", @"LS discovery unavailable detail=%@", lsdError ?: @"(nil)");
            }
        }

        NSArray<NSString *> *all = candidates.array;
        NSUInteger total = all.count;
        [self publishScanning:YES progress:0 linked:registry.identifiers.count total:total];
        FFLogTag(@"MCM", @"virtual discovery candidates=%lu structured=%lu dynamic=%lu authoritative=%d rawFallback=%d workers=4 detail=%@",
            (unsigned long)total, (unsigned long)structured.count,
            (unsigned long)dynamic.count, structuredComplete, usedRawFallback,
            enumerationError ?: @"(nil)");

        NSObject *stateLock = [NSObject new];
        __block NSUInteger nextIndex = 0;
        __block NSUInteger processed = 0;
        __block NSUInteger accessibleThisPass = 0;
        NSMutableSet<NSString *> *definitiveMissing = [NSMutableSet set];
        dispatch_group_t workers = dispatch_group_create();
        dispatch_queue_t workerQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        NSUInteger workerCount = MIN((NSUInteger)4, MAX((NSUInteger)1, total));

        for (NSUInteger worker = 0; worker < workerCount; worker++) {
            dispatch_group_async(workers, workerQueue, ^{
                while (YES) {
                    NSString *identifier = nil;
                    @synchronized (stateLock) {
                        if (nextIndex < all.count) identifier = all[nextIndex++];
                    }
                    if (!identifier) break;

                    NSError *error = nil;
                    NSString *target = [FFAppDataLeaseManager.sharedManager
                        acquireIdentifier:identifier error:&error];
                    if (target.length) {
                        NSString *name = FFAppContainerItemName(target);
                        if (!name.length) name = FFAppDisplayName(identifier);
                        [registry registerIdentifier:identifier displayName:name];
                    } else if (error.code == ENOENT &&
                               [registryBeforeSet containsObject:identifier]) {
                        @synchronized (stateLock) {
                            [definitiveMissing addObject:identifier];
                        }
                    }

                    NSUInteger snapshot = 0;
                    NSUInteger linkedSnapshot = 0;
                    @synchronized (stateLock) {
                        processed++;
                        if (target.length) accessibleThisPass++;
                        snapshot = processed;
                        linkedSnapshot = registry.identifiers.count;
                    }
                    if (snapshot % 25 == 0 || snapshot == total) {
                        [self publishScanning:YES
                            progress:total ? (double)snapshot / (double)total : 1.0
                            linked:linkedSnapshot total:total];
                    }
                }
            });
        }
        dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);

        // For identifiers still considered installed (or when LS inventory is
        // not authoritative), retain the conservative two-ENOENT MCM rule.
        NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
        for (NSString *identifier in definitiveMissing.allObjects) {
            NSError *verifyError = nil;
            NSString *target = [FFAppDataLeaseManager.sharedManager
                acquireIdentifier:identifier error:&verifyError];
            if (target.length) {
                NSString *name = FFAppContainerItemName(target);
                if (!name.length) name = FFAppDisplayName(identifier);
                [registry registerIdentifier:identifier displayName:name];
                FFLogTag(@"AppDataSync", @"missing candidate recovered id=%@", identifier);
            } else if (verifyError.code == ENOENT) {
                [toRemove addObject:identifier];
            } else {
                FFLogTag(@"AppDataSync", @"keep id=%@ after non-ENOENT verify error=%@",
                    identifier, verifyError.localizedDescription ?: @"(nil)");
            }
        }
        for (NSString *identifier in toRemove) {
            [FFAppDataLeaseManager.sharedManager invalidateIdentifier:identifier];
            FFRemoveSessionMaterialization(identifier);
        }
        NSUInteger confirmedRemoved = [registry removeIdentifiers:toRemove];
        NSUInteger removedCount = authoritativeRemoved + confirmedRemoved;

        FFLogTag(@"MCM", @"virtual discovery complete processed=%lu accessible=%lu registry=%lu removed=%lu installed=%@ authoritative=%d",
            (unsigned long)processed, (unsigned long)accessibleThisPass,
            (unsigned long)registry.identifiers.count, (unsigned long)removedCount,
            self.installedCountReliable
                ? [NSString stringWithFormat:@"%lu", (unsigned long)self.installedCount]
                : @"unknown",
            structuredComplete);

        // Save the fingerprint only after reconciliation completes. If lsd is
        // inaccessible, keep the old baseline so the next foreground can retry.
        NSString *finalFingerprint = lsdRoot.length ? FFLSStoreFingerprint(lsdRoot) : nil;
        if (finalFingerprint.length) {
            [NSUserDefaults.standardUserDefaults setObject:finalFingerprint
                forKey:kFFAppDataLSFingerprintKey];
        }

        [mcm runMobileGestaltProbe:root];
        [mcm writeAccessMap:root];

        [self publishScanning:NO progress:1.0 linked:registry.identifiers.count total:total];
        NSArray<void (^)(void)> *callbacks = nil;
        @synchronized (self) {
            _scanning = NO;
            callbacks = [_pendingScanCompletions copy];
            [_pendingScanCompletions removeAllObjects];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^callback)(void) in callbacks) callback();
        });
    });
}

@end
