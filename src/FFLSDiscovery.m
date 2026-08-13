#import "FFLSDiscovery.h"
#import "FFLogger.h"

static const NSUInteger kMaximumCandidateCount = 65536;

static BOOL FFLSIdentifierByte(uint8_t value)
{
    return (value >= 'a' && value <= 'z') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') ||
        value == '.' || value == '-' || value == '_';
}

static BOOL FFLSSafeIdentifier(NSString *identifier)
{
    if (identifier.length < 3 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier hasPrefix:@"."] && ![identifier hasSuffix:@"."] &&
        ![identifier containsString:@".."] && [identifier containsString:@"."];
}

static NSString *FFLSCachePathForMode(BOOL groupsOnly)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:
        groupsOnly ? @"LSGroupCache.plist" : @"LSIdentifierCache.plist"];
}

static NSArray<NSString *> *FFLSCachedIdentifiersForSize(unsigned long long storeSize, BOOL groupsOnly)
{
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:
        FFLSCachePathForMode(groupsOnly)];
    if (![cache[@"StoreSize"] isKindOfClass:NSNumber.class] ||
        [cache[@"StoreSize"] unsignedLongLongValue] != storeSize)
        return nil;
    NSArray *identifiers = cache[@"Identifiers"];
    if (![identifiers isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *safe = [NSMutableArray arrayWithCapacity:identifiers.count];
    for (id value in identifiers)
        if ([value isKindOfClass:NSString.class] && FFLSSafeIdentifier(value))
            [safe addObject:value];
    return safe;
}

static void FFLSWriteCache(unsigned long long storeSize, NSArray<NSString *> *identifiers,
                           BOOL groupsOnly)
{
    NSDictionary *cache = @{ @"StoreSize": @(storeSize), @"Identifiers": identifiers };
    [cache writeToFile:FFLSCachePathForMode(groupsOnly) atomically:YES];
}

static NSArray<NSString *> *FFLSDiscoverWithPrefix(NSString *lsdContainerRoot,
                                                   NSUInteger maxCandidates,
                                                   BOOL groupsOnly);

NSArray<NSString *> *FFLSDiscoverInstalledIdentifiers(NSString *lsdContainerRoot,
                                                      NSUInteger maxCandidates)
{
    return FFLSDiscoverWithPrefix(lsdContainerRoot, maxCandidates, NO);
}

NSArray<NSString *> *FFLSDiscoverGroupIdentifiers(NSString *lsdContainerRoot,
                                                  NSUInteger maxCandidates)
{
    return FFLSDiscoverWithPrefix(lsdContainerRoot, maxCandidates, YES);
}

static NSArray<NSString *> *FFLSDiscoverWithPrefix(NSString *lsdContainerRoot,
                                                   NSUInteger maxCandidates,
                                                   BOOL groupsOnly)
{
    if (!lsdContainerRoot.length || maxCandidates == 0) return @[];
    NSString *caches = [lsdContainerRoot stringByAppendingPathComponent:@"Library/Caches"];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:caches error:nil];

    // Aggregate the store size so unchanged stores reuse the cached scan.
    unsigned long long totalStoreSize = 0;
    NSMutableArray<NSString *> *storePaths = [NSMutableArray array];
    for (NSString *name in names ?: @[]) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"] ||
            ![name hasSuffix:@"-v2.csstore"])
            continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSNumber *size = [[manager attributesOfItemAtPath:path error:nil]
            objectForKey:NSFileSize];
        if (!size || size.unsignedLongLongValue == 0 ||
            size.unsignedLongLongValue > 64 * 1024 * 1024)
            continue;
        totalStoreSize += size.unsignedLongLongValue;
        [storePaths addObject:path];
    }
    if (storePaths.count == 0) {
        FFLogTag(@"LSDiscovery", @"no LaunchServices store files under %@", caches);
        return @[];
    }

    NSArray<NSString *> *cached = FFLSCachedIdentifiersForSize(totalStoreSize, groupsOnly);
    if (cached) {
        FFLogTag(@"LSDiscovery", @"store unchanged mode=%@ (%llu bytes, %lu files); reused cached candidates=%lu",
                 groupsOnly ? @"groups" : @"apps", totalStoreSize,
                 (unsigned long)storePaths.count, (unsigned long)cached.count);
        if (cached.count > maxCandidates)
            return [cached subarrayWithRange:NSMakeRange(0, maxCandidates)];
        return cached;
    }

    // Case-insensitive dedupe: bundle identifiers are case-insensitive, and
    // the store can repeat the same id in several case forms.
    NSMutableDictionary<NSString *, NSString *> *byLowercase =
        [NSMutableDictionary dictionary];
    BOOL reachedLimit = NO;
    for (NSString *storePath in storePaths) {
        NSData *data = [NSData dataWithContentsOfFile:storePath
            options:NSDataReadingMappedIfSafe error:nil];
        if (!data) {
            FFLogTag(@"LSDiscovery", @"store read failed path=%@", storePath);
            continue;
        }
        const uint8_t *bytes = data.bytes;
        NSUInteger start = NSNotFound;
        for (NSUInteger index = 0; index <= data.length; index++) {
            BOOL allowed = index < data.length && FFLSIdentifierByte(bytes[index]);
            if (allowed) {
                if (start == NSNotFound) start = index;
                continue;
            }
            if (start == NSNotFound) continue;
            NSUInteger length = index - start;
            if (length >= 3 && length <= 255) {
                NSString *candidate = [[NSString alloc]
                    initWithBytes:bytes + start length:length
                    encoding:NSUTF8StringEncoding];
                if (groupsOnly) {
                    // Keep only "group.<team>.<name>" shaped identifiers.
                    if (![candidate hasPrefix:@"group."]) {
                        start = NSNotFound;
                        continue;
                    }
                }
                if (FFLSSafeIdentifier(candidate)) {
                    NSString *key = candidate.lowercaseString;
                    if (!byLowercase[key]) byLowercase[key] = candidate;
                    if (byLowercase.count >= kMaximumCandidateCount) {
                        reachedLimit = YES;
                        break;
                    }
                }
            }
            start = NSNotFound;
        }
        FFLogTag(@"LSDiscovery", @"scanned path=%@ bytes=%lu candidates=%lu",
                 storePath, (unsigned long)data.length,
                 (unsigned long)byLowercase.count);
        if (reachedLimit) break;
    }
    if (reachedLimit)
        FFLogTag(@"LSDiscovery", @"candidate limit (%lu) reached; scan truncated",
                 (unsigned long)kMaximumCandidateCount);
    NSArray<NSString *> *result = byLowercase.allValues;
    FFLogTag(@"LSDiscovery", @"scan complete mode=%@ storeFiles=%lu bytes=%llu candidates=%lu",
             groupsOnly ? @"groups" : @"apps",
             (unsigned long)storePaths.count, totalStoreSize,
             (unsigned long)result.count);
    FFLSWriteCache(totalStoreSize, result, groupsOnly);
    if (result.count > maxCandidates)
        return [result subarrayWithRange:NSMakeRange(0, maxCandidates)];
    return result;
}

#pragma mark - Display name extraction

static BOOL FFLSNameByte(uint8_t value)
{
    // Printable UTF-8 continuation bytes plus a sane ASCII range; NUL and
    // control bytes delimit candidates.
    return value >= 0x20 && value != 0x7F && value != '/';
}

static BOOL FFLSPlausibleName(NSString *candidate)
{
    if (candidate.length < 2 || candidate.length > 64) return NO;
    // Reject strings that are actually paths or other identifiers.
    if ([candidate containsString:@".app"]) return NO;
    if ([candidate hasSuffix:@".plist"] || [candidate hasSuffix:@".bundle"]) return NO;
    if ([candidate rangeOfString:@"\\"].location != NSNotFound) return NO;
    if ([candidate rangeOfString:@".."].location != NSNotFound) return NO;
    // A pure identifier-looking dotted string is not a display name.
    if ([candidate containsString:@"."]) {
        NSCharacterSet *idChars = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
        if ([candidate stringByTrimmingCharactersInSet:idChars].length == 0) return NO;
    }
    // Names typically contain a space, a non-ASCII char, or are short
    // capitalized words; accept broadly but drop pure gibberish control.
    return YES;
}

static NSString *FFLSNameCachePath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"LSNameCache.plist"];
}

NSDictionary<NSString *, NSString *> *FFLSDiscoverAppNames(NSString *lsdContainerRoot,
                                                           NSUInteger maxEntries)
{
    if (!lsdContainerRoot.length || maxEntries == 0) return @{};
    NSString *caches = [lsdContainerRoot stringByAppendingPathComponent:@"Library/Caches"];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:caches error:nil];
    unsigned long long totalStoreSize = 0;
    NSMutableArray<NSString *> *storePaths = [NSMutableArray array];
    for (NSString *name in names ?: @[]) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"] ||
            ![name hasSuffix:@"-v2.csstore"]) continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSNumber *size = [[manager attributesOfItemAtPath:path error:nil]
            objectForKey:NSFileSize];
        if (!size || size.unsignedLongLongValue == 0 ||
            size.unsignedLongLongValue > 64 * 1024 * 1024) continue;
        totalStoreSize += size.unsignedLongLongValue;
        [storePaths addObject:path];
    }
    if (storePaths.count == 0) return @{};

    NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:FFLSNameCachePath()];
    if ([cached[@"StoreSize"] isKindOfClass:NSNumber.class] &&
        [cached[@"StoreSize"] unsignedLongLongValue] == totalStoreSize &&
        [cached[@"Names"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *cachedNames = cached[@"Names"];
        FFLogTag(@"LSDiscovery", @"name store unchanged; reused cached names=%lu",
                 (unsigned long)cachedNames.count);
        return cachedNames;
    }

    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    for (NSString *storePath in storePaths) {
        NSData *data = [NSData dataWithContentsOfFile:storePath
            options:NSDataReadingMappedIfSafe error:nil];
        if (!data) continue;
        const uint8_t *bytes = data.bytes;
        NSUInteger index = 0;
        while (index < data.length) {
            // Find an identifier-shaped run.
            NSUInteger runStart = index;
            while (index < data.length && FFLSIdentifierByte(bytes[index])) index++;
            NSUInteger runLength = index - runStart;
            if (runLength >= 3 && runLength <= 255) {
                NSString *identifier = [[NSString alloc]
                    initWithBytes:bytes + runStart length:runLength
                    encoding:NSUTF8StringEncoding];
                if (FFLSSafeIdentifier(identifier) && !result[identifier]) {
                    // Look for a name candidate within the next 256 bytes.
                    NSUInteger windowEnd = MIN(data.length, index + 256);
                    NSUInteger cursor = index;
                    NSString *foundName = nil;
                    while (cursor < windowEnd) {
                        while (cursor < windowEnd && !FFLSNameByte(bytes[cursor])) cursor++;
                        if (cursor >= windowEnd) break;
                        NSUInteger nameStart = cursor;
                        while (cursor < windowEnd && FFLSNameByte(bytes[cursor])) cursor++;
                        NSUInteger nameLength = cursor - nameStart;
                        if (nameLength >= 2 && nameLength <= 64) {
                            NSString *candidate = [[NSString alloc]
                                initWithBytes:bytes + nameStart length:nameLength
                                encoding:NSUTF8StringEncoding];
                            if (candidate && FFLSPlausibleName(candidate)) {
                                foundName = candidate;
                                break;
                            }
                        }
                    }
                    if (foundName) {
                        result[identifier] = foundName;
                        if (result.count >= maxEntries) break;
                    }
                }
            }
            while (index < data.length && FFLSIdentifierByte(bytes[index])) index++;
            if (index < data.length) index++;
        }
        if (result.count >= maxEntries) break;
    }
    NSDictionary *cacheWrite = @{
        @"StoreSize": @(totalStoreSize),
        @"Names": result,
    };
    [cacheWrite writeToFile:FFLSNameCachePath() atomically:YES];
    FFLogTag(@"LSDiscovery", @"name extraction complete entries=%lu",
             (unsigned long)result.count);
    return result;
}
