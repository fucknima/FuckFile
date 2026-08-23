#import "FFBrowserViewController.h"

#import <objc/runtime.h>

// Presentation-only adapter for the legacy browser controller.
//
// FFBrowserViewController currently contains mature file-operation, task,
// preview, import and crash-workaround logic in one large implementation.
// This adapter deliberately changes only UIKit presentation selectors so the
// UI can evolve without rewriting those working code paths. Every swizzled
// selector either calls the original implementation first or replaces only a
// layout calculation. File operations and navigation routing are untouched.

static void FFSwapBrowserMethod(Class cls, SEL original, SEL replacement)
{
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (!originalMethod || !replacementMethod) return;
    method_exchangeImplementations(originalMethod, replacementMethod);
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

@interface FFBrowserViewController (FFBrowserPresentation)
- (void)ffui_viewDidLoad;
- (void)ffui_viewWillAppear:(BOOL)animated;
- (void)ffui_configureCell:(UITableViewCell *)cell withItem:(FFEntry *)item;
- (CGSize)ffui_collectionView:(UICollectionView *)collectionView
                       layout:(UICollectionViewLayout *)collectionViewLayout
       sizeForItemAtIndexPath:(NSIndexPath *)indexPath;
- (UICollectionViewCell *)ffui_collectionView:(UICollectionView *)collectionView
                        cellForItemAtIndexPath:(NSIndexPath *)indexPath;
- (UIMenu *)ffui_moreMenu;
@end

@implementation FFBrowserViewController (FFBrowserPresentation)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FFBrowserViewController.class;
        FFSwapBrowserMethod(cls, @selector(viewDidLoad), @selector(ffui_viewDidLoad));
        FFSwapBrowserMethod(cls, @selector(viewWillAppear:), @selector(ffui_viewWillAppear:));
        FFSwapBrowserMethod(cls, @selector(configureCell:withItem:),
                            @selector(ffui_configureCell:withItem:));
        FFSwapBrowserMethod(cls,
            @selector(collectionView:layout:sizeForItemAtIndexPath:),
            @selector(ffui_collectionView:layout:sizeForItemAtIndexPath:));
        FFSwapBrowserMethod(cls,
            @selector(collectionView:cellForItemAtIndexPath:),
            @selector(ffui_collectionView:cellForItemAtIndexPath:));
        FFSwapBrowserMethod(cls, @selector(moreMenu), @selector(ffui_moreMenu));
    });
}

- (void)ffui_viewDidLoad
{
    // Calls the original -viewDidLoad after swizzling.
    [self ffui_viewDidLoad];

    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 64, 0, 0);
}

- (void)ffui_viewWillAppear:(BOOL)animated
{
    // Calls the original -viewWillAppear: after swizzling.
    [self ffui_viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)ffui_configureCell:(UITableViewCell *)cell withItem:(FFEntry *)item
{
    // Preserve the browser's icon/thumbnail generation and async refresh path,
    // then only restyle the resulting list content configuration.
    [self ffui_configureCell:cell withItem:item];

    id<UIContentConfiguration> current = cell.contentConfiguration;
    if (![current isKindOfClass:UIListContentConfiguration.class]) return;
    UIListContentConfiguration *config = (UIListContentConfiguration *)current;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.numberOfLines = 1;
    config.secondaryText = FFBrowserCompactDetail(item);
    config.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.secondaryTextProperties.numberOfLines = 1;
    config.imageProperties.maximumSize = CGSizeMake(40, 40);
    config.imageProperties.cornerRadius = 6;
    cell.contentConfiguration = config;
}

- (CGSize)ffui_collectionView:(UICollectionView *)collectionView
                       layout:(UICollectionViewLayout *)collectionViewLayout
       sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    // Keep the original crash-prevention rule (integer/floored widths), while
    // choosing the column count from actual available width instead of fixing
    // every device to three columns.
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
    if (![current isKindOfClass:UIListContentConfiguration.class]) return cell;
    UIListContentConfiguration *config = (UIListContentConfiguration *)current;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.textProperties.numberOfLines = 1;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.imageProperties.maximumSize = CGSizeMake(52, 52);
    config.imageProperties.cornerRadius = 8;
    contentView.configuration = config;
    return cell;
}

- (UIMenu *)ffui_moreMenu
{
    // Calls the original menu builder, then prepends a view-mode selector.
    // Existing Paste / Import / Multi-select / Sort / Filter actions stay intact.
    UIMenu *base = [self ffui_moreMenu];
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

    UIMenu *viewMode = [UIMenu menuWithTitle:@"视图"
        image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[list, grid]];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObject:viewMode];
    [children addObjectsFromArray:base.children ?: @[]];
    return [UIMenu menuWithTitle:base.title ?: @"更多"
        image:base.image identifier:base.identifier options:base.options children:children];
}

@end
