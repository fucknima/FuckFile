#import "FFContentProbe.h"

#import <ctype.h>

// 头窗口采样：文本统计 16 KB 即可稳定，magic/JSON 需要 64 KB 容纳
// 头窗口采样：文本统计 16 KB 即可稳定，magic/JSON 需要 64 KB 容纳。
static const NSUInteger kFFProbeSampleLength = 64 * 1024;

static BOOL FFIsNullByte(uint8_t byte) { return byte == 0x00; }

// 可打印判断：0x20 ~ 0x7E 加上常用控制字符（\t \n \r \f \b 与 0x1B）
// 计入可读；其余计为噪声。
static BOOL FFIsReadableByte(uint8_t byte)
{
    if (byte >= 0x20 && byte != 0x7F) return YES;
    switch (byte) {
        case '\t': case '\n': case '\r': case '\f': case '\b': case 0x1B:
            return YES;
        default: return NO;
    }
}

@implementation FFContentProbe

+ (NSUInteger)sampleLength
{
    return kFFProbeSampleLength;
}

+ (NSData *)sampleFile:(NSString *)path
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSData *data = [handle readDataOfLength:kFFProbeSampleLength];
    [handle closeFile];
    return data;
}

+ (FFContentKind)contentKindOfFile:(NSString *)path
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return FFContentKindUnknown;
    NSData *sample = [handle readDataOfLength:kFFProbeSampleLength];
    [handle closeFile];
    if (sample.length == 0) return FFContentKindUnknown;
    return [self contentKindOfSample:sample];
}

+ (FFContentKind)contentKindOfData:(NSData *)data
{
    return [self contentKindOfSample:data.length ? data : [NSData data]];
}

+ (FFContentKind)contentKindOfSample:(NSData *)sample
{
    if (sample.length == 0) return FFContentKindUnknown;
    const uint8_t *bytes = sample.bytes;

    // ---- 精确 magic 判定（优先级最高，不参与文本竞争） ----
    if ([self isZIP:sample]) return FFContentKindZIP;
    if ([self isSQLite:sample]) return FFContentKindSQLite;

    // 二进制 plist / XML plist（bplist00 或 XML 字典）。
    if (sample.length >= 8 && memcmp(bytes, "bplist0", 7) == 0)
        return FFContentKindPlist;

    // 图片类已知魔数直接归为 binary（QuickLook 兜底处理）。
    if (sample.length >= 8) {
        if (memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0 ||
            memcmp(bytes, "\xFF\xD8\xFF", 3) == 0 ||
            memcmp(bytes, "GIF8", 4) == 0 ||
            memcmp(bytes, "RIFF", 4) == 0 ||
            memcmp(bytes, "\x00\x00\x00\x14" "ftyp", 8) == 0 ||
            memcmp(bytes, "\x00\x01\x00\x00", 4) == 0) {
            return FFContentKindBinary;
        }
    }

    // ---- 文本：UTF-8 / UTF-16 ----
    if ([self isTextSample:sample]) {
        // 相对廉价的结构探测仅作用于已确认文本。
        FFContentKind structural = [self structuralKindOfTextSample:sample];
        if (structural != FFContentKindUnknown) return structural;
        BOOL hasBOM = NO;
        NSString *encoding = [self detectedEncodingOfSample:sample hasBOM:&hasBOM];
        if ([encoding isEqualToString:@"UTF-16"]) return FFContentKindTextUTF16;
        return FFContentKindTextUTF8;
    }

    // ---- 其余：已知可解释类型 / 未知二进制 ----
    return FFContentKindBinary;
}

// 文本结构探测：XML / JSON / XML plist。文本判定已通过时使用。
+ (FFContentKind)structuralKindOfTextSample:(NSData *)sample
{
    NSUInteger head = MIN(sample.length, (NSUInteger)4096);
    NSData *headData = [sample subdataWithRange:NSMakeRange(0, head)];
    NSString *headString = [[NSString alloc] initWithData:headData
                                                 encoding:NSUTF8StringEncoding];
    if (!headString) return FFContentKindUnknown;

    // 去 BOM 与空白。
    NSUInteger cursor = 0;
    NSString *trimmed = nil;
    if ([headString hasPrefix:@"\uFEFF"]) cursor = 1;
    NSUInteger length = headString.length;
    while (cursor < length) {
        unichar c = [headString characterAtIndex:cursor];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') cursor++;
        else break;
    }
    if (cursor < length) trimmed = [headString substringFromIndex:cursor];

    // JSON 文本：头字符 { 或 [。
    if (trimmed.length > 0) {
        unichar c0 = [trimmed characterAtIndex:0];
        if (c0 == '{' || c0 == '[') return FFContentKindJSON;
    }

    // XML / XML plist：<? 或以 < 开头且短窗口内包含 <tag。
    if (trimmed.length >= 4 && [[trimmed substringWithRange:NSMakeRange(0, 4)]
            isEqualToString:@"<?xm"]) return FFContentKindXML;
    if (trimmed.length > 0 && [trimmed characterAtIndex:0] == '<') {
        NSRange lt = [trimmed rangeOfString:@"<!DOCTYPE"];
        NSRange attrs = [trimmed rangeOfString:@"<?xml"];
        if (attrs.location == 0 || lt.length > 0 ||
            [trimmed containsString:@"<html"] ||
            [trimmed containsString:@"<plist"]) {
            return FFContentKindXML;
        }
    }
    return FFContentKindUnknown;
}

#pragma mark - Text detection

+ (BOOL)isTextSample:(NSData *)sample
{
    if (sample.length == 0) return YES;
    const uint8_t *bytes = sample.bytes;
    NSUInteger count = sample.length;

    // ---- UTF-8 有效性：严格前 8KB，允许 64KB 内容且要求全通过。 ----
    // （16 KB 内包含错误字节视为非文本。）
    BOOL utf8 = [self isValidUTF8:bytes length:count];
    if (utf8) {
        // 不允许 NUL（UTF-16 独占该模式）。
        BOOL hasNull = NO;
        for (NSUInteger i = 0; i < count && !hasNull; i++)
            if (bytes[i] == 0x00) hasNull = YES;
        if (!hasNull) return YES;
    }

    // ---- UTF-16 LE/BE：BOM 为主，无 BOM 时用 NUL 模式启发式。 ----
    if ([self looksLikeUTF16:bytes length:count]) return YES;

    // UTF-32 BOM 视为非文本（本项目不支持）。
    return NO;
}

+ (BOOL)isValidUTF8Sample:(NSData *)data
{
    return [self isValidUTF8:data.bytes length:data.length];
}

+ (BOOL)isValidUTF8:(const uint8_t *)bytes length:(NSUInteger)length
{
    NSUInteger i = 0;
    while (i < length) {
        uint8_t c = bytes[i];
        NSUInteger n = 0;      // continuation count
        uint32_t code = 0;
        if (c < 0x80) {
            i += 1;
            continue;
        } else if ((c & 0xE0) == 0xC0) {
            n = 1; code = c & 0x1F;
            if (code < 2) return NO;    // overlong
        } else if ((c & 0xF0) == 0xE0) {
            n = 2; code = c & 0x0F;
        } else if ((c & 0xF8) == 0xF0) {
            n = 3; code = c & 0x07;
            if (code > 4) return NO;    // > U+10FFFF
        } else {
            return NO;
        }
        if (i + n >= length) return NO;     // truncated sequence
        for (NSUInteger k = 1; k <= n; k++) {
            uint8_t cc = bytes[i + k];
            if ((cc & 0xC0) != 0x80) return NO;
            code = (code << 6) | (cc & 0x3F);
        }
        // Surrogate range 拒绝（UTF-8 编码的 UTF-16 surrogate 非法）。
        if (code >= 0xD800 && code <= 0xDFFF) return NO;
        i += n + 1;
    }
    return YES;
}

+ (BOOL)looksLikeUTF16:(const uint8_t *)bytes length:(NSUInteger)length
{
    if (length < 4) return NO;
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return YES; // LE BOM
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return YES; // BE BOM

    // 无 BOM：奇数偏移 NUL 配对比率启发式（ASCII 文本的 UTF-16 形式）。
    NSUInteger nulls = 0;
    NSUInteger pairs = 0;
    NSUInteger limit = MIN(length / 2, (NSUInteger)4096);
    for (NSUInteger u = 0; u < limit; u++) {
        uint8_t lo = bytes[u * 2];
        uint8_t hi = bytes[u * 2 + 1];
        if ((lo != 0 && hi == 0) || (lo == 0 && hi != 0)) {
            nulls++;
            if ((lo != 0 && hi == 0)) pairs = 1;
        }
    }
    if (length % 2 != 0 && nulls > 0) return NO;
    // 每个字符恰好一个 NUL 字节且另一字节可打印 → 极大概率 UTF-16。
    if (nulls >= limit / 2) return YES;
    return NO;
}

+ (NSString *)detectedEncodingOfSample:(NSData *)sample hasBOM:(BOOL *)hasBOM
{
    if (hasBOM) *hasBOM = NO;
    if (sample.length < 2) return nil;
    const uint8_t *bytes = sample.bytes;
    if (bytes[0] == 0xEF && bytes[1] == 0xBB) {
        if (hasBOM) *hasBOM = YES;
        return @"UTF-8";
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        if (hasBOM) *hasBOM = YES;
        return @"UTF-16";
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        if (hasBOM) *hasBOM = YES;
        return @"UTF-16";
    }
    // 无 BOM：UTF-16 启发式。
    if ([self looksLikeUTF16:bytes length:sample.length]) return @"UTF-16";
    if ([self isValidUTF8:bytes length:sample.length]) return @"UTF-8";
    return nil;
}

#pragma mark - Specific formats

+ (BOOL)isSQLite:(NSData *)sample
{
    if (sample.length < 16) return NO;
    static const uint8_t magic[] = "SQLite format 3\0";
    return memcmp(sample.bytes, magic, sizeof(magic) - 1) == 0;
}

+ (BOOL)isZIP:(NSData *)sample
{
    if (sample.length < 4) return NO;
    const uint8_t *bytes = sample.bytes;
    return (bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == '\x03' && bytes[3] == '\x04')
        || (bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == '\x05' && bytes[3] == '\x06')
        || (bytes[0] == 'P' && bytes[1] == 'K' && bytes[2] == '\x07' && bytes[3] == '\x08');
}

@end
