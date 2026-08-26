#import "FFLSStoreInventory.h"
#import "FFLogger.h"

static BOOL FFLSIReadU32(NSData *data, NSUInteger offset, uint32_t *value)
{
    if (!value || offset > data.length || data.length - offset < 4) return NO;
    const uint8_t *bytes = data.bytes + offset;
    *value = (uint32_t)bytes[0] |
        ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) |
        ((uint32_t)bytes[3] << 24);
    return YES;
}

static BOOL FFLSIUnitPayload(NSData *data, NSUInteger unitOffset, NSRange *payload)
{
    if (!payload || unitOffset > data.length || data.length - unitOffset < 8) return NO;
    uint32_t size = 0;
    if (!FFLSIReadU32(data, unitOffset + 4, &size)) return NO;
    NSUInteger start = unitOffset + 8;
    if (start > data.length || (NSUInteger)size > data.length - start) return NO;
    *payload = NSMakeRange(start, (NSUInteger)size);
    return YES;
}

static BOOL FFLSITable(NSData *data, NSUInteger unitOffset,
                       NSString **nameOut, NSUInteger *hashmapOut)
{
    NSRange payload = NSMakeRange(0, 0);
    if (!FFLSIUnitPayload(data, unitOffset, &payload) || payload.length < 0x48) return NO;
    const uint8_t *nameBytes = data.bytes + payload.location;
    NSUInteger length = 0;
    while (length < 0x30 && nameBytes[length] != 0) length++;
    NSString *name = [[NSString alloc] initWithBytes:nameBytes length:length
        encoding:NSUTF8StringEncoding];
    if (!name.length) return NO;
    uint32_t hashmap = 0;
    if (!FFLSIReadU32(data, payload.location + 0x44, &hashmap)) return NO;
    if (hashmap != 0 && hashmap >= data.length) return NO;
    if (nameOut) *nameOut = name;
    if (hashmapOut) *hashmapOut = hashmap;
    return YES;
}

// CoreServicesStore hash map: u32 bucketCount followed by bucketCount pairs of
// {u32 itemCount,u32 itemsOffset}; each item is {u32 key,u32 absoluteUnitOffset}.
// This layout is independently documented by JJTech0130/launchservices and is
// already the format used by FFLSBundleRecordCount in FFLSDiscovery.m.
static NSDictionary<NSNumber *, NSNumber *> *FFLSIHashmap(NSData *data,
                                                           NSUInteger offset,
                                                           BOOL *validOut)
{
    if (validOut) *validOut = NO;
    uint32_t bucketCount = 0;
    if (!offset || !FFLSIReadU32(data, offset, &bucketCount) ||
        bucketCount == 0 || bucketCount > 65536) return nil;
    NSUInteger buckets = offset + 4;
    if (buckets > data.length || (NSUInteger)bucketCount > (data.length - buckets) / 8)
        return nil;

    NSMutableDictionary<NSNumber *, NSNumber *> *result = [NSMutableDictionary dictionary];
    for (uint32_t bucket = 0; bucket < bucketCount; bucket++) {
        NSUInteger bucketOffset = buckets + (NSUInteger)bucket * 8;
        uint32_t count = 0, items = 0;
        if (!FFLSIReadU32(data, bucketOffset, &count) ||
            !FFLSIReadU32(data, bucketOffset + 4, &items)) return nil;
        if (count == 0) continue;
        if (count > 1000000 || items >= data.length ||
            (NSUInteger)count > (data.length - items) / 8) return nil;
        for (uint32_t index = 0; index < count; index++) {
            NSUInteger pair = items + (NSUInteger)index * 8;
            uint32_t key = 0, value = 0;
            if (!FFLSIReadU32(data, pair, &key) || !FFLSIReadU32(data, pair + 4, &value))
                return nil;
            if (value == 0 || value == UINT32_MAX) continue;
            if (value >= data.length) return nil;
            result[@(key)] = @(value);
        }
    }
    if (validOut) *validOut = YES;
    return result;
}

static BOOL FFLSISafeIdentifier(NSString *identifier)
{
    if (identifier.length < 3 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier hasPrefix:@"."] && ![identifier hasSuffix:@"."] &&
        ![identifier containsString:@".."] && [identifier containsString:@"."];
}

static NSString *FFLSIStringAtKey(NSData *data,
                                  NSDictionary<NSNumber *, NSNumber *> *strings,
                                  uint32_t key)
{
    NSNumber *offsetNumber = strings[@(key)];
    if (!offsetNumber) return nil;
    NSRange payload = NSMakeRange(0, 0);
    if (!FFLSIUnitPayload(data, offsetNumber.unsignedIntegerValue, &payload) ||
        payload.length == 0 || payload.length > 4096) return nil;
    NSString *value = [[NSString alloc] initWithBytes:(const uint8_t *)data.bytes + payload.location
        length:payload.length encoding:NSUTF8StringEncoding];
    // Some store generations include a terminating NUL in the CSString unit.
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
    return value.length ? value : nil;
}

NSArray<NSString *> *FFLSStoreBundleIdentifiersFromData(NSData *data,
                                                        BOOL *complete,
                                                        NSUInteger *recordCount)
{
    if (complete) *complete = NO;
    if (recordCount) *recordCount = 0;
    if (data.length < 28) return @[];
    const uint8_t *bytes = data.bytes;
    if (bytes[0] != 'b' || bytes[1] != 'd' || bytes[2] != 's' || bytes[3] != 'l' ||
        bytes[4] != 2) return @[];

    NSString *catalogName = nil;
    NSUInteger catalogHashmap = 0;
    if (!FFLSITable(data, 20, &catalogName, &catalogHashmap) ||
        ![catalogName isEqualToString:@"<catalog>"] || !catalogHashmap) return @[];

    BOOL catalogValid = NO;
    NSDictionary<NSNumber *, NSNumber *> *catalog = FFLSIHashmap(data, catalogHashmap, &catalogValid);
    if (!catalogValid) return @[];

    NSUInteger bundleHashmap = 0, stringHashmap = 0;
    for (NSNumber *unitOffset in catalog.allValues) {
        NSString *tableName = nil;
        NSUInteger tableHashmap = 0;
        if (!FFLSITable(data, unitOffset.unsignedIntegerValue, &tableName, &tableHashmap)) continue;
        if ([tableName isEqualToString:@"Bundle"]) bundleHashmap = tableHashmap;
        else if ([tableName isEqualToString:@"<string>"]) stringHashmap = tableHashmap;
    }
    if (!bundleHashmap || !stringHashmap) return @[];

    BOOL bundlesValid = NO, stringsValid = NO;
    NSDictionary<NSNumber *, NSNumber *> *bundles = FFLSIHashmap(data, bundleHashmap, &bundlesValid);
    NSDictionary<NSNumber *, NSNumber *> *strings = FFLSIHashmap(data, stringHashmap, &stringsValid);
    if (!bundlesValid || !stringsValid) return @[];

    NSUInteger records = bundles.count;
    if (recordCount) *recordCount = records;
    if (records == 0) {
        if (complete) *complete = YES;
        return @[];
    }

    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    BOOL allResolved = YES;
    for (NSNumber *recordOffset in bundles.allValues) {
        NSRange payload = NSMakeRange(0, 0);
        // iOS 18.2, iOS 26.1 and iOS 27 class dumps agree on
        // LSBundleBaseData's first fields:
        // bookmark, container, execPath, exactIdentifier (four u32 values).
        // LSBundleRecordBuilder on iOS 26.1 assigns exactIdentifier using
        // _LSDatabaseCreateStringForCFString(identifier, const=0).
        if (!FFLSIUnitPayload(data, recordOffset.unsignedIntegerValue, &payload) ||
            payload.length < 16) {
            allResolved = NO;
            continue;
        }
        uint32_t exactIdentifier = 0;
        if (!FFLSIReadU32(data, payload.location + 12, &exactIdentifier) || !exactIdentifier) {
            allResolved = NO;
            continue;
        }
        NSString *identifier = FFLSIStringAtKey(data, strings, exactIdentifier);
        if (!FFLSISafeIdentifier(identifier)) {
            allResolved = NO;
            continue;
        }
        [identifiers addObject:identifier];
    }

    // Duplicate exact identifiers are not accepted as authoritative either:
    // callers compare records, not a heuristic subset. A mismatch falls back to
    // the older candidate scan rather than risking an uninstall false-positive.
    BOOL authoritative = allResolved && identifiers.count == records;
    if (complete) *complete = authoritative;
    return identifiers.array;
}

static NSArray<NSString *> *FFLSIStorePaths(NSString *root)
{
    if (!root.length) return @[];
    NSString *caches = [root stringByAppendingPathComponent:@"Library/Caches"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:caches error:nil] ?: @[];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"] ||
            ![name hasSuffix:@"-v2.csstore"]) continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size == 0 || size > 64ULL * 1024 * 1024) continue;
        [paths addObject:path];
    }
    return [paths sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *FFLSStoreBundleIdentifiers(NSString *lsdContainerRoot,
                                                BOOL *complete,
                                                NSUInteger *recordCount)
{
    if (complete) *complete = NO;
    if (recordCount) *recordCount = 0;

    NSArray<NSString *> *best = @[];
    NSUInteger bestRecords = 0;
    BOOL bestComplete = NO;
    NSString *bestName = nil;

    for (NSString *path in FFLSIStorePaths(lsdContainerRoot)) {
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (!data) continue;
        BOOL parsedComplete = NO;
        NSUInteger records = 0;
        NSArray<NSString *> *ids = FFLSStoreBundleIdentifiersFromData(data, &parsedComplete, &records);
        if (records > bestRecords || (records == bestRecords && parsedComplete && !bestComplete)) {
            best = ids;
            bestRecords = records;
            bestComplete = parsedComplete;
            bestName = path.lastPathComponent;
        }
    }

    if (complete) *complete = bestComplete;
    if (recordCount) *recordCount = bestRecords;
    FFLogTag(@"LSInventory", @"structural Bundle ids=%lu records=%lu complete=%d store=%@",
        (unsigned long)best.count, (unsigned long)bestRecords, bestComplete,
        bestName ?: @"(none)");
    return best;
}
