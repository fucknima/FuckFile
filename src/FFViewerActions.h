#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Shared trailing navigation items for file viewers: 分享 / 文件信息 /
// 移到回收站. Viewers that already carry their own ⋯ menu append only the
// share item; read-only viewers append the whole actions menu.
@interface FFViewerActions : NSObject

// ⋯ menu with 分享, 文件信息 and (optionally) 移到回收站.
+ (UIBarButtonItem *)actionsItemForPath:(NSString *)path
                                  title:(nullable NSString *)title
                                   icon:(nullable UIImage *)icon
                              presenter:(UIViewController *)presenter
                             allowTrash:(BOOL)allowTrash;

// Single share glyph for viewers that already have a ⋯ menu of their own.
+ (UIBarButtonItem *)shareItemForPath:(NSString *)path
                            presenter:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
