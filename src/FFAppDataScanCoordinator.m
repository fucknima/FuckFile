#import "FFAppDataScanCoordinator.h"
#import "FFStorageEnvironment.h"
#import "FFLSDiscovery.h"
#import "MCMManager.h"
#import "MCMBridge.h"
#import "FFLogger.h"

#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FFAppDataScanStateDidChangeNotification =
    @"FFAppDataScanStateDidChangeNotification";

// These selectors already exist in MCMManager.m. Keep the expensive scan
// orchestration outside MCMManager so advanced access can become ready without
// waiting for a full LaunchServices pass.
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
            unlink(link.fileSystemRepresentation);
        } else {
            // Never replace a user-created real file/folder.
            return NO;
        }
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        return NO;
    return FFValidLinkedDirectory(link);
}

- (void)publishScanning:(BOOL)scanning progress:(double)progress
                 linked:(NSUInteger)linked total:(NSUInteger)total
{
    @synchronized (self) {
        _scanning = scanning;
        _progress = progress;
        _linked = linked;
        _total = total;
    }
    NSDictionary *info = @{
        @"Scanning": @(scanning),
        @"Progress": @(progress),
        @"Linked": @(linked),
        @"Total": @(total),
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFAppDataScanStateDidChangeNotification
                          object:self userInfo:info];
        // Preserve the existing home-screen observer contract.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFMCMAppLinksUpdatedNotification
                          object:self userInfo:info];
    });
}

- (BOOL)isScanning
{
    @synchronized (self) { return _scanning; }
}

- (double)progress
{
    @synchronized (self) { return _progress; }
}

- (NSUInteger)total
{
    @synchronized (self) { return _total; }
}

- (NSUInteger)linked
{
    @synchronized (self) { return _linked; }
}

- (void)bootstrapWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion
{
    dispatch_async(_queue, ^{
        if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.mobile.MobileHouseArrest"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"当前 App 身份不是 MobileHouseArrest。 ");
            });
            return;
        }
        if (!MCMBridgeAvailable()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"ContainerManager 接口不可用。 ");
            });
            return;
        }

        NSString *root = FFStorageRootPath();
        NSString *apps = FFAppDataVirtualPath();
        [NSFileManager.defaultManager createDirectoryAtPath:apps
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];

        // Existing live link is the cheapest possible capability proof.
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
            if (FFValidLinkedDirectory([apps stringByAppendingPathComponent:name])) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
                return;
            }
        }

        MCMManager *mcm = MCMManager.sharedManager;
        NSArray<NSString *> *fastTargets = @[
            @"com.apple.mobilesafari",
            @"com.apple.mobilenotes",
            @"com.apple.Maps",
            @"com.apple.mobilemail",
        ];
        NSString *lastError = nil;
        for (NSString *identifier in fastTargets) {
            NSString *target = [mcm activateClass2WithMatrix:identifier error:&lastError];
            if (target.length && FFInstallAppDataLink(apps, identifier, target)) {
                FFLogTag(@"SystemAccess", @"fast bootstrap OK id=%@ root=%@", identifier, target);
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

static BOOL FFLooksLikeApplicationIdentifier(NSString *identifier)
{
    if (identifier.length < 5 || identifier.length > 180) return NO;
    if ([identifier hasPrefix:@"group."] ||
        [identifier hasPrefix:@"systemgroup."] ||
        [identifier hasPrefix:@"com.apple.private."] ||
        [identifier hasPrefix:@"com.apple.security."] ||
        [identifier hasPrefix:@"com.apple.developer."])
        return NO;
    if ([identifier hasSuffix:@".plist"] ||
        [identifier hasSuffix:@".framework"] ||
        [identifier hasSuffix:@".dylib"] ||
        [identifier hasSuffix:@".xpc"] ||
        [identifier hasSuffix:@".appex"])
        return NO;
    NSUInteger dots = 0;
    for (NSUInteger i = 0; i < identifier.length; i++)
        if ([identifier characterAtIndex:i] == '.') dots++;
    return dots >= 2;
}

- (void)scanWithCompletion:(void (^)(void))completion
{
    @synchronized (self) {
        if (completion) [_pendingScanCompletions addObject:[completion copy]];
        if (_scanning) return;
        _scanning = YES;
    }

    [self publishScanning:YES progress:0 linked:0 total:0];
    dispatch_async(_queue, ^{
        NSString *root = FFStorageRootPath();
        NSString *apps = FFAppDataVirtualPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:apps withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil];

        // Remove only broken generated symlinks. Real user files are untouched.
        for (NSString *name in [fm contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
            NSString *path = [apps stringByAppendingPathComponent:name];
            struct stat st = {0};
            if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode) &&
                !FFValidLinkedDirectory(path))
                unlink(path.fileSystemRepresentation);
        }

        MCMManager *mcm = MCMManager.sharedManager;
        NSString *lsdError = nil;
        NSString *lsdRoot = [mcm activate:10 identifier:@"com.apple.lsd"
            group:NO error:&lsdError];
        NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSetWithArray:@[
            @"com.apple.mobilesafari", @"com.apple.mobilenotes", @"com.apple.Maps",
            @"com.apple.mobilemail", @"com.apple.Photos", @"com.apple.AppStore",
            @"com.apple.Music", @"com.apple.MobileSMS", @"com.apple.Preferences",
        ]];

        if (lsdRoot.length) {
            NSArray<NSString *> *raw = FFLSDiscoverInstalledIdentifiers(lsdRoot, 12000);
            for (NSString *identifier in raw)
                if (FFLooksLikeApplicationIdentifier(identifier)) [candidates addObject:identifier];
        } else {
            FFLogTag(@"MCM", @"LS discovery unavailable during optimized scan: %@",
                lsdError ?: @"(nil)");
        }

        NSUInteger total = candidates.count;
        NSUInteger linked = 0;
        NSUInteger index = 0;
        [self publishScanning:YES progress:0 linked:0 total:total];

        for (NSString *identifier in candidates) {
            index++;
            NSString *link = [apps stringByAppendingPathComponent:identifier];
            if (FFValidLinkedDirectory(link)) {
                linked++;
            } else {
                NSString *error = nil;
                NSString *target = [mcm activateClass2WithMatrix:identifier error:&error];
                if (target.length && FFInstallAppDataLink(apps, identifier, target)) linked++;
            }

            if (index % 20 == 0 || index == total) {
                [self publishScanning:YES
                    progress:total ? (double)index / (double)total : 1.0
                    linked:linked total:total];
                // Yield between batches. ContainerManager is a system service;
                // hammering it continuously causes visible UI stalls even from
                // a background thread.
                usleep(6000);
            }
        }

        // Non-critical probes are deliberately after App Data discovery.
        [mcm runMobileGestaltProbe:root];
        [mcm writeAccessMap:root];

        [self publishScanning:NO progress:1.0 linked:linked total:total];
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
