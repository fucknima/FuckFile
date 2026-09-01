#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Curated, high-confidence short names for common apps. These are display-only
// hints keyed by exact Bundle ID; they never participate in app discovery.
FOUNDATION_EXPORT nullable NSString *FFBuiltInAppNameForIdentifier(NSString *identifier);

// Conservative normalization for App Store product titles. It keeps legitimate
// names intact and trims only obvious marketing/tagline suffixes.
FOUNDATION_EXPORT NSString *FFNormalizeAppDisplayName(NSString *name);

NS_ASSUME_NONNULL_END
