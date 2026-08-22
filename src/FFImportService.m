#import "FFImportService.h"
#import "FFLogger.h"

NSString * const FFAppGroupID = @"group.com.apple.mobile.MobileHouseArrest";
NSString * const FFAppGroupInboxFolder = @"SharedInbox";

@implementation FFImportService

+ (instancetype)sharedService
{
    static FFImportService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [FFImportService new];
    });
    return service;
}

- (NSURL *)groupContainerURL
{
    return [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:FFAppGroupID];
}

- (NSString *)importedDirectory
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[documents stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"Imported"];
}

- (NSUInteger)collectGroupInboxToImported
{
    NSURL *groupURL = [self groupContainerURL];
    if (!groupURL) {
        FFLogTag(@"Import", @"App Group 容器不可用（缺少 application-groups entitlement）");
        return 0;
    }
    NSURL *inbox = [groupURL URLByAppendingPathComponent:FFAppGroupInboxFolder];
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:inbox.path error:nil];
    if (names.count == 0) return 0;

    NSString *imported = [self importedDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:imported
        withIntermediateDirectories:YES attributes:nil error:nil];

    NSUInteger collected = 0;
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *source = [inbox.path stringByAppendingPathComponent:name];
        NSString *destination = [self uniquePathFor:name inDirectory:imported];
        if (!destination) continue;
        NSError *error = nil;
        if ([[NSFileManager defaultManager] moveItemAtPath:source
                toPath:destination error:&error]) {
            collected++;
            FFLogTag(@"Import", @"group inbox -> %@", destination);
        } else {
            FFLogTag(@"Import", @"move FAIL %@ (%@)", name,
                error.localizedDescription ?: @"?");
        }
    }
    return collected;
}

- (NSString *)uniquePathFor:(NSString *)name inDirectory:(NSString *)directory
{
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension.length ?
        [@"." stringByAppendingString:name.pathExtension] : @"";
    for (NSInteger index = 2; index < 1000; index++) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ (%ld)%@", base, (long)index, ext]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

@end