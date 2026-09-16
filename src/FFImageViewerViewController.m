#import "FFImageViewerViewController.h"

#import "FFBrowserViewController.h"
#import "FFFileAssociationService.h"
#import "FFFileInfoViewController.h"
#import "FFLogger.h"
#import "FFThumbnailService.h"
#import "FFTrashService.h"

#pragma mark - Thumbnail strip cell

static NSString * const FFImageStripCellID = @"FFImageStripCell";

@interface FFImageStripCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *thumbView;
- (void)setCurrent:(BOOL)current;
@end

@implementation FFImageStripCell

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _thumbView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _thumbView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        _thumbView.layer.cornerRadius = 5;
        _thumbView.backgroundColor = UIColor.secondarySystemBackgroundColor;
        [self.contentView addSubview:_thumbView];
        self.contentView.layer.cornerRadius = 5;
        self.contentView.layer.masksToBounds = YES;
    }
    return self;
}

- (void)setCurrent:(BOOL)current
{
    self.contentView.layer.borderWidth = current ? 2 : 0;
    self.contentView.layer.borderColor = UIColor.systemBlueColor.CGColor;
}

@end

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

@interface FFImageViewerViewController () <UIGestureRecognizerDelegate, UICollectionViewDataSource,
                                            UICollectionViewDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, copy) NSArray<NSString *> *imagePaths;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger loadGeneration;
@property(nonatomic, strong) FFImageZoomView *zoomView;
@property(nonatomic, strong) UILabel *errorLabel;
@property(nonatomic, strong) UIToolbar *toolbar;
@property(nonatomic, strong) UICollectionView *strip;
@property(nonatomic, strong) NSLayoutConstraint *zoomBottomBars;
@property(nonatomic, strong) NSLayoutConstraint *zoomBottomSafe;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
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

    UICollectionViewFlowLayout *stripLayout = [[UICollectionViewFlowLayout alloc] init];
    stripLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    stripLayout.itemSize = CGSizeMake(56, 56);
    stripLayout.minimumLineSpacing = 6;
    stripLayout.sectionInset = UIEdgeInsetsMake(0, 10, 0, 10);
    self.strip = [[UICollectionView alloc] initWithFrame:CGRectZero
        collectionViewLayout:stripLayout];
    self.strip.dataSource = self;
    self.strip.delegate = self;
    self.strip.backgroundColor = UIColor.clearColor;
    self.strip.showsHorizontalScrollIndicator = NO;
    self.strip.translatesAutoresizingMaskIntoConstraints = NO;
    [self.strip registerClass:FFImageStripCell.class forCellWithReuseIdentifier:FFImageStripCellID];
    [self.view addSubview:self.strip];

    self.imageCache = [[NSCache alloc] init];
    self.imageCache.countLimit = 12;

    // 图片只在「导航栏下方 → 工具栏/缩略图条上方」的可见区域里居中，
    // 否则会在顶栏与图片之间留下一条明显的空白（0 图/多图两种布局切换）。
    self.zoomBottomBars = [self.zoomView.bottomAnchor
        constraintEqualToAnchor:self.strip.topAnchor constant:-6];
    self.zoomBottomSafe = [self.zoomView.bottomAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    NSLayoutConstraint *zoomTop = [self.zoomView.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor];
    NSLayoutConstraint *zoomLeading = [self.zoomView.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor];
    NSLayoutConstraint *zoomTrailing = [self.zoomView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor];
    zoomTop.active = YES;
    zoomLeading.active = YES;
    zoomTrailing.active = YES;
    self.zoomBottomSafe.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.strip.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.strip.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.strip.bottomAnchor constraintEqualToAnchor:self.toolbar.topAnchor constant:-6],
        [self.strip.heightAnchor constraintEqualToConstant:64],
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
    self.strip.hidden = !multi;
    // 有底栏时图片让位给底栏，没有底栏时铺满安全区。
    self.zoomBottomBars.active = multi;
    self.zoomBottomSafe.active = !multi;
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
        // 当前文件可能没有扩展名（相册导入）或走了内容识别兜底，不在
        // 上面的扩展名家族里；至少要能单独显示它。
        if (![images containsObject:startingPath]) [images insertObject:startingPath atIndex:0];
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
    [self showImageAtIndex:index animated:NO direction:0];
}

// direction: +1 = 下一张（新图从右侧进入），-1 = 上一张，0 = 原地淡入。
- (void)showImageAtIndex:(NSUInteger)index animated:(BOOL)animated direction:(NSInteger)direction
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
    [self updateToolbar];
    [self updateStripSelection];

    UIImage *cached = [self.imageCache objectForKey:path];
    if (cached) {
        self.errorLabel.hidden = YES;
        [self applyImage:cached animated:animated direction:direction];
        [self preloadNeighbours];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.loadGeneration) return;
            if (image) [strongSelf.imageCache setObject:image forKey:path];
            strongSelf.errorLabel.hidden = image != nil;
            [strongSelf applyImage:image animated:animated direction:direction];
            [strongSelf preloadNeighbours];
        });
    });
}

// 切换动画：左右滑动翻页（旧图滑出、新图从对应方向滑入）。
// 动画层用 frame 驱动的一次性视图，不受 Auto Layout 约束影响。
- (void)applyImage:(UIImage *)image animated:(BOOL)animated direction:(NSInteger)direction
{
    if (!animated || !self.zoomView.window ||
        !self.zoomView.superview || CGRectIsEmpty(self.zoomView.bounds)) {
        [self.zoomView setImage:image];
        return;
    }
    if (direction == 0) {
        // 原地切换（点缩略图当前项、删除后落到相邻图）用交叉淡入。
        [UIView transitionWithView:self.zoomView duration:0.2
            options:UIViewAnimationOptionTransitionCrossDissolve
            animations:^{ [self.zoomView setImage:image]; } completion:nil];
        return;
    }

    CGFloat width = self.zoomView.bounds.size.width;
    UIView *outgoing = [self.zoomView snapshotViewAfterScreenUpdates:NO];
    outgoing.frame = self.zoomView.frame;
    outgoing.userInteractionEnabled = NO;
    [self.view addSubview:outgoing];

    FFImageZoomView *incoming = [[FFImageZoomView alloc] initWithFrame:
        CGRectOffset(self.zoomView.frame, direction * width, 0)];
    [incoming setImage:image];
    incoming.userInteractionEnabled = NO;
    [self.view addSubview:incoming];

    // 真实视图同步换到新图，动画结束后再露出，避免中途闪回旧内容。
    [self.zoomView setImage:image];
    self.zoomView.hidden = YES;

    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseInOut
        animations:^{
            outgoing.frame = CGRectOffset(outgoing.frame, -direction * width, 0);
            incoming.frame = CGRectOffset(incoming.frame, -direction * width, 0);
        } completion:^(BOOL finished) {
            [outgoing removeFromSuperview];
            [incoming removeFromSuperview];
            self.zoomView.hidden = NO;
        }];
}

// 相邻图片预取，连续切换不再每张都等磁盘解码。
- (void)preloadNeighbours
{
    if (self.imagePaths.count < 2) return;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (self.index > 0) [candidates addObject:self.imagePaths[self.index - 1]];
    if (self.index + 1 < self.imagePaths.count) [candidates addObject:self.imagePaths[self.index + 1]];
    NSCache<NSString *, UIImage *> *cache = self.imageCache;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *path in candidates) {
            if ([cache objectForKey:path]) continue;
            UIImage *image = [UIImage imageWithContentsOfFile:path];
            if (image) [cache setObject:image forKey:path];
        }
    });
}

#pragma mark - Thumbnail strip

- (void)updateStripSelection
{
    if (self.strip.hidden || !self.imagePaths.count) return;
    // 先 reloadData 让集合视图看到新数据，再选中。数据还没刷新就
    // selectItemAtIndexPath: 会因 indexPath 越界触发 UIKit 断言
    // （表现为打开 .heic 直接闪退）。
    [self.strip reloadData];
    [self.strip layoutIfNeeded];
    NSInteger items = [self.strip numberOfItemsInSection:0];
    if (items <= 0 || self.index >= (NSUInteger)items) return;
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:(NSInteger)self.index inSection:0];
    [self.strip selectItemAtIndexPath:indexPath animated:NO
        scrollPosition:UICollectionViewScrollPositionCenteredHorizontally];
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView
     numberOfItemsInSection:(__unused NSInteger)section
{
    return (NSInteger)self.imagePaths.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    FFImageStripCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:FFImageStripCellID
        forIndexPath:indexPath];
    NSUInteger index = (NSUInteger)indexPath.item;
    cell.thumbView.image = nil;
    [cell setCurrent:index == self.index];
    if (index >= self.imagePaths.count) return cell;
    NSString *path = self.imagePaths[index];
    UIImage *cached = [self.imageCache objectForKey:path];
    if (cached) {
        cell.thumbView.image = cached;
        return cell;
    }
    __weak FFImageStripCell *weakCell = cell;
    [FFThumbnailService.sharedService thumbnailForPath:path size:CGSizeMake(56, 56)
        completion:^(UIImage *image) {
            typeof(weakCell) strongCell = weakCell;
            if (strongCell && image) strongCell.thumbView.image = image;
        }];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    (void)collectionView;
    NSUInteger target = (NSUInteger)indexPath.item;
    NSInteger direction = target == self.index ? 0 : (target > self.index ? 1 : -1);
    [self showImageAtIndex:target animated:YES direction:direction];
}

- (void)showPrevious
{
    if (self.index == 0) return;
    [self showImageAtIndex:self.index - 1 animated:YES direction:-1];
}

- (void)showNext
{
    if (self.index + 1 >= self.imagePaths.count) return;
    [self showImageAtIndex:self.index + 1 animated:YES direction:1];
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
    [self.imageCache removeObjectForKey:path];
    NSMutableArray<NSString *> *remaining = [self.imagePaths mutableCopy];
    [remaining removeObject:path];
    self.imagePaths = remaining;
    [self.strip reloadData];
    if (!remaining.count) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self showImageAtIndex:MIN(self.index, remaining.count - 1) animated:YES direction:0];
}

- (void)presentError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作失败"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
