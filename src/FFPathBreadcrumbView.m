#import "FFPathBreadcrumbView.h"
#import "FFBrowserViewController.h"
#import "MCMManager.h"

#import <objc/runtime.h>

@implementation FFPathBreadcrumbItem
@end

static NSString *const kFFStorageRootLabel = @"设备存储";

@implementation FFPathBreadcrumbView {
    UIStackView *_stack;
    UIScrollView *_scroll;
    NSLayoutConstraint *_heightConstraint;
}

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _path = [path copy];
        self.backgroundColor = [UIColor systemBackgroundColor];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        // 固定高度，隐藏（root）时收缩为 0，不给列表留下空隙。
        _heightConstraint = [self.heightAnchor constraintEqualToConstant:36];
        [NSLayoutConstraint activateConstraints:@[_heightConstraint]];

        _scroll = [UIScrollView new];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.showsHorizontalScrollIndicator = NO;
        [self addSubview:_scroll];
        [NSLayoutConstraint activateConstraints:@[
            [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        _stack = [UIStackView new];
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.alignment = UIStackViewAlignmentCenter;
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_scroll addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor
                                                  constant:16],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor
                                                   constant:-8],
            [_stack.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor],
        ]];

        [self rebuild];
    }
    return self;
}

// (label, absolute path) pairs. Under the storage root the container
// scaffolding is replaced by the "设备存储" label so no /private/var/...
// prefixes leak into the UI. Ancestor taps always carry the exact absolute
// path and navigate through the normal browser model.
- (void)rebuild
{
    for (UIView *view in [_stack.arrangedSubviews copy])
        [view removeFromSuperview];

    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *root = [MCMVirtualRoot() stringByStandardizingPath];
    NSString *standardized = [self.path stringByStandardizingPath];

    if ([standardized isEqualToString:root]) {
        [labels addObject:kFFStorageRootLabel];
        [paths addObject:root];
    } else if ([standardized hasPrefix:[root stringByAppendingString:@"/"]]) {
        NSArray<NSString *> *rest = [[standardized substringFromIndex:root.length + 1]
            pathComponents];
        [labels addObject:kFFStorageRootLabel];
        [paths addObject:root];
        NSString *accumulated = root;
        for (NSString *component in rest) {
            accumulated = [accumulated stringByAppendingPathComponent:component];
            [labels addObject:component];
            [paths addObject:accumulated];
        }
    } else {
        // Generic absolute path: walk the real components, drop the leading
        // containment scaffolding (/private/var/mobile/Containers/Data/
        // Application), keep exact prefix paths for every visible segment.
        NSSet<NSString *> *scaffold = [NSSet setWithArray:@[
            @"/", @"private", @"var", @"mobile", @"Containers", @"Data",
            @"Application",
        ]];
        BOOL leading = YES;
        NSString *accumulated = @"";
        for (NSString *component in standardized.pathComponents) {
            if (leading && [scaffold containsObject:component]) continue;
            leading = NO;
            accumulated = accumulated.length
                ? [accumulated stringByAppendingPathComponent:component]
                : component;
            [labels addObject:component];
            [paths addObject:accumulated];
        }
        if (labels.count > 8) {
            NSRange drop = NSMakeRange(0, labels.count - 8);
            [labels removeObjectsInRange:drop];
            [paths removeObjectsInRange:drop];
            [labels insertObject:@"…" atIndex:0];
            [paths insertObject:@"" atIndex:0];
        }
    }

    self.hidden = labels.count <= 1;
    _heightConstraint.constant = self.hidden ? 0 : 36;
    if (self.hidden) return;

    for (NSUInteger index = 0; index < labels.count; index++) {
        NSString *label = labels[index];
        BOOL isLast = index == labels.count - 1;
        BOOL isEllipsis = label.length == 0 || [label isEqualToString:@"…"];
        if (index > 0) {
            UILabel *separator = [UILabel new];
            separator.text = @"›";
            separator.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            separator.textColor = [UIColor tertiaryLabelColor];
            [_stack addArrangedSubview:separator];
        }
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateDisabled];
        [button setTitle:label forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        // Current directory emphasized; ancestors read as links; "…" plain.
        [button setTitleColor:(isLast ? [UIColor labelColor] : [UIColor linkColor])
                     forState:UIControlStateNormal];
        if (isEllipsis) [button setTitleColor:[UIColor secondaryLabelColor]
                                    forState:UIControlStateNormal];
        button.accessibilityLabel = [NSString stringWithFormat:@"路径 %@", label];
        button.userInteractionEnabled = !isEllipsis && !isLast && paths[index].length > 0;
        if (button.userInteractionEnabled) {
            [button addTarget:self action:@selector(segmentTapped:)
             forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(button, "ff.crumb.path", paths[index],
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [_stack addArrangedSubview:button];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_scroll) return;
        CGFloat offset = MAX(0, _scroll.contentSize.width - _scroll.bounds.size.width);
        [_scroll setContentOffset:CGPointMake(offset, 0) animated:NO];
    });
}

- (void)segmentTapped:(UIButton *)button
{
    NSString *path = objc_getAssociatedObject(button, "ff.crumb.path");
    if (!path.length || !self.navigationController) return;
    if ([path isEqualToString:[self.path stringByStandardizingPath]]) return;
    // 路径跳转复用正常导航模型：push 新浏览器，不重新实现文件系统读取。
    FFBrowserViewController *browser =
        [[FFBrowserViewController alloc] initWithPath:path];
    [self.navigationController pushViewController:browser animated:YES];
}

@end
