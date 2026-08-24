#import "FFRHWNDecoder.h"

#include <inttypes.h>

static const NSUInteger kFFRHWNStringMinLength = 5;
static const NSUInteger kFFRHWNPreviewLength = 512;

@implementation FFRHWNDecoder

- (instancetype)initWithData:(NSData *)data
{
    self = [super init];
    if (self) {
        _isRHWN = data.length >= 4 && memcmp(data.bytes, "RHWN", 4) == 0;
        if (!_isRHWN) return self;

        _payloadSize = data.length;

        // 字符串提取：可打印 ASCII 连续段（0x20-0x7E 与 \t）。
        NSMutableArray<NSString *> *strings = [NSMutableArray array];
        const uint8_t *bytes = data.bytes;
        NSUInteger length = data.length;
        NSMutableString *run = [NSMutableString string];
        for (NSUInteger i = 0; i < length; i++) {
            uint8_t c = bytes[i];
            if (c == '\t' || (c >= 0x20 && c < 0x7F)) {
                [run appendFormat:@"%c", (char)c];
            } else {
                if (run.length >= kFFRHWNStringMinLength) [strings addObject:run];
                [run setString:@""];
            }
        }
        if (run.length >= kFFRHWNStringMinLength) [strings addObject:run];
        _printableStrings = strings;
        _asciiHeadPreview = [self asciiPreviewBytes:bytes length:length];

        // 版本字段没有公开分配：本实现不猜 offset、不猜含义。
        // 只有拿到官方或多样本验证的格式说明后才启用版本展示。
        _versionReliable = NO;
        _versionString = nil;
    }
    return self;
}

- (NSString *)asciiPreviewBytes:(const uint8_t *)bytes length:(NSUInteger)length
{
    NSUInteger n = MIN(length, kFFRHWNPreviewLength);
    NSMutableString *out = [NSMutableString stringWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        uint8_t c = bytes[i];
        if (c == '\t') [out appendString:@"  "];
        else if (c == '\n' || c == '\r') [out appendString:@"\n"];
        else if (c >= 0x20 && c < 0x7F) [out appendFormat:@"%c", (char)c];
        else [out appendString:@"·"];
    }
    if (length > kFFRHWNPreviewLength)
        [out appendString:@"\n…（仅显示前 512 字节预览）"];
    return [out copy];
}

@end
