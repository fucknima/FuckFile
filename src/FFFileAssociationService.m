#import "FFFileAssociationService.h"

NSString * const FFFileAssociationsDidChangeNotification =
    @"FFFileAssociationsDidChange";

// Built-in defaults. Keys are lowercase suffixes without the leading dot;
// compound keys like "tar.gz" participate in longest-suffix matching.
// .deb deliberately has no entry anywhere (no dedicated viewer, not an
// archive, never routed to installer/zip).
static NSDictionary<NSString *, NSString *> *FFDefaultAssociations(void)
{
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            // 文本编辑器（.sh/.script/.applescript 仅按文本打开，不执行）
            @"txt": @"text", @"log": @"text", @"md": @"text",
            @"mdown": @"text", @"json": @"text", @"xml": @"text",
            @"c": @"text", @"h": @"text", @"m": @"text", @"mm": @"text",
            @"cpp": @"text", @"cc": @"text", @"py": @"text", @"php": @"text",
            @"js": @"text", @"css": @"text", @"as": @"text", @"as3": @"text",
            @"clisp": @"text", @"sh": @"text", @"script": @"text",
            @"applescript": @"text", @"list": @"text",
            @"plist": @"plist",
            @"sqlite": @"sqlite", @"sqlite3": @"sqlite", @"sqlitedb": @"sqlite", @"db": @"sqlite",
            @"png": @"image", @"jpg": @"image", @"jpeg": @"image", @"gif": @"image",
            @"heic": @"image", @"webp": @"image", @"bmp": @"image", @"tif": @"image",
            @"tiff": @"image", @"ico": @"image", @"car": @"image",
            @"mp3": @"media", @"wav": @"media", @"m4a": @"media", @"aac": @"media",
            @"aif": @"media", @"aiff": @"media", @"aifc": @"media", @"caf": @"media",
            @"m4b": @"media", @"m4p": @"media", @"m4r": @"media", @"flac": @"media",
            @"mov": @"media", @"mp4": @"media", @"m4v": @"media", @"3gp": @"media",
            @"avi": @"media", @"mkv": @"media",
            @"html": @"web", @"htm": @"web", @"url": @"web", @"webloc": @"web",
            @"hex": @"hex", @"dat": @"hex",
            @"ipa": @"installer",
            @"zip": @"archive", @"tar": @"archive", @"tar.gz": @"archive",
            @"tgz": @"archive", @"tar.bz2": @"archive", @"tbz": @"archive",
            @"tbz2": @"archive", @"tar.xz": @"archive", @"txz": @"archive",
            @"gz": @"archive", @"7z": @"archive", @"rar": @"archive",
            @"xz": @"archive", @"bz2": @"archive",

            // Word OOXML is the single intentional custom office reader.
            @"docx": @"docx", @"docm": @"docx", @"dotx": @"docx", @"dotm": @"docx",

            // Work documents that iOS already previews well stay on system Quick Look.
            @"pdf": @"quicklook",
            @"doc": @"quicklook", @"dot": @"quicklook", @"rtf": @"quicklook", @"rtfd": @"quicklook",
            @"xls": @"quicklook", @"xlsx": @"quicklook", @"xlsm": @"quicklook",
            @"xlsb": @"quicklook", @"xlt": @"quicklook", @"xltx": @"quicklook",
            @"xltm": @"quicklook", @"csv": @"quicklook", @"tsv": @"quicklook",
            @"ppt": @"quicklook", @"pptx": @"quicklook", @"pptm": @"quicklook",
            @"pps": @"quicklook", @"ppsx": @"quicklook", @"ppsm": @"quicklook",
            @"pot": @"quicklook", @"potx": @"quicklook", @"potm": @"quicklook",
            @"pages": @"quicklook", @"numbers": @"quicklook", @"key": @"quicklook",
            @"odt": @"quicklook", @"ods": @"quicklook", @"odp": @"quicklook",
            @"fods": @"quicklook", @"wps": @"quicklook", @"et": @"quicklook",
            @"dps": @"quicklook", @"dif": @"quicklook", @"dbf": @"quicklook",
            @"slk": @"quicklook", @"sylk": @"quicklook",
        };
    });
    return table;
}

static NSString * const kFFAssociationOverridesKey = @"FFFileAssociations.overrides";
static NSString * const kFFRemovedOfficeReadingStatesKey = @"FFOfficeReadingStatesV1";

static BOOL FFIsDocxFamily(NSString *extension)
{
    static NSSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSSet setWithArray:@[@"docx", @"docm", @"dotx", @"dotm"]]; });
    return [set containsObject:extension.lowercaseString];
}

@implementation FFFileAssociationService

+ (instancetype)sharedService
{
    static FFFileAssociationService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [FFFileAssociationService new];

        // Old builds exposed a generic viewerID="office". It no longer exists.
        // Preserve the intentional Word reader only for Word OOXML; every other
        // old Office override migrates to system Quick Look.
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *stored = [defaults dictionaryForKey:kFFAssociationOverridesKey];
        if ([stored isKindOfClass:NSDictionary.class] && stored.count) {
            NSMutableDictionary *migrated = [stored mutableCopy];
            __block BOOL changed = NO;
            [stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                (void)stop;
                if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class] &&
                    [value isEqualToString:@"office"]) {
                    migrated[key] = FFIsDocxFamily(key) ? @"docx" : @"quicklook";
                    changed = YES;
                }
            }];
            if (changed) [defaults setObject:migrated forKey:kFFAssociationOverridesKey];
        }
        [defaults removeObjectForKey:kFFRemovedOfficeReadingStatesKey];
    });
    return service;
}

+ (NSString *)normalizedExtension:(NSString *)rawExtension
{
    NSMutableString *result = [rawExtension.lowercaseString mutableCopy];
    while ([result hasPrefix:@"."]) [result deleteCharactersInRange:NSMakeRange(0, 1)];
    return result ?: @"";
}

- (NSDictionary<NSString *, NSString *> *)overrides
{
    id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kFFAssociationOverridesKey];
    return [stored isKindOfClass:NSDictionary.class] ? stored : @{};
}

- (void)saveOverrides:(NSDictionary<NSString *, NSString *> *)overrides
{
    [NSUserDefaults.standardUserDefaults setObject:overrides forKey:kFFAssociationOverridesKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FFFileAssociationsDidChangeNotification object:nil];
    });
}

- (NSString *)viewerIDForFileName:(NSString *)fileName
{
    if (fileName.length == 0) return nil;
    NSString *lower = fileName.lowercaseString;
    for (NSUInteger i = 1; i < lower.length; i++) {
        if ([lower characterAtIndex:i] != '.') continue;
        NSString *suffix = [lower substringFromIndex:i + 1];
        if (!suffix.length) continue;
        NSString *override = self.overrides[suffix];
        if (override.length) return override;
        NSString *builtin = FFDefaultAssociations()[suffix];
        if (builtin.length) return builtin;
    }
    return nil;
}

- (NSString *)effectiveViewerIDForExtension:(NSString *)extension
{
    NSString *key = [FFFileAssociationService normalizedExtension:extension];
    if (!key.length) return nil;
    return self.overrides[key] ?: FFDefaultAssociations()[key];
}

- (BOOL)hasOverrideForExtension:(NSString *)extension
{
    return self.overrides[[FFFileAssociationService normalizedExtension:extension]] != nil;
}

- (void)setOverrideViewerID:(NSString *)viewerID forExtension:(NSString *)extension
{
    NSString *key = [FFFileAssociationService normalizedExtension:extension];
    if (!key.length || !viewerID.length) return;
    NSMutableDictionary *overrides = [self.overrides mutableCopy];
    overrides[key] = viewerID;
    [self saveOverrides:overrides];
}

- (void)removeOverrideForExtension:(NSString *)extension
{
    NSString *key = [FFFileAssociationService normalizedExtension:extension];
    NSMutableDictionary *overrides = [self.overrides mutableCopy];
    if (!overrides[key]) return;
    [overrides removeObjectForKey:key];
    [self saveOverrides:overrides];
}

- (NSArray<NSString *> *)allKnownExtensions
{
    NSMutableSet *all = [NSMutableSet setWithArray:FFDefaultAssociations().allKeys];
    [all addObjectsFromArray:self.overrides.allKeys];
    return [all.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (void)resetAllOverrides { [self saveOverrides:@{}]; }

@end
