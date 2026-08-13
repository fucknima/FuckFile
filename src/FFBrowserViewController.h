#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) BOOL isSymlink;
@property(nonatomic, copy) NSString *linkTarget;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *fullDetail;
@property(nonatomic) unsigned long long size;
@property(nonatomic, strong) NSDate *modificationDate;
@property(nonatomic, strong) NSDate *creationDate;
@property(nonatomic) mode_t mode;
@property(nonatomic) uid_t uid;
@property(nonatomic) gid_t gid;
@property(nonatomic, strong) UIImage *thumbnail;
@end

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
