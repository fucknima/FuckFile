#import <UIKit/UIKit.h>
#import "FFAppDelegate.h"

// Keep every UINavigationBar background state identical during interactive
// push/pop transitions. FuckFile intentionally keeps the navigation bar
// non-translucent in FFAppDelegate because several custom controllers lay out
// content from view.topAnchor; changing that globally would move those views
// underneath the bar. The default standard/scroll-edge appearances can switch
// while an edge-swipe pop is in progress, which exposes a gray backdrop for a
// few frames. Pin all bar background states to the same dynamic system surface
// instead; iOS 26/27 still renders the UIBarButtonItems with their native glass
// treatment, while the large gray flash disappears.
static void FFConfigureNavigationBarAppearance(void)
{
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = UIColor.systemBackgroundColor;
        appearance.shadowColor = UIColor.clearColor;

        UINavigationBar *proxy = UINavigationBar.appearance;
        proxy.standardAppearance = appearance;
        proxy.scrollEdgeAppearance = appearance;
        proxy.compactAppearance = appearance;
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        FFConfigureNavigationBarAppearance();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FFAppDelegate class]));
    }
}
