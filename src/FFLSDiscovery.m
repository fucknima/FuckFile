#import "FFLSDiscovery.h"
#import "FFLogger.h"

#import <objc/message.h>

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

static NSArray<NSString *> *FFLSStorePaths(NSString *lsdContainerRoot,
    unsigned long long *totalSizeOut, NSString **fingerprintOut)
{
    if (totalSizeOut) *totalSizeOut = 0;
    if (fingerprintOut) *fingerprintOut = nil;
    if (!lsdContainerRoot.length) return @[];

    NSString *caches = [lsdContainerRoot stringByAppendingPathComponent:@"Library/Caches"];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:caches error:nil] ?: @[]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    unsigned long long totalSize = 0;

    for (NSString *name in names) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"] ||
            ![name hasSuffix:@"-v2.csstore"])
            continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        NSNumber *size = attributes[NSFileSize];
        if (!size || size.unsignedLongLongValue == 0 ||
            size.unsignedLongLongValue > 64 * 1024 * 1024)
            continue;

        NSDate *modified = attributes[NSFileModificationDate];
        NSNumber *inode = attributes[NSFileSystemFileNumber];
        totalSize += size.unsignedLongLongValue;
        [paths addObject:path];
        [rows addObject:[NSString stringWithFormat:@"%@:%llu:%.6f:%llu",
            name, size.unsignedLongLongValue,
            modified ? modified.timeIntervalSince1970 : 0.0,
            inode ? inode.unsignedLongLongValue : 0ULL]];
    }

    if (totalSizeOut) *totalSizeOut = totalSize;
    if (fingerprintOut && rows.count)
        *fingerprintOut = [rows componentsJoinedByString:@"|"];
    return paths;
}

NSString *FFLSStoreFingerprint(NSString *lsdContainerRoot)
{
    NSString *fingerprint = nil;
    (void)FFLSStorePaths(lsdContainerRoot, NULL, &fingerprint);
    return fingerprint;
}

#pragma mark - Structured CoreServicesStore metadata

static BOOL FFLSReadLE32(NSData *data, NSUInteger offset, uint32_t *valueOut)
{
    if (!valueOut || offset > data.length || data.length - offset < 4) return NO;
    const uint8_t *bytes = data.bytes;
    const uint8_t *p = bytes + offset;
    *valueOut = (uint32_t)p[0] |
        ((uint32_t)p[1] << 8) |
        ((uint32_t)p[2] << 16) |
        ((uint32_t)p[3] << 24);
    return YES;
}

static BOOL FFLSUnitPayloadRange(NSData *data, NSUInteger unitOffset, NSRange *rangeOut)
{
    if (!rangeOut || unitOffset > data.length || data.length - unitOffset < 8) return NO;
    uint32_t payloadSize = 0;
    if (!FFLSReadLE32(data, unitOffset + 4, &payloadSize)) return NO;
    NSUInteger payloadOffset = unitOffset + 8;
    if (payloadOffset > data.length || payloadSize > data.length - payloadOffset) return NO;
    *rangeOut = NSMakeRange(payloadOffset, payloadSize);
    return YES;
}

static BOOL FFLSTableInfoAtUnitOffset(NSData *data, NSUInteger unitOffset,
                                      NSString **nameOut, NSUInteger *hashmapOffsetOut)
{
    NSRange payload = NSMakeRange(0, 0);
    if (!FFLSUnitPayloadRange(data, unitOffset, &payload) || payload.length < 0x48) return NO;

    const uint8_t *bytes = data.bytes;
    const uint8_t *nameBytes = bytes + payload.location;
    NSUInteger nameLength = 0;
    while (nameLength < 0x30 && nameBytes[nameLength] != 0) nameLength++;
    NSString *name = [[NSString alloc] initWithBytes:nameBytes
        length:nameLength encoding:NSUTF8StringEncoding];
    if (!name) return NO;

    uint32_t hashmapOffset = 0;
    if (!FFLSReadLE32(data, payload.location + 0x44, &hashmapOffset)) return NO;
    if (hashmapOffset && hashmapOffset >= data.length) return NO;

    if (nameOut) *nameOut = name;
    if (hashmapOffsetOut) *hashmapOffsetOut = hashmapOffset;
    return YES;
}

static NSUInteger FFLSValidHashmapEntryCount(NSData *data, NSUInteger hashmapOffset)
{
    if (!hashmapOffset || hashmapOffset >= data.length) return NSNotFound;
    uint32_t bucketCount = 0;
    if (!FFLSReadLE32(data, hashmapOffset, &bucketCount) ||
        bucketCount == 0 || bucketCount > 65536)
        return NSNotFound;

    NSUInteger bucketTable = hashmapOffset + 4;
    if (bucketTable > data.length || (NSUInteger)bucketCount > (data.length - bucketTable) / 8)
        return NSNotFound;

    NSUInteger count = 0;
    for (uint32_t bucket = 0; bucket < bucketCount; bucket++) {
        NSUInteger bucketOffset = bucketTable + (NSUInteger)bucket * 8;
        uint32_t itemCount = 0;
        uint32_t itemsOffset = 0;
        if (!FFLSReadLE32(data, bucketOffset, &itemCount) ||
            !FFLSReadLE32(data, bucketOffset + 4, &itemsOffset))
            return NSNotFound;
        if (itemCount == 0) continue;
        if (itemCount > 1000000 || itemsOffset >= data.length ||
            (NSUInteger)itemCount > (data.length - itemsOffset) / 8)
            return NSNotFound;

        for (uint32_t item = 0; item < itemCount; item++) {
            uint32_t valueOffset = 0;
            NSUInteger pairOffset = itemsOffset + (NSUInteger)item * 8;
            if (!FFLSReadLE32(data, pairOffset + 4, &valueOffset)) return NSNotFound;
            if (valueOffset == UINT32_MAX || valueOffset == 0 || valueOffset >= data.length)
                continue;
            count++;
        }
    }
    return count;
}

static NSUInteger FFLSBundleRecordCountInStore(NSData *data)
{
    if (data.length < 28) return NSNotFound;
    const uint8_t *bytes = data.bytes;
    if (bytes[0] != 'b' || bytes[1] != 'd' || bytes[2] != 's' || bytes[3] != 'l' ||
        bytes[4] != 2)
        return NSNotFound;

    NSString *catalogName = nil;
    NSUInteger catalogHashmap = 0;
    if (!FFLSTableInfoAtUnitOffset(data, 20, &catalogName, &catalogHashmap) ||
        ![catalogName isEqualToString:@"<catalog>"] || !catalogHashmap)
        return NSNotFound;

    uint32_t bucketCount = 0;
    if (!FFLSReadLE32(data, catalogHashmap, &bucketCount) ||
        bucketCount == 0 || bucketCount > 65536)
        return NSNotFound;
    NSUInteger bucketTable = catalogHashmap + 4;
    if (bucketTable > data.length || (NSUInteger)bucketCount > (data.length - bucketTable) / 8)
        return NSNotFound;

    for (uint32_t bucket = 0; bucket < bucketCount; bucket++) {
        NSUInteger bucketOffset = bucketTable + (NSUInteger)bucket * 8;
        uint32_t itemCount = 0;
        uint32_t itemsOffset = 0;
        if (!FFLSReadLE32(data, bucketOffset, &itemCount) ||
            !FFLSReadLE32(data, bucketOffset + 4, &itemsOffset))
            return NSNotFound;
        if (itemCount == 0) continue;
        if (itemCount > 100000 || itemsOffset >= data.length ||
            (NSUInteger)itemCount > (data.length - itemsOffset) / 8)
            return NSNotFound;

        for (uint32_t item = 0; item < itemCount; item++) {
            uint32_t tableUnitOffset = 0;
            NSUInteger pairOffset = itemsOffset + (NSUInteger)item * 8;
            if (!FFLSReadLE32(data, pairOffset + 4, &tableUnitOffset)) return NSNotFound;
            if (tableUnitOffset == UINT32_MAX || tableUnitOffset == 0 ||
                tableUnitOffset >= data.length)
                continue;

            NSString *tableName = nil;
            NSUInteger tableHashmap = 0;
            if (!FFLSTableInfoAtUnitOffset(data, tableUnitOffset, &tableName, &tableHashmap))
                continue;
            if (![tableName isEqualToString:@"Bundle"]) continue;
            return FFLSValidHashmapEntryCount(data, tableHashmap);
        }
    }
    return NSNotFound;
}

NSUInteger FFLSBundleRecordCount(NSString *lsdContainerRoot)
{
    NSArray<NSString *> *storePaths = FFLSStorePaths(lsdContainerRoot, NULL, NULL);
    NSUInteger best = NSNotFound;
    for (NSString *path in storePaths) {
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:nil];
        if (!data) continue;
        NSUInteger count = FFLSBundleRecordCountInStore(data);
        if (count == NSNotFound) {
            FFLogTag(@"LSInventory", @"Bundle table parse failed path=%@", path.lastPathComponent);
            continue;
        }
        FFLogTag(@"LSInventory", @"Bundle table path=%@ records=%lu",
            path.lastPathComponent, (unsigned long)count);
        if (best == NSNotFound || count > best) best = count;
    }
    return best;
}

static NSString *FFLSIdentifierFromApplicationObject(id object)
{
    if ([object isKindOfClass:NSString.class])
        return FFLSSafeIdentifier(object) ? object : nil;
    if (!object) return nil;

    SEL installedSelector = NSSelectorFromString(@"isInstalled");
    if ([object respondsToSelector:installedSelector] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(object, installedSelector))
        return nil;
    SEL placeholderSelector = NSSelectorFromString(@"isPlaceholder");
    if ([object respondsToSelector:placeholderSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(object, placeholderSelector))
        return nil;

    NSString *identifier = nil;
    SEL bundleIDSelector = NSSelectorFromString(@"bundleIdentifier");
    SEL appIDSelector = NSSelectorFromString(@"applicationIdentifier");
    if ([object respondsToSelector:bundleIDSelector])
        identifier = ((id (*)(id, SEL))objc_msgSend)(object, bundleIDSelector);
    if (!FFLSSafeIdentifier(identifier) && [object respondsToSelector:appIDSelector])
        identifier = ((id (*)(id, SEL))objc_msgSend)(object, appIDSelector);
    return FFLSSafeIdentifier(identifier) ? identifier : nil;
}

static void FFLSAddApplicationObjects(NSMutableOrderedSet<NSString *> *result, id objects)
{
    if (![objects isKindOfClass:NSArray.class]) return;
    for (id object in (NSArray *)objects) {
        NSString *identifier = FFLSIdentifierFromApplicationObject(object);
        if (identifier.length) [result addObject:identifier];
    }
}

static NSUInteger FFLSAddDirectApplicationRecords(NSMutableOrderedSet<NSString *> *result)
{
    Class recordClass = NSClassFromString(@"LSApplicationRecord");
    SEL selector = NSSelectorFromString(@"enumeratorWithOptions:");
    if (!recordClass || ![recordClass respondsToSelector:selector]) return 0;

    NSUInteger before = result.count;
    @try {
        id enumerator = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(recordClass, selector, 0ULL);
        SEL nextSelector = @selector(nextObject);
        if ([enumerator respondsToSelector:nextSelector]) {
            NSUInteger guard = 0;
            while (guard++ < 8192) {
                id record = ((id (*)(id, SEL))objc_msgSend)(enumerator, nextSelector);
                if (!record) break;
                NSString *identifier = FFLSIdentifierFromApplicationObject(record);
                if (identifier.length) [result addObject:identifier];
            }
        } else if ([enumerator conformsToProtocol:@protocol(NSFastEnumeration)]) {
            NSUInteger guard = 0;
            for (id record in enumerator) {
                NSString *identifier = FFLSIdentifierFromApplicationObject(record);
                if (identifier.length) [result addObject:identifier];
                if (++guard >= 8192) break;
            }
        }
    } @catch (NSException *exception) {
        FFLogTag(@"LSInventory", @"direct record enumerator exception=%@",
            exception.reason ?: exception.name);
    }
    NSUInteger added = result.count - before;
    FFLogTag(@"LSInventory", @"direct record enumerator identifiers=%lu",
        (unsigned long)added);
    return added;
}

NSArray<NSString *> *FFLSStructuredInstalledApplicationIdentifiers(void)
{
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];

    // LSApplicationWorkspace is filtered to zero records for the
    // MobileHouseArrest identity on the user's iOS 27 build. Try the newer
    // LSApplicationRecord database enumerator first; it maps the LaunchServices
    // record layer directly and does not depend on Workspace enumeration.
    FFLSAddDirectApplicationRecords(result);

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (workspaceClass && [workspaceClass respondsToSelector:defaultSelector]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
        if (workspace) {
            @try {
                SEL enumerateSelector = NSSelectorFromString(@"enumerateApplicationsOfType:block:");
                if ([workspace respondsToSelector:enumerateSelector]) {
                    typedef void (^FFLSApplicationBlock)(id);
                    void (*enumerateSend)(id, SEL, unsigned long long, FFLSApplicationBlock) =
                        (void (*)(id, SEL, unsigned long long, FFLSApplicationBlock))objc_msgSend;
                    for (unsigned long long type = 0; type <= 1; type++) {
                        enumerateSend(workspace, enumerateSelector, type, ^(id proxy) {
                            NSString *identifier = FFLSIdentifierFromApplicationObject(proxy);
                            if (identifier.length) @synchronized (result) { [result addObject:identifier]; }
                        });
                    }
                } else {
                    SEL applicationsOfTypeSelector = NSSelectorFromString(@"applicationsOfType:");
                    if ([workspace respondsToSelector:applicationsOfTypeSelector]) {
                        id (*sendType)(id, SEL, unsigned long long) =
                            (id (*)(id, SEL, unsigned long long))objc_msgSend;
                        FFLSAddApplicationObjects(result, sendType(workspace, applicationsOfTypeSelector, 0));
                        FFLSAddApplicationObjects(result, sendType(workspace, applicationsOfTypeSelector, 1));
                    }
                }

                for (NSString *selectorName in @[@"allInstalledApplications", @"installedApplications", @"allApplications"]) {
                    SEL listSelector = NSSelectorFromString(selectorName);
                    if ([workspace respondsToSelector:listSelector]) {
                        id objects = ((id (*)(id, SEL))objc_msgSend)(workspace, listSelector);
                        FFLSAddApplicationObjects(result, objects);
                    }
                }
            } @catch (NSException *exception) {
                FFLogTag(@"LSInventory", @"structured workspace exception=%@",
                    exception.reason ?: exception.name);
            }
        }
    }

    FFLogTag(@"LSInventory", @"structured installed identifiers=%lu",
        (unsigned long)result.count);
    return result.array;
}

#pragma mark - Raw fallback discovery

static NSArray<NSString *> *FFLSCachedIdentifiersForFingerprint(NSString *fingerprint,
                                                                 BOOL groupsOnly)
{
    if (!fingerprint.length) return nil;
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:
        FFLSCachePathForMode(groupsOnly)];
    if (![cache[@"StoreFingerprint"] isKindOfClass:NSString.class] ||
        ![cache[@"StoreFingerprint"] isEqualToString:fingerprint])
        return nil;
    NSArray *identifiers = cache[@"Identifiers"];
    if (![identifiers isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *safe = [NSMutableArray arrayWithCapacity:identifiers.count];
    for (id value in identifiers)
        if ([value isKindOfClass:NSString.class] && FFLSSafeIdentifier(value))
            [safe addObject:value];
    return safe;
}

static void FFLSWriteCache(NSString *fingerprint, unsigned long long storeSize,
                           NSArray<NSString *> *identifiers, BOOL groupsOnly)
{
    if (!fingerprint.length) return;
    NSDictionary *cache = @{
        @"StoreFingerprint": fingerprint,
        @"StoreSize": @(storeSize),
        @"Identifiers": identifiers,
    };
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

    unsigned long long totalStoreSize = 0;
    NSString *fingerprint = nil;
    NSArray<NSString *> *storePaths = FFLSStorePaths(lsdContainerRoot,
        &totalStoreSize, &fingerprint);
    if (storePaths.count == 0 || !fingerprint.length) {
        FFLogTag(@"LSDiscovery", @"no LaunchServices store files under %@",
            [lsdContainerRoot stringByAppendingPathComponent:@"Library/Caches"]);
        return @[];
    }

    NSArray<NSString *> *cached = FFLSCachedIdentifiersForFingerprint(fingerprint, groupsOnly);
    if (cached) {
        FFLogTag(@"LSDiscovery", @"store unchanged mode=%@ (%llu bytes, %lu files); reused cached candidates=%lu",
                 groupsOnly ? @"groups" : @"apps", totalStoreSize,
                 (unsigned long)storePaths.count, (unsigned long)cached.count);
        if (cached.count > maxCandidates)
            return [cached subarrayWithRange:NSMakeRange(0, maxCandidates)];
        return cached;
    }

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
                if (groupsOnly && ![candidate hasPrefix:@"group."]) {
                    start = NSNotFound;
                    continue;
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
    FFLSWriteCache(fingerprint, totalStoreSize, result, groupsOnly);
    if (result.count > maxCandidates)
        return [result subarrayWithRange:NSMakeRange(0, maxCandidates)];
    return result;
}
