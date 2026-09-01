#import "FFRootTabBarController.h"
#import "FFBrowserViewController.h"
#import "FFBookmarksViewController.h"
#import "FFTasksViewController.h"
#import "FFSettingsViewController.h"
#import "FFStorageEnvironment.h"
#import "FFFileTaskManager.h"

@interface FFRootTabBarController () <UITabBarControllerDelegate>
@end

@implementation FFRootTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;

    FFBrowserViewController *storage = [[FFBrowserViewController alloc] initWithPath:FFStorageRootPath()];
    storage.title = @"Documents";

    FFBookmarksViewController *favorites = [[FFBookmarksViewController alloc]
        initWithMode:FFBookmarksModeFavorites];
    favorites.title = @"收藏";

    FFBookmarksViewController *recent = [[FFBookmarksViewController alloc]
        initWithMode:FFBookmarksModeRecent];
    recent.title = @"最近";

    FFTasksViewController *tasks = [FFTasksViewController new];
    tasks.title = @"任务";

    FFSettingsViewController *settings = [FFSettingsViewController new];
    settings.title = @"设置";

    NSArray<UIViewController *> *roots = @[storage, favorites, recent, tasks, settings];
    NSArray<NSString *> *titles = @[@"文件", @"收藏", @"最近", @"任务", @"设置"];
    NSArray<NSString *> *symbols = @[@"folder", @"star", @"clock", @"arrow.triangle.2.circlepath", @"gearshape"];
    NSMutableArray<UINavigationController *> *controllers = [NSMutableArray arrayWithCapacity:roots.count];

    [roots enumerateObjectsUsingBlock:^(UIViewController *root, NSUInteger idx, BOOL *stop) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
        nav.navigationBar.translucent = NO;
        nav.navigationBar.prefersLargeTitles = NO;
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:titles[idx]
            image:[UIImage systemImageNamed:symbols[idx]] selectedImage:nil];
        [controllers addObject:nav];
    }];
    self.viewControllers = controllers;

    UITabBarAppearance *appearance = [UITabBarAppearance new];
    [appearance configureWithDefaultBackground];
    self.tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) self.tabBar.scrollEdgeAppearance = appearance;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fileTasksChanged:)
        name:FFFileTaskManagerDidChangeNotification object:nil];
    [self updateTaskBadge];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)fileTasksChanged:(NSNotification *)note
{
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateTaskBadge]; });
}

- (void)updateTaskBadge
{
    if (self.viewControllers.count <= 3) return;
    NSUInteger active = 0;
    for (FFFileTask *task in FFFileTaskManager.sharedManager.tasks) {
        if (task.state == FFFileTaskStateQueued || task.state == FFFileTaskStateRunning) active++;
    }
    UITabBarItem *item = self.viewControllers[3].tabBarItem;
    item.badgeValue = active > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)active] : nil;
    item.accessibilityValue = active > 0
        ? [NSString stringWithFormat:@"%lu 个任务进行中", (unsigned long)active] : nil;
}

- (UINavigationController *)activeNavigationController
{
    UIViewController *selected = self.selectedViewController;
    return [selected isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)selected : nil;
}

@end