#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 统一文本编解码：检测 BOM/编码/换行符，解码与编码双向映射。
// 保存时默认保持原编码/BOM/换行符；用户显式切换后按用户选择保存。
//
// 自动检测白名单：UTF-8 / UTF-8 BOM / UTF-16 LE / UTF-16 BE。
// Latin-1 只允许出现在「用户强制以文本打开」路径（forceEncoding）。
typedef NS_ENUM(NSInteger, FFTextEncoding) {
    FFTextEncodingUTF8 = 0,
    FFTextEncodingUTF8BOM,
    FFTextEncodingUTF16LE,
    FFTextEncodingUTF16BE,
    FFTextEncodingLatin1,
};

typedef NS_ENUM(NSInteger, FFLineEnding) {
    FFLineEndingLF = 0,
    FFLineEndingCRLF,
    FFLineEndingCR,
};

@interface FFTextCodec : NSObject

// 检测并解码。返回文本；无法判定为合法文本时返回 nil（不猜测、不 Latin-1 兜底）。
// 输出：检测出的编码、BOM 是否存在、检测出的换行符。
+ (nullable NSString *)decodeData:(NSData *)data
                         encoding:(FFTextEncoding *)outEncoding
                              bom:(BOOL *)outBOM
                       lineEnding:(FFLineEnding *)outLineEnding;

// 用户强制编码解码（Latin-1 仅此路径；该路径同样输出换行符检测）。
+ (nullable NSString *)decodeData:(NSData *)data
                   forcedEncoding:(FFTextEncoding)encoding
                        lineEnding:(FFLineEnding *)outLineEnding;

// 按指定编码/BOM/换行符编码。失败（目标编码无法表示）返回 nil。
+ (nullable NSData *)encodeString:(NSString *)string
                         encoding:(FFTextEncoding)encoding
                              bom:(BOOL)bom
                       lineEnding:(FFLineEnding)lineEnding;

// 换行符检测：优先检测全文第一个换行出现位置；CRLF>优先；无换行返回 LF。
+ (FFLineEnding)detectLineEndingOfString:(NSString *)string;

+ (NSString *)nameForEncoding:(FFTextEncoding)encoding;   // UI 文案
+ (NSString *)nameForLineEnding:(FFLineEnding)lineEnding;  // UI 文案

@end

NS_ASSUME_NONNULL_END
