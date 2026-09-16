#import "FFViewerActions.h"

#import "FFBrowserViewController.h"
#import "FFFileInfoViewController.h"
#import "FFLogger.h"
#import "FFPreviewRouter.h"
#import "FFTrashService.h"

@implementation FFViewerActions

+ (void)presentShareForPath:(NSString *)path
                   presenter:(UIViewController *)presenter
{
    if (!path.length) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = presenter.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(
        presenter.view.bounds.size.width - 30, 40, 1, 1);
    [presenter presentViewController:activity animated:YES completion:nil];
}

+ (void)presentInfoForPath:(NSString *)path
                     title:(nullable NSString *)title
                      icon:(nullable UIImage *)icon
                 presenter:(UIViewController *)presenter
{
    if (!path.length) return;
    FFEntry *entry = [FFEntry new];
    NSString *name = path.lastPathComponent;
    entry.name = name;
    entry.displayName = name;
    entry.path = path;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    entry.size = [attributes[NSFileSize] unsignedLongLongValue];
    entry.modificationDate = attributes[NSFileModificationDate];
    entry.creationDate = attributes[NSFileCreationDate];
    (void)title;
    FFFileInfoViewController *info = [[FFFileInfoViewController alloc] initWithEntry:entry icon:icon];
    UINavigationController *nav = presenter.navigationController;
    if (nav) [nav pushViewController:info animated:YES];
}

+ (void)confirmTrashForPath:(NSString *)path presenter:(UIViewController *)presenter
{
    if (!path.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"移到回收站"
        message:[NSString stringWithFormat:@"“%@” 将移到回收站，可在那里恢复。",
            path.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(presenter) weakPresenter = presenter;
    __weak UINavigationController *weakNav = presenter.navigationController;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移到回收站"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            NSUInteger moved = [FFTrashService.sharedService moveToTrash:@[path] firstError:&error];
            __strong UIViewController *strongPresenter = weakPresenter;
            if (!strongPresenter) return;
            if (moved == 0) {
                [FFPreviewRouter alertOnNav:strongPresenter.navigationController
                    title:@"操作失败" message:error.localizedDescription ?: @"无法移到回收站"];
                return;
            }
            FFLogTag(@"Viewer", @"moved to trash from viewer path=%@", path);
            [weakNav popViewControllerAnimated:YES];
        }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (UIBarButtonItem *)actionsItemForPath:(NSString *)path
                                  title:(nullable NSString *)title
                                   icon:(nullable UIImage *)icon
                              presenter:(UIViewController *)presenter
                             allowTrash:(BOOL)allowTrash
{
    __weak typeof(presenter) weakPresenter = presenter;
    UIAction *share = [UIAction actionWithTitle:@"分享"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
        handler:^(__unused UIAction *action) {
            __strong UIViewController *strongPresenter = weakPresenter;
            if (strongPresenter) [self presentShareForPath:path presenter:strongPresenter];
        }];
    UIAction *info = [UIAction actionWithTitle:@"文件信息"
        image:[UIImage systemImageNamed:@"info.circle"] identifier:nil
        handler:^(__unused UIAction *action) {
            __strong UIViewController *strongPresenter = weakPresenter;
            if (strongPresenter)
                [self presentInfoForPath:path title:title icon:icon presenter:strongPresenter];
        }];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithObjects:share, info, nil];
    if (allowTrash) {
        UIAction *trash = [UIAction actionWithTitle:@"移到回收站"
            image:[UIImage systemImageNamed:@"trash"] identifier:nil
            handler:^(__unused UIAction *action) {
                __strong UIViewController *strongPresenter = weakPresenter;
                if (strongPresenter)
                    [self confirmTrashForPath:path presenter:strongPresenter];
            }];
        trash.attributes = UIMenuElementAttributesDestructive;
        [items addObject:trash];
    }
    return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithChildren:items]];
}

+ (UIBarButtonItem *)shareItemForPath:(NSString *)path presenter:(UIViewController *)presenter
{
    __weak typeof(presenter) weakPresenter = presenter;
    UIAction *share = [UIAction actionWithTitle:@"分享"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
        handler:^(__unused UIAction *action) {
            __strong UIViewController *strongPresenter = weakPresenter;
            if (strongPresenter) [self presentShareForPath:path presenter:strongPresenter];
        }];
    return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
        primaryAction:share];
}

@end
