#import "FFAppDelegate.h"
#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "MCMManager.h"
#import "FFLogger.h"

@implementation FFAppDelegate

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
    FFLog(@"screen bounds=%@ native=%@ scale=%.2f",
        NSStringFromCGRect(UIScreen.mainScreen.bounds),
        NSStringFromCGRect(UIScreen.mainScreen.nativeBounds),
        UIScreen.mainScreen.scale);

    // Build the MCM virtual root on a background queue so the UI stays
    // responsive while leases are activated and links are created.
    // MHA is the only channel: the MCM start builds the virtual root
    // with class-2/7/10/12/13 direct lookups plus the full LaunchServices
    // store confirmation on a background queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFLog(@"MCM start begin");
        [[MCMManager sharedManager] start];
        FFLog(@"MCM start done");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"FFProbeFinished" object:nil];
        });
    });

    FFHomeViewController *root = [FFHomeViewController new];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:root];
    navigation.navigationBar.translucent = NO;
    navigation.navigationBar.prefersLargeTitles = YES;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    self.window.rootViewController = navigation;
    navigation.view.backgroundColor = [UIColor systemBackgroundColor];
    [self.window makeKeyAndVisible];
    FFLog(@"window frame=%@", NSStringFromCGRect(self.window.frame));
    FFLog(@"window root frame=%@", NSStringFromCGRect(navigation.view.frame));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            FFLog(@"layout window=%@ screen=%@ root=%@ safe=%@ nav=%@",
                NSStringFromCGRect(self.window.frame),
                NSStringFromCGRect(UIScreen.mainScreen.bounds),
                NSStringFromCGRect(navigation.view.frame),
                NSStringFromUIEdgeInsets(navigation.view.safeAreaInsets),
                NSStringFromCGRect(navigation.navigationBar.frame));
        });

    // 启动默认直接进入可访问的沙盒根（MCM 虚拟根），首页作为上层入口。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (navigation.topViewController != root) return;
            FFBrowserViewController *browser =
                [[FFBrowserViewController alloc] initWithPath:MCMVirtualRoot()];
            browser.title = @"文件";
            [navigation pushViewController:browser animated:NO];
        });

    // 冷启动经「打开方式」/分享进入：立即导入。系统的沙盒授权在
    // 启动后很快回收，延迟处理会报"没有权限"。
    NSURL *incoming = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (incoming) [self importIncomingFileURL:incoming];
    return YES;
}

#pragma mark - Incoming files（"打开方式" / AirDrop / 分享）

// 经典 AppDelegate 生命周期（无 Scene），系统直接回调本方法。
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    return [self importIncomingFileURL:url];
}

// 接收外部传入的文件：拷贝到 ~/Documents/Device Storage/Imported/
// （与 AppData 同级目录，重名自动加序号），成功后给出「前往查看」入口。
// 绝不原地打开外部路径。
- (BOOL)importIncomingFileURL:(NSURL *)url
{
    if (!url || !url.isFileURL) {
        FFLog(@"import REJECT non-file URL: %@", url);
        return NO;
    }
    // iOS 27 冷启动时同一 URL 会经 launchOptions 和 openURL: 各投递一次；
    // 第二次时 Inbox 源文件已被消费 → “no such file”。按路径去重。
    static NSMutableSet<NSString *> *handled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handled = [NSMutableSet set];
    });
    NSString *key = url.path;
    BOOL isNew = YES;
    @synchronized (handled) {
        isNew = ![handled containsObject:key];
        if (isNew) [handled addObject:key];
    }
    if (!isNew) {
        FFLog(@"import SKIP already handled: %@", key);
        return YES;
    }
    FFLog(@"import BEGIN url=%@", url.path);
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // 导入位置：Device Storage/Imported（与 AppData 同级，浏览器内可见）。
    NSString *importedDirectory = [[documents stringByAppendingPathComponent:
        @"Device Storage"] stringByAppendingPathComponent:@"Imported"];
    [[NSFileManager defaultManager] createDirectoryAtPath:importedDirectory
        withIntermediateDirectories:YES attributes:nil error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [url startAccessingSecurityScopedResource];
        NSString *name = url.lastPathComponent ?: @"imported";
        NSString *destination = [self importDestinationForName:name inDirectory:importedDirectory];
        NSError *error = nil;
        BOOL ok = NO;
        // 授权/Inbox 落盘可能有竞态：失败后退避重试，每次换新目标名。
        NSTimeInterval delays[] = {0, 0.5, 1.5, 3.0};
        for (NSUInteger attempt = 0; attempt < 4 && !ok; attempt++) {
            if (delays[attempt] > 0) [NSThread sleepForTimeInterval:delays[attempt]];
            error = nil;
            ok = [[NSFileManager defaultManager]
                copyItemAtPath:url.path toPath:destination error:&error];
            FFLog(@"import attempt %lu %@ (%@)", attempt + 1,
                ok ? @"OK" : @"FAIL", error.localizedDescription ?: @"");
            if (!ok && attempt < 3)
                destination = [self importDestinationForName:name
                                                 inDirectory:importedDirectory] ?: destination;
        }
        [url stopAccessingSecurityScopedResource];
        FFLog(@"import %@ -> %@ (%@)", ok ? @"OK" : @"FAIL", destination,
            error.localizedDescription ?: @"");
        NSString *finalDestination = destination;

        dispatch_async(dispatch_get_main_queue(), ^{
            UINavigationController *navigation =
                (UINavigationController *)self.window.rootViewController;
            if (!navigation) return;
            UIViewController *top =
                navigation.topViewController ?: navigation;

            if (!ok) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"接收文件"
                    message:[NSString stringWithFormat:@"导入失败：%@",
                        error.localizedDescription ?: @"无法读取来源文件"]
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好"
                    style:UIAlertActionStyleCancel handler:nil]];
                [top presentViewController:alert animated:YES completion:nil];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"接收文件"
                message:[NSString stringWithFormat:@"已导入：\n%@",
                    finalDestination.lastPathComponent]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"前往查看"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    FFBrowserViewController *browser =
                        [[FFBrowserViewController alloc] initWithPath:importedDirectory];
                    browser.title = @"Imported";
                    [navigation pushViewController:browser animated:YES];
                }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleCancel handler:nil]];
            if ([top isKindOfClass:UIAlertController.class]) return; // 已有弹窗时丢弃提示
            [top presentViewController:alert animated:YES completion:nil];
        });
    });
    return YES;
}

- (NSString *)importDestinationForName:(NSString *)name inDirectory:(NSString *)directory
{
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension.length ?
        [@"." stringByAppendingString:name.pathExtension] : @"";
    for (NSInteger index = 2; index < 1000; index++) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ (%ld)%@", base, (long)index, ext]];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

@end
