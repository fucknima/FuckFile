#import "FFAppDelegate.h"
#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFImportService.h"
#import "FFSharedInboxService.h"
#import "FFShareBridge.h"
#import "FFSystemAccessManager.h"
#import "MCMManager.h"
#import "FFLogger.h"

static const NSTimeInterval kFFImportDedupTTL = 5.0;

@interface FFAppDelegate ()
@property(nonatomic, strong) NSMutableSet<NSString *> *inFlightImports;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentImports;
@end

@implementation FFAppDelegate

- (instancetype)init
{
    self = [super init];
    if (self) {
        _inFlightImports = [NSMutableSet set];
        _recentImports = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    FFLog(@"==== FuckFile launch ====");
    FFLog(@"build=%s %s", __DATE__, __TIME__);
    FFLog(@"device=%@ iOS=%@ build=%@ bundle=%@ log=%@",
        UIDevice.currentDevice.model,
        UIDevice.currentDevice.systemVersion,
        [NSProcessInfo processInfo].operatingSystemVersionString,
        NSBundle.mainBundle.bundleIdentifier ?: @"nil",
        FFLogPath());
    FFLog(@"required MCM identity=com.apple.mobile.MobileHouseArrest match=%d",
        [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.mobile.MobileHouseArrest"]);

    FFHomeViewController *root = [FFHomeViewController new];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:root];
    navigation.navigationBar.translucent = NO;
    navigation.navigationBar.prefersLargeTitles = NO;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = navigation;
    navigation.view.backgroundColor = UIColor.systemBackgroundColor;
    [self.window makeKeyAndVisible];

    // Advanced system access is opt-in. A normal launch must not initialize
    // the MCM bypass path at all. If enabled, load it in the background and
    // retry the shared inbox after the leases become available.
    [FFSystemAccessManager.sharedManager loadIfEnabledWithCompletion:^(BOOL loaded) {
        if (!loaded) return;
        [self processSharedInboxShowingResult:NO];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"FFProbeFinished" object:nil];
    }];

    // App Group based sharing remains available in normal mode. The MCM-backed
    // fallback is only retried after advanced system access is loaded above.
    [self processSharedInboxShowingResult:NO];

    NSURL *incoming = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (incoming) {
        FFLogTag(@"Import", @"launchOptions file=%@", incoming.path);
        [self importIncomingFileURL:incoming];
    }
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    [self processSharedInboxShowingResult:NO];
}

#pragma mark - Incoming URLs

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    if ([[url.scheme lowercaseString] isEqualToString:[FFShareWakeScheme lowercaseString]]) {
        FFLogTag(@"ShareInbox", @"wake URL received=%@", url.absoluteString);
        [self processSharedInboxShowingResult:YES];
        return YES;
    }

    if (!url.isFileURL) {
        FFLogTag(@"Import", @"reject non-file URL=%@", url.absoluteString);
        return NO;
    }

    BOOL openInPlace = [options[UIApplicationOpenURLOptionsOpenInPlaceKey] boolValue];
    NSString *sourceApp = options[UIApplicationOpenURLOptionsSourceApplicationKey];
    FFLogTag(@"Import", @"openURL file=%@ openInPlace=%d sourceApp=%@",
        url.path, openInPlace, sourceApp ?: @"?");
    return [self importIncomingFileURL:url];
}

#pragma mark - File import

- (void)pruneRecentImports
{
    NSDate *now = NSDate.date;
    NSMutableArray<NSString *> *expired = [NSMutableArray array];
    for (NSString *key in self.recentImports) {
        if ([now timeIntervalSinceDate:self.recentImports[key]] >= kFFImportDedupTTL)
            [expired addObject:key];
    }
    [self.recentImports removeObjectsForKeys:expired];
}

- (BOOL)importIncomingFileURL:(NSURL *)url
{
    if (!url || !url.isFileURL) return NO;
    NSString *key = url.absoluteString ?: url.path;

    @synchronized (self.inFlightImports) {
        [self pruneRecentImports];
        if ([self.inFlightImports containsObject:key]) {
            FFLogTag(@"Import", @"skip in-flight=%@", key);
            return YES;
        }
        NSDate *recent = self.recentImports[key];
        if (recent && [NSDate.date timeIntervalSinceDate:recent] < kFFImportDedupTTL) {
            FFLogTag(@"Import", @"skip recent success=%@", key);
            return YES;
        }
        [self.inFlightImports addObject:key];
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *importedDirectory = [[documents stringByAppendingPathComponent:
        @"Device Storage"] stringByAppendingPathComponent:@"Imported"];
    NSError *mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:importedDirectory
        withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        @synchronized (self.inFlightImports) {
            [self.inFlightImports removeObject:key];
        }
        [self presentImportFailure:mkdirError];
        return NO;
    }

    FFLogTag(@"Import", @"BEGIN source=%@", url.path);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFImportResult *result = [FFImportService importURL:url
            displayName:nil toDirectory:importedDirectory];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            @synchronized (strongSelf.inFlightImports) {
                [strongSelf.inFlightImports removeObject:key];
                if (result.success) strongSelf.recentImports[key] = NSDate.date;
            }
            if (result.success)
                [strongSelf presentImportSuccess:result.destinationPath];
            else
                [strongSelf presentImportFailure:result.error];
        });
    });
    return YES;
}

#pragma mark - Shared extension inbox

- (void)processSharedInboxShowingResult:(BOOL)showResult
{
    [FFSharedInboxService processPendingWithCompletion:^(NSUInteger imported,
        NSArray<NSString *> *destinations, NSArray<NSError *> *errors) {
        if (imported == 0 && errors.count == 0) return;
        FFLogTag(@"ShareInbox", @"drain imported=%lu errors=%lu",
            (unsigned long)imported, (unsigned long)errors.count);
        if (!showResult && imported == 0) return;

        UINavigationController *navigation =
            (UINavigationController *)self.window.rootViewController;
        UIViewController *top = navigation.topViewController ?: navigation;
        if (!top || [top isKindOfClass:UIAlertController.class]) return;

        NSString *message = nil;
        if (imported > 0 && errors.count == 0) {
            message = [NSString stringWithFormat:@"已导入 %lu 个共享文件。",
                (unsigned long)imported];
        } else if (imported > 0) {
            message = [NSString stringWithFormat:@"已导入 %lu 个文件，%lu 个失败：%@",
                (unsigned long)imported, (unsigned long)errors.count,
                errors.firstObject.localizedDescription ?: @"未知错误"];
        } else {
            message = [NSString stringWithFormat:@"共享文件导入失败：%@",
                errors.firstObject.localizedDescription ?: @"未知错误"];
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"接收文件"
            message:message preferredStyle:UIAlertControllerStyleAlert];
        if (destinations.count) {
            [alert addAction:[UIAlertAction actionWithTitle:@"前往查看"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    NSString *directory = destinations.firstObject.stringByDeletingLastPathComponent;
                    [self showImportedDirectory:directory navigationController:navigation];
                }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"好"
            style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    }];
}

#pragma mark - Imported-folder navigation

- (void)showImportedDirectory:(NSString *)directory
         navigationController:(UINavigationController *)navigation
{
    if (!directory.length || !navigation) return;
    NSString *target = directory.stringByStandardizingPath;
    FFBrowserViewController *existing = nil;

    for (UIViewController *controller in navigation.viewControllers) {
        if (![controller isKindOfClass:FFBrowserViewController.class]) continue;
        FFBrowserViewController *browser = (FFBrowserViewController *)controller;
        NSString *path = browser.currentPath.stringByStandardizingPath;
        if ([path isEqualToString:target]) {
            existing = browser;
            break;
        }
    }

    if (existing) {
        FFLogTag(@"ImportUI", @"reuse Imported browser path=%@", target);
        [existing reloadEntries];
        if (navigation.topViewController != existing)
            [navigation popToViewController:existing animated:YES];
        return;
    }

    FFLogTag(@"ImportUI", @"push Imported browser path=%@", target);
    FFBrowserViewController *browser = [[FFBrowserViewController alloc]
        initWithPath:target];
    browser.title = @"Imported";
    [navigation pushViewController:browser animated:YES];
}

#pragma mark - Import result UI

- (UIViewController *)topViewController
{
    UINavigationController *navigation =
        (UINavigationController *)self.window.rootViewController;
    return navigation.topViewController ?: navigation;
}

- (void)presentImportFailure:(NSError *)error
{
    UIViewController *top = [self topViewController];
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"接收文件"
        message:[NSString stringWithFormat:@"导入失败：%@",
            error.localizedDescription ?: @"无法读取来源文件"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

- (void)presentImportSuccess:(NSString *)destination
{
    if (!destination.length) return;
    UINavigationController *navigation =
        (UINavigationController *)self.window.rootViewController;
    UIViewController *top = navigation.topViewController ?: navigation;
    if (!top || [top isKindOfClass:UIAlertController.class]) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"接收文件"
        message:[NSString stringWithFormat:@"已导入：\n%@", destination.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"前往查看"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self showImportedDirectory:destination.stringByDeletingLastPathComponent
                   navigationController:navigation];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

@end
