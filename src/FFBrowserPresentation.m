#import "FFBrowserViewController.h"
#import "MCMManager.h"

#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

// UI-only adapter around the mature browser implementation.
// File I/O, task execution, preview routing, imports and path policy stay in
// FFBrowserViewController / services; this file owns presentation plus a thin
// clipboard-UI synchronization layer.

static NSString *const FFUIClipboardStateDidChangeNotification =
    @"FFUIClipboardStateDidChangeNotification";

// The browser's clipboard storage remains the source of truth for operations.
// These mirrors are only used to keep every already-created browser screen in
// sync and to distinguish Copy from Cut for same-directory paste UX.
static NSInteger FFUIClipboardMode = 0; // 0 none, 1 copy, 2 cut
static BOOL FFUIClipboardActive = NO;

static const void *FFUIPathBarKey = &FFUIPathBarKey;
static const void *FFUIPathLabelKey = &FFUIPathLabelKey;
static const void *FFUIBottomBarKey = &FFUIBottomBarKey;
static const void *FFUIBottomStackKey = &FFUIBottomStackKey;

static void FFSwapBrowserMethod(Class cls, SEL original, SEL replacement)
{
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (!originalMethod || !replacementMethod) return;
    method_exchangeImplementations(originalMethod, replacementMethod);
}

static id FFUISendId(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL FFUISendBool(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void FFUISendVoid(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *FFBrowserCompactDate(NSDate *date)
{
    if (!date) return nil;
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return [formatter stringFromDate:date];
}

static NSString *FFBrowserCompactDetail(FFEntry *item)
{
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (item.isSymlink) {
        [parts addObject:@"链接"];
    } else if (item.isDirectory) {
        [parts addObject:@"文件夹"];
    } else {
        NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)item.size
            countStyle:NSByteCountFormatterCountStyleFile];
        if (size.length) [parts addObject:size];
    }
    NSString *date = FFBrowserCompactDate(item.modificationDate);
    if (date.length) [parts addObject:date];
    return [parts componentsJoinedByString:@" · "];
}

static NSString *FFBrowserDisplayPath(NSString *path)
{
    NSString *root = MCMVirtualRoot();
    if (!path.length) return @"Device Storage";
    if ([path isEqualToString:root]) return @"Device Storage";
    NSString *prefix = [root stringByAppendingString:@"/"];
    if ([path hasPrefix:prefix]) {
        NSString *tail = [path substringFromIndex:prefix.length];
        return tail.length ? [NSString stringWithFormat:@"Device Storage / %@", tail]
                           : @"Device Storage";
    }
    return path;
}

static BOOL FFExtensionIn(NSString *ext, NSArray<NSString *> *values)
{
    return [values containsObject:ext ?: @""];
}

@interface FFBrowserViewController (FFBrowserPresentation)
- (void)ffui_viewDidLoad;
- (void)ffui_viewWillAppear:(BOOL)animated;
- (void)ffui_setEditing:(BOOL)editing animated:(BOOL)animated;
- (void)ffui_configureCell:(UITableViewCell *)cell withItem:(FFEntry *)item;
- (CGSize)ffui_collectionView:(UICollectionView *)collectionView
                       layout:(UICollectionViewLayout *)collectionViewLayout
       sizeForItemAtIndexPath:(NSIndexPath *)indexPath;
- (UICollectionViewCell *)ffui_collectionView:(UICollectionView *)collectionView
                        cellForItemAtIndexPath:(NSIndexPath *)indexPath;
- (UIImage *)ffui_iconForEntry:(FFEntry *)item;
- (UIColor *)ffui_tintForEntry:(FFEntry *)item;

// Clipboard behavior/visual synchronization.
- (void)ffui_setClipboard:(FFEntry *)item mode:(NSInteger)mode;
- (void)ffui_batchSetClipboard:(NSInteger)mode;
- (NSArray<NSString *> *)ffui_clipboardSourcesInCurrentDirectory;
- (void)ffui_cancelPaste;
- (void)ffui_pasteAction:(id)sender;
- (void)ffui_showPasteBanner;

// Custom preview-style chrome.
- (void)ffui_installBrowserChrome;
- (void)ffui_refreshBottomBar;
- (void)ffui_syncClipboardChrome;
- (UIButton *)ffui_buttonWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                          selector:(SEL)selector
                              tint:(UIColor *)tint;
- (UIButton *)ffui_menuButtonWithTitle:(NSString *)title
                                symbol:(NSString *)symbol
                                  menu:(UIMenu *)menu;
- (UIMenu *)ffui_viewMenu;
@end

@implementation FFBrowserViewController (FFBrowserPresentation)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FFBrowserViewController.class;
        FFSwapBrowserMethod(cls, @selector(viewDidLoad), @selector(ffui_viewDidLoad));
        FFSwapBrowserMethod(cls, @selector(viewWillAppear:), @selector(ffui_viewWillAppear:));
        FFSwapBrowserMethod(cls, @selector(setEditing:animated:),
                            @selector(ffui_setEditing:animated:));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"configureCell:withItem:"),
                            @selector(ffui_configureCell:withItem:));
        FFSwapBrowserMethod(cls,
            @selector(collectionView:layout:sizeForItemAtIndexPath:),
            @selector(ffui_collectionView:layout:sizeForItemAtIndexPath:));
        FFSwapBrowserMethod(cls,
            @selector(collectionView:cellForItemAtIndexPath:),
            @selector(ffui_collectionView:cellForItemAtIndexPath:));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"iconForEntry:"),
                            @selector(ffui_iconForEntry:));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"tintForEntry:"),
                            @selector(ffui_tintForEntry:));

        FFSwapBrowserMethod(cls, NSSelectorFromString(@"setClipboard:mode:"),
                            @selector(ffui_setClipboard:mode:));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"batchSetClipboard:"),
                            @selector(ffui_batchSetClipboard:));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"clipboardSourcesInCurrentDirectory"),
                            @selector(ffui_clipboardSourcesInCurrentDirectory));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"cancelPaste"),
                            @selector(ffui_cancelPaste));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"pasteAction:"),
                            @selector(ffui_pasteAction:));
        FFSwapBrowserMethod(cls, NSSelectorFromString(@"showPasteBanner"),
                            @selector(ffui_showPasteBanner));
    });
}

#pragma mark - Lifecycle / chrome

- (void)ffui_viewDidLoad
{
    // Calls the original -viewDidLoad after swizzling.
    [self ffui_viewDidLoad];

    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.searchController.searchBar.placeholder = @"搜索当前目录";
    self.tableView.estimatedRowHeight = 68;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 72, 0, 16);
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;

    // Reserve real space for the path strip and the custom four-action bar.
    // This also makes the existing paste banner naturally sit above the bar.
    UIEdgeInsets safeInsets = self.additionalSafeAreaInsets;
    safeInsets.top = MAX(safeInsets.top, 30.0);
    safeInsets.bottom = MAX(safeInsets.bottom, 72.0);
    self.additionalSafeAreaInsets = safeInsets;

    [self ffui_installBrowserChrome];

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:FFUIClipboardStateDidChangeNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(__unused NSNotification *note) {
            [weakSelf ffui_syncClipboardChrome];
        }];
}

- (void)ffui_viewWillAppear:(BOOL)animated
{
    // Calls the original -viewWillAppear: after swizzling.
    [self ffui_viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    // The preview uses a fixed in-content action bar, not the iOS 27 glass
    // UINavigationController toolbar (which renders as two floating circles).
    [self.navigationController setToolbarHidden:YES animated:NO];
    [self ffui_refreshBottomBar];
    [self ffui_syncClipboardChrome];
}

- (void)ffui_setEditing:(BOOL)editing animated:(BOOL)animated
{
    [self ffui_setEditing:editing animated:animated];
    [self.navigationController setToolbarHidden:YES animated:NO];

    // Match the approved selection hierarchy: 全选 | 已选择 N 项 | 取消.
    if (editing) {
        UIBarButtonItem *selectAll = [[UIBarButtonItem alloc]
            initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self
            action:NSSelectorFromString(@"batchSelectAll")];
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc]
            initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self
            action:NSSelectorFromString(@"cancelBatchMode")];
        self.navigationItem.leftBarButtonItem = selectAll;
        self.navigationItem.rightBarButtonItems = @[cancel];
    }
    [self ffui_refreshBottomBar];
}

- (void)ffui_installBrowserChrome
{
    if (objc_getAssociatedObject(self, FFUIPathBarKey)) return;

    UIView *pathBar = [UIView new];
    pathBar.translatesAutoresizingMaskIntoConstraints = NO;
    pathBar.backgroundColor = UIColor.systemBackgroundColor;
    pathBar.layer.zPosition = 1000;
    [self.view addSubview:pathBar];
    objc_setAssociatedObject(self, FFUIPathBarKey, pathBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *pathLabel = [UILabel new];
    pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    pathLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    pathLabel.textColor = UIColor.secondaryLabelColor;
    pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    pathLabel.numberOfLines = 1;
    pathLabel.text = FFBrowserDisplayPath(self.currentPath);
    [pathBar addSubview:pathLabel];
    objc_setAssociatedObject(self, FFUIPathLabelKey, pathLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *pathSeparator = [UIView new];
    pathSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    pathSeparator.backgroundColor = UIColor.separatorColor;
    [pathBar addSubview:pathSeparator];

    [NSLayoutConstraint activateConstraints:@[
        [pathBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [pathBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [pathBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [pathBar.heightAnchor constraintEqualToConstant:30],
        [pathLabel.leadingAnchor constraintEqualToAnchor:pathBar.leadingAnchor constant:16],
        [pathLabel.trailingAnchor constraintEqualToAnchor:pathBar.trailingAnchor constant:-16],
        [pathLabel.centerYAnchor constraintEqualToAnchor:pathBar.centerYAnchor constant:-1],
        [pathSeparator.leadingAnchor constraintEqualToAnchor:pathBar.leadingAnchor],
        [pathSeparator.trailingAnchor constraintEqualToAnchor:pathBar.trailingAnchor],
        [pathSeparator.bottomAnchor constraintEqualToAnchor:pathBar.bottomAnchor],
        [pathSeparator.heightAnchor constraintEqualToConstant:0.5],
    ]];

    UIView *bottomBar = [UIView new];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    bottomBar.layer.zPosition = 1000;
    [self.view addSubview:bottomBar];
    objc_setAssociatedObject(self, FFUIBottomBarKey, bottomBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *topSeparator = [UIView new];
    topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    topSeparator.backgroundColor = UIColor.separatorColor;
    [bottomBar addSubview:topSeparator];

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 2;
    [bottomBar addSubview:stack];
    objc_setAssociatedObject(self, FFUIBottomStackKey, stack, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [NSLayoutConstraint activateConstraints:@[
        // additionalSafeAreaInsets.bottom reserves 72 pt; this bar occupies
        // that reserved strip plus the physical home-indicator inset.
        [bottomBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [topSeparator.topAnchor constraintEqualToAnchor:bottomBar.topAnchor],
        [topSeparator.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor],
        [topSeparator.heightAnchor constraintEqualToConstant:0.5],
        [stack.topAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:5],
        [stack.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor constant:-10],
        [stack.heightAnchor constraintEqualToConstant:58],
    ]];

    [self ffui_refreshBottomBar];
}

- (UIButton *)ffui_buttonWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                          selector:(SEL)selector
                              tint:(UIColor *)tint
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePlacement = NSDirectionalRectEdgeTop;
    configuration.imagePadding = 3;
    configuration.baseForegroundColor = tint ?: UIColor.systemBlueColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(3, 4, 3, 4);
    button.configuration = configuration;
    if (selector) [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)ffui_menuButtonWithTitle:(NSString *)title
                                symbol:(NSString *)symbol
                                  menu:(UIMenu *)menu
{
    UIButton *button = [self ffui_buttonWithTitle:title symbol:symbol selector:nil tint:nil];
    button.menu = menu;
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

- (UIMenu *)ffui_viewMenu
{
    BOOL gridEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"FFSettingsGridMode"];
    UIAction *list = [UIAction actionWithTitle:@"列表"
        image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil
        handler:^(__unused UIAction *action) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FFSettingsGridMode"];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"FFSettingsChangedNotification" object:nil];
        }];
    list.state = gridEnabled ? UIMenuElementStateOff : UIMenuElementStateOn;

    UIAction *grid = [UIAction actionWithTitle:@"网格"
        image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil
        handler:^(__unused UIAction *action) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FFSettingsGridMode"];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"FFSettingsChangedNotification" object:nil];
        }];
    grid.state = gridEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@"视图" children:@[list, grid]];
}

- (void)ffui_refreshBottomBar
{
    UIStackView *stack = objc_getAssociatedObject(self, FFUIBottomStackKey);
    if (!stack) return;
    for (UIView *view in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (!self.editing) {
        UIAction *newFolder = [UIAction actionWithTitle:@"新建文件夹"
            image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
            handler:^(__unused UIAction *action) { FFUISendVoid(self, @"createFolder"); }];
        UIAction *newFile = [UIAction actionWithTitle:@"新建文件"
            image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil
            handler:^(__unused UIAction *action) { FFUISendVoid(self, @"createFile"); }];
        UIAction *refresh = [UIAction actionWithTitle:@"刷新"
            image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil
            handler:^(__unused UIAction *action) { [self reloadEntries]; }];
        UIMenu *newMenu = [UIMenu menuWithTitle:@"新建" children:@[newFolder, newFile, refresh]];

        UIMenu *sortMenu = FFUISendId(self, @"sortMenu");
        if (!sortMenu) sortMenu = [UIMenu menuWithTitle:@"排序" children:@[]];

        NSArray<UIButton *> *buttons = @[
            [self ffui_menuButtonWithTitle:@"新建" symbol:@"plus" menu:newMenu],
            [self ffui_menuButtonWithTitle:@"排序" symbol:@"arrow.up.arrow.down" menu:sortMenu],
            [self ffui_menuButtonWithTitle:@"视图" symbol:@"square.grid.2x2" menu:[self ffui_viewMenu]],
            [self ffui_buttonWithTitle:@"选择" symbol:@"checkmark.circle"
                selector:NSSelectorFromString(@"toggleBatchMode") tint:nil],
        ];
        for (UIButton *button in buttons) [stack addArrangedSubview:button];
    } else {
        UIAction *compress = [UIAction actionWithTitle:@"压缩"
            image:[UIImage systemImageNamed:@"archivebox"] identifier:nil
            handler:^(__unused UIAction *action) { FFUISendVoid(self, @"batchCompress"); }];
        UIAction *share = [UIAction actionWithTitle:@"分享"
            image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
            handler:^(__unused UIAction *action) { FFUISendVoid(self, @"batchShare"); }];
        UIMenu *more = [UIMenu menuWithTitle:@"更多" children:@[compress, share]];

        NSArray<UIButton *> *buttons = @[
            [self ffui_buttonWithTitle:@"复制" symbol:@"doc.on.doc"
                selector:NSSelectorFromString(@"batchCopy") tint:nil],
            [self ffui_buttonWithTitle:@"移动" symbol:@"folder"
                selector:NSSelectorFromString(@"batchCut") tint:nil],
            [self ffui_buttonWithTitle:@"删除" symbol:@"trash"
                selector:NSSelectorFromString(@"batchDelete") tint:UIColor.systemRedColor],
            [self ffui_menuButtonWithTitle:@"更多" symbol:@"ellipsis" menu:more],
        ];
        for (UIButton *button in buttons) [stack addArrangedSubview:button];
    }
}

#pragma mark - Clipboard fixes

- (void)ffui_setClipboard:(FFEntry *)item mode:(NSInteger)mode
{
    FFUIClipboardMode = mode;
    FFUIClipboardActive = YES;
    [self ffui_setClipboard:item mode:mode];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFUIClipboardStateDidChangeNotification object:nil];
}

- (void)ffui_batchSetClipboard:(NSInteger)mode
{
    FFUIClipboardMode = mode;
    FFUIClipboardActive = YES;
    [self ffui_batchSetClipboard:mode];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFUIClipboardStateDidChangeNotification object:nil];
}

- (NSArray<NSString *> *)ffui_clipboardSourcesInCurrentDirectory
{
    // Copying in the source directory is valid: the task conflict flow can
    // create a second copy. Only Cut/Move in the same directory must be ignored.
    if (FFUIClipboardMode == 1) return @[];
    return [self ffui_clipboardSourcesInCurrentDirectory];
}

- (void)ffui_cancelPaste
{
    [self ffui_cancelPaste];
    FFUIClipboardMode = 0;
    FFUIClipboardActive = NO;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:FFUIClipboardStateDidChangeNotification object:nil];
}

- (void)ffui_pasteAction:(id)sender
{
    // Compute blockers before the original method mutates clipboard state.
    BOOL blockedInsideSource = FFUISendBool(self, @"pasteIsInsideClipboardSource");
    // Calling the swapped selector directly reaches the original implementation,
    // giving the real same-directory set even though Copy intentionally exposes
    // an empty set to the original pasteAction.
    NSArray<NSString *> *actualSameDirectory = [self ffui_clipboardSourcesInCurrentDirectory];
    BOOL blockedSameDirectoryCut = FFUIClipboardMode == 2 && actualSameDirectory.count > 0;

    [self ffui_pasteAction:sender];

    if (!blockedInsideSource && !blockedSameDirectoryCut && FFUIClipboardActive) {
        // A paste consumes both Copy and Cut clipboard state in FuckFile. Clear
        // every already-created browser's banner, not only the visible folder.
        FFUIClipboardMode = 0;
        FFUIClipboardActive = NO;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:FFUIClipboardStateDidChangeNotification object:nil];
    }
}

- (void)ffui_showPasteBanner
{
    [self ffui_showPasteBanner];
    // The existing banner already anchors to safeAreaLayoutGuide.bottomAnchor;
    // the added 72 pt bottom safe area therefore places it directly above the
    // custom action bar. Only refine its card styling here.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *banner = [self.view viewWithTag:9347];
        if (!banner) return;
        banner.backgroundColor = UIColor.tertiarySystemBackgroundColor;
        banner.layer.cornerRadius = 16;
        banner.layer.borderWidth = 0.5;
        banner.layer.borderColor = UIColor.separatorColor.CGColor;
    });
}

- (void)ffui_syncClipboardChrome
{
    if (FFUIClipboardActive) return;
    UIView *banner = [self.view viewWithTag:9347];
    [banner.layer removeAllAnimations];
    [banner removeFromSuperview];
}

#pragma mark - File list presentation

- (void)ffui_configureCell:(UITableViewCell *)cell withItem:(FFEntry *)item
{
    // Preserve thumbnail generation, async refresh and accessory behavior, then
    // restyle only the content configuration.
    [self ffui_configureCell:cell withItem:item];

    id<UIContentConfiguration> current = cell.contentConfiguration;
    if (![(id)current isKindOfClass:UIListContentConfiguration.class]) return;
    UIListContentConfiguration *config = (UIListContentConfiguration *)current;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.numberOfLines = 1;
    config.secondaryText = FFBrowserCompactDetail(item);
    config.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.secondaryTextProperties.numberOfLines = 1;
    config.imageProperties.maximumSize = CGSizeMake(38, 38);
    config.imageProperties.cornerRadius = 7;
    config.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(9, 16, 9, 12);
    cell.contentConfiguration = config;
    cell.backgroundColor = UIColor.systemBackgroundColor;
}

- (UIImage *)ffui_iconForEntry:(FFEntry *)item
{
    if (item.isDirectory) return [UIImage systemImageNamed:@"folder.fill"];
    if (item.isSymlink) return [UIImage systemImageNamed:@"link"];

    NSString *ext = item.name.pathExtension.lowercaseString;
    NSString *symbol = nil;

    if ([ext isEqualToString:@"ipa"]) symbol = @"app.badge";
    else if (FFExtensionIn(ext, @[@"zip", @"rar", @"7z", @"tar", @"gz", @"xz", @"bz2"])) symbol = @"archivebox.fill";
    else if ([ext isEqualToString:@"pdf"]) symbol = @"doc.richtext";
    else if (FFExtensionIn(ext, @[@"doc", @"docx", @"rtf", @"pages"])) symbol = @"doc.text.fill";
    else if (FFExtensionIn(ext, @[@"xls", @"xlsx", @"csv", @"numbers"])) symbol = @"tablecells";
    else if (FFExtensionIn(ext, @[@"ppt", @"pptx", @"key"])) symbol = @"rectangle.on.rectangle.angled";
    else if (FFExtensionIn(ext, @[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp", @"tendies"])) symbol = @"photo.fill";
    else if (FFExtensionIn(ext, @[@"mp4", @"mov", @"m4v", @"avi", @"mkv"])) symbol = @"film.fill";
    else if (FFExtensionIn(ext, @[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"])) symbol = @"waveform";
    else if ([ext isEqualToString:@"plist"]) symbol = @"list.bullet.rectangle.fill";
    else if (FFExtensionIn(ext, @[@"db", @"sqlite", @"sqlite3"])) symbol = @"cylinder.fill";
    else if (FFExtensionIn(ext, @[@"json", @"xml"])) symbol = @"curlybraces";
    else if (FFExtensionIn(ext, @[@"html", @"htm", @"css", @"js", @"ts", @"c", @"h", @"m", @"mm", @"swift", @"py", @"java", @"kt", @"go", @"rs", @"rb", @"php", @"sh", @"command"])) symbol = @"chevron.left.forwardslash.chevron.right";
    else if (FFExtensionIn(ext, @[@"txt", @"log", @"md"])) symbol = @"doc.plaintext";
    else if (FFExtensionIn(ext, @[@"key", @"mobileconfig", @"cer", @"p12", @"crt"])) symbol = @"lock.doc.fill";
    else if (FFExtensionIn(ext, @[@"app", @"bundle", @"framework", @"dylib"])) symbol = @"shippingbox.fill";
    else symbol = @"doc.fill";

    UIImage *image = [UIImage systemImageNamed:symbol];
    return image ?: [self ffui_iconForEntry:item];
}

- (UIColor *)ffui_tintForEntry:(FFEntry *)item
{
    if (item.isDirectory) return UIColor.systemBlueColor;
    if (item.isSymlink) return UIColor.systemTealColor;

    NSString *ext = item.name.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ipa"]) return UIColor.systemIndigoColor;
    if (FFExtensionIn(ext, @[@"zip", @"rar", @"7z", @"tar", @"gz", @"xz", @"bz2"])) return UIColor.systemOrangeColor;
    if ([ext isEqualToString:@"pdf"]) return UIColor.systemRedColor;
    if (FFExtensionIn(ext, @[@"doc", @"docx", @"rtf", @"pages"])) return UIColor.systemBlueColor;
    if (FFExtensionIn(ext, @[@"xls", @"xlsx", @"csv", @"numbers"])) return UIColor.systemGreenColor;
    if (FFExtensionIn(ext, @[@"ppt", @"pptx", @"key"])) return UIColor.systemOrangeColor;
    if (FFExtensionIn(ext, @[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp", @"tendies"])) return UIColor.systemPinkColor;
    if (FFExtensionIn(ext, @[@"mp4", @"mov", @"m4v", @"avi", @"mkv"])) return UIColor.systemPurpleColor;
    if (FFExtensionIn(ext, @[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"])) return UIColor.systemPinkColor;
    if (FFExtensionIn(ext, @[@"plist", @"db", @"sqlite", @"sqlite3"])) return UIColor.systemPurpleColor;
    if (FFExtensionIn(ext, @[@"html", @"htm", @"css", @"js", @"ts", @"c", @"h", @"m", @"mm", @"swift", @"py", @"java", @"kt", @"go", @"rs", @"rb", @"php", @"sh", @"command", @"json", @"xml"])) return UIColor.systemTealColor;
    if (FFExtensionIn(ext, @[@"key", @"mobileconfig", @"cer", @"p12", @"crt"])) return UIColor.systemYellowColor;
    if (FFExtensionIn(ext, @[@"app", @"bundle", @"framework", @"dylib"])) return UIColor.systemIndigoColor;
    return UIColor.secondaryLabelColor;
}

#pragma mark - Adaptive grid

- (CGSize)ffui_collectionView:(UICollectionView *)collectionView
                       layout:(UICollectionViewLayout *)collectionViewLayout
       sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    // Preserve the original iOS 27 crash rule: all widths are floored and an
    // extremely narrow layout receives a defensive fallback size.
    UICollectionViewFlowLayout *layout =
        [collectionViewLayout isKindOfClass:UICollectionViewFlowLayout.class]
            ? (UICollectionViewFlowLayout *)collectionViewLayout : nil;
    if (!layout) {
        return [self ffui_collectionView:collectionView layout:collectionViewLayout
                  sizeForItemAtIndexPath:indexPath];
    }

    CGFloat horizontalInsets = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat spacing = MAX(0, layout.minimumInteritemSpacing);
    CGFloat available = collectionView.bounds.size.width - horizontalInsets;
    if (!isfinite(available) || available < 88) return CGSizeMake(44, 72);

    const CGFloat targetWidth = 108.0;
    NSInteger columns = (NSInteger)floor((available + spacing) / (targetWidth + spacing));
    columns = MAX(2, MIN(columns, 8));
    CGFloat totalSpacing = spacing * MAX(0, columns - 1);
    CGFloat width = floor((available - totalSpacing) / columns);
    if (!isfinite(width) || width < 44) return CGSizeMake(44, 72);
    return CGSizeMake(width, width + 30);
}

- (UICollectionViewCell *)ffui_collectionView:(UICollectionView *)collectionView
                        cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell =
        [self ffui_collectionView:collectionView cellForItemAtIndexPath:indexPath];
    UIView *content = [cell.contentView viewWithTag:999];
    if (![content conformsToProtocol:@protocol(UIContentView)]) return cell;

    id<UIContentView> contentView = (id<UIContentView>)content;
    id<UIContentConfiguration> current = contentView.configuration;
    if (![(id)current isKindOfClass:UIListContentConfiguration.class]) return cell;
    UIListContentConfiguration *config = (UIListContentConfiguration *)current;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.textProperties.numberOfLines = 1;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.imageProperties.maximumSize = CGSizeMake(52, 52);
    config.imageProperties.cornerRadius = 9;
    contentView.configuration = config;
    return cell;
}

@end
