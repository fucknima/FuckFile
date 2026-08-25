#import "FFAppDataScanCoordinator.h"
#import "FFStorageEnvironment.h"
#import "FFLSDiscovery.h"
#import "MCMManager.h"
#import "MCMBridge.h"
#import "FFLogger.h"

#import <limits.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FFAppDataScanStateDidChangeNotification =
    @"FFAppDataScanStateDidChangeNotification";

static NSString *const kFFKnownAppDataIdentifiersKey = @"FFKnownAppDataIdentifiers";
static NSString *const kFFAppDataNegativeFingerprintKey = @"FFAppDataNegativeFingerprint";
static NSString *const kFFAppDataNegativeIdentifiersKey = @"FFAppDataNegativeIdentifiers";
static NSString *const kFFAppDataLastDeepFingerprintKey = @"FFAppDataLastDeepFingerprint";

@interface MCMManager (FFScanCoordinatorPrivate)
- (nullable NSString *)activate:(uint64_t)containerClass
                     identifier:(NSString *)identifier
                          group:(BOOL)group
                          error:(NSString * _Nullable * _Nullable)error;
- (nullable NSString *)activateClass2WithMatrix:(NSString *)identifier
                                           error:(NSString * _Nullable * _Nullable)error;
- (void)runMobileGestaltProbe:(NSString *)root;
- (void)writeAccessMap:(NSString *)root;
@end

@interface FFAppDataScanCoordinator ()
@property(nonatomic) BOOL scanning;
@property(nonatomic) BOOL deepScanning;
@property(nonatomic) double progress;
@property(nonatomic) NSUInteger total;
@property(nonatomic) NSUInteger linked;
@end

@implementation FFAppDataScanCoordinator {
    dispatch_queue_t _queue;
    NSMutableArray<void (^)(void)> *_pendingScanCompletions;
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

static BOOL FFValidLinkedDirectory(NSString *path)
{
    struct stat linkStatus = {0};
    struct stat targetStatus = {0};
    return lstat(path.fileSystemRepresentation, &linkStatus) == 0 &&
        S_ISLNK(linkStatus.st_mode) &&
        stat(path.fileSystemRepresentation, &targetStatus) == 0 &&
        S_ISDIR(targetStatus.st_mode);
}

static BOOL FFInstallAppDataLink(NSString *apps, NSString *identifier, NSString *target)
{
    if (!apps.length || !identifier.length || !target.length) return NO;
    NSString *link = [apps stringByAppendingPathComponent:identifier];
    struct stat st = {0};
    if (lstat(link.fileSystemRepresentation, &st) == 0) {
        if (S_ISLNK(st.st_mode)) {
            char current[PATH_MAX] = {0};
            ssize_t length = readlink(link.fileSystemRepresentation, current, sizeof(current) - 1);
            if (length > 0) {
                current[length] = '\0';
                NSString *existing = [NSString stringWithUTF8String:current];
                if ([existing isEqualToString:target] && FFValidLinkedDirectory(link)) return YES;
            }
            // A stale link is replaced only after MCM has already returned a
            // fresh path for this exact identifier. Discovery misses never delete
            // a real/previously valid AppData entry.
            unlink(link.fileSystemRepresentation);
        } else {
            return NO;
        }
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        return NO;
    return FFValidLinkedDirectory(link);
}

static NSArray<NSString *> *FFWorkspaceApplicationIdentifiers(void)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return @[];
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
    SEL allSelector = NSSelectorFromString(@"allApplications");
    NSArray *applications = workspace && [workspace respondsToSelector:allSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(workspace, allSelector) : @[];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (id proxy in applications ?: @[]) {
        NSString *identifier = nil;
        SEL appIDSelector = NSSelectorFromString(@"applicationIdentifier");
        SEL bundleIDSelector = NSSelectorFromString(@"bundleIdentifier");
        if ([proxy respondsToSelector:appIDSelector])
            identifier = ((id (*)(id, SEL))objc_msgSend)(proxy, appIDSelector);
        if (!FFSafeIdentifier(identifier) && [proxy respondsToSelector:bundleIDSelector])
            identifier = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleIDSelector);
        if (FFSafeIdentifier(identifier)) [result addObject:identifier];
    }
    return result.array;
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

static NSArray<NSString *> *FFKnownAppDataIdentifiers(void)
{
    NSArray *stored = [NSUserDefaults.standardUserDefaults
        arrayForKey:kFFKnownAppDataIdentifiersKey];
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableOrderedSet<NSString *> *safe = [NSMutableOrderedSet orderedSet];
    for (id value in stored)
        if ([value isKindOfClass:NSString.class] && FFSafeIdentifier(value))
            [safe addObject:value];
    return safe.array;
}

static void FFPersistKnownAppDataIdentifiers(NSOrderedSet<NSString *> *identifiers)
{
    if (!identifiers) return;
    [NSUserDefaults.standardUserDefaults setObject:identifiers.array
                                            forKey:kFFKnownAppDataIdentifiersKey];
}

static NSMutableOrderedSet<NSString *> *FFNegativeIdentifiersForFingerprint(NSString *fingerprint)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *storedFingerprint = [defaults stringForKey:kFFAppDataNegativeFingerprintKey];
    if (!fingerprint.length || ![storedFingerprint isEqualToString:fingerprint])
        return [NSMutableOrderedSet orderedSet];

    NSArray *stored = [defaults arrayForKey:kFFAppDataNegativeIdentifiersKey];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (id value in stored ?: @[])
        if ([value isKindOfClass:NSString.class] && FFSafeIdentifier(value))
            [result addObject:value];
    return result;
}

static void FFPersistNegativeIdentifiers(NSString *fingerprint,
                                         NSOrderedSet<NSString *> *identifiers)
{
    if (!fingerprint.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:fingerprint forKey:kFFAppDataNegativeFingerprintKey];
    [defaults setObject:identifiers.array ?: @[] forKey:kFFAppDataNegativeIdentifiersKey];
}

static void FFClearDeepDiscoveryState(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:kFFAppDataNegativeFingerprintKey];
    [defaults removeObjectForKey:kFFAppDataNegativeIdentifiersKey];
    [defaults removeObjectForKey:kFFAppDataLastDeepFingerprintKey];
}

static BOOL FFFailureLooksPermanent(NSString *detail)
{
    if (!detail.length) return NO;
    NSString *lower = detail.lowercaseString;
    if ([lower containsString:@"posix=2"]) return YES; // ENOENT
    if ([lower containsString:@"no such file"]) return YES;
    if ([lower containsString:@"does not exist"]) return YES;
    if ([lower containsString:@"not found"]) return YES;
    return NO;
}

- (void)publishScanning:(BOOL)scanning progress:(double)progress
                 linked:(NSUInteger)linked total:(NSUInteger)total deep:(BOOL)deep
{
    @synchronized (self) {
        _scanning = scanning;
        _deepScanning = scanning && deep;
        _progress = progress;
        _linked = linked;
        _total = total;
    }
    NSDictionary *info = @{
        @"Scanning": @(scanning), @"DeepScanning": @(scanning && deep),
        @"Progress": @(progress), @"Linked": @(linked), @"Total": @(total),
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFAppDataScanStateDidChangeNotification
                          object:self userInfo:info];
    });
}

- (BOOL)isScanning { @synchronized (self) { return _scanning; } }
- (BOOL)isDeepScanning { @synchronized (self) { return _deepScanning; } }
- (double)progress { @synchronized (self) { return _progress; } }
- (NSUInteger)total { @synchronized (self) { return _total; } }
- (NSUInteger)linked { @synchronized (self) { return _linked; } }

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

        NSString *apps = FFAppDataVirtualPath();
        [NSFileManager.defaultManager createDirectoryAtPath:apps
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];

        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
            if (FFValidLinkedDirectory([apps stringByAppendingPathComponent:name])) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
                return;
            }
        }

        MCMManager *mcm = MCMManager.sharedManager;
        NSString *lastError = nil;
        for (NSString *identifier in @[@"com.apple.mobilesafari", @"com.apple.mobilenotes",
                                        @"com.apple.Maps", @"com.apple.mobilemail"]) {
            NSString *target = [mcm activateClass2WithMatrix:identifier error:&lastError];
            if (target.length && FFInstallAppDataLink(apps, identifier, target)) {
                NSMutableOrderedSet<NSString *> *known = [NSMutableOrderedSet
                    orderedSetWithArray:FFKnownAppDataIdentifiers()];
                [known addObject:identifier];
                FFPersistKnownAppDataIdentifiers(known);
                FFLogTag(@"SystemAccess", @"fast bootstrap OK id=%@", identifier);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
                return;
            }
        }
        NSString *reason = lastError.length
            ? [NSString stringWithFormat:@"快速能力探测失败：%@", lastError]
            : @"快速能力探测没有获得可用 App Data 容器。";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, reason); });
    });
}

- (void)scanWithCompletion:(void (^)(void))completion
{
    [self startScanForceFull:NO completion:completion];
}

- (void)fullRescanWithCompletion:(void (^)(void))completion
{
    [self startScanForceFull:YES completion:completion];
}

- (void)startScanForceFull:(BOOL)forceFull completion:(void (^)(void))completion
{
    @synchronized (self) {
        if (completion) [_pendingScanCompletions addObject:[completion copy]];
        if (_scanning) return;
        _scanning = YES;
        _deepScanning = NO;
    }

    [self publishScanning:YES progress:0 linked:0 total:0 deep:NO];
    dispatch_async(_queue, ^{
        NSString *root = FFStorageRootPath();
        NSString *apps = FFAppDataVirtualPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:apps withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil];

        NSMutableOrderedSet<NSString *> *existingLinks = [NSMutableOrderedSet orderedSet];
        NSMutableOrderedSet<NSString *> *validExistingLinks = [NSMutableOrderedSet orderedSet];
        for (NSString *name in [fm contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
            NSString *path = [apps stringByAppendingPathComponent:name];
            struct stat st = {0};
            if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISLNK(st.st_mode)) continue;
            if (!FFSafeIdentifier(name)) continue;
            [existingLinks addObject:name];
            if (FFValidLinkedDirectory(path))
                [validExistingLinks addObject:name];
            else
                FFLogTag(@"MCM", @"preserve stale AppData link pending revalidation id=%@", name);
        }

        NSArray<NSString *> *workspace = FFWorkspaceApplicationIdentifiers();
        NSArray<NSString *> *knownStored = FFKnownAppDataIdentifiers();
        NSString *enumerationError = nil;
        NSArray<NSString *> *dynamic = MCMEnumerateIdentifiersForClass(
            2, NSUIntegerMax, &enumerationError);
        NSMutableOrderedSet<NSString *> *dynamicSafe = [NSMutableOrderedSet orderedSet];
        for (NSString *identifier in dynamic ?: @[])
            if (FFSafeIdentifier(identifier)) [dynamicSafe addObject:identifier];

        // Fast/high-confidence phase. It never waits for the noisy csstore pass.
        NSMutableOrderedSet<NSString *> *quickCandidates = [NSMutableOrderedSet orderedSet];
        [quickCandidates addObjectsFromArray:existingLinks.array];
        [quickCandidates addObjectsFromArray:knownStored];
        [quickCandidates addObjectsFromArray:workspace];
        [quickCandidates addObjectsFromArray:dynamicSafe.array];
        [quickCandidates addObjectsFromArray:FFResearchIdentifiers()];
        [quickCandidates addObjectsFromArray:FFCustomIdentifiers()];

        NSMutableOrderedSet<NSString *> *knownSuccessful = [NSMutableOrderedSet
            orderedSetWithArray:knownStored];
        [knownSuccessful addObjectsFromArray:validExistingLinks.array];
        NSUInteger linked = 0;
        NSUInteger quickIndex = 0;
        NSUInteger quickTotal = quickCandidates.count;
        MCMManager *mcm = MCMManager.sharedManager;

        FFLogTag(@"MCM", @"AppData quick discovery total=%lu mcm=%lu workspace=%lu existing=%lu known=%lu detail=%@",
            (unsigned long)quickTotal, (unsigned long)dynamicSafe.count,
            (unsigned long)workspace.count, (unsigned long)existingLinks.count,
            (unsigned long)knownStored.count, enumerationError ?: @"(nil)");
        [self publishScanning:YES progress:quickTotal ? 0 : 1
            linked:0 total:quickTotal deep:NO];

        for (NSString *identifier in quickCandidates) {
            quickIndex++;
            NSString *link = [apps stringByAppendingPathComponent:identifier];
            if (FFValidLinkedDirectory(link)) {
                linked++;
                [knownSuccessful addObject:identifier];
            } else {
                NSString *error = nil;
                NSString *target = [mcm activateClass2WithMatrix:identifier error:&error];
                if (target.length && FFInstallAppDataLink(apps, identifier, target)) {
                    linked++;
                    [knownSuccessful addObject:identifier];
                }
            }

            if (quickIndex % 25 == 0 || quickIndex == quickTotal) {
                [self publishScanning:YES
                    progress:quickTotal ? (double)quickIndex / (double)quickTotal : 1.0
                    linked:linked total:quickTotal deep:NO];
                FFPersistKnownAppDataIdentifiers(knownSuccessful);
                usleep(1500);
            }
        }
        FFPersistKnownAppDataIdentifiers(knownSuccessful);

        // Deep fallback is incremental. The LaunchServices store fingerprint
        // decides whether anything changed, and a per-fingerprint negative cache
        // prevents the same ENOENT junk candidates from being retried forever.
        NSString *lsdError = nil;
        NSString *lsdRoot = [mcm activate:10 identifier:@"com.apple.lsd" group:NO error:&lsdError];
        if (lsdRoot.length) {
            if (forceFull) {
                FFClearDeepDiscoveryState();
                FFLSInvalidateDiscoveryCaches();
            }

            NSString *fingerprint = FFLSStoreFingerprint(lsdRoot);
            NSString *lastDeepFingerprint = [NSUserDefaults.standardUserDefaults
                stringForKey:kFFAppDataLastDeepFingerprintKey];
            BOOL needsDeep = forceFull ||
                (fingerprint.length && ![lastDeepFingerprint isEqualToString:fingerprint]);

            if (needsDeep && fingerprint.length) {
                NSArray<NSString *> *raw = FFLSDiscoverInstalledIdentifiers(lsdRoot, 65536);
                NSMutableOrderedSet<NSString *> *negative = forceFull
                    ? [NSMutableOrderedSet orderedSet]
                    : FFNegativeIdentifiersForFingerprint(fingerprint);
                NSMutableOrderedSet<NSString *> *deepCandidates = [NSMutableOrderedSet orderedSet];
                for (NSString *identifier in raw) {
                    if (!FFSafeIdentifier(identifier)) continue;
                    if ([quickCandidates containsObject:identifier]) continue;
                    if ([negative containsObject:identifier]) continue;
                    [deepCandidates addObject:identifier];
                }

                NSUInteger deepIndex = 0;
                NSUInteger deepTotal = deepCandidates.count;
                NSUInteger transientFailures = 0;
                [self publishScanning:YES progress:deepTotal ? 0 : 1
                    linked:linked total:deepTotal deep:YES];
                FFLogTag(@"MCM", @"AppData deep discovery raw=%lu pending=%lu negative=%lu force=%d fingerprintChanged=%d",
                    (unsigned long)raw.count, (unsigned long)deepTotal,
                    (unsigned long)negative.count, forceFull,
                    ![lastDeepFingerprint isEqualToString:fingerprint]);

                for (NSString *identifier in deepCandidates) {
                    deepIndex++;
                    NSString *error = nil;
                    NSString *target = [mcm activateClass2WithMatrix:identifier error:&error];
                    if (target.length && FFInstallAppDataLink(apps, identifier, target)) {
                        linked++;
                        [knownSuccessful addObject:identifier];
                        [negative removeObject:identifier];
                    } else if (FFFailureLooksPermanent(error)) {
                        [negative addObject:identifier];
                    } else {
                        transientFailures++;
                    }

                    if (deepIndex % 100 == 0 || deepIndex == deepTotal) {
                        FFPersistKnownAppDataIdentifiers(knownSuccessful);
                        FFPersistNegativeIdentifiers(fingerprint, negative);
                        [self publishScanning:YES
                            progress:deepTotal ? (double)deepIndex / (double)deepTotal : 1.0
                            linked:linked total:deepTotal deep:YES];
                        usleep(2500);
                    }
                }

                FFPersistKnownAppDataIdentifiers(knownSuccessful);
                FFPersistNegativeIdentifiers(fingerprint, negative);
                if (transientFailures == 0) {
                    [NSUserDefaults.standardUserDefaults setObject:fingerprint
                        forKey:kFFAppDataLastDeepFingerprintKey];
                } else {
                    // Leave the deep fingerprint incomplete so the next launch
                    // retries only transient failures; permanent junk remains
                    // suppressed by the negative cache.
                    [NSUserDefaults.standardUserDefaults
                        removeObjectForKey:kFFAppDataLastDeepFingerprintKey];
                }
                FFLogTag(@"MCM", @"AppData deep complete linked=%lu transient=%lu negative=%lu",
                    (unsigned long)linked, (unsigned long)transientFailures,
                    (unsigned long)negative.count);
            } else if (fingerprint.length) {
                FFLogTag(@"MCM", @"AppData deep scan skipped; LaunchServices fingerprint unchanged");
            } else {
                FFLogTag(@"MCM", @"AppData deep scan skipped; no LaunchServices fingerprint");
            }
        } else {
            FFLogTag(@"MCM", @"AppData deep scan unavailable detail=%@", lsdError ?: @"(nil)");
        }

        FFPersistKnownAppDataIdentifiers(knownSuccessful);
        [mcm runMobileGestaltProbe:root];
        [mcm writeAccessMap:root];

        [self publishScanning:NO progress:1.0 linked:linked total:0 deep:NO];
        NSArray<void (^)(void)> *callbacks = nil;
        @synchronized (self) {
            _scanning = NO;
            _deepScanning = NO;
            callbacks = [_pendingScanCompletions copy];
            [_pendingScanCompletions removeAllObjects];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^callback)(void) in callbacks) callback();
        });
    });
}

@end
