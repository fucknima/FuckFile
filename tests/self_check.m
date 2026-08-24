// Core 逻辑自检：FFContentProbe / FFTextCodec / FFIPSParser / FFRHWNDecoder。
// 在 macOS（CI runner）用系统 clang 编译运行：不需要 UIKit、不需要 theos。
//
//   clang -fobjc-arc -framework Foundation -lz -I src \
//     tests/self_check.m src/FFContentProbe.m src/FFTextCodec.m \
//     src/FFIPSParser.m src/FFRHWNDecoder.m \
//     -o /tmp/ff_selfcheck && /tmp/ff_selfcheck
#import <Foundation/Foundation.h>
#import <zlib.h>

#import "FFContentProbe.h"
#import "FFTextCodec.h"
#import "FFIPSParser.h"
#import "FFRHWNDecoder.h"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, name) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; fprintf(stderr, "FAIL: %s (%s:%d)\n", name, __FILE__, __LINE__); } \
} while (0)

static NSData *DataFromText(const char *text, NSStringEncoding enc)
{
    return [[NSString stringWithUTF8String:text] dataUsingEncoding:enc];
}

#pragma mark - Probe

static void testProbe(void)
{
    // UTF-8 文本（含中文）。
    NSData *utf8 = DataFromText("int main() { return 0; } // 注释\n", NSUTF8StringEncoding);
    CHECK([FFContentProbe isTextSample:utf8], @"utf8-is-text");
    CHECK([FFContentProbe contentKindOfData:utf8] == FFContentKindTextUTF8, @"utf8-kind");

    // UTF-8 BOM。
    NSMutableData *bomUtf8 = [DataFromText("hello\n", NSUTF8StringEncoding) mutableCopy];
    [bomUtf8 replaceBytesInRange:NSMakeRange(0, 0)
        withBytes:"\xEF\xBB\xBF" length:3];
    BOOL hasBOM = NO;
    NSString *encoding = [FFContentProbe detectedEncodingOfSample:bomUtf8 hasBOM:&hasBOM];
    CHECK([encoding isEqualToString:@"UTF-8"] && hasBOM, @"utf8-bom-detected");
    CHECK([FFContentProbe isTextSample:bomUtf8], @"utf8-bom-is-text");

    // UTF-16 LE with BOM（中文）。
    NSData *utf16le = [[NSString stringWithFormat:@"abc 中文\n"]
        dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    CHECK([FFContentProbe isTextSample:utf16le], @"utf16le-is-text");
    CHECK([FFContentProbe contentKindOfData:utf16le] == FFContentKindTextUTF16, @"utf16le-kind");

    // UTF-16 BE with BOM。
    NSData *utf16be = [[NSString stringWithFormat:@"abc 中文\n"]
        dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    CHECK([FFContentProbe isTextSample:utf16be], @"utf16be-is-text");

    // 无 BOM UTF-16（ASCII 内容 NUL 模式）。
    uint8_t rawUtf16[] = { 'h', 0, 'i', 0, 0, 0 }; // "hi\0" LE
    NSData *noBomUtf16 = [NSData dataWithBytes:rawUtf16 length:sizeof(rawUtf16)];
    CHECK([FFContentProbe isTextSample:noBomUtf16], @"utf16-no-bom-heuristic");

    // 随机二进制：NUL + 高字节 —— 不得判为文本。
    uint8_t binary[8192];
    for (size_t i = 0; i < sizeof(binary); i++) binary[i] = (uint8_t)(i * 37) ^ 0x55;
    binary[0] = 0; binary[1] = 1;
    NSData *randomBinary = [NSData dataWithBytes:binary length:sizeof(binary)];
    CHECK(![FFContentProbe isTextSample:randomBinary], @"random-binary-not-text");
    CHECK([FFContentProbe contentKindOfData:randomBinary] == FFContentKindBinary, @"random-binary-kind");

    // ZIP / SQLite / PNG magic。
    uint8_t zipMagic[] = {'P','K','\x03','\x04',0,0,0,0};
    CHECK([FFContentProbe contentKindOfData:[NSData dataWithBytes:zipMagic length:8]]
        == FFContentKindZIP, @"zip-kind");
    uint8_t sqliteMagic[] = "SQLite format 3\0";
    CHECK([FFContentProbe contentKindOfData:
        [NSData dataWithBytes:sqliteMagic length:17]] == FFContentKindSQLite, @"sqlite-kind");
    uint8_t pngMagic[] = {0x89,'P','N','G','\r','\n',0x1A,'\n',0,0,0,0};
    CHECK([FFContentProbe contentKindOfData:
        [NSData dataWithBytes:pngMagic length:12]] == FFContentKindBinary, @"png-kind-binary");

    // JSON / XML。
    NSData *json = DataFromText("{\"a\":1,\"b\":[1,2,3]}\n", NSUTF8StringEncoding);
    CHECK([FFContentProbe contentKindOfData:json] == FFContentKindJSON, @"json-kind");
    NSData *xml = DataFromText("<?xml version=\"1.0\"?><root><a/></root>\n", NSUTF8StringEncoding);
    CHECK([FFContentProbe contentKindOfData:xml] == FFContentKindXML, @"xml-kind");

    // Latin-1 类字节（高字节）不允许自动判为文本。
    uint8_t latin1ish[] = { 0x63, 0x61, 0x66, 0xE9, 0x20, 0x6D, 0x61, 0x6E, 0x0A };
    CHECK(![FFContentProbe isTextSample:
        [NSData dataWithBytes:latin1ish length:sizeof(latin1ish)]], @"latin1-not-auto-text");
}

#pragma mark - Codec

static void testCodec(void)
{
    // 检测 + 往返保持。
    NSData *utf8 = DataFromText("line1\nline2\r\nline3\rline4", NSUTF8StringEncoding);
    FFTextEncoding enc = FFTextEncodingUTF8; BOOL bom = YES; FFLineEnding le = FFLineEndingLF;
    NSString *text = [FFTextCodec decodeData:utf8 encoding:&enc bom:&bom lineEnding:&le];
    CHECK([text isEqualToString:@"line1\nline2\nline3\nline4"], @"codec-crlf-normalize");
    CHECK(le == FFLineEndingCRLF, @"codec-crlf-detect"); // 首个换行是 CRLF（两个混合时取第一组）
    CHECK(enc == FFTextEncodingUTF8 && bom == NO, @"codec-utf8-detect");

    // UTF-16 LE 往返。
    NSData *utf16le = [[NSString stringWithFormat:@"hello 中文\n"]
        dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    enc = FFTextEncodingUTF8; bom = NO; le = FFLineEndingLF;
    text = [FFTextCodec decodeData:utf16le encoding:&enc bom:&bom lineEnding:&le];
    CHECK([text isEqualToString:@"hello 中文\n"], @"codec-utf16le-decode");
    CHECK(le == FFLineEndingLF, @"codec-lf-detect");

    // UTF-16 BE 往返。
    NSData *utf16be = [[NSString stringWithFormat:@"hello 中文\n"]
        dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    text = [FFTextCodec decodeData:utf16be encoding:&enc bom:&bom lineEnding:&le];
    CHECK([text isEqualToString:@"hello 中文\n"], @"codec-utf16be-decode");

    // 任意二进制不能「解码成文本字符串」。
    uint8_t junk[64] = {0};
    for (int i = 0; i < 64; i++) junk[i] = (uint8_t)(i * 223);
    NSString *decoded = [FFTextCodec decodeData:[NSData dataWithBytes:junk length:64]
        encoding:&enc bom:&bom lineEnding:&le];
    CHECK(decoded == nil, @"codec-binary-decode-fails");

    // 用户强制 Latin-1 路径。
    uint8_t latin[3] = { 0xE9, 0x20, 0x41 };
    NSString *forced = [FFTextCodec decodeData:[NSData dataWithBytes:latin length:3]
        forcedEncoding:FFTextEncodingLatin1 lineEnding:&le];
    CHECK(forced != nil, @"codec-forced-latin1");

    // 编码保持：LF→CRLF 强制重排 + BOM 行为。
    NSData *crlfData = [FFTextCodec encodeString:@"a\nb\n" encoding:FFTextEncodingUTF8
        bom:NO lineEnding:FFLineEndingCRLF];
    NSString *round = [FFTextCodec decodeData:crlfData encoding:&enc bom:&bom lineEnding:&le];
    CHECK([round isEqualToString:@"a\nb\n"], @"codec-crlf-encode-roundtrip");

    NSData *bomData = [FFTextCodec encodeString:@"x\n" encoding:FFTextEncodingUTF16LE
        bom:YES lineEnding:FFLineEndingLF];
    CHECK(bomData.length >= 4 && ((uint8_t *)bomData.bytes)[0] == 0xFF
        && ((uint8_t *)bomData.bytes)[1] == 0xFE, @"codec-utf16le-bom");

    // Latin-1 反向编码：UTF-8 无法表达的字符在 Latin-1 合法。
    NSData *latinData = [FFTextCodec encodeString:@"café" encoding:FFTextEncodingLatin1
        bom:NO lineEnding:FFLineEndingLF];
    CHECK(latinData != nil, @"codec-latin1-encode");
}

#pragma mark - IPS

static NSData *MakeIPSDictionary(void)
{
    NSDictionary *header = @{
        @"bug_type": @"241",
        @"os_version": @"iPhone OS 27.0 (21A123)",
        @"custom_headers": @{
            @"stalls": @1,
            @"sender": @"CM-HLS",
            @"clientName": @"Twitter",
            @"type": @"ABRTrace",
            @"version": @"3",
            @"compression": @"zlib",
        },
    };
    return [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
}

static NSData *CompressZlib(NSData *input, int windowBits)
{
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY);
    NSMutableData *out = [NSMutableData dataWithLength:
        compressBound((uLong)input.length) + input.length + 64];
    stream.next_in = (Bytef *)(uintptr_t)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = out.mutableBytes;
    stream.avail_out = (uInt)out.length;
    deflate(&stream, Z_FINISH);
    deflateEnd(&stream);
    out.length = stream.total_out;
    return out;
}

static void testIPS(void)
{
    // A. 纯 JSON（无 payload）。
    NSData *plain = MakeIPSDictionary();
    FFIPSParseResult *result = [FFIPSParser parseData:plain];
    CHECK(result.status == FFIPSStatusOK, @"ips-plain-json");
    CHECK([result.header[@"bug_type"] isEqualToString:@"241"], @"ips-header-bugtype");
    CHECK(!result.hasPayload, @"ips-no-payload");

    // B. JSON + zlib payload。
    NSData *payload = [NSData dataWithBytes:"RHWN\x00\x01\x02hello, world! this is the payload content with text."
                                     length:60];
    NSMutableData *withZlib = [plain mutableCopy];
    NSData *zlibPayload = CompressZlib(payload, MAX_WBITS);
    [withZlib appendData:zlibPayload];
    result = [FFIPSParser parseData:withZlib];
    CHECK(result.status == FFIPSStatusOK, @"ips-zlib-ok");
    CHECK(result.actualCompression == FFIPSCompressionZlib, @"ips-zlib-actual");
    CHECK(result.isRHWN, @"ips-rhwn-detected");
    CHECK(result.payload.length == 60, @"ips-payload-size");
    FFRHWNDecoder *rhwn = [[FFRHWNDecoder alloc] initWithData:result.payload];
    CHECK(rhwn.isRHWN, @"rhwn-magic");
    CHECK(rhwn.printableStrings.count >= 1, @"rhwn-strings");

    // C. JSON + RAW DEFLATE payload（元数据声称 zlib，实际 raw）。
    NSMutableData *withRaw = [plain mutableCopy];
    NSData *rawPayload = CompressZlib(payload, -MAX_WBITS);
    [withRaw appendData:rawPayload];
    result = [FFIPSParser parseData:withRaw];
    CHECK(result.status == FFIPSStatusOK, @"ips-rawdeflate-ok");
    CHECK(result.actualCompression == FFIPSCompressionRawDeflate, @"ips-rawdeflate-actual");

    // D. 截断 / 损坏：Header 正确，payload 坏。
    NSMutableData *corrupt = [withZlib mutableCopy];
    uint8_t *bytes = corrupt.mutableBytes;
    bytes[corrupt.length - 10] ^= 0xFF;
    result = [FFIPSParser parseData:corrupt];
    CHECK(result.status == FFIPSStatusDecompressFailed ||
          result.status == FFIPSStatusOK, @"ips-corrupt-handled");

    // Header 存在但根本不可解析。
    NSData *truncatedHeader = [plain subdataWithRange:NSMakeRange(0, 10)];
    result = [FFIPSParser parseData:truncatedHeader];
    CHECK(result.status == FFIPSStatusNotIPS, @"ips-truncated-header");

    // 非 IPS 垃圾。
    NSData *garbage = [NSData dataWithBytes:"\x00\x01\x02\x03\x04\x05\x06\x07" length:8];
    result = [FFIPSParser parseData:garbage];
    CHECK(result.status == FFIPSStatusNotIPS, @"ips-garbage");

    // E. 超高压缩比炸弹：高比率压缩输入 → 解压超过 64MB/256:1 上限。
    NSData *compressed = CompressZlib([NSMutableData dataWithLength:128 * 1024 * 1024], MAX_WBITS); // high ratio zeros
    NSMutableData *bombIPS = [plain mutableCopy];
    [bombIPS appendData:compressed];
    result = [FFIPSParser parseData:bombIPS];
    CHECK(result.status == FFIPSStatusOK ||
          result.status == FFIPSStatusDecompressBomb ||
          result.status == FFIPSStatusDecompressFailed, @"ips-bomb-never-crashed");

    // header 边界扫描：带转义字符串的 JSON。
    NSMutableData *tricky = [plain mutableCopy];
    [tricky appendData:[@"{\"a\":\"}\"}" dataUsingEncoding:NSUTF8StringEncoding]];
    long long end = [FFIPSParser headerJSONEndOffset:tricky];
    CHECK(end == (long long)plain.length, @"ips-header-scan-escapes");
}

static void testHeaderScan(void)
{
    NSData *simple = [@"{\"a\":1}" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([FFIPSParser headerJSONEndOffset:simple] == 8, @"ips-scan-simple");
    NSData *escaped = [@"{\"x\":\"{\\\"y\\\"}\"}" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([FFIPSParser headerJSONEndOffset:escaped] == (long long)escaped.length, @"ips-scan-escaped");
    CHECK([FFIPSParser headerJSONEndOffset:[@"not json" dataUsingEncoding:NSUTF8StringEncoding]] == -1, @"ips-scan-reject");
}

int main(void)
{
    @autoreleasepool {
        testProbe();
        testCodec();
        testHeaderScan();
        testIPS();
    }
    fprintf(stderr, "\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
