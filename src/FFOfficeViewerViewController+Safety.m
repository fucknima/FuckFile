#import "FFOfficeViewerViewController.h"
#import "FFLogger.h"
#import "unzip.h"

#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString * const FFOfficeSafetyScheme = @"ffoffice";
static NSString * const FFOfficeSafetyHost = @"local";
static const void *kFFOfficeLoadGenerationKey = &kFFOfficeLoadGenerationKey;
static NSString * const kFFOfficeReadingStatesKey = @"FFOfficeReadingStatesV1";

static const unsigned long long kFFOfficeMaxCompressedBytes = 256ULL * 1024 * 1024;
static const unsigned long long kFFOfficeMaxExpandedBytes = 512ULL * 1024 * 1024;
static const unsigned long long kFFOfficeMaxEntryBytes = 192ULL * 1024 * 1024;
static const unsigned long long kFFOfficeRatioGuardMinBytes = 8ULL * 1024 * 1024;
static const double kFFOfficeMaxCompressionRatio = 300.0;
static const NSUInteger kFFOfficeMaxEntries = 20000;

@interface FFOfficeViewerViewController (FFSafetyPrivate)
- (void)loadOfficeDocument;
- (void)toggleFullScreen;
- (void)openQuickLook;
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message;
@end

static BOOL FFOfficeNeedsZipPreflight(NSString *path)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[
            @"docx",@"docm",@"dotx",@"dotm",
            @"pptx",@"pptm",@"ppsx",@"ppsm",@"potx",@"potm",
            @"xlsx",@"xlsm",@"xltx",@"xltm",@"ods"
        ]];
    });
    return [extensions containsObject:path.pathExtension.lowercaseString];
}

static NSString *FFOfficePreflightArchive(NSString *path)
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long compressedFile = [attrs[NSFileSize] unsignedLongLongValue];
    if (compressedFile == 0) return @"文件为空或无法读取";
    if (compressedFile > kFFOfficeMaxCompressedBytes)
        return @"压缩文件超过 256 MiB 安全上限，请使用系统快速查看";

    unzFile zip = unzOpen64(path.fileSystemRepresentation);
    if (!zip) return @"OOXML/ODS 文件不是有效的 ZIP 容器或已经损坏";

    unz_global_info64 global;
    memset(&global, 0, sizeof(global));
    if (unzGetGlobalInfo64(zip, &global) != UNZ_OK) {
        unzClose(zip);
        return @"无法读取 Office ZIP 中央目录";
    }
    if (global.number_entry > kFFOfficeMaxEntries) {
        unzClose(zip);
        return @"Office 文件内部条目超过 20000 个，已阻止渲染";
    }

    unsigned long long expanded = 0;
    NSUInteger count = 0;
    int rc = unzGoToFirstFile(zip);
    while (rc == UNZ_OK) {
        unz_file_info64 info;
        memset(&info, 0, sizeof(info));
        if (unzGetCurrentFileInfo64(zip, &info, NULL, 0, NULL, 0, NULL, 0) != UNZ_OK) {
            unzClose(zip);
            return @"Office ZIP 条目元数据损坏";
        }
        if (++count > kFFOfficeMaxEntries) {
            unzClose(zip);
            return @"Office 文件内部条目过多，已阻止渲染";
        }
        if (info.uncompressed_size > kFFOfficeMaxEntryBytes) {
            unzClose(zip);
            return @"Office 文件包含超过 192 MiB 的单个展开条目，已阻止渲染";
        }
        if (expanded > kFFOfficeMaxExpandedBytes - MIN(info.uncompressed_size, kFFOfficeMaxExpandedBytes)) {
            unzClose(zip);
            return @"Office 文件展开后超过 512 MiB 安全上限，已阻止渲染";
        }
        expanded += info.uncompressed_size;
        if (info.uncompressed_size >= kFFOfficeRatioGuardMinBytes) {
            double ratio = info.compressed_size == 0 ? DBL_MAX :
                (double)info.uncompressed_size / (double)info.compressed_size;
            if (ratio > kFFOfficeMaxCompressionRatio) {
                unzClose(zip);
                return @"Office 文件包含异常高压缩比条目，疑似 ZIP bomb，已阻止渲染";
            }
        }
        rc = unzGoToNextFile(zip);
    }
    unzClose(zip);
    if (rc != UNZ_END_OF_LIST_OF_FILE)
        return @"Office ZIP 中央目录遍历失败";
    return nil;
}

static NSMutableDictionary *FFOfficeReadingStates(void)
{
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kFFOfficeReadingStatesKey];
    return saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static NSDictionary *FFOfficeReadingStateForPath(NSString *path)
{
    if (!path.length) return nil;
    NSDictionary *row = FFOfficeReadingStates()[path.stringByStandardizingPath];
    return [row[@"state"] isKindOfClass:NSDictionary.class] ? row[@"state"] : nil;
}

static void FFOfficeSaveReadingState(NSString *path, NSDictionary *state)
{
    if (!path.length || ![state isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *all = FFOfficeReadingStates();
    NSString *key = path.stringByStandardizingPath;
    all[key] = @{ @"state":state, @"updated":@([NSDate date].timeIntervalSince1970) };
    if (all.count > 50) {
        NSArray *ordered = [all.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSNumber *av = [all[a][@"updated"] isKindOfClass:NSNumber.class] ? all[a][@"updated"] : @0;
            NSNumber *bv = [all[b][@"updated"] isKindOfClass:NSNumber.class] ? all[b][@"updated"] : @0;
            return [av compare:bv];
        }];
        while (all.count > 50 && ordered.count) {
            NSString *oldest = ordered[ordered.count - all.count];
            [all removeObjectForKey:oldest];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:all forKey:kFFOfficeReadingStatesKey];
}

static NSString *FFOfficeJSONString(NSDictionary *dictionary)
{
    if (!dictionary.count || ![NSJSONSerialization isValidJSONObject:dictionary]) return @"";
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

@implementation FFOfficeViewerViewController (Safety)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;
        SEL pairs[][2] = {
            {@selector(viewDidLoad), @selector(ff_safe_viewDidLoad)},
            {@selector(viewWillDisappear:), @selector(ff_safe_viewWillDisappear:)},
            {@selector(loadOfficeDocument), @selector(ff_safe_loadOfficeDocument)},
            {@selector(toggleFullScreen), @selector(ff_safe_toggleFullScreen)},
            {@selector(userContentController:didReceiveScriptMessage:),
             @selector(ff_safe_userContentController:didReceiveScriptMessage:)},
        };
        for (NSUInteger i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            Method a = class_getInstanceMethod(cls, pairs[i][0]);
            Method b = class_getInstanceMethod(cls, pairs[i][1]);
            if (a && b) method_exchangeImplementations(a, b);
        }
    });
}

- (NSString *)ff_safe_filePath
{
    id value = [self valueForKey:@"filePath"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (NSString *)ff_safe_officeKind
{
    id value = [self valueForKey:@"officeKind"];
    return [value isKindOfClass:NSString.class] ? value : @"unknown";
}

- (WKWebView *)ff_safe_webView
{
    id value = [self valueForKey:@"webView"];
    return [value isKindOfClass:WKWebView.class] ? value : nil;
}

- (BOOL)ff_safe_isFullScreen
{
    return [[self valueForKey:@"fullScreen"] boolValue];
}

- (void)ff_safe_viewDidLoad
{
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ff_officeMemoryWarning:)
        name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [self ff_safe_viewDidLoad];
}

- (void)ff_safe_viewWillDisappear:(BOOL)animated
{
    [self ff_safe_viewWillDisappear:animated];
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}

- (BOOL)prefersStatusBarHidden
{
    return [self ff_safe_isFullScreen];
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return [self ff_safe_isFullScreen];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures
{
    return [self ff_safe_isFullScreen] ? UIRectEdgeAll : UIRectEdgeNone;
}

- (void)ff_safe_toggleFullScreen
{
    [self ff_safe_toggleFullScreen];
    [UIView animateWithDuration:0.2 animations:^{
        [self setNeedsStatusBarAppearanceUpdate];
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self.view layoutIfNeeded];
    }];
}

- (void)ff_officeMemoryWarning:(__unused NSNotification *)notification
{
    [[self ff_safe_webView] evaluateJavaScript:
        @"window.ffOfficeMemoryWarning && window.ffOfficeMemoryWarning()"
        completionHandler:nil];
}

- (void)ff_safe_loadOfficeDocument
{
    NSString *path = [self ff_safe_filePath];
    NSNumber *old = objc_getAssociatedObject(self, kFFOfficeLoadGenerationKey);
    NSUInteger generation = old.unsignedIntegerValue + 1;
    objc_setAssociatedObject(self, kFFOfficeLoadGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = FFOfficeNeedsZipPreflight(path) ? FFOfficePreflightArchive(path) : nil;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        NSDictionary *restore = FFOfficeReadingStateForPath(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([objc_getAssociatedObject(strongSelf, kFFOfficeLoadGenerationKey) unsignedIntegerValue] != generation)
                return;
            if (failure.length) {
                FFLogTag(@"Office", @"preflight blocked path=%@ reason=%@", path, failure);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Office 安全检查未通过"
                    message:failure preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"系统快速查看"
                    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                        [strongSelf openQuickLook];
                    }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [strongSelf presentViewController:alert animated:YES completion:nil];
                return;
            }

            NSURLComponents *components = [NSURLComponents new];
            components.scheme = FFOfficeSafetyScheme;
            components.host = FFOfficeSafetyHost;
            components.path = @"/index.html";
            NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithArray:@[
                [NSURLQueryItem queryItemWithName:@"kind" value:[strongSelf ff_safe_officeKind]],
                [NSURLQueryItem queryItemWithName:@"name" value:path.lastPathComponent ?: @"document"],
                [NSURLQueryItem queryItemWithName:@"title" value:strongSelf.title ?: path.lastPathComponent],
                [NSURLQueryItem queryItemWithName:@"bytes" value:[NSString stringWithFormat:@"%llu", size]],
            ]];
            NSString *restoreJSON = FFOfficeJSONString(restore);
            if (restoreJSON.length) [items addObject:[NSURLQueryItem queryItemWithName:@"restore" value:restoreJSON]];
            components.queryItems = items;
            FFLogTag(@"Office", @"preflight OK kind=%@ path=%@ size=%llu restore=%d",
                [strongSelf ff_safe_officeKind], path, size, restoreJSON.length > 0);
            [[strongSelf ff_safe_webView] loadRequest:[NSURLRequest requestWithURL:components.URL
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0]];
        });
    });
}

- (void)ff_safe_userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if ([message.name isEqualToString:@"ffOffice"] && [message.body isKindOfClass:NSDictionary.class]) {
        NSDictionary *body = message.body;
        NSString *type = [body[@"type"] isKindOfClass:NSString.class] ? body[@"type"] : @"";
        if ([type isEqualToString:@"state"] && [body[@"state"] isKindOfClass:NSDictionary.class]) {
            FFOfficeSaveReadingState([self ff_safe_filePath], body[@"state"]);
            return;
        }
    }
    [self ff_safe_userContentController:userContentController didReceiveScriptMessage:message];
}

@end
