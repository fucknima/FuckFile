// Core 逻辑自检：FFContentProbe / FFTextCodec / 搜索会话 / 回收站 / 批量重命名。
// 在 macOS（CI runner）用系统 clang 编译运行：不需要 UIKit、不需要 theos。
//
//   clang -fobjc-arc -framework Foundation -lz -I src \
//     tests/self_check.m src/FFContentProbe.m src/FFTextCodec.m \
//     src/FFTrashService.m src/FFBatchRename.m \
//     -o /tmp/ff_selfcheck && /tmp/ff_selfcheck
#import <Foundation/Foundation.h>
#import <zlib.h>

#import "FFContentProbe.h"
#import "FFTextCodec.h"
#import "FFSearchSession.h"
#import "FFBatchRename.h"
#import "FFTrashService.h"

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


#pragma mark - SearchSession（Prev/Next 镜像一致性）

static FFSearchSession *MakeSearch(NSString *text, NSString *query, BOOL regex, BOOL cs)
{
    FFSearchSession *session = [[FFSearchSession alloc] initWithInitialText:text];
    [session setQuery:query regexEnabled:regex caseSensitive:cs];
    [session refreshNow];
    return session;
}

static BOOL SessionHasRanges(FFSearchSession *session, NSUInteger *locs, NSUInteger count)
{
    if (session.matchCount != count) return NO;
    for (NSUInteger i = 0; i < count; i++) {
        NSRange r = [session.matches[i] rangeValue];
        if (r.location != locs[i]) return NO;
    }
    return YES;
}

static void testSearchSessionMirror(void)
{
    // matches = [A, B]（"aa bb aa"：0-2 与 6-8）。
    FFSearchSession *s = MakeSearch(@"aa bb aa", @"aa", NO, YES);
    NSUInteger two[2] = {0, 6};
    CHECK(SessionHasRanges(s, two, 2), @"session-two-matches");

    // Next: A → B → A → B
    [s navigateNext];
    CHECK(s.currentRange.location == 0 && s.currentIndex == 0, @"next-A");
    [s navigateNext];
    CHECK(s.currentRange.location == 6 && s.currentIndex == 1, @"next-B");
    [s navigateNext];
    CHECK(s.currentRange.location == 0 && s.currentIndex == 0, @"next-wrap-A");
    [s navigateNext];
    CHECK(s.currentRange.location == 6 && s.currentIndex == 1, @"next-wrap-B");

    // Previous: B → A → B → A（从未选中开始：直接到最后一个）
    FFSearchSession *p = MakeSearch(@"aa bb aa", @"aa", NO, YES);
    [p navigatePrevious];
    CHECK(p.currentRange.location == 6 && p.currentIndex == 1, @"prev-初始-最后");
    [p navigatePrevious];
    CHECK(p.currentRange.location == 0 && p.currentIndex == 0, @"prev-A");
    [p navigatePrevious];
    CHECK(p.currentRange.location == 6 && p.currentIndex == 1, @"prev-wrap-B");
    [p navigatePrevious];
    CHECK(p.currentRange.location == 0 && p.currentIndex == 0, @"prev-wrap-A");

    // 交叉：A →next B →prev A →prev B →next A（fresh session）
    FFSearchSession *x = MakeSearch(@"aa bb aa", @"aa", NO, YES);
    [x navigateNext];                       // A
    [x navigateNext];                       // B
    [x navigatePrevious];                   // A
    [x navigatePrevious];                   // B (wrap)
    [x navigateNext];                       // A (wrap)
    CHECK(x.currentRange.location == 0 && x.currentIndex == 0, @"cross-final-A");

    // 1 个结果：Next/Previous 永远停留同一结果。
    FFSearchSession *one = MakeSearch(@"xx yy", @"xx", NO, YES);
    [one navigateNext];
    [one navigateNext];
    CHECK(one.currentRange.location == 0, @"single-stay");
    [one navigatePrevious];
    CHECK(one.currentRange.location == 0, @"single-stay-prev");

    // 3 个结果：Next A B C A；Previous（fresh）→ C B A C。
    FFSearchSession *three = MakeSearch(@"a b a b a b", @"a", NO, YES);
    NSUInteger threeLocs[3] = {0, 4, 8};
    CHECK(SessionHasRanges(three, threeLocs, 3), @"three-matches");
    [three navigateNext]; CHECK(three.currentIndex == 0 && three.currentRange.location == 0, @"3-next-A");
    [three navigateNext]; CHECK(three.currentIndex == 1 && three.currentRange.location == 4, @"3-next-B");
    [three navigateNext]; CHECK(three.currentIndex == 2 && three.currentRange.location == 8, @"3-next-C");
    [three navigateNext]; CHECK(three.currentIndex == 0 && three.currentRange.location == 0, @"3-next-wrap-A");
    FFSearchSession *threeP = MakeSearch(@"a b a b a b", @"a", NO, YES);
    [threeP navigatePrevious]; CHECK(threeP.currentIndex == 2 && threeP.currentRange.location == 8, @"3-prev-init-C");
    [threeP navigatePrevious]; CHECK(threeP.currentIndex == 1 && threeP.currentRange.location == 4, @"3-prev-B");
    [threeP navigatePrevious]; CHECK(threeP.currentIndex == 0 && threeP.currentRange.location == 0, @"3-prev-A");

    // 快速交替：Next Next Previous Next Previous Previous → index/range 恒一致。
    FFSearchSession *rapid = MakeSearch(@"a b a b a b", @"a", NO, YES);
    NSInteger sequence[] = {1, 1, -1, 1, -1, -1};
    for (NSUInteger i = 0; i < 6; i++) {
        if (sequence[i] > 0) [rapid navigateNext]; else [rapid navigatePrevious];
        CHECK(rapid.currentIndex >= 0 && rapid.currentIndex < (NSInteger)rapid.matchCount &&
              NSEqualRanges(rapid.currentRange, [rapid.matches[rapid.currentIndex] rangeValue]),
              @"rapid-consistency");
    }

    // 无命中：导航 no-op，不越界。
    FFSearchSession *empty = MakeSearch(@"abc", @"zzz", NO, YES);
    CHECK(empty.state == FFSearchSessionStateEmpty && empty.matchCount == 0, @"empty-state");
    [empty navigateNext];
    CHECK(empty.currentIndex == -1, @"empty-next-noop");
    [empty navigatePrevious];
    CHECK(empty.currentIndex == -1, @"empty-prev-noop");

    // 索引修复：正文变化后按旧 currentRange 就近修复（不再沿用旧下标）。
    FFSearchSession *repair = MakeSearch(@"aaa bbb ccc", @"aaa", NO, YES);
    [repair navigateNext]; // index 0 (loc 0)
    [repair setSearchText:@"bbb ccc aaa"];
    [repair refreshNow];
    CHECK(repair.matchCount == 1 && repair.currentRange.location == 8 &&
          repair.currentIndex == 0, @"repair-nearest");
}


#pragma mark - Trash

static NSString *TrashTestRoot(void)
{
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ff-trash-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:root
        withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static void testTrash(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *sandbox = TrashTestRoot();
    NSString *trashRoot = [sandbox stringByAppendingPathComponent:@".Trash"];
    FFTrashService *service = [[FFTrashService alloc] initWithTrashRoot:trashRoot];

    NSString *file = [sandbox stringByAppendingPathComponent:@"note.txt"];
    [@"hello" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *folder = [sandbox stringByAppendingPathComponent:@"folder"];
    [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [@"inner" writeToFile:[folder stringByAppendingPathComponent:@"inner.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSError *error = nil;
    NSUInteger moved = [service moveToTrash:@[file, folder] firstError:&error];
    CHECK(moved == 2 && error == nil, @"trash-move-count");
    CHECK(![fm fileExistsAtPath:file] && ![fm fileExistsAtPath:folder], @"trash-source-gone");

    NSArray<FFTrashEntry *> *entries = [service entries];
    CHECK(entries.count == 2, @"trash-entry-count");
    FFTrashEntry *fileEntry = nil, *folderEntry = nil;
    for (FFTrashEntry *entry in entries) {
        if ([entry.name isEqualToString:@"note.txt"]) fileEntry = entry;
        if ([entry.name isEqualToString:@"folder"]) folderEntry = entry;
    }
    CHECK(fileEntry != nil && !fileEntry.isDirectory && fileEntry.size == 5, @"trash-file-metadata");
    CHECK(folderEntry != nil && folderEntry.isDirectory, @"trash-folder-metadata");
    CHECK([fileEntry.originalPath isEqualToString:file], @"trash-original-path");
    CHECK([fm fileExistsAtPath:fileEntry.payloadPath], @"trash-payload-present");

    // Trash root itself must never be trashable.
    CHECK([service moveToTrash:@[trashRoot] firstError:NULL] == 0, @"trash-refuses-trash-root");

    NSString *restored = nil;
    error = nil;
    CHECK([service restoreEntry:fileEntry restoredPath:&restored error:&error], @"trash-restore-ok");
    CHECK([restored isEqualToString:file] && [fm fileExistsAtPath:file], @"trash-restored-in-place");
    CHECK([service entries].count == 1, @"trash-entry-count-after-restore");

    // Restore again with a name collision keeps both files.
    [fm removeItemAtPath:file error:nil];
    CHECK([service moveToTrash:@[file] firstError:NULL] == 0, @"trash-missing-source-skipped");

    NSString *second = [sandbox stringByAppendingPathComponent:@"again.txt"];
    [@"x" writeToFile:second atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [service moveToTrash:@[second] firstError:NULL];
    [@"y" writeToFile:second atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [service moveToTrash:@[second] firstError:NULL];
    FFTrashEntry *newest = [service entries].firstObject;
    NSString *target = nil;
    error = nil;
    CHECK([service restoreEntry:newest restoredPath:&target error:&error], @"trash-restore-collision-ok");
    CHECK([target.lastPathComponent hasPrefix:@"again"], @"trash-collision-name-kept");
    CHECK(![target isEqualToString:second] && [fm fileExistsAtPath:second],
        @"trash-collision-did-not-overwrite");
    CHECK([fm fileExistsAtPath:target], @"trash-collision-restored-file-exists");

    NSUInteger beforeEmpty = [service itemCount];
    error = nil;
    NSUInteger emptied = [service emptyWithError:&error];
    CHECK(error == nil && emptied == beforeEmpty, @"trash-empty-count");
    CHECK([service itemCount] == 0, @"trash-empty-clears");

    [fm removeItemAtPath:sandbox error:nil];
}

#pragma mark - Batch rename

static void testBatchRename(void)
{
    NSString *error = nil;

    // 查找替换保留扩展名。
    NSArray<NSString *> *replaced = [FFBatchRename newNamesForNames:
        @[@"IMG_001.jpg", @"IMG_002.jpg"]
        mode:FFBatchRenameModeReplace find:@"IMG" replace:@"照片" caseSensitive:NO
        prefix:nil suffix:nil sequencePrefix:nil start:1 digits:3 error:&error];
    CHECK([replaced isEqualToArray:@[@"照片_001.jpg", @"照片_002.jpg"]], @"rename-replace");

    // 前缀/后缀作用于主体名。
    error = nil;
    NSArray<NSString *> *affixed = [FFBatchRename newNamesForNames:@[@"a.txt", @"b"]
        mode:FFBatchRenameModeAffix find:nil replace:nil caseSensitive:NO
        prefix:@"新_" suffix:@"_终" sequencePrefix:nil start:1 digits:3 error:&error];
    CHECK([affixed isEqualToArray:@[@"新_a_终.txt", @"新_b_终"]], @"rename-affix");

    // 序号命名。
    error = nil;
    NSArray<NSString *> *sequenced = [FFBatchRename newNamesForNames:@[@"a.txt", @"b.txt"]
        mode:FFBatchRenameModeSequence find:nil replace:nil caseSensitive:NO
        prefix:nil suffix:nil sequencePrefix:@"文档_" start:7 digits:3 error:&error];
    CHECK([sequenced isEqualToArray:@[@"文档_007.txt", @"文档_008.txt"]], @"rename-sequence");

    // 大小写不敏感的重名必须拒绝。
    error = nil;
    CHECK([FFBatchRename newNamesForNames:@[@"a.txt", @"A.txt"]
        mode:FFBatchRenameModeAffix find:nil replace:nil caseSensitive:NO
        prefix:@"x" suffix:nil sequencePrefix:nil start:1 digits:3 error:&error] == nil &&
        error.length > 0, @"rename-duplicate-rejected");

    // 非法字符拒绝。
    error = nil;
    CHECK([FFBatchRename newNamesForNames:@[@"a.txt"]
        mode:FFBatchRenameModeReplace find:@"a" replace:@"b/c" caseSensitive:NO
        prefix:nil suffix:nil sequencePrefix:nil start:1 digits:3 error:&error] == nil,
        @"rename-invalid-char-rejected");

    // 无变化视为错误（避免误操作）。
    error = nil;
    CHECK([FFBatchRename newNamesForNames:@[@"a.txt"]
        mode:FFBatchRenameModeReplace find:@"zzz" replace:@"" caseSensitive:NO
        prefix:nil suffix:nil sequencePrefix:nil start:1 digits:3 error:&error] == nil,
        @"rename-noop-rejected");
}

int main(void)
{
    @autoreleasepool {
        testProbe();
        testCodec();
        testSearchSessionMirror();
        testTrash();
        testBatchRename();
    }
    fprintf(stderr, "\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
