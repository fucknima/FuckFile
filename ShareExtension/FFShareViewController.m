#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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
        [self.extensionContext openURL:wakeURL completionHandler:^(BOOL success) {
            NSLog(@"[FuckFileShare] wake main app success=%d", success);
            dispatch_async(dispatch_get_main_queue(), completeOnce);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), completeOnce);
    } else {
        completeOnce();
    }
}

@end
