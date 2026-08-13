#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Resolves a bundle identifier to a human-readable app name. Uses a static
// map for system apps, then the LaunchServices workspace (cached), then
// falls back to a capitalized form of the identifier.
NSString *FFAppDisplayName(NSString *identifier);

// Reads the iTunesMetadata.plist itemName of an app container directory
// (App Store installs carry the localized display name there). Returns nil
// when the container has no readable metadata.
NSString * _Nullable FFAppContainerItemName(NSString *containerPath);


// YES for 8-4-4-4-12 container UUID directory names (36 chars, dashes).
BOOL FFIsUUIDShapedName(NSString *name);

NS_ASSUME_NONNULL_END
