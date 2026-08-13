// MCMManager.m — MCM identity-bypass integration layer for FuckFile.
// Core logic ported from 0xjohnnydev/FilzaSlop MCMFilzaIntegration.m
// (https://github.com/0xjohnnydev/FilzaSlop), stripped of Filza-specific
// functionality (paste hooks, unrestricted filesystem, wallpaper lab,
// Files traversal). Identifier whitelisting and fail-closed checks kept.

#import "MCMManager.h"
#import "MCMBridge.h"
#import "FFLogger.h"
#import "FFLSDiscovery.h"

#import <fcntl.h>
#import <limits.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static const uint64_t kMCMFlags = 0x900000000ULL;
static NSString *const kRequiredIdentifier = @"com.apple.mobile.MobileHouseArrest";

NSNotificationName const FFMCMAppLinksUpdatedNotification =
    @"FFMCMAppLinksUpdatedNotification";

// Private LaunchServices API used only for installed-app discovery.
@interface NSObject (MCMLaunchServices)
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
@end


NSString *MCMVirtualRoot(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"Device Storage"];
}

@implementation MCMManager {
    NSMutableDictionary<NSString *, MCMLease *> *_leases;
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *_links;
    BOOL _started;
}

+ (instancetype)sharedManager
{
    static MCMManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [MCMManager new]; });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _leases = [NSMutableDictionary dictionary];
        _links = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Identifier validation

static BOOL MCMSafeIdentifier(NSString *identifier)
{
    if (identifier.length == 0 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier isEqualToString:@"."] && ![identifier isEqualToString:@".."];
}

#pragma mark - Lease activation

static NSString *MCMKey(uint64_t containerClass, NSString *identifier)
{
    return [NSString stringWithFormat:@"%llu:%@", containerClass, identifier];
}

- (NSString *)activate:(uint64_t)containerClass
            identifier:(NSString *)identifier
                 group:(BOOL)group
                 error:(NSString **)error
{
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:kRequiredIdentifier]) {
        if (error) *error = @"host bundle identifier is not the required MCM caller identity";
        return nil;
    }
    if (!MCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    @synchronized (_leases) {
        MCMLease *existing = _leases[MCMKey(containerClass, identifier)];
        if (existing && existing.rootPath.length) return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass identifier:identifier
            group:group part:0 flags:kMCMFlags error:&detail];
        BOOL activated = lease && [lease activate:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"MCM activation failed";
            return nil;
        }
        // iOS 26 containermanagerd lacks genericExtensionsAllowedForAll: it
        // refuses sandbox tokens for callers outside the per-class allowed
        // set, but the returned container path can still be valid. Try
        // opening it before giving up on an activation failure.
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            if (!activated) {
                if (error) *error = detail ?: @"MCM activation failed";
                [lease invalidate];
                return nil;
            }
            if (error) *error = [NSString stringWithFormat:
                @"container root open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
        if (!activated)
            FFLogTag(@"MCM", @"activation token-less but path opens class=%llu id=%@ root=%@",
                     containerClass, identifier, lease.rootPath);
        _leases[MCMKey(containerClass, identifier)] = lease;
        return lease.rootPath;
    }
}

- (NSString *)activateScoped:(uint64_t)containerClass
                  identifier:(NSString *)identifier
                       group:(BOOL)group
                        part:(uint64_t)part
                  partDomain:(NSString *)partDomain
                       flags:(uint64_t)flags
                       error:(NSString **)error
{
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:kRequiredIdentifier]) {
        if (error) *error = @"host bundle identifier is not the required MCM caller identity";
        return nil;
    }
    if (!MCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    NSString *key = [NSString stringWithFormat:@"%llu:%@:%llu:%@:%llx",
        containerClass, identifier, part, partDomain ?: @"", flags];
    @synchronized (_leases) {
        MCMLease *existing = _leases[key];
        if (existing && existing.rootPath.length) return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass
            identifier:identifier group:group part:part partDomain:partDomain
            flags:flags error:&detail];
        BOOL activated = lease && [lease activate:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"scoped MCM activation failed";
            return nil;
        }
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (descriptor < 0) {
            if (!activated) {
                if (error) *error = detail ?: @"scoped MCM activation failed";
                [lease invalidate];
                return nil;
            }
            if (error) *error = [NSString stringWithFormat:
                @"scoped directory open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
        if (!activated)
            FFLogTag(@"MCM", @"scoped activation token-less but path opens class=%llu id=%@ part=%llu root=%@",
                     containerClass, identifier, part, lease.rootPath);
        _leases[key] = lease;
        return lease.rootPath;
    }
}

- (NSString *)dataContainerPathForIdentifier:(NSString *)identifier
                                        error:(NSString **)error
{
    return [self activate:2 identifier:identifier group:NO error:error];
}

#pragma mark - Virtual root link installation

- (void)recordLink:(NSString *)directory identifier:(NSString *)identifier target:(NSString *)target
{
    NSMutableDictionary<NSString *, NSString *> *map = _links[directory];
    if (!map) {
        map = [NSMutableDictionary dictionary];
        _links[directory] = map;
    }
    map[identifier] = target;
}

static NSString *MCMNormalizedPath(NSString *path)
{
    NSString *result = path.stringByStandardizingPath;
    if ([result isEqualToString:@"/var"] || [result hasPrefix:@"/var/"])
        result = [@"/private" stringByAppendingString:result];
    return result;
}

- (BOOL)hasActiveLeaseForPath:(NSString *)path
{
    if (!path.length || !path.isAbsolutePath) return NO;
    NSString *candidate = MCMNormalizedPath(path);
    @synchronized (_leases) {
        for (MCMLease *lease in _leases.allValues)
            if (lease.rootPath.length &&
                ([candidate isEqualToString:lease.rootPath] ||
                 [candidate hasPrefix:[lease.rootPath stringByAppendingString:@"/"]]))
                return YES;
    }
    return NO;
}

- (void)installLink:(NSString *)directory identifier:(NSString *)identifier
    containerClass:(uint64_t)containerClass group:(BOOL)group
{
    [self installLink:directory identifier:identifier containerClass:containerClass
                group:group logFailure:YES];
}

- (void)installLink:(NSString *)directory identifier:(NSString *)identifier
    containerClass:(uint64_t)containerClass group:(BOOL)group logFailure:(BOOL)logFailure
{
    NSString *error = nil;
    NSString *target = [self activate:containerClass identifier:identifier
                                group:group error:&error];
    if (!target) {
        if (logFailure)
            FFLogTag(@"MCM", @"activation FAIL class=%llu id=%@ group=%d error=%@",
                     containerClass, identifier, group, error ?: @"(nil)");
        return;
    }
    [self installLinkForTarget:target directory:directory identifier:identifier
        containerClass:containerClass];
}

// Class-2 lookup with a flags matrix fallback: when the canonical
// query (0x900000000, part 0) is denied for an identifier, retry the
// other flags combinations containermanagerd has accepted on this OS.
- (NSString *)activateClass2WithMatrix:(NSString *)identifier error:(NSString **)error
{
    NSString *detail = nil;
    NSString *path = [self activate:2 identifier:identifier group:NO error:&detail];
    if (path.length) return path;

    static NSArray<NSNumber *> *flags;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        flags = @[@(0x800000000ULL), @(0x8100000000ULL), @(0x080000000ULL)];
    });
    for (NSNumber *flag in flags) {
        MCMLease *lease = [MCMLease leaseForClass:2 identifier:identifier group:NO
            part:0 flags:flag.unsignedLongLongValue error:&detail];
        if (!lease) continue;
        [lease activate:&detail];
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor >= 0) {
            close(descriptor);
            @synchronized (_leases) {
                _leases[MCMKey(2, identifier)] = lease;
            }
            FFLogTag(@"MCM", @"class-2 matrix hit id=%@ flags=0x%llx root=%@",
                     identifier, flag.unsignedLongLongValue, lease.rootPath);
            return lease.rootPath;
        }
        [lease invalidate];
    }
    if (error) *error = detail ?: @"class-2 lookup denied (matrix exhausted)";
    return nil;
}

- (BOOL)installLinkClass2Matrix:(NSString *)directory identifier:(NSString *)identifier
{
    NSString *error = nil;
    NSString *target = [self activateClass2WithMatrix:identifier error:&error];
    if (!target.length) {
        FFLogTag(@"MCM", @"class-2 matrix FAIL id=%@ error=%@", identifier, error ?: @"(nil)");
        return NO;
    }
    [self installLinkForTarget:target directory:directory identifier:identifier
        containerClass:2];
    return YES;
}

- (void)installLinkForTarget:(NSString *)target directory:(NSString *)directory
                  identifier:(NSString *)identifier containerClass:(uint64_t)containerClass
{
    NSString *link = [directory stringByAppendingPathComponent:identifier];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) return;
        char current[PATH_MAX] = {0};
        ssize_t count = readlink(link.fileSystemRepresentation, current, sizeof(current) - 1);
        if (count > 0 && [[NSString stringWithUTF8String:current] isEqualToString:target]) {
            [self recordLink:directory identifier:identifier target:target];
            return;
        }
        unlink(link.fileSystemRepresentation);
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
        FFLogTag(@"MCM", @"symlink FAIL id=%@ errno=%d", identifier, errno);
        return;
    }
    [self recordLink:directory identifier:identifier target:target];
    FFLogTag(@"MCM", @"link OK class=%llu id=%@ target=%@", containerClass, identifier, target);
}

#pragma mark - Identifier discovery

static NSArray<NSString *> *MCMDynamicIdentifiers(uint64_t containerClass)
{
    NSString *error = nil;
    NSArray *identifiers = MCMEnumerateIdentifiersForClass(containerClass, 1024, &error);
    FFLogTag(@"MCM", @"discovery class=%llu count=%lu detail=%@", containerClass,
             (unsigned long)identifiers.count, error ?: @"(nil)");
    NSMutableArray *safe = [NSMutableArray arrayWithCapacity:identifiers.count];
    for (NSString *identifier in identifiers)
        if (MCMSafeIdentifier(identifier)) [safe addObject:identifier];
    return safe;
}

static NSArray<NSString *> *MCMInstalledApplicationIdentifiers(void)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)]
        ? [workspaceClass defaultWorkspace] : nil;
    NSArray *applications = [workspace respondsToSelector:@selector(allApplications)]
        ? [workspace allApplications] : @[];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (id proxy in applications) {
        NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
            ? [proxy applicationIdentifier] : nil;
        if (!MCMSafeIdentifier(identifier) &&
            [proxy respondsToSelector:@selector(bundleIdentifier)])
            identifier = [proxy bundleIdentifier];
        if (MCMSafeIdentifier(identifier)) [result addObject:identifier];
        if (result.count >= 1024) break;
    }
    return result.array;
}

static NSArray<NSString *> *MCMResearchTargetIdentifiers(void)
{
    // Enumeration returns near-empty results on iOS 26 even though direct
    // lookups succeed. Seed known first-party identifiers so the MHA bypass
    // can resolve them by name when discovery is denied or incomplete.
    return @[
        @"com.apple.mobilesafari",
        @"com.apple.mobilenotes",
        @"com.apple.Maps",
        @"com.apple.facetime",
        @"com.apple.iBooks",
        @"com.apple.podcasts",
        @"com.apple.PosterBoard",
        @"com.apple.mobilemail",
        @"com.apple.weather",
        @"com.apple.camera",
        @"com.apple.Health",
        @"com.apple.Fitness",
        @"com.apple.tips",
        @"com.apple.Passbook",
        @"com.apple.reminders",
        @"com.apple.stocks",
        @"com.apple.news",
        @"com.apple.Home",
        @"com.apple.tv",
        @"com.apple.shortcuts",
        @"com.apple.freeform",
        @"com.apple.calculator",
        @"com.apple.MobileSMS",
        @"com.apple.InCallService",
        @"com.apple.Preferences",
        @"com.apple.springboard",
        @"com.apple.Photos",
        @"com.apple.AppStore",
        @"com.apple.Music",
        @"com.apple.Bridge",
        @"com.apple.Clock",
        @"com.apple.VoiceMemos",
        @"com.apple.Translate",
        @"com.apple.measure",
        @"com.apple.compass",
        @"com.apple.Magnifier",
        @"com.apple.DocumentsApp",
    ];
}

static NSDictionary *MCMCustomIdentifiers(void)
{
    NSString *documentsPath = [MCMVirtualRoot().stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"MCMIdentifiers.plist"];
    NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"MCMIdentifiers"
                                                         ofType:@"plist"];
    NSArray<NSString *> *keys = @[ @"AppData" ];
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (NSString *key in keys)
        merged[key] = [NSMutableOrderedSet orderedSet];
    for (NSString *path in @[bundlePath ?: @"", documentsPath]) {
        NSDictionary *value = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![value isKindOfClass:NSDictionary.class]) continue;
        for (NSString *key in merged) {
            NSArray *identifiers = [value[key] isKindOfClass:NSArray.class] ? value[key] : @[];
            for (id identifier in identifiers)
                if ([identifier isKindOfClass:NSString.class] && MCMSafeIdentifier(identifier))
                    [merged[key] addObject:identifier];
        }
    }
    for (NSString *key in keys)
        merged[key] = [merged[key] array];
    return merged;
}

#pragma mark - Startup

- (void)writeAccessMap:(NSString *)root
{
    NSMutableString *map = [NSMutableString stringWithFormat:
        @"FuckFile access map\n"
        "MHA-MCM: MobileHouseArrest identity-trust bypass in MobileContainerManager.\n"
        "Device: %@\n"
        "The map records enabled roots only. It does not enumerate container contents.\n"
        "Boundary: no root, no /var/mobile, no Keychain, no TCC, no app-bundle access.\n\n",
        NSProcessInfo.processInfo.operatingSystemVersionString];
    for (NSString *category in _links) {
        [map appendFormat:@"%@\n", category];
        NSDictionary<NSString *, NSString *> *links = _links[category];
        if (links.count == 0) {
            [map appendString:@"  Enabled roots: none.\n\n"];
            continue;
        }
        for (NSString *name in links)
            [map appendFormat:@"  %@\n    root: %@\n", name, links[name]];
        [map appendString:@"\n"];
    }
    [map writeToFile:[root stringByAppendingPathComponent:@"ACCESS MAP.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)start
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self startOnce];
    });
}

#pragma mark - App Data scan progress

// Cleans up virtual-root directories from earlier releases that are no
// longer in scope (App Groups, Service Data, …) so the browser only
// ever sees the App Data folder.
- (void)removeLegacyDirectoriesUnder:(NSString *)root
{
    // Remove every [MHA-*] folder from earlier releases and any stray
    // app symlinks left flat in the root by the intermediate build that
    // linked without the App Data folder.
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in names ?: @[]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if ([manager fileExistsAtPath:path isDirectory:&isDirectory]) {
            if (isDirectory && [name hasPrefix:@"[MHA-"]) {
                [manager removeItemAtPath:path error:nil];
                continue;
            }
            // Flat symlinks from the pre-folder build point into the
            // real container tree; drop them so the root only shows the
            // App Data folder and the log file.
            if (!isDirectory) {
                struct stat status = {0};
                if (lstat(path.fileSystemRepresentation, &status) == 0 && S_ISLNK(status.st_mode)) {
                    char target[PATH_MAX] = {0};
                    ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
                    if (length > 0) {
                        target[length] = '\0';
                        NSString *targetPath = [NSString stringWithUTF8String:target];
                        if ([targetPath hasPrefix:@"/private/var/"] ||
                            [targetPath hasPrefix:@"/var/"])
                            [manager removeItemAtPath:path error:nil];
                    }
                }
            }
        }
    }
}

// Publishes App Data scan progress so the home screen can show the
// current state instead of a silent gap during the LS confirmation.
- (void)postScanProgress:(double)progress linked:(NSUInteger)linked
                   total:(NSUInteger)total scanning:(BOOL)scanning
{
    NSDictionary *userInfo = @{
        @"Progress": @(progress),
        @"Linked": @(linked),
        @"Total": @(total),
        @"Scanning": @(scanning),
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFMCMAppLinksUpdatedNotification
                          object:self userInfo:userInfo];
    });
}

- (void)rescan
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self startOnce];
    });
}

- (void)startOnce
{
    NSString *actual = NSBundle.mainBundle.bundleIdentifier;
    if (![actual isEqualToString:kRequiredIdentifier]) {
        FFLogTag(@"MCM", @"DISABLED bundle identifier '%@' != required '%@'",
            actual, kRequiredIdentifier);
        _started = YES;
        return;
    }
    if (!MCMBridgeAvailable()) {
        FFLogTag(@"MCM", @"DISABLED ContainerManager symbols unavailable");
        _started = YES;
        return;
    }
    FFLogTag(@"MCM", @"start root=%@ bridge=OK", MCMVirtualRoot());
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = MCMVirtualRoot();
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];

    // Scope: App Data only. Links live in an "App Data" folder next to
    // the log file inside our own container root. All other container
    // classes are intentionally not probed anymore.
    NSString *apps = [root stringByAppendingPathComponent:@"App Data"];
    [fm createDirectoryAtPath:apps withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    [self removeLegacyDirectoriesUnder:root];

    NSMutableOrderedSet *appIdentifiers =
        [NSMutableOrderedSet orderedSetWithArray:MCMDynamicIdentifiers(2)];
    [appIdentifiers addObjectsFromArray:MCMInstalledApplicationIdentifiers()];
    [appIdentifiers addObjectsFromArray:MCMResearchTargetIdentifiers()];
    NSDictionary *custom = MCMCustomIdentifiers();
    for (id value in [custom[@"AppData"] isKindOfClass:NSArray.class] ? custom[@"AppData"] : @[])
        if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
            [appIdentifiers addObject:value];
    NSUInteger seeded = appIdentifiers.count;
    NSUInteger linkedSeeded = 0;
    for (NSString *identifier in appIdentifiers)
        if ([self installLinkClass2Matrix:apps identifier:identifier])
            linkedSeeded++;
    FFLogTag(@"MCM", @"seeded app identifiers=%lu linked=%lu",
             (unsigned long)seeded, (unsigned long)linkedSeeded);
    [self postScanProgress:1.0 linked:linkedSeeded total:seeded scanning:NO];

    // iOS 26 hides third-party apps from ContainerManager/LaunchServices
    // enumeration, but the LaunchServices store inside com.apple.lsd still
    // lists every installed identifier. Confirm each candidate with a
    // class-2 lookup on a background queue, reporting progress so the UI
    // can show the scan state.
    NSString *lsdError = nil;
    NSString *lsdContainer = [self activate:10 identifier:@"com.apple.lsd"
        group:NO error:&lsdError];
    if (!lsdContainer.length) {
        FFLogTag(@"MCM", @"LaunchServices store container unavailable detail=%@",
                 lsdError ?: @"(nil)");
    } else {
        NSArray<NSString *> *candidates =
            FFLSDiscoverInstalledIdentifiers(lsdContainer, 65536);
        NSUInteger total = candidates.count;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSUInteger confirmed = 0;
            NSUInteger index = 0;
            for (NSString *identifier in candidates) {
                index++;
                BOOL known = NO;
                @synchronized (appIdentifiers) {
                    known = [appIdentifiers containsObject:identifier];
                }
                if (!known &&
                    [self activate:2 identifier:identifier group:NO error:nil]) {
                    @synchronized (appIdentifiers) {
                        [appIdentifiers addObject:identifier];
                    }
                    confirmed++;
                }
                if (!known)
                    [self installLink:apps identifier:identifier containerClass:2
                                group:NO logFailure:NO];
                if (index % 50 == 0 || index == total)
                    [self postScanProgress:total > 0 ? (double)index / (double)total : 1.0
                                    linked:confirmed total:total scanning:index < total];
            }
            FFLogTag(@"MCM", @"LaunchServices candidates=%lu newly-linked=%lu",
                     (unsigned long)total, (unsigned long)confirmed);
            [self postScanProgress:1.0 linked:confirmed total:total scanning:NO];
        });
    }

    [self writeAccessMap:root];
    _started = YES;
    FFLogTag(@"MCM", @"ready root=%@ active_leases=%lu", root, (unsigned long)_leases.count);
}

@end
