#import "FFPlistDocument.h"
#import "FFPathPolicy.h"
#import "FFLogger.h"

NSString * const FFPlistDocumentDidChangeNotification = @"FFPlistDocumentDidChange";
NSString * const FFPlistDocumentErrorDomain = @"FuckFile.PlistDocument";

static NSError *FFPlistError(FFPlistDocumentErrorCode code, NSString *message)
{
    return [NSError errorWithDomain:FFPlistDocumentErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"属性表操作失败"}];
}

static id FFPlistDeepMutableCopy(id object)
{
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:[object count]];
        [object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if (key) dict[key] = FFPlistDeepMutableCopy(value);
        }];
        return dict;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:[object count]];
        for (id value in object) [array addObject:FFPlistDeepMutableCopy(value)];
        return array;
    }
    // Property-list leaves are immutable value objects in practice. Copy where
    // meaningful so the editor never aliases a mutable object handed to the parser.
    if ([object conformsToProtocol:@protocol(NSCopying)]) return [object copy];
    return object;
}

@interface FFPlistDocument ()
@property(nonatomic, copy, readwrite) NSString *filePath;
@property(nonatomic, strong, readwrite) id rootObject;
@property(nonatomic, readwrite) NSPropertyListFormat format;
@property(nonatomic, readwrite, getter=isLoaded) BOOL loaded;
@property(nonatomic, readwrite, getter=isDirty) BOOL dirty;
@property(nonatomic, readwrite) unsigned long long fileSize;
@property(nonatomic, strong) NSData *baselineData;
@end

@implementation FFPlistDocument

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) _filePath = [path copy];
    return self;
}

- (BOOL)loadWithMaximumBytes:(unsigned long long)maxBytes error:(NSError **)error
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:self.filePath error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (maxBytes > 0 && size > maxBytes) {
        if (error) {
            NSString *actual = [NSByteCountFormatter stringFromByteCount:(long long)size
                countStyle:NSByteCountFormatterCountStyleFile];
            NSString *limit = [NSByteCountFormatter stringFromByteCount:(long long)maxBytes
                countStyle:NSByteCountFormatterCountStyleFile];
            *error = FFPlistError(FFPlistDocumentErrorTooLarge,
                [NSString stringWithFormat:@"文件 %@，超过结构化编辑上限 %@。", actual, limit]);
        }
        return NO;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:self.filePath
        options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorUnreadable,
            readError.localizedDescription ?: @"无法读取文件");
        return NO;
    }

    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    NSError *parseError = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:&format error:&parseError];
    if (!plist) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorInvalidPropertyList,
            parseError.localizedDescription ?: @"不是有效的属性表");
        return NO;
    }
    if (![plist isKindOfClass:NSDictionary.class] && ![plist isKindOfClass:NSArray.class]) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorUnsupportedRoot,
            @"属性表根节点必须是字典或数组。");
        return NO;
    }

    self.rootObject = FFPlistDeepMutableCopy(plist);
    self.format = format;
    self.baselineData = data;
    self.fileSize = data.length;
    self.loaded = YES;
    self.dirty = NO;
    [self notifyChanged];
    return YES;
}

- (void)markChanged
{
    if (!self.loaded) return;
    self.dirty = YES;
    [self notifyChanged];
}

- (NSData *)serializedData:(NSError **)error
{
    if (!self.loaded || !self.rootObject) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorSerialization, @"属性表尚未载入。");
        return nil;
    }
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.rootObject
        format:self.format options:0 error:&serializationError];
    if (!data && error) {
        *error = FFPlistError(FFPlistDocumentErrorSerialization,
            serializationError.localizedDescription ?: @"无法序列化属性表");
    }
    return data;
}

- (BOOL)hasExternalModification:(NSError **)error
{
    if (!self.loaded || !self.baselineData) return NO;
    NSError *readError = nil;
    NSData *current = [NSData dataWithContentsOfFile:self.filePath
        options:NSDataReadingMappedIfSafe error:&readError];
    if (!current) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorExternalModification,
            readError.localizedDescription ?: @"原文件已不存在或无法读取");
        return YES;
    }
    return ![current isEqualToData:self.baselineData];
}

- (BOOL)saveForcingExternalOverwrite:(BOOL)force error:(NSError **)error
{
    NSError *conflictError = nil;
    if (!force && [self hasExternalModification:&conflictError]) {
        if (error) *error = conflictError ?: FFPlistError(
            FFPlistDocumentErrorExternalModification, @"文件已被其他进程修改。");
        return NO;
    }

    NSError *serializationError = nil;
    NSData *data = [self serializedData:&serializationError];
    if (!data) {
        if (error) *error = serializationError;
        return NO;
    }

    NSString *detail = nil;
    NSString *finalName = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:self.filePath
        finalName:&finalName errorMessage:&detail];
    if (!parent || finalName.length == 0) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorPathRejected,
            detail ?: @"路径不合法");
        return NO;
    }
    NSString *target = [parent stringByAppendingPathComponent:finalName];

    NSError *writeError = nil;
    if (![data writeToFile:target options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorWriteFailed,
            writeError.localizedDescription ?: @"无法写入文件");
        return NO;
    }

    // Read-back verification protects the live AppData use case from reporting a
    // successful save when the replacement was truncated or immediately invalid.
    NSError *verifyReadError = nil;
    NSData *verifyData = [NSData dataWithContentsOfFile:target
        options:NSDataReadingMappedIfSafe error:&verifyReadError];
    NSPropertyListFormat verifyFormat = self.format;
    NSError *verifyParseError = nil;
    id verifyPlist = verifyData ? [NSPropertyListSerialization propertyListWithData:verifyData
        options:NSPropertyListImmutable format:&verifyFormat error:&verifyParseError] : nil;
    if (!verifyData || !verifyPlist || ![verifyData isEqualToData:data]) {
        FFLogTag(@"PlistDocument", @"verification failed path=%@ read=%@ parse=%@",
            target, verifyReadError, verifyParseError);
        if (error) *error = FFPlistError(FFPlistDocumentErrorVerificationFailed,
            verifyParseError.localizedDescription ?: verifyReadError.localizedDescription ?:
            @"写入后的文件校验失败");
        return NO;
    }

    self.baselineData = verifyData;
    self.fileSize = verifyData.length;
    self.dirty = NO;
    [self notifyChanged];
    FFLogTag(@"PlistDocument", @"saved %@ (%lu bytes, format=%lu)", self.filePath,
        (unsigned long)verifyData.length, (unsigned long)self.format);
    return YES;
}

- (BOOL)saveCopyToPath:(NSString *)copyPath error:(NSError **)error
{
    NSError *serializationError = nil;
    NSData *data = [self serializedData:&serializationError];
    if (!data) {
        if (error) *error = serializationError;
        return NO;
    }
    NSError *writeError = nil;
    if (![data writeToFile:copyPath options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = FFPlistError(FFPlistDocumentErrorWriteFailed,
            writeError.localizedDescription ?: @"副本写入失败");
        return NO;
    }
    return YES;
}

- (void)notifyChanged
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FFPlistDocumentDidChangeNotification
            object:self];
    });
}

@end
