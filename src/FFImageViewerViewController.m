#import "FFImageViewerViewController.h"

#import "FFBrowserViewController.h"
#import "FFFileAssociationService.h"
#import "FFFileInfoViewController.h"
#import "FFLogger.h"
#import "FFTrashService.h"

#pragma mark - Zoom view

@interface FFImageZoomView : UIView <UIScrollViewDelegate>
@property(nonatomic, strong, readonly) UIScrollView *scrollView;
@property(nonatomic, strong, readonly) UIImageView *imageView;
- (void)setImage:(UIImage *)image;
- (BOOL)isZoomedOut;
@end

@implementation FFImageZoomView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        _scrollView.backgroundColor = UIColor.systemBackgroundColor;
        _scrollView.delegate = self;
        _scrollView.minimumZoomScale = 1.0;
        _scrollView.maximumZoomScale = 8.0;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        [self addSubview:_scrollView];

        _imageView = [[UIImageView alloc] initWithFrame:_scrollView.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.userInteractionEnabled = YES;
        [_scrollView addSubview:_imageView];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(doubleTapped:)];
        doubleTap.numberOfTapsRequired = 2;
        [_imageView addGestureRecognizer:doubleTap];
    }
    return self;
}

- (void)setImage:(UIImage *)image
{
    [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:NO];
    self.imageView.image = image;
    self.imageView.frame = CGRectMake(0, 0, image.size.width, image.size.height);
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (BOOL)isZoomedOut
{
    return self.scrollView.zoomScale <= self.scrollView.minimumZoomScale + 0.01;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.scrollView.frame = self.bounds;
    if (!self.isZoomedOut || !self.imageView.image) return;
    CGSize bounds = self.scrollView.bounds.size;
    CGSize image = self.imageView.image.size;
    if (bounds.width <= 0 || bounds.height <= 0 || image.width <= 0 || image.height <= 0) return;
    CGFloat scale = MIN(bounds.width / image.width, bounds.height / image.height);
    CGSize fitted = CGSizeMake(floor(image.width * scale), floor(image.height * scale));
    self.imageView.frame = CGRectMake((bounds.width - fitted.width) / 2,
                                      (bounds.height - fitted.height) / 2,
                                      fitted.width, fitted.height);
    self.scrollView.contentSize = fitted;
}

- (UIView *)viewForZoomingInScrollView:(__unused UIScrollView *)scrollView
{
    return self.imageView;
}

- (void)doubleTapped:(UITapGestureRecognizer *)gesture
{
    if (!self.isZoomedOut) {
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
        return;
    }
    CGFloat target = MIN(self.scrollView.maximumZoomScale, 3.0);
    CGPoint center = [gesture locationInView:self.imageView];
    CGRect rect = CGRectMake(center.x - self.scrollView.bounds.size.width / target / 2,
                             center.y - self.scrollView.bounds.size.height / target / 2,
                             self.scrollView.bounds.size.width / target,
                             self.scrollView.bounds.size.height / target);
    [self.scrollView zoomToRect:rect animated:YES];
}

@end

#pragma mark - Viewer

@interface FFImageViewerViewController () <UIGestureRecognizerDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, copy) NSArray<NSString *> *imagePaths;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger loadGeneration;
@property(nonatomic, strong) FFImageZoomView *zoomView;
@property(nonatomic, strong) UILabel *errorLabel;
@property(nonatomic, strong) UIToolbar *toolbar;
@end

@implementation FFImageViewerViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _currentPath = [path copy];
        _imagePaths = @[];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    self.zoomView = [[FFImageZoomView alloc] initWithFrame:self.view.bounds];
    self.zoomView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.zoomView];

    self.errorLabel = [UILabel new];
    self.errorLabel.text = @"无法加载图片";
    self.errorLabel.textColor = UIColor.secondaryLabelColor;
    self.errorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.errorLabel.hidden = YES;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.errorLabel];

    self.toolbar = [[UIToolbar alloc] init];
    self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.toolbar];

    [NSLayoutConstraint activateConstraints:@[
        [self.zoomView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.zoomView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.zoomView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.zoomView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItems = @[ [self moreItem], [self shareItem] ];

    UISwipeGestureRecognizer *left = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(swiped:)];
    left.direction = UISwipeGestureRecognizerDirectionLeft;
    left.delegate = self;
    UISwipeGestureRecognizer *right = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(swiped:)];
    right.direction = UISwipeGestureRecognizerDirectionRight;
    right.delegate = self;
    [self.view addGestureRecognizer:left];
    [self.view addGestureRecognizer:right];

    [self loadImageList];
}

#pragma mark - Chrome

- (UIBarButtonItem *)shareItem
{
    return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self action:@selector(shareTapped:)];
}

- (UIBarButtonItem *)moreItem
{
    __weak typeof(self) weakSelf = self;
    UIAction *info = [UIAction actionWithTitle:@"文件信息"
        image:[UIImage systemImageNamed:@"info.circle"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf showInfo]; }];
    UIAction *delete = [UIAction actionWithTitle:@"移到回收站"
        image:[UIImage systemImageNamed:@"trash"] identifier:nil
        handler:^(__unused UIAction *action) { [weakSelf confirmDelete]; }];
    delete.attributes = UIMenuElementAttributesDestructive;
    return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithChildren:@[info, delete]]];
}

- (void)updateToolbar
{
    BOOL multi = self.imagePaths.count > 1;
    self.toolbar.hidden = !multi;
    if (!multi) {
        [self.toolbar setItems:@[] animated:NO];
        return;
    }
    UIBarButtonItem *previous = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.left"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showPrevious)];
    previous.enabled = self.index > 0;
    UIBarButtonItem *next = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.right"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showNext)];
    next.enabled = self.index + 1 < self.imagePaths.count;
    UIBarButtonItem *counter = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:@"%lu / %lu",
            (unsigned long)(self.index + 1), (unsigned long)self.imagePaths.count]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    counter.enabled = NO;
    UIBarButtonItem *flexA = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *flexB = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    [self.toolbar setItems:@[flexA, previous, counter, next, flexB] animated:NO];
}

#pragma mark - Images

- (void)loadImageList
{
    NSString *startingPath = self.currentPath;
    NSString *directory = startingPath.stringByDeletingLastPathComponent;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:directory error:nil] ?: @[]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        NSMutableArray<NSString *> *images = [NSMutableArray array];
        for (NSString *name in names) {
            if ([name hasPrefix:@"."]) continue;
            NSString *full = [directory stringByAppendingPathComponent:name];
            BOOL isDirectory = NO;
            if (![manager fileExistsAtPath:full isDirectory:&isDirectory] || isDirectory) continue;
            NSString *viewerID = [FFFileAssociationService
                builtinViewerIDForExtension:name.pathExtension];
            if ([viewerID isEqualToString:@"image"]) [images addObject:full];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.imagePaths = images;
            NSUInteger index = [images indexOfObject:startingPath];
            [strongSelf showImageAtIndex:index == NSNotFound ? 0 : index];
            FFLogTag(@"ImageViewer", @"loaded directory=%@ images=%lu",
                directory.lastPathComponent, (unsigned long)images.count);
        });
    });
}

- (void)showImageAtIndex:(NSUInteger)index
{
    if (!self.imagePaths.count) {
        self.errorLabel.hidden = NO;
        [self updateToolbar];
        return;
    }
    index = MIN(index, self.imagePaths.count - 1);
    self.index = index;
    NSString *path = self.imagePaths[index];
    self.currentPath = path;
    self.title = path.lastPathComponent;
    self.loadGeneration += 1;
    NSUInteger generation = self.loadGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.loadGeneration) return;
            strongSelf.errorLabel.hidden = image != nil;
            [strongSelf.zoomView setImage:image];
            [strongSelf updateToolbar];
        });
    });
}

- (void)showPrevious
{
    if (self.index == 0) return;
    [self showImageAtIndex:self.index - 1];
}

- (void)showNext
{
    if (self.index + 1 >= self.imagePaths.count) return;
    [self showImageAtIndex:self.index + 1];
}

- (void)swiped:(UISwipeGestureRecognizer *)gesture
{
    // 放大状态下左右滑动用于平移图片，不切换文件。
    if (!self.zoomView.isZoomedOut) return;
    if (gesture.direction == UISwipeGestureRecognizerDirectionLeft) [self showNext];
    else if (gesture.direction == UISwipeGestureRecognizerDirectionRight) [self showPrevious];
}

- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(__unused UIGestureRecognizer *)other
{
    return YES;
}

#pragma mark - Actions

- (void)shareTapped:(UIBarButtonItem *)sender
{
    if (!self.currentPath.length) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.currentPath]]
        applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)showInfo
{
    if (!self.currentPath.length) return;
    NSString *path = self.currentPath;
    FFEntry *entry = [FFEntry new];
    entry.name = path.lastPathComponent;
    entry.displayName = entry.name;
    entry.path = path;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    entry.size = [attributes[NSFileSize] unsignedLongLongValue];
    entry.modificationDate = attributes[NSFileModificationDate];
    entry.creationDate = attributes[NSFileCreationDate];
    FFFileInfoViewController *info = [[FFFileInfoViewController alloc] initWithEntry:entry
        icon:self.zoomView.imageView.image];
    [self.navigationController pushViewController:info animated:YES];
}

- (void)confirmDelete
{
    if (!self.currentPath.length) return;
    NSString *name = self.currentPath.lastPathComponent;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"移到回收站"
        message:[NSString stringWithFormat:@"“%@” 将移到回收站，可在那里恢复。", name]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移到回收站"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [weakSelf deleteCurrent];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteCurrent
{
    NSString *path = self.currentPath;
    if (!path.length) return;
    NSError *error = nil;
    NSUInteger moved = [FFTrashService.sharedService moveToTrash:@[path] firstError:&error];
    if (moved == 0) {
        [self presentError:error.localizedDescription ?: @"无法移到回收站"];
        return;
    }
    NSMutableArray<NSString *> *remaining = [self.imagePaths mutableCopy];
    [remaining removeObject:path];
    self.imagePaths = remaining;
    if (!remaining.count) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self showImageAtIndex:MIN(self.index, remaining.count - 1)];
}

- (void)presentError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作失败"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
