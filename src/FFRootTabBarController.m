#import "FFRootTabBarController.h"
#import "FFBrowserViewController.h"
#import "FFMainSplitViewController.h"
#import "FFTasksViewController.h"
#import "FFSettingsViewController.h"
#import "FFStorageEnvironment.h"
#import "FFFileTaskManager.h"

@interface FFRootTabBarController () <UITabBarControllerDelegate>
@property(nonatomic, strong) UIButton *taskPill;
@property(nonatomic, strong) NSLayoutConstraint *taskPillBottomConstraint;
@end

@implementation FFRootTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;

    // iPad uses a two-column shell (locations sidebar + browser) inside the
    // 文件 tab; iPhone keeps the single-column browser. The tab bar and task
    // pill stay identical on both.
    UIViewController *storage = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? (UIViewController *)[FFMainSplitViewController new]
        : (UIViewController *)[[FFBrowserViewController alloc] initWithPath:FFStorageRootPath()];
    storage.title = @"文件";

    FFSettingsViewController *settings = [FFSettingsViewController new];
    settings.title = @"设置";

    NSArray<UIViewController *> *roots = @[storage, settings];
    NSArray<NSString *> *titles = @[@"文件", @"设置"];
    NSArray<NSString *> *symbols = @[@"folder", @"gearshape"];
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray arrayWithCapacity:roots.count];

    [roots enumerateObjectsUsingBlock:^(UIViewController *root, NSUInteger idx, BOOL *stop) {
        (void)stop;
        UIViewController *tabRoot = root;
        if (![root isKindOfClass:FFMainSplitViewController.class]) {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
            nav.navigationBar.translucent = NO;
            nav.navigationBar.prefersLargeTitles = NO;
            tabRoot = nav;
        }
        tabRoot.tabBarItem = [[UITabBarItem alloc] initWithTitle:titles[idx]
            image:[UIImage systemImageNamed:symbols[idx]] selectedImage:nil];
        [controllers addObject:tabRoot];
    }];
    self.viewControllers = controllers;

    UITabBarAppearance *appearance = [UITabBarAppearance new];
    [appearance configureWithDefaultBackground];
    self.tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) self.tabBar.scrollEdgeAppearance = appearance;

    // 任务只在运行时出现：底部胶囊显示进度/数量，点开是任务中心。
    // 不再占用一个常驻 tab（95% 时间是空的）。
    // 经典 UIButton API：不依赖 UIButtonConfiguration 的 SDK 差异。
    self.taskPill = [UIButton buttonWithType:UIButtonTypeSystem];
    self.taskPill.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.taskPill.tintColor = UIColor.labelColor;
    self.taskPill.layer.cornerRadius = 19;
    self.taskPill.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 16);
    self.taskPill.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    [self.taskPill setImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
        forState:UIControlStateNormal];
    [self.taskPill setTitle:@"任务" forState:UIControlStateNormal];
    self.taskPill.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
    self.taskPill.translatesAutoresizingMaskIntoConstraints = NO;
    self.taskPill.hidden = YES;
    self.taskPill.layer.shadowColor = UIColor.blackColor.CGColor;
    self.taskPill.layer.shadowOpacity = 0.18;
    self.taskPill.layer.shadowRadius = 10;
    self.taskPill.layer.shadowOffset = CGSizeMake(0, 3);
    [self.taskPill addTarget:self action:@selector(showTasks) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.taskPill];
    [NSLayoutConstraint activateConstraints:@[
        [self.taskPill.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.taskPill.heightAnchor constraintGreaterThanOrEqualToConstant:38],
    ]];
    // tabBar 采用 scrollEdgeAppearance 时高度随内容变化，用安全区底部锚定，
    // 视觉上始终贴在 tabBar 上方。
    self.taskPillBottomConstraint = [self.taskPill.bottomAnchor
        constraintEqualToAnchor:self.tabBar.topAnchor constant:-10];
    self.taskPillBottomConstraint.active = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fileTasksChanged:)
        name:FFFileTaskManagerDidChangeNotification object:nil];
    [self updateTaskPill];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.taskPill];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)fileTasksChanged:(NSNotification *)note
{
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateTaskPill]; });
}

- (void)updateTaskPill
{
    NSUInteger active = 0;
    NSUInteger total = 0;
    FFFileTask *current = nil;
    for (FFFileTask *task in FFFileTaskManager.sharedManager.tasks) {
        if (task.state == FFFileTaskStateQueued || task.state == FFFileTaskStateRunning) {
            active++;
            if (!current && task.state == FFFileTaskStateRunning) current = task;
        }
        if (task.state == FFFileTaskStateQueued || task.state == FFFileTaskStateRunning ||
            task.state == FFFileTaskStateFailed || task.state == FFFileTaskStateCompleted) total++;
    }
    (void)total;

    self.taskPill.hidden = active == 0;
    if (active == 0) return;
    NSString *title = current.displayName.length
        ? [NSString stringWithFormat:@"%lu 个任务 · %@", (unsigned long)active, current.displayName]
        : [NSString stringWithFormat:@"%lu 个任务", (unsigned long)active];
    [self.taskPill setTitle:title forState:UIControlStateNormal];
    self.taskPill.accessibilityLabel = title;
}

- (void)showTasks
{
    FFTasksViewController *tasks = [FFTasksViewController new];
    tasks.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(dismissTasks)];
    // 点已完成任务：关掉任务中心，切到文件 tab 并跳到落盘位置。
    __weak typeof(self) weakSelf = self;
    tasks.revealHandler = ^(NSString *path) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf dismissViewControllerAnimated:YES completion:^{
            [strongSelf revealPathInBrowser:path];
        }];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:tasks];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

// 打开 path 所在目录；是文件则滚动定位并短暂高亮。已在浏览栈里的同目录
// 页面优先复用（与导入结果跳转一致），否则新 push 一个浏览器。
- (void)revealPathInBrowser:(NSString *)path
{
    if (!path.length) return;
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]) return;
    NSString *directory = isDirectory ? path : path.stringByDeletingLastPathComponent;
    if (!directory.length) return;

    self.selectedIndex = 0;
    UINavigationController *nav = [self activeNavigationController];
    if (!nav) return;
    NSString *target = directory.stringByStandardizingPath;
    FFBrowserViewController *existing = nil;
    for (UIViewController *controller in nav.viewControllers) {
        if (![controller isKindOfClass:FFBrowserViewController.class]) continue;
        FFBrowserViewController *browser = (FFBrowserViewController *)controller;
        if ([browser.currentPath.stringByStandardizingPath isEqualToString:target]) {
            existing = browser;
            break;
        }
    }
    NSString *revealPath = isDirectory ? nil : path;
    if (existing) {
        existing.pendingRevealPath = revealPath;
        if (nav.topViewController != existing) [nav popToViewController:existing animated:YES];
        [existing reloadEntries];
        return;
    }
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:directory];
    browser.title = directory.lastPathComponent.length ? directory.lastPathComponent : @"文件";
    browser.pendingRevealPath = revealPath;
    [nav pushViewController:browser animated:YES];
}

- (void)dismissTasks
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UINavigationController *)activeNavigationController
{
    UIViewController *selected = self.selectedViewController;
    if ([selected isKindOfClass:FFMainSplitViewController.class])
        return [(FFMainSplitViewController *)selected activeNavigationController];
    return [selected isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)selected : nil;
}

@end
