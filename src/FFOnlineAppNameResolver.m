#import "FFOnlineAppNameResolver.h"
#import "FFAppDataRegistry.h"
#import "FFLogger.h"

NSString *const FFOnlineAppNameResolutionEnabledKey =
    @"FFOnlineAppNameResolutionEnabledV1";
NSNotificationName const FFOnlineAppNameResolutionPreferenceDidChangeNotification =
    @"FFOnlineAppNameResolutionPreferenceDidChangeNotification";

static NSString *const kFFOnlineAppNameCacheKey = @"FFOnlineAppNameCacheV1";
static NSString *const kFFOnlineAppNameCacheName = @"Name";
static NSString *const kFFOnlineAppNameCacheCountry = @"Country";
static NSString *const kFFOnlineAppNameCacheFetchedAt = @"FetchedAt";
static NSString *const kFFOnlineAppNameCacheMissing = @"Missing";

static const NSTimeInterval kFFOnlineAppNamePositiveTTL = 30.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval kFFOnlineAppNameNegativeTTL = 24.0 * 60.0 * 60.0;
static const NSTimeInterval kFFOnlineAppNameRequestSpacing = 0.75;
static const NSUInteger kFFOnlineAppNameApplyBatchSize = 5;

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
    if (!enabled) [[FFOnlineAppNameResolver sharedResolver] cancelPendingResolution];
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

@interface FFOnlineAppNameResolver ()
@end

@implementation FFOnlineAppNameResolver {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSMutableDictionary<NSString *, NSDictionary *> *_cache;
    NSMutableDictionary<NSString *, NSString *> *_pendingResolvedNames;
    NSArray<NSString *> *_activeIdentifiers;
    FFAppDataRegistry *_activeRegistry;
    NSURLSessionDataTask *_activeTask;
    NSUInteger _activeIndex;
    BOOL _running;
    BOOL _rerunRequested;
    BOOL _cancelled;
    NSTimeInterval _backoffUntil;
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
        _pendingResolvedNames = [NSMutableDictionary dictionary];

        NSDictionary *stored = [NSUserDefaults.standardUserDefaults
            dictionaryForKey:kFFOnlineAppNameCacheKey];
        _cache = [NSMutableDictionary dictionary];
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
    }
    return self;
}

- (NSArray<NSString *> *)storefronts
{
    NSMutableOrderedSet<NSString *> *countries = [NSMutableOrderedSet orderedSet];
    // Prefer the Chinese storefront so Chinese-market apps use their familiar
    // localized product name, then widen the search for region-limited apps.
    [countries addObject:@"CN"];
    NSString *localeCountry = [NSLocale.currentLocale objectForKey:NSLocaleCountryCode];
    if ([localeCountry isKindOfClass:NSString.class] && localeCountry.length == 2)
        [countries addObject:localeCountry.uppercaseString];
    [countries addObjectsFromArray:@[@"US", @"JP", @"GB", @"NZ", @"AE"]];
    return countries.array;
}

- (NSDictionary *)freshCacheEntryForIdentifier:(NSString *)identifier
{
    NSDictionary *entry = _cache[identifier];
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *fetchedAt = [entry[kFFOnlineAppNameCacheFetchedAt]
        isKindOfClass:NSNumber.class] ? entry[kFFOnlineAppNameCacheFetchedAt] : nil;
    if (!fetchedAt) {
        [_cache removeObjectForKey:identifier];
        return nil;
    }
    BOOL missing = [entry[kFFOnlineAppNameCacheMissing] boolValue];
    NSTimeInterval ttl = missing ? kFFOnlineAppNameNegativeTTL : kFFOnlineAppNamePositiveTTL;
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - fetchedAt.doubleValue;
    if (age >= 0 && age <= ttl) return entry;
    [_cache removeObjectForKey:identifier];
    return nil;
}

- (void)persistCache
{
    [NSUserDefaults.standardUserDefaults setObject:_cache.copy forKey:kFFOnlineAppNameCacheKey];
}

- (void)cacheName:(NSString *)name identifier:(NSString *)identifier country:(NSString *)country
{
    if (!identifier.length || !name.length) return;
    _cache[identifier] = @{
        kFFOnlineAppNameCacheName: name,
        kFFOnlineAppNameCacheCountry: country ?: @"",
        kFFOnlineAppNameCacheFetchedAt: @(NSDate.date.timeIntervalSince1970),
        kFFOnlineAppNameCacheMissing: @NO,
    };
    [self persistCache];
}

- (void)cacheMissingIdentifier:(NSString *)identifier
{
    if (!identifier.length) return;
    _cache[identifier] = @{
        kFFOnlineAppNameCacheFetchedAt: @(NSDate.date.timeIntervalSince1970),
        kFFOnlineAppNameCacheMissing: @YES,
    };
    [self persistCache];
}

- (void)resolveMissingNamesInRegistry:(FFAppDataRegistry *)registry
{
    if (!registry) return;
    dispatch_async(_queue, ^{
        if (!FFOnlineAppNameResolutionEnabled()) return;
        if (NSDate.date.timeIntervalSince1970 < self->_backoffUntil) return;
        if (self->_running) {
            self->_rerunRequested = YES;
            return;
        }
        self->_running = YES;
        self->_cancelled = NO;
        self->_activeRegistry = registry;
        [self beginPass];
    });
}

- (void)cancelPendingResolution
{
    dispatch_async(_queue, ^{
        self->_cancelled = YES;
        self->_rerunRequested = NO;
        [self->_activeTask cancel];
        self->_activeTask = nil;
        [self flushResolvedNames];
        [self finishPass];
    });
}

- (void)beginPass
{
    if (_cancelled || !FFOnlineAppNameResolutionEnabled() || !_activeRegistry) {
        [self finishPass];
        return;
    }

    NSMutableArray<NSString *> *network = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *cachedNames = [NSMutableDictionary dictionary];
    for (NSString *identifier in _activeRegistry.identifiers) {
        if (FFOnlineAppNameIsAppleIdentifier(identifier)) continue;
        NSString *displayName = [_activeRegistry displayNameForIdentifier:identifier];
        BOOL fallback = displayName.length == 0 || [displayName isEqualToString:identifier];
        if (!fallback) continue;

        NSDictionary *entry = [self freshCacheEntryForIdentifier:identifier];
        if (entry) {
            if ([entry[kFFOnlineAppNameCacheMissing] boolValue]) continue;
            NSString *name = [entry[kFFOnlineAppNameCacheName] isKindOfClass:NSString.class]
                ? entry[kFFOnlineAppNameCacheName] : nil;
            if (name.length) cachedNames[identifier] = name;
            else [network addObject:identifier];
        } else {
            [network addObject:identifier];
        }
    }

    if (cachedNames.count)
        [_activeRegistry upgradeFallbackDisplayNames:cachedNames];

    _activeIdentifiers = network.copy;
    _activeIndex = 0;
    [_pendingResolvedNames removeAllObjects];
    FFLogTag(@"AppNameOnline", @"pass start unresolved=%lu cached=%lu enabled=1",
        (unsigned long)_activeIdentifiers.count, (unsigned long)cachedNames.count);

    if (_activeIdentifiers.count == 0) {
        [self finishPass];
        return;
    }
    [self processNextIdentifier];
}

- (void)processNextIdentifier
{
    if (_cancelled || !FFOnlineAppNameResolutionEnabled()) {
        [self flushResolvedNames];
        [self finishPass];
        return;
    }
    if (_activeIndex >= _activeIdentifiers.count) {
        [self flushResolvedNames];
        [self finishPass];
        return;
    }

    NSString *identifier = _activeIdentifiers[_activeIndex++];
    NSArray<NSString *> *countries = [self storefronts];
    [self lookupIdentifier:identifier storefronts:countries index:0
        completion:^(NSString *name, NSString *country, BOOL definitiveMiss, BOOL rateLimited) {
            dispatch_async(self->_queue, ^{
                if (self->_cancelled || !FFOnlineAppNameResolutionEnabled()) {
                    [self flushResolvedNames];
                    [self finishPass];
                    return;
                }
                if (rateLimited) {
                    self->_backoffUntil = NSDate.date.timeIntervalSince1970 + 60.0;
                    FFLogTag(@"AppNameOnline", @"rate limited; pause new lookups for 60s");
                    [self flushResolvedNames];
                    [self finishPass];
                    return;
                }
                if (name.length) {
                    [self cacheName:name identifier:identifier country:country];
                    self->_pendingResolvedNames[identifier] = name;
                    FFLogTag(@"AppNameOnline", @"resolved id=%@ name=%@ storefront=%@",
                        identifier, name, country ?: @"?");
                    if (self->_pendingResolvedNames.count >= kFFOnlineAppNameApplyBatchSize)
                        [self flushResolvedNames];
                } else if (definitiveMiss) {
                    [self cacheMissingIdentifier:identifier];
                    FFLogTag(@"AppNameOnline", @"no catalog match id=%@", identifier);
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(kFFOnlineAppNameRequestSpacing * NSEC_PER_SEC)),
                    self->_queue, ^{ [self processNextIdentifier]; });
            });
        }];
}

- (void)lookupIdentifier:(NSString *)identifier
             storefronts:(NSArray<NSString *> *)storefronts
                   index:(NSUInteger)index
              completion:(void (^)(NSString * _Nullable name,
                                   NSString * _Nullable country,
                                   BOOL definitiveMiss,
                                   BOOL rateLimited))completion
{
    if (_cancelled || !FFOnlineAppNameResolutionEnabled()) {
        completion(nil, nil, NO, NO);
        return;
    }
    if (index >= storefronts.count) {
        completion(nil, nil, YES, NO);
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
        completion(nil, nil, NO, NO);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            dispatch_async(self->_queue, ^{
                if (self->_activeTask == task) self->_activeTask = nil;
                if (self->_cancelled || !FFOnlineAppNameResolutionEnabled()) {
                    completion(nil, nil, NO, NO);
                    return;
                }
                if (error) {
                    if (error.code != NSURLErrorCancelled)
                        FFLogTag(@"AppNameOnline", @"lookup failed id=%@ storefront=%@ error=%@",
                            identifier, country, error.localizedDescription ?: @"unknown");
                    completion(nil, nil, NO, NO);
                    return;
                }

                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                    ? ((NSHTTPURLResponse *)response).statusCode : 0;
                if (status == 429) {
                    completion(nil, nil, NO, YES);
                    return;
                }
                if (status < 200 || status >= 300 || data.length == 0) {
                    FFLogTag(@"AppNameOnline", @"lookup HTTP id=%@ storefront=%@ status=%ld",
                        identifier, country, (long)status);
                    completion(nil, nil, NO, NO);
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
                    completion(nil, nil, NO, NO);
                    return;
                }

                NSString *matchedName = nil;
                for (id value in results) {
                    if (![value isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *result = value;
                    NSString *returnedID = [result[@"bundleId"] isKindOfClass:NSString.class]
                        ? result[@"bundleId"] : nil;
                    // Do not accept fuzzy/search matches. Exact Bundle ID equality
                    // is the trust boundary for online display-name replacement.
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
                    completion(matchedName, country, NO, NO);
                    return;
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.25 * NSEC_PER_SEC)), self->_queue, ^{
                    [self lookupIdentifier:identifier storefronts:storefronts
                                     index:index + 1 completion:completion];
                });
            });
        }];
    _activeTask = task;
    [task resume];
}

- (void)flushResolvedNames
{
    if (_pendingResolvedNames.count == 0 || !_activeRegistry) return;
    NSDictionary *batch = _pendingResolvedNames.copy;
    [_pendingResolvedNames removeAllObjects];
    NSUInteger changed = [_activeRegistry upgradeFallbackDisplayNames:batch];
    FFLogTag(@"AppNameOnline", @"applied online names=%lu candidates=%lu",
        (unsigned long)changed, (unsigned long)batch.count);
}

- (void)finishPass
{
    if (!_running) return;
    _activeTask = nil;
    _activeIdentifiers = nil;
    _activeRegistry = nil;
    _activeIndex = 0;
    _running = NO;
    BOOL rerun = _rerunRequested && !_cancelled && FFOnlineAppNameResolutionEnabled();
    _rerunRequested = NO;
    if (rerun) {
        // A registry update landed while the pass was active (for example the
        // AppData scan discovered more apps). The next browser-triggered call is
        // normally enough; this short rerun closes that race immediately.
        FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            _queue, ^{
                if (!FFOnlineAppNameResolutionEnabled()) return;
                self->_running = YES;
                self->_cancelled = NO;
                self->_activeRegistry = registry;
                [self beginPass];
            });
    }
}

@end
