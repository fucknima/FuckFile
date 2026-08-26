#import "FFBrowserViewController.h"
#import "FFFileIconProvider.h"
#import <objc/runtime.h>

/// Visual-only hook kept outside the browser controller so icon policy does not
/// get mixed into navigation, file IO, sorting or search logic. The original
/// implementation remains available as a safety fallback after swizzling.
@interface FFBrowserViewController (FileIcons)
- (UIImage *)ff_design_iconForEntry:(FFEntry *)entry;
@end

@implementation FFBrowserViewController (FileIcons)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;
        SEL originalSEL = NSSelectorFromString(@"iconForEntry:");
        SEL replacementSEL = @selector(ff_design_iconForEntry:);
        Method original = class_getInstanceMethod(cls, originalSEL);
        Method replacement = class_getInstanceMethod(cls, replacementSEL);
        if (original && replacement)
            method_exchangeImplementations(original, replacement);
    });
}

- (UIImage *)ff_design_iconForEntry:(FFEntry *)entry
{
    UIImage *icon = [FFFileIconProvider iconForEntry:entry];
    if (icon) return icon;
    // After exchange this selector points to Browser's original implementation.
    return [self ff_design_iconForEntry:entry];
}

@end
