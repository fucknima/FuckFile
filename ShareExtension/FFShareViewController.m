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
@property(nonatomic, copy) NSString *shareSessionID;
@end

@implementation FFShareViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.shareSessionID = NSUUID.UUID.UUIDString;

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
        @"session": self.shareSessionID ?: @"",
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
    NSLog(@"[FuckFileShare] stored name=%@ type=%@ item=%@ session=%@",
        metadata[@"name"], metadata[@"type"], final.lastPathComponent, self.shareSessionID);
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
        @"session": self.shareSessionID ?: @"",
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

    NSLog(@"[FuckFileShare] START items=%lu providers=%lu session=%@",
        (unsigned long)inputItems.count, (unsigned long)providers.count, self.shareSessionID);
    if (!providers.count) {
        [self finishWithImportedCount:0];
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];
    __block NSInteger imported = 0;
    for (NSItemProvider *provider in providers) {
        [self loadProvider:provider group:group completion:^(BOOL ok) {
            if (ok) @synchronized (lock) { imported++; }
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self finishWithImportedCount:imported];
    });
}

#pragma mark - Containing-app handoff

- (void)openWakeURL:(NSURL *)url
{
    if (!url) return;
    // Public, extension-safe path: ask the system to open the containing app.
    [self.extensionContext openURL:url completionHandler:^(BOOL success) {
        NSLog(@"[FuckFileShare] wake containing app=%d", success);
    }];
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

    if (self.bridgeUsesAppGroup) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"已接收 %ld 个文件，正在打开 FuckFile…", (long)count];
        NSURL *wakeURL = [NSURL URLWithString:
            [NSString stringWithFormat:@"%@://shared-inbox", FFShareWakeScheme]];
        [self openWakeURL:wakeURL];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.80 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ [self completeExtension]; });
        return;
    }

    NSString *token = NSUUID.UUID.UUIDString;
    NSURL *wakeURL = [NSURL URLWithString:[NSString stringWithFormat:
        @"%@://share-stream?token=%@&count=%ld", FFShareWakeScheme, token, (long)count]];
    self.statusLabel.text = @"正在将文件传给 FuckFile…";
    [self openWakeURL:wakeURL];

    NSString *inbox = self.bridgeInboxPath;
    NSString *session = self.shareSessionID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSUInteger sent = 0;
        NSError *error = nil;
        BOOL ok = FFLocalShareBridgeSendInbox(inbox, session, token, &sent, &error);
        NSLog(@"[FuckFileShare] loopback send ok=%d sent=%lu error=%@",
            ok, (unsigned long)sent, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = ok
                ? [NSString stringWithFormat:@"已导入 %lu 个文件", (unsigned long)sent]
                : @"直传失败，文件已暂存；请保持 FuckFile 在前台后重试";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)((ok ? 0.15 : 1.2) * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ [self completeExtension]; });
        });
    });
}

@end
