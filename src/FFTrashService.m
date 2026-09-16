#import "FFTrashService.h"

#import "FFLogger.h"

NSNotificationName const FFTrashDidChangeNotification = @"FFTrashDidChangeNotification";

static NSString * const FFTrashErrorDomain = @"FFTrashErrorDomain";
static NSString * const FFTrashItemMetadataName = @"item.plist";
static NSString * const FFTrashItemPayloadName = @"payload";

@interface FFTrashEntry ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, copy, readwrite) NSString *originalPath;
@property(nonatomic, copy, readwrite) NSString *payloadPath;
@property(nonatomic, strong, readwrite) NSDate *deletedAt;
@property(nonatomic, readwrite) BOOL isDirectory;
@property(nonatomic, readwrite) unsigned long long size;
@end

@implementation FFTrashEntry
@end

@implementation FFTrashService

+ (instancetype)sharedService
{
    static FFTrashService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *root = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@".Trash"];
        service = [[FFTrashService alloc] initWithTrashRoot:root];
    });
    return service;
}

- (instancetype)initWithTrashRoot:(NSString *)trashRoot
{
    self = [super init];
    if (self) {
        _trashRoot = [trashRoot copy];
    }
    return self;
}

- (BOOL)ensureTrashRoot:(NSError **)error
{
    return [NSFileManager.defaultManager createDirectoryAtPath:self.trashRoot
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error];
}

- (BOOL)pathIsInsideTrash:(NSString *)path
{
    NSString *candidate = path.stringByStandardizingPath;
    NSString *root = self.trashRoot.stringByStandardizingPath;
    return [candidate isEqualToString:root] ||
        [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSError *FFTrashError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:FFTrashErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSUInteger)moveToTrash:(NSArray<NSString *> *)paths firstError:(NSError **)error
{
    NSError *mkdirError = nil;
    if (![self ensureTrashRoot:&mkdirError]) {
        if (error) *error = mkdirError;
        return 0;
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSUInteger moved = 0;
    for (NSString *path in paths) {
        if (!path.length || [self pathIsInsideTrash:path]) continue;
        BOOL directory = NO;
        if (![manager fileExistsAtPath:path isDirectory:&directory]) continue;

        NSString *identifier = NSUUID.UUID.UUIDString;
        NSString *itemDirectory = [self.trashRoot stringByAppendingPathComponent:identifier];
        NSString *payload = [itemDirectory stringByAppendingPathComponent:FFTrashItemPayloadName];
        NSError *itemError = nil;
        if (![manager createDirectoryAtPath:itemDirectory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:&itemError]) {
            if (error) *error = itemError;
            return moved;
        }

        if (![manager moveItemAtPath:path toPath:payload error:&itemError]) {
            // Copy + delete covers the (unlikely) cross-volume case; failures
            // leave the original untouched.
            if (![manager copyItemAtPath:path toPath:payload error:&itemError] ||
                ![manager removeItemAtPath:path error:&itemError]) {
                [manager removeItemAtPath:itemDirectory error:nil];
                if (error && itemError) *error = itemError;
                return moved;
            }
        }

        NSDictionary *metadata = @{
            @"name": path.lastPathComponent,
            @"originalPath": path,
            @"deletedAt": NSDate.date,
            @"isDirectory": @(directory),
        };
        NSString *metadataPath = [itemDirectory stringByAppendingPathComponent:FFTrashItemMetadataName];
        NSData *metadataData = [NSPropertyListSerialization dataWithPropertyList:metadata
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&itemError];
        if (!metadataData.length || ![metadataData writeToFile:metadataPath
            options:NSDataWritingAtomic error:&itemError]) {
            // The entry would be invisible without its metadata; put the item
            // back instead of losing it.
            [manager moveItemAtPath:payload toPath:path error:nil];
            [manager removeItemAtPath:itemDirectory error:nil];
            if (error) *error = itemError ?: FFTrashError(4, @"无法写入回收站元数据。");
            return moved;
        }
        moved += 1;
        FFLogTag(@"Trash", @"moved name=%@ id=%@", path.lastPathComponent, identifier);
    }
    if (moved) [NSNotificationCenter.defaultCenter
        postNotificationName:FFTrashDidChangeNotification object:nil];
    return moved;
}

- (NSArray<FFTrashEntry *> *)entries
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:self.trashRoot
        error:nil] ?: @[];
    NSMutableArray<FFTrashEntry *> *result = [NSMutableArray arrayWithCapacity:children.count];
    for (NSString *identifier in children) {
        if ([identifier hasPrefix:@"."]) continue;
        NSString *itemDirectory = [self.trashRoot stringByAppendingPathComponent:identifier];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
            [itemDirectory stringByAppendingPathComponent:FFTrashItemMetadataName]];
        NSString *payloadPath = [itemDirectory stringByAppendingPathComponent:FFTrashItemPayloadName];
        if (![manager fileExistsAtPath:payloadPath]) continue;

        FFTrashEntry *entry = [FFTrashEntry new];
        entry.identifier = identifier;
        BOOL metadataOK = [metadata isKindOfClass:NSDictionary.class];
        entry.name = metadataOK && [metadata[@"name"] isKindOfClass:NSString.class]
            ? metadata[@"name"] : identifier;
        entry.originalPath = metadataOK && [metadata[@"originalPath"] isKindOfClass:NSString.class]
            ? metadata[@"originalPath"] : entry.name;
        entry.payloadPath = payloadPath;
        NSDictionary *itemAttributes = [manager attributesOfItemAtPath:itemDirectory error:nil];
        NSDate *deletedAt = metadataOK && [metadata[@"deletedAt"] isKindOfClass:NSDate.class]
            ? metadata[@"deletedAt"] : nil;
        // Item directories are created at trash time, so their creation date is
        // a reliable fallback when the metadata date is missing.
        entry.deletedAt = deletedAt ?: ([itemAttributes[NSFileCreationDate] isKindOfClass:NSDate.class]
            ? itemAttributes[NSFileCreationDate] : NSDate.distantPast);
        BOOL isDirectory = NO;
        [manager fileExistsAtPath:payloadPath isDirectory:&isDirectory];
        entry.isDirectory = metadataOK ? [metadata[@"isDirectory"] boolValue] : isDirectory;
        NSDictionary *attributes = [manager attributesOfItemAtPath:payloadPath error:nil];
        entry.size = entry.isDirectory ? 0 : [attributes[NSFileSize] unsignedLongLongValue];
        [result addObject:entry];
    }
    [result sortUsingComparator:^NSComparisonResult(FFTrashEntry *left, FFTrashEntry *right) {
        NSComparisonResult byDate = [right.deletedAt compare:left.deletedAt];
        if (byDate != NSOrderedSame) return byDate;
        return [right.identifier compare:left.identifier];
    }];
    return result;
}

- (NSUInteger)itemCount
{
    return self.entries.count;
}

- (NSString *)uniqueRestorePathForName:(NSString *)name inDirectory:(NSString *)directory
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![manager fileExistsAtPath:candidate]) return candidate;
    NSString *stem = name.stringByDeletingPathExtension;
    NSString *extension = name.pathExtension;
    for (NSUInteger index = 2; index < 10000; index++) {
        NSString *indexed = [NSString stringWithFormat:@"%@ (%lu)", stem, (unsigned long)index];
        if (extension.length) indexed = [indexed stringByAppendingPathExtension:extension];
        candidate = [directory stringByAppendingPathComponent:indexed];
        if (![manager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

- (BOOL)restoreEntry:(FFTrashEntry *)entry
        restoredPath:(NSString * _Nullable * _Nullable)outPath
               error:(NSError **)error
{
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager fileExistsAtPath:entry.payloadPath]) {
        if (error) *error = FFTrashError(2, @"回收站条目已不存在。");
        return NO;
    }
    NSString *directory = entry.originalPath.stringByDeletingLastPathComponent;
    if (!directory.length || ![manager fileExistsAtPath:directory]) {
        // Original folder is gone: restore next to the trash root instead of
        // refusing, so nothing is stranded.
        directory = self.trashRoot.stringByDeletingLastPathComponent;
    }
    NSString *destination = [self uniqueRestorePathForName:entry.name inDirectory:directory];
    if (!destination.length) {
        if (error) *error = FFTrashError(3, @"无法生成恢复后的文件名。");
        return NO;
    }
    NSError *moveError = nil;
    if (![manager moveItemAtPath:entry.payloadPath toPath:destination error:&moveError]) {
        // Cross-volume fallback.
        if (![manager copyItemAtPath:entry.payloadPath toPath:destination error:&moveError]) {
            if (error) *error = moveError;
            return NO;
        }
        [manager removeItemAtPath:entry.payloadPath error:nil];
    }
    [manager removeItemAtPath:
        [self.trashRoot stringByAppendingPathComponent:entry.identifier] error:nil];
    if (outPath) *outPath = destination;
    FFLogTag(@"Trash", @"restored name=%@ to=%@", entry.name, destination);
    [NSNotificationCenter.defaultCenter postNotificationName:FFTrashDidChangeNotification object:nil];
    return YES;
}

- (BOOL)removeEntryPermanently:(FFTrashEntry *)entry error:(NSError **)error
{
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:
        [self.trashRoot stringByAppendingPathComponent:entry.identifier] error:error];
    if (ok) [NSNotificationCenter.defaultCenter
        postNotificationName:FFTrashDidChangeNotification object:nil];
    return ok;
}

- (NSUInteger)emptyWithError:(NSError **)error
{
    NSUInteger removed = 0;
    for (FFTrashEntry *entry in self.entries) {
        NSError *itemError = nil;
        if ([self removeEntryPermanently:entry error:&itemError]) removed += 1;
        else if (error && !*error) *error = itemError;
    }
    return removed;
}

@end
