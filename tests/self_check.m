// Core 逻辑自检：FFContentProbe / FFTextCodec。
// 在 macOS（CI runner）用系统 clang 编译运行：不需要 UIKit、不需要 theos。
//
//   clang -fobjc-arc -framework Foundation -lz -I src \
//     tests/self_check.m src/FFContentProbe.m src/FFTextCodec.m \
//     -o /tmp/ff_selfcheck && /tmp/ff_selfcheck
#import <Foundation/Foundation.h>
#import <zlib.h>

#import "FFContentProbe.h"
#import "FFTextCodec.h"

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
    // 检测 + 往返保持：decode 语义 = 原样解码，换行符由 detectLineEnding 报告。
    NSData *utf8 = DataFromText("line1\nline2\r\nline3\rline4", NSUTF8StringEncoding);
    FFTextEncoding enc = FFTextEncodingUTF8; BOOL bom = YES; FFLineEnding le = FFLineEndingLF;
    NSString *text = [FFTextCodec decodeData:utf8 encoding:&enc bom:&bom lineEnding:&le];
    CHECK([text isEqualToString:@"line1\nline2\r\nline3\rline4"], @"codec-crlf-identity");
    CHECK(le == FFLineEndingLF, @"codec-crlf-detect"); // 首个换行序列是 LF
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
    CHECK([round isEqualToString:@"a\r\nb\r\n"], @"codec-crlf-encode-roundtrip");
    CHECK(le == FFLineEndingCRLF, @"codec-crlf-encode-detect");

    NSData *bomData = [FFTextCodec encodeString:@"x\n" encoding:FFTextEncodingUTF16LE
        bom:YES lineEnding:FFLineEndingLF];
    CHECK(bomData.length >= 4 && ((uint8_t *)bomData.bytes)[0] == 0xFF
        && ((uint8_t *)bomData.bytes)[1] == 0xFE, @"codec-utf16le-bom");

    // Latin-1 反向编码：UTF-8 无法表达的字符在 Latin-1 合法。
    NSData *latinData = [FFTextCodec encodeString:@"café" encoding:FFTextEncodingLatin1
        bom:NO lineEnding:FFLineEndingLF];
    CHECK(latinData != nil, @"codec-latin1-encode");
}


int main(void)
{
    @autoreleasepool {
        testProbe();
        testCodec();
    }
    fprintf(stderr, "\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
