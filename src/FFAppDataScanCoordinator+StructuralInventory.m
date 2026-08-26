#import "FFAppDataScanCoordinator.h"
#import "FFLSDiscovery.h"
#import "FFLSStoreInventory.h"
#import "FFLogger.h"
#import "MCMManager.h"

#import <objc/runtime.h>

@interface MCMManager (FFStructuralInventoryPrivate)
- (nullable NSString *)activate:(uint64_t)containerClass
                     identifier:(NSString *)identifier
                          group:(BOOL)group
                          error:(NSString * _Nullable * _Nullable)error;
@end

@implementation FFAppDataScanCoordinator (StructuralInventory)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(scanWithCompletion:));
        Method replacement = class_getInstanceMethod(self, @selector(ff_structural_scanWithCompletion:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

static NSString *FFStructuralLSCachePath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"LSIdentifierCache.plist"];
}

static void FFPrewarmStructuralLaunchServicesCache(void)
{
    NSString *error = nil;
    NSString *lsdRoot = [MCMManager.sharedManager activate:10
        identifier:@"com.apple.lsd" group:NO error:&error];
    if (!lsdRoot.length) {
        FFLogTag(@"LSInventory", @"structural prewarm skipped: lsd unavailable detail=%@",
            error ?: @"(nil)");
        return;
    }

    NSString *fingerprint = FFLSStoreFingerprint(lsdRoot);
    if (!fingerprint.length) {
        FFLogTag(@"LSInventory", @"structural prewarm skipped: no store fingerprint");
        return;
    }

    BOOL complete = NO;
    NSUInteger parsedRecords = 0;
    NSArray<NSString *> *identifiers = FFLSStoreBundleIdentifiers(
        lsdRoot, &complete, &parsedRecords);
    NSUInteger independentCount = FFLSBundleRecordCount(lsdRoot);

    // Two independent structural walks must agree before we replace the old
    // byte-string candidate cache. Any schema drift fails closed and leaves the
    // legacy raw scan untouched.
    BOOL countsAgree = independentCount != NSNotFound &&
        independentCount == parsedRecords && identifiers.count == parsedRecords;
    if (!complete || !countsAgree || identifiers.count == 0) {
        FFLogTag(@"LSInventory",
            @"structural prewarm rejected complete=%d ids=%lu parsed=%lu independent=%@; keep raw fallback",
            complete, (unsigned long)identifiers.count, (unsigned long)parsedRecords,
            independentCount == NSNotFound ? @"unknown" :
                [NSString stringWithFormat:@"%lu", (unsigned long)independentCount]);
        return;
    }

    NSDictionary *cache = @{
        @"StoreFingerprint": fingerprint,
        @"StoreSize": @0,
        @"Identifiers": identifiers,
        @"Source": @"CoreServicesStore.Bundle.exactIdentifier",
    };
    if (![cache writeToFile:FFStructuralLSCachePath() atomically:YES]) {
        FFLogTag(@"LSInventory", @"structural prewarm cache write failed");
        return;
    }
    FFLogTag(@"LSInventory", @"structural prewarm accepted ids=%lu; raw byte scan bypassed",
        (unsigned long)identifiers.count);
}

- (void)ff_structural_scanWithCompletion:(void (^)(void))completion
{
    // Parsing a several-megabyte csstore and activating lsd must never block UI.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { FFPrewarmStructuralLaunchServicesCache(); }
        // Swizzled selector now points at the original coordinator method.
        [self ff_structural_scanWithCompletion:completion];
    });
}

@end
