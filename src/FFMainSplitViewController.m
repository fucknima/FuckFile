#import "FFMainSplitViewController.h"

#import "FFBookmarksViewController.h"
#import "FFBrowserViewController.h"
#import "FFSettingsViewController.h"
#import "FFStorageAnalysisViewController.h"
#import "FFStorageEnvironment.h"
#import "FFTrashViewController.h"

typedef NS_ENUM(NSInteger, FFSidebarLocation) {
    FFSidebarLocationStorage = 0,
    FFSidebarLocationImported,
    FFSidebarLocationFavorites,
    FFSidebarLocationRecent,
    FFSidebarLocationTrash,
    FFSidebarLocationAnalysis,
    FFSidebarLocationSettings,
};

@interface FFSidebarViewController : UITableViewController
@property(nonatomic, copy) void (^selectionHandler)(FFSidebarLocation location);
@end

@implementation FFSidebarViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"位置";
    return self;
}

- (NSArray<NSArray<NSNumber *> *> *)sections
{
    return @[
        @[@(FFSidebarLocationStorage), @(FFSidebarLocationImported)],
        @[@(FFSidebarLocationFavorites), @(FFSidebarLocationRecent),
          @(FFSidebarLocationTrash), @(FFSidebarLocationAnalysis)],
        @[@(FFSidebarLocationSettings)],
    ];
}

- (NSString *)titleForLocation:(FFSidebarLocation)location
{
    switch (location) {
        case FFSidebarLocationStorage: return @"设备存储";
        case FFSidebarLocationImported: return @"导入";
        case FFSidebarLocationFavorites: return @"收藏";
        case FFSidebarLocationRecent: return @"最近";
        case FFSidebarLocationTrash: return @"回收站";
        case FFSidebarLocationAnalysis: return @"存储空间";
        case FFSidebarLocationSettings: return @"设置";
    }
    return @"";
}

- (NSString *)symbolForLocation:(FFSidebarLocation)location
{
    switch (location) {
        case FFSidebarLocationStorage: return @"folder";
        case FFSidebarLocationImported: return @"square.and.arrow.down";
        case FFSidebarLocationFavorites: return @"star";
        case FFSidebarLocationRecent: return @"clock";
        case FFSidebarLocationTrash: return @"trash";
        case FFSidebarLocationAnalysis: return @"internaldrive";
        case FFSidebarLocationSettings: return @"gearshape";
    }
    return @"folder";
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView
{
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Cell"];
    FFSidebarLocation location =
        (FFSidebarLocation)self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row].integerValue;
    cell.textLabel.text = [self titleForLocation:location];
    cell.imageView.image = [UIImage systemImageNamed:[self symbolForLocation:location]];
    cell.imageView.tintColor = location == FFSidebarLocationTrash
        ? UIColor.systemRedColor : UIColor.systemBlueColor;
    return cell;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    NSIndexPath *first = [NSIndexPath indexPathForRow:0 inSection:0];
    if (!self.tableView.indexPathForSelectedRow)
        [self.tableView selectRowAtIndexPath:first animated:NO
                              scrollPosition:UITableViewScrollPositionNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFSidebarLocation location =
        (FFSidebarLocation)self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row].integerValue;
    if (self.selectionHandler) self.selectionHandler(location);
    if (location == FFSidebarLocationSettings) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

@end

@interface FFMainSplitViewController () <UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) UINavigationController *detailNav;
@property(nonatomic, strong) UINavigationController *presentedSettingsNav;
@end

@implementation FFMainSplitViewController

- (instancetype)init
{
    self = [super initWithStyle:UISplitViewControllerStyleDoubleColumn];
    if (self) {
        self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        self.minimumPrimaryColumnWidth = 260;
        self.maximumPrimaryColumnWidth = 360;
        self.preferredPrimaryColumnWidthFraction = 0.28;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    FFSidebarViewController *sidebar = [FFSidebarViewController new];
    __weak typeof(self) weakSelf = self;
    sidebar.selectionHandler = ^(FFSidebarLocation location) {
        [weakSelf handleLocation:location];
    };
    UINavigationController *sidebarNav = [[UINavigationController alloc]
        initWithRootViewController:sidebar];
    sidebarNav.navigationBar.translucent = NO;
    sidebarNav.navigationBar.prefersLargeTitles = NO;

    FFBrowserViewController *browser = [[FFBrowserViewController alloc]
        initWithPath:FFStorageRootPath()];
    browser.title = @"文件";
    UINavigationController *detailNav = [[UINavigationController alloc]
        initWithRootViewController:browser];
    detailNav.navigationBar.translucent = NO;
    detailNav.navigationBar.prefersLargeTitles = NO;
    self.detailNav = detailNav;

    [self setViewController:sidebarNav forColumn:UISplitViewControllerColumnPrimary];
    [self setViewController:detailNav forColumn:UISplitViewControllerColumnSecondary];
}

- (UINavigationController *)activeNavigationController
{
    return self.detailNav;
}

- (void)handleLocation:(FFSidebarLocation)location
{
    switch (location) {
        case FFSidebarLocationStorage:
            [self showBrowserAtPath:FFStorageRootPath() title:@"文件"];
            break;
        case FFSidebarLocationImported:
            [self showBrowserAtPath:FFImportedDirectoryPath() title:@"导入"];
            break;
        case FFSidebarLocationFavorites: {
            FFBookmarksViewController *page = [[FFBookmarksViewController alloc]
                initWithMode:FFBookmarksModeFavorites];
            page.title = @"收藏";
            [self.detailNav pushViewController:page animated:YES];
            break;
        }
        case FFSidebarLocationRecent: {
            FFBookmarksViewController *page = [[FFBookmarksViewController alloc]
                initWithMode:FFBookmarksModeRecent];
            page.title = @"最近";
            [self.detailNav pushViewController:page animated:YES];
            break;
        }
        case FFSidebarLocationTrash:
            [self.detailNav pushViewController:[FFTrashViewController new] animated:YES];
            break;
        case FFSidebarLocationAnalysis:
            [self.detailNav pushViewController:[FFStorageAnalysisViewController new] animated:YES];
            break;
        case FFSidebarLocationSettings:
            [self presentSettings];
            break;
    }
}

- (void)showBrowserAtPath:(NSString *)path title:(NSString *)title
{
    if (!path.length || !self.detailNav) return;
    FFBrowserViewController *browser = [[FFBrowserViewController alloc] initWithPath:path];
    browser.title = title;
    self.detailNav.viewControllers = @[browser];
}

- (void)presentSettings
{
    if (self.presentedSettingsNav) return;
    FFSettingsViewController *settings = [FFSettingsViewController new];
    settings.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(dismissSettings)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    self.presentedSettingsNav = nav;
    [self presentViewController:nav animated:YES completion:^{
        // presentationController 在 present 之前为 nil，必须在这之后挂 delegate。
        nav.presentationController.delegate = self;
    }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController
{
    if (presentationController.presentedViewController == self.presentedSettingsNav)
        self.presentedSettingsNav = nil;
}

- (void)dismissSettings
{
    [self.presentedSettingsNav dismissViewControllerAnimated:YES completion:^{
        self.presentedSettingsNav = nil;
    }];
}

@end
