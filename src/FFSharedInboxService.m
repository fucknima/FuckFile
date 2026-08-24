#import "FFSharedInboxService.h"
#import "FFShareBridge.h"
#import "FFImportService.h"
#import "FFLogger.h"
#import "FFSystemAccessManager.h"
#import "MCMManager+ExtensionData.h"

NSNotificationName const FFSharedInboxDidImportNotification =
    @"FFSharedInboxDidImportNotification";

@implementation FFSharedInboxService

+ (dispatch_queue_t)queue
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("ff.shared-inbox", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (NSArray<NSString *> *)candidateInboxRoots
{
    NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];

    NSURL *groupURL = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:FFShareAppGroupIdentifier];
    if (groupURL.path.length) {
        NSString *groupInbox = [groupURL.path stringByAppendingPathComponent:
            FFShareInboxDirectoryName];
        [roots addObject:groupInbox];
        FFLogTag(@"ShareInbox", @"bridge app-group=%@", groupInbox);
    } else {
        FFLogTag(@"ShareInbox", @"app-group unavailable");
    }

    // The class-4 MCM fallback is part of advanced system access. Normal mode
    // must not touch MCM at all; App Group sharing continues to work normally.
    if (FFSystemAccessManager.sharedManager.enabled &&
        FFSystemAccessManager.sharedManager.loadedThisSession) {
        NSString *mcmError = nil;
        NSString *extensionRoot = [[MCMManager sharedManager]
            extensionContainerPathForIdentifier:FFShareExtensionBundleIdentifier
            error:&mcmError];
        if (extensionRoot.length) {
            NSString *extensionInbox = [[extensionRoot stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:FFShareInboxDirectoryName];
            [roots addObject:extensionInbox];
            FFLogTag(@"ShareInbox", @"bridge extension-data=%@", extensionInbox);
        } else {
            FFLogTag(@"ShareInbox", @"class-4 bridge unavailable detail=%@",
                mcmError ?: @"(nil)");
        }
    } else {
        FFLogTag(@"ShareInbox", @"class-4 bridge skipped (advanced access disabled/not loaded)");
    }

    return roots.array;
}

+ (void)processPendingWithCompletion:(void (^)(NSUInteger,
    NSArray<NSString *> *, NSArray<NSError *> *))completion
{
    dispatch_async([self queue], ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *destinationDirectory = [[documents stringByAppendingPathComponent:
            @"Device Storage"] stringByAppendingPathComponent:@"Imported"];
        NSError *mkdirError = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:destinationDirectory
            withIntermediateDirectories:YES attributes:nil error:&mkdirError];

        NSMutableArray<NSString *> *destinations = [NSMutableArray array];
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        if (mkdirError) [errors addObject:mkdirError];

        for (NSString *root in [self candidateInboxRoots]) {
            NSArray<NSString *> *names = [NSFileManager.defaultManager
                contentsOfDirectoryAtPath:root error:nil];
            for (NSString *name in names ?: @[]) {
                if (![name hasSuffix:FFShareItemSuffix]) continue;
                NSString *itemDirectory = [root stringByAppendingPathComponent:name];
                NSString *payloadPath = [itemDirectory stringByAppendingPathComponent:@"payload"];
                NSString *metadataPath = [itemDirectory stringByAppendingPathComponent:@"metadata.plist"];
                NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                NSString *originalName = [metadata[@"name"] isKindOfClass:NSString.class]
                    ? metadata[@"name"] : @"imported";

                BOOL isDirectory = NO;
                if (![NSFileManager.defaultManager fileExistsAtPath:payloadPath
                    isDirectory:&isDirectory]) {
                    NSError *error = [NSError errorWithDomain:@"FFSharedInboxErrorDomain"
                        code:1 userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"共享收件箱缺少 payload：%@", name]}];
                    [errors addObject:error];
                    FFLogTag(@"ShareInbox", @"invalid item=%@", itemDirectory);
                    continue;
                }

                FFLogTag(@"ShareInbox", @"consume item=%@ name=%@", name, originalName);
                FFImportResult *result = [FFImportService
                    importURL:[NSURL fileURLWithPath:payloadPath]
                    displayName:originalName
                    toDirectory:destinationDirectory];
                if (result.success) {
                    if (result.destinationPath) [destinations addObject:result.destinationPath];
                    NSError *removeError = nil;
                    if (![NSFileManager.defaultManager removeItemAtPath:itemDirectory
                        error:&removeError] && removeError) {
                        [errors addObject:removeError];
                        FFLogTag(@"ShareInbox", @"cleanup FAIL item=%@ error=%@",
                            itemDirectory, removeError);
                    } else {
                        FFLogTag(@"ShareInbox", @"cleanup OK item=%@", itemDirectory);
                    }
                } else if (result.error) {
                    [errors addObject:result.error];
                    FFLogTag(@"ShareInbox", @"import FAIL item=%@ error=%@",
                        itemDirectory, result.error);
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (destinations.count) {
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:FFSharedInboxDidImportNotification
                    object:nil userInfo:@{@"Destinations": destinations.copy}];
            }
            if (completion) completion(destinations.count, destinations.copy, errors.copy);
        });
    });
}

@end
