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
// App 数据容器（UUID 容器目录 / bundle-id 符号链接）：AppData 专有展示层级。
@property(nonatomic) BOOL isAppContainer;
@property(nonatomic, copy) NSString *containerIdentifier;
@end

// UIViewController + 自管 tableView：网格模式需要 tableView 与
// collectionView 作为平级兄弟视图切换显示；UITableViewController 的
// self.view 就是 tableView，子视图会随其隐藏而整体不可见（网格黑屏根因）。
@interface FFBrowserViewController : UIViewController

@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy, readonly) NSString *currentPath;

- (instancetype)initWithPath:(NSString *)path;

// Explicit refresh hook used when an already-open browser is reused instead
// of pushing another controller for the same directory.
- (void)reloadEntries;

// Opens an item: directories push a browser, files open the preview.
// nav is the caller's navigation controller (a fresh browser instance
// has none). Missing items call the completion with NO.
- (void)openItemAtPath:(NSString *)path title:(NSString *)title
             navigationController:(UINavigationController *)nav
            completion:(void (^ _Nullable)(BOOL available))completion;

@end

NS_ASSUME_NONNULL_END
