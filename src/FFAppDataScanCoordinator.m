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
        if (result.count >= 1024) break;
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
        @"Scanning": @(scanning), @"Progress": @(progress),
        @"Linked": @(linked), @"Total": @(total),
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFAppDataScanStateDidChangeNotification
                          object:self userInfo:info];
    });
}

- (BOOL)isScanning { @synchronized (self) { return _scanning; } }
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

        for (NSString *name in [fm contentsOfDirectoryAtPath:apps error:nil] ?: @[]) {
            NSString *path = [apps stringByAppendingPathComponent:name];
            struct stat st = {0};
            if (lstat(path.fileSystemRepresentation, &st) == 0 &&
                S_ISLNK(st.st_mode) && !FFValidLinkedDirectory(path))
                unlink(path.fileSystemRepresentation);
        }

        NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
        NSString *enumerationError = nil;
        NSArray<NSString *> *dynamic = MCMEnumerateIdentifiersForClass(2, 1024, &enumerationError);
        for (NSString *identifier in dynamic ?: @[])
            if (FFSafeIdentifier(identifier)) [candidates addObject:identifier];
        [candidates addObjectsFromArray:FFWorkspaceApplicationIdentifiers()];
        [candidates addObjectsFromArray:FFResearchIdentifiers()];
        [candidates addObjectsFromArray:FFCustomIdentifiers()];

        MCMManager *mcm = MCMManager.sharedManager;
        NSString *lsdError = nil;
        NSString *lsdRoot = [mcm activate:10 identifier:@"com.apple.lsd" group:NO error:&lsdError];
        if (lsdRoot.length) {
            NSArray<NSString *> *raw = FFLSDiscoverInstalledIdentifiers(lsdRoot, 65536);
            for (NSString *identifier in raw)
                if (FFSafeIdentifier(identifier)) [candidates addObject:identifier];
        } else {
            FFLogTag(@"MCM", @"LS discovery unavailable detail=%@", lsdError ?: @"(nil)");
        }

        NSUInteger total = candidates.count;
        NSUInteger linked = 0;
        NSUInteger index = 0;
        [self publishScanning:YES progress:0 linked:0 total:total];
        FFLogTag(@"MCM", @"full discovery candidates=%lu dynamic=%lu detail=%@",
            (unsigned long)total, (unsigned long)dynamic.count,
            enumerationError ?: @"(nil)");

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

            if (index % 25 == 0 || index == total) {
                [self publishScanning:YES
                    progress:total ? (double)index / (double)total : 1.0
                    linked:linked total:total];
                usleep(2500);
            }
        }

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
