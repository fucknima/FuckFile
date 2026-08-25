#import "FFAppDelegate.h"
#import "FFShareBridge.h"
#import "FFLogger.h"

#import <objc/runtime.h>

static const void *kFFHandledShareTokensKey = &kFFHandledShareTokensKey;
static const NSTimeInterval kFFShareTokenDedupTTL = 60.0;

@interface FFAppDelegate (ShareWakeDedup)
- (void)ff_handleShareWakeURLDeduplicated:(NSURL *)url;
@end

@implementation FFAppDelegate (ShareWakeDedup)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"handleShareWakeURL:"));
        Method replacement = class_getInstanceMethod(self,
            @selector(ff_handleShareWakeURLDeduplicated:));
        if (original && replacement)
            method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_handleShareWakeURLDeduplicated:(NSURL *)url
{
    BOOL isShareStream =
        [[url.scheme lowercaseString] isEqualToString:[FFShareWakeScheme lowercaseString]] &&
        [[url.host lowercaseString] isEqualToString:@"share-stream"];
    if (!isShareStream) {
        [self ff_handleShareWakeURLDeduplicated:url];
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url
        resolvingAgainstBaseURL:NO];
    NSString *token = nil;
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if ([item.name isEqualToString:@"token"]) {
            token = item.value;
            break;
        }
    }

    // Malformed URLs still go through the host implementation so its existing
    // validation and logging remain authoritative.
    if (!token.length) {
        [self ff_handleShareWakeURLDeduplicated:url];
        return;
    }

    @synchronized (self) {
        NSMutableDictionary<NSString *, NSDate *> *handled =
            objc_getAssociatedObject(self, kFFHandledShareTokensKey);
        if (!handled) {
            handled = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, kFFHandledShareTokensKey, handled,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSDate *now = NSDate.date;
        NSMutableArray<NSString *> *expired = [NSMutableArray array];
        for (NSString *key in handled) {
            if ([now timeIntervalSinceDate:handled[key]] >= kFFShareTokenDedupTTL)
                [expired addObject:key];
        }
        [handled removeObjectsForKeys:expired];

        NSDate *seen = handled[token];
        if (seen && [now timeIntervalSinceDate:seen] < kFFShareTokenDedupTTL) {
            FFLogTag(@"ShareBridge", @"ignore duplicate share-stream wake token=%@", token);
            return;
        }
        handled[token] = now;
    }

    // Cold launch can deliver the same custom URL once in launchOptions and
    // again via application:openURL:. Without token-level deduplication each
    // delivery starts another serial listener. The first listener imports the
    // file successfully; the second has no client left and emits the misleading
    // "等待分享扩展连接超时" alert five seconds later.
    [self ff_handleShareWakeURLDeduplicated:url];
}

@end
