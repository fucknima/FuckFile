#import "FFBrowserViewController.h"
#import "FFFileIconProvider.h"
#import "FFThumbnailService.h"
#import <objc/runtime.h>

static const void *kFFGridThumbnailRequestedKey = &kFFGridThumbnailRequestedKey;

/// Visual-only hooks kept outside the browser controller so icon policy does not
/// get mixed into navigation, file IO, sorting or search logic.
///
/// Content thumbnails used to make PDFs/images/videos occupy wildly different
/// optical sizes (a portrait PDF page could look ~12pt wide beside a 40pt app
/// icon). The new design uses one fixed type-icon language for ordinary files;
/// only IPA keeps its real app artwork, where the artwork itself is meaningful.
@interface FFBrowserViewController (FileIcons)
- (UIImage *)ff_design_iconForEntry:(FFEntry *)entry;
- (BOOL)ff_design_supportsThumbnail:(FFEntry *)entry;
- (UICollectionViewCell *)ff_stable_collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)indexPath;
- (UIImage *)iconForEntry:(FFEntry *)entry;
- (UIColor *)tintForEntry:(FFEntry *)entry;
- (BOOL)supportsThumbnail:(FFEntry *)entry;
- (NSString *)formatSize:(unsigned long long)size;
@end

@implementation FFBrowserViewController (FileIcons)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;

        Method iconOriginal = class_getInstanceMethod(cls, NSSelectorFromString(@"iconForEntry:"));
        Method iconReplacement = class_getInstanceMethod(cls, @selector(ff_design_iconForEntry:));
        if (iconOriginal && iconReplacement)
            method_exchangeImplementations(iconOriginal, iconReplacement);

        Method thumbnailOriginal = class_getInstanceMethod(cls, NSSelectorFromString(@"supportsThumbnail:"));
        Method thumbnailReplacement = class_getInstanceMethod(cls, @selector(ff_design_supportsThumbnail:));
        if (thumbnailOriginal && thumbnailReplacement)
            method_exchangeImplementations(thumbnailOriginal, thumbnailReplacement);

        // Grid used to reload individual collection items from asynchronous
        // thumbnail callbacks. That can race a directory/search reload and ask
        // UICollectionViewFlowLayout to update an index path that belongs to an
        // old snapshot. Replace only the grid cell provider: data source,
        // navigation, selection and list mode remain untouched.
        Method gridOriginal = class_getInstanceMethod(cls,
            @selector(collectionView:cellForItemAtIndexPath:));
        Method gridReplacement = class_getInstanceMethod(cls,
            @selector(ff_stable_collectionView:cellForItemAtIndexPath:));
        if (gridOriginal && gridReplacement)
            method_exchangeImplementations(gridOriginal, gridReplacement);
    });
}

- (UIImage *)ff_design_iconForEntry:(FFEntry *)entry
{
    UIImage *icon = [FFFileIconProvider iconForEntry:entry];
    if (icon) return icon;
    // After exchange this selector points to Browser's original implementation.
    return [self ff_design_iconForEntry:entry];
}

- (BOOL)ff_design_supportsThumbnail:(FFEntry *)entry
{
    // Real app artwork is deliberately preserved. Everything else uses the
    // unified type icon so list rows never jump between portrait-page previews,
    // landscape frames and square app icons.
    return [entry.name.pathExtension.lowercaseString isEqualToString:@"ipa"];
}

- (UIContentConfiguration *)ff_gridContentForEntry:(FFEntry *)item
{
    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.text = item.displayName.length ? item.displayName : item.name;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    config.textProperties.numberOfLines = 1;
    config.textProperties.alignment = UIListContentTextAlignmentCenter;

    config.secondaryText = [self formatSize:item.size];
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryTextProperties.numberOfLines = 1;
    config.secondaryTextProperties.alignment = UIListContentTextAlignmentCenter;

    config.image = item.thumbnail ?: [self iconForEntry:item];
    config.imageProperties.maximumSize = CGSizeMake(48, 48);
    config.imageProperties.cornerRadius = 6;
    config.imageProperties.tintColor = item.thumbnail ? nil : [self tintForEntry:item];
    return config;
}

- (UICollectionViewCell *)ff_stable_collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = [collectionView
        dequeueReusableCellWithReuseIdentifier:@"GridCell" forIndexPath:indexPath];

    NSArray<FFEntry *> *entries = nil;
    @try { entries = [self valueForKey:@"filteredEntries"]; }
    @catch (__unused NSException *exception) { entries = nil; }

    if (![entries isKindOfClass:NSArray.class] || indexPath.section != 0 ||
        (NSUInteger)indexPath.item >= entries.count) {
        cell.contentConfiguration = nil;
        return cell;
    }

    FFEntry *item = entries[(NSUInteger)indexPath.item];
    cell.contentConfiguration = [self ff_gridContentForEntry:item];

    if (item.thumbnail || item.isDirectory || item.isSymlink ||
        ![self supportsThumbnail:item]) return cell;

    // Reconfiguration can happen several times while the collection settles.
    // Start at most one thumbnail request per FFEntry object.
    if ([objc_getAssociatedObject(item, kFFGridThumbnailRequestedKey) boolValue]) return cell;
    objc_setAssociatedObject(item, kFFGridThumbnailRequestedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *requestedPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    __weak UICollectionView *weakCollection = collectionView;

    // FFThumbnailService computes its fingerprint (stat/attributes) before it
    // enters its own worker queue. Call it off-main so the first grid render
    // never blocks UIKit on filesystem metadata or IPA cache lookup.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[FFThumbnailService sharedService] thumbnailForPath:requestedPath
            size:CGSizeMake(48, 48) completion:^(UIImage * _Nullable image) {
                if (!image) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    FFBrowserViewController *strongSelf = weakSelf;
                    UICollectionView *strongCollection = weakCollection;
                    if (!strongSelf || !strongCollection || strongCollection.hidden) return;
                    if (![item.path isEqualToString:requestedPath]) return;

                    NSArray<FFEntry *> *current = nil;
                    @try { current = [strongSelf valueForKey:@"filteredEntries"]; }
                    @catch (__unused NSException *exception) { current = nil; }
                    if (![current isKindOfClass:NSArray.class]) return;

                    NSUInteger index = [current indexOfObjectIdenticalTo:item];
                    if (index == NSNotFound || index >= current.count) return;
                    NSIndexPath *currentPath = [NSIndexPath indexPathForItem:index inSection:0];

                    // Do not call reloadItemsAtIndexPaths:. Updating the visible
                    // cell's contentConfiguration does not start a collection
                    // layout transaction and therefore cannot race reloadData.
                    UICollectionViewCell *visible =
                        [strongCollection cellForItemAtIndexPath:currentPath];
                    item.thumbnail = image;
                    if (visible)
                        visible.contentConfiguration = [strongSelf ff_gridContentForEntry:item];
                });
            }];
    });

    return cell;
}

@end
