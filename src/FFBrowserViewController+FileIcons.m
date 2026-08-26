#import "FFBrowserViewController.h"
#import "FFFileIconProvider.h"
#import <objc/runtime.h>

/// Visual-only hooks kept outside the browser controller so icon policy does not
/// get mixed into navigation, file IO, sorting or search logic.
///
/// Content thumbnails used to make PDFs/images/videos occupy wildly different
/// optical sizes (a portrait PDF page could look ~12pt wide beside a 40pt app
/// icon). The new design uses one fixed type-icon language for ordinary files;
/// only IPA keeps its real app artwork, where the artwork itself is meaningful.
@interface FFBrowserViewController (FileIcons)
- (UIImage *)ff_design_iconForEntry:(FFEntry *)entry;
- (BOOL)ff_design_supportsThumbnail:(FFEntry *)entry;
@end

@implementation FFBrowserViewController (FileIcons)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;

        Method iconOriginal = class_getInstanceMethod(cls, NSSelectorFromString(@"iconForEntry:"));
        Method iconReplacement = class_getInstanceMethod(cls, @selector(ff_design_iconForEntry:));
        if (iconOriginal && iconReplacement)
            method_exchangeImplementations(iconOriginal, iconReplacement);

        Method thumbnailOriginal = class_getInstanceMethod(cls, NSSelectorFromString(@"supportsThumbnail:"));
        Method thumbnailReplacement = class_getInstanceMethod(cls, @selector(ff_design_supportsThumbnail:));
        if (thumbnailOriginal && thumbnailReplacement)
            method_exchangeImplementations(thumbnailOriginal, thumbnailReplacement);
    });
}

- (UIImage *)ff_design_iconForEntry:(FFEntry *)entry
{
    UIImage *icon = [FFFileIconProvider iconForEntry:entry];
    if (icon) return icon;
    // After exchange this selector points to Browser's original implementation.
    return [self ff_design_iconForEntry:entry];
}

- (BOOL)ff_design_supportsThumbnail:(FFEntry *)entry
{
    // Real app artwork is deliberately preserved. Everything else uses the
    // unified type icon so list rows never jump between portrait-page previews,
    // landscape frames and square app icons.
    return [entry.name.pathExtension.lowercaseString isEqualToString:@"ipa"];
}

@end
