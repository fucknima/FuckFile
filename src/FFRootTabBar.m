#import "FFRootTabBar.h"

#import "FFBrowserViewController.h"
#import "FFSettingsViewController.h"
#import "MCMManager.h"

NSInteger const FFRootTabBarViewTag = 98420;

@interface FFRootTabBar ()
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic) FFRootTab selectedTab;
@property(nonatomic, strong) UIVisualEffectView *materialView;
@property(nonatomic, strong) UIStackView *stackView;
@end

@implementation FFRootTabBar

+ (instancetype)installInViewController:(UIViewController *)viewController
                               selected:(FFRootTab)selected
{
    UIView *existing = [viewController.view viewWithTag:FFRootTabBarViewTag];
    if ([existing isKindOfClass:FFRootTabBar.class]) {
        FFRootTabBar *bar = (FFRootTabBar *)existing;
        if (bar.selectedTab != selected) {
            [bar removeFromSuperview];
        } else {
            return bar;
        }
    }

    FFRootTabBar *bar = [[FFRootTabBar alloc] initWithOwner:viewController selected:selected];
    [viewController.view addSubview:bar];
    NSLayoutConstraint *preferredWidth = [bar.widthAnchor constraintEqualToConstant:300];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [bar.centerXAnchor constraintEqualToAnchor:viewController.view.centerXAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:viewController.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [bar.widthAnchor constraintLessThanOrEqualToAnchor:viewController.view.widthAnchor constant:-32],
        preferredWidth,
        [bar.heightAnchor constraintEqualToConstant:70],
    ]];
    return bar;
}

+ (void)removeFromViewController:(UIViewController *)viewController
{
    [[viewController.view viewWithTag:FFRootTabBarViewTag] removeFromSuperview];
}

- (instancetype)initWithOwner:(UIViewController *)owner selected:(FFRootTab)selected
{
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.owner = owner;
    self.selectedTab = selected;
    self.tag = FFRootTabBarViewTag;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = 31;
    self.layer.masksToBounds = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 18;
    self.layer.shadowOffset = CGSizeMake(0, 8);

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *material = [[UIVisualEffectView alloc] initWithEffect:blur];
    material.translatesAutoresizingMaskIntoConstraints = NO;
    material.userInteractionEnabled = NO;
    material.layer.cornerRadius = 31;
    material.layer.masksToBounds = YES;
    material.layer.borderWidth = 0.5;
    material.layer.borderColor = [UIColor separatorColor].CGColor;
    [self addSubview:material];
    self.materialView = material;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self buttonForTab:FFRootTabHome title:@"主页" symbol:@"house.fill"],
        [self buttonForTab:FFRootTabFiles title:@"文件" symbol:@"folder.fill"],
        [self buttonForTab:FFRootTabSettings title:@"设置" symbol:@"gearshape.fill"],
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 6;
    [self addSubview:stack];
    self.stackView = stack;

    [NSLayoutConstraint activateConstraints:@[
        [material.topAnchor constraintEqualToAnchor:self.topAnchor],
        [material.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [material.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [material.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:7],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-7],
    ]];
    return self;
}

- (UIColor *)selectedBackgroundColor
{
    return [UIColor colorWithDynamicProvider:^UIColor *(__unused UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.03 alpha:0.92]
            : [UIColor colorWithWhite:1.0 alpha:0.88];
    }];
}

- (UIButton *)buttonForTab:(FFRootTab)tab title:(NSString *)title symbol:(NSString *)symbol
{
    BOOL selected = self.selectedTab == tab;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = 1000 + tab;

    UIButtonConfiguration *configuration = selected
        ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration plainButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePlacement = NSDirectionalRectEdgeTop;
    configuration.imagePadding = 3;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(7, 10, 7, 10);
    configuration.baseForegroundColor = selected ? UIColor.systemBlueColor
                                                 : UIColor.labelColor;
    if (selected)
        configuration.baseBackgroundColor = [self selectedBackgroundColor];
    button.configuration = configuration;
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)tabTapped:(UIButton *)sender
{
    FFRootTab tab = (FFRootTab)(sender.tag - 1000);
    if (tab == self.selectedTab) return;

    UINavigationController *nav = self.owner.navigationController;
    if (!nav || nav.viewControllers.count == 0) return;
    UIViewController *root = nav.viewControllers.firstObject;

    switch (tab) {
        case FFRootTabHome:
            [nav popToRootViewControllerAnimated:NO];
            break;
        case FFRootTabFiles: {
            FFBrowserViewController *browser = [[FFBrowserViewController alloc]
                initWithPath:MCMVirtualRoot()];
            browser.title = @"Device Storage";
            [nav setViewControllers:@[root, browser] animated:NO];
            break;
        }
        case FFRootTabSettings: {
            FFSettingsViewController *settings = [FFSettingsViewController new];
            settings.navigationItem.hidesBackButton = YES;
            [nav setViewControllers:@[root, settings] animated:NO];
            break;
        }
    }
}

@end
