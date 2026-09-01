#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FFEntry;

// Preview routing shared by the browser, search, favorites and recents.
// Every preview is pushed onto the navigation controller passed by the
// caller — no detached view controller instances are created.
//
// Resolution order:
//   1. user override association (FFFileAssociationService)
//   2. built-in default association
//   3. viewer availability check + open (FFViewerRegistry)
//   4. content detection fallback (plist → text → Quick Look → hex)
// The router holds no extension-name if/else chains: extension knowledge
// lives in FFFileAssociationService, capabilities in FFViewerRegistry.
@interface FFPreviewRouter : NSObject

// Pushes the appropriate preview for the item onto nav. Always pushes
// something (association hit or fallback), so it returns YES unless the
// item itself is unusable.
+ (BOOL)previewItem:(FFEntry *)item navigationController:(UINavigationController *)nav;

// Explicitly opens with one registered viewer (context-menu actions like
// 安装 / 浏览压缩包 / 用其他查看器打开). Returns NO when unavailable.
+ (BOOL)openItem:(FFEntry *)item viewerID:(NSString *)viewerID
navigationController:(UINavigationController *)nav;

// Text/plist/hex viewer with a share button (used by previewData).
+ (void)presentText:(NSString *)title body:(NSString *)body
    navigationController:(UINavigationController *)nav;

// Shared feedback helpers (also used by registry-driven viewers).
+ (void)alertOnNav:(UINavigationController *)nav title:(nullable NSString *)title
           message:(NSString *)message;
+ (void)toastOnNav:(UINavigationController *)nav message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
