#import "FFPdfPreviewViewController.h"
#import "FFBrowserViewController.h"
#import "FFFileInfoViewController.h"
#import "FFLogger.h"

#import <PDFKit/PDFKit.h>

@interface FFPDFOutlineItem : NSObject
@property(nonatomic, strong) PDFOutline *outline;
@property(nonatomic) NSInteger level;
@end
@implementation FFPDFOutlineItem @end

static void FFAppendPDFOutlineItems(PDFOutline *node, NSInteger level,
                                    NSMutableArray<FFPDFOutlineItem *> *items)
{
    if (!node || !items) return;
    for (NSInteger i = 0; i < node.numberOfChildren; i++) {
        PDFOutline *child = [node childAtIndex:i];
        if (!child) continue;
        FFPDFOutlineItem *item = [FFPDFOutlineItem new];
        item.outline = child;
        item.level = level;
        [items addObject:item];
        FFAppendPDFOutlineItems(child, level + 1, items);
    }
}

@interface FFPDFOutlineViewController : UITableViewController
@property(nonatomic, weak) PDFView *pdfView;
@property(nonatomic, strong) NSArray<FFPDFOutlineItem *> *items;
- (instancetype)initWithDocument:(PDFDocument *)document pdfView:(PDFView *)pdfView;
@end

@implementation FFPDFOutlineViewController
- (instancetype)initWithDocument:(PDFDocument *)document pdfView:(PDFView *)pdfView
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _pdfView = pdfView;
        self.title = @"目录";
        NSMutableArray<FFPDFOutlineItem *> *items = [NSMutableArray array];
        FFAppendPDFOutlineItems(document.outlineRoot, 0, items);
        _items = [items copy];
    }
    return self;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.items.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Outline"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Outline"];
    FFPDFOutlineItem *item = self.items[indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = item.outline.label ?: @"未命名";
    config.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, MIN(40, item.level * 14), 0, 0);
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PDFOutline *outline = self.items[indexPath.row].outline;
    PDFDestination *destination = outline.destination;
    if (destination) {
        [self.pdfView goToDestination:destination];
    } else if (outline.action && [outline.action isKindOfClass:PDFActionGoTo.class]) {
        [self.pdfView goToDestination:((PDFActionGoTo *)outline.action).destination];
    }
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface FFPDFThumbnailPanelController : UIViewController
@property(nonatomic, weak) PDFView *pdfView;
@property(nonatomic, strong) PDFThumbnailView *thumbnailView;
- (instancetype)initWithPDFView:(PDFView *)pdfView;
@end

@implementation FFPDFThumbnailPanelController
- (instancetype)initWithPDFView:(PDFView *)pdfView
{
    self = [super init];
    if (self) {
        _pdfView = pdfView;
        self.title = @"页面缩略图";
    }
    return self;
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDFThumbnailView *thumb = [PDFThumbnailView new];
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    thumb.PDFView = self.pdfView;
    thumb.layoutMode = PDFThumbnailLayoutModeVertical;
    thumb.thumbnailSize = CGSizeMake(92, 124);
    thumb.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self.view addSubview:thumb];
    self.thumbnailView = thumb;
    [NSLayoutConstraint activateConstraints:@[
        [thumb.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [thumb.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [thumb.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [thumb.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}
- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

@interface FFPdfPreviewViewController () <PDFViewDelegate, UITextFieldDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) PDFView *pdfView;
@property(nonatomic, strong) PDFDocument *document;
@property(nonatomic, strong) UIButton *pageButton;
@property(nonatomic, strong) UIView *searchBar;
@property(nonatomic, strong) UITextField *searchField;
@property(nonatomic, strong) UILabel *searchCountLabel;
@property(nonatomic, strong) UIButton *searchPrevButton;
@property(nonatomic, strong) UIButton *searchNextButton;
@property(nonatomic, strong) NSArray<PDFSelection *> *searchResults;
@property(nonatomic) NSInteger searchIndex;
@property(nonatomic) NSUInteger searchGeneration;
@end

@implementation FFPdfPreviewViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _filePath = [path copy];
        self.title = path.lastPathComponent;
        _searchIndex = -1;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.pdfView = [PDFView new];
    self.pdfView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pdfView.autoScales = YES;
    self.pdfView.displayMode = kPDFDisplaySinglePageContinuous;
    self.pdfView.displayDirection = kPDFDisplayDirectionVertical;
    self.pdfView.displaysPageBreaks = YES;
    self.pdfView.pageShadowsEnabled = YES;
    self.pdfView.delegate = self;
    [self.view addSubview:self.pdfView];
    [NSLayoutConstraint activateConstraints:@[
        [self.pdfView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.pdfView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.pdfView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.pdfView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self setupPageChip];
    [self setupNavigation];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pageChanged:)
        name:PDFViewPageChangedNotification object:self.pdfView];
    [self loadDocument];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupNavigation
{
    UIBarButtonItem *search = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showSearch)];
    UIBarButtonItem *more = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    more.menu = [self buildMenu];
    self.navigationItem.rightBarButtonItems = @[more, search];
}

- (void)setupPageChip
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    [button setTitle:@"– / –" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(promptGoToPage) forControlEvents:UIControlEventTouchUpInside];
    button.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.92];
    button.layer.cornerRadius = 15;
    button.layer.masksToBounds = YES;
    [self.view addSubview:button];
    self.pageButton = button;
    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [button.heightAnchor constraintEqualToConstant:30],
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:74],
    ]];
}

- (UIMenu *)inlineMenuWithTitle:(NSString *)title children:(NSArray<UIMenuElement *> *)children
{
    return [UIMenu menuWithTitle:title image:nil identifier:nil
                         options:UIMenuOptionsDisplayInline children:children];
}

- (UIMenu *)buildMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *thumbs = [UIAction actionWithTitle:@"页面缩略图"
        image:[UIImage systemImageNamed:@"rectangle.grid.2x2"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf showThumbnails]; }];
    UIAction *outline = [UIAction actionWithTitle:@"目录"
        image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf showOutline]; }];
    outline.attributes = self.document.outlineRoot ? 0 : UIMenuElementAttributesDisabled;
    UIAction *jump = [UIAction actionWithTitle:@"跳转到页面"
        image:[UIImage systemImageNamed:@"number"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf promptGoToPage]; }];

    UIAction *continuous = [UIAction actionWithTitle:@"连续滚动" image:nil identifier:nil
        handler:^(__unused UIAction *a) {
            weakSelf.pdfView.displayMode = kPDFDisplaySinglePageContinuous;
            weakSelf.pdfView.displayDirection = kPDFDisplayDirectionVertical;
            [weakSelf refreshMenu];
        }];
    continuous.state = self.pdfView.displayMode == kPDFDisplaySinglePageContinuous
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *single = [UIAction actionWithTitle:@"单页" image:nil identifier:nil
        handler:^(__unused UIAction *a) {
            weakSelf.pdfView.displayMode = kPDFDisplaySinglePage;
            [weakSelf refreshMenu];
        }];
    single.state = self.pdfView.displayMode == kPDFDisplaySinglePage
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *twoUp = [UIAction actionWithTitle:@"双页" image:nil identifier:nil
        handler:^(__unused UIAction *a) {
            weakSelf.pdfView.displayMode = kPDFDisplayTwoUpContinuous;
            [weakSelf refreshMenu];
        }];
    twoUp.state = self.pdfView.displayMode == kPDFDisplayTwoUpContinuous
        ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *fit = [UIAction actionWithTitle:@"适合页面"
        image:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"] identifier:nil
        handler:^(__unused UIAction *a) { weakSelf.pdfView.autoScales = YES; }];
    UIAction *actual = [UIAction actionWithTitle:@"实际大小"
        image:[UIImage systemImageNamed:@"1.magnifyingglass"] identifier:nil
        handler:^(__unused UIAction *a) {
            weakSelf.pdfView.autoScales = NO;
            weakSelf.pdfView.scaleFactor = 1.0;
        }];
    UIAction *back = [UIAction actionWithTitle:@"上一个位置"
        image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf.pdfView goBack:nil]; }];
    UIAction *forward = [UIAction actionWithTitle:@"下一个位置"
        image:[UIImage systemImageNamed:@"arrow.uturn.forward"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf.pdfView goForward:nil]; }];
    back.attributes = self.pdfView.canGoBack ? 0 : UIMenuElementAttributesDisabled;
    forward.attributes = self.pdfView.canGoForward ? 0 : UIMenuElementAttributesDisabled;

    UIAction *share = [UIAction actionWithTitle:@"分享"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf share]; }];
    UIAction *info = [UIAction actionWithTitle:@"文件信息"
        image:[UIImage systemImageNamed:@"info.circle"] identifier:nil
        handler:^(__unused UIAction *a) { [weakSelf showFileInfo]; }];

    return [UIMenu menuWithTitle:@"" children:@[
        thumbs, outline, jump,
        [self inlineMenuWithTitle:@"阅读模式" children:@[continuous, single, twoUp]],
        [self inlineMenuWithTitle:@"缩放" children:@[fit, actual]],
        [self inlineMenuWithTitle:@"导航" children:@[back, forward]],
        [self inlineMenuWithTitle:@"" children:@[share, info]],
    ]];
}

- (void)refreshMenu
{
    UIBarButtonItem *more = self.navigationItem.rightBarButtonItems.firstObject;
    more.menu = [self buildMenu];
}

- (void)loadDocument
{
    NSString *path = self.filePath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PDFDocument *document = [[PDFDocument alloc]
            initWithURL:[NSURL fileURLWithPath:path]];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!document) {
                [self showLoadFailure:@"文件损坏或不可读。"]; return;
            }
            self.document = document;
            if (document.isLocked) {
                [self promptForPasswordWithMessage:@"请输入密码以打开文档。"]; return;
            }
            [self attachDocument];
        });
    });
}

- (void)attachDocument
{
    self.pdfView.document = self.document;
    self.pdfView.autoScales = YES;
    [self updatePageIndicator];
    [self refreshMenu];
    FFLogTag(@"Preview", @"pdf opened path=%@ pages=%lu",
        self.filePath, (unsigned long)self.document.pageCount);
}

- (void)promptForPasswordWithMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"PDF 已加密"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.secureTextEntry = YES;
        field.placeholder = @"密码";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"解锁" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
            NSString *password = alert.textFields.firstObject.text ?: @"";
            if ([weakSelf.document unlockWithPassword:password]) {
                [weakSelf attachDocument];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf promptForPasswordWithMessage:@"密码错误，请重新输入。"];
                });
            }
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pageChanged:(NSNotification *)note
{
    (void)note;
    [self updatePageIndicator];
    [self refreshMenu];
}

- (void)updatePageIndicator
{
    if (!self.document || self.document.pageCount == 0) {
        [self.pageButton setTitle:@"– / –" forState:UIControlStateNormal];
        return;
    }
    PDFPage *page = self.pdfView.currentPage ?: [self.document pageAtIndex:0];
    NSInteger index = page ? [self.document indexForPage:page] : 0;
    [self.pageButton setTitle:[NSString stringWithFormat:@"%ld / %lu",
        (long)index + 1, (unsigned long)self.document.pageCount]
        forState:UIControlStateNormal];
}

- (void)promptGoToPage
{
    if (!self.document.pageCount) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跳转到页面"
        message:[NSString stringWithFormat:@"共 %lu 页", (unsigned long)self.document.pageCount]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"页码";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
            NSInteger page = alert.textFields.firstObject.text.integerValue;
            if (page < 1 || page > (NSInteger)weakSelf.document.pageCount) return;
            [weakSelf.pdfView goToPage:[weakSelf.document pageAtIndex:page - 1]];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showThumbnails
{
    if (!self.document) return;
    FFPDFThumbnailPanelController *panel =
        [[FFPDFThumbnailPanelController alloc] initWithPDFView:self.pdfView];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.modalPresentationStyle = UIModalPresentationPopover;
        nav.preferredContentSize = CGSizeMake(320, 620);
        nav.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    } else {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            nav.sheetPresentationController.detents = @[
                UISheetPresentationControllerDetent.mediumDetent,
                UISheetPresentationControllerDetent.largeDetent,
            ];
        }
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showOutline
{
    if (!self.document.outlineRoot) return;
    FFPDFOutlineViewController *outline = [[FFPDFOutlineViewController alloc]
        initWithDocument:self.document pdfView:self.pdfView];
    [self.navigationController pushViewController:outline animated:YES];
}

- (void)showSearch
{
    if (!self.document) return;
    if (self.searchBar) {
        [self.searchField becomeFirstResponder];
        return;
    }

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.layer.cornerRadius = 12;
    blur.layer.masksToBounds = YES;
    [self.view addSubview:blur];
    self.searchBar = blur;
    self.pageButton.hidden = YES;

    UITextField *field = [UITextField new];
    field.placeholder = @"搜索 PDF";
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.returnKeyType = UIReturnKeySearch;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged];
    [blur.contentView addSubview:field];
    self.searchField = field;

    UILabel *count = [UILabel new];
    count.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    count.textColor = UIColor.secondaryLabelColor;
    count.text = @"0/0";
    count.translatesAutoresizingMaskIntoConstraints = NO;
    [blur.contentView addSubview:count];
    self.searchCountLabel = count;

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    [prev setImage:[UIImage systemImageNamed:@"chevron.up"] forState:UIControlStateNormal];
    [prev addTarget:self action:@selector(searchPrevious) forControlEvents:UIControlEventTouchUpInside];
    prev.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *next = [UIButton buttonWithType:UIButtonTypeSystem];
    [next setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    [next addTarget:self action:@selector(searchNext) forControlEvents:UIControlEventTouchUpInside];
    next.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hideSearch) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [blur.contentView addSubview:prev];
    [blur.contentView addSubview:next];
    [blur.contentView addSubview:close];
    self.searchPrevButton = prev;
    self.searchNextButton = next;

    UILayoutGuide *keyboardGuide = self.view.keyboardLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [blur.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [blur.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [blur.bottomAnchor constraintEqualToAnchor:keyboardGuide.topAnchor constant:-8],
        [blur.heightAnchor constraintEqualToConstant:52],
        [field.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:8],
        [field.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor],
        [field.heightAnchor constraintEqualToConstant:36],
        [count.leadingAnchor constraintEqualToAnchor:field.trailingAnchor constant:8],
        [count.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
        [prev.leadingAnchor constraintEqualToAnchor:count.trailingAnchor constant:8],
        [prev.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
        [prev.widthAnchor constraintEqualToConstant:32],
        [next.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor],
        [next.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
        [next.widthAnchor constraintEqualToConstant:32],
        [close.leadingAnchor constraintEqualToAnchor:next.trailingAnchor],
        [close.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-6],
        [close.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:32],
    ]];
    prev.enabled = NO;
    next.enabled = NO;
    [field becomeFirstResponder];
}

- (void)searchChanged:(UITextField *)field
{
    NSString *query = field.text ?: @"";
    self.searchGeneration += 1;
    NSUInteger generation = self.searchGeneration;
    self.searchIndex = -1;
    self.searchResults = @[];
    self.searchCountLabel.text = query.length ? @"…" : @"0/0";
    self.searchPrevButton.enabled = NO;
    self.searchNextButton.enabled = NO;
    self.pdfView.highlightedSelections = @[];
    if (!query.length) return;

    PDFDocument *doc = self.document;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<PDFSelection *> *results =
            [doc findString:query withOptions:NSCaseInsensitiveSearch] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return;
            self.searchResults = results;
            self.searchIndex = results.count ? 0 : -1;
            self.searchPrevButton.enabled = results.count > 0;
            self.searchNextButton.enabled = results.count > 0;
            [self updateSearchUIAndNavigate:YES];
        });
    });
}

- (void)searchNext
{
    if (!self.searchResults.count) return;
    self.searchIndex = (self.searchIndex + 1) % (NSInteger)self.searchResults.count;
    [self updateSearchUIAndNavigate:YES];
}

- (void)searchPrevious
{
    if (!self.searchResults.count) return;
    self.searchIndex = (self.searchIndex - 1 + (NSInteger)self.searchResults.count)
        % (NSInteger)self.searchResults.count;
    [self updateSearchUIAndNavigate:YES];
}

- (void)updateSearchUIAndNavigate:(BOOL)navigate
{
    NSUInteger count = self.searchResults.count;
    self.searchCountLabel.text = count
        ? [NSString stringWithFormat:@"%ld/%lu", (long)self.searchIndex + 1, (unsigned long)count]
        : @"0/0";
    if (!count || self.searchIndex < 0) {
        self.pdfView.highlightedSelections = @[];
        return;
    }

    NSMutableArray<PDFSelection *> *highlights = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        PDFSelection *selection = [self.searchResults[i] copy];
        selection.color = (i == (NSUInteger)self.searchIndex)
            ? UIColor.systemOrangeColor
            : [UIColor.systemYellowColor colorWithAlphaComponent:0.55];
        [highlights addObject:selection];
    }
    self.pdfView.highlightedSelections = highlights;
    PDFSelection *current = self.searchResults[(NSUInteger)self.searchIndex];
    self.pdfView.currentSelection = current;
    if (navigate) [self.pdfView goToSelection:current];
}

- (void)hideSearch
{
    self.searchGeneration += 1;
    self.searchResults = @[];
    self.searchIndex = -1;
    self.pdfView.highlightedSelections = @[];
    [self.searchField resignFirstResponder];
    [self.searchBar removeFromSuperview];
    self.searchBar = nil;
    self.searchField = nil;
    self.searchCountLabel = nil;
    self.searchPrevButton = nil;
    self.searchNextButton = nil;
    self.pageButton.hidden = NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)share
{
    NSURL *url = [NSURL fileURLWithPath:self.filePath];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)showFileInfo
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:self.filePath error:nil];
    FFEntry *entry = [FFEntry new];
    entry.name = self.filePath.lastPathComponent;
    entry.displayName = entry.name;
    entry.path = self.filePath;
    entry.size = [attrs[NSFileSize] unsignedLongLongValue];
    entry.creationDate = attrs[NSFileCreationDate];
    entry.modificationDate = attrs[NSFileModificationDate];
    FFFileInfoViewController *info = [[FFFileInfoViewController alloc] initWithEntry:entry icon:nil];
    [self.navigationController pushViewController:info animated:YES];
}

- (void)showLoadFailure:(NSString *)message
{
    FFLogTag(@"Preview", @"pdf load FAIL path=%@ reason=%@", self.filePath, message);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开 PDF"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
