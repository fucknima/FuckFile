#import "FFBrowserViewController.h"
#import "FFCopyEngine.h"
#import "FFConflictPolicy.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFFileOperationService.h"
#import "MCMManager.h"
#import "FFLogger.h"
#import "FFAppNames.h"
#import "FFZipExtract.h"
#import "FFTextEditorViewController.h"
#import "FFPlistEditorViewController.h"
#import "FFPdfPreviewViewController.h"
#import "FFPreviewRouter.h"
#import "FFFileAssociationService.h"
#import "FFViewerRegistry.h"
#import "FFPathPolicy.h"
#import "FFThumbnailService.h"
#import "FFBookmarksService.h"
#import "FFPathBreadcrumbView.h"
#import "FFFileMetadataService.h"
#import "FFFileInfoViewController.h"
#import "FFViewerPickerViewController.h"

#import <AVKit/AVKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, FFClipboardMode) {
    FFClipboardModeNone = 0,
    FFClipboardModeCopy,
    FFClipboardModeCut,
};

typedef NS_ENUM(NSInteger, FFSortMode) {
    FFSortModeName = 0,
    FFSortModeSize,
    FFSortModeDate,
    FFSortModeKind,
};

typedef NS_ENUM(NSInteger, FFFilterMode) {
    FFFilterModeAll = 0,
    FFFilterModeImages,
    FFFilterModeVideos,
    FFFilterModeAudio,
    FFFilterModeDocuments,
    FFFilterModeArchives,
    FFFilterModeCode,
};

@implementation FFEntry
@end

// Map well-known bundle identifiers to readable display names; fall back to
// stripping the "com.apple." prefix and camel-case splitting.
@interface FFBrowserViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UIDocumentInteractionControllerDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL hasLoaded;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIRefreshControl *gridRefreshControl;
@property(nonatomic, strong) UIBarButtonItem *plusItem;
@property(nonatomic, strong) NSArray<UIBarButtonItem *> *batchToolbarItems;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, copy) NSString *searchText;
@property(nonatomic) FFSortMode sortMode;
@property(nonatomic) BOOL sortDescending;
@property(nonatomic) FFFilterMode filterMode;
@property(nonatomic, strong) UIBarButtonItem *moreItem;
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic, copy) NSString *batchNormalTitle;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic) BOOL gridMode;
@property(nonatomic, copy) NSString *loadError;
@property(nonatomic, strong) FFEntry *interactionItem;
@property(nonatomic, copy) NSString *interactionText;
// ADR-013：路径导航条与各芯片对应的目标路径。
@property(nonatomic, strong) FFPathBreadcrumbView *breadcrumbView;
@property(nonatomic, strong) NSLayoutConstraint *breadcrumbHeightConstraint;
@property(nonatomic, copy) NSArray<NSString *> *breadcrumbPaths;
// 顶部布局：breadcrumb 锚定 view.topAnchor，动态常量 = 导航栏当前
// frame 下缘（每帧从系统 frame 读取，不依赖 safeArea 的结算结果）。
@property(nonatomic, strong) NSLayoutConstraint *breadcrumbTopInsetConstraint;
// 底部悬浮搜索条的真实高度：从 systemSearchBar 的 frame 实测换算。
@property(nonatomic) CGFloat bottomChrome;
// 任务落盘后的尾随刷新（trailing edge debounce）：最后一次通知后必刷一次。
@property(nonatomic) BOOL pendingAutoReload;
@end

// Process-wide paste state so Copy in one folder can Paste in another.
static NSArray<NSString *> *gClipboardSources = nil;
static FFClipboardMode gClipboardMode = FFClipboardModeNone;

// 单个菜单项：Context Menu 与左滑「更多」Action Sheet 共用同一份定义，
// 避免出现两套对象级操作菜单。
@interface FFMenuDescriptor : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic) BOOL destructive;
@property(nonatomic, copy) void (^handler)(void);
@end
@implementation FFMenuDescriptor
@end

@implementation FFBrowserViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _currentPath = [path copy];
        _showHiddenFiles = [NSUserDefaults.standardUserDefaults
            boolForKey:@"FFSettingsShowHiddenFiles"];
        self.title = path.lastPathComponent.length ? path.lastPathComponent : @"设备存储";
        _sortMode = FFSortModeName;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // 路径导航条（ADR-013）：固定在导航栏下方，根目录时收起。
    self.breadcrumbView = [[FFPathBreadcrumbView alloc] init];
    self.breadcrumbView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.breadcrumbView];

    // 自建 tableView（基类已从 UITableViewController 改为 UIViewController）。
    // 约束布局：顶部跟随 breadcrumb（收起时等于安全区顶部）。
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
        style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self.view addSubview:self.tableView];

    // 顶级布局：breadcrumb 锚定 view.topAnchor + 动态常量（每帧跟随导航栏
    // 下缘，见 viewDidLayoutSubviews）。不再锚定 safeArea/navigationBar：
    // safeArea 在 iOS 27 底部集成搜索时残留搜索条高度出现空白；
    // navigationBar 跨层约束在 push 转场期间抛 NSISEngine（真机 SIGABRT）。
    self.breadcrumbHeightConstraint =
        [self.breadcrumbView.heightAnchor constraintEqualToConstant:32];
    self.breadcrumbTopInsetConstraint =
        [self.breadcrumbView.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                      constant:self.view.safeAreaInsets.top];
    [NSLayoutConstraint activateConstraints:@[
        self.breadcrumbTopInsetConstraint,
        [self.breadcrumbView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.breadcrumbView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.breadcrumbHeightConstraint,
        [self.tableView.topAnchor constraintEqualToAnchor:
            self.breadcrumbView.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:
            self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    [self updateBreadcrumbVisibility];
    [self.tableView reloadData];
    // 底部悬浮搜索条是 iOS 26+ 系统 chrome（Liquid Glass 悬浮层），
    // 不会自动为内容预留空间。余量在 viewDidLayoutSubviews 每帧从系统
    // searchBar 实测；这里给首发帧一个合理缺省，实测值随后覆盖。
    self.bottomChrome = 64;
    [self applySearchChromeInsets];
    // 网格视图懒创建：仅网格模式才实例化 UICollectionView。列表模式下
    // 隐藏的网格仍会参与布局提交（横幅/键盘/菜单动画），是长按操作后
    // flowlayout 断言闪退的源头 —— 不创建就彻底消除这一类崩溃。
    self.gridMode = [NSUserDefaults.standardUserDefaults
        boolForKey:@"FFSettingsGridMode"];
    if (self.gridMode) [self setupCollectionView];
    [self applyLayoutModeAnimated:NO];

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadEntries)
                  forControlEvents:UIControlEventValueChanged];
    // 普通 UIViewController 需要手动挂载 refreshControl（iOS 10+ 官方方式）。
    [self.tableView addSubview:self.refreshControl];

    // 任务中心变更：有任务落到当前目录（复制/移动/解压/压缩完成）时
    // 自动刷新列表，免去手动下拉。
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:FFFileTaskManagerDidChangeNotification object:nil queue:nil
        usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSArray<FFFileTask *> *tasks = [FFFileTaskManager sharedManager].tasks;
            BOOL affectsHere = NO;
            for (FFFileTask *task in tasks) {
                if (task.destination.length == 0 ||
                    task.state == FFFileTaskStateQueued) continue;
                // 粘贴：目标文件夹就是当前目录；压缩/解压：目标文件/
                // 目录的父级是当前目录。两种情况都刷新。
                if ([task.destination isEqualToString:strongSelf.currentPath] ||
                    [task.destination.stringByDeletingLastPathComponent
                        isEqualToString:strongSelf.currentPath]) {
                    affectsHere = YES;
                    break;
                }
            }
            if (!affectsHere) return;
            // 尾随刷新（trailing edge）：不为每个进度通知刷一次，也绝不
            // 因为去抖而丢掉任务完成后的最后一次变化（压缩/复制完成时
            // 临时文件 rename 成目标，必须保证最新状态可见）。
            if (strongSelf.pendingAutoReload) return;
            strongSelf.pendingAutoReload = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                strongSelf.pendingAutoReload = NO;
                if (strongSelf.hasLoaded) [strongSelf reloadEntries];
            });
        }];

    // Reload once the background MCM scan has finished.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFProbeFinished"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf reloadEntries];
            });
        }];

    // Reload when the background LaunchServices confirmation pass installs
    // new MCM App Data links (iOS 26 third-party app discovery).
    [[NSNotificationCenter defaultCenter] addObserverForName:FFMCMAppLinksUpdatedNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (![strongSelf.currentPath hasPrefix:MCMVirtualRoot()]) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf reloadEntries];
            });
        }];

    // 设置页修改（显示隐藏文件等）后，已打开的浏览器页面即时生效。
    // 网格默认值只对新打开的目录生效；运行中页面用"更多 → 显示方式"
    // 局部切换，避免设置页覆盖用户当前选择。
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFSettingsChangedNotification"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.showHiddenFiles = [NSUserDefaults.standardUserDefaults
                    boolForKey:@"FFSettingsShowHiddenFiles"];
                if (strongSelf.moreItem) strongSelf.moreItem.menu = [strongSelf moreMenu];
                [strongSelf reloadEntries];
            });
        }];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"在当前文件夹搜索";
    self.navigationItem.searchController = self.searchController;
    // 常驻导航栏下：不参与滚动隐藏（iOS 26 把隐藏态渲染成底部悬浮条，
    // 会盖住列表内容；Files 同款常驻搜索，无此问题）。
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.moreItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"ellipsis.circle" tint:nil]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.moreItem.menu = [self moreMenu];
    self.moreItem.accessibilityLabel = @"更多操作";
    // ＋：唯一创建入口（新建文件夹/文件）。…：低频页面级操作。
    // 底部工具栏只在选择模式出现，普通浏览完全让位内容。
    self.plusItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"plus" tint:nil]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.plusItem.menu = [self createMenu];
    self.plusItem.accessibilityLabel = @"新建";
    self.navigationItem.rightBarButtonItems = @[self.plusItem, self.moreItem];
    self.navigationController.toolbarHidden = YES;
    [self updatePasteState];
    [self reloadEntries];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updatePasteState];
    // 剪贴板是全局的：切到任何文件夹都恢复横幅与菜单状态。
    if (gClipboardSources.count > 0) [self showPasteBanner];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    if (self.plusItem) self.plusItem.menu = [self createMenu];
    if (self.hasLoaded) [self reloadEntries];
    self.navigationController.toolbarHidden = !self.editing;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

// 布局结算后同步两个动态值（均为运行时实测，不猜常量）：
// 1) 顶部：breadcrumb 距屏幕顶 = 导航栏 frame 下缘（系统里唯一权威值）；
// 2) 底部：悬浮搜索条高度 = 系统 searchBar 的 window frame 实测换算。
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    UINavigationController *nav = self.navigationController;
    if (nav && nav.navigationBar.frame.size.height > 1) {
        CGFloat barBottom = CGRectGetMaxY(nav.navigationBar.frame);
        if (self.breadcrumbTopInsetConstraint.constant != barBottom) {
            self.breadcrumbTopInsetConstraint.constant = barBottom;
            FFLogTag(@"LayoutDiag", @"topInset=%.1f navBarMaxY=%.1f",
                barBottom, barBottom);
        }
    }

    if (!self.editing) {
        CGFloat pad = [self measuredBottomChrome];
        if (pad > 0 && fabs(pad - self.bottomChrome) > 0.5) {
            self.bottomChrome = pad;
            FFLogTag(@"LayoutDiag", @"bottomChrome=%.1f", pad);
        }
    }
    [self applySearchChromeInsets];
}

// 从系统 searchBar 的窗口坐标实测悬浮条高度（含底部留白）。
// 搜索条不在底部（隐藏/转场中/激活时）返回上一次测量值或 0。
- (CGFloat)measuredBottomChrome
{
    UISearchBar *bar = self.searchController.searchBar;
    if (!bar.window || bar.window == nil) return self.bottomChrome;
    CGRect inWindow = [bar convertRect:bar.bounds toView:nil];
    CGFloat screenHeight = self.view.window.bounds.size.height;
    if (inWindow.size.height < 10) return self.bottomChrome;
    // 仅在搜索条真实位于下半屏时按底部测算（顶部阶段忽略）。
    if (CGRectGetMidY(inWindow) < screenHeight * 0.4)
        return self.bottomChrome;
    CGFloat pad = screenHeight - CGRectGetMaxY(inWindow);
    return MAX(pad + 12, 24);
}

// 转场完成后把面包屑顶部改锚导航栏下缘：不再使用（viewDidLayoutSubviews
// 每帧读取导航栏 frame 已覆盖全部形态）。
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
}

#pragma mark - Clipboard state

- (void)updatePasteState
{
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
}

- (BOOL)pasteIsInsideClipboardSource
{
    if (gClipboardSources.count == 0) return NO;
    for (NSString *source in gClipboardSources) {
        struct stat status = {0};
        if (lstat(source.fileSystemRepresentation, &status) != 0 || !S_ISDIR(status.st_mode))
            continue;
        char sourceReal[PATH_MAX] = {0};
        char destinationReal[PATH_MAX] = {0};
        if (!realpath(source.fileSystemRepresentation, sourceReal) ||
            !realpath(self.currentPath.fileSystemRepresentation, destinationReal)) continue;
        NSString *sourcePath = [NSString stringWithUTF8String:sourceReal];
        NSString *destinationPath = [NSString stringWithUTF8String:destinationReal];
        if ([destinationPath isEqualToString:sourcePath] ||
            [destinationPath hasPrefix:[sourcePath stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}

// 源文件正好来自当前目录（剪切模式同目录粘贴的致命场景）。
- (NSArray<NSString *> *)clipboardSourcesInCurrentDirectory
{
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSString *myDirectory = self.currentPath;
    for (NSString *source in gClipboardSources) {
        if ([source.stringByDeletingLastPathComponent isEqualToString:myDirectory])
            [result addObject:source];
    }
    return result;
}

// 底部悬浮 Search Chrome 的余量管理（值为运行实测 bottomChrome）。
// iOS 17+：contentScrollAreaInsets 抬升滚动区（最后一行无论满屏与否
// 都悬在浮条之上，无需依赖滚动）；旧系统回退 contentInset。
// 多选：底部批量工具栏接管，两者清零避免双重空白。
- (void)applySearchChromeInsets
{
    CGFloat chrome = self.editing ? 0 : self.bottomChrome;
    UIEdgeInsets inset = UIEdgeInsetsMake(0, 0, chrome, 0);
    if (@available(iOS 17.0, *)) {
        UIEdgeInsets area = self.editing ? UIEdgeInsetsZero : inset;
        if (!UIEdgeInsetsEqualToEdgeInsets(self.tableView.contentScrollAreaInsets, area)) {
            self.tableView.contentScrollAreaInsets = area;
            self.tableView.contentInset = UIEdgeInsetsZero;
            self.tableView.verticalScrollIndicatorInsets = UIEdgeInsetsZero;
        }
        if (self.collectionView &&
            !UIEdgeInsetsEqualToEdgeInsets(self.collectionView.contentScrollAreaInsets, area)) {
            self.collectionView.contentScrollAreaInsets = area;
            self.collectionView.contentInset = UIEdgeInsetsZero;
            self.collectionView.verticalScrollIndicatorInsets = UIEdgeInsetsZero;
        }
        return;
    }
    if (!UIEdgeInsetsEqualToEdgeInsets(self.tableView.contentInset, inset) ||
        !UIEdgeInsetsEqualToEdgeInsets(self.tableView.verticalScrollIndicatorInsets, inset)) {
        self.tableView.contentInset = inset;
        self.tableView.verticalScrollIndicatorInsets = inset;
    }
    if (self.collectionView &&
        (!UIEdgeInsetsEqualToEdgeInsets(self.collectionView.contentInset, inset) ||
         !UIEdgeInsetsEqualToEdgeInsets(self.collectionView.verticalScrollIndicatorInsets, inset))) {
        self.collectionView.contentInset = inset;
        self.collectionView.verticalScrollIndicatorInsets = inset;
    }
}

#pragma mark - Batch mode (multi-select)

- (void)toggleBatchMode
{
    [self setEditing:!self.editing animated:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    // 基类已是 UIViewController：editing 状态必须手动同步到 tableView。
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    if (editing) {
        // 导航栏：左侧“取消”，右侧“全选”；标题显示已选数量。
        _batchNormalTitle = self.navigationItem.title;
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消"
            style:UIBarButtonItemStylePlain target:self action:@selector(cancelBatchMode)];
        self.navigationItem.leftBarButtonItem = cancel;
        UIBarButtonItem *selectAll = [[UIBarButtonItem alloc] initWithTitle:@"全选"
            style:UIBarButtonItemStylePlain target:self action:@selector(batchSelectAll)];
        self.navigationItem.rightBarButtonItems = @[selectAll];
        [self updateSelectionTitle];
        // 粘贴横幅退出选择模式再恢复，避免与底部批量工具栏叠在一起。
        [self hidePasteBanner];
        // 多选时隐藏系统搜索条（避免与底部批量工具栏叠压），退出恢复。
        self.navigationItem.searchController = nil;
        self.batchToolbarItems = [self buildBatchToolbarItems];
        self.toolbarItems = self.batchToolbarItems;
        self.navigationController.toolbarHidden = NO;
        [self applySearchChromeInsets];
        // 工具栏就位后再同步一次：进入多选且无选中时按钮应禁用。
        [self updateBatchActionsEnabled];
    } else {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItems = @[self.plusItem, self.moreItem];
        if (_batchNormalTitle.length) self.navigationItem.title = _batchNormalTitle;
        self.navigationController.toolbarHidden = YES;
        self.navigationItem.searchController = self.searchController;
        if (gClipboardSources.count > 0) [self showPasteBanner];
    }
    [self updatePasteState];
    [self applyLayoutModeAnimated:NO];
}

// ＋（导航栏）的唯一职责：往当前目录添加内容（创建 + 导入）。
- (UIMenu *)createMenu
{
    UIAction *newFolder = [UIAction actionWithTitle:@"新建文件夹"
        image:[self symbolImage:@"folder.badge.plus" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self createFolder]; }];
    UIAction *newFile = [UIAction actionWithTitle:@"新建文件"
        image:[self symbolImage:@"doc.badge.plus" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self createFile]; }];
    UIAction *import = [UIAction actionWithTitle:@"导入文件…"
        image:[self symbolImage:@"square.and.arrow.down" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self importFilesTapped]; }];
    return [UIMenu menuWithTitle:@"新建" children:@[newFolder, newFile, import]];
}

- (void)cancelBatchMode
{
    [self setEditing:NO animated:YES];
}

- (NSArray<UIBarButtonItem *> *)buildBatchToolbarItems
{
    // 只放“对选中内容做什么”：复制 / 移动 / 分享 / 压缩 / 删除——全部
    // 直接可见，无二级折叠。全选在导航栏、删除单独红色。
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"doc.on.doc" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCopy)];
    copy.accessibilityLabel = @"复制";
    UIBarButtonItem *cut = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"scissors" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCut)];
    cut.accessibilityLabel = @"移动";
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"square.and.arrow.up" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchShare)];
    share.accessibilityLabel = @"分享";
    UIBarButtonItem *zip = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"shippingbox" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCompress)];
    zip.accessibilityLabel = @"压缩";
    UIBarButtonItem *trash = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"trash" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchDelete)];
    trash.tintColor = [UIColor systemRedColor];
    trash.accessibilityLabel = @"删除";
    return @[copy, cut, share, zip, trash];
}

// 无选中时禁用批量操作按钮。
- (void)updateBatchActionsEnabled
{
    BOOL hasSelection = self.tableView.indexPathsForSelectedRows.count > 0;
    for (UIBarButtonItem *item in self.toolbarItems)
        item.enabled = hasSelection;
}

- (NSArray<FFEntry *> *)selectedBatchEntries
{
    NSArray<NSIndexPath *> *indexPaths = self.tableView.indexPathsForSelectedRows;
    NSMutableArray<FFEntry *> *items = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSIndexPath *indexPath in indexPaths)
        if (indexPath.row < self.filteredEntries.count)
            [items addObject:self.filteredEntries[indexPath.row]];
    return items;
}

- (void)batchSelectAll
{
    for (NSUInteger row = 0; row < self.filteredEntries.count; row++)
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
            animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateSelectionTitle];
    [self updatePasteState];
}

- (void)batchCopy
{
    [self batchSetClipboard:FFClipboardModeCopy];
}

- (void)batchCut
{
    [self batchSetClipboard:FFClipboardModeCut];
}

- (void)batchSetClipboard:(FFClipboardMode)mode
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
    for (FFEntry *item in items) [paths addObject:item.path];
    gClipboardSources = paths;
    gClipboardMode = mode;
    [self setEditing:NO animated:YES];
    [self updatePasteState];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    [self showPasteBanner];
}

- (void)batchCompress
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    [self setEditing:NO animated:YES];
    [self compressEntries:items];
}

- (void)compressEntries:(NSArray<FFEntry *> *)items
{
    NSString *defaultName = items.count == 1
        ? [NSString stringWithFormat:@"%@.zip", items.firstObject.name]
        : @"归档.zip";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"压缩"
        message:[NSString stringWithFormat:@"%lu 个项目，压缩到当前目录",
            (unsigned long)items.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = defaultName;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"压缩" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text ?: defaultName;
            if (![weakSelf validNewName:name]) return;
            if (![name.pathExtension.lowercaseString isEqualToString:@"zip"])
                name = [name stringByAppendingPathExtension:@"zip"];
            [weakSelf compressWithName:name items:items];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 压缩前重名检测（防止静默覆盖已有压缩包），冲突交互与重命名一致。
- (void)compressWithName:(NSString *)name items:(NSArray<FFEntry *> *)items
{
    NSString *destination = [self.currentPath stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:destination]) {
        [self enqueueCompressWithName:name items:items];
        return;
    }
    // 已存在：替换 / 保留两者（自动加序号）/ 取消。
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"压缩包已存在"
        message:[NSString stringWithFormat:@"「%@」已存在于当前目录，是否替换？", name]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf enqueueCompressWithName:name items:items];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"保留两者"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *available = [weakSelf uniqueDestinationForName:name];
            if (!available) {
                [weakSelf flash:@"无法生成不冲突的名称"];
                return;
            }
            [weakSelf enqueueCompressWithName:available.lastPathComponent items:items];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height - 60, 1, 1);
    [self presentOnTop:sheet];
}

- (void)enqueueCompressWithName:(NSString *)name items:(NSArray<FFEntry *> *)items
{
    NSString *destination = [self.currentPath stringByAppendingPathComponent:name];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
    for (FFEntry *item in items) [paths addObject:item.path];
    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindCompress;
    task.displayName = [NSString stringWithFormat:@"压缩 %@", name];
    task.sources = paths;
    task.destination = destination;
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    [self flash:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
}

- (void)batchShare
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:items.count];
    for (FFEntry *item in items) [urls addObject:[NSURL fileURLWithPath:item.path]];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:urls applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
    [self setEditing:NO animated:YES];
}

- (void)batchDelete
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除"
        message:[NSString stringWithFormat:@"确定删除 %lu 个项目？", (unsigned long)items.count]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
            for (FFEntry *item in items) [paths addObject:item.path];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *error = nil;
                NSUInteger removed = [[FFFileOperationService sharedService]
                    removeItemsAtPaths:paths firstError:&error];
                NSUInteger failed = (NSUInteger)(paths.count - removed);
                if (error)
                    FFLogTag(@"Browser", @"batch delete FAIL path=%@ error=%@",
                             error.userInfo[NSFilePathErrorKey] ?: @"?", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf flash:failed == 0 ? @"删除完成"
                        : [NSString stringWithFormat:@"删除完成，%lu 个失败", (unsigned long)failed]];
                    [weakSelf setEditing:NO animated:YES];
                    [weakSelf reloadEntries];
                });
            });
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Loading

- (void)reloadEntries
{
    if (self.loading) return;
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // MHA is the only channel: every link in the MCM folders was
        // activated at startup, so its token already covers the target.
        // No per-directory extension consumption is needed.
        NSString *linkTarget = [self symlinkTargetOfPath:self.currentPath];
        if (linkTarget.length) {
            BOOL mhaCovered = [[MCMManager sharedManager] hasActiveLeaseForPath:linkTarget];
            FFLogTag(@"Browser", @"target=%@ mha-lease-covered=%d",
                     linkTarget, mhaCovered);
        }
        NSArray<FFEntry *> *loaded = [self loadDirectoryContents];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.entries = loaded;
            self.hasLoaded = YES;
            self.loading = NO;
            [self applyFilter];
            [self refreshVisibleContent];
            [self.refreshControl endRefreshing];
            [self.gridRefreshControl endRefreshing];
            [self applyLayoutModeAnimated:NO];
            [self updateBreadcrumbVisibility];
        });
    });
}

// 统一可见内容刷新：搜索、筛选、排序、任务完成、设置变化全部走这里。
// List / Grid 平级兄弟视图必须一起刷新，空态同步。
- (void)refreshVisibleContent
{
    [self.tableView reloadData];
    if (self.collectionView) [self.collectionView reloadData];
    [self updateEmptyState];
}

// 空状态视图（列表与网格共用）：iOS 17+ 使用系统
// UIContentUnavailableConfiguration 模板（原生字体/图标/动效），
// 旧系统保持居中 Label fallback。
- (void)updateEmptyState
{
    UIView *emptyView = nil;
    if (self.loading) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        spinner.frame = CGRectMake(0, 0, 44, 44);
        emptyView = spinner;
    } else if (self.loadError.length) {
        if (@available(iOS 17.0, *)) {
            UIContentUnavailableConfiguration *config = [UIContentUnavailableConfiguration
                emptyConfiguration];
            config.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
            config.text = @"无法打开此文件夹";
            config.secondaryText = self.loadError;
            emptyView = [[UIContentUnavailableView alloc] initWithConfiguration:config];
        } else {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0,
                self.view.bounds.size.width - 80, 120)];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.textColor = [UIColor secondaryLabelColor];
            label.text = [NSString stringWithFormat:@"无法打开此文件夹\n\n%@\n\n点按重试",
                self.loadError];
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
            label.adjustsFontForContentSizeCategory = YES;
            label.userInteractionEnabled = YES;
            [label addGestureRecognizer:[[UITapGestureRecognizer alloc]
                initWithTarget:self action:@selector(reloadEntries)]];
            emptyView = label;
        }
    } else if (self.filteredEntries.count == 0) {
        // 筛选/搜索无命中与真空目录区分提示。
        BOOL filteredOut = (self.entries.count > 0 || self.searchText.length ||
            self.filterMode != FFFilterModeAll);
        if (@available(iOS 17.0, *)) {
            UIContentUnavailableConfiguration *config = [UIContentUnavailableConfiguration
                searchConfiguration];
            if (filteredOut) {
                config.text = @"没有匹配的文件";
                config.secondaryText = @"尝试其他关键词或筛选条件";
            } else {
                config.image = [UIImage systemImageNamed:@"folder"];
                config.text = @"此文件夹为空";
                config.secondaryText = @"在这里创建或导入内容";
            }
            emptyView = [[UIContentUnavailableView alloc] initWithConfiguration:config];
        } else {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0,
                self.view.bounds.size.width - 80, 80)];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.textColor = [UIColor secondaryLabelColor];
            label.text = filteredOut ? @"没有匹配的文件" : @"此文件夹为空";
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
            label.adjustsFontForContentSizeCategory = YES;
            emptyView = label;
        }
    }
    if (emptyView) {
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
            self.view.bounds.size.width, self.view.bounds.size.height)];
        emptyView.center = container.center;
        [container addSubview:emptyView];
        // 错误态支持点按重试（与旧系统 fallback 行为一致）。
        if (self.loadError.length) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                initWithTarget:self action:@selector(reloadEntries)];
            [container addGestureRecognizer:tap];
        }
        self.tableView.backgroundView = container;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        // 网格模式下列表隐藏：空态必须同时挂到 collectionView 上。
        if (self.collectionView) self.collectionView.backgroundView = container;
    } else {
        self.tableView.backgroundView = nil;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        if (self.collectionView) self.collectionView.backgroundView = nil;
    }
}

- (NSString *)symlinkTargetOfPath:(NSString *)path
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0 || !S_ISLNK(status.st_mode))
        return nil;
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
    if (length <= 0) return nil;
    target[length] = '\0';
    return [NSString stringWithUTF8String:target];
}


- (NSArray<FFEntry *> *)loadDirectoryContents
{
    NSMutableArray<FFEntry *> *result = [NSMutableArray array];
    DIR *directory = opendir(self.currentPath.fileSystemRepresentation);
    if (!directory) {
        self.loadError = [NSString stringWithFormat:@"无法打开目录 errno=%d (%s)",
            errno, strerror(errno)];
        FFLogTag(@"Browser", @"opendir FAIL path=%@ errno=%d (%s)",
            self.currentPath, errno, strerror(errno));
        return result;
    }
    self.loadError = nil;
    NSUInteger total = 0;
    NSUInteger dirs = 0;
    NSUInteger files = 0;
    NSUInteger links = 0;
    NSUInteger lstatFailures = 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        total++;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        // 隐藏文件默认不显示（可在“更多”菜单打开）。
        if (!self.showHiddenFiles && [name hasPrefix:@"."]) continue;
        NSString *path = [self.currentPath stringByAppendingPathComponent:name];
        FFEntry *item = [FFEntry new];
        item.name = name;
        item.path = path;
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0) {
            lstatFailures++;
            item.detail = [NSString stringWithFormat:@"lstat errno=%d", errno];
            [result addObject:item];
            continue;
        }
        if (S_ISLNK(status.st_mode)) links++;
        else if (S_ISDIR(status.st_mode)) dirs++;
        else files++;
        item.mode = status.st_mode;
        item.uid = status.st_uid;
        item.gid = status.st_gid;
        item.modificationDate = [NSDate dateWithTimeIntervalSince1970:status.st_mtimespec.tv_sec];
        item.creationDate = [NSDate dateWithTimeIntervalSince1970:status.st_birthtimespec.tv_sec];
        item.isSymlink = S_ISLNK(status.st_mode);
        if (item.isSymlink) {
            char target[PATH_MAX] = {0};
            ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
            if (length > 0) {
                target[length] = '\0';
                item.linkTarget = [NSString stringWithUTF8String:target];
            }
            struct stat resolved = {0};
            if (stat(path.fileSystemRepresentation, &resolved) == 0) {
                item.isDirectory = S_ISDIR(resolved.st_mode);
                item.size = (unsigned long long)resolved.st_size;
            }
        } else {
            item.isDirectory = S_ISDIR(status.st_mode);
            item.size = S_ISREG(status.st_mode) ? (unsigned long long)status.st_size : 0;
        }
        // Resolve container UUIDs to readable app names via the MCM metadata
        // plist so directories show app names, not UUIDs. App Store installs
        // carry the localized display name in iTunesMetadata.plist; prefer
        // it over the bundle-identifier lookup.
        item.displayName = item.name;
        if (!item.isSymlink && item.isDirectory) {
            NSString *metadataPath = [path stringByAppendingPathComponent:
                @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            NSString *identifier = [metadata[@"MCMMetadataIdentifier"]
                isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
            if (identifier.length) {
                NSString *itemName = FFAppContainerItemName(path);
                item.displayName = itemName ?: FFAppDisplayName(identifier);
                item.containerIdentifier = identifier;
                item.isAppContainer = YES;
                // Only log actual container roots (UUID-shaped names).
                if (FFIsUUIDShapedName(name))
                    FFLogTag(@"Browser", @"metadata resolved %@ -> %@ (%@)",
                        name, item.displayName, identifier);
            } else if (FFIsUUIDShapedName(name)) {
                FFLogTag(@"Browser", @"metadata MISSING/unreadable for %@",
                    path.lastPathComponent);
            }
        }
        [result addObject:item];
    }
    closedir(directory);
    FFLogTag(@"Browser", @"dir scan path=%@ total=%lu dirs=%lu files=%lu links=%lu lstatFail=%lu",
        self.currentPath, (unsigned long)total, (unsigned long)dirs,
        (unsigned long)files, (unsigned long)links, (unsigned long)lstatFailures);
    // 文件夹优先可关（设置页）；历史行为默认开启。
    id foldersFirstValue = [NSUserDefaults.standardUserDefaults
        objectForKey:@"FFSettingsFoldersFirst"];
    BOOL foldersFirst = foldersFirstValue == nil ? YES : [foldersFirstValue boolValue];
    [self decorateEntries:result];
    [result sortUsingComparator:^NSComparisonResult(FFEntry *left, FFEntry *right) {
        // Folder-first ordering is a display preference, unaffected by
        // the sort direction.
        if (foldersFirst && left.isDirectory != right.isDirectory)
            return left.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult comparison = NSOrderedSame;
        switch (self.sortMode) {
            case FFSortModeSize:
                if (left.size != right.size)
                    comparison = left.size > right.size ? NSOrderedAscending : NSOrderedDescending;
                break;
            case FFSortModeDate:
                comparison = [right.modificationDate compare:left.modificationDate];
                break;
            case FFSortModeKind:
                comparison = [[self kindName:left] compare:[self kindName:right]];
                break;
            case FFSortModeName:
            default:
                break;
        }
        if (comparison == NSOrderedSame)
            comparison = [left.name compare:right.name options:NSNumericSearch];
        if (self.sortDescending)
            comparison = -comparison;
        return comparison;
    }];
    return result;
}

- (void)decorateEntries:(NSArray<FFEntry *> *)entries
{
    for (FFEntry *item in entries) {
        // Bundle-id links in the MCM folders read better as app names.
        // The link target is the real container root: its iTunesMetadata
        // carries the localized App Store display name (e.g. 中国移动).
        if (item.isSymlink && item.name.pathExtension.length &&
            [item.name containsString:@"."] && ![item.name hasPrefix:@"."]) {
            NSString *itemName = item.linkTarget.length
                ? FFAppContainerItemName(item.linkTarget) : nil;
            item.displayName = itemName ?: FFAppDisplayName(item.name);
            item.isAppContainer = YES;
            item.containerIdentifier = item.name;
        }
        // App Data 容器行：Primary=App 显示名，Secondary="标识符 · 时间"
        // （与普通目录的信息层级不同）。
        if (item.isAppContainer) {
            NSString *identifier = item.containerIdentifier.length
                ? item.containerIdentifier : item.name;
            NSString *time = item.modificationDate ?
                [self formatDate:item.modificationDate] : nil;
            item.detail = [NSString stringWithFormat:@"%@%@%@",
                identifier, time ? @" · " : @"",
                time ?: @""];
            continue;
        }
        // 列表只展示当前决策需要的信息（ADR-013）。xattr / 权限 /
        // 链接完整目标等慢数据一律推迟到 FFFileInfoViewController。
        NSString *primary;
        if (item.isDirectory) primary = @"文件夹";
        else if (item.isSymlink) primary = @"符号链接";
        else primary = [self formatSize:item.size];
        if (item.modificationDate)
            item.detail = [NSString stringWithFormat:@"%@ · %@", primary,
                [self formatDate:item.modificationDate]];
        else
            item.detail = primary;
    }
}

- (NSString *)kindName:(FFEntry *)item
{
    if (item.isDirectory) return @"目录";
    if (item.isSymlink) return @"符号链接";
    NSString *ext = item.name.pathExtension.lowercaseString;
    if (ext.length) return [NSString stringWithFormat:@"%@ 文件", ext.uppercaseString];
    return @"文件";
}

// 列表时间显示：相对日期 + 短时间（"今天 17:29"），信息密度与
// Apple Files 对齐；完整精确时间在文件信息页。
- (NSString *)formatDate:(NSDate *)date
{
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.doesRelativeDateFormatting = YES;
        formatter.dateStyle = NSDateFormatterNoStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
    });
    return [formatter stringFromDate:date];
}

- (NSString *)formatSize:(unsigned long long)bytes
{
    if (bytes >= 1024ULL * 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
    if (bytes >= 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    if (bytes >= 1024ULL)
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%llu B", bytes];
}

- (void)applyFilter
{
    NSArray<FFEntry *> *source = self.entries;
    if (self.filterMode != FFFilterModeAll)
        source = [source filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(FFEntry *item, __unused NSDictionary *bindings) {
                return [self entry:item matchesFilter:self.filterMode];
            }]];
    if (!self.searchText.length) {
        self.filteredEntries = source;
        return;
    }
    NSPredicate *predicate = [NSPredicate predicateWithFormat:
        @"name contains[cd] %@ OR path contains[cd] %@", self.searchText, self.searchText];
    self.filteredEntries = [source filteredArrayUsingPredicate:predicate];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.searchText = searchController.searchBar.text;
    [self applyFilter];
    [self refreshVisibleContent];
}

#pragma mark - More menu

// 更多菜单：动作全部一级直接可见；排序/筛选/显示方式归并为一个
// 「视图」二级菜单（选项组）。导入在 ＋；创建不在本菜单。
- (UIMenu *)moreMenu
{
    UIAction *select = [UIAction actionWithTitle:@"选择" image:[self symbolImage:@"checkmark.circle" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self toggleBatchMode]; }];
    UIAction *paste = [UIAction actionWithTitle:@"粘贴" image:[self symbolImage:@"doc.on.clipboard" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self pasteAction:nil]; }];
    paste.attributes = gClipboardSources.count == 0 ? UIMenuElementAttributesDisabled : 0;
    UIAction *refresh = [UIAction actionWithTitle:@"刷新" image:[self symbolImage:@"arrow.clockwise" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self reloadEntries]; }];
    UIAction *copyCurrentPath = [UIAction actionWithTitle:@"复制当前路径"
        image:[self symbolImage:@"point.topleft.down.curvedto.point.bottomright.up" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            UIPasteboard.generalPasteboard.string = self.currentPath;
            [self flash:@"路径已复制"];
        }];
    UIAction *folderInfo = [UIAction actionWithTitle:@"文件夹信息"
        image:[self symbolImage:@"info.circle" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self showCurrentFolderInfo]; }];

    // 视图：排序/筛选/显示方式（只此一个二级，其余全部一级）。
    UIMenu *viewMenu = [UIMenu menuWithTitle:@"视图" children:@[
        [self sortMenu],
        [self filterMenu],
        [self displayModeMenu],
    ]];

    return [UIMenu menuWithTitle:@"更多" children:@[
        select, paste, refresh, copyCurrentPath, folderInfo, viewMenu,
    ]];
}

// 当前文件夹的属性页：构造 currentPath 对应的 FFEntry（目录）。
- (void)showCurrentFolderInfo
{
    FFEntry *entry = [FFEntry new];
    entry.name = self.currentPath.lastPathComponent.length ?
        self.currentPath.lastPathComponent : MCMVirtualRoot();
    entry.path = self.currentPath;
    entry.isDirectory = YES;
    entry.isSymlink = NO;
    struct stat status = {0};
    if (lstat(self.currentPath.fileSystemRepresentation, &status) == 0) {
        entry.mode = status.st_mode;
        entry.uid = status.st_uid;
        entry.gid = status.st_gid;
        entry.modificationDate =
            [NSDate dateWithTimeIntervalSince1970:status.st_mtimespec.tv_sec];
        entry.creationDate =
            [NSDate dateWithTimeIntervalSince1970:status.st_birthtimespec.tv_sec];
    }
    [self showProperties:entry];
}

// 当前目录的列表/网格快速切换（运行时局部生效；设置页控制的是新目录默认值）。
- (UIMenu *)displayModeMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *list = [UIAction actionWithTitle:@"列表"
        image:[self symbolImage:@"list.bullet" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            weakSelf.gridMode = NO;
            [weakSelf applyLayoutModeAnimated:YES];
        }];
    UIAction *grid = [UIAction actionWithTitle:@"网格"
        image:[self symbolImage:@"square.grid.2x2" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            weakSelf.gridMode = YES;
            [weakSelf applyLayoutModeAnimated:YES];
        }];
    list.state = self.gridMode ? UIMenuElementStateOff : UIMenuElementStateOn;
    grid.state = self.gridMode ? UIMenuElementStateOn : UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@"显示方式" children:@[list, grid]];
}

#pragma mark - Import from Files app

// 外部导入：系统文件选择器（拷贝模式）。文件落到发起导入的当前目录，
// 写入经路径安全策略校验，重名自动加序号。
- (void)importFilesTapped
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data", @"public.content"]
                       inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

// 目标重名时自动加序号，绝不静默覆盖。
- (NSString *)importDestinationForName:(NSString *)name inDirectory:(NSString *)directory
{
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension.length ?
        [@"." stringByAppendingString:name.pathExtension] : @"";
    for (NSInteger index = 2; index < 1000; index++) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ (%ld)%@", base, (long)index, ext]];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 0) return;
    NSMutableArray<NSURL *> *picked = [urls mutableCopy];
    // 从哪个文件夹的右上角导入就落到哪个文件夹。目标目录是“目的地
    // 目录”而非被创建的文件：传一个探针路径（父=当前目录）验证可写，
    // 再用解析出的 parent（=当前目录）作为落盘根。
    NSString *probePath = [self.currentPath stringByAppendingPathComponent:@".ff-import"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger imported = 0;
        NSString *firstFailure = nil;
        for (NSURL *url in picked) {
            [url startAccessingSecurityScopedResource];
            @try {
                NSString *detail = nil;
                NSString *finalName = nil;
                NSString *parent = [FFPathPolicy resolveParentForMutation:probePath
                    finalName:&finalName errorMessage:&detail];
                if (!parent) { firstFailure = detail ?: @"路径不可写"; continue; }
                NSString *destination = [weakSelf importDestinationForName:url.lastPathComponent
                    inDirectory:parent];
                if (!destination || ![NSFileManager.defaultManager copyItemAtPath:url.path
                        toPath:destination error:nil]) {
                    firstFailure = url.lastPathComponent ?: @"未知文件";
                    continue;
                }
                imported++;
            } @finally {
                [url stopAccessingSecurityScopedResource];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (imported > 0 && weakSelf.hasLoaded)
                [weakSelf reloadEntries];
            NSString *message = firstFailure ?
                [NSString stringWithFormat:@"已导入 %lu 项；失败：%@",
                    (unsigned long)imported, firstFailure] :
                [NSString stringWithFormat:@"已导入 %lu 项到当前目录。", (unsigned long)imported];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

#pragma mark - Sort menu

- (UIMenu *)sortMenu
{
    UIAction *name = [UIAction actionWithTitle:@"名称" image:[self symbolImage:@"textformat" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeName]; }];
    UIAction *size = [UIAction actionWithTitle:@"大小" image:[self symbolImage:@"arrow.down.right.and.arrow.up.left" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeSize]; }];
    UIAction *date = [UIAction actionWithTitle:@"修改时间" image:[self symbolImage:@"calendar" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeDate]; }];
    UIAction *kind = [UIAction actionWithTitle:@"类型" image:[self symbolImage:@"square.grid.2x2" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeKind]; }];
    name.state = self.sortMode == FFSortModeName ? UIMenuElementStateOn : UIMenuElementStateOff;
    size.state = self.sortMode == FFSortModeSize ? UIMenuElementStateOn : UIMenuElementStateOff;
    date.state = self.sortMode == FFSortModeDate ? UIMenuElementStateOn : UIMenuElementStateOff;
    kind.state = self.sortMode == FFSortModeKind ? UIMenuElementStateOn : UIMenuElementStateOff;
    NSString *directionTitle = self.sortDescending ? @"降序" : @"升序";
    UIAction *direction = [UIAction actionWithTitle:directionTitle
        image:[self symbolImage:self.sortDescending ? @"arrow.down" : @"arrow.up" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            self.sortDescending = !self.sortDescending;
            [self updatePasteState];
            [self reloadEntries];
        }];
    return [UIMenu menuWithTitle:@"排序方式" children:@[name, size, date, kind, direction]];
}

- (void)setSortMode:(FFSortMode)sortMode
{
    _sortMode = sortMode;
    [self updatePasteState];
    [self reloadEntries];
}

#pragma mark - Filter menu

static NSString *FFFilterTitle(FFFilterMode mode)
{
    switch (mode) {
        case FFFilterModeImages: return @"图片";
        case FFFilterModeVideos: return @"视频";
        case FFFilterModeAudio: return @"音频";
        case FFFilterModeDocuments: return @"文档";
        case FFFilterModeArchives: return @"压缩包";
        case FFFilterModeCode: return @"代码";
        case FFFilterModeAll: default: return @"全部";
    }
}

- (BOOL)entry:(FFEntry *)item matchesFilter:(FFFilterMode)mode
{
    if (item.isDirectory || mode == FFFilterModeAll) return YES;
    NSString *ext = item.name.pathExtension.lowercaseString;
    switch (mode) {
        case FFFilterModeImages:
            return [@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp"] containsObject:ext];
        case FFFilterModeVideos:
            return [@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"] containsObject:ext];
        case FFFilterModeAudio:
            return [@[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"] containsObject:ext];
        case FFFilterModeDocuments:
            return [@[@"txt", @"log", @"md", @"json", @"xml", @"plist", @"csv", @"pdf",
                      @"rtf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx",
                      @"pages", @"numbers", @"key"] containsObject:ext];
        case FFFilterModeArchives:
            // .deb 不属于压缩包：无解析后端，不参与归档逻辑。
            return [@[@"zip", @"ipa", @"tar", @"gz", @"7z", @"rar", @"xz"] containsObject:ext];
        case FFFilterModeCode:
            return [@[@"c", @"h", @"m", @"mm", @"swift", @"sh", @"py", @"js", @"ts",
                      @"html", @"css", @"java", @"kt", @"go", @"rs", @"rb", @"php"] containsObject:ext];
        case FFFilterModeAll: default:
            return YES;
    }
}

- (UIMenu *)filterMenu
{
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSInteger mode = FFFilterModeAll; mode <= FFFilterModeCode; mode++) {
        FFFilterMode filterMode = (FFFilterMode)mode;
        UIAction *action = [UIAction actionWithTitle:FFFilterTitle(filterMode)
            image:nil identifier:nil handler:^(__unused UIAction *act) {
                self.filterMode = filterMode;
                [self updatePasteState];
                [self applyFilter];
                [self refreshVisibleContent];
            }];
        action.state = self.filterMode == filterMode ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"筛选" children:actions];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.filteredEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Cell"];
    }
    FFEntry *item = self.filteredEntries[indexPath.row];
    [self configureCell:cell withItem:item];
    return cell;
}

- (void)configureCell:(UITableViewCell *)cell withItem:(FFEntry *)item
{
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = item.displayName.length ? item.displayName : item.name;
    // Dynamic Type（ADR-013）：文件名 Body（medium 权重提升层级）、
    // 元数据 Caption1，随系统字号。
    UIFont *bodyFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UIFontDescriptor *semibold = [bodyFont.fontDescriptor
        fontDescriptorByAddingAttributes:@{
            UIFontDescriptorTraitsAttribute: @{ UIFontWeightTrait: @(UIFontWeightMedium) }
        }];
    if (semibold) bodyFont = [UIFont fontWithDescriptor:semibold size:0];
    config.textProperties.font = bodyFont;
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    config.textProperties.numberOfLines = 2;
    config.secondaryText = item.detail;
    config.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryTextProperties.numberOfLines = 1;
    config.image = item.thumbnail ?: [self iconForEntry:item];
    config.imageProperties.cornerRadius = 4;
    config.imageProperties.maximumSize = CGSizeMake(40, 40);
    if (item.thumbnail)
        config.imageProperties.tintColor = nil;
    else
        config.imageProperties.tintColor = [self tintForEntry:item];
    cell.contentConfiguration = config;
    cell.accessoryType = item.isDirectory ? UITableViewCellAccessoryDisclosureIndicator
                                         : UITableViewCellAccessoryNone;

    if (item.thumbnail || item.isDirectory || item.isSymlink ||
        ![self supportsThumbnail:item]) return;
    // Async thumbnail generation; the cell is re-configured once the
    // image lands and still hosts the same entry.
    __weak typeof(self) weakSelf = self;
    [[FFThumbnailService sharedService] thumbnailForPath:item.path
        size:CGSizeMake(40, 40) completion:^(UIImage * _Nullable image) {
            if (!image) return;
            item.thumbnail = image;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSIndexPath *path = [weakSelf.tableView indexPathForCell:cell];
                if (!path) return;
                NSArray<FFEntry *> *entries = weakSelf.filteredEntries;
                if (path.row >= entries.count || entries[path.row] != item) return;
                [weakSelf configureCell:cell withItem:item];
            });
        }];
}

- (BOOL)supportsThumbnail:(FFEntry *)item
{
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSSet<NSString *> *supported;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supported = [NSSet setWithArray:@[
            @"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp",
            @"mp4", @"mov", @"m4v", @"avi", @"mkv",
            @"pdf",
        ]];
    });
    return [supported containsObject:ext];
}

- (UIImage *)iconForEntry:(FFEntry *)item
{
    if (item.isDirectory) return [self symbolImage:@"folder.fill" tint:nil];
    if (item.isSymlink) return [self symbolImage:@"link" tint:nil];
    // App 数据容器（AppData 下）：与普通蓝色文件夹区分开的容器语义图标。
    if (item.isAppContainer) return [self symbolImage:@"cube" tint:nil];
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            // 媒体
            @"png": @"photo", @"jpg": @"photo", @"jpeg": @"photo", @"gif": @"photo",
            @"heic": @"photo", @"webp": @"photo", @"tiff": @"photo", @"bmp": @"photo",
            @"ico": @"photo", @"svg": @"photo", @"car": @"photo",
            @"mp4": @"film", @"mov": @"film", @"m4v": @"film", @"avi": @"film", @"mkv": @"film",
            @"mp3": @"music.note", @"m4a": @"music.note", @"wav": @"music.note",
            @"aac": @"music.note", @"caf": @"music.note", @"flac": @"music.note",
            // 文档
            @"txt": @"doc.text", @"log": @"doc.text", @"rtf": @"doc.text",
            @"doc": @"doc.text", @"docx": @"doc.text", @"pages": @"doc.text",
            @"ppt": @"doc.text", @"pptx": @"doc.text",
            @"pdf": @"doc.richtext",
            @"md": @"text.alignleft",
            @"csv": @"tablecells", @"xls": @"tablecells", @"xlsx": @"tablecells",
            @"numbers": @"tablecells",
            // 配置与代码
            @"plist": @"list.bullet.rectangle",
            @"json": @"curlybraces", @"xml": @"curlybraces", @"html": @"curlybraces",
            @"yaml": @"curlybraces", @"yml": @"curlybraces", @"toml": @"curlybraces",
            @"c": @"chevron.left.forwardslash.chevron.right",
            @"h": @"chevron.left.forwardslash.chevron.right",
            @"m": @"chevron.left.forwardslash.chevron.right",
            @"mm": @"chevron.left.forwardslash.chevron.right",
            @"swift": @"chevron.left.forwardslash.chevron.right",
            @"py": @"chevron.left.forwardslash.chevron.right",
            @"js": @"chevron.left.forwardslash.chevron.right",
            @"ts": @"chevron.left.forwardslash.chevron.right",
            @"java": @"chevron.left.forwardslash.chevron.right",
            @"kt": @"chevron.left.forwardslash.chevron.right",
            @"go": @"chevron.left.forwardslash.chevron.right",
            @"rs": @"chevron.left.forwardslash.chevron.right",
            @"rb": @"chevron.left.forwardslash.chevron.right",
            @"php": @"chevron.left.forwardslash.chevron.right",
            @"sh": @"chevron.left.forwardslash.chevron.right",
            @"command": @"chevron.left.forwardslash.chevron.right",
            // 压缩包 / 容器
            @"zip": @"archivebox", @"tar": @"archivebox", @"gz": @"archivebox",
            @"7z": @"archivebox", @"rar": @"archivebox", @"xz": @"archivebox",
            @"war": @"archivebox", @"jar": @"archivebox", @"apk": @"archivebox",
            @"epub": @"archivebox", @"xcarchive": @"archivebox",
            @"ipa": @"arrow.down.app",
            // 数据库
            @"db": @"cylinder.split.1x2", @"sqlite": @"cylinder.split.1x2",
            @"sqlite3": @"cylinder.split.1x2",
            // 证书 / 密钥
            @"key": @"key", @"mobileconfig": @"lock.doc", @"cer": @"lock.doc",
            @"p12": @"lock.doc", @"crt": @"lock.doc",
            // 系统 / 二进制
            @"app": @"app.badge", @"appex": @"app.badge",
            @"dylib": @"shippingbox", @"bundle": @"shippingbox",
            @"framework": @"shippingbox",
            // 字体
            @"ttf": @"textformat", @"otf": @"textformat", @"woff": @"textformat",
            @"woff2": @"textformat",
        };
    });
    NSString *symbol = map[ext];
    if (!symbol) {
        if ([item.name hasPrefix:@"."]) symbol = @"gearshape";
        else symbol = @"doc";
    }
    return [self symbolImage:symbol tint:nil];
}

- (UIColor *)tintForEntry:(FFEntry *)item
{
    // 有限语义色分层（每类统一）：形状 + 色系双维度区分，不做彩虹渐变。
    if (item.isDirectory) return [UIColor systemBlueColor];
    if (item.isSymlink) return [UIColor systemTealColor];
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSDictionary<NSString *, NSString *> *category;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // NSD colorName（hex）→ UIColor 映射由下方着色：仅分类高亮，
        // 这里列清楚每类的语义色。类别集合集中定义一次。
        category = @{
            // 文档（蓝）
            @"txt": @"doc", @"log": @"doc", @"rtf": @"doc", @"doc": @"doc",
            @"docx": @"doc", @"pages": @"doc", @"ppt": @"doc", @"pptx": @"doc",
            @"pdf": @"doc", @"md": @"doc", @"csv": @"doc",
            @"xls": @"doc", @"xlsx": @"doc", @"numbers": @"doc",
            // 数据/代码/配置（紫）
            @"plist": @"code", @"json": @"code", @"xml": @"code", @"html": @"code",
            @"yaml": @"code", @"yml": @"code", @"toml": @"code",
            @"c": @"code", @"h": @"code", @"m": @"code", @"mm": @"code",
            @"swift": @"code", @"py": @"code", @"js": @"code", @"ts": @"code",
            @"java": @"code", @"kt": @"code", @"go": @"code", @"rs": @"code",
            @"rb": @"code", @"php": @"code", @"sh": @"code", @"command": @"code",
            // 压缩包（棕）
            @"zip": @"archive", @"ipa": @"archive", @"tar": @"archive", @"gz": @"archive",
            @"7z": @"archive", @"rar": @"archive", @"xz": @"archive",
            @"war": @"archive", @"jar": @"archive", @"apk": @"archive",
            @"epub": @"archive", @"xcarchive": @"archive",
            // 数据库（橙）
            @"db": @"db", @"sqlite": @"db", @"sqlite3": @"db",
            // 证书（黄）
            @"key": @"cert", @"mobileconfig": @"cert", @"cer": @"cert",
            @"p12": @"cert", @"crt": @"cert",
            // 媒体（绿）
            @"png": @"media", @"jpg": @"media", @"jpeg": @"media", @"gif": @"media",
            @"heic": @"media", @"webp": @"media", @"tiff": @"media", @"bmp": @"media",
            @"ico": @"media", @"svg": @"media", @"car": @"media",
            @"mp4": @"media", @"mov": @"media", @"m4v": @"media", @"avi": @"media",
            @"mkv": @"media", @"mp3": @"media", @"m4a": @"media", @"wav": @"media",
            @"aac": @"media", @"caf": @"media", @"flac": @"media",
        };
    });
    NSString *kind = category[ext] ?: @"other";
    if ([kind isEqualToString:@"doc"]) return [UIColor systemBlueColor];
    if ([kind isEqualToString:@"code"]) return [UIColor systemPurpleColor];
    if ([kind isEqualToString:@"archive"]) return [UIColor systemBrownColor];
    if ([kind isEqualToString:@"db"]) return [UIColor systemOrangeColor];
    if ([kind isEqualToString:@"cert"]) return [UIColor systemYellowColor];
    if ([kind isEqualToString:@"media"]) return [UIColor systemGreenColor];
    return [UIColor systemGrayColor];
}

- (UIImage *)symbolImage:(NSString *)name tint:(UIColor *)tint
{
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:name];
        if (!image) return nil;
        return [image imageWithTintColor:tint ?: [UIColor systemBlueColor]
                           renderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Multi-select mode: selection only toggles, never opens. The cell
    // keeps its selection state; the title bar shows the running count.
    if (self.editing) {
        [self updateSelectionTitle];
        [self updatePasteState];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openEntry:self.filteredEntries[indexPath.row]];
}

// 打开条目：目录进入、文件预览（列表与网格共用）。
- (void)openEntry:(FFEntry *)item
{
    [[FFRecentService sharedService] recordPath:item.path
        name:item.displayName.length ? item.displayName : item.name
        isDirectory:item.isDirectory];
    if (item.isDirectory) {
        FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
        next.title = item.displayName.length ? item.displayName : item.name;
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    [self previewEntry:item];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.editing) {
        [self updateSelectionTitle];
        [self updatePasteState];
    }
}

// Multi-select title: "已选 X 项" while editing; normal title untouched.
- (void)updateSelectionTitle
{
    if (!self.editing) return;
    NSInteger count = (NSInteger)self.tableView.indexPathsForSelectedRows.count;
    self.navigationItem.title = count == 0 ? @"已选 0 项" :
        [NSString stringWithFormat:@"已选 %ld 项", (long)count];
    [self updateBatchActionsEnabled];
}

#pragma mark - Breadcrumb

// 显示规则：只展示"返回上级"层级链，当前目录不重复展示（导航标题已经
// 告诉用户在哪）。MCM 虚拟根之下从 Device Storage 起显示；其他路径最多
// 显示最后 2 个祖先级。绝不展示完整 /private/var/... 链路。
- (void)updateBreadcrumbVisibility
{
    NSString *root = MCMVirtualRoot();
    BOOL atRoot = [self.currentPath isEqualToString:root];
    self.breadcrumbHeightConstraint.constant = atRoot ? 0 : 32;
    self.breadcrumbView.hidden = atRoot;
    if (atRoot) return;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *base = [self.currentPath hasPrefix:root] ? root : nil;
    if (base) {
        [names addObject:@"Device Storage"];
        [paths addObject:base];
        NSString *relative = [self.currentPath substringFromIndex:base.length];
        for (NSString *component in [relative pathComponents])
            if (component.length && ![component isEqualToString:@"/"]) {
                [paths addObject:[[paths.lastObject stringByAppendingPathComponent:
                    component] stringByStandardizingPath]];
                [names addObject:component];
            }
        // 去掉最后一段（当前目录）：与导航标题去重，只留祖先链。
        if (names.count > 1) {
            [names removeLastObject];
            [paths removeLastObject];
        } else {
            // 当前目录就是根下第一层：只保留 "Device Storage ＞"。
        }
    } else {
        NSArray<NSString *> *components = self.currentPath.pathComponents;
        // 祖先链：最多取到直接父级。内容从最后一段（当前目录）前一节开始。
        NSMutableArray<NSString *> *stages = [NSMutableArray array];
        for (NSString *component in components) {
            if ([component isEqualToString:@"/"] ||
                [component isEqualToString:@".."] ||
                [component isEqualToString:@"."]) continue;
            [stages addObject:component];
        }
        if (stages.count > 1)
            [stages removeLastObject]; // 去当前目录
        NSUInteger start = stages.count > 2 ? stages.count - 2 : 0;
        for (NSUInteger i = start; i < stages.count; i++) {
            NSString *component = stages[i];
            // 从头拼接真实路径，避免手写斜杠逻辑。
            NSMutableString *path = [NSMutableString string];
            for (NSUInteger j = 0; j < components.count; j++) {
                if ([components[j] isEqualToString:component]) {
                    for (NSUInteger k = 0; k <= j; k++)
                        [path appendString:[components[k] isEqualToString:@"/"]
                            ? @"/" : [components[k] stringByAppendingString:@"/"]];
                    break;
                }
            }
            [names addObject:component];
            [paths addObject:path.stringByStandardizingPath];
        }
    }
    if (names.count == 0) {
        // 无祖先层：收起面包屑，标题已足够。
        self.breadcrumbHeightConstraint.constant = 0;
        self.breadcrumbView.hidden = YES;
        return;
    }
    self.breadcrumbPaths = paths;
    // 最后显示的层级（直接父级）加粗：它是"下一步跳回"的目标。
    [self.breadcrumbView setComponentNames:names selectedIndex:names.count - 1
        target:self action:@selector(breadcrumbTapped:)];
}

// 上级目录跳转：优先复用导航栈中的既有浏览器，否则按正常导航模型 push。
- (void)breadcrumbTapped:(UIButton *)sender
{
    if (sender.tag >= self.breadcrumbPaths.count) return;
    NSString *target = self.breadcrumbPaths[sender.tag];
    UINavigationController *navigation = self.navigationController;
    if (!navigation) return;
    NSString *standardized = target.stringByStandardizingPath;
    for (UIViewController *controller in navigation.viewControllers) {
        if (![controller isKindOfClass:FFBrowserViewController.class]) continue;
        FFBrowserViewController *browser = (FFBrowserViewController *)controller;
        if ([browser.currentPath.stringByStandardizingPath isEqualToString:standardized]) {
            [navigation popToViewController:browser animated:YES];
            return;
        }
    }
    FFBrowserViewController *browser =
        [[FFBrowserViewController alloc] initWithPath:target];
    browser.title = target.lastPathComponent;
    [navigation pushViewController:browser animated:YES];
}

#pragma mark - Grid / list layout

- (void)setupCollectionView
{
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 8;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds
        collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor systemBackgroundColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.hidden = YES;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collectionView registerClass:UICollectionViewCell.class
            forCellWithReuseIdentifier:@"GridCell"];
    [self.view addSubview:self.collectionView];
    // 网格同样支持下拉刷新（与列表一致）。
    UIRefreshControl *gridRefresh = [UIRefreshControl new];
    [gridRefresh addTarget:self action:@selector(reloadEntries)
          forControlEvents:UIControlEventValueChanged];
    self.gridRefreshControl = gridRefresh;
    [self.collectionView addSubview:gridRefresh];
    [NSLayoutConstraint activateConstraints:@[
        // 顶部与列表一致：跟随 breadcrumb（收起时等于安全区顶部）。
        [self.collectionView.topAnchor constraintEqualToAnchor:
            self.breadcrumbView.bottomAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    [self applySearchChromeInsets];
    [self updateEmptyState];
}

// 列表/网格切换：显示对应视图（网格 3 列，仅浏览；多选/编辑保持列表）。
- (void)applyLayoutModeAnimated:(BOOL)animated
{
    BOOL useGrid = self.gridMode && !self.editing;
    if (useGrid && !self.collectionView) [self setupCollectionView];
    if (!useGrid && self.collectionView && !self.collectionView.hidden) {
        // 退出网格即销毁：不留隐藏布局对象。
        [self.collectionView removeFromSuperview];
        self.collectionView = nil;
        self.gridRefreshControl = nil;
    }
    if (!self.collectionView) {
        self.tableView.hidden = NO;
        return;
    }
    self.collectionView.hidden = !useGrid;
    self.tableView.hidden = useGrid;
    if (useGrid) {
        [self.collectionView reloadData];
    }
}

#pragma mark - Collection view (grid)

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section
{
    return (NSInteger)self.filteredEntries.count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    // 防御性尺寸：未完成布局（宽度为 0）或极窄时给安全默认值；floor
    // 防止浮点累加使整行宽度超出可用宽度 —— 超出会触发 flowlayout
    // 断言闪退（iOS 27 上隐藏视图同样参与 CATransaction 布局）。
    // 自适应列数（ADR-013）：按可用宽度与最小项宽计算，不判断设备型号。
    CGFloat available = collectionView.bounds.size.width - 24 - 16;
    if (available < 120) return CGSizeMake(44, 72);
    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat spacing = flowLayout ? flowLayout.minimumInteritemSpacing : 8.0;
    NSInteger columns = (NSInteger)floor((available + spacing) / (96.0 + spacing));
    columns = MAX(2, MIN(columns, 8));
    CGFloat width = floor((available - (columns - 1) * spacing) / columns);
    return CGSizeMake(width, width + 28);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = [collectionView
        dequeueReusableCellWithReuseIdentifier:@"GridCell" forIndexPath:indexPath];
    FFEntry *item = self.filteredEntries[indexPath.row];
    UIView *existing = [cell.contentView viewWithTag:999];
    [existing removeFromSuperview];

    UIListContentConfiguration *config = [UIListContentConfiguration
        subtitleCellConfiguration];
    config.text = item.displayName.length ? item.displayName : item.name;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    config.textProperties.numberOfLines = 1;
    config.textProperties.alignment = UIListContentTextAlignmentCenter;
    config.secondaryText = [self formatSize:item.size];
    config.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryTextProperties.alignment = UIListContentTextAlignmentCenter;
    config.image = item.thumbnail ?: [self iconForEntry:item];
    config.imageProperties.maximumSize = CGSizeMake(48, 48);
    config.imageProperties.cornerRadius = 6;
    config.imageProperties.tintColor = item.thumbnail ? nil : [self tintForEntry:item];
    UIView *content = [config makeContentView];
    content.tag = 999;
    content.frame = cell.contentView.bounds;
    content.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [cell.contentView addSubview:content];

    if (!item.thumbnail && !item.isDirectory && !item.isSymlink &&
        [self supportsThumbnail:item]) {
        // 网格缩略图异步生成，与列表一致；完成时只重载对应项。
        __weak typeof(self) weakSelf = self;
        [[FFThumbnailService sharedService] thumbnailForPath:item.path
            size:CGSizeMake(48, 48) completion:^(UIImage * _Nullable image) {
                if (!image) return;
                item.thumbnail = image;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!weakSelf.collectionView || weakSelf.collectionView.hidden) return;
                    NSArray<FFEntry *> *entries = weakSelf.filteredEntries;
                    NSUInteger index = [entries indexOfObjectIdenticalTo:item];
                    if (index == NSNotFound) return;
                    NSIndexPath *target =
                        [NSIndexPath indexPathForItem:(NSInteger)index inSection:0];
                    [weakSelf.collectionView reloadItemsAtIndexPaths:@[target]];
                });
            }];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    [self openEntry:self.filteredEntries[indexPath.row]];
}

#pragma mark - Context menu & swipe actions

// 上下文菜单的 action handler 在菜单收起动画期间被回调；此时直接
// present（尤其带输入框、会拉起键盘的 alert）会与进行中的转场冲突，
// 在 iOS 27 上直接闪退。统一推迟到下一轮主循环，让菜单先完成收起。
- (void)performAfterContextMenu:(void (^)(void))block
{
    dispatch_async(dispatch_get_main_queue(), block);
}

// 对象级操作的唯一定义（分区）：打开/查看 ‖ 复制·剪切·副本·重命名·
// 收藏·分享 ‖ 压缩/浏览压缩包/解压/安装 ‖ 用其他查看器打开（仅文件）‖
// 复制路径·属性·删除。文件夹不展示查看器类操作。
- (NSArray<NSArray<FFMenuDescriptor *> *> *)contextMenuSectionsForEntry:(FFEntry *)item
{
    __weak typeof(self) weakSelf = self;
    FFMenuDescriptor *(^descriptor)(NSString *, NSString *, BOOL, void (^)(void)) =
        ^FFMenuDescriptor *(NSString *title, NSString *symbol, BOOL destructive,
            void (^handler)(void)) {
        FFMenuDescriptor *d = [FFMenuDescriptor new];
        d.title = title;
        d.symbol = symbol;
        d.destructive = destructive;
        d.handler = handler;
        return d;
    };
    FFMenuDescriptor *view = descriptor(item.isDirectory ? @"打开" : @"查看", @"eye", NO, ^{
        if (!weakSelf || !item.path) return;
        if (item.isDirectory) {
            FFBrowserViewController *next =
                [[FFBrowserViewController alloc] initWithPath:item.path];
            next.title = item.displayName.length ? item.displayName : item.name;
            [weakSelf.navigationController pushViewController:next animated:YES];
        } else {
            [weakSelf previewEntry:item];
        }
    });
    FFMenuDescriptor *copy = descriptor(@"复制", @"doc.on.doc", NO, ^{
        [weakSelf setClipboard:item mode:FFClipboardModeCopy];
    });
    FFMenuDescriptor *cut = descriptor(@"剪切", @"scissors", NO, ^{
        [weakSelf setClipboard:item mode:FFClipboardModeCut];
    });
    FFMenuDescriptor *duplicate = descriptor(@"创建副本", @"plus.square.on.square", NO, ^{
        [weakSelf duplicateEntry:item];
    });
    FFMenuDescriptor *favorite = descriptor(
        [[FFFavoritesService sharedService] isFavoritePath:item.path] ? @"取消收藏" : @"收藏",
        @"star", NO, ^{ [weakSelf toggleFavorite:item]; });
    FFMenuDescriptor *ren = descriptor(@"重命名", @"pencil", NO, ^{
        [weakSelf renameEntry:item];
    });
    FFMenuDescriptor *share = descriptor(@"分享", @"square.and.arrow.up", NO, ^{
        [weakSelf shareEntry:item];
    });
    FFMenuDescriptor *compress = descriptor(@"压缩", @"shippingbox", NO, ^{
        [weakSelf compressEntries:@[item]];
    });
    FFMenuDescriptor *copyPath = descriptor(@"复制路径",
        @"point.topleft.down.curvedto.point.bottomright.up", NO, ^{
        [weakSelf copyPath:item];
    });
    FFMenuDescriptor *properties = descriptor(@"属性", @"info.circle", NO, ^{
        [weakSelf showProperties:item];
    });
    FFMenuDescriptor *remove = descriptor(@"删除", @"trash", YES, ^{
        [weakSelf deleteEntry:item];
    });

    NSMutableArray<FFMenuDescriptor *> *section1 =
        [NSMutableArray arrayWithObjects:view, nil];
    NSMutableArray<FFMenuDescriptor *> *section2 =
        [NSMutableArray arrayWithObjects:copy, cut, duplicate, ren, favorite, share, nil];
    NSMutableArray<FFMenuDescriptor *> *section3 =
        [NSMutableArray arrayWithObjects:compress, nil];
    NSMutableArray<FFMenuDescriptor *> *section4 = [NSMutableArray array];
    NSMutableArray<FFMenuDescriptor *> *section5 =
        [NSMutableArray arrayWithObjects:copyPath, properties, remove, nil];

    if (!item.isDirectory) {
        NSString *ext = item.name.pathExtension.lowercaseString;
        if ([self isArchiveEntry:item]) {
            [section3 addObject:descriptor(@"浏览压缩包", @"shippingbox", NO, ^{
                [weakSelf openWithViewer:item viewerID:@"archive"];
            })];
            [section3 addObject:descriptor(@"解压", @"shippingbox", NO, ^{
                [weakSelf extractEntry:item];
            })];
        }
        if ([ext isEqualToString:@"ipa"]) {
            [section3 addObject:descriptor(@"安装", @"arrow.down.app", NO, ^{
                [weakSelf openWithViewer:item viewerID:@"installer"];
            })];
        }
        [section4 addObject:descriptor(@"用其他查看器打开",
            @"square.and.arrow.down.on.square", NO, ^{
            [weakSelf openWithPicker:item];
        })];
    }
    NSMutableArray *sections = [NSMutableArray arrayWithObjects:section1, section2,
        section3, nil];
    if (section4.count) [sections addObject:section4];
    [sections addObject:section5];
    return sections;
}

- (UIMenu *)contextMenuForEntry:(FFEntry *)item
{
    // 分区全部 displayInline：直接平铺显示，绝不折叠成箭头子菜单。
    // 分组只用于视觉分段；iPad 上系统自动双列。
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSArray<FFMenuDescriptor *> *section in
        [self contextMenuSectionsForEntry:item]) {
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (FFMenuDescriptor *d in section) {
            UIAction *action = [UIAction actionWithTitle:d.title
                image:[self symbolImage:d.symbol tint:nil]
                identifier:nil handler:^(__unused UIAction *a) {
                    [self performAfterContextMenu:d.handler];
                }];
            if (d.destructive) action.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:action];
        }
        [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
            options:UIMenuOptionsDisplayInline children:actions]];
    }
    return [UIMenu menuWithTitle:item.name children:children];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point
{
    __weak typeof(self) weakSelf = self;
    FFEntry *item = self.filteredEntries[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            return [weakSelf contextMenuForEntry:item];
        }];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point
{
    __weak typeof(self) weakSelf = self;
    FFEntry *item = self.filteredEntries[(NSUInteger)indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            return [weakSelf contextMenuForEntry:item];
        }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // 编辑（多选）模式下禁用左滑：swipe 按钮与底部批量工具栏重叠。
    if (self.editing) return nil;
    FFEntry *item = self.filteredEntries[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
            void (^completionHandler)(BOOL)) {
            [weakSelf deleteEntry:item];
            completionHandler(YES);
        }];
    delete.image = [self symbolImage:@"trash" tint:nil];
    UIContextualAction *more = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"更多" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
            void (^completionHandler)(BOOL)) {
            [weakSelf presentActionsForEntry:item];
            completionHandler(YES);
        }];
    more.image = [self symbolImage:@"ellipsis.circle" tint:nil];
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[delete, more]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

#pragma mark - Actions

// 左滑「更多」：与长按菜单同一份定义渲染成 Action Sheet（UIKit 没有
// 在 UIContextualAction 里直接展示 UIMenu 的 API），不是第二套菜单。
- (void)presentActionsForEntry:(FFEntry *)item
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.name
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSArray<FFMenuDescriptor *> *section in
        [self contextMenuSectionsForEntry:item]) {
        for (FFMenuDescriptor *d in section) {
            UIAlertAction *action = [UIAlertAction actionWithTitle:d.title
                style:d.destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) {
                    if (d.handler) d.handler();
                }];
            [sheet addAction:action];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
        self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setClipboard:(FFEntry *)item mode:(FFClipboardMode)mode
{
    gClipboardSources = @[item.path];
    gClipboardMode = mode;
    [self updatePasteState];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    [self showPasteBanner];
}

#pragma mark - Paste banner

// 底部提示条：复制/剪切后显示“已复制 X 项 + 粘贴/取消”，
// 替代连续弹窗，进入目标目录后粘贴按钮清晰可见。
- (void)showPasteBanner
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *existing = [self.view viewWithTag:9347];
        [existing removeFromSuperview];
        if (gClipboardSources.count == 0) return;

        // 材质：新系统下 UIVisualEffectView 的 systemMaterial 渲染为
        // Liquid Glass 材质；旧系统回退为磨砂。与底部悬浮搜索同一语言。
        UIVisualEffectView *banner = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        banner.tag = 9347;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        banner.layer.cornerRadius = 12;
        banner.layer.masksToBounds = YES;
        [self.view addSubview:banner];
        [NSLayoutConstraint activateConstraints:@[
            [banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
            [banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
            [banner.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                constant:-8],
            [banner.heightAnchor constraintEqualToConstant:52],
        ]];

        NSString *action = gClipboardMode == FFClipboardModeCopy ? @"已复制" : @"已剪切";
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        label.adjustsFontForContentSizeCategory = YES;
        label.text = [NSString stringWithFormat:@"%@ %lu 项",
            action, (unsigned long)gClipboardSources.count];
        [banner.contentView addSubview:label];

        UIButton *pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        pasteButton.translatesAutoresizingMaskIntoConstraints = NO;
        [pasteButton setTitle:@"粘贴" forState:UIControlStateNormal];
        [pasteButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [pasteButton addTarget:self action:@selector(pasteAction:)
              forControlEvents:UIControlEventTouchUpInside];
        [banner.contentView addSubview:pasteButton];

        UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [cancelButton setTitle:@"取消" forState:UIControlStateNormal];
        [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        [cancelButton addTarget:self action:@selector(cancelPaste)
              forControlEvents:UIControlEventTouchUpInside];
        [banner.contentView addSubview:cancelButton];

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:banner.contentView.leadingAnchor constant:14],
            [label.centerYAnchor constraintEqualToAnchor:banner.contentView.centerYAnchor],
            [cancelButton.trailingAnchor constraintEqualToAnchor:banner.contentView.trailingAnchor constant:-8],
            [cancelButton.centerYAnchor constraintEqualToAnchor:banner.contentView.centerYAnchor],
            [pasteButton.trailingAnchor constraintEqualToAnchor:cancelButton.leadingAnchor constant:-8],
            [pasteButton.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
        ]];
        banner.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ banner.alpha = 1; }];
    });
}

- (void)cancelPaste
{
    gClipboardSources = nil;
    gClipboardMode = FFClipboardModeNone;
    [self hidePasteBanner];
    [self updatePasteState];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
}

- (void)hidePasteBanner
{
    UIView *banner = [self.view viewWithTag:9347];
    [UIView animateWithDuration:0.15 animations:^{ banner.alpha = 0; }
        completion:^(BOOL finished) { [banner removeFromSuperview]; }];
}

- (void)pasteAction:(id)sender
{
    if (gClipboardSources.count == 0) return;
    // 拦截分支同样收起横幅并提示原因，不残留"粘贴/取消"悬浮条。
    if ([self pasteIsInsideClipboardSource]) {
        [self hidePasteBanner];
        [self flash:@"不能粘贴到自身或其子目录"];
        return;
    }
    // 同目录粘贴（剪切模式）：移动引擎会把文件搬到自身再“替换”，
    // 导致源文件消失。直接拦截并提示。
    NSArray<NSString *> *sameDir = [self clipboardSourcesInCurrentDirectory];
    if (sameDir.count > 0) {
        [self hidePasteBanner];
        [self flash:[NSString stringWithFormat:
            @"已在当前目录内，忽略 %lu 项", (unsigned long)sameDir.count]];
        return;
    }
    NSArray<NSString *> *sources = gClipboardSources;
    gClipboardSources = nil;
    FFClipboardMode mode = gClipboardMode;
    gClipboardMode = FFClipboardModeNone;

    FFFileTask *task = [FFFileTask new];
    task.kind = mode == FFClipboardModeCut ? FFFileTaskKindMove : FFFileTaskKindCopy;
    task.displayName = [NSString stringWithFormat:@"%@ %lu 个项目",
        task.kindText, (unsigned long)sources.count];
    task.sources = sources;
    task.destination = self.currentPath;
    __weak typeof(self) weakSelf = self;
    // 冲突处理绑定到本任务，避免并发任务交叉。
    task.conflictHandler = ^FFConflictAction(NSString *name) {
        typeof(weakSelf) strongSelf = weakSelf;
        return strongSelf ? [strongSelf askConflictForName:name] : FFConflictActionSkip;
    };
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    [self hidePasteBanner];
    [self flash:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
    [self updatePasteState];
}

// Blocks the calling (background) thread until the user picks a
// conflict action on the main thread.
- (FFConflictAction)askConflictForName:(NSString *)name
{
    __block FFConflictAction chosen = FFConflictActionSkip;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"目标已存在"
            message:[NSString stringWithFormat:@"“%@” 已存在于当前目录。", name]
            preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionReplace;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"跳过" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkip;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"保留两者" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionKeepBoth;
                dispatch_semaphore_signal(semaphore);
            }]];
        // “应用于后续项目”：替换/跳过应用到剩余项目。
        [sheet addAction:[UIAlertAction actionWithTitle:@"应用于后续：全部替换"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionReplaceAll;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"应用于后续：全部跳过"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkipAll;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkip;
                dispatch_semaphore_signal(semaphore);
            }]];
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(
            self.view.bounds.size.width / 2, self.view.bounds.size.height - 60, 1, 1);
        [self presentOnTop:sheet];
    });
    // 超时兜底：90 秒未决策（例如页面已离开、弹窗被覆盖）按“跳过”处理，
    // 避免任务永久阻塞在冲突决策上。
    long timedOut = dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
    if (timedOut != 0) return FFConflictActionSkip;
    return chosen;
}

- (NSString *)uniqueDestinationForName:(NSString *)name
{
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."])
        return nil;
    NSString *candidate = [self.currentPath stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
        return candidate;
    NSString *extension = name.pathExtension;
    NSString *stem = extension.length ? name.stringByDeletingPathExtension : name;
    for (NSUInteger index = 1; index <= 999; index++) {
        NSString *suffix = index == 1 ? @" copy"
            : [NSString stringWithFormat:@" copy %lu", (unsigned long)index];
        NSString *copyName = [stem stringByAppendingString:suffix];
        if (extension.length) copyName = [copyName stringByAppendingPathExtension:extension];
        candidate = [self.currentPath stringByAppendingPathComponent:copyName];
        if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
            return candidate;
    }
    return nil;
}

- (void)createFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹"
        message:self.currentPath preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"文件夹名称";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text;
            if (![weakSelf validNewName:name]) return;
            NSString *path = [weakSelf.currentPath stringByAppendingPathComponent:name];
            NSError *error = nil;
            if (![[FFFileOperationService sharedService] createDirectoryAtPath:path error:&error])
                [weakSelf showError:error];
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createFile
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件"
        message:self.currentPath preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"文件名";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text;
            if (![weakSelf validNewName:name]) return;
            NSString *path = [weakSelf.currentPath stringByAppendingPathComponent:name];
            NSError *error = nil;
            if (![[FFFileOperationService sharedService] createEmptyFileAtPath:path error:&error])
                [weakSelf showError:error];
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleFavorite:(FFEntry *)item
{
    BOOL wasFavorite = [[FFFavoritesService sharedService] isFavoritePath:item.path];
    [[FFFavoritesService sharedService] togglePath:item.path
        name:item.displayName.length ? item.displayName : item.name
        isDirectory:item.isDirectory];
    [self flash:wasFavorite ? @"已取消收藏" : @"已收藏"];
}

- (void)duplicateEntry:(FFEntry *)item
{
    NSString *destination = [self uniqueDestinationForName:item.name];
    if (!destination) {
        [self flash:@"无法确定副本目标"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [FFCopyEngine copyItemAtPath:item.path toPath:destination error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [weakSelf flash:@"副本已创建"];
                [weakSelf reloadEntries];
            } else {
                [weakSelf showError:error];
            }
        });
    });
}

- (BOOL)validNewName:(NSString *)name
{
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@"\0"]) {
        [self flash:@"名称无效"];
        return NO;
    }
    return YES;
}

- (void)renameEntry:(FFEntry *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名"
        message:item.path preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = item.name;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *newName = alert.textFields.firstObject.text;
            if (![weakSelf validNewName:newName]) return;
            [weakSelf performRenameItem:item toName:newName overwrite:NO];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 重命名冲突处理：目标已存在时提供 取消 / 覆盖 / 保留两者。
- (void)performRenameItem:(FFEntry *)item toName:(NSString *)newName
                overwrite:(BOOL)overwrite
{
    NSString *newPath = [self.currentPath stringByAppendingPathComponent:newName];
    NSError *error = nil;
    if ([[FFFileOperationService sharedService] renameItemAtPath:item.path
        toPath:newPath overwrite:overwrite error:&error]) {
        [self reloadEntries];
        return;
    }
    if (error.code != EEXIST) {
        [self showError:error];
        [self reloadEntries];
        return;
    }
    // 目标存在：提供覆盖 / 保留两者 / 取消。
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"名称已存在"
        message:[NSString stringWithFormat:@"“%@” 已存在，是否覆盖？", newName]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"覆盖" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf performRenameItem:item toName:newName overwrite:YES];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"保留两者" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *copyName = [weakSelf uniqueDestinationForName:newName];
            if (!copyName) {
                [weakSelf flash:@"无法生成不冲突的名称"];
                return;
            }
            NSString *copyPath = [weakSelf.currentPath stringByAppendingPathComponent:copyName];
            NSError *moveError = nil;
            if (![[FFFileOperationService sharedService] renameItemAtPath:item.path
                toPath:copyPath error:&moveError])
                [weakSelf showError:moveError];
            [weakSelf reloadEntries];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height - 60, 1, 1);
    [self presentOnTop:sheet];
}

- (void)deleteEntry:(FFEntry *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除"
        message:[NSString stringWithFormat:@"确定删除 %@？", item.path]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            if (![[FFFileOperationService sharedService] removeItemAtPath:item.path error:&error]) {
                FFLogTag(@"Browser", @"delete FAIL path=%@ errno=%ld (%@)",
                    item.path, (long)error.code, error.localizedDescription);
                [weakSelf showError:error];
            }
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareEntry:(FFEntry *)item
{
    NSURL *url = [NSURL fileURLWithPath:item.path];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
        self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)copyPath:(FFEntry *)item
{
    UIPasteboard.generalPasteboard.string = item.path;
    [self flash:@"路径已复制"];
}

- (BOOL)isArchiveEntry:(FFEntry *)item
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 真实 zip 容器家族。.deb 明确排除：无解析后端，不再当作 ZIP/归档。
        extensions = [NSSet setWithArray:@[
            @"zip", @"ipa", @"xcarchive", @"appex", @"app",
            @"bundle", @"framework", @"war", @"jar", @"crx", @"xpi",
            @"docx", @"xlsx", @"pptx", @"pages", @"numbers", @"key",
            @"epub", @"apk",
        ]];
    });
    return [extensions containsObject:item.name.pathExtension.lowercaseString];
}

- (void)extractEntry:(FFEntry *)item
{
    NSString *stem = item.name.stringByDeletingPathExtension;
    if (stem.length == 0) stem = @"archive";
    NSString *sibling = [self.currentPath stringByAppendingPathComponent:
        [stem stringByAppendingString:@" (解压)"]];
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *extractedRoot = [[documents stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"Extracted"];
    NSString *fallbackDestination = [extractedRoot stringByAppendingPathComponent:
        [stem stringByAppendingFormat:@"-%@",
            [[[NSUUID UUID] UUIDString] substringToIndex:8]]];

    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindExtract;
    task.displayName = [NSString stringWithFormat:@"解压 %@", item.name];
    task.sources = @[item.path];
    // Prefer the sibling folder; sandbox-denied destinations fall back
    // to the app's own Documents on the next attempt (sibling write
    // failures leave the fallback path stored on the task).
    task.destination = sibling;
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    FFLogTag(@"Browser", @"extract task queued archive=%@ sibling=%@ fallback=%@",
             item.path, sibling, fallbackDestination);
    [self flash:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
}

// 属性从大段 Alert 升级为独立页面（ADR-013）；慢数据由
// FFFileInfoViewController 后台加载。
- (void)showProperties:(FFEntry *)item
{
    FFFileInfoViewController *info = [[FFFileInfoViewController alloc]
        initWithEntry:item icon:item.thumbnail ?: [self iconForEntry:item]];
    [self presentViewController:info animated:YES completion:nil];
}

#pragma mark - Preview

// 显式指定查看器打开（长按菜单：浏览压缩包 / 安装）。
- (void)openWithViewer:(FFEntry *)item viewerID:(NSString *)viewerID
{
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    [FFPreviewRouter openItem:item viewerID:viewerID navigationController:nav];
}

// 用其他查看器打开：列表式选择页（ADR-014），选中即设为默认关联并打开。
// 不再使用超长 Action Sheet。
- (void)openWithPicker:(FFEntry *)item
{
    FFViewerPickerViewController *picker =
        [[FFViewerPickerViewController alloc] initWithFile:item];
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    [nav pushViewController:picker animated:YES];
}

// Opens a path from search/favorites/recents: directories push a
// browser, files open the preview directly. Uses the caller's
// navigation controller (a freshly created browser has none).
- (void)openItemAtPath:(NSString *)path title:(NSString *)title
     navigationController:(UINavigationController *)nav
            completion:(void (^)(BOOL))completion
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) {
        if (completion) completion(NO);
        return;
    }
    // 符号链接：跟随目标判断类型（App Data 深层目录本身可以是链接）。
    BOOL isDirectory = S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
    if (S_ISLNK(status.st_mode)) {
        struct stat target = {0};
        if (stat(path.fileSystemRepresentation, &target) == 0 &&
            S_ISDIR(target.st_mode)) {
            isDirectory = YES;
        }
    }
    if (isDirectory) {
        FFBrowserViewController *browser =
            [[FFBrowserViewController alloc] initWithPath:path];
        browser.title = title.length ? title : path.lastPathComponent;
        [nav pushViewController:browser animated:YES];
        if (completion) completion(YES);
        return;
    }
    FFEntry *item = [FFEntry new];
    item.name = path.lastPathComponent;
    item.path = path;
    item.isDirectory = NO;
    item.isSymlink = S_ISLNK(status.st_mode);
    item.size = S_ISREG(status.st_mode) ? (unsigned long long)status.st_size : 0;
    item.modificationDate = [NSDate dateWithTimeIntervalSince1970:status.st_mtimespec.tv_sec];
    item.creationDate = [NSDate dateWithTimeIntervalSince1970:status.st_birthtimespec.tv_sec];
    item.mode = status.st_mode;
    item.uid = status.st_uid;
    item.gid = status.st_gid;
    if (item.isSymlink) {
        char target[PATH_MAX] = {0};
        ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
        if (length > 0) {
            target[length] = '\0';
            item.linkTarget = [NSString stringWithUTF8String:target];
        }
    }
    [FFPreviewRouter previewItem:item navigationController:nav];
    if (completion) completion(YES);
}

- (void)previewEntry:(FFEntry *)item
{
    [FFPreviewRouter previewItem:item navigationController:self.navigationController];
}










#pragma mark - Helpers

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentOnTop:alert];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
}

// UIKit silently drops presentViewController when an alert is already
// up; dismiss whatever is on top first so sequential prompts survive.
- (void)presentOnTop:(UIViewController *)controller
{
    if (self.presentedViewController) {
        UIViewController *presented = self.presentedViewController;
        [presented dismissViewControllerAnimated:NO completion:^{
            [self presentViewController:controller animated:YES completion:nil];
        }];
    } else {
        [self presentViewController:controller animated:YES completion:nil];
    }
}

- (void)showError:(NSError *)error
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
        message:error.localizedDescription ?: @"未知错误"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
