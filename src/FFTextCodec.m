#import "FFTextCodec.h"
#import "FFContentProbe.h"

@implementation FFTextCodec

#pragma mark - Decode

+ (NSString *)decodeData:(NSData *)data
                 encoding:(FFTextEncoding *)outEncoding
                      bom:(BOOL *)outBOM
               lineEnding:(FFLineEnding *)outLineEnding
{
    if (data.length == 0) {
        if (outEncoding) *outEncoding = FFTextEncodingUTF8;
        if (outBOM) *outBOM = NO;
        if (outLineEnding) *outLineEnding = FFLineEndingLF;
        return @"";
    }
    FFTextEncoding encoding = [self detectEncodingOfData:data bom:outBOM];
    if (encoding == FFTextEncodingLatin1) {
        // 自动路径永远不到 Latin-1（Latin-1 = 强制打开专用哨兵）。
        return nil;
    }
    if (outEncoding) *outEncoding = encoding;
    NSString *string = [self decodeData:data forcedEncoding:encoding
                             lineEnding:outLineEnding];
    return string;
}

+ (NSString *)decodeData:(NSData *)data
           forcedEncoding:(FFTextEncoding)encoding
                lineEnding:(FFLineEnding *)outLineEnding
{
    NSStringEncoding nsEncoding = 0;
    NSRange range = NSMakeRange(0, data.length);
    switch (encoding) {
        case FFTextEncodingUTF8:
        case FFTextEncodingUTF8BOM:
            nsEncoding = NSUTF8StringEncoding;
            break;
        case FFTextEncodingUTF16LE:
            nsEncoding = NSUTF16LittleEndianStringEncoding;
            break;
        case FFTextEncodingUTF16BE:
            nsEncoding = NSUTF16BigEndianStringEncoding;
            break;
        case FFTextEncodingLatin1:
            nsEncoding = NSISOLatin1StringEncoding;
            break;
    }
    // 跳过 BOM 字节按对应编码解码（Foundation 会自行辨认 BOM，可能重复）。
    NSString *string = [[NSString alloc] initWithData:data encoding:nsEncoding];
    if (!string) {
        // 允许末尾截断的序列：取偶数长度（UTF-16）。
        if (encoding == FFTextEncodingUTF16LE || encoding == FFTextEncodingUTF16BE) {
            NSData *trimmed = [data subdataWithRange:NSMakeRange(0, data.length & ~1ULL)];
            string = [[NSString alloc] initWithData:trimmed encoding:nsEncoding];
        }
        if (!string) return nil;
    }
    // UTF-8 BOM 残留（如果解码时未被吃掉）。
    if ([string hasPrefix:@"\uFEFF"]) {
        string = [string substringFromIndex:1];
    }
    if (outLineEnding) {
        *outLineEnding = [self detectLineEndingOfString:string];
    }
    // Foundation 按 UTF-16LE/BE 解码时，若数据带 BOM，NSString 会保留 BOM 字符，
    // 或 NSString 直接用 NSUTF16StringEncoding 吃 BOM；这里统一确认无 BOM。
    if ((encoding == FFTextEncodingUTF16LE || encoding == FFTextEncodingUTF16BE)
        && [string hasPrefix:@"\uFEFF"]) {
        string = [string substringFromIndex:1];
    }
    return string;
}

+ (FFTextEncoding)detectEncodingOfData:(NSData *)data bom:(BOOL *)outBOM
{
    if (outBOM) *outBOM = NO;
    if (data.length < 2) return FFTextEncodingUTF8;
    const uint8_t *bytes = data.bytes;
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        if (outBOM) *outBOM = YES;
        return FFTextEncodingUTF16LE;
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        if (outBOM) *outBOM = YES;
        return FFTextEncodingUTF16BE;
    }
    if (bytes[0] == 0xEF && bytes[1] == 0xBB && data.length > 2 && bytes[2] == 0xBF) {
        if (outBOM) *outBOM = YES;
        return FFTextEncodingUTF8BOM;
    }
    // 无 BOM：UTF-16 启发式（LE/BE 按 NUL 位置对称判断），否则要求严格 UTF-8。
    NSUInteger limit = MIN(data.length / 2, (NSUInteger)4096);
    NSUInteger leNulls = 0;
    NSUInteger beNulls = 0;
    for (NSUInteger u = 0; u < limit; u++) {
        uint8_t lo = bytes[u * 2];
        uint8_t hi = bytes[u * 2 + 1];
        if (lo != 0 && hi == 0) leNulls++;   // BE 样式：高位字节 0
        if (lo == 0 && hi != 0) beNulls++;   // LE 样式：低位字节 0
    }
    if (limit > 0 && (leNulls >= limit / 2 || beNulls >= limit / 2)) {
        if (beNulls > leNulls) return FFTextEncodingUTF16BE; // 高字节在后 → BE 存储
        return FFTextEncodingUTF16LE;
    }
    // 严格 UTF-8 校验（FFContentProbe 提供采样级有效判定）。
    if ([FFContentProbe isValidUTF8Sample:data]) return FFTextEncodingUTF8;
    return FFTextEncodingLatin1; // 哨兵：自动识别失败（调用方视为「非文本」，不强解）
}

#pragma mark - Encode

+ (NSData *)encodeString:(NSString *)string
                 encoding:(FFTextEncoding)encoding
                      bom:(BOOL)bom
               lineEnding:(FFLineEnding)lineEnding
{
    // 先统一换行符（归一化到目标），再次标准化所有分隔符。
    NSString *normalized = FFNormalizeLineEndings(string, lineEnding);

    NSStringEncoding nsEncoding = 0;
    switch (encoding) {
        case FFTextEncodingUTF8:
        case FFTextEncodingUTF8BOM:
            nsEncoding = NSUTF8StringEncoding;
            break;
        case FFTextEncodingUTF16LE:
            nsEncoding = NSUTF16LittleEndianStringEncoding;
            break;
        case FFTextEncodingUTF16BE:
            nsEncoding = NSUTF16BigEndianStringEncoding;
            break;
        case FFTextEncodingLatin1:
            nsEncoding = NSISOLatin1StringEncoding;
            break;
    }
    NSData *payload = [normalized dataUsingEncoding:nsEncoding allowLossyConversion:NO];
    if (!payload) return nil;
    NSMutableData *result = [payload mutableCopy];
    if (bom) {
        NSData *bomData = nil;
        switch (encoding) {
            case FFTextEncodingUTF8BOM:
                bomData = [NSData dataWithBytes:"\xEF\xBB\xBF" length:3];
                break;
            case FFTextEncodingUTF16LE:
                bomData = [NSData dataWithBytes:"\xFF\xFE" length:2];
                break;
            case FFTextEncodingUTF16BE:
                bomData = [NSData dataWithBytes:"\xFE\xFF" length:2];
                break;
            case FFTextEncodingUTF8:
            case FFTextEncodingLatin1:
                break;
        }
        if (bomData) [result replaceBytesInRange:NSMakeRange(0, 0) withBytes:bomData.bytes length:bomData.length];
    }
    return result;
}

static NSString *FFNormalizeLineEndings(NSString *text, FFLineEnding target)
{
    if (text == nil) return @"";
    NSMutableString *work = [text mutableCopy];
    // 合并 CRLF 与裸 CR。
    [work replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0
                                range:NSMakeRange(0, work.length)];
    [work replaceOccurrencesOfString:@"\r" withString:@"\n" options:0
                                range:NSMakeRange(0, work.length)];
    switch (target) {
        case FFLineEndingLF: return [work copy];
        case FFLineEndingCRLF:
            [work replaceOccurrencesOfString:@"\n" withString:@"\r\n" options:0
                                        range:NSMakeRange(0, work.length)];
            return [work copy];
        case FFLineEndingCR:
            [work replaceOccurrencesOfString:@"\n" withString:@"\r" options:0
                                        range:NSMakeRange(0, work.length)];
            return [work copy];
    }
}

+ (FFLineEnding)detectLineEndingOfString:(NSString *)string
{
    NSUInteger crlf = 0, lfOnly = 0, crOnly = 0;
    NSUInteger length = string.length;
    NSUInteger i = 0;
    while (i < length) {
        unichar c = [string characterAtIndex:i];
        if (c == '\r') {
            if (i + 1 < length && [string characterAtIndex:i + 1] == '\n') { crlf++; i += 2; }
            else { crOnly++; i += 1; }
        } else if (c == '\n') {
            lfOnly++; i += 1;
        } else {
            i += 1;
        }
    }
    if (crlf >= lfOnly && crlf >= crOnly && crlf > 0) return FFLineEndingCRLF;
    if (crOnly > lfOnly && crOnly > 0) return FFLineEndingCR;
    return FFLineEndingLF;
}

+ (NSString *)nameForEncoding:(FFTextEncoding)encoding
{
    switch (encoding) {
        case FFTextEncodingUTF8: return @"UTF-8";
        case FFTextEncodingUTF8BOM: return @"UTF-8 (BOM)";
        case FFTextEncodingUTF16LE: return @"UTF-16 LE";
        case FFTextEncodingUTF16BE: return @"UTF-16 BE";
        case FFTextEncodingLatin1: return @"Latin-1 (强制)";
    }
}

+ (NSString *)nameForLineEnding:(FFLineEnding)lineEnding
{
    switch (lineEnding) {
        case FFLineEndingLF: return @"LF (Unix)";
        case FFLineEndingCRLF: return @"CRLF (Windows)";
        case FFLineEndingCR: return @"CR (Mac)";
    }
}

@end
