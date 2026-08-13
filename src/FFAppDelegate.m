#import "FFAppDelegate.h"
#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "MCMManager.h"
#import "BadQueryProbe.h"
#import "FFLogger.h"

@implementation FFAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    FFLog(@"==== FuckFile launch ====");
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
    // responsive while leases are activated and links are created. The
    // bad_query probe runs right after, sharing the same queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFLog(@"BadQueryProbe run begin");
        BadQueryProbeRun();
        FFLog(@"BadQueryProbe run done");
        // bad_query sweep only contributes the UUID enumeration + index.
        FFLog(@"BadQueryEnumerate begin");
        BadQueryEnumerateAllContainers();
        FFLog(@"BadQueryEnumerate done");
        // Primary channel: MHA class-2 lookups open every discovered
        // container with a proper token and build the App Data links.
        FFLog(@"MCM start begin");
        [[MCMManager sharedManager] start];
        FFLog(@"MCM start done");
        // bad_query handles stay alive only as a browsing fallback for
        // containers the MHA route was denied.
        FFLog(@"BadQueryReconnect begin");
        BadQueryReconnectEscapedRoots();
        FFLog(@"BadQueryReconnect done");
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
    return YES;
}

@end
