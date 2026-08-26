#import "FFRootTabBarController.h"
#import "FFBrowserViewController.h"
#import "FFBookmarksViewController.h"
#import "FFTasksViewController.h"
#import "FFSettingsViewController.h"
#import "FFSearchViewController.h"
#import "FFStorageEnvironment.h"

@interface FFRootTabBarController () <UITabBarControllerDelegate>
@property(nonatomic, strong) UIVisualEffectView *searchChrome;
@property(nonatomic, strong) UIButton *searchButton;
@end

@implementation FFRootTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;

    FFBrowserViewController *storage = [[FFBrowserViewController alloc] initWithPath:FFStorageRootPath()];
    storage.title = @"Device Storage";

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

    [self installSearchChrome];
    [self updateSearchClearance];
}

- (void)installSearchChrome
{
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    self.searchChrome = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.searchChrome.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchChrome.layer.cornerRadius = 22.0;
    self.searchChrome.layer.cornerCurve = kCACornerCurveContinuous;
    self.searchChrome.clipsToBounds = YES;

    self.searchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.searchButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.searchButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    self.searchButton.tintColor = UIColor.secondaryLabelColor;
    [self.searchButton setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateNormal];
    [self.searchButton setImage:[UIImage systemImageNamed:@"magnifyingglass"] forState:UIControlStateNormal];
    [self.searchButton setTitle:@"  搜索文件与 App Data" forState:UIControlStateNormal];
    self.searchButton.accessibilityLabel = @"全局搜索";
    [self.searchButton addTarget:self action:@selector(searchTapped) forControlEvents:UIControlEventTouchUpInside];

    [self.searchChrome.contentView addSubview:self.searchButton];
    [self.view addSubview:self.searchChrome];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchChrome.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.searchChrome.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.searchChrome.bottomAnchor constraintEqualToAnchor:self.tabBar.topAnchor constant:-10],
        [self.searchChrome.heightAnchor constraintEqualToConstant:44],
        [self.searchButton.leadingAnchor constraintEqualToAnchor:self.searchChrome.contentView.leadingAnchor constant:14],
        [self.searchButton.trailingAnchor constraintEqualToAnchor:self.searchChrome.contentView.trailingAnchor constant:-10],
        [self.searchButton.topAnchor constraintEqualToAnchor:self.searchChrome.contentView.topAnchor],
        [self.searchButton.bottomAnchor constraintEqualToAnchor:self.searchChrome.contentView.bottomAnchor],
    ]];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.searchChrome];
    [self updateSearchClearance];
}

- (void)updateSearchClearance
{
    // Tab bar already reserves its own height. This extra inset reserves only
    // the floating search pill + gap, keeping lists/grids tappable behind it.
    CGFloat extra = 64.0;
    for (UIViewController *controller in self.viewControllers) {
        controller.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, extra, 0);
    }
}

- (void)searchTapped
{
    UINavigationController *nav = [self activeNavigationController];
    if (!nav) return;
    if ([nav.topViewController isKindOfClass:FFSearchViewController.class]) return;
    FFSearchViewController *search = [FFSearchViewController new];
    search.title = @"搜索";
    [nav pushViewController:search animated:YES];
}

- (UINavigationController *)activeNavigationController
{
    UIViewController *selected = self.selectedViewController;
    return [selected isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)selected : nil;
}

@end
