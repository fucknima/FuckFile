#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFBrowserViewController : UITableViewController

- (instancetype)initWithPath:(NSString *)path;

// Opens an item: directories push a browser, files open the preview.
// nav is the caller's navigation controller (a fresh browser instance
// has none). Missing items call the completion with NO.
- (void)openItemAtPath:(NSString *)path title:(NSString *)title
             navigationController:(UINavigationController *)nav
            completion:(void (^ _Nullable)(BOOL available))completion;

@end

NS_ASSUME_NONNULL_END
