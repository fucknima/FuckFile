#import "FFPlistEditorViewController.h"
#import "FFPlistDocument.h"
#import "FFPlistValueEditorViewController.h"
#import "FFLogger.h"

#import <CoreFoundation/CoreFoundation.h>

const unsigned long long FFPlistEditorMaximumEditableBytes = 8ULL * 1024ULL * 1024ULL;

static BOOL FFPlistIsBoolean(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL FFPlistNumberIsReal(NSNumber *value)
{
    const char *type = value.objCType;
    return strcmp(type, @encode(float)) == 0 ||
           strcmp(type, @encode(double)) == 0;
}

static BOOL FFPlistIsContainer(id value)
{
    return [value isKindOfClass:NSDictionary.class] ||
           [value isKindOfClass:NSArray.class];
}

static NSString *FFPlistTypeName(id value)
{
    if ([value isKindOfClass:NSDictionary.class]) return @"字典";
    if ([value isKindOfClass:NSArray.class]) return @"数组";
    if ([value isKindOfClass:NSString.class]) return @"字符串";
    if ([value isKindOfClass:NSData.class]) return @"数据";
    if ([value isKindOfClass:NSDate.class]) return @"日期";
    if (FFPlistIsBoolean(value)) return @"布尔";
    if ([value isKindOfClass:NSNumber.class])
        return FFPlistNumberIsReal(value) ? @"实数" : @"整数";
    return @"未知";
}

static NSString *FFPlistSymbolName(id value)
{
    if ([value isKindOfClass:NSDictionary.class]) return @"curlybraces.square";
    if ([value isKindOfClass:NSArray.class]) return @"list.number";
    if ([value isKindOfClass:NSString.class]) return @"text.quote";
    if ([value isKindOfClass:NSData.class]) return @"tray.full";
    if ([value isKindOfClass:NSDate.class]) return @"calendar";
    if (FFPlistIsBoolean(value)) return [value boolValue] ? @"checkmark.circle.fill" : @"xmark.circle";
    if ([value isKindOfClass:NSNumber.class])
        return FFPlistNumberIsReal(value) ? @"function" : @"number.square";
    return @"questionmark.square.dashed";
}

static UIColor *FFPlistTypeTintColor(id value)
{
    if ([value isKindOfClass:NSDictionary.class]) return UIColor.systemOrangeColor;
    if ([value isKindOfClass:NSArray.class]) return UIColor.systemPurpleColor;
    if ([value isKindOfClass:NSString.class]) return UIColor.systemBlueColor;
    if ([value isKindOfClass:NSData.class]) return UIColor.systemGrayColor;
    if ([value isKindOfClass:NSDate.class]) return UIColor.systemRedColor;
    if (FFPlistIsBoolean(value)) return [value boolValue] ? UIColor.systemGreenColor : UIColor.systemGrayColor;
    if ([value isKindOfClass:NSNumber.class])
        return FFPlistNumberIsReal(value) ? UIColor.systemIndigoColor : UIColor.systemTealColor;
    return UIColor.secondaryLabelColor;
}

static NSString *FFPlistValueSummary(id value)
{
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"%lu 项", (unsigned long)[value count]];
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"%lu 项", (unsigned long)[value count]];
    if (FFPlistIsBoolean(value)) return [value boolValue] ? @"YES" : @"NO";
    if ([value isKindOfClass:NSString.class]) {
        NSString *oneLine = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" ↵ "];
        if (oneLine.length > 120)
            oneLine = [[oneLine substringToIndex:117] stringByAppendingString:@"…"];
        return oneLine.length ? oneLine : @"空字符串";
    }
    if ([value isKindOfClass:NSData.class])
        return [NSByteCountFormatter stringFromByteCount:(long long)[value length]
            countStyle:NSByteCountFormatterCountStyleMemory];
    if ([value isKindOfClass:NSDate.class]) {
        static NSDateFormatter *formatter;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [NSDateFormatter new];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterMediumStyle;
        });
        return [formatter stringFromDate:value];
    }
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return [value description] ?: @"";
}

static id FFPlistEditableCopy(id object)
{
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithCapacity:[object count]];
        [object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            copy[key] = FFPlistEditableCopy(value);
        }];
        return copy;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *copy = [NSMutableArray arrayWithCapacity:[object count]];
        for (id value in object) [copy addObject:FFPlistEditableCopy(value)];
        return copy;
    }
    return [object conformsToProtocol:@protocol(NSCopying)] ? [object copy] : object;
}

static BOOL FFPlistPathHasPrefix(NSArray *path, NSArray *prefix)
{
    if (path.count < prefix.count) return NO;
    for (NSUInteger i = 0; i < prefix.count; i++) {
        if (![path[i] isEqual:prefix[i]]) return NO;
    }
    return YES;
}

typedef NS_ENUM(NSInteger, FFPlistNewValueType) {
    FFPlistNewValueString = 0,
    FFPlistNewValueBoolean,
    FFPlistNewValueInteger,
    FFPlistNewValueReal,
    FFPlistNewValueDate,
    FFPlistNewValueData,
    FFPlistNewValueDictionary,
    FFPlistNewValueArray,
};

@interface FFPlistTreeRow : NSObject
@property(nonatomic, copy) NSArray *keyPath;
@property(nonatomic, strong, nullable) id component;
@property(nonatomic, strong) id value;
@property(nonatomic) NSUInteger depth;
@property(nonatomic) BOOL root;
@end

@implementation FFPlistTreeRow
@end

@interface FFPlistTreeGuideView : UIView
@property(nonatomic) NSUInteger depth;
@end

@implementation FFPlistTreeGuideView

- (instancetype)init
{
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setDepth:(NSUInteger)depth
{
    if (_depth == depth) return;
    _depth = depth;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    if (self.depth == 0) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    UIColor *lineColor = [UIColor.separatorColor colorWithAlphaComponent:0.72];
    CGContextSetStrokeColorWithColor(context, lineColor.CGColor);
    CGContextSetLineWidth(context, 1.0 / UIScreen.mainScreen.scale);

    const CGFloat step = 18.0;
    const CGFloat firstX = 9.0;
    const CGFloat midY = CGRectGetMidY(rect);
    for (NSUInteger level = 0; level < self.depth; level++) {
        CGFloat x = firstX + (CGFloat)level * step;
        CGContextMoveToPoint(context, x, CGRectGetMinY(rect));
        CGContextAddLineToPoint(context, x, CGRectGetMaxY(rect));
    }

    CGFloat branchX = firstX + (CGFloat)(self.depth - 1) * step;
    CGContextMoveToPoint(context, branchX, midY);
    CGContextAddLineToPoint(context, CGRectGetMaxX(rect), midY);
    CGContextStrokePath(context);
}

@end

@interface FFPlistTreeCell : UITableViewCell
@property(nonatomic, strong) FFPlistTreeGuideView *guideView;
@property(nonatomic, strong) UIImageView *disclosureIconView;
@property(nonatomic, strong) UIImageView *typeIconView;
@property(nonatomic, strong) UILabel *nodeTitleLabel;
@property(nonatomic, strong) UILabel *nodeDetailLabel;
@property(nonatomic, strong) NSLayoutConstraint *guideWidthConstraint;
@end

@implementation FFPlistTreeCell

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.guideView = [FFPlistTreeGuideView new];
    self.disclosureIconView = [UIImageView new];
    self.typeIconView = [UIImageView new];
    self.nodeTitleLabel = [UILabel new];
    self.nodeDetailLabel = [UILabel new];

    for (UIView *view in @[self.guideView, self.disclosureIconView, self.typeIconView,
                           self.nodeTitleLabel, self.nodeDetailLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:view];
    }

    self.disclosureIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.disclosureIconView.tintColor = UIColor.tertiaryLabelColor;
    self.typeIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.nodeTitleLabel.numberOfLines = 1;
    self.nodeTitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.nodeDetailLabel.numberOfLines = 2;
    self.nodeDetailLabel.textColor = UIColor.secondaryLabelColor;
    self.nodeDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];

    self.guideWidthConstraint = [self.guideView.widthAnchor constraintEqualToConstant:0.0];
    [NSLayoutConstraint activateConstraints:@[
        [self.guideView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8.0],
        [self.guideView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.guideView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        self.guideWidthConstraint,

        [self.disclosureIconView.leadingAnchor constraintEqualToAnchor:self.guideView.trailingAnchor constant:4.0],
        [self.disclosureIconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.disclosureIconView.widthAnchor constraintEqualToConstant:18.0],
        [self.disclosureIconView.heightAnchor constraintEqualToConstant:18.0],

        [self.typeIconView.leadingAnchor constraintEqualToAnchor:self.disclosureIconView.trailingAnchor constant:6.0],
        [self.typeIconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.typeIconView.widthAnchor constraintEqualToConstant:22.0],
        [self.typeIconView.heightAnchor constraintEqualToConstant:22.0],

        [self.nodeTitleLabel.leadingAnchor constraintEqualToAnchor:self.typeIconView.trailingAnchor constant:10.0],
        [self.nodeTitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12.0],
        [self.nodeTitleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],

        [self.nodeDetailLabel.leadingAnchor constraintEqualToAnchor:self.nodeTitleLabel.leadingAnchor],
        [self.nodeDetailLabel.trailingAnchor constraintEqualToAnchor:self.nodeTitleLabel.trailingAnchor],
        [self.nodeDetailLabel.topAnchor constraintEqualToAnchor:self.nodeTitleLabel.bottomAnchor constant:2.0],
        [self.nodeDetailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
    ]];

    return self;
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    self.guideView.depth = 0;
    self.guideWidthConstraint.constant = 0.0;
    self.disclosureIconView.image = nil;
    self.typeIconView.image = nil;
    self.nodeTitleLabel.text = nil;
    self.nodeDetailLabel.text = nil;
}

- (void)configureWithName:(NSString *)name
                    value:(id)value
                    depth:(NSUInteger)depth
                     root:(BOOL)root
                container:(BOOL)container
                 expanded:(BOOL)expanded
{
    NSUInteger visualDepth = MIN(depth, 12);
    self.guideView.depth = visualDepth;
    self.guideWidthConstraint.constant = (CGFloat)visualDepth * 18.0;

    self.disclosureIconView.image = container
        ? [UIImage systemImageNamed:(expanded ? @"chevron.down" : @"chevron.right")]
        : nil;
    self.typeIconView.image = [UIImage systemImageNamed:FFPlistSymbolName(value)];
    self.typeIconView.tintColor = FFPlistTypeTintColor(value);

    self.nodeTitleLabel.text = name;
    if (root) {
        self.nodeTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    } else if (container) {
        self.nodeTitleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
            weight:UIFontWeightSemibold];
    } else {
        self.nodeTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    }
    self.nodeDetailLabel.text = [NSString stringWithFormat:@"%@ · %@",
        FFPlistTypeName(value), FFPlistValueSummary(value)];
}

@end

@interface FFPlistEditorViewController () <UISearchResultsUpdating, UIGestureRecognizerDelegate>
@property(nonatomic, strong) FFPlistDocument *document;
@property(nonatomic, copy) NSArray<FFPlistTreeRow *> *treeRows;
@property(nonatomic, strong) NSMutableSet<NSArray *> *expandedKeyPaths;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UIBarButtonItem *saveButton;
@property(nonatomic, strong) UIBarButtonItem *addButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation FFPlistEditorViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _document = [[FFPlistDocument alloc] initWithPath:path];
        _expandedKeyPaths = [NSMutableSet setWithObject:@[]];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.navigationController.interactivePopGestureRecognizer.delegate == self)
        self.navigationController.interactivePopGestureRecognizer.delegate = nil;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58;
    [self.tableView registerClass:FFPlistTreeCell.class forCellReuseIdentifier:@"PlistTreeNode"];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"搜索 Key 或 Value";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.navigationItem.prompt = nil;
    self.definesPresentationContext = YES;

    self.saveButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave
        target:self action:@selector(saveTapped)];
    self.addButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:nil action:nil];
    self.navigationItem.rightBarButtonItems = @[self.saveButton, self.addButton];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"返回" style:UIBarButtonItemStylePlain
        target:self action:@selector(backTapped)];
    self.navigationController.interactivePopGestureRecognizer.delegate = self;

    self.tableView.tableFooterView = [UIView new];

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(documentDidChange:)
        name:FFPlistDocumentDidChangeNotification object:self.document];

    if (self.document.isLoaded) [self refreshTreeAndUI];
    else [self beginLoading];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshTreeAndUI];
}

#pragma mark - Loading / state

- (void)beginLoading
{
    self.saveButton.enabled = NO;
    self.addButton.enabled = NO;
    self.searchController.searchBar.userInteractionEnabled = NO;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;

    FFPlistDocument *document = self.document;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [document loadWithMaximumBytes:FFPlistEditorMaximumEditableBytes error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.tableView.backgroundView = nil;
            self.spinner = nil;
            self.searchController.searchBar.userInteractionEnabled = YES;
            if (!ok) {
                [self showLoadError:error];
                return;
            }
            [self.expandedKeyPaths removeAllObjects];
            [self.expandedKeyPaths addObject:@[]];
            [self refreshTreeAndUI];
        });
    });
}

- (void)showLoadError:(NSError *)error
{
    NSString *message = error.localizedDescription ?: @"无法打开属性表";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"返回"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentDidChange:(NSNotification *)note
{
    if (note.object != self.document) return;
    [self refreshTreeAndUI];
}

- (id)objectAtKeyPath:(NSArray *)keyPath
{
    id current = self.document.rootObject;
    for (id component in keyPath) {
        if ([component isKindOfClass:NSNumber.class] &&
            [current isKindOfClass:NSArray.class]) {
            NSUInteger index = [component unsignedIntegerValue];
            if (index >= [current count]) return nil;
            current = current[index];
        } else if ([component isKindOfClass:NSString.class] &&
                   [current isKindOfClass:NSDictionary.class]) {
            current = current[component];
        } else {
            return nil;
        }
    }
    return current;
}

- (NSArray *)childComponentsForObject:(id)object
{
    if ([object isKindOfClass:NSDictionary.class]) {
        return [[object allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] localizedCaseInsensitiveCompare:[b description]];
        }];
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *indices = [NSMutableArray arrayWithCapacity:[object count]];
        for (NSUInteger i = 0; i < [object count]; i++) [indices addObject:@(i)];
        return indices;
    }
    return @[];
}

- (id)childOfObject:(id)object component:(id)component
{
    if ([object isKindOfClass:NSDictionary.class] &&
        [component isKindOfClass:NSString.class]) return object[component];
    if ([object isKindOfClass:NSArray.class] &&
        [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        return index < [object count] ? object[index] : nil;
    }
    return nil;
}

- (FFPlistTreeRow *)rowWithPath:(NSArray *)path
                      component:(id)component
                          value:(id)value
                          depth:(NSUInteger)depth
                           root:(BOOL)root
{
    FFPlistTreeRow *row = [FFPlistTreeRow new];
    row.keyPath = [path copy];
    row.component = component;
    row.value = value;
    row.depth = depth;
    row.root = root;
    return row;
}

- (void)appendVisibleRowsForObject:(id)object
                              path:(NSArray *)path
                         component:(id)component
                             depth:(NSUInteger)depth
                              root:(BOOL)root
                              into:(NSMutableArray *)rows
{
    if (!object) return;
    [rows addObject:[self rowWithPath:path component:component value:object depth:depth root:root]];
    if (!FFPlistIsContainer(object) || ![self.expandedKeyPaths containsObject:path]) return;

    for (id childComponent in [self childComponentsForObject:object]) {
        id child = [self childOfObject:object component:childComponent];
        if (!child) continue;
        NSArray *childPath = [path arrayByAddingObject:childComponent];
        [self appendVisibleRowsForObject:child path:childPath component:childComponent
            depth:depth + 1 root:NO into:rows];
    }
}

- (void)appendAllRowsForObject:(id)object
                          path:(NSArray *)path
                     component:(id)component
                         depth:(NSUInteger)depth
                          root:(BOOL)root
                          into:(NSMutableArray *)rows
{
    if (!object) return;
    [rows addObject:[self rowWithPath:path component:component value:object depth:depth root:root]];
    if (!FFPlistIsContainer(object)) return;
    for (id childComponent in [self childComponentsForObject:object]) {
        id child = [self childOfObject:object component:childComponent];
        if (!child) continue;
        NSArray *childPath = [path arrayByAddingObject:childComponent];
        [self appendAllRowsForObject:child path:childPath component:childComponent
            depth:depth + 1 root:NO into:rows];
    }
}

- (NSString *)displayNameForRow:(FFPlistTreeRow *)row
{
    if (row.root) return @"Root";
    if ([row.component isKindOfClass:NSNumber.class])
        return [NSString stringWithFormat:@"[%@]", row.component];
    return [row.component description] ?: @"";
}

- (BOOL)row:(FFPlistTreeRow *)row matchesQuery:(NSString *)query
{
    if (query.length == 0) return YES;
    NSString *name = [self displayNameForRow:row];
    NSString *summary = FFPlistValueSummary(row.value);
    NSString *type = FFPlistTypeName(row.value);
    NSString *path = [self pathStringForKeyPath:row.keyPath];
    return [name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [summary rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [type rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [path rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (NSArray<FFPlistTreeRow *> *)searchRowsForQuery:(NSString *)query
{
    NSMutableArray *allRows = [NSMutableArray array];
    [self appendAllRowsForObject:self.document.rootObject path:@[] component:nil
        depth:0 root:YES into:allRows];

    NSMutableSet<NSArray *> *visiblePaths = [NSMutableSet set];
    for (FFPlistTreeRow *row in allRows) {
        if (![self row:row matchesQuery:query]) continue;
        for (NSUInteger length = 0; length <= row.keyPath.count; length++) {
            [visiblePaths addObject:[row.keyPath subarrayWithRange:NSMakeRange(0, length)]];
        }
    }
    if (visiblePaths.count == 0) return @[];

    NSMutableArray *result = [NSMutableArray array];
    for (FFPlistTreeRow *row in allRows) {
        if ([visiblePaths containsObject:row.keyPath]) [result addObject:row];
    }
    return result;
}

- (void)refreshTreeAndUI
{
    if (!self.document.isLoaded) return;

    NSString *query = [self.searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length > 0) {
        self.treeRows = [self searchRowsForQuery:query];
    } else {
        NSMutableArray *rows = [NSMutableArray array];
        [self appendVisibleRowsForObject:self.document.rootObject path:@[] component:nil
            depth:0 root:YES into:rows];
        self.treeRows = rows;
    }

    self.saveButton.enabled = self.document.isDirty;
    self.addButton.enabled = FFPlistIsContainer(self.document.rootObject);
    self.addButton.menu = [self buildAddMenuForContainerPath:@[] title:@"添加到 Root"];
    self.navigationItem.prompt = nil;

    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState
{
    if (!self.document.isLoaded || self.treeRows.count > 0) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.numberOfLines = 0;
    label.text = self.searchController.searchBar.text.length ?
        @"没有匹配的 Key 或 Value" : @"属性表为空";
    self.tableView.backgroundView = label;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController
{
    [self refreshTreeAndUI];
}

- (void)expandAncestorsForPath:(NSArray *)path
{
    for (NSUInteger length = 0; length <= path.count; length++) {
        NSArray *prefix = [path subarrayWithRange:NSMakeRange(0, length)];
        id value = [self objectAtKeyPath:prefix];
        if (FFPlistIsContainer(value)) [self.expandedKeyPaths addObject:prefix];
    }
}

- (void)revealPathAfterSearch:(NSArray *)path
{
    [self expandAncestorsForPath:path];
    self.searchController.searchBar.text = @"";
    self.searchController.active = NO;
    [self refreshTreeAndUI];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger index = [self.treeRows indexOfObjectPassingTest:^BOOL(FFPlistTreeRow *row, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop;
            return [row.keyPath isEqual:path];
        }];
        if (index != NSNotFound) {
            [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)index inSection:0]
                atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        }
    });
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return (NSInteger)self.treeRows.count;
}

- (BOOL)isRowExpandedAtIndex:(NSUInteger)index
{
    if (index >= self.treeRows.count) return NO;
    FFPlistTreeRow *row = self.treeRows[index];
    if (!FFPlistIsContainer(row.value)) return NO;

    NSString *query = [self.searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) return [self.expandedKeyPaths containsObject:row.keyPath];

    if (index + 1 >= self.treeRows.count) return NO;
    return self.treeRows[index + 1].depth > row.depth;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFPlistTreeCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PlistTreeNode"
        forIndexPath:indexPath];
    FFPlistTreeRow *row = self.treeRows[(NSUInteger)indexPath.row];
    BOOL container = FFPlistIsContainer(row.value);
    BOOL expanded = [self isRowExpandedAtIndex:(NSUInteger)indexPath.row];

    [cell configureWithName:[self displayNameForRow:row]
        value:row.value depth:row.depth root:row.root container:container expanded:expanded];
    cell.separatorInset = UIEdgeInsetsMake(0, 58.0 + (CGFloat)MIN(row.depth, 12) * 18.0, 0, 0);
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFPlistTreeRow *row = self.treeRows[(NSUInteger)indexPath.row];
    [self openRow:row];
}

- (void)openRow:(FFPlistTreeRow *)row
{
    if (!row.value) return;
    if (FFPlistIsContainer(row.value)) {
        NSString *query = [self.searchController.searchBar.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (query.length > 0) {
            [self revealPathAfterSearch:row.keyPath];
            return;
        }

        if ([self.expandedKeyPaths containsObject:row.keyPath])
            [self.expandedKeyPaths removeObject:row.keyPath];
        else
            [self.expandedKeyPaths addObject:row.keyPath];
        [self refreshTreeAndUI];
        return;
    }

    __weak typeof(self) weakSelf = self;
    FFPlistValueEditorViewController *editor =
        [[FFPlistValueEditorViewController alloc] initWithValue:row.value
            title:[self displayNameForRow:row]
            commitHandler:^(id newValue) {
                [weakSelf replaceValueAtPath:row.keyPath withValue:newValue];
            }];
    [self.navigationController pushViewController:editor animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    FFPlistTreeRow *row = self.treeRows[(NSUInteger)indexPath.row];
    if (row.root) return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(__unused UIContextualAction *action,
            __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
            [weakSelf confirmDeletePath:row.keyPath completion:completionHandler];
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                      point:(CGPoint)point
{
    (void)tableView; (void)point;
    FFPlistTreeRow *row = self.treeRows[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
            NSMutableArray *children = [NSMutableArray array];

            if (FFPlistIsContainer(row.value)) {
                BOOL expanded = [weakSelf.expandedKeyPaths containsObject:row.keyPath];
                [children addObject:[UIAction actionWithTitle:(expanded ? @"收起" : @"展开")
                    image:[UIImage systemImageNamed:(expanded ? @"chevron.up" : @"chevron.down")]
                    identifier:nil handler:^(__unused UIAction *action) { [weakSelf openRow:row]; }]];
                [children addObject:[weakSelf buildAddMenuForContainerPath:row.keyPath title:@"添加子项"]];
            } else {
                [children addObject:[UIAction actionWithTitle:@"编辑"
                    image:[UIImage systemImageNamed:@"pencil"] identifier:nil
                    handler:^(__unused UIAction *action) { [weakSelf openRow:row]; }]];
            }

            [children addObject:[UIAction actionWithTitle:@"复制值"
                image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf copyValueAtPath:row.keyPath]; }]];
            [children addObject:[UIAction actionWithTitle:@"复制 Key Path"
                image:[UIImage systemImageNamed:@"point.topleft.down.curvedto.point.bottomright.up"]
                identifier:nil handler:^(__unused UIAction *action) {
                    [UIPasteboard generalPasteboard].string = [weakSelf pathStringForKeyPath:row.keyPath];
                }]];

            if (row.root) {
                [children addObject:[UIAction actionWithTitle:@"全部展开"
                    image:[UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left"] identifier:nil
                    handler:^(__unused UIAction *action) { [weakSelf expandAll]; }]];
                [children addObject:[UIAction actionWithTitle:@"全部收起"
                    image:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"] identifier:nil
                    handler:^(__unused UIAction *action) { [weakSelf collapseAll]; }]];
                return [UIMenu menuWithTitle:@"" children:children];
            }

            id parent = [weakSelf parentObjectForPath:row.keyPath];
            if ([parent isKindOfClass:NSDictionary.class]) {
                [children addObject:[UIAction actionWithTitle:@"重命名 Key"
                    image:[UIImage systemImageNamed:@"character.cursor.ibeam"] identifier:nil
                    handler:^(__unused UIAction *action) { [weakSelf promptRenamePath:row.keyPath]; }]];
            }

            [children addObject:[UIAction actionWithTitle:@"复制条目"
                image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf duplicatePath:row.keyPath]; }]];

            if ([parent isKindOfClass:NSArray.class]) {
                NSUInteger idx = [row.keyPath.lastObject unsignedIntegerValue];
                if (idx > 0)
                    [children addObject:[UIAction actionWithTitle:@"上移"
                        image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil
                        handler:^(__unused UIAction *action) { [weakSelf moveArrayPath:row.keyPath offset:-1]; }]];
                if (idx + 1 < [parent count])
                    [children addObject:[UIAction actionWithTitle:@"下移"
                        image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil
                        handler:^(__unused UIAction *action) { [weakSelf moveArrayPath:row.keyPath offset:1]; }]];
            }

            [children addObject:[weakSelf changeTypeMenuForPath:row.keyPath]];
            [children addObject:[UIAction actionWithTitle:@"删除"
                image:[UIImage systemImageNamed:@"trash"] identifier:nil
                handler:^(__unused UIAction *action) {
                    [weakSelf confirmDeletePath:row.keyPath completion:nil];
                }]];
            return [UIMenu menuWithTitle:@"" children:children];
        }];
}

#pragma mark - Tree expansion

- (void)collectContainerPathsForObject:(id)object path:(NSArray *)path into:(NSMutableSet *)paths
{
    if (!FFPlistIsContainer(object)) return;
    [paths addObject:path];
    for (id component in [self childComponentsForObject:object]) {
        id child = [self childOfObject:object component:component];
        if (!child) continue;
        [self collectContainerPathsForObject:child
            path:[path arrayByAddingObject:component] into:paths];
    }
}

- (void)expandAll
{
    NSMutableSet *paths = [NSMutableSet set];
    [self collectContainerPathsForObject:self.document.rootObject path:@[] into:paths];
    self.expandedKeyPaths = paths;
    [self refreshTreeAndUI];
}

- (void)collapseAll
{
    [self.expandedKeyPaths removeAllObjects];
    if (FFPlistIsContainer(self.document.rootObject)) [self.expandedKeyPaths addObject:@[]];
    [self refreshTreeAndUI];
}

- (void)removeExpandedPathsWithPrefix:(NSArray *)prefix
{
    NSArray *snapshot = self.expandedKeyPaths.allObjects;
    for (NSArray *path in snapshot) {
        if (FFPlistPathHasPrefix(path, prefix)) [self.expandedKeyPaths removeObject:path];
    }
}

- (void)removeExpandedDescendantsOfPath:(NSArray *)path
{
    NSArray *snapshot = self.expandedKeyPaths.allObjects;
    for (NSArray *candidate in snapshot) {
        if (candidate.count > path.count && FFPlistPathHasPrefix(candidate, path))
            [self.expandedKeyPaths removeObject:candidate];
    }
}

- (void)remapExpandedPathsFromPrefix:(NSArray *)oldPrefix toPrefix:(NSArray *)newPrefix
{
    NSArray *snapshot = self.expandedKeyPaths.allObjects;
    for (NSArray *path in snapshot) {
        if (!FFPlistPathHasPrefix(path, oldPrefix)) continue;
        NSArray *suffix = [path subarrayWithRange:NSMakeRange(oldPrefix.count, path.count - oldPrefix.count)];
        NSArray *replacement = [newPrefix arrayByAddingObjectsFromArray:suffix];
        [self.expandedKeyPaths removeObject:path];
        [self.expandedKeyPaths addObject:replacement];
    }
}

#pragma mark - Mutations

- (id)parentObjectForPath:(NSArray *)path
{
    if (path.count == 0) return nil;
    NSArray *parentPath = [path subarrayWithRange:NSMakeRange(0, path.count - 1)];
    return [self objectAtKeyPath:parentPath];
}

- (void)replaceValueAtPath:(NSArray *)path withValue:(id)value
{
    if (!value || path.count == 0) return;
    id parent = [self parentObjectForPath:path];
    id component = path.lastObject;
    if ([parent isKindOfClass:NSDictionary.class] && [component isKindOfClass:NSString.class]) {
        parent[component] = value;
    } else if ([parent isKindOfClass:NSArray.class] && [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        if (index >= [parent count]) return;
        [parent replaceObjectAtIndex:index withObject:value];
    } else return;

    if (!FFPlistIsContainer(value)) [self removeExpandedPathsWithPrefix:path];
    [self.document markChanged];
}

- (void)confirmDeletePath:(NSArray *)path completion:(void (^ _Nullable)(BOOL))completion
{
    NSString *name = path.count ? [path.lastObject description] : @"Root";
    if ([path.lastObject isKindOfClass:NSNumber.class])
        name = [NSString stringWithFormat:@"[%@]", path.lastObject];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除条目？"
        message:[NSString stringWithFormat:@"将删除 %@。此操作在保存文件前仍可通过放弃修改撤销。", name]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            BOOL removed = [weakSelf removePath:path];
            if (completion) completion(removed);
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)removePath:(NSArray *)path
{
    if (path.count == 0) return NO;
    id parent = [self parentObjectForPath:path];
    id component = path.lastObject;
    NSArray *parentPath = [path subarrayWithRange:NSMakeRange(0, path.count - 1)];

    if ([parent isKindOfClass:NSDictionary.class] && [component isKindOfClass:NSString.class]) {
        if (!parent[component]) return NO;
        [parent removeObjectForKey:component];
        [self removeExpandedPathsWithPrefix:path];
    } else if ([parent isKindOfClass:NSArray.class] && [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        if (index >= [parent count]) return NO;
        [parent removeObjectAtIndex:index];
        [self removeExpandedDescendantsOfPath:parentPath];
    } else return NO;

    [self.document markChanged];
    return YES;
}

- (void)promptRenamePath:(NSArray *)path
{
    if (path.count == 0) return;
    id parent = [self parentObjectForPath:path];
    NSString *component = [path.lastObject isKindOfClass:NSString.class] ? path.lastObject : nil;
    if (![parent isKindOfClass:NSDictionary.class] || !component) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名 Key"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = component;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *newKey = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (newKey.length == 0) { [weakSelf showMessage:@"Key 不能为空" title:@"无法重命名"]; return; }
            if ([newKey isEqualToString:component]) return;
            if (parent[newKey] != nil) {
                [weakSelf showMessage:@"同名 Key 已存在，不会覆盖原值。" title:@"无法重命名"];
                return;
            }
            id value = parent[component];
            if (!value) return;
            parent[newKey] = value;
            [parent removeObjectForKey:component];

            NSArray *parentPath = [path subarrayWithRange:NSMakeRange(0, path.count - 1)];
            NSArray *newPath = [parentPath arrayByAddingObject:newKey];
            [weakSelf remapExpandedPathsFromPrefix:path toPrefix:newPath];
            [weakSelf.document markChanged];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)duplicatePath:(NSArray *)path
{
    if (path.count == 0) return;
    id value = [self objectAtKeyPath:path];
    id parent = [self parentObjectForPath:path];
    id component = path.lastObject;
    if (!value || !parent) return;
    id copy = FFPlistEditableCopy(value);

    if ([parent isKindOfClass:NSDictionary.class] && [component isKindOfClass:NSString.class]) {
        NSString *base = [NSString stringWithFormat:@"%@ copy", component];
        NSString *candidate = base;
        NSUInteger n = 2;
        while (parent[candidate] != nil)
            candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n++];
        parent[candidate] = copy;
    } else if ([parent isKindOfClass:NSArray.class] && [component isKindOfClass:NSNumber.class]) {
        NSUInteger index = [component unsignedIntegerValue];
        if (index >= [parent count]) return;
        [parent insertObject:copy atIndex:index + 1];
        NSArray *parentPath = [path subarrayWithRange:NSMakeRange(0, path.count - 1)];
        [self removeExpandedDescendantsOfPath:parentPath];
    } else return;

    [self.document markChanged];
}

- (void)moveArrayPath:(NSArray *)path offset:(NSInteger)offset
{
    if (path.count == 0) return;
    id parent = [self parentObjectForPath:path];
    if (![parent isKindOfClass:NSArray.class]) return;

    NSInteger from = [path.lastObject integerValue], to = from + offset;
    if (from < 0 || to < 0 || from >= (NSInteger)[parent count] || to >= (NSInteger)[parent count]) return;
    id value = parent[(NSUInteger)from];
    [parent removeObjectAtIndex:(NSUInteger)from];
    [parent insertObject:value atIndex:(NSUInteger)to];
    NSArray *parentPath = [path subarrayWithRange:NSMakeRange(0, path.count - 1)];
    [self removeExpandedDescendantsOfPath:parentPath];
    [self.document markChanged];
}

- (void)copyValueAtPath:(NSArray *)path
{
    id value = [self objectAtKeyPath:path];
    NSString *text = nil;
    if ([value isKindOfClass:NSData.class]) text = [value base64EncodedStringWithOptions:0];
    else if ([value isKindOfClass:NSDate.class]) text = [value description];
    else if ([value isKindOfClass:NSString.class]) text = value;
    else if ([value isKindOfClass:NSNumber.class]) text = [value stringValue];
    else text = [value description];
    [UIPasteboard generalPasteboard].string = text ?: @"";
}

- (NSString *)pathStringForKeyPath:(NSArray *)keyPath
{
    NSMutableString *path = [NSMutableString stringWithString:@"Root"];
    for (id part in keyPath) {
        if ([part isKindOfClass:NSNumber.class]) [path appendFormat:@"[%@]", part];
        else [path appendFormat:@".%@", part];
    }
    return path;
}

#pragma mark - Add / type

- (UIMenu *)buildAddMenuForContainerPath:(NSArray *)containerPath title:(NSString *)title
{
    id container = [self objectAtKeyPath:containerPath];
    if (!FFPlistIsContainer(container)) return [UIMenu menuWithTitle:title children:@[]];

    NSMutableArray *actions = [NSMutableArray array];
    NSArray *specs = @[
        @[@(FFPlistNewValueString), @"字符串", @"text.quote"],
        @[@(FFPlistNewValueBoolean), @"布尔", @"checkmark.circle"],
        @[@(FFPlistNewValueInteger), @"整数", @"number.square"],
        @[@(FFPlistNewValueReal), @"实数", @"function"],
        @[@(FFPlistNewValueDate), @"日期", @"calendar"],
        @[@(FFPlistNewValueData), @"数据", @"tray.full"],
        @[@(FFPlistNewValueDictionary), @"字典", @"curlybraces.square"],
        @[@(FFPlistNewValueArray), @"数组", @"list.number"],
    ];
    __weak typeof(self) weakSelf = self;
    for (NSArray *spec in specs) {
        FFPlistNewValueType type = [spec[0] integerValue];
        [actions addObject:[UIAction actionWithTitle:spec[1]
            image:[UIImage systemImageNamed:spec[2]] identifier:nil
            handler:^(__unused UIAction *action) { [weakSelf addValueOfType:type toContainerPath:containerPath]; }]];
    }
    return [UIMenu menuWithTitle:title children:actions];
}

- (id)defaultValueForType:(FFPlistNewValueType)type
{
    switch (type) {
        case FFPlistNewValueBoolean: return @NO;
        case FFPlistNewValueInteger: return @0;
        case FFPlistNewValueReal: return @0.0;
        case FFPlistNewValueDate: return NSDate.date;
        case FFPlistNewValueData: return NSMutableData.data;
        case FFPlistNewValueDictionary: return [NSMutableDictionary dictionary];
        case FFPlistNewValueArray: return [NSMutableArray array];
        default: return @"";
    }
}

- (NSString *)nameForType:(FFPlistNewValueType)type
{
    switch (type) {
        case FFPlistNewValueBoolean: return @"布尔";
        case FFPlistNewValueInteger: return @"整数";
        case FFPlistNewValueReal: return @"实数";
        case FFPlistNewValueDate: return @"日期";
        case FFPlistNewValueData: return @"数据";
        case FFPlistNewValueDictionary: return @"字典";
        case FFPlistNewValueArray: return @"数组";
        default: return @"字符串";
    }
}

- (void)addValueOfType:(FFPlistNewValueType)type toContainerPath:(NSArray *)containerPath
{
    id container = [self objectAtKeyPath:containerPath];
    if ([container isKindOfClass:NSArray.class]) {
        [container addObject:[self defaultValueForType:type]];
        [self.expandedKeyPaths addObject:containerPath];
        [self.document markChanged];
        return;
    }
    if (![container isKindOfClass:NSDictionary.class]) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"添加%@", [self nameForType:type]]
        message:[NSString stringWithFormat:@"添加到 %@；已有 Key 不会被覆盖。", [self pathStringForKeyPath:containerPath]]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Key";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *key = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (key.length == 0) { [weakSelf showMessage:@"Key 不能为空" title:@"无法添加"]; return; }
            if (container[key] != nil) {
                [weakSelf showMessage:@"同名 Key 已存在，不会覆盖原值。" title:@"无法添加"];
                return;
            }
            container[key] = [weakSelf defaultValueForType:type];
            [weakSelf.expandedKeyPaths addObject:containerPath];
            [weakSelf.document markChanged];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIMenu *)changeTypeMenuForPath:(NSArray *)path
{
    NSArray *specs = @[
        @[@(FFPlistNewValueString), @"字符串"], @[@(FFPlistNewValueBoolean), @"布尔"],
        @[@(FFPlistNewValueInteger), @"整数"], @[@(FFPlistNewValueReal), @"实数"],
        @[@(FFPlistNewValueDate), @"日期"], @[@(FFPlistNewValueData), @"数据"],
        @[@(FFPlistNewValueDictionary), @"字典"], @[@(FFPlistNewValueArray), @"数组"],
    ];
    NSMutableArray *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSArray *spec in specs) {
        FFPlistNewValueType type = [spec[0] integerValue];
        [actions addObject:[UIAction actionWithTitle:spec[1] image:nil identifier:nil
            handler:^(__unused UIAction *action) { [weakSelf confirmChangePath:path toType:type]; }]];
    }
    return [UIMenu menuWithTitle:@"更改类型（重置值）"
        image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil
        options:0 children:actions];
}

- (void)confirmChangePath:(NSArray *)path toType:(FFPlistNewValueType)type
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"更改类型？"
        message:[NSString stringWithFormat:@"当前值将被重置为新的%@默认值。", [self nameForType:type]]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"更改" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf removeExpandedPathsWithPrefix:path];
            [weakSelf replaceValueAtPath:path withValue:[weakSelf defaultValueForType:type]];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Save / conflict

- (void)saveTapped { [self attemptSaveWithCompletion:nil]; }

- (void)attemptSaveWithCompletion:(void (^ _Nullable)(BOOL success))completion
{
    NSError *error = nil;
    if ([self.document saveForcingExternalOverwrite:NO error:&error]) {
        [self flash:@"已保存"];
        if (completion) completion(YES);
        return;
    }
    if ([error.domain isEqualToString:FFPlistDocumentErrorDomain] &&
        error.code == FFPlistDocumentErrorExternalModification) {
        [self presentConflict:error completion:completion];
        return;
    }
    FFLogTag(@"PlistEditor", @"save FAIL path=%@ error=%@", self.document.filePath, error);
    [self offerCopyForSaveError:error completion:completion];
}

- (void)presentConflict:(NSError *)error completion:(void (^ _Nullable)(BOOL))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件已在外部修改"
        message:@"打开此 plist 后，磁盘内容发生了变化。为避免覆盖 App 或系统刚写入的数据，请选择处理方式。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重新载入" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf reloadFromDiskDiscardingChanges]; if (completion) completion(NO);
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf saveCopy]; if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"仍然覆盖" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSError *forceError = nil;
            BOOL ok = [weakSelf.document saveForcingExternalOverwrite:YES error:&forceError];
            if (ok) [weakSelf flash:@"已覆盖保存"];
            else [weakSelf showMessage:forceError.localizedDescription ?: @"覆盖保存失败" title:@"保存失败"];
            if (completion) completion(ok);
        }]];
    (void)error;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)offerCopyForSaveError:(NSError *)error completion:(void (^ _Nullable)(BOOL))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法写入原文件"
        message:[NSString stringWithFormat:@"%@\n\n可以保存副本到 FuckFile 文档。",
            error.localizedDescription ?: @"当前位置不可写。"]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { if (completion) completion(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf saveCopy]; if (completion) completion(NO); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveCopy
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *folder = [documents stringByAppendingPathComponent:@"Edited Copies"];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError) { [self showMessage:directoryError.localizedDescription title:@"副本保存失败"]; return; }

    NSString *name = self.document.filePath.lastPathComponent;
    NSString *stem = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *suffix = [formatter stringFromDate:NSDate.date];
    NSString *copyName = ext.length
        ? [NSString stringWithFormat:@"%@-edited-%@.%@", stem, suffix, ext]
        : [NSString stringWithFormat:@"%@-edited-%@", stem, suffix];
    NSString *copyPath = [folder stringByAppendingPathComponent:copyName];

    NSError *error = nil;
    if ([self.document saveCopyToPath:copyPath error:&error]) [self showMessage:copyPath title:@"副本已保存"];
    else [self showMessage:error.localizedDescription ?: @"副本写入失败" title:@"副本保存失败"];
}

- (void)reloadFromDiskDiscardingChanges
{
    NSError *error = nil;
    if (![self.document loadWithMaximumBytes:FFPlistEditorMaximumEditableBytes error:&error]) {
        [self showMessage:error.localizedDescription ?: @"重新载入失败" title:@"重新载入失败"];
        return;
    }
    [self.expandedKeyPaths removeAllObjects];
    if (FFPlistIsContainer(self.document.rootObject)) [self.expandedKeyPaths addObject:@[]];
    [self refreshTreeAndUI];
    [self flash:@"已重新载入磁盘版本"];
}

#pragma mark - Back / unsaved

- (void)backTapped
{
    if (!self.document.isDirty) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未保存的修改"
        message:@"是否保存对此 plist 的修改？" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf attemptSaveWithCompletion:^(BOOL success) {
                if (success) [weakSelf.navigationController popViewControllerAnimated:YES];
            }];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf.navigationController popViewControllerAnimated:YES]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer == self.navigationController.interactivePopGestureRecognizer && self.document.isDirty) {
        [self backTapped];
        return NO;
    }
    return YES;
}

#pragma mark - Feedback

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

@end
