#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "FFShareBridge.h"

@interface FFShareViewController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) BOOL started;
@end

@implementation FFShareViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"正在导入到 FuckFile…";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    // 轻量视觉统一（ADR-013）：Dynamic Type + 次级色；导入逻辑不变。
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.isAccessibilityElement = YES;
    self.statusLabel.accessibilityLabel = @"正在导入到 FuckFile";
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:14],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.started) return;
    self.started = YES;
    [self processInputItems];
}

- (NSURL *)bridgeInboxURL
{
    NSFileManager *manager = NSFileManager.defaultManager;

    // LCSign-compatible path when the final signer grants the App Group.
    NSURL *groupURL = [manager
        containerURLForSecurityApplicationGroupIdentifier:FFShareAppGroupIdentifier];
    NSURL *root = groupURL;
    NSString *mode = @"app-group";

    // Critical fallback for re-signers that strip/deny App Group entitlements:
    // persist in the extension's own data container. The main FuckFile process
    // (MobileHouseArrest identity) retrieves this class-4 Extension Data
    // container through MCM, so the bridge does not depend on provisioning.
    if (!root) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        root = [NSURL fileURLWithPath:documents isDirectory:YES];
        mode = @"extension-data";
    }

    NSURL *inbox = [root URLByAppendingPathComponent:FFShareInboxDirectoryName
                                         isDirectory:YES];
    NSError *error = nil;
    if (![manager createDirectoryAtURL:inbox withIntermediateDirectories:YES
        attributes:nil error:&error]) {
        NSLog(@"[FuckFileShare] bridge mkdir FAIL mode=%@ path=%@ error=%@",
            mode, inbox.path, error);
        return nil;
    }
    NSLog(@"[FuckFileShare] bridge mode=%@ path=%@", mode, inbox.path);
    return inbox;
}

static NSString *FFShareSafeName(NSString *name)
{
    NSString *last = name.lastPathComponent;
    return last.length ? last : @"imported";
}

- (BOOL)storeSourceURL:(NSURL *)sourceURL
                  name:(NSString *)name
        typeIdentifier:(NSString *)typeIdentifier
                 error:(NSError **)error
{
    NSURL *inbox = [self bridgeInboxURL];
    if (!inbox) {
        if (error) *error = [NSError errorWithDomain:@"FFShareErrorDomain" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"无法创建共享收件箱"}];
        return NO;
    }

    NSString *uuid = NSUUID.UUID.UUIDString;
    NSURL *partial = [inbox URLByAppendingPathComponent:
        [@".partial-" stringByAppendingString:uuid] isDirectory:YES];
    NSURL *final = [inbox URLByAppendingPathComponent:
        [uuid stringByAppendingString:FFShareItemSuffix] isDirectory:YES];
    NSURL *payload = [partial URLByAppendingPathComponent:@"payload"];
    NSURL *metadataURL = [partial URLByAppendingPathComponent:@"metadata.plist"];

    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtURL:partial withIntermediateDirectories:YES
        attributes:nil error:error]) return NO;

    BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
    BOOL copied = [manager copyItemAtURL:sourceURL toURL:payload error:error];
    if (scoped) [sourceURL stopAccessingSecurityScopedResource];
    if (!copied) {
        [manager removeItemAtURL:partial error:nil];
        return NO;
    }

    NSNumber *size = nil;
    [payload getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    NSDictionary *metadata = @{
        @"name": FFShareSafeName(name.length ? name : sourceURL.lastPathComponent),
        @"type": typeIdentifier ?: @"public.data",
        @"created": NSDate.date,
        @"size": size ?: @0,
    };
    if (![metadata writeToURL:metadataURL atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"FFShareErrorDomain" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"写入共享元数据失败"}];
        [manager removeItemAtURL:partial error:nil];
        return NO;
    }

    if (![manager moveItemAtURL:partial toURL:final error:error]) {
        [manager removeItemAtURL:partial error:nil];
        return NO;
    }
    NSLog(@"[FuckFileShare] stored name=%@ type=%@ item=%@",
        metadata[@"name"], metadata[@"type"], final.lastPathComponent);
    return YES;
}

- (BOOL)storeData:(NSData *)data
             name:(NSString *)name
   typeIdentifier:(NSString *)typeIdentifier
            error:(NSError **)error
{
    NSURL *inbox = [self bridgeInboxURL];
    if (!inbox) return NO;

    NSString *uuid = NSUUID.UUID.UUIDString;
    NSURL *partial = [inbox URLByAppendingPathComponent:
        [@".partial-" stringByAppendingString:uuid] isDirectory:YES];
    NSURL *final = [inbox URLByAppendingPathComponent:
        [uuid stringByAppendingString:FFShareItemSuffix] isDirectory:YES];
    NSURL *payload = [partial URLByAppendingPathComponent:@"payload"];
    NSURL *metadataURL = [partial URLByAppendingPathComponent:@"metadata.plist"];

    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtURL:partial withIntermediateDirectories:YES
        attributes:nil error:error]) return NO;
    if (![data writeToURL:payload options:NSDataWritingAtomic error:error]) {
        [manager removeItemAtURL:partial error:nil];
        return NO;
    }
    NSDictionary *metadata = @{
        @"name": FFShareSafeName(name.length ? name : @"imported"),
        @"type": typeIdentifier ?: @"public.data",
        @"created": NSDate.date,
        @"size": @(data.length),
    };
    if (![metadata writeToURL:metadataURL atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"FFShareErrorDomain" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"写入共享元数据失败"}];
        [manager removeItemAtURL:partial error:nil];
        return NO;
    }
    if (![manager moveItemAtURL:partial toURL:final error:error]) {
        [manager removeItemAtURL:partial error:nil];
        return NO;
    }
    return YES;
}

- (NSString *)fileRepresentationTypeForProvider:(NSItemProvider *)provider
{
    for (NSString *identifier in provider.registeredTypeIdentifiers) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if ([type conformsToType:UTTypeData] ||
            [type conformsToType:UTTypeContent])
            return identifier;
    }
    return nil;
}

- (void)loadProvider:(NSItemProvider *)provider
               group:(dispatch_group_t)group
          completion:(void (^)(BOOL ok))completion
{
    dispatch_group_enter(group);
    // Keep nil here. For file representations the provider URL's own basename
    // is a better fallback than replacing an unknown original name with
    // "imported" and losing .pdf/.ipa/.zip.
    NSString *suggestedName = provider.suggestedName;
    NSString *representationType = [self fileRepresentationTypeForProvider:provider];

    void (^record)(BOOL) = ^(BOOL ok) {
        if (completion) completion(ok);
        dispatch_group_leave(group);
    };

    if (representationType.length) {
        NSLog(@"[FuckFileShare] loadFileRepresentation type=%@ name=%@",
            representationType, suggestedName ?: @"(provider URL fallback)");
        [provider loadFileRepresentationForTypeIdentifier:representationType
            completionHandler:^(NSURL *url, NSError *loadError) {
                NSError *storeError = nil;
                BOOL ok = url && !loadError && [self storeSourceURL:url
                    name:suggestedName typeIdentifier:representationType error:&storeError];
                if (!ok)
                    NSLog(@"[FuckFileShare] representation FAIL load=%@ store=%@",
                        loadError, storeError);
                record(ok);
            }];
        return;
    }

    NSString *fileURLType = UTTypeFileURL.identifier;
    if ([provider hasItemConformingToTypeIdentifier:fileURLType]) {
        [provider loadItemForTypeIdentifier:fileURLType options:nil
            completionHandler:^(id item, NSError *loadError) {
                NSURL *url = [item isKindOfClass:NSURL.class] ? item : nil;
                NSError *storeError = nil;
                BOOL ok = url && !loadError && [self storeSourceURL:url
                    name:suggestedName typeIdentifier:fileURLType error:&storeError];
                if (!ok)
                    NSLog(@"[FuckFileShare] file-url FAIL load=%@ store=%@",
                        loadError, storeError);
                record(ok);
            }];
        return;
    }

    NSString *fallbackType = provider.registeredTypeIdentifiers.firstObject;
    if (!fallbackType.length) {
        NSLog(@"[FuckFileShare] provider has no registered types");
        record(NO);
        return;
    }
    [provider loadItemForTypeIdentifier:fallbackType options:nil
        completionHandler:^(id item, NSError *loadError) {
            NSError *storeError = nil;
            BOOL ok = NO;
            if ([item isKindOfClass:NSURL.class]) {
                ok = [self storeSourceURL:item name:suggestedName
                    typeIdentifier:fallbackType error:&storeError];
            } else if ([item isKindOfClass:NSData.class]) {
                ok = [self storeData:item name:suggestedName
                    typeIdentifier:fallbackType error:&storeError];
            }
            if (!ok)
                NSLog(@"[FuckFileShare] loadItem FAIL type=%@ load=%@ store=%@ class=%@",
                    fallbackType, loadError, storeError, [item class]);
            record(ok);
        }];
}

- (void)processInputItems
{
    NSArray *inputItems = self.extensionContext.inputItems ?: @[];
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (id object in inputItems) {
        if (![object isKindOfClass:NSExtensionItem.class]) continue;
        NSExtensionItem *item = object;
        for (NSItemProvider *provider in item.attachments ?: @[]) {
            if ([provider isKindOfClass:NSItemProvider.class]) [providers addObject:provider];
        }
    }

    NSLog(@"[FuckFileShare] START items=%lu providers=%lu",
        (unsigned long)inputItems.count, (unsigned long)providers.count);
    if (!providers.count) {
        [self finishWithImportedCount:0];
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];
    __block NSInteger imported = 0;
    for (NSItemProvider *provider in providers) {
        NSLog(@"[FuckFileShare] provider types=%@", provider.registeredTypeIdentifiers);
        [self loadProvider:provider group:group completion:^(BOOL ok) {
            if (ok) {
                @synchronized (lock) { imported++; }
            }
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self finishWithImportedCount:imported];
    });
}

#pragma mark - Containing-app handoff

static void FFEnsureLaunchServicesLoaded(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // LSApplicationWorkspace is private SPI. FuckFile already depends on
        // private LaunchServices/MCM behavior and is not an App Store target.
        // Loading by path keeps the extension build independent of private
        // headers and lets this gracefully fall back when the class moves.
        void *handle = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            handle = dlopen(
                "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
                RTLD_LAZY | RTLD_LOCAL);
        }
        NSLog(@"[FuckFileShare] LaunchServices dlopen=%s", handle ? "OK" : "FAIL");
    });
}

- (BOOL)openWakeURLViaLaunchServices:(NSURL *)url
{
    FFEnsureLaunchServicesLoaded();
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) {
        NSLog(@"[FuckFileShare] wake LS unavailable class=%@", workspaceClass);
        return NO;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
    if (!workspace) {
        NSLog(@"[FuckFileShare] wake LS defaultWorkspace=nil");
        return NO;
    }

    NSError *error = nil;
    SEL openSelector = NSSelectorFromString(@"openURL:withOptions:error:");
    if ([workspace respondsToSelector:openSelector]) {
        BOOL opened = ((BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend)(
            workspace, openSelector, url, @{}, &error);
        NSLog(@"[FuckFileShare] wake LS openURL result=%d error=%@", opened,
            error.localizedDescription ?: @"(nil)");
        if (opened) return YES;
    }

    error = nil;
    SEL sensitiveSelector = NSSelectorFromString(@"openSensitiveURL:withOptions:error:");
    if ([workspace respondsToSelector:sensitiveSelector]) {
        BOOL opened = ((BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend)(
            workspace, sensitiveSelector, url, @{}, &error);
        NSLog(@"[FuckFileShare] wake LS sensitive result=%d error=%@", opened,
            error.localizedDescription ?: @"(nil)");
        if (opened) return YES;
    }

    SEL simpleSelector = NSSelectorFromString(@"openURL:");
    if ([workspace respondsToSelector:simpleSelector]) {
        BOOL opened = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(
            workspace, simpleSelector, url);
        NSLog(@"[FuckFileShare] wake LS simple result=%d", opened);
        if (opened) return YES;
    }
    return NO;
}

- (BOOL)openWakeURLViaUIApplication:(NSURL *)url
{
    Class applicationClass = NSClassFromString(@"UIApplication");
    SEL openSelector = NSSelectorFromString(@"openURL:options:completionHandler:");
    if (!applicationClass || !openSelector) return NO;

    // Share extensions are not allowed to reference UIApplication.shared at
    // compile time, but the hosting UIKit process has a UIApplication object
    // in its responder chain. The iOS 18+ openURL:options: API is required;
    // the legacy openURL: path is force-rejected by modern UIKit.
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:applicationClass] &&
            [responder respondsToSelector:openSelector]) {
            void (^completion)(BOOL) = ^(BOOL success) {
                NSLog(@"[FuckFileShare] wake UIApplication responder result=%d", success);
            };
            ((void (*)(id, SEL, NSURL *, NSDictionary *, id))objc_msgSend)(
                responder, openSelector, url, @{}, completion);
            NSLog(@"[FuckFileShare] wake UIApplication responder requested");
            return YES;
        }
        responder = responder.nextResponder;
    }

    // Some iOS builds no longer place UIApplication directly in the responder
    // chain. Use the same runtime-only call as a second compatibility route.
    SEL sharedSelector = NSSelectorFromString(@"sharedApplication");
    if ([applicationClass respondsToSelector:sharedSelector]) {
        id application = ((id (*)(id, SEL))objc_msgSend)(applicationClass, sharedSelector);
        if (application && [application respondsToSelector:openSelector]) {
            void (^completion)(BOOL) = ^(BOOL success) {
                NSLog(@"[FuckFileShare] wake UIApplication shared result=%d", success);
            };
            ((void (*)(id, SEL, NSURL *, NSDictionary *, id))objc_msgSend)(
                application, openSelector, url, @{}, completion);
            NSLog(@"[FuckFileShare] wake UIApplication shared requested");
            return YES;
        }
    }
    NSLog(@"[FuckFileShare] wake UIApplication route unavailable");
    return NO;
}

- (void)finishWithImportedCount:(NSInteger)count
{
    [self.spinner stopAnimating];
    self.statusLabel.text = count > 0
        ? [NSString stringWithFormat:@"已接收 %ld 个文件，正在打开 FuckFile…", (long)count]
        : @"没有收到可导入的文件";

    NSURL *wakeURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"%@://shared-inbox", FFShareWakeScheme]];
    NSLog(@"[FuckFileShare] COMPLETE imported=%ld wake=%@", (long)count, wakeURL);

    __block BOOL completed = NO;
    void (^completeOnce)(void) = ^{
        if (completed) return;
        completed = YES;
        [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
    };

    if (count > 0 && wakeURL) {
        // NSExtensionContext.openURL is not supported by the iOS Share
        // extension point, which is why the previous build merely dismissed
        // this sheet. Use LaunchServices first; responder-chain UIApplication
        // is the compatibility fallback for builds where LS SPI is filtered.
        BOOL requested = [self openWakeURLViaLaunchServices:wakeURL];
        if (!requested) requested = [self openWakeURLViaUIApplication:wakeURL];

        if (!requested) {
            // Keep the official API as a last diagnostic fallback. Apple only
            // documents it as supported for Today/iMessage extension points,
            // so failure here is expected for share-services.
            [self.extensionContext openURL:wakeURL completionHandler:^(BOOL success) {
                NSLog(@"[FuckFileShare] wake extensionContext fallback result=%d", success);
            }];
            self.statusLabel.text = @"已导入，请打开 FuckFile 查看";
        }

        // Give the foreground request a short head start, then finish the
        // extension request exactly once. A full one-second timeout is only
        // needed when every direct foreground route was unavailable.
        NSTimeInterval delay = requested ? 0.20 : 1.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), completeOnce);
    } else {
        completeOnce();
    }
}

@end
