#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread after any override change so association UI
// can reload. Lookups always read live state, previews take effect
// immediately without restart.
extern NSString * const FFFileAssociationsDidChangeNotification;

// Extension → viewer mapping.
//
// Built-in defaults live in code; user changes are persisted as overrides
// in NSUserDefaults only. App upgrades adding new default extensions never
// overwrite existing overrides, and "恢复默认关联" simply clears them.
//
// Extension matching is longest-suffix-first ("backup.tar.gz" matches the
// key "tar.gz" before "gz"), case-insensitive, with leading dots and
// whitespace normalized away. For a given suffix an override beats the
// built-in default; longer suffixes win regardless of their source.
@interface FFFileAssociationService : NSObject

+ (instancetype)sharedService;

// Longest-suffix match over the file name; nil when nothing matches.
- (nullable NSString *)viewerIDForFileName:(NSString *)fileName;

// Effective viewer for one extension key (lowercase, no dot):
// override if present, otherwise built-in default, otherwise nil.
- (nullable NSString *)effectiveViewerIDForExtension:(NSString *)extension;

// The extension's source: YES = stored override / custom entry,
// NO = built-in default, NO when unknown.
- (BOOL)hasOverrideForExtension:(NSString *)extension;

- (void)setOverrideViewerID:(NSString *)viewerID forExtension:(NSString *)extension;
- (void)removeOverrideForExtension:(NSString *)extension;

// Union of default keys and override keys, sorted.
- (NSArray<NSString *> *)allKnownExtensions;

// Clears every override and custom entry (restores built-in defaults).
- (void)resetAllOverrides;

// "TAR.GZ" / ".Tar.gz" → "tar.gz"; also collapses a bare "." chain.
+ (NSString *)normalizedExtension:(NSString *)rawExtension;

@end

NS_ASSUME_NONNULL_END
