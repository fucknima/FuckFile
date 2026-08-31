#import "FFBrowserViewController.h"
#import "FFLogger.h"
#import "FFPathBreadcrumbView.h"
#import "FFThumbnailService.h"

#import <objc/runtime.h>

@interface FFBrowserViewController (GridStabilityHostPrivate)
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) UIRefreshControl *gridRefreshControl;
@property(nonatomic, strong) FFPathBreadcrumbView *breadcrumbView;
@property(nonatomic) BOOL gridMode;
@property(nonatomic) BOOL hasLoaded;

- (void)setupCollectionView;
- (void)applyLayoutModeAnimated:(BOOL)animated;
- (void)refreshVisibleContent;
- (void)updateEmptyState;
- (void)updatePasteState;
- (UIImage *)iconForEntry:(FFEntry *)item;
- (UIColor *)tintForEntry:(FFEntry *)item;
- (BOOL)supportsThumbnail:(FFEntry *)item;
- (NSString *)formatSize:(unsigned long long)bytes;
- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath;
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point;
@end

@interface FFStableGridCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, copy) NSString *representedPath;
- (void)configureWithName:(NSString *)name
                   detail:(NSString *)detail
                    image:(UIImage *)image
                     tint:(UIColor *)tint
              isThumbnail:(BOOL)isThumbnail
                     path:(NSString *)path;
- (void)applyThumbnail:(UIImage *)image;
@end

@implementation FFStableGridCell

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _iconView = [UIImageView new];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.clipsToBounds = YES;
    _iconView.layer.cornerRadius = 10.0;
    [self.contentView addSubview:_iconView];

    _nameLabel = [UILabel new];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _nameLabel.adjustsFontForContentSizeCategory = YES;
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.numberOfLines = 2;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.contentView addSubview:_nameLabel];

    _detailLabel = [UILabel new];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    _detailLabel.adjustsFontForContentSizeCategory = YES;
    _detailLabel.textAlignment = NSTextAlignmentCenter;
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 1;
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.contentView addSubview:_detailLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:7.0],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:58.0],
        [_iconView.heightAnchor constraintEqualToConstant:58.0],
        [_nameLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:5.0],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:3.0],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-3.0],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1.0],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:3.0],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-3.0],
        [_detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-4.0],
    ]];

    UIView *selected = [UIView new];
    selected.backgroundColor = UIColor.tertiarySystemFillColor;
    selected.layer.cornerRadius = 12.0;
    self.selectedBackgroundView = selected;
    self.isAccessibilityElement = YES;
    return self;
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    self.representedPath = nil;
    self.iconView.image = nil;
    self.iconView.tintColor = nil;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.nameLabel.text = nil;
    self.detailLabel.text = nil;
}

- (void)configureWithName:(NSString *)name detail:(NSString *)detail image:(UIImage *)image
                     tint:(UIColor *)tint isThumbnail:(BOOL)isThumbnail path:(NSString *)path
{
    self.representedPath = path;
    self.nameLabel.text = name ?: @"";
    self.detailLabel.text = detail ?: @"";
    self.accessibilityLabel = name ?: @"";
    self.accessibilityValue = detail ?: @"";
    if (isThumbnail) {
        self.iconView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        self.iconView.tintColor = nil;
        self.iconView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        self.iconView.image = image;
        self.iconView.tintColor = tint ?: UIColor.labelColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)applyThumbnail:(UIImage *)image
{
    if (!image) return;
    self.iconView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    self.iconView.tintColor = nil;
    self.iconView.contentMode = UIViewContentModeScaleAspectFill;
}
@end

static void FFSwapGridMethod(Class cls, SEL originalSelector, SEL replacementSelector)
{
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

static NSArray<FFEntry *> *FFCurrentGridEntries(FFBrowserViewController *browser)
{
    NSArray<FFEntry *> *entries = browser.filteredEntries;
    return [entries isKindOfClass:NSArray.class] ? entries : @[];
}

static NSString *FFGridDetail(FFBrowserViewController *browser, FFEntry *item)
{
    if (item.isAppContainer) return @"App 数据";
    if (item.isDirectory) return @"文件夹";
    if (item.isSymlink) return @"符号链接";
    return [browser formatSize:item.size] ?: @"";
}

static UICollectionViewLayout *FFStableGridLayout(void)
{
    return [[UICollectionViewCompositionalLayout alloc]
        initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(
            NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> environment) {
            (void)sectionIndex;
            CGFloat width = environment.container.effectiveContentSize.width;
            NSInteger columns = 3;
            if (width >= 900.0) columns = 7;
            else if (width >= 700.0) columns = 6;
            else if (width >= 520.0) columns = 4;

            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                heightDimension:[NSCollectionLayoutDimension absoluteDimension:126.0]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                heightDimension:[NSCollectionLayoutDimension absoluteDimension:126.0]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup
                horizontalGroupWithLayoutSize:groupSize subitem:item count:columns];
            group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:8.0];
            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.interGroupSpacing = 10.0;
            section.contentInsets = NSDirectionalEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
            return section;
        }];
}

@interface FFBrowserViewController (GridStability)
- (void)ff_stable_setupCollectionView;
- (void)ff_stable_applyLayoutModeAnimated:(BOOL)animated;
- (void)ff_stable_refreshVisibleContent;
- (void)ff_stable_updateEmptyState;
- (UICollectionViewCell *)ff_stable_collectionView:(UICollectionView *)collectionView
                            cellForItemAtIndexPath:(NSIndexPath *)indexPath;
- (void)ff_stable_collectionView:(UICollectionView *)collectionView
       didSelectItemAtIndexPath:(NSIndexPath *)indexPath;
- (UIContextMenuConfiguration *)ff_stable_collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point;
@end

@implementation FFBrowserViewController (GridStability)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FFBrowserViewController.class;
        FFSwapGridMethod(cls, @selector(setupCollectionView), @selector(ff_stable_setupCollectionView));
        FFSwapGridMethod(cls, @selector(applyLayoutModeAnimated:), @selector(ff_stable_applyLayoutModeAnimated:));
        FFSwapGridMethod(cls, @selector(refreshVisibleContent), @selector(ff_stable_refreshVisibleContent));
        FFSwapGridMethod(cls, @selector(updateEmptyState), @selector(ff_stable_updateEmptyState));
        FFSwapGridMethod(cls, @selector(collectionView:cellForItemAtIndexPath:),
            @selector(ff_stable_collectionView:cellForItemAtIndexPath:));
        FFSwapGridMethod(cls, @selector(collectionView:didSelectItemAtIndexPath:),
            @selector(ff_stable_collectionView:didSelectItemAtIndexPath:));
        FFSwapGridMethod(cls, @selector(collectionView:contextMenuConfigurationForItemAtIndexPath:point:),
            @selector(ff_stable_collectionView:contextMenuConfigurationForItemAtIndexPath:point:));
    });
}

- (void)ff_stable_setupCollectionView
{
    if (self.collectionView) return;
    UICollectionView *collection = [[UICollectionView alloc]
        initWithFrame:CGRectZero collectionViewLayout:FFStableGridLayout()];
    collection.translatesAutoresizingMaskIntoConstraints = NO;
    collection.backgroundColor = UIColor.systemBackgroundColor;
    collection.dataSource = (id<UICollectionViewDataSource>)self;
    collection.delegate = (id<UICollectionViewDelegate>)self;
    collection.hidden = YES;
    collection.alwaysBounceVertical = YES;
    collection.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    collection.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    collection.prefetchingEnabled = NO;
    [collection registerClass:FFStableGridCell.class forCellWithReuseIdentifier:@"StableGridCell"];
    self.collectionView = collection;
    [self.view addSubview:collection];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(reloadEntries) forControlEvents:UIControlEventValueChanged];
    self.gridRefreshControl = refresh;
    collection.refreshControl = refresh;

    [NSLayoutConstraint activateConstraints:@[
        [collection.topAnchor constraintEqualToAnchor:self.breadcrumbView.bottomAnchor],
        [collection.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [collection.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [collection.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    FFLogTag(@"Grid", @"stable grid created path=%@", self.currentPath);
}

- (void)ff_stable_applyLayoutModeAnimated:(BOOL)animated
{
    (void)animated;
    BOOL useGrid = self.gridMode && !self.editing;
    UICollectionView *collection = self.collectionView;
    BOOL needsInitialReload = NO;
    if (useGrid && !collection) {
        [self setupCollectionView];
        collection = self.collectionView;
        needsInitialReload = YES;
    } else if (useGrid && collection.hidden) {
        needsInitialReload = YES;
    }

    if (!useGrid) {
        if (collection) {
            [self.gridRefreshControl endRefreshing];
            collection.dataSource = nil;
            collection.delegate = nil;
            [collection removeFromSuperview];
            self.collectionView = nil;
            self.gridRefreshControl = nil;
        }
        self.tableView.hidden = NO;
        [self.tableView reloadData];
        if (self.hasLoaded) [self updateEmptyState];
        [self updatePasteState];
        return;
    }

    self.tableView.hidden = YES;
    collection.hidden = NO;
    if (needsInitialReload) [collection reloadData];
    [collection.collectionViewLayout invalidateLayout];
    if (self.hasLoaded) [self updateEmptyState];
    [self updatePasteState];
}

- (void)ff_stable_refreshVisibleContent
{
    UICollectionView *collection = self.collectionView;
    BOOL gridVisible = self.gridMode && !self.editing && collection && !collection.hidden;
    if (gridVisible) [collection reloadData];
    else [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)ff_stable_updateEmptyState
{
    [self ff_stable_updateEmptyState];
    UICollectionView *collection = self.collectionView;
    if (!collection) return;
    UIView *background = collection.backgroundView ?: self.tableView.backgroundView;
    if (!background) return;
    self.tableView.backgroundView = nil;
    collection.backgroundView = nil;
    BOOL gridVisible = self.gridMode && !self.editing && !collection.hidden;
    if (gridVisible) collection.backgroundView = background;
    else self.tableView.backgroundView = background;
}

- (UICollectionViewCell *)ff_stable_collectionView:(UICollectionView *)collectionView
                            cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    FFStableGridCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"StableGridCell"
        forIndexPath:indexPath];
    NSArray<FFEntry *> *entries = FFCurrentGridEntries(self);
    if ((NSUInteger)indexPath.item >= entries.count) {
        [cell configureWithName:@"" detail:@"" image:nil tint:nil isThumbnail:NO path:nil];
        FFLogTag(@"Grid", @"stale cell index=%ld count=%lu", (long)indexPath.item,
            (unsigned long)entries.count);
        return cell;
    }

    FFEntry *item = entries[(NSUInteger)indexPath.item];
    BOOL hasThumbnail = item.thumbnail != nil;
    [cell configureWithName:(item.displayName.length ? item.displayName : item.name)
        detail:FFGridDetail(self, item)
        image:(item.thumbnail ?: [self iconForEntry:item])
        tint:(hasThumbnail ? nil : [self tintForEntry:item])
        isThumbnail:hasThumbnail path:item.path];

    if (!hasThumbnail && !item.isDirectory && !item.isSymlink && [self supportsThumbnail:item]) {
        __weak typeof(self) weakSelf = self;
        NSString *expectedPath = [item.path copy];
        [[FFThumbnailService sharedService] thumbnailForPath:item.path size:CGSizeMake(64.0, 64.0)
            completion:^(UIImage * _Nullable thumbnail) {
                if (!thumbnail) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    UICollectionView *currentCollection = strongSelf.collectionView;
                    if (!currentCollection || currentCollection.hidden) return;
                    NSArray<FFEntry *> *currentEntries = FFCurrentGridEntries(strongSelf);
                    NSUInteger index = [currentEntries indexOfObjectIdenticalTo:item];
                    if (index == NSNotFound) return;
                    item.thumbnail = thumbnail;
                    NSIndexPath *visiblePath = [NSIndexPath indexPathForItem:(NSInteger)index inSection:0];
                    FFStableGridCell *visible = (FFStableGridCell *)[currentCollection
                        cellForItemAtIndexPath:visiblePath];
                    if (![visible isKindOfClass:FFStableGridCell.class]) return;
                    if (![visible.representedPath isEqualToString:expectedPath]) return;
                    [visible applyThumbnail:thumbnail];
                });
            }];
    }
    return cell;
}

- (void)ff_stable_collectionView:(UICollectionView *)collectionView
       didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<FFEntry *> *entries = FFCurrentGridEntries(self);
    if ((NSUInteger)indexPath.item >= entries.count) {
        [collectionView deselectItemAtIndexPath:indexPath animated:NO];
        return;
    }
    [self ff_stable_collectionView:collectionView didSelectItemAtIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)ff_stable_collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NSArray<FFEntry *> *entries = FFCurrentGridEntries(self);
    if ((NSUInteger)indexPath.item >= entries.count) return nil;
    return [self ff_stable_collectionView:collectionView
        contextMenuConfigurationForItemAtIndexPath:indexPath point:point];
}
@end
