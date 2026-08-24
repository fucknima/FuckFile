#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "FFShareBridge.h"
#import "FFLocalShareBridge.h"

@interface FFShareViewController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL bridgeUsesAppGroup;
@property(nonatomic, copy) NSString *bridgeInboxPath;
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
    NSURL *groupURL = [manager
        containerURLForSecurityApplicationGroupIdentifier:FFShareAppGroupIdentifier];
    NSURL *root = groupURL;
    NSString *mode = @"app-group";
    self.bridgeUsesAppGroup = groupURL != nil;

    // A Share Extension is a separate executable and a separate sandbox even
    // though it is nested inside the same installed app. Under the MHA spoofed
    // host identity, a re-signed build frequently has no provisioned App Group
    // container. Keep staging in the extension container, then transfer the
    // bytes to the foreground host over a one-shot loopback bridge. This path
    // uses no MCM/exploit capability and therefore also works in normal mode.
    if (!root) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        root = [NSURL fileURLWithPath:documents isDirectory:YES];
        mode = @"extension-data+loopback";
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
    self.bridgeInboxPath = inbox.path;
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
        if (!type) continue;
        if ([type conformsToType:UTTypeURL]) {
            NSLog(@"[FuckFileShare] skip URL representation type=%@", identifier);
            continue;
        }
        if ([type conformsToType:UTTypeData] || [type conformsToType:UTTypeContent])
            return identifier;
    }
    return nil;
}

- (void)loadProvider:(NSItemProvider *)provider
               group:(dispatch_group_t)group
          completion:(void (^)(BOOL ok))completion
{
    dispatch_group_enter(group);
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
        NSLog(@"[FuckFileShare] loadItem file-url name=%@",
            suggestedName ?: @"(actual URL basename)");
        [provider loadItemForTypeIdentifier:fileURLType options:nil
            completionHandler:^(id item, NSError *loadError) {
                NSURL *url = [item isKindOfClass:NSURL.class] ? item : nil;
                NSString *actualName = url.lastPathComponent.length
                    ? url.lastPathComponent : suggestedName;
                NSError *storeError = nil;
                BOOL ok = url && url.isFileURL && !loadError && [self storeSourceURL:url
                    name:actualName typeIdentifier:fileURLType error:&storeError];
                if (!ok)
                    NSLog(@"[FuckFileShare] file-url FAIL load=%@ store=%@ item=%@",
                        loadError, storeError, item);
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
                NSURL *url = item;
                NSString *actualName = url.lastPathComponent.length
                    ? url.lastPathComponent : suggestedName;
                ok = url.isFileURL && [self storeSourceURL:url name:actualName
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
            if (ok) @synchronized (lock) { imported++; }
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
    if (!workspace) return NO;

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
        BOOL opened = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(workspace, simpleSelector, url);
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

    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:applicationClass] &&
            [responder respondsToSelector:openSelector]) {
            void (^completion)(BOOL) = ^(BOOL success) {
                NSLog(@"[FuckFileShare] wake UIApplication responder result=%d", success);
            };
            ((void (*)(id, SEL, NSURL *, NSDictionary *, id))objc_msgSend)(
                responder, openSelector, url, @{}, completion);
            return YES;
        }
        responder = responder.nextResponder;
    }

    SEL sharedSelector = NSSelectorFromString(@"sharedApplication");
    if ([applicationClass respondsToSelector:sharedSelector]) {
        id application = ((id (*)(id, SEL))objc_msgSend)(applicationClass, sharedSelector);
        if (application && [application respondsToSelector:openSelector]) {
            void (^completion)(BOOL) = ^(BOOL success) {
                NSLog(@"[FuckFileShare] wake UIApplication shared result=%d", success);
            };
            ((void (*)(id, SEL, NSURL *, NSDictionary *, id))objc_msgSend)(
                application, openSelector, url, @{}, completion);
            return YES;
        }
    }
    return NO;
}

- (void)completeExtension
{
    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
}

- (void)finishWithImportedCount:(NSInteger)count
{
    [self.spinner stopAnimating];
    if (count <= 0) {
        self.statusLabel.text = @"没有收到可导入的文件";
        [self completeExtension];
        return;
    }

    // Standard App Group transport remains the first choice when the final
    // signer actually provisioned it.
    if (self.bridgeUsesAppGroup) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"已接收 %ld 个文件，正在打开 FuckFile…", (long)count];
        NSURL *wakeURL = [NSURL URLWithString:
            [NSString stringWithFormat:@"%@://shared-inbox", FFShareWakeScheme]];
        BOOL requested = wakeURL && [self openWakeURLViaLaunchServices:wakeURL];
        if (!requested && wakeURL) requested = [self openWakeURLViaUIApplication:wakeURL];
        if (!requested && wakeURL) {
            [self.extensionContext openURL:wakeURL completionHandler:^(BOOL success) {
                NSLog(@"[FuckFileShare] app-group wake fallback=%d", success);
            }];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)((requested ? 0.20 : 0.80) * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ [self completeExtension]; });
        return;
    }

    // No App Group: wake the host with a one-time token and stream the staged
    // files over 127.0.0.1. This is ordinary sandboxed IPC; it does not touch
    // MobileContainerManager and works with advanced system access disabled.
    NSString *token = NSUUID.UUID.UUIDString;
    NSString *urlString = [NSString stringWithFormat:
        @"%@://share-stream?token=%@&count=%ld", FFShareWakeScheme, token, (long)count];
    NSURL *wakeURL = [NSURL URLWithString:urlString];
    self.statusLabel.text = @"正在将文件传给 FuckFile…";
    BOOL requested = wakeURL && [self openWakeURLViaLaunchServices:wakeURL];
    if (!requested && wakeURL) requested = [self openWakeURLViaUIApplication:wakeURL];
    if (!requested && wakeURL) {
        [self.extensionContext openURL:wakeURL completionHandler:^(BOOL success) {
            NSLog(@"[FuckFileShare] loopback wake fallback=%d", success);
        }];
    }

    NSString *inbox = self.bridgeInboxPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSUInteger sent = 0;
        NSError *error = nil;
        BOOL ok = FFLocalShareBridgeSendInbox(inbox, token, &sent, &error);
        NSLog(@"[FuckFileShare] loopback send ok=%d sent=%lu error=%@",
            ok, (unsigned long)sent, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = ok
                ? [NSString stringWithFormat:@"已导入 %lu 个文件", (unsigned long)sent]
                : @"直传失败，文件已暂存；可稍后重试或启用高级访问恢复";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)((ok ? 0.15 : 1.2) * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ [self completeExtension]; });
        });
    });
}

@end
