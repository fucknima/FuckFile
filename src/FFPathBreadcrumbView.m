#import "FFPathBreadcrumbView.h"

// helper：空名兜底显示
static NSString *FFBreadcrumbTitle(NSArray<NSString *> *names, NSUInteger i)
{
    NSString *name = names[i];
    return name.length ? name : @"…";
}

@implementation FFPathBreadcrumbView {
    UIScrollView *_scroll;
    UIStackView *_stack;
    BOOL _pendingScrollToEnd;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.alwaysBounceHorizontal = YES;
        [self addSubview:_scroll];

        _stack = [[UIStackView alloc] init];
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.spacing = 2;
        _stack.alignment = UIStackViewAlignmentCenter;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_scroll addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor
                                                 constant:12],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor
                                                  constant:-12],
            [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
            [_stack.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor],
        ]];
    }
    return self;
}

// 默认定位当前目录：布局完成后滚到最右端。
- (void)layoutSubviews
{
    [super layoutSubviews];
    if (_pendingScrollToEnd && _scroll.contentSize.width > 0) {
        CGFloat x = _scroll.contentSize.width - _scroll.bounds.size.width + 8;
        [_scroll setContentOffset:CGPointMake(MAX(x, 0), 0)];
        _pendingScrollToEnd = NO;
    }
}

- (void)setComponentNames:(NSArray<NSString *> *)names
             selectedIndex:(NSUInteger)index
                    target:(id)target
                    action:(SEL)action
{
    NSMutableArray<UIView *> *chips = [NSMutableArray array];
    UIFont *ancestorFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    // 当前目录加粗且随 Dynamic Type 缩放。
    UIFontDescriptor *boldDescriptor = [ancestorFont.fontDescriptor
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    UIFont *currentFont = boldDescriptor ?
        [UIFont fontWithDescriptor:boldDescriptor size:0] : ancestorFont;

    for (NSUInteger i = 0; i < names.count; i++) {
        if (chips.count > 0) {
            UIButton *chevron = [UIButton buttonWithType:UIButtonTypeSystem];
            chevron.userInteractionEnabled = NO;
            [chevron setImage:[UIImage systemImageNamed:@"chevron.compact.right"]
                     forState:UIControlStateNormal];
            [chips addObject:chevron];
        }

        BOOL current = (i == index);
        NSString *title = FFBreadcrumbTitle(names, i);
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = i;
        [button setTitle:title forState:UIControlStateNormal];
        // 当前目录加粗强调；上级目录次级色。
        button.titleLabel.font = current ? currentFont : ancestorFont;
        [button setTitleColor:current ? UIColor.labelColor : UIColor.secondaryLabelColor
                     forState:UIControlStateNormal];
        button.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        button.accessibilityLabel = title;
        button.accessibilityTraits = current ? UIAccessibilityTraitSelected
                                             : UIAccessibilityTraitButton;
        [chips addObject:button];
    }

    // 尾部箭头：指示"当前目录在此层级之下"（面包屑不含当前目录名，
    // 避免与导航标题重复）。
    if (names.count > 0) {
        UIButton *trailing = [UIButton buttonWithType:UIButtonTypeSystem];
        trailing.userInteractionEnabled = NO;
        [trailing setImage:[UIImage systemImageNamed:@"chevron.compact.right"]
                  forState:UIControlStateNormal];
        [trailing setTintColor:UIColor.tertiaryLabelColor];
        [chips addObject:trailing];
    }

    // 先拷贝再移除：枚举中修改 arrangedSubviews 会崩溃；
    // removeArrangedSubview 不脱离父视图，需手动 removeFromSuperview。
    NSArray<UIView *> *existing = [_stack.arrangedSubviews copy];
    for (UIView *view in existing) {
        [_stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (UIView *chip in chips)
        [_stack addArrangedSubview:chip];

    _pendingScrollToEnd = YES;
    [self setNeedsLayout];
}

@end
