#import "FFRootTabBar.h"
#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFSettingsViewController.h"
#import "MCMManager.h"

#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSInteger const FFSelectionActionBarTag = 98421;

// Install a hook without exchanging an inherited Method object.
// method_exchangeImplementations(class_getInstanceMethod(subclass, inheritedSEL), ...)
// can mutate the superclass method table and leave the alias selector unresolved on the
// subclass. Copy the original IMP to a private alias on the concrete class first, then
// replace only the concrete class' implementation.
static BOOL FFInstallHook(Class cls, SEL original, SEL replacement, SEL originalAlias)
{
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (!originalMethod || !replacementMethod) return NO;

    IMP originalIMP = method_getImplementation(originalMethod);
    IMP replacementIMP = method_getImplementation(replacementMethod);
    const char *types = method_getTypeEncoding(originalMethod);
    if (!types) return NO;

    if (!class_addMethod(cls, originalAlias, originalIMP, types)) return NO;
    class_replaceMethod(cls, original, replacementIMP, types);
    return YES;
}

static void FFSendVoid(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (object && [object respondsToSelector:selector])
        ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

#pragma mark - Home root tab

@interface FFHomeViewController (FFRootNavigation)
- (void)ffnav_homeViewDidAppear:(BOOL)animated;
- (void)ffnav_originalHomeViewDidAppear:(BOOL)animated;
@end

@implementation FFHomeViewController (FFRootNavigation)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFInstallHook(self, @selector(viewDidAppear:),
            @selector(ffnav_homeViewDidAppear:),
            @selector(ffnav_originalHomeViewDidAppear:));
    });
}

- (void)ffnav_homeViewDidAppear:(BOOL)animated
{
    [self ffnav_originalHomeViewDidAppear:animated];

    // Remove the earlier full-width prototype tab bar if this branch created it.
    @try {
        UIView *legacy = [self valueForKey:@"bottomTabBar"];
        if (legacy && legacy.tag != FFRootTabBarViewTag) {
            [legacy removeFromSuperview];
            [self setValue:nil forKey:@"bottomTabBar"];
        }
    } @catch (__unused NSException *exception) {}

    UIEdgeInsets insets = self.additionalSafeAreaInsets;
    insets.bottom = 96;
    self.additionalSafeAreaInsets = insets;
    [FFRootTabBar installInViewController:self selected:FFRootTabHome];
}

@end

#pragma mark - Settings root tab

@interface FFSettingsViewController (FFRootNavigation)
- (void)ffnav_settingsViewDidAppear:(BOOL)animated;
- (void)ffnav_originalSettingsViewDidAppear:(BOOL)animated;
@end

@implementation FFSettingsViewController (FFRootNavigation)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFInstallHook(self, @selector(viewDidAppear:),
            @selector(ffnav_settingsViewDidAppear:),
            @selector(ffnav_originalSettingsViewDidAppear:));
    });
}

- (void)ffnav_settingsViewDidAppear:(BOOL)animated
{
    [self ffnav_originalSettingsViewDidAppear:animated];
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = nil;

    UIEdgeInsets insets = self.additionalSafeAreaInsets;
    insets.bottom = 96;
    self.additionalSafeAreaInsets = insets;
    [FFRootTabBar installInViewController:self selected:FFRootTabSettings];
}

@end

#pragma mark - Browser navigation cleanup

@interface FFBrowserViewController (FFNavigationPresentation)
- (void)ffnav_browserViewDidLayoutSubviews;
- (void)ffnav_originalBrowserViewDidLayoutSubviews;
- (UIMenu *)ffnav_moreMenu;
- (UIMenu *)ffnav_originalMoreMenu;
- (void)ffnav_removeLegacyActionBar;
- (void)ffnav_updateContextBars;
- (void)ffnav_installSelectionBar;
- (UIButton *)ffnav_selectionButton:(NSString *)title
                              symbol:(NSString *)symbol
                              action:(SEL)action
                                tint:(UIColor *)tint;
- (void)ffnav_batchCopy;
- (void)ffnav_batchMove;
- (void)ffnav_batchDelete;
- (void)ffnav_batchCompress;
- (void)ffnav_batchShare;
@end

@implementation FFBrowserViewController (FFNavigationPresentation)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFInstallHook(self, @selector(viewDidLayoutSubviews),
            @selector(ffnav_browserViewDidLayoutSubviews),
            @selector(ffnav_originalBrowserViewDidLayoutSubviews));
        FFInstallHook(self, NSSelectorFromString(@"moreMenu"),
            @selector(ffnav_moreMenu),
            @selector(ffnav_originalMoreMenu));
    });
}

- (void)ffnav_browserViewDidLayoutSubviews
{
    [self ffnav_originalBrowserViewDidLayoutSubviews];
    [self ffnav_removeLegacyActionBar];
    [self ffnav_updateContextBars];
}

- (void)ffnav_removeLegacyActionBar
{
    // FFBrowserPresentation's first UI pass created one permanent bottom view
    // with a direct UIStackView child. Remove only that obsolete view.
    for (UIView *candidate in [self.view.subviews copy]) {
        if (candidate.tag == FFRootTabBarViewTag || candidate.tag == FFSelectionActionBarTag)
            continue;

        BOOL containsDirectStack = NO;
        for (UIView *child in candidate.subviews) {
            if ([child isKindOfClass:UIStackView.class]) {
                containsDirectStack = YES;
                break;
            }
        }
        if (!containsDirectStack) continue;
        candidate.hidden = YES;
        [candidate removeFromSuperview];
    }
}

- (void)ffnav_updateContextBars
{
    BOOL isRoot = [self.currentPath isEqualToString:MCMVirtualRoot()];
    BOOL selecting = self.editing;

    if (isRoot && !selecting) {
        self.navigationItem.hidesBackButton = YES;
        self.navigationItem.leftBarButtonItem = nil;
        [FFRootTabBar installInViewController:self selected:FFRootTabFiles];
    } else {
        [FFRootTabBar removeFromViewController:self];
    }

    UIView *selectionBar = [self.view viewWithTag:FFSelectionActionBarTag];
    if (selecting) {
        if (!selectionBar) [self ffnav_installSelectionBar];
    } else {
        [selectionBar removeFromSuperview];
    }

    CGFloat desiredBottom = selecting ? 86.0 : (isRoot ? 96.0 : 0.0);
    UIEdgeInsets insets = self.additionalSafeAreaInsets;
    if (fabs(insets.top - 30.0) > 0.1 || fabs(insets.bottom - desiredBottom) > 0.1) {
        insets.top = 30.0;
        insets.bottom = desiredBottom;
        self.additionalSafeAreaInsets = insets;
    }
}

- (UIButton *)ffnav_selectionButton:(NSString *)title
                              symbol:(NSString *)symbol
                              action:(SEL)action
                                tint:(UIColor *)tint
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:symbol];
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.imagePadding = 3;
    config.baseForegroundColor = tint ?: UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 6);
    button.configuration = config;
    if (action)
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)ffnav_installSelectionBar
{
    UIView *bar = [UIView new];
    bar.tag = FFSelectionActionBarTag;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.layer.cornerRadius = 26;
    bar.layer.masksToBounds = YES;
    bar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    bar.layer.borderWidth = 0.5;
    bar.layer.borderColor = UIColor.separatorColor.CGColor;
    [self.view addSubview:bar];

    UIAction *compress = [UIAction actionWithTitle:@"压缩"
        image:[UIImage systemImageNamed:@"archivebox"] identifier:nil
        handler:^(__unused UIAction *action) { [self ffnav_batchCompress]; }];
    UIAction *share = [UIAction actionWithTitle:@"分享"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
        handler:^(__unused UIAction *action) { [self ffnav_batchShare]; }];
    UIMenu *moreMenu = [UIMenu menuWithTitle:@"更多" children:@[compress, share]];

    UIButton *more = [self ffnav_selectionButton:@"更多" symbol:@"ellipsis"
        action:nil tint:nil];
    more.menu = moreMenu;
    more.showsMenuAsPrimaryAction = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self ffnav_selectionButton:@"复制" symbol:@"doc.on.doc"
            action:@selector(ffnav_batchCopy) tint:nil],
        [self ffnav_selectionButton:@"移动" symbol:@"folder"
            action:@selector(ffnav_batchMove) tint:nil],
        [self ffnav_selectionButton:@"删除" symbol:@"trash"
            action:@selector(ffnav_batchDelete) tint:UIColor.systemRedColor],
        more,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    [bar addSubview:stack];

    NSLayoutConstraint *preferredWidth = [bar.widthAnchor constraintEqualToConstant:330];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [bar.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [bar.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-24],
        preferredWidth,
        [bar.heightAnchor constraintEqualToConstant:58],
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor constant:3],
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:6],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-6],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-3],
    ]];
}

- (void)ffnav_batchCopy { FFSendVoid(self, @"batchCopy"); }
- (void)ffnav_batchMove { FFSendVoid(self, @"batchCut"); }
- (void)ffnav_batchDelete { FFSendVoid(self, @"batchDelete"); }
- (void)ffnav_batchCompress { FFSendVoid(self, @"batchCompress"); }
- (void)ffnav_batchShare { FFSendVoid(self, @"batchShare"); }

- (UIMenu *)ffnav_moreMenu
{
    UIMenu *base = [self ffnav_originalMoreMenu];
    if (!base) base = [UIMenu menuWithTitle:@"更多" children:@[]];

    UIAction *newFolder = [UIAction actionWithTitle:@"新建文件夹"
        image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
        handler:^(__unused UIAction *action) { FFSendVoid(self, @"createFolder"); }];
    UIAction *newFile = [UIAction actionWithTitle:@"新建文件"
        image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil
        handler:^(__unused UIAction *action) { FFSendVoid(self, @"createFile"); }];
    UIMenu *create = [UIMenu menuWithTitle:@"新建" image:nil identifier:nil
        options:UIMenuOptionsDisplayInline children:@[newFolder, newFile]];

    BOOL grid = [NSUserDefaults.standardUserDefaults boolForKey:@"FFSettingsGridMode"];
    UIAction *list = [UIAction actionWithTitle:@"列表"
        image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil
        handler:^(__unused UIAction *action) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FFSettingsGridMode"];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"FFSettingsChangedNotification" object:nil];
        }];
    list.state = grid ? UIMenuElementStateOff : UIMenuElementStateOn;

    UIAction *gridAction = [UIAction actionWithTitle:@"网格"
        image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil
        handler:^(__unused UIAction *action) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FFSettingsGridMode"];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"FFSettingsChangedNotification" object:nil];
        }];
    gridAction.state = grid ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIMenu *view = [UIMenu menuWithTitle:@"视图" image:nil identifier:nil
        options:UIMenuOptionsDisplayInline children:@[list, gridAction]];

    UIAction *refresh = [UIAction actionWithTitle:@"刷新"
        image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil
        handler:^(__unused UIAction *action) { [self reloadEntries]; }];

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    [children addObject:create];
    [children addObjectsFromArray:base.children ?: @[]];
    [children addObject:view];
    [children addObject:refresh];
    return [UIMenu menuWithTitle:base.title ?: @"更多" children:children];
}

@end
