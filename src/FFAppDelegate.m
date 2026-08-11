#import "FFAppDelegate.h"
#import "FFBrowserViewController.h"
#import "MCMManager.h"

@implementation FFAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Build the MCM virtual root on a background queue so the UI stays
    // responsive while leases are activated and links are created.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [[MCMManager sharedManager] start];
    });

    FFBrowserViewController *root = [[FFBrowserViewController alloc]
        initWithPath:MCMVirtualRoot()];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:root];
    navigation.navigationBar.translucent = NO;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
