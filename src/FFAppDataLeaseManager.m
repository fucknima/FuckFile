#import "FFAppDataLeaseManager.h"
#import "MCMBridge.h"
#import "FFLogger.h"

#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const FFAppDataLeaseErrorDomain = @"FFAppDataLeaseErrorDomain";
static NSString *const kRequiredIdentifier = @"com.apple.mobile.MobileHouseArrest";

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
        // One global budget shared by background discovery, search prewarm and
        // user-driven opens. This prevents concurrent features from accidentally
        // hammering containermanagerd with 8-12 simultaneous lookups.
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
    // MCMBridge formats lookup failures as "lookup denied posix=N ...".
    // ENOENT is the one failure we can safely use as evidence that the class-2
    // container itself no longer exists; permission/token failures must never
    // evict a persistent registry entry.
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

    // Do not let an already-running acquisition repopulate the cache after the
    // uninstall path has decided to evict this identifier.
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

        // A real container object existed. Any later activation/open failure is
        // transient/access-related, not proof of uninstall.
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
