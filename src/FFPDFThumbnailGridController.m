#import "FFPDFThumbnailGridController.h"
#import "FFLogger.h"

#import <PDFKit/PDFKit.h>

@interface FFPDFThumbnailCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *imageView;
@property(nonatomic, strong) UILabel *pageLabel;
@property(nonatomic) NSInteger representedIndex;
- (void)configureSelected:(BOOL)selected;
@end

@implementation FFPDFThumbnailCell

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.contentView.layer.cornerRadius = 10;
        self.contentView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        self.contentView.layer.borderColor = UIColor.separatorColor.CGColor;
        self.contentView.layer.masksToBounds = YES;

        _imageView = [UIImageView new];
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.backgroundColor = UIColor.systemBackgroundColor;
        [self.contentView addSubview:_imageView];

        _pageLabel = [UILabel new];
        _pageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _pageLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _pageLabel.textAlignment = NSTextAlignmentCenter;
        _pageLabel.textColor = UIColor.secondaryLabelColor;
        [self.contentView addSubview:_pageLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_imageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [_imageView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6],
            [_imageView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
            [_pageLabel.topAnchor constraintEqualToAnchor:_imageView.bottomAnchor constant:5],
            [_pageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [_pageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            [_pageLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
            [_pageLabel.heightAnchor constraintEqualToConstant:17],
        ]];
    }
    return self;
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    self.representedIndex = NSNotFound;
    self.imageView.image = nil;
    self.pageLabel.text = nil;
    [self configureSelected:NO];
}

- (void)configureSelected:(BOOL)selected
{
    self.contentView.layer.borderWidth = selected ? 2.0 : 1.0 / UIScreen.mainScreen.scale;
    self.contentView.layer.borderColor = (selected ? UIColor.systemBlueColor : UIColor.separatorColor).CGColor;
    self.pageLabel.textColor = selected ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
}

@end

@interface FFPDFThumbnailGridController ()
<UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout,
 UICollectionViewDataSourcePrefetching>
@property(nonatomic, strong) PDFDocument *document;
@property(nonatomic, weak) PDFView *pdfView;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) NSCache<NSNumber *, UIImage *> *cache;
@property(nonatomic, strong) NSOperationQueue *renderQueue;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *pendingIndexes;
@property(nonatomic) NSInteger currentIndex;
@property(nonatomic) BOOL didInitialScroll;
@end

@implementation FFPDFThumbnailGridController

- (instancetype)initWithDocument:(PDFDocument *)document pdfView:(PDFView *)pdfView
{
    self = [super init];
    if (self) {
        _document = document;
        _pdfView = pdfView;
        _cache = [NSCache new];
        _cache.countLimit = 80;
        _pendingIndexes = [NSMutableSet set];
        _renderQueue = [NSOperationQueue new];
        _renderQueue.name = @"ff.pdf.thumbnail.render";
        _renderQueue.maxConcurrentOperationCount = 2;
        _renderQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _currentIndex = [self indexForCurrentPage];
        self.title = @"页面";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 16;
    layout.sectionInset = UIEdgeInsetsMake(16, 16, 24, 16);

    UICollectionView *collection = [[UICollectionView alloc] initWithFrame:CGRectZero
                                                      collectionViewLayout:layout];
    collection.translatesAutoresizingMaskIntoConstraints = NO;
    collection.backgroundColor = UIColor.systemGroupedBackgroundColor;
    collection.alwaysBounceVertical = YES;
    collection.showsVerticalScrollIndicator = YES;
    collection.dataSource = self;
    collection.delegate = self;
    collection.prefetchDataSource = self;
    [collection registerClass:FFPDFThumbnailCell.class forCellWithReuseIdentifier:@"PDFThumb"];
    [self.view addSubview:collection];
    self.collectionView = collection;

    [NSLayoutConstraint activateConstraints:@[
        [collection.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [collection.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [collection.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [collection.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pdfPageChanged:)
        name:PDFViewPageChangedNotification object:self.pdfView];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.renderQueue cancelAllOperations];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self scrollToCurrentPageIfNeeded];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (!self.didInitialScroll) [self scrollToCurrentPageIfNeeded];
}

- (NSInteger)indexForCurrentPage
{
    PDFPage *page = self.pdfView.currentPage;
    if (!page) return 0;
    NSInteger index = [self.document indexForPage:page];
    return index == NSNotFound ? 0 : index;
}

- (void)scrollToCurrentPageIfNeeded
{
    if (self.didInitialScroll || self.document.pageCount == 0 || self.collectionView.bounds.size.height <= 0)
        return;
    NSInteger index = MAX(0, MIN((NSInteger)self.document.pageCount - 1, self.currentIndex));
    NSIndexPath *path = [NSIndexPath indexPathForItem:index inSection:0];
    [self.collectionView scrollToItemAtIndexPath:path
                                atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                        animated:NO];
    self.didInitialScroll = YES;
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Collection

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return self.document.pageCount;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    FFPDFThumbnailCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"PDFThumb"
                                                                          forIndexPath:indexPath];
    NSInteger index = indexPath.item;
    cell.representedIndex = index;
    cell.pageLabel.text = [NSString stringWithFormat:@"%ld", (long)index + 1];
    [cell configureSelected:index == self.currentIndex];

    UIImage *cached = [self.cache objectForKey:@(index)];
    if (cached) {
        cell.imageView.image = cached;
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"doc.richtext"];
        cell.imageView.tintColor = UIColor.tertiaryLabelColor;
        [self requestThumbnailForIndex:index];
    }
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat width = collectionView.bounds.size.width;
    UIUserInterfaceIdiom idiom = UIDevice.currentDevice.userInterfaceIdiom;
    NSInteger columns = idiom == UIUserInterfaceIdiomPad ? 4 : 2;
    if (width < 360) columns = 2;
    else if (width >= 700) columns = 4;
    else if (width >= 520) columns = 3;
    CGFloat spacing = 12.0;
    CGFloat insets = 32.0;
    CGFloat itemWidth = floor((width - insets - spacing * (columns - 1)) / columns);
    CGFloat imageHeight = itemWidth * 1.30;
    return CGSizeMake(itemWidth, imageHeight + 34.0);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    PDFPage *page = [self.document pageAtIndex:indexPath.item];
    if (!page) return;
    NSInteger oldIndex = self.currentIndex;
    self.currentIndex = indexPath.item;
    [self.pdfView goToPage:page];

    NSMutableArray<NSIndexPath *> *reload = [NSMutableArray arrayWithObject:indexPath];
    if (oldIndex >= 0 && oldIndex < (NSInteger)self.document.pageCount && oldIndex != self.currentIndex)
        [reload addObject:[NSIndexPath indexPathForItem:oldIndex inSection:0]];
    [collectionView reloadItemsAtIndexPaths:reload];

    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad)
        [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Rendering

- (CGSize)renderSize
{
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat width = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 180.0 : 150.0;
    return CGSizeMake(width * scale, width * 1.42 * scale);
}

- (void)requestThumbnailForIndex:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)self.document.pageCount) return;
    NSNumber *key = @(index);
    @synchronized (self.pendingIndexes) {
        if ([self.pendingIndexes containsObject:key] || [self.cache objectForKey:key]) return;
        [self.pendingIndexes addObject:key];
    }

    __weak typeof(self) weakSelf = self;
    [self.renderQueue addOperationWithBlock:^{
        typeof(weakSelf) self = weakSelf;
        if (!self) return;
        PDFPage *page = [self.document pageAtIndex:index];
        UIImage *image = page ? [page thumbnailOfSize:[self renderSize] forBox:kPDFDisplayBoxCropBox] : nil;
        if (image) [self.cache setObject:image forKey:key cost:(NSUInteger)(image.size.width * image.size.height * 4)];
        @synchronized (self.pendingIndexes) { [self.pendingIndexes removeObject:key]; }
        if (!image) return;
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            FFPDFThumbnailCell *cell = (FFPDFThumbnailCell *)[self.collectionView
                cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
            if ([cell isKindOfClass:FFPDFThumbnailCell.class] && cell.representedIndex == index) {
                cell.imageView.tintColor = nil;
                cell.imageView.image = image;
            }
        }];
    }];
}

- (void)collectionView:(UICollectionView *)collectionView
    prefetchItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    for (NSIndexPath *path in indexPaths) [self requestThumbnailForIndex:path.item];
}

- (void)collectionView:(UICollectionView *)collectionView
    cancelPrefetchingForItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    // Rendering work is deliberately not cancelled per-page; the result is useful
    // in cache if the user reverses direction. The queue is only two-wide.
}

#pragma mark - PDF sync

- (void)pdfPageChanged:(NSNotification *)note
{
    NSInteger old = self.currentIndex;
    self.currentIndex = [self indexForCurrentPage];
    if (old == self.currentIndex) return;
    NSMutableArray<NSIndexPath *> *reload = [NSMutableArray array];
    if (old >= 0 && old < (NSInteger)self.document.pageCount)
        [reload addObject:[NSIndexPath indexPathForItem:old inSection:0]];
    if (self.currentIndex >= 0 && self.currentIndex < (NSInteger)self.document.pageCount)
        [reload addObject:[NSIndexPath indexPathForItem:self.currentIndex inSection:0]];
    [self.collectionView reloadItemsAtIndexPaths:reload];
}

@end
