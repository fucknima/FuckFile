#import "FFIPSParser.h"
#import "FFContentProbe.h"

#import <zlib.h>
#import <string.h>
#import <stdlib.h>

// 解压安全边界：在大量被压缩数据下 App 不允许 OOM。
static const unsigned long long kFFIPSMaxDecompressedBytes = 64 * 1024 * 1024; // 64 MB
static const unsigned long kFFIPSMaxCompressionRatio = 256;

@implementation FFIPSParseResult
@end

@implementation FFIPSParser

+ (unsigned long long)maxDecompressedBytes
{
    return kFFIPSMaxDecompressedBytes;
}

+ (unsigned long)maxCompressionRatio
{
    return kFFIPSMaxCompressionRatio;
}

+ (BOOL)fileLooksLikeIPS:(NSString *)path
{
    if (!path.length) return NO;
    NSData *sample = [FFContentProbe sampleFile:path];
    if (sample.length == 0) return NO;
    return [FFContentProbe looksLikeIPSDiagnostic:sample];
}

#pragma mark - Header boundary scan

// 平衡括号扫描：从第一个非空白字符开始（必须 { 或 [；只处理 { 顶层）。
// Header JSON 里字符串可能带有括号/转义，需要按 " 与 \ 状态机处理。
+ (long long)headerJSONEndOffset:(NSData *)data
{
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger i = 0;
    // 仅接受 { 顶层对象（.ips header 均为对象；数组不当作合法 header）。
    while (i < length && (bytes[i] == ' ' || bytes[i] == '\t' ||
                          bytes[i] == '\r' || bytes[i] == '\n')) i++;
    if (i >= length || bytes[i] != '{') return -1;
    NSUInteger depth = 0;
    BOOL inString = NO;
    BOOL escaped = NO;
    while (i < length) {
        uint8_t c = bytes[i];
        if (inString) {
            if (escaped) {
                escaped = NO;
            } else if (c == '\\') {
                escaped = YES;
            } else if (c == '"') {
                inString = NO;
            }
        } else {
            switch (c) {
                case '{': depth++; break;
                case '}':
                    depth--;
                    if (depth == 0) return (long long)(i + 1);
                    if (depth == 0) break;
                    break;
                case '"':
                    inString = YES;
                    break;
                default: break;
            }
        }
        i++;
    }
    return -1;
}

#pragma mark - Parse

+ (FFIPSParseResult *)parseData:(NSData *)data
{
    FFIPSParseResult *result = [FFIPSParseResult new];
    result.status = FFIPSStatusNotIPS;
    if (data.length == 0) return result;

    long long endOffset = [self headerJSONEndOffset:data];
    if (endOffset <= 0) return result;

    NSData *headerData = [data subdataWithRange:NSMakeRange(0, (NSUInteger)endOffset)];
    NSDictionary *header = nil;
    @try {
        header = [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil];
    } @catch (NSException *exception) {
        header = nil;
    }
    if (![header isKindOfClass:NSDictionary.class] || header.count == 0) {
        // 结构上从 { 开始但 JSON 解析失败：非规范 IPS。
        return result;
    }
    result.header = header;
    result.headerData = headerData;
    result.payloadOffset = (unsigned long long)endOffset;
    result.payloadLength = (unsigned long long)(data.length - (NSUInteger)endOffset);
    result.hasPayload = result.payloadLength > 0;
    result.status = FFIPSStatusOK;

    // Header 声称的压缩方式（custom_headers.compression 最常见；
    // 个别格式在顶层 "compression"）。
    NSString *compression = nil;
    id customHeaders = header[@"custom_headers"];
    if ([customHeaders isKindOfClass:NSDictionary.class]) {
        id value = customHeaders[@"compression"];
        if ([value isKindOfClass:NSString.class]) compression = value;
        if ([value isKindOfClass:NSNumber.class]) compression = [value stringValue];
    }
    if (!compression.length && [header[@"compression"] isKindOfClass:NSString.class]) {
        compression = header[@"compression"];
    }
    if (!compression.length && [header[@"compression"] isKindOfClass:NSNumber.class]) {
        compression = [header[@"compression"] stringValue];
    }
    if ([compression isEqualToString:@"zlib"]) {
        result.declaredCompression = FFIPSCompressionZlib;
    } else if (compression.length == 0 || [compression isEqualToString:@"none"]) {
        result.declaredCompression = FFIPSCompressionNone;
    } else {
        result.declaredCompression = FFIPSCompressionUnknown;
    }

    if (!result.hasPayload) {
        // ✅ 纯 JSON IPS（无 payload）。
        result.payloadFormat = [self probePayloadFormat:nil];
        return result;
    }

    // 有 payload：按声明顺序解压。none → 原样复制（带 64MB 上限）。
    NSData *payload = [data subdataWithRange:NSMakeRange((NSUInteger)endOffset,
        (NSUInteger)result.payloadLength)];

    if (result.declaredCompression == FFIPSCompressionNone) {
        if (payload.length > kFFIPSMaxDecompressedBytes) {
            result.status = FFIPSStatusDecompressBomb;
            result.failureDetail = @"Payload 超过安全大小上限（64 MB）";
            return result;
        }
        result.actualCompression = FFIPSCompressionNone;
        result.payload = payload;
        result.payloadDecodedSize = payload.length;
        result.payloadFormat = [self probePayloadFormat:payload];
        result.isRHWN = [result.payloadFormat isEqualToString:@"RHWN"];
        return result;
    }

    // zlib 标准 → raw deflate 回退。
    unsigned long long ratioSeed = MAX(result.payloadLength, (unsigned long long)1);

    // 1) 标准 zlib。
    BOOL bomb = NO;
    NSData *inflated = [self inflate:payload windowBits:15
                              expectedRatio:ratioSeed bomb:&bomb];
    if (!inflated && !bomb) {
        // 2) raw DEFLATE。
        inflated = [self inflate:payload windowBits:-15
                          expectedRatio:ratioSeed bomb:&bomb];
        result.actualCompression = inflated ? FFIPSCompressionRawDeflate
                                            : FFIPSCompressionUnknown;
    } else {
        result.actualCompression = inflated ? FFIPSCompressionZlib
                                            : FFIPSCompressionUnknown;
    }
    if (!inflated) {
        if (bomb) {
            result.status = FFIPSStatusDecompressBomb;
            result.failureDetail = @"Payload 解压超过安全大小上限（64 MB），已中止";
        } else {
            result.status = FFIPSStatusDecompressFailed;
            result.failureDetail = @"zlib 与 raw DEFLATE 均无法解压（数据可能损坏或使用了其他压缩方式）";
        }
        return result;
    }
    result.payload = inflated;
    result.payloadDecodedSize = inflated.length;
    result.payloadFormat = [self probePayloadFormat:inflated];
    result.isRHWN = [result.payloadFormat isEqualToString:@"RHWN"];
    return result;
}

+ (FFIPSParseResult *)parseFile:(NSString *)path
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        FFIPSParseResult *failed = [FFIPSParseResult new];
        failed.status = FFIPSStatusNotIPS;
        failed.failureDetail = @"无法读取文件";
        return failed;
    }
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    return [self parseData:data];
}

#pragma mark - Inflate

// 尝试一次 inflate；返回 nil 表示该模式失败或超限。
// *bomb 输出 YES 表示超过安全输出上限（防压缩炸弹）。
+ (nullable NSData *)inflate:(NSData *)source windowBits:(int)windowBits
                 expectedRatio:(unsigned long long)sourceLength
                          bomb:(BOOL *)bomb
{
    if (bomb) *bomb = NO;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, windowBits) != Z_OK) return nil;

    const uint8_t *input = source.bytes;
    uLong inputLength = (uLong)source.length;
    NSMutableData *output = [NSMutableData dataWithCapacity:
        MIN(sourceLength * 2, kFFIPSMaxDecompressedBytes)];
    BOOL failed = NO;
    BOOL overLimit = NO;

    stream.next_in = (Bytef *)(uintptr_t)input;
    stream.avail_in = inputLength;
    while (1) {
        size_t remaining = kFFIPSMaxDecompressedBytes - output.length;
        if (remaining == 0) { overLimit = YES; break; }
        size_t chunk = MIN((size_t)(256 * 1024), remaining);
        uint8_t *buffer = malloc(chunk);
        stream.next_out = buffer;
        uInt want = (uInt)chunk;
        stream.avail_out = want;
        int status = inflate(&stream, Z_NO_FLUSH);
        size_t produced = want - stream.avail_out;
        if (produced > 0) [output appendBytes:buffer length:produced];
        free(buffer);

        if (status == Z_STREAM_END) break;
        if (status != Z_OK) { failed = YES; break; }
        if (produced == 0 && stream.avail_out == want) { failed = YES; break; }
    }
    inflateEnd(&stream);
    if (overLimit) {
        if (bomb) *bomb = YES;
        return nil;
    }
    if (failed || output.length == 0) return nil;
    // 压缩比检查（防高比率炸弹：比如 4KB 解出 10MB）。
    if (sourceLength > 0 &&
        output.length > sourceLength * kFFIPSMaxCompressionRatio) {
        if (bomb) *bomb = YES;
        return nil;
    }
    return output;
}

#pragma mark - Payload format probing

+ (NSString *)probePayloadFormat:(nullable NSData *)payload
{
    if (!payload || payload.length == 0) return @"text";
    if (payload.length >= 4 && memcmp(payload.bytes, "RHWN", 4) == 0)
        return @"RHWN";
    if (payload.length >= 8 && memcmp(payload.bytes, "bplist0", 7) == 0)
        return @"bplist";
    if (payload.length >= 2 && memcmp(payload.bytes, "PK", 2) == 0)
        return @"binary";
    FFContentKind kind = [FFContentProbe contentKindOfData:payload];
    switch (kind) {
        case FFContentKindJSON: return @"json";
        case FFContentKindXML: return @"xml";
        case FFContentKindTextUTF8:
        case FFContentKindTextUTF16: return @"text";
        default: return @"binary";
    }
}

@end
