#import "FFLocalShareBridge.h"
#import "FFShareBridge.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

static BOOL FFWriteAll(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (written == 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL FFReadAll(int fd, void *bytes, size_t length)
{
    uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t readCount = read(fd, cursor, length);
        if (readCount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (readCount == 0) return NO;
        cursor += readCount;
        length -= (size_t)readCount;
    }
    return YES;
}

static uint64_t FFHostToNetwork64(uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(value);
#else
    return value;
#endif
}

static int FFConnectLoopback(void)
{
    for (NSUInteger attempt = 0; attempt < 60; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(FFLocalShareBridgePort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0)
            return fd;
        close(fd);
        usleep(50000);
    }
    return -1;
}

BOOL FFLocalShareBridgeSendInbox(NSString *inboxPath, NSString *sessionID, NSString *token,
                                 NSUInteger *sentCount, NSError **error)
{
    if (sentCount) *sentCount = 0;
    if (!inboxPath.length || !sessionID.length || !token.length) {
        if (error) *error = [NSError errorWithDomain:@"FFLocalShareBridge" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"本地分享桥接参数无效"}];
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:inboxPath error:nil] ?: @[]) {
        if (![name hasSuffix:FFShareItemSuffix]) continue;
        NSString *itemDir = [inboxPath stringByAppendingPathComponent:name];
        NSString *payload = [itemDir stringByAppendingPathComponent:@"payload"];
        NSString *metadataPath = [itemDir stringByAppendingPathComponent:@"metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath] ?: @{};
        NSString *itemSession = [metadata[@"session"] isKindOfClass:NSString.class]
            ? metadata[@"session"] : nil;
        if (![itemSession isEqualToString:sessionID]) continue;

        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:payload isDirectory:&isDirectory] || isDirectory) continue;
        NSNumber *size = [fm attributesOfItemAtPath:payload error:nil][NSFileSize];
        if (!size) continue;
        NSString *displayName = [metadata[@"name"] isKindOfClass:NSString.class]
            ? [metadata[@"name"] lastPathComponent] : @"imported";
        NSString *type = [metadata[@"type"] isKindOfClass:NSString.class]
            ? metadata[@"type"] : @"public.data";
        [items addObject:@{@"dir": itemDir, @"payload": payload,
                           @"name": displayName.length ? displayName : @"imported",
                           @"type": type, @"size": size}];
    }

    if (items.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"FFLocalShareBridge" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"没有可直传的本次共享文件"}];
        return NO;
    }

    int fd = FFConnectLoopback();
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"FFLocalShareBridge" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"无法连接 FuckFile 本地导入服务"}];
        return NO;
    }

    struct timeval timeout = {.tv_sec = 8, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    const char magic[8] = {'F','F','S','H','A','R','E','1'};
    NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t tokenLength = htonl((uint32_t)tokenData.length);
    uint32_t count = htonl((uint32_t)items.count);
    BOOL ok = FFWriteAll(fd, magic, sizeof(magic)) &&
        FFWriteAll(fd, &tokenLength, sizeof(tokenLength)) &&
        FFWriteAll(fd, &count, sizeof(count)) &&
        FFWriteAll(fd, tokenData.bytes, tokenData.length);

    uint8_t buffer[64 * 1024];
    if (ok) {
        for (NSDictionary *item in items) {
            NSData *nameData = [item[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
            NSData *typeData = [item[@"type"] dataUsingEncoding:NSUTF8StringEncoding];
            uint32_t nameLength = htonl((uint32_t)nameData.length);
            uint32_t typeLength = htonl((uint32_t)typeData.length);
            uint64_t fileLength = FFHostToNetwork64([item[@"size"] unsignedLongLongValue]);
            ok = FFWriteAll(fd, &nameLength, sizeof(nameLength)) &&
                FFWriteAll(fd, &typeLength, sizeof(typeLength)) &&
                FFWriteAll(fd, &fileLength, sizeof(fileLength)) &&
                FFWriteAll(fd, nameData.bytes, nameData.length) &&
                FFWriteAll(fd, typeData.bytes, typeData.length);
            if (!ok) break;

            int input = open([item[@"payload"] fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
            if (input < 0) { ok = NO; break; }
            uint64_t remaining = [item[@"size"] unsignedLongLongValue];
            while (remaining > 0) {
                size_t wanted = (size_t)MIN((uint64_t)sizeof(buffer), remaining);
                ssize_t got = read(input, buffer, wanted);
                if (got < 0 && errno == EINTR) continue;
                if (got <= 0 || !FFWriteAll(fd, buffer, (size_t)got)) {
                    ok = NO;
                    break;
                }
                remaining -= (uint64_t)got;
            }
            close(input);
            if (!ok) break;
        }
    }

    uint32_t acknowledged = 0;
    if (ok && FFReadAll(fd, &acknowledged, sizeof(acknowledged))) {
        acknowledged = ntohl(acknowledged);
        ok = acknowledged == items.count;
    } else {
        ok = NO;
    }
    close(fd);

    if (!ok) {
        if (error) *error = [NSError errorWithDomain:@"FFLocalShareBridge" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"本地分享直传未被完整确认"}];
        return NO;
    }

    for (NSDictionary *item in items)
        [fm removeItemAtPath:item[@"dir"] error:nil];
    if (sentCount) *sentCount = items.count;
    return YES;
}
