#import "FFBrowserViewController.h"
#import <objc/runtime.h>

// Browser 的缩略图请求链已经统一走 FFThumbnailService；这里只扩展它的
// capability gate，让 .ipa 进入同一异步缩略图管线，避免复制 cell/grid 逻辑。
@interface FFBrowserViewController (IPAThumbnail)
- (BOOL)ff_ipa_supportsThumbnail:(FFEntry *)item;
@end

@implementation FFBrowserViewController (IPAThumbnail)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;
        SEL originalSEL = NSSelectorFromString(@"supportsThumbnail:");
        SEL replacementSEL = @selector(ff_ipa_supportsThumbnail:);
        Method original = class_getInstanceMethod(cls, originalSEL);
        Method replacement = class_getInstanceMethod(cls, replacementSEL);
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (BOOL)ff_ipa_supportsThumbnail:(FFEntry *)item
{
    if ([item.name.pathExtension.lowercaseString isEqualToString:@"ipa"]) return YES;
    // 交换后该 selector 指向原实现。
    return [self ff_ipa_supportsThumbnail:item];
}

@end
