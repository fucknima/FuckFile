#import "FFAppNames.h"

@interface NSObject (FFAppNameLaunchServices)
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
@end

// LaunchServices store display names (bundle id -> localized name).
// Populated by MCMManager from the com.apple.lsd container; this is the
// only source that covers third-party apps on iOS 26.
static NSMutableDictionary<NSString *, NSString *> *FFStoreNames(void);

static NSDictionary<NSString *, NSString *> *FFKnownAppNames(void)
{
    static NSDictionary<NSString *, NSString *> *map;    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"com.apple.mobilesafari": @"Safari",
            @"com.apple.MobileSMS": @"信息",
            @"com.apple.mobilephone": @"电话",
            @"com.apple.MobileMail": @"邮件",
            @"com.apple.Preferences": @"设置",
            @"com.apple.mobileslideshow": @"照片",
            @"com.apple.mobiletimer": @"时钟",
            @"com.apple.mobilecal": @"日历",
            @"com.apple.Maps": @"地图",
            @"com.apple.camera": @"相机",
            @"com.apple.mobileme.fmf1": @"查找",
            @"com.apple.AppStore": @"App Store",
            @"com.apple.Passbook": @"钱包",
            @"com.apple.Health": @"健康",
            @"com.apple.Music": @"音乐",
            @"com.apple.Podcasts": @"播客",
            @"com.apple.reminders": @"提醒事项",
            @"com.apple.notes": @"备忘录",
            @"com.apple.news": @"新闻",
            @"com.apple.stocks": @"股市",
            @"com.apple.compass": @"指南针",
            @"com.apple.weather": @"天气",
            @"com.apple.voice-memos": @"语音备忘录",
            @"com.apple.files": @"文件",
            @"com.apple.Translate": @"翻译",
            @"com.apple.Calculator": @"计算器",
            @"com.apple.mobileaddressbook": @"通讯录",
            @"com.apple.tv": @"视频",
            @"com.apple.mobilegarageband": @"库乐队",
            @"com.apple.iMovie": @"iMovie",
            @"com.apple.clips": @"可立拍",
            @"com.apple.mobileipod": @"音乐",
            @"com.apple.purplebuddy": @"设置助理",
            @"com.apple.springboard": @"SpringBoard",
            @"com.apple.Shazam": @"Shazam",
            @"com.apple.mobile.MobileHouseArrest": @"FuckFile",
        };
    });
    return map;
}

// LaunchServices workspace name cache built once per process. Workspace
// enumeration is hidden on iOS 26, but when it does answer the result is
// authoritative for third-party names.
static NSDictionary<NSString *, NSString *> *FFWorkspaceNames(void)
{
    static NSDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)]
            ? [workspaceClass defaultWorkspace] : nil;
        NSArray *applications = [workspace respondsToSelector:@selector(allApplications)]
            ? [workspace allApplications] : nil;
        for (id proxy in applications ?: @[]) {
            NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
                ? [proxy applicationIdentifier] : nil;
            if (!identifier && [proxy respondsToSelector:@selector(bundleIdentifier)])
                identifier = [proxy bundleIdentifier];
            if (![identifier isKindOfClass:NSString.class] || identifier.length == 0)
                continue;
            NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                ? [proxy localizedName] : nil;
            if ([name isKindOfClass:NSString.class] && name.length)
                names[identifier] = name;
        }
        cache = names;
    });
    return cache;
}

NSString *FFAppDisplayName(NSString *identifier)
{
    if (identifier.length == 0) return identifier;
    NSString *known = FFKnownAppNames()[identifier];
    if (known) return known;
    NSString *workspace = FFWorkspaceNames()[identifier];
    if (workspace) return workspace;
    NSString *storeName = FFStoreNames()[identifier];
    if (storeName) return storeName;
    NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
    if (parts.count >= 3 && [parts[1] isEqualToString:@"apple"]) {
        NSString *last = parts.lastObject;
        if (last.length) {
            NSString *capitalized = [last substringToIndex:1].uppercaseString;
            return [capitalized stringByAppendingString:[last substringFromIndex:1]];
        }
    }
    return identifier;
}

// LaunchServices store display names (bundle id -> localized name).
// Populated by MCMManager from the com.apple.lsd container; this is the
// only source that covers third-party apps on iOS 26.
static NSMutableDictionary<NSString *, NSString *> *FFStoreNames(void)
{
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

void FFAppNamesRegisterStoreNames(NSDictionary<NSString *, NSString *> *names)
{
    @synchronized (FFStoreNames()) {
        [FFStoreNames() addEntriesFromDictionary:names];
    }
}

NSString *FFAppContainerItemName(NSString *containerPath)
{
    NSString *metadataPath = [containerPath stringByAppendingPathComponent:
        @"iTunesMetadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    NSString *name = [metadata[@"itemName"] isKindOfClass:NSString.class]
        ? metadata[@"itemName"] : nil;
    if (name.length) return name;
    metadataPath = [containerPath stringByAppendingPathComponent:
        @".iTunesMetadata.plist"];
    metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    name = [metadata[@"itemName"] isKindOfClass:NSString.class]
        ? metadata[@"itemName"] : nil;
    return name.length ? name : nil;
}

BOOL FFIsUUIDShapedName(NSString *name)
{
    if (name.length != 36) return NO;
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"-"];
    if (parts.count != 5) return NO;
    NSUInteger lengths[5] = {8, 4, 4, 4, 12};
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefABCDEF"];
    for (NSUInteger index = 0; index < 5; index++) {
        NSString *part = parts[index];
        if (part.length != lengths[index]) return NO;
        if ([part stringByTrimmingCharactersInSet:hex].length) return NO;
    }
    return YES;
}
