// MCMManager.m — MCM identity-bypass integration layer for FuckFile.
// Core logic ported from 0xjohnnydev/FilzaSlop MCMFilzaIntegration.m
// (https://github.com/0xjohnnydev/FilzaSlop), stripped of Filza-specific
// functionality (paste hooks, unrestricted filesystem, wallpaper lab,
// Files traversal). Identifier whitelisting and fail-closed checks kept.

#import "MCMManager.h"
#import "MCMBridge.h"

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

// Private LaunchServices API used only for installed-app discovery.
@interface NSObject (MCMLaunchServices)
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
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

NSString *MCMWallpaperLabName(void) { return @"[MHA-C2] Wallpaper Lab"; }

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
        if (!lease || !activated) {
            [lease invalidate];
            if (error) *error = detail ?: @"MCM activation failed";
            return nil;
        }
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            if (error) *error = [NSString stringWithFormat:
                @"container root open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
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
        if (existing && existing.activated) return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass
            identifier:identifier group:group part:part partDomain:partDomain
            flags:flags error:&detail];
        if (!lease || ![lease activate:&detail]) {
            [lease invalidate];
            if (error) *error = detail ?: @"scoped MCM activation failed";
            return nil;
        }
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (descriptor < 0) {
            if (error) *error = [NSString stringWithFormat:
                @"scoped directory open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
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

- (void)installLink:(NSString *)directory identifier:(NSString *)identifier
    containerClass:(uint64_t)containerClass group:(BOOL)group
{
    NSString *error = nil;
    NSString *target = [self activate:containerClass identifier:identifier
                                group:group error:&error];
    if (!target) {
        NSLog(@"[FuckFile] activation failed class=%llu id=%@ detail=%@",
              containerClass, identifier, error);
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
        NSLog(@"[FuckFile] symlink failed id=%@ errno=%d", identifier, errno);
        return;
    }
    [self recordLink:directory identifier:identifier target:target];
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
            NSLog(@"[FuckFile] direct symlink failed id=%@ target=%@ errno=%d",
                  identifier, target, errno);
        else
            [self recordLink:directory identifier:identifier target:target];
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
        NSLog(@"[FuckFile] scoped activation failed class=%llu id=%@ part=%llu domain=%@ detail=%@",
              containerClass, identifier, part, partDomain, error);
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
        NSLog(@"[FuckFile] scoped symlink failed name=%@ errno=%d", linkName, errno);
    else {
        NSLog(@"[FuckFile] scoped path ready name=%@ target=%@", linkName, target);
        [self recordLink:directory identifier:linkName target:target];
    }
}

#pragma mark - Identifier discovery

static NSArray<NSString *> *MCMDynamicIdentifiers(uint64_t containerClass)
{
    NSString *error = nil;
    NSArray *identifiers = MCMEnumerateIdentifiersForClass(containerClass, 1024, &error);
    NSLog(@"[FuckFile] discovery class=%llu count=%lu detail=%@", containerClass,
          (unsigned long)identifiers.count, error);
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
        if (MCMSafeIdentifier(identifier)) [result addObject:identifier];
        if (result.count >= 1024) break;
    }
    return result.array;
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
        NSLog(@"[FuckFile] experimental name=%@ status=failed error=%@", name, detail);
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
    NSLog(@"[FuckFile] experimental name=%@ class=%llu id=%@ part=%llu domain=%@ status=%@ target=%@",
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
        NSLog(@"[FuckFile] disabled: bundle identifier %@ must be %@", actual, kRequiredIdentifier);
        _started = YES;
        return;
    }
    if (!MCMBridgeAvailable()) {
        NSLog(@"[FuckFile] disabled: ContainerManager symbols unavailable");
        _started = YES;
        return;
    }
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
    NSDictionary *custom = MCMCustomIdentifiers();
    for (id value in [custom[@"AppData"] isKindOfClass:NSArray.class] ? custom[@"AppData"] : @[])
        if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
            [appIdentifiers addObject:value];
    for (NSString *identifier in appIdentifiers)
        [self installLink:apps identifier:identifier containerClass:2 group:NO];

    NSMutableOrderedSet *groupIdentifiers =
        [NSMutableOrderedSet orderedSetWithArray:MCMDynamicIdentifiers(7)];
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

    NSArray<NSDictionary *> *additionalCategories = @[
        @{@"Directory": vpnData, @"Class": @6, @"Group": @(NO), @"CustomKey": @"VPNData", @"Fallback": @[]},
        @{@"Directory": serviceData, @"Class": @10, @"Group": @(NO), @"CustomKey": @"ServiceData",
          @"Fallback": @[@"com.apple.swcd", @"com.apple.familycircled", @"com.apple.locationd"]},
        @{@"Directory": systemData, @"Class": @12, @"Group": @(NO), @"CustomKey": @"SystemData",
          @"Fallback": @[@"com.apple.eligibilityd", @"com.apple.geod"]},
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
    NSLog(@"[FuckFile] ready root=%@ active_leases=%lu", root, (unsigned long)_leases.count);
}

@end
