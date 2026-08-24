#import "FFLocalShareBridge.h"
#import "FFImportService.h"
#import "FFStorageEnvironment.h"
#import "FFLogger.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static BOOL FFReadAllServer(int fd, void *bytes, size_t length)
{
    uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t got = read(fd, cursor, length);
        if (got < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (got == 0) return NO;
        cursor += got;
        length -= (size_t)got;
    }
    return YES;
}

static BOOL FFWriteAllServer(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t wrote = write(fd, cursor, length);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (wrote == 0) return NO;
        cursor += wrote;
        length -= (size_t)wrote;
    }
    return YES;
}

static uint64_t FFNetworkToHost64(uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(value);
#else
    return value;
#endif
}

static NSError *FFBridgeError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"FFLocalShareBridge" code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"本地分享桥接失败"}];
}

@implementation FFLocalShareBridgeServer {
    dispatch_queue_t _queue;
    NSUInteger _generation;
}

+ (instancetype)sharedServer
{
    static FFLocalShareBridgeServer *server;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ server = [FFLocalShareBridgeServer new]; });
    return server;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _queue = dispatch_queue_create("ff.local-share-server", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)prepareForToken:(NSString *)token
          expectedCount:(NSUInteger)expectedCount
             completion:(void (^)(NSUInteger, NSArray<NSString *> *, NSArray<NSError *> *))completion
{
    if (!token.length) {
        if (completion) completion(0, @[], @[FFBridgeError(10, @"分享握手缺少 token")]);
        return;
    }

    @synchronized (self) { _generation++; }
    NSUInteger generation = _generation;
    dispatch_async(_queue, ^{
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        if (listener < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, @[], @[FFBridgeError(11, @"无法创建本地导入监听")]);
            });
            return;
        }
        int reuse = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(FFLocalShareBridgePort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
            listen(listener, 1) != 0) {
            close(listener);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, @[], @[FFBridgeError(12, @"本地导入端口被占用")]);
            });
            return;
        }

        fd_set set;
        FD_ZERO(&set);
        FD_SET(listener, &set);
        struct timeval wait = {.tv_sec = 5, .tv_usec = 0};
        int selected = select(listener + 1, &set, NULL, NULL, &wait);
        if (selected <= 0) {
            close(listener);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, @[], @[FFBridgeError(13, @"等待分享扩展连接超时")]);
            });
            return;
        }

        int client = accept(listener, NULL, NULL);
        close(listener);
        if (client < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(0, @[], @[FFBridgeError(14, @"接受本地分享连接失败")]);
            });
            return;
        }
        struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        NSMutableArray<NSString *> *destinations = [NSMutableArray array];
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        BOOL ok = YES;
        char magic[8] = {0};
        uint32_t tokenLengthNetwork = 0, countNetwork = 0;
        ok = FFReadAllServer(client, magic, sizeof(magic)) &&
            memcmp(magic, "FFSHARE1", 8) == 0 &&
            FFReadAllServer(client, &tokenLengthNetwork, sizeof(tokenLengthNetwork)) &&
            FFReadAllServer(client, &countNetwork, sizeof(countNetwork));
        uint32_t tokenLength = ntohl(tokenLengthNetwork);
        uint32_t count = ntohl(countNetwork);
        if (!ok || tokenLength == 0 || tokenLength > 4096 || count == 0 || count > 64) ok = NO;

        NSMutableData *tokenData = ok ? [NSMutableData dataWithLength:tokenLength] : nil;
        if (ok) ok = FFReadAllServer(client, tokenData.mutableBytes, tokenLength);
        NSString *receivedToken = ok
            ? [[NSString alloc] initWithData:tokenData encoding:NSUTF8StringEncoding] : nil;
        if (!ok || ![receivedToken isEqualToString:token]) ok = NO;
        if (expectedCount > 0 && ok && count != expectedCount)
            FFLogTag(@"ShareBridge", @"count differs wake=%lu stream=%u",
                (unsigned long)expectedCount, count);

        NSString *incomingRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"FFShareBridge-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (ok) [NSFileManager.defaultManager createDirectoryAtPath:incomingRoot
            withIntermediateDirectories:YES attributes:nil error:nil];

        uint8_t buffer[64 * 1024];
        for (uint32_t index = 0; ok && index < count; index++) {
            uint32_t nameLengthNetwork = 0, typeLengthNetwork = 0;
            uint64_t dataLengthNetwork = 0;
            ok = FFReadAllServer(client, &nameLengthNetwork, sizeof(nameLengthNetwork)) &&
                FFReadAllServer(client, &typeLengthNetwork, sizeof(typeLengthNetwork)) &&
                FFReadAllServer(client, &dataLengthNetwork, sizeof(dataLengthNetwork));
            uint32_t nameLength = ntohl(nameLengthNetwork);
            uint32_t typeLength = ntohl(typeLengthNetwork);
            uint64_t dataLength = FFNetworkToHost64(dataLengthNetwork);
            if (!ok || nameLength == 0 || nameLength > 4096 || typeLength > 4096 ||
                dataLength > (uint64_t)8 * 1024 * 1024 * 1024) { ok = NO; break; }

            NSMutableData *nameData = [NSMutableData dataWithLength:nameLength];
            NSMutableData *typeData = [NSMutableData dataWithLength:typeLength];
            ok = FFReadAllServer(client, nameData.mutableBytes, nameLength) &&
                (typeLength == 0 || FFReadAllServer(client, typeData.mutableBytes, typeLength));
            NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding].lastPathComponent;
            if (!name.length) name = @"imported";
            NSString *tempPath = [incomingRoot stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%u-%@", index, name]];
            [[NSFileManager defaultManager] createFileAtPath:tempPath contents:nil attributes:nil];
            int output = open(tempPath.fileSystemRepresentation, O_WRONLY | O_TRUNC | O_CLOEXEC);
            if (output < 0) { ok = NO; break; }

            uint64_t remaining = dataLength;
            while (remaining > 0) {
                size_t wanted = (size_t)MIN((uint64_t)sizeof(buffer), remaining);
                if (!FFReadAllServer(client, buffer, wanted) || !FFWriteAllServer(output, buffer, wanted)) {
                    ok = NO;
                    break;
                }
                remaining -= wanted;
            }
            close(output);
            if (!ok) break;

            FFImportResult *result = [FFImportService
                importURL:[NSURL fileURLWithPath:tempPath]
                displayName:name
                toDirectory:FFImportedDirectoryPath()];
            if (result.success) {
                if (result.destinationPath) [destinations addObject:result.destinationPath];
            } else {
                [errors addObject:result.error ?: FFBridgeError(15, @"导入共享文件失败")];
                ok = NO;
                break;
            }
        }

        uint32_t ack = htonl(ok ? (uint32_t)destinations.count : 0);
        FFWriteAllServer(client, &ack, sizeof(ack));
        close(client);
        [NSFileManager.defaultManager removeItemAtPath:incomingRoot error:nil];

        if (!ok && errors.count == 0) [errors addObject:FFBridgeError(16, @"共享数据流中断或格式无效")];
        FFLogTag(@"ShareBridge", @"loopback receive generation=%lu imported=%lu errors=%lu",
            (unsigned long)generation, (unsigned long)destinations.count, (unsigned long)errors.count);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(destinations.count, destinations.copy, errors.copy);
        });
    });
}

@end
