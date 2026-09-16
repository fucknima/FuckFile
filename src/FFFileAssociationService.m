#import "FFFileAssociationService.h"

NSString * const FFFileAssociationsDidChangeNotification =
    @"FFFileAssociationsDidChange";

// Built-in defaults. Keys are lowercase suffixes without the leading dot;
// compound keys like "tar.gz" participate in longest-suffix matching.
// .deb deliberately has no entry anywhere (no dedicated viewer, not an
// archive, never routed to zip).
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
            @"dylib": @"macho", @"so": @"macho",
            @"ipa": @"archive",
            @"zip": @"archive", @"tar": @"archive", @"tar.gz": @"archive",
            @"tgz": @"archive", @"tar.bz2": @"archive", @"tbz": @"archive",
            @"tbz2": @"archive", @"tar.xz": @"archive", @"txz": @"archive",
            @"gz": @"archive", @"7z": @"archive", @"rar": @"archive",
            @"xz": @"archive", @"bz2": @"archive",

            // Dedicated offline Office readers. Quick Look is no longer the
            // default route for Office formats; it remains a manual fallback.
            // The .docx family shares the unified office-document viewer so
            // fixed-layout zoom, search, page jump and selection behave the
            // same as .doc/.ppt/…; the older docx viewer stays registered as a
            // manual option.
            @"docx": @"office-document", @"docm": @"office-document",
            @"dotx": @"office-document", @"dotm": @"office-document",
            @"xls": @"spreadsheet", @"xlsx": @"spreadsheet", @"xlsm": @"spreadsheet",
            @"xlsb": @"spreadsheet", @"xlt": @"spreadsheet", @"xltx": @"spreadsheet",
            @"xltm": @"spreadsheet", @"csv": @"spreadsheet", @"tsv": @"spreadsheet",
            @"ods": @"spreadsheet", @"dif": @"spreadsheet", @"dbf": @"spreadsheet",
            @"slk": @"spreadsheet", @"sylk": @"spreadsheet",

            @"doc": @"office-document", @"dot": @"office-document",
            @"rtf": @"office-document", @"rtfd": @"office-document",
            @"odt": @"office-document", @"fodt": @"office-document", @"ott": @"office-document",
            @"ppt": @"office-document", @"pptx": @"office-document", @"pptm": @"office-document",
            @"pps": @"office-document", @"ppsx": @"office-document", @"ppsm": @"office-document",
            @"pot": @"office-document", @"potx": @"office-document", @"potm": @"office-document",
            @"odp": @"office-document", @"fodp": @"office-document", @"otp": @"office-document",
            @"fods": @"office-document", @"ots": @"office-document",
            @"pages": @"office-document", @"numbers": @"office-document", @"key": @"office-document",
            @"wps": @"office-document", @"wpt": @"office-document",
            @"et": @"office-document", @"ett": @"office-document",
            @"dps": @"office-document", @"dpt": @"office-document",

            // PDF remains a system preview by default; it is not part of the
            // Office migration and the app still offers the PDFKit reader.
            @"pdf": @"quicklook",
        };
    });
    return table;
}

static NSString * const kFFAssociationOverridesKey = @"FFFileAssociations.overrides";
static NSString * const kFFRemovedOfficeReadingStatesKey = @"FFOfficeReadingStatesV1";
static NSString * const kFFSpreadsheetViewerMigrationKey = @"FFSpreadsheetViewerMigrationV1";
static NSString * const kFFOfficeDocumentViewerMigrationKey = @"FFOfficeDocumentViewerMigrationV2";
static NSString * const kFFUnifiedWordViewerMigrationKey = @"FFUnifiedWordViewerMigrationV3";

static BOOL FFIsDocxFamily(NSString *extension)
{
    static NSSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSSet setWithArray:@[@"docx", @"docm", @"dotx", @"dotm"]]; });
    return [set containsObject:extension.lowercaseString];
}

static BOOL FFIsSpreadsheetFamily(NSString *extension)
{
    static NSSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"xls", @"xlsx", @"xlsm", @"xlsb", @"xlt", @"xltx", @"xltm",
            @"csv", @"tsv", @"ods", @"dif", @"dbf", @"slk", @"sylk",
        ]];
    });
    return [set containsObject:extension.lowercaseString];
}

static BOOL FFIsOfficeDocumentFamily(NSString *extension)
{
    static NSSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"doc", @"dot", @"rtf", @"rtfd", @"odt", @"fodt", @"ott",
            @"ppt", @"pptx", @"pptm", @"pps", @"ppsx", @"ppsm",
            @"pot", @"potx", @"potm", @"odp", @"fodp", @"otp",
            @"fods", @"ots", @"pages", @"numbers", @"key",
            @"wps", @"wpt", @"et", @"ett", @"dps", @"dpt",
        ]];
    });
    return [set containsObject:extension.lowercaseString];
}

@implementation FFFileAssociationService

+ (instancetype)sharedService
{
    static FFFileAssociationService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [FFFileAssociationService new];

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *stored = [defaults dictionaryForKey:kFFAssociationOverridesKey];
        NSMutableDictionary *migrated = [stored isKindOfClass:NSDictionary.class]
            ? [stored mutableCopy] : [NSMutableDictionary dictionary];
        __block BOOL changed = NO;

        // Older builds exposed viewerID="office". Re-map it to the current
        // dedicated readers instead of leaving stale entries pointing at a
        // removed viewer.
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class])
                return;
            NSString *extension = [(NSString *)key lowercaseString];
            // The IPA installer viewer was removed (ADR-019); .ipa files are
            // ZIP containers, so stale overrides fall back to the archive
            // browser instead of pointing at a missing viewer.
            if ([value isEqualToString:@"installer"]) {
                migrated[key] = @"archive";
                changed = YES;
                return;
            }
            if ([value isEqualToString:@"office"]) {
                if (FFIsSpreadsheetFamily(extension)) migrated[key] = @"spreadsheet";
                else if (FFIsDocxFamily(extension) || FFIsOfficeDocumentFamily(extension))
                    migrated[key] = @"office-document";
                else migrated[key] = @"quicklook";
                changed = YES;
            }
        }];

        // One-time adoption of the dedicated spreadsheet viewer. Old app
        // builds may have written Quick Look as an override during migration.
        if (![defaults boolForKey:kFFSpreadsheetViewerMigrationKey]) {
            for (NSString *key in [migrated.allKeys copy]) {
                if (FFIsSpreadsheetFamily(key) && [migrated[key] isEqualToString:@"quicklook"]) {
                    [migrated removeObjectForKey:key];
                    changed = YES;
                }
            }
            [defaults setBool:YES forKey:kFFSpreadsheetViewerMigrationKey];
        }

        // Build 821+: every Office document family now has an app-owned default
        // reader. Remove only legacy Quick Look overrides once so existing
        // installs actually adopt the new defaults. Users can still explicitly
        // choose Quick Look again afterwards if desired.
        if (![defaults boolForKey:kFFOfficeDocumentViewerMigrationKey]) {
            for (NSString *key in [migrated.allKeys copy]) {
                if (FFIsOfficeDocumentFamily(key) && [migrated[key] isEqualToString:@"quicklook"]) {
                    [migrated removeObjectForKey:key];
                    changed = YES;
                }
            }
            [defaults setBool:YES forKey:kFFOfficeDocumentViewerMigrationKey];
        }

        // Build 852+: the .docx family moved onto the unified Office viewer.
        // Drop stale explicit "docx" choices once so existing installs adopt
        // the new default; explicit choices made afterwards remain untouched.
        if (![defaults boolForKey:kFFUnifiedWordViewerMigrationKey]) {
            for (NSString *key in [migrated.allKeys copy]) {
                if (FFIsDocxFamily(key) && [migrated[key] isEqualToString:@"docx"]) {
                    [migrated removeObjectForKey:key];
                    changed = YES;
                }
            }
            [defaults setBool:YES forKey:kFFUnifiedWordViewerMigrationKey];
        }

        if (changed) [defaults setObject:migrated forKey:kFFAssociationOverridesKey];
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