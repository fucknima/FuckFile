#import "FFOnlineAppNameResolver.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataScanCoordinator.h"
#import "FFSystemAccessManager.h"
#import "FFLogger.h"

#import <UIKit/UIKit.h>

NSString *const FFOnlineAppNameResolutionEnabledKey =
    @"FFOnlineAppNameResolutionEnabledV1";
NSNotificationName const FFOnlineAppNameResolutionPreferenceDidChangeNotification =
    @"FFOnlineAppNameResolutionPreferenceDidChangeNotification";
NSNotificationName const FFOnlineAppNameResolutionStateDidChangeNotification =
    @"FFOnlineAppNameResolutionStateDidChangeNotification";
NSNotificationName const FFOnlineAppNameResolutionNamesDidChangeNotification =
    @"FFOnlineAppNameResolutionNamesDidChangeNotification";

static NSString *const kFFOnlineAppNameCacheKey = @"FFOnlineAppNameCacheV1";
static NSString *const kFFOnlineAppNameCacheName = @"Name";
static NSString *const kFFOnlineAppNameCacheCountry = @"Country";
static NSString *const kFFOnlineAppNameCacheFetchedAt = @"FetchedAt";
static NSString *const kFFOnlineAppNameCacheMissing = @"Missing";

static const NSTimeInterval kFFOnlineAppNamePositiveTTL = 30.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval kFFOnlineAppNameNegativeTTL = 24.0 * 60.0 * 60.0;
// Apple's public iTunes Search API documents an approximate 20 calls/minute
// limit. 3.2 seconds keeps FuckFile below that ceiling (~18.75/minute), even
// when a Bundle ID has to fall through several storefronts.
static const NSTimeInterval kFFOnlineAppNameRequestSpacing = 3.2;
static const NSTimeInterval kFFOnlineAppNameRateLimitRetry = 60.0;
static const NSTimeInterval kFFOnlineAppNameRetryBase = 30.0;
static const NSTimeInterval kFFOnlineAppNameRetryMax = 300.0;

typedef NS_ENUM(NSInteger, FFOnlineLookupOutcome) {
    FFOnlineLookupOutcomeMatch = 0,
    FFOnlineLookupOutcomeDefinitiveMiss,
    FFOnlineLookupOutcomeTransientFailure,
    FFOnlineLookupOutcomeRateLimited,
};

BOOL FFOnlineAppNameResolutionEnabled(void)
{
    id stored = [NSUserDefaults.standardUserDefaults
        objectForKey:FFOnlineAppNameResolutionEnabledKey];
    return stored == nil ? YES : [stored boolValue];
}

void FFSetOnlineAppNameResolutionEnabled(BOOL enabled)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL previous = FFOnlineAppNameResolutionEnabled();
    [defaults setBool:enabled forKey:FFOnlineAppNameResolutionEnabledKey];
    if (previous != enabled) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFOnlineAppNameResolutionPreferenceDidChangeNotification
                          object:nil userInfo:@{ @"Enabled": @(enabled) }];
    }
}

static BOOL FFOnlineAppNameIsAppleIdentifier(NSString *identifier)
{
    NSString *lower = identifier.lowercaseString;
    return [lower isEqualToString:@"com.apple"] || [lower hasPrefix:@"com.apple."];
}

static BOOL FFOnlineAppNameIsLocalResolved(NSString *identifier, NSString *localName)
{
    return localName.length > 0 && ![localName isEqualToString:identifier];
}

@interface FFOnlineAppNameResolver ()
@end

@implementation FFOnlineAppNameResolver {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSMutableDictionary<NSString *, NSDictionary *> *_cache;

    NSArray<NSString *> *_activeIdentifiers;
    NSUInteger _activeIndex;
    NSURLSessionDataTask *_activeTask;
    NSUInteger _requestGeneration;
    BOOL _running;
    BOOL _rerunRequested;
    BOOL _reevaluateScheduled;

    NSUInteger _workUserTotal;
    NSUInteger _workNamedCount;
    NSUInteger _workPassTotal;
    NSUInteger _workPassCompleted;
    NSUInteger _workPassResolved;

    NSUInteger _retryAttempt;
    NSUInteger _retryGeneration;
    NSTimeInterval _retryAfterInternal;

    FFOnlineAppNameResolutionState _snapshotState;
    NSUInteger _snapshotUserAppTotal;
    NSUInteger _snapshotNamedAppCount;
    NSUInteger _snapshotPassCompleted;
    NSUInteger _snapshotPassTotal;
    NSUInteger _snapshotPassResolved;
    NSTimeInterval _snapshotRetryAfter;
}

+ (instancetype)sharedResolver
{
    static FFOnlineAppNameResolver *resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ resolver = [FFOnlineAppNameResolver new]; });
    return resolver;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("ff.appdata.online-names", DISPATCH_QUEUE_SERIAL);
        _cache = [NSMutableDictionary dictionary];
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults
            dictionaryForKey:kFFOnlineAppNameCacheKey];
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSDictionary.class])
                self->_cache[key] = value;
        }];

        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 15.0;
        configuration.HTTPAdditionalHeaders = @{
            @"Accept": @"application/json",
            @"User-Agent": @"FuckFile/AppDataNameResolver"
        };
        _session = [NSURLSession sessionWithConfiguration:configuration];

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(dependencyChanged:)
            name:FFOnlineAppNameResolutionPreferenceDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(dependencyChanged:)
            name:FFSystemAccessPreferenceDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(dependencyChanged:)
            name:FFAppDataScanStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(dependencyChanged:)
            name:FFAppDataRegistryDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(dependencyChanged:)
            name:UIApplicationDidBecomeActiveNotification object:nil];

        _snapshotState = FFOnlineAppNameResolutionStateDisabled;
        [self reevaluate];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_activeTask cancel];
    [_session invalidateAndCancel];
}

#pragma mark - Public snapshots

- (FFOnlineAppNameResolutionState)state
{
    @synchronized (self) { return _snapshotState; }
}

- (NSUInteger)userAppTotal
{
    @synchronized (self) { return _snapshotUserAppTotal; }
}

- (NSUInteger)namedAppCount
{
    @synchronized (self) { return _snapshotNamedAppCount; }
}

- (NSUInteger)passCompleted
{
    @synchronized (self) { return _snapshotPassCompleted; }
}

- (NSUInteger)passTotal
{
    @synchronized (self) { return _snapshotPassTotal; }
}

- (NSUInteger)passResolved
{
    @synchronized (self) { return _snapshotPassResolved; }
}

- (NSTimeInterval)retryAfter
{
    @synchronized (self) { return _snapshotRetryAfter; }
}

- (double)progress
{
    @synchronized (self) {
        if (_snapshotPassTotal == 0)
            return _snapshotState == FFOnlineAppNameResolutionStateIdle ? 1.0 : 0.0;
        return MIN(1.0, (double)_snapshotPassCompleted / (double)_snapshotPassTotal);
    }
}

- (void)publishState:(FFOnlineAppNameResolutionState)state
{
    BOOL changed = NO;
    NSDictionary *info = nil;
    @synchronized (self) {
        changed = _snapshotState != state ||
            _snapshotUserAppTotal != _workUserTotal ||
            _snapshotNamedAppCount != _workNamedCount ||
            _snapshotPassCompleted != _workPassCompleted ||
            _snapshotPassTotal != _workPassTotal ||
            _snapshotPassResolved != _workPassResolved ||
            _snapshotRetryAfter != _retryAfterInternal;
        _snapshotState = state;
        _snapshotUserAppTotal = _workUserTotal;
        _snapshotNamedAppCount = _workNamedCount;
        _snapshotPassCompleted = _workPassCompleted;
        _snapshotPassTotal = _workPassTotal;
        _snapshotPassResolved = _workPassResolved;
        _snapshotRetryAfter = _retryAfterInternal;
        if (changed) {
            info = @{
                @"State": @(state),
                @"UserAppTotal": @(_workUserTotal),
                @"NamedAppCount": @(_workNamedCount),
                @"Completed": @(_workPassCompleted),
                @"Total": @(_workPassTotal),
                @"Resolved": @(_workPassResolved),
                @"RetryAfter": @(_retryAfterInternal),
            };
        }
    }
    if (!changed) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFOnlineAppNameResolutionStateDidChangeNotification
                          object:self userInfo:info];
    });
}

#pragma mark - Cache overlay

- (NSDictionary *)cacheEntryForIdentifier:(NSString *)identifier
{
    if (!identifier.length) return nil;
    @synchronized (self) {
        NSDictionary *entry = _cache[identifier];
        return [entry isKindOfClass:NSDictionary.class] ? [entry copy] : nil;
    }
}

- (NSString *)cachedOnlineNameForIdentifier:(NSString *)identifier
{
    NSDictionary *entry = [self cacheEntryForIdentifier:identifier];
    if ([entry[kFFOnlineAppNameCacheMissing] boolValue]) return nil;
    NSString *name = [entry[kFFOnlineAppNameCacheName] isKindOfClass:NSString.class]
        ? entry[kFFOnlineAppNameCacheName] : nil;
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length ? name : nil;
}

- (NSString *)displayNameForIdentifier:(NSString *)identifier localName:(NSString *)localName
{
    if (!identifier.length) return localName.length ? localName : @"";
    NSString *cleanLocal = [localName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (FFOnlineAppNameIsLocalResolved(identifier, cleanLocal)) return cleanLocal;
    NSString *online = [self cachedOnlineNameForIdentifier:identifier];
    if (online.length) return online;
    return cleanLocal.length ? cleanLocal : identifier;
}

- (BOOL)cacheEntryNeedsQueryForIdentifier:(NSString *)identifier
{
    NSDictionary *entry = [self cacheEntryForIdentifier:identifier];
    if (!entry) return YES;
    NSNumber *fetchedAt = [entry[kFFOnlineAppNameCacheFetchedAt]
        isKindOfClass:NSNumber.class] ? entry[kFFOnlineAppNameCacheFetchedAt] : nil;
    if (!fetchedAt) return YES;
    BOOL missing = [entry[kFFOnlineAppNameCacheMissing] boolValue];
    NSTimeInterval ttl = missing ? kFFOnlineAppNameNegativeTTL : kFFOnlineAppNamePositiveTTL;
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - fetchedAt.doubleValue;
    return !(age >= 0.0 && age <= ttl);
}

- (void)persistCache
{
    NSDictionary *snapshot = nil;
    @synchronized (self) { snapshot = _cache.copy; }
    [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kFFOnlineAppNameCacheKey];
}

- (BOOL)cacheName:(NSString *)name identifier:(NSString *)identifier country:(NSString *)country
{
    if (!identifier.length || !name.length) return NO;
    NSString *oldName = [self cachedOnlineNameForIdentifier:identifier];
    NSDictionary *entry = @{
        kFFOnlineAppNameCacheName: name,
        kFFOnlineAppNameCacheCountry: country ?: @"",
        kFFOnlineAppNameCacheFetchedAt: @(NSDate.date.timeIntervalSince1970),
        kFFOnlineAppNameCacheMissing: @NO,
    };
    @synchronized (self) { _cache[identifier] = entry; }
    [self persistCache];
    BOOL changed = ![oldName isEqualToString:name];
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:FFOnlineAppNameResolutionNamesDidChangeNotification
                              object:self userInfo:@{ @"Identifier": identifier }];
        });
    }
    return changed;
}

- (void)cacheMissingIdentifier:(NSString *)identifier
{
    if (!identifier.length) return;
    NSDictionary *entry = @{
        kFFOnlineAppNameCacheFetchedAt: @(NSDate.date.timeIntervalSince1970),
        kFFOnlineAppNameCacheMissing: @YES,
    };
    @synchronized (self) { _cache[identifier] = entry; }
    [self persistCache];
}

- (void)touchExistingPositiveIdentifier:(NSString *)identifier
{
    NSDictionary *old = [self cacheEntryForIdentifier:identifier];
    NSString *name = [old[kFFOnlineAppNameCacheName] isKindOfClass:NSString.class]
        ? old[kFFOnlineAppNameCacheName] : nil;
    if (!name.length || [old[kFFOnlineAppNameCacheMissing] boolValue]) return;
    NSMutableDictionary *updated = old.mutableCopy;
    updated[kFFOnlineAppNameCacheFetchedAt] = @(NSDate.date.timeIntervalSince1970);
    @synchronized (self) { _cache[identifier] = updated.copy; }
    [self persistCache];
}

#pragma mark - Lifecycle

- (void)dependencyChanged:(NSNotification *)note
{
    (void)note;
    [self reevaluate];
}

- (void)reevaluate
{
    dispatch_async(_queue, ^{
        if (self->_reevaluateScheduled) return;
        self->_reevaluateScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
            self->_queue, ^{
                self->_reevaluateScheduled = NO;
                [self reevaluateLocked];
            });
    });
}

- (void)cancelPendingResolution
{
    dispatch_async(_queue, ^{
        [self stopActiveWorkClearingRetry:YES];
        [self refreshInventoryMetricsResetPass:YES];
        [self publishState:FFOnlineAppNameResolutionStateIdle];
    });
}

- (void)reevaluateLocked
{
    BOOL preference = FFOnlineAppNameResolutionEnabled();
    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;

    if (!preference) {
        [self stopActiveWorkClearingRetry:YES];
        [self refreshInventoryMetricsResetPass:YES];
        [self publishState:FFOnlineAppNameResolutionStateDisabled];
        return;
    }
    if (!access.enabled || !access.ready) {
        [self stopActiveWorkClearingRetry:YES];
        [self refreshInventoryMetricsResetPass:YES];
        [self publishState:FFOnlineAppNameResolutionStateWaitingForSystemAccess];
        return;
    }
    if (scan.scanning) {
        [self stopActiveWorkClearingRetry:NO];
        [self refreshInventoryMetricsResetPass:YES];
        [self publishState:FFOnlineAppNameResolutionStateWaitingForScan];
        return;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (_retryAfterInternal > now) {
        [self publishState:FFOnlineAppNameResolutionStateWaitingForRetry];
        return;
    }
    if (_retryAfterInternal > 0.0) {
        _retryAfterInternal = 0.0;
        _retryGeneration++;
    }

    if (_running) {
        _rerunRequested = YES;
        return;
    }
    [self beginPass];
}

- (void)stopActiveWorkClearingRetry:(BOOL)clearRetry
{
    _requestGeneration++;
    [_activeTask cancel];
    _activeTask = nil;
    _activeIdentifiers = nil;
    _activeIndex = 0;
    _running = NO;
    _rerunRequested = NO;
    if (clearRetry) {
        _retryAttempt = 0;
        _retryAfterInternal = 0.0;
        _retryGeneration++;
    }
}

- (void)refreshInventoryMetricsResetPass:(BOOL)resetPass
{
    FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
    NSUInteger total = 0;
    NSUInteger named = 0;
    for (NSString *identifier in registry.identifiers) {
        if (FFOnlineAppNameIsAppleIdentifier(identifier)) continue;
        total++;
        NSString *local = [registry displayNameForIdentifier:identifier];
        if (FFOnlineAppNameIsLocalResolved(identifier, local) ||
            [self cachedOnlineNameForIdentifier:identifier].length)
            named++;
    }
    _workUserTotal = total;
    _workNamedCount = named;
    if (resetPass) {
        _workPassTotal = 0;
        _workPassCompleted = 0;
        _workPassResolved = 0;
    }
}

- (void)beginPass
{
    FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
    NSMutableArray<NSString *> *work = [NSMutableArray array];
    NSUInteger total = 0;
    NSUInteger named = 0;

    for (NSString *identifier in registry.identifiers) {
        if (FFOnlineAppNameIsAppleIdentifier(identifier)) continue;
        total++;
        NSString *local = [registry displayNameForIdentifier:identifier];
        if (FFOnlineAppNameIsLocalResolved(identifier, local)) {
            named++;
            continue;
        }
        if ([self cachedOnlineNameForIdentifier:identifier].length) named++;
        if ([self cacheEntryNeedsQueryForIdentifier:identifier]) [work addObject:identifier];
    }

    _workUserTotal = total;
    _workNamedCount = named;
    _workPassTotal = work.count;
    _workPassCompleted = 0;
    _workPassResolved = 0;
    _activeIdentifiers = work.copy;
    _activeIndex = 0;
    _running = work.count > 0;
    _rerunRequested = NO;

    FFLogTag(@"AppNameOnline", @"lifecycle pass user=%lu named=%lu query=%lu",
        (unsigned long)total, (unsigned long)named, (unsigned long)work.count);

    if (work.count == 0) {
        _retryAttempt = 0;
        _retryAfterInternal = 0.0;
        [self publishState:FFOnlineAppNameResolutionStateIdle];
        return;
    }
    [self publishState:FFOnlineAppNameResolutionStateResolving];
    [self processNextIdentifier];
}

- (void)processNextIdentifier
{
    if (!_running) return;
    if (!FFOnlineAppNameResolutionEnabled() ||
        !FFSystemAccessManager.sharedManager.enabled ||
        !FFSystemAccessManager.sharedManager.ready ||
        FFAppDataScanCoordinator.sharedCoordinator.scanning) {
        [self reevaluateLocked];
        return;
    }
    if (_activeIndex >= _activeIdentifiers.count) {
        [self finishPass];
        return;
    }

    NSString *identifier = _activeIdentifiers[_activeIndex++];
    BOOL alreadyNamed = [self cachedOnlineNameForIdentifier:identifier].length > 0;
    NSArray<NSString *> *countries = [self storefronts];
    [self lookupIdentifier:identifier storefronts:countries index:0
        completion:^(FFOnlineLookupOutcome outcome, NSString *name, NSString *country) {
            dispatch_async(self->_queue, ^{
                if (!self->_running) return;
                if (outcome == FFOnlineLookupOutcomeRateLimited) {
                    FFLogTag(@"AppNameOnline", @"rate limited; retry in 60s");
                    [self scheduleRetryAfter:kFFOnlineAppNameRateLimitRetry incrementAttempt:NO];
                    return;
                }
                if (outcome == FFOnlineLookupOutcomeTransientFailure) {
                    NSUInteger exponent = MIN(self->_retryAttempt, (NSUInteger)4);
                    NSTimeInterval delay = MIN(kFFOnlineAppNameRetryMax,
                        kFFOnlineAppNameRetryBase * (NSTimeInterval)(1u << exponent));
                    FFLogTag(@"AppNameOnline", @"transient failure; retry in %.0fs", delay);
                    [self scheduleRetryAfter:delay incrementAttempt:YES];
                    return;
                }

                self->_retryAttempt = 0;
                if (outcome == FFOnlineLookupOutcomeMatch && name.length) {
                    [self cacheName:name identifier:identifier country:country];
                    self->_workPassResolved++;
                    if (!alreadyNamed) self->_workNamedCount++;
                    FFLogTag(@"AppNameOnline", @"resolved id=%@ name=%@ storefront=%@",
                        identifier, name, country ?: @"?");
                } else if (outcome == FFOnlineLookupOutcomeDefinitiveMiss) {
                    if (alreadyNamed) {
                        // A previously exact match remains useful after delisting or
                        // storefront changes. Keep the known name and only refresh
                        // its validation time so the UI never regresses to Bundle ID.
                        [self touchExistingPositiveIdentifier:identifier];
                    } else {
                        [self cacheMissingIdentifier:identifier];
                    }
                    FFLogTag(@"AppNameOnline", @"no catalog match id=%@", identifier);
                }

                self->_workPassCompleted++;
                [self publishState:FFOnlineAppNameResolutionStateResolving];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(kFFOnlineAppNameRequestSpacing * NSEC_PER_SEC)),
                    self->_queue, ^{ [self processNextIdentifier]; });
            });
        }];
}

- (void)finishPass
{
    _running = NO;
    _activeTask = nil;
    _activeIdentifiers = nil;
    _activeIndex = 0;
    _retryAttempt = 0;
    _retryAfterInternal = 0.0;
    [self refreshInventoryMetricsResetPass:NO];
    _workPassCompleted = _workPassTotal;
    [self publishState:FFOnlineAppNameResolutionStateIdle];
    FFLogTag(@"AppNameOnline", @"pass complete named=%lu/%lu resolvedThisPass=%lu",
        (unsigned long)_workNamedCount, (unsigned long)_workUserTotal,
        (unsigned long)_workPassResolved);

    if (_rerunRequested) {
        _rerunRequested = NO;
        dispatch_async(_queue, ^{ [self reevaluateLocked]; });
    }
}

- (void)scheduleRetryAfter:(NSTimeInterval)delay incrementAttempt:(BOOL)incrementAttempt
{
    _requestGeneration++;
    [_activeTask cancel];
    _activeTask = nil;
    _running = NO;
    _activeIdentifiers = nil;
    _activeIndex = 0;
    if (incrementAttempt) _retryAttempt = MIN(_retryAttempt + 1, (NSUInteger)8);
    _retryAfterInternal = NSDate.date.timeIntervalSince1970 + MAX(1.0, delay);
    NSUInteger retryGeneration = ++_retryGeneration;
    [self publishState:FFOnlineAppNameResolutionStateWaitingForRetry];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(1.0, delay) * NSEC_PER_SEC)),
        _queue, ^{
            if (retryGeneration != self->_retryGeneration) return;
            self->_retryAfterInternal = 0.0;
            [self reevaluateLocked];
        });
}

#pragma mark - Storefront lookup

- (NSArray<NSString *> *)storefronts
{
    NSMutableOrderedSet<NSString *> *countries = [NSMutableOrderedSet orderedSet];
    [countries addObject:@"CN"];
    NSString *localeCountry = [NSLocale.currentLocale objectForKey:NSLocaleCountryCode];
    if ([localeCountry isKindOfClass:NSString.class] && localeCountry.length == 2)
        [countries addObject:localeCountry.uppercaseString];
    [countries addObjectsFromArray:@[@"US", @"JP", @"GB", @"NZ", @"AE"]];
    return countries.array;
}

- (void)lookupIdentifier:(NSString *)identifier
             storefronts:(NSArray<NSString *> *)storefronts
                   index:(NSUInteger)index
              completion:(void (^)(FFOnlineLookupOutcome outcome,
                                   NSString * _Nullable name,
                                   NSString * _Nullable country))completion
{
    if (!_running) return;
    if (index >= storefronts.count) {
        completion(FFOnlineLookupOutcomeDefinitiveMiss, nil, nil);
        return;
    }

    NSString *country = storefronts[index];
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = @"itunes.apple.com";
    components.path = @"/lookup";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"bundleId" value:identifier],
        [NSURLQueryItem queryItemWithName:@"entity" value:@"software"],
        [NSURLQueryItem queryItemWithName:@"country" value:country],
    ];
    NSURL *url = components.URL;
    if (!url) {
        completion(FFOnlineLookupOutcomeTransientFailure, nil, nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSUInteger requestGeneration = ++_requestGeneration;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            dispatch_async(self->_queue, ^{
                if (requestGeneration != self->_requestGeneration || !self->_running) return;
                self->_activeTask = nil;

                if (error) {
                    if (error.code != NSURLErrorCancelled) {
                        FFLogTag(@"AppNameOnline", @"lookup failed id=%@ storefront=%@ error=%@",
                            identifier, country, error.localizedDescription ?: @"unknown");
                        completion(FFOnlineLookupOutcomeTransientFailure, nil, country);
                    }
                    return;
                }

                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                    ? ((NSHTTPURLResponse *)response).statusCode : 0;
                if (status == 429) {
                    completion(FFOnlineLookupOutcomeRateLimited, nil, country);
                    return;
                }
                if (status < 200 || status >= 300 || data.length == 0) {
                    FFLogTag(@"AppNameOnline", @"lookup HTTP id=%@ storefront=%@ status=%ld",
                        identifier, country, (long)status);
                    completion(FFOnlineLookupOutcomeTransientFailure, nil, country);
                    return;
                }

                NSError *jsonError = nil;
                id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                NSDictionary *root = [object isKindOfClass:NSDictionary.class] ? object : nil;
                NSArray *results = [root[@"results"] isKindOfClass:NSArray.class]
                    ? root[@"results"] : nil;
                if (!results) {
                    FFLogTag(@"AppNameOnline", @"invalid response id=%@ storefront=%@ error=%@",
                        identifier, country, jsonError.localizedDescription ?: @"shape");
                    completion(FFOnlineLookupOutcomeTransientFailure, nil, country);
                    return;
                }

                NSString *matchedName = nil;
                for (id value in results) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *result = value;
                    NSString *returnedID = [result[@"bundleId"] isKindOfClass:NSString.class]
                        ? result[@"bundleId"] : nil;
                    if (![returnedID isEqualToString:identifier]) continue;
                    NSString *trackName = [result[@"trackName"] isKindOfClass:NSString.class]
                        ? result[@"trackName"] : nil;
                    if (!trackName.length)
                        trackName = [result[@"trackCensoredName"] isKindOfClass:NSString.class]
                            ? result[@"trackCensoredName"] : nil;
                    trackName = [trackName stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (trackName.length && ![trackName isEqualToString:identifier]) {
                        matchedName = trackName;
                        break;
                    }
                }

                if (matchedName.length) {
                    completion(FFOnlineLookupOutcomeMatch, matchedName, country);
                    return;
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(kFFOnlineAppNameRequestSpacing * NSEC_PER_SEC)),
                    self->_queue, ^{
                    if (requestGeneration != self->_requestGeneration || !self->_running) return;
                    [self lookupIdentifier:identifier storefronts:storefronts
                                     index:index + 1 completion:completion];
                });
            });
        }];
    _activeTask = task;
    [task resume];
}

@end

__attribute__((constructor)) static void FFInstallOnlineAppNameResolver(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)FFOnlineAppNameResolver.sharedResolver;
    });
}
