#import "FFWebDAVServer.h"
#import "FFLogger.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FFWebDAVServerDidChangeNotification =
    @"FFWebDAVServerDidChangeNotification";

static const NSUInteger kFFWebDAVMaxHeaderBytes = 64 * 1024;
static const unsigned long long kFFWebDAVMaxUploadBytes = 8ULL * 1024 * 1024 * 1024;

@interface FFWebDAVRequest : NSObject
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSString *target;
@property(nonatomic, strong) NSDictionary<NSString *, NSString *> *headers;
@property(nonatomic, strong) NSData *bodyPrefix;
@property(nonatomic) unsigned long long contentLength;
@end
@implementation FFWebDAVRequest @end

static BOOL FFWriteAllFD(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t wrote = write(fd, cursor, length);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return NO;
        cursor += wrote;
        length -= (size_t)wrote;
    }
    return YES;
}

static NSString *FFHTTPDate(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
    });
    @synchronized (formatter) { return [formatter stringFromDate:date ?: NSDate.date]; }
}

static NSString *FFXMLEscape(NSString *value)
{
    if (!value) return @"";
    NSMutableString *result = [value mutableCopy];
    [result replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, result.length)];
    return result;
}

static NSString *FFHTMLEscape(NSString *value)
{
    return FFXMLEscape(value);
}

static NSString *FFPercentPath(NSString *path, BOOL directory)
{
    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *encoded = [NSMutableArray arrayWithCapacity:components.count];
    NSCharacterSet *allowed = [NSCharacterSet URLPathAllowedCharacterSet];
    for (NSString *part in components) {
        if (!part.length) { [encoded addObject:@""]; continue; }
        [encoded addObject:[part stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: part];
    }
    NSString *result = [encoded componentsJoinedByString:@"/"];
    if (![result hasPrefix:@"/"]) result = [@"/" stringByAppendingString:result];
    if (directory && ![result hasSuffix:@"/"]) result = [result stringByAppendingString:@"/"];
    return result;
}

static NSString *FFWiFiIPv4Address(void)
{
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;
    NSString *answer = nil;
    for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(cursor->ifa_name, "en0") != 0) continue;
        if (!(cursor->ifa_flags & IFF_UP) || !(cursor->ifa_flags & IFF_RUNNING)) continue;
        char buffer[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *address = (struct sockaddr_in *)cursor->ifa_addr;
        if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer))) {
            answer = [NSString stringWithUTF8String:buffer];
            break;
        }
    }
    freeifaddrs(interfaces);
    return answer;
}

static BOOL FFPathInsideRoot(NSString *path, NSString *root)
{
    if ([path isEqualToString:root]) return YES;
    return [path hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSString *FFRealPath(NSString *path)
{
    char resolved[PATH_MAX] = {0};
    if (!realpath(path.fileSystemRepresentation, resolved)) return nil;
    return [NSString stringWithUTF8String:resolved];
}

@interface FFWebDAVServer () {
    int _listenerFD;
    NSUInteger _generation;
}
@property(nonatomic) BOOL running;
@property(nonatomic, copy) NSString *addressString;
@property(nonatomic, copy) NSString *rootPath;
@property(nonatomic, copy) NSString *realRootPath;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *password;
@property(nonatomic) uint16_t port;
@property(nonatomic, strong) dispatch_queue_t acceptQueue;
@end

@implementation FFWebDAVServer

+ (instancetype)sharedServer
{
    static FFWebDAVServer *server;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ server = [FFWebDAVServer new]; });
    return server;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _listenerFD = -1;
        _acceptQueue = dispatch_queue_create("ff.webdav.accept", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message
{
    return [NSError errorWithDomain:@"FFWebDAVServer" code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"局域网文件共享失败"}];
}

- (BOOL)startWithRoot:(NSString *)rootPath
             username:(NSString *)username
             password:(NSString *)password
                 port:(uint16_t)port
                error:(NSError **)error
{
    if (error) *error = nil;
    [self stop];

    NSString *realRoot = FFRealPath(rootPath);
    BOOL isDirectory = NO;
    if (!realRoot.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:realRoot isDirectory:&isDirectory] ||
        !isDirectory) {
        if (error) *error = [self errorWithCode:1 message:@"共享目录不存在或无法访问"];
        return NO;
    }
    if (!username.length || !password.length) {
        if (error) *error = [self errorWithCode:2 message:@"WebDAV 必须设置用户名和密码"];
        return NO;
    }
    if (port == 0) {
        if (error) *error = [self errorWithCode:3 message:@"端口无效"];
        return NO;
    }

    NSString *ip = FFWiFiIPv4Address();
    if (!ip.length) {
        if (error) *error = [self errorWithCode:4 message:@"未检测到 Wi‑Fi IPv4 地址；局域网共享只在 Wi‑Fi 下启用"];
        return NO;
    }

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        if (error) *error = [self errorWithCode:5 message:@"无法创建共享监听端口"];
        return NO;
    }
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (inet_pton(AF_INET, ip.UTF8String, &address.sin_addr) != 1 ||
        bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listener, 16) != 0) {
        int saved = errno;
        close(listener);
        if (error) *error = [self errorWithCode:saved
            message:[NSString stringWithFormat:@"无法监听 %@:%u：%s", ip, port, strerror(saved)]];
        return NO;
    }

    @synchronized (self) {
        _generation++;
        _listenerFD = listener;
        self.rootPath = rootPath.stringByStandardizingPath;
        self.realRootPath = realRoot;
        self.username = username;
        self.password = password;
        self.port = port;
        self.addressString = [NSString stringWithFormat:@"http://%@:%u/", ip, port];
        self.running = YES;
    }
    [self postChanged];

    NSUInteger generation = _generation;
    dispatch_async(self.acceptQueue, ^{
        [self acceptLoopForGeneration:generation listener:listener];
    });
    FFLogTag(@"WebDAV", @"started %@ root=%@", self.addressString, self.rootPath);
    return YES;
}

- (void)stop
{
    int fd = -1;
    @synchronized (self) {
        _generation++;
        fd = _listenerFD;
        _listenerFD = -1;
        self.running = NO;
        self.addressString = nil;
        self.password = nil;
    }
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
        [self postChanged];
        FFLogTag(@"WebDAV", @"stopped");
    }
}

- (void)postChanged
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFWebDAVServerDidChangeNotification object:self];
    });
}

- (void)acceptLoopForGeneration:(NSUInteger)generation listener:(int)listener
{
    while (YES) {
        @synchronized (self) {
            if (!self.running || generation != _generation || listener != _listenerFD) break;
        }
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        struct timeval timeout = {.tv_sec = 30, .tv_usec = 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handleClient:client generation:generation];
            close(client);
        });
    }
}

- (FFWebDAVRequest *)readRequestFromFD:(int)fd
{
    NSMutableData *data = [NSMutableData data];
    const uint8_t delimiter[] = {'\r','\n','\r','\n'};
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    uint8_t buffer[8192];

    while (data.length < kFFWebDAVMaxHeaderBytes) {
        ssize_t got = read(fd, buffer, sizeof(buffer));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return nil;
        [data appendBytes:buffer length:(NSUInteger)got];
        headerEnd = [data rangeOfData:[NSData dataWithBytes:delimiter length:4]
                              options:0 range:NSMakeRange(0, data.length)];
        if (headerEnd.location != NSNotFound) break;
    }
    if (headerEnd.location == NSNotFound) return nil;

    NSUInteger bodyOffset = NSMaxRange(headerEnd);
    NSData *headerData = [data subdataWithRange:NSMakeRange(0, headerEnd.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (!headerText.length) return nil;
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count < 2) return nil;

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length) headers[key] = value ?: @"";
    }

    unsigned long long contentLength = 0;
    NSString *length = headers[@"content-length"];
    if (length.length) {
        NSScanner *scanner = [NSScanner scannerWithString:length];
        if (![scanner scanUnsignedLongLong:&contentLength] || !scanner.isAtEnd ||
            contentLength > kFFWebDAVMaxUploadBytes)
            return nil;
    }

    FFWebDAVRequest *request = [FFWebDAVRequest new];
    request.method = [requestLine[0] uppercaseString];
    request.target = requestLine[1];
    request.headers = headers;
    request.contentLength = contentLength;
    request.bodyPrefix = data.length > bodyOffset
        ? [data subdataWithRange:NSMakeRange(bodyOffset, data.length - bodyOffset)]
        : NSData.data;
    return request;
}

- (BOOL)isAuthorized:(FFWebDAVRequest *)request
{
    NSString *authorization = request.headers[@"authorization"];
    if (![authorization hasPrefix:@"Basic "]) return NO;
    NSString *raw = [NSString stringWithFormat:@"%@:%@", self.username ?: @"", self.password ?: @""];
    NSString *expected = [[raw dataUsingEncoding:NSUTF8StringEncoding]
        base64EncodedStringWithOptions:0];
    return [[authorization substringFromIndex:6] isEqualToString:expected];
}

- (NSString *)decodedRequestPath:(NSString *)target
{
    NSString *path = target ?: @"/";
    NSRange query = [path rangeOfString:@"?"];
    if (query.location != NSNotFound) path = [path substringToIndex:query.location];
    path = [path stringByRemovingPercentEncoding] ?: path;
    if (![path hasPrefix:@"/"]) return nil;

    NSMutableArray<NSString *> *safe = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (!component.length || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."] || [component containsString:@"\0"]) return nil;
        [safe addObject:component];
    }
    return [@"/" stringByAppendingString:[safe componentsJoinedByString:@"/"]];
}

- (NSString *)filesystemPathForRequestTarget:(NSString *)target
                                  mustExist:(BOOL)mustExist
                                      error:(NSError **)error
{
    NSString *relative = [self decodedRequestPath:target];
    if (!relative) {
        if (error) *error = [self errorWithCode:400 message:@"请求路径无效"];
        return nil;
    }
    NSString *candidate = relative.length > 1
        ? [self.realRootPath stringByAppendingPathComponent:[relative substringFromIndex:1]]
        : self.realRootPath;
    candidate = candidate.stringByStandardizingPath;
    if (!FFPathInsideRoot(candidate, self.realRootPath)) {
        if (error) *error = [self errorWithCode:403 message:@"请求路径超出共享目录"];
        return nil;
    }

    if (mustExist) {
        NSString *resolved = FFRealPath(candidate);
        if (!resolved.length || !FFPathInsideRoot(resolved, self.realRootPath)) {
            if (error) *error = [self errorWithCode:404 message:@"文件不存在或不可访问"];
            return nil;
        }
        return resolved;
    }

    NSString *parent = FFRealPath(candidate.stringByDeletingLastPathComponent);
    if (!parent.length || !FFPathInsideRoot(parent, self.realRootPath)) {
        if (error) *error = [self errorWithCode:409 message:@"目标父目录不存在或越界"];
        return nil;
    }
    return candidate;
}

- (void)sendStatus:(NSInteger)status
            reason:(NSString *)reason
           headers:(NSDictionary<NSString *, NSString *> *)headers
              body:(NSData *)body
                fd:(int)fd
              head:(BOOL)head
{
    NSMutableDictionary *all = [@{
        @"Connection": @"close",
        @"Server": @"FuckFile-WebDAV/1",
        @"Date": FFHTTPDate(NSDate.date),
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
    } mutableCopy];
    [all addEntriesFromDictionary:headers ?: @{}];

    NSMutableString *response = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n",
        (long)status, reason ?: @""];
    [all enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        [response appendFormat:@"%@: %@\r\n", key, value];
    }];
    [response appendString:@"\r\n"];
    NSData *headerData = [response dataUsingEncoding:NSUTF8StringEncoding];
    FFWriteAllFD(fd, headerData.bytes, headerData.length);
    if (!head && body.length) FFWriteAllFD(fd, body.bytes, body.length);
}

- (void)sendTextStatus:(NSInteger)status reason:(NSString *)reason message:(NSString *)message fd:(int)fd
{
    NSData *body = [(message ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    [self sendStatus:status reason:reason
        headers:@{@"Content-Type":@"text/plain; charset=utf-8"}
        body:body fd:fd head:NO];
}

- (void)handleClient:(int)fd generation:(NSUInteger)generation
{
    @synchronized (self) {
        if (!self.running || generation != _generation) return;
    }
    FFWebDAVRequest *request = [self readRequestFromFD:fd];
    if (!request) {
        [self sendTextStatus:400 reason:@"Bad Request" message:@"Bad Request" fd:fd];
        return;
    }
    if (![self isAuthorized:request]) {
        [self sendStatus:401 reason:@"Unauthorized"
            headers:@{@"WWW-Authenticate":@"Basic realm=\"FuckFile\"",
                      @"Content-Type":@"text/plain; charset=utf-8"}
            body:[@"需要用户名和密码" dataUsingEncoding:NSUTF8StringEncoding]
            fd:fd head:NO];
        return;
    }

    NSString *method = request.method;
    if ([method isEqualToString:@"OPTIONS"]) {
        [self sendStatus:200 reason:@"OK"
            headers:@{@"DAV":@"1, 2",
                      @"Allow":@"OPTIONS, GET, HEAD, PROPFIND, PUT, MKCOL, DELETE, COPY, MOVE, LOCK, UNLOCK",
                      @"MS-Author-Via":@"DAV"}
            body:NSData.data fd:fd head:NO];
        return;
    }
    if ([method isEqualToString:@"PROPFIND"]) {
        [self handlePropfind:request fd:fd];
        return;
    }
    if ([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]) {
        [self handleGet:request fd:fd head:[method isEqualToString:@"HEAD"]];
        return;
    }
    if ([method isEqualToString:@"PUT"]) {
        [self handlePut:request fd:fd];
        return;
    }
    if ([method isEqualToString:@"MKCOL"]) {
        [self handleMkcol:request fd:fd];
        return;
    }
    if ([method isEqualToString:@"DELETE"]) {
        [self handleDelete:request fd:fd];
        return;
    }
    if ([method isEqualToString:@"MOVE"] || [method isEqualToString:@"COPY"]) {
        [self handleCopyMove:request fd:fd move:[method isEqualToString:@"MOVE"]];
        return;
    }
    if ([method isEqualToString:@"LOCK"]) {
        NSString *token = [NSString stringWithFormat:@"opaquelocktoken:%@", NSUUID.UUID.UUIDString];
        NSString *xml = [NSString stringWithFormat:
            @"<?xml version=\"1.0\" encoding=\"utf-8\"?><d:prop xmlns:d=\"DAV:\"><d:lockdiscovery><d:activelock><d:locktype><d:write/></d:locktype><d:lockscope><d:exclusive/></d:lockscope><d:depth>infinity</d:depth><d:timeout>Second-3600</d:timeout><d:locktoken><d:href>%@</d:href></d:locktoken></d:activelock></d:lockdiscovery></d:prop>",
            FFXMLEscape(token)];
        NSData *body = [xml dataUsingEncoding:NSUTF8StringEncoding];
        [self sendStatus:200 reason:@"OK"
            headers:@{@"Content-Type":@"application/xml; charset=utf-8",
                      @"Lock-Token":[NSString stringWithFormat:@"<%@>", token]}
            body:body fd:fd head:NO];
        return;
    }
    if ([method isEqualToString:@"UNLOCK"]) {
        [self sendStatus:204 reason:@"No Content" headers:nil body:NSData.data fd:fd head:NO];
        return;
    }

    [self sendStatus:405 reason:@"Method Not Allowed"
        headers:@{@"Allow":@"OPTIONS, GET, HEAD, PROPFIND, PUT, MKCOL, DELETE, COPY, MOVE, LOCK, UNLOCK"}
        body:NSData.data fd:fd head:NO];
}

- (NSString *)davResponseForPath:(NSString *)path requestPath:(NSString *)requestPath
{
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory]) return @"";
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] ?: @{};
    NSString *name = path.lastPathComponent.length ? path.lastPathComponent : @"文件";
    NSString *href = FFPercentPath(requestPath, directory);
    NSString *resource = directory ? @"<d:collection/>" : @"";
    unsigned long long size = directory ? 0 : [attrs[NSFileSize] unsignedLongLongValue];
    NSDate *modified = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
        ? attrs[NSFileModificationDate] : NSDate.date;
    NSString *etag = [NSString stringWithFormat:@"\"%llx-%llx\"",
        size, (unsigned long long)(modified.timeIntervalSince1970)];

    return [NSString stringWithFormat:
        @"<d:response><d:href>%@</d:href><d:propstat><d:prop>"
         "<d:displayname>%@</d:displayname><d:resourcetype>%@</d:resourcetype>"
         "<d:getcontentlength>%llu</d:getcontentlength>"
         "<d:getlastmodified>%@</d:getlastmodified><d:getetag>%@</d:getetag>"
         "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>",
        FFXMLEscape(href), FFXMLEscape(name), resource, size,
        FFXMLEscape(FFHTTPDate(modified)), FFXMLEscape(etag)];
}

- (void)handlePropfind:(FFWebDAVRequest *)request fd:(int)fd
{
    NSError *error = nil;
    NSString *path = [self filesystemPathForRequestTarget:request.target mustExist:YES error:&error];
    if (!path) {
        [self sendTextStatus:error.code == 403 ? 403 : 404
            reason:error.code == 403 ? @"Forbidden" : @"Not Found"
            message:error.localizedDescription fd:fd];
        return;
    }

    NSString *requestPath = [self decodedRequestPath:request.target] ?: @"/";
    BOOL directory = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory];
    NSMutableString *xml = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">"];
    [xml appendString:[self davResponseForPath:path requestPath:requestPath]];

    NSString *depth = request.headers[@"depth"] ?: @"1";
    if (directory && ![depth isEqualToString:@"0"]) {
        NSArray<NSString *> *children = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:path error:nil] ?: @[];
        children = [children sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *name in children) {
            if ([name hasPrefix:@".ffwebdav-"]) continue;
            NSString *child = [path stringByAppendingPathComponent:name];
            NSString *childRequest = [requestPath isEqualToString:@"/"]
                ? [@"/" stringByAppendingString:name]
                : [requestPath stringByAppendingPathComponent:name];
            [xml appendString:[self davResponseForPath:child requestPath:childRequest]];
        }
    }
    [xml appendString:@"</d:multistatus>"];
    NSData *body = [xml dataUsingEncoding:NSUTF8StringEncoding];
    [self sendStatus:207 reason:@"Multi-Status"
        headers:@{@"Content-Type":@"application/xml; charset=utf-8", @"DAV":@"1, 2"}
        body:body fd:fd head:NO];
}

- (NSString *)directoryHTMLForPath:(NSString *)path requestPath:(NSString *)requestPath
{
    NSArray<NSString *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:path error:nil] ?: @[];
    children = [children sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSMutableString *rows = [NSMutableString string];
    if (![requestPath isEqualToString:@"/"]) {
        NSString *parent = requestPath.stringByDeletingLastPathComponent;
        if (!parent.length) parent = @"/";
        [rows appendFormat:@"<tr><td>📁</td><td><a href=\"%@\">..</a></td><td></td><td></td></tr>",
            FFPercentPath(parent, YES)];
    }
    for (NSString *name in children) {
        if ([name hasPrefix:@".ffwebdav-"]) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        BOOL directory = NO;
        [NSFileManager.defaultManager fileExistsAtPath:child isDirectory:&directory];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:child error:nil] ?: @{};
        NSString *hrefPath = [requestPath isEqualToString:@"/"]
            ? [@"/" stringByAppendingString:name]
            : [requestPath stringByAppendingPathComponent:name];
        NSString *href = FFPercentPath(hrefPath, directory);
        NSString *size = directory ? @"—" : [NSByteCountFormatter
            stringFromByteCount:[attrs[NSFileSize] longLongValue]
            countStyle:NSByteCountFormatterCountStyleFile];
        [rows appendFormat:
            @"<tr><td>%@</td><td><a href=\"%@\">%@</a></td><td>%@</td>"
             "<td><button onclick=\"removeItem('%@')\">删除</button></td></tr>",
            directory ? @"📁" : @"📄", href, FFHTMLEscape(name), FFHTMLEscape(size),
            [href stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]];
    }

    NSString *base = FFPercentPath(requestPath, YES);
    return [NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset=\"utf-8\">"
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
         "<title>FuckFile</title><style>"
         "body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:900px;margin:32px auto;padding:0 18px;background:#f5f5f7;color:#111}"
         "h1{font-size:26px} .bar{display:flex;gap:10px;flex-wrap:wrap;margin:18px 0}"
         "button,.pick{border:0;border-radius:10px;padding:10px 14px;background:#0a84ff;color:white;font-size:15px}"
         "table{width:100%%;border-collapse:collapse;background:white;border-radius:14px;overflow:hidden}"
         "td{padding:12px;border-bottom:1px solid #eee}a{color:#0a84ff;text-decoration:none}small{color:#777}"
         "</style></head><body><h1>FuckFile</h1><small>%@</small>"
         "<div class=\"bar\"><label class=\"pick\">上传文件<input id=\"files\" type=\"file\" multiple hidden></label>"
         "<button onclick=\"mkdir()\">新建文件夹</button></div>"
         "<table>%@</table><script>"
         "const base='%@';"
         "document.getElementById('files').onchange=async e=>{for(const f of e.target.files){"
         "let u=base+encodeURIComponent(f.name);let r=await fetch(u,{method:'PUT',body:f});if(!r.ok)alert('上传失败 '+f.name+' '+r.status);}location.reload();};"
         "async function mkdir(){let n=prompt('文件夹名称');if(!n)return;let r=await fetch(base+encodeURIComponent(n),{method:'MKCOL'});if(!r.ok)alert('创建失败 '+r.status);else location.reload();}"
         "async function removeItem(u){if(!confirm('确定删除？'))return;let r=await fetch(u,{method:'DELETE'});if(!r.ok)alert('删除失败 '+r.status);else location.reload();}"
         "</script></body></html>",
        FFHTMLEscape(requestPath), rows, base];
}

- (void)handleGet:(FFWebDAVRequest *)request fd:(int)fd head:(BOOL)head
{
    NSError *error = nil;
    NSString *path = [self filesystemPathForRequestTarget:request.target mustExist:YES error:&error];
    if (!path) {
        [self sendTextStatus:404 reason:@"Not Found" message:error.localizedDescription fd:fd];
        return;
    }

    BOOL directory = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory];
    if (directory) {
        NSString *requestPath = [self decodedRequestPath:request.target] ?: @"/";
        NSString *html = [self directoryHTMLForPath:path requestPath:requestPath];
        NSData *body = [html dataUsingEncoding:NSUTF8StringEncoding];
        [self sendStatus:200 reason:@"OK"
            headers:@{@"Content-Type":@"text/html; charset=utf-8"}
            body:body fd:fd head:head];
        return;
    }

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] ?: @{};
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    NSMutableString *header = [NSMutableString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nConnection: close\r\nServer: FuckFile-WebDAV/1\r\n"
         "Date: %@\r\nContent-Type: application/octet-stream\r\n"
         "Content-Length: %llu\r\nLast-Modified: %@\r\n\r\n",
        FFHTTPDate(NSDate.date), size,
        FFHTTPDate([attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
            ? attrs[NSFileModificationDate] : NSDate.date)];
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    if (!FFWriteAllFD(fd, headerData.bytes, headerData.length) || head) return;

    int input = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) return;
    uint8_t buffer[128 * 1024];
    for (;;) {
        ssize_t got = read(input, buffer, sizeof(buffer));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        if (!FFWriteAllFD(fd, buffer, (size_t)got)) break;
    }
    close(input);
}

- (BOOL)writeRequestBody:(FFWebDAVRequest *)request toFD:(int)output socket:(int)fd
{
    unsigned long long remaining = request.contentLength;
    NSUInteger prefixCount = (NSUInteger)MIN((unsigned long long)request.bodyPrefix.length, remaining);
    if (prefixCount && !FFWriteAllFD(output, request.bodyPrefix.bytes, prefixCount)) return NO;
    remaining -= prefixCount;

    uint8_t buffer[128 * 1024];
    while (remaining) {
        size_t wanted = (size_t)MIN((unsigned long long)sizeof(buffer), remaining);
        ssize_t got = read(fd, buffer, wanted);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return NO;
        if (!FFWriteAllFD(output, buffer, (size_t)got)) return NO;
        remaining -= (unsigned long long)got;
    }
    return YES;
}

- (void)handlePut:(FFWebDAVRequest *)request fd:(int)fd
{
    if (!request.headers[@"content-length"]) {
        [self sendTextStatus:411 reason:@"Length Required" message:@"PUT 需要 Content-Length" fd:fd];
        return;
    }
    NSError *error = nil;
    NSString *target = [self filesystemPathForRequestTarget:request.target mustExist:NO error:&error];
    if (!target) {
        [self sendTextStatus:409 reason:@"Conflict" message:error.localizedDescription fd:fd];
        return;
    }

    BOOL isDirectory = NO;
    BOOL existed = [NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&isDirectory];
    if (isDirectory) {
        [self sendTextStatus:409 reason:@"Conflict" message:@"目标是文件夹" fd:fd];
        return;
    }

    NSString *parent = target.stringByDeletingLastPathComponent;
    NSString *temp = [parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".ffwebdav-%@.tmp", NSUUID.UUID.UUIDString]];
    int output = open(temp.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0) {
        [self sendTextStatus:500 reason:@"Internal Server Error" message:@"无法创建上传临时文件" fd:fd];
        return;
    }

    BOOL ok = [self writeRequestBody:request toFD:output socket:fd];
    if (ok) ok = fsync(output) == 0;
    close(output);
    if (!ok) {
        unlink(temp.fileSystemRepresentation);
        [self sendTextStatus:400 reason:@"Bad Request" message:@"上传数据中断" fd:fd];
        return;
    }

    @synchronized (self) {
        if (rename(temp.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
            ok = NO;
            unlink(temp.fileSystemRepresentation);
        }
    }
    if (!ok) {
        [self sendTextStatus:500 reason:@"Internal Server Error" message:@"提交上传文件失败" fd:fd];
        return;
    }
    [self sendStatus:existed ? 204 : 201 reason:existed ? @"No Content" : @"Created"
        headers:nil body:NSData.data fd:fd head:NO];
}

- (void)handleMkcol:(FFWebDAVRequest *)request fd:(int)fd
{
    NSError *error = nil;
    NSString *target = [self filesystemPathForRequestTarget:request.target mustExist:NO error:&error];
    if (!target) {
        [self sendTextStatus:409 reason:@"Conflict" message:error.localizedDescription fd:fd];
        return;
    }
    NSError *mkdir = nil;
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:target
        withIntermediateDirectories:NO attributes:nil error:&mkdir];
    if (!ok) {
        [self sendTextStatus:405 reason:@"Method Not Allowed"
            message:mkdir.localizedDescription ?: @"创建文件夹失败" fd:fd];
        return;
    }
    [self sendStatus:201 reason:@"Created" headers:nil body:NSData.data fd:fd head:NO];
}

- (void)handleDelete:(FFWebDAVRequest *)request fd:(int)fd
{
    NSError *error = nil;
    NSString *target = [self filesystemPathForRequestTarget:request.target mustExist:YES error:&error];
    if (!target) {
        [self sendTextStatus:404 reason:@"Not Found" message:error.localizedDescription fd:fd];
        return;
    }
    if ([target isEqualToString:self.realRootPath]) {
        [self sendTextStatus:403 reason:@"Forbidden" message:@"不能删除共享根目录" fd:fd];
        return;
    }
    NSError *remove = nil;
    BOOL ok = NO;
    @synchronized (self) {
        ok = [NSFileManager.defaultManager removeItemAtPath:target error:&remove];
    }
    if (!ok) {
        [self sendTextStatus:500 reason:@"Internal Server Error"
            message:remove.localizedDescription ?: @"删除失败" fd:fd];
        return;
    }
    [self sendStatus:204 reason:@"No Content" headers:nil body:NSData.data fd:fd head:NO];
}

- (NSString *)destinationTargetFromHeader:(NSString *)header
{
    if (!header.length) return nil;
    NSURL *url = [NSURL URLWithString:header];
    if (url.scheme.length) return url.path ?: @"/";
    return header;
}

- (void)handleCopyMove:(FFWebDAVRequest *)request fd:(int)fd move:(BOOL)move
{
    NSError *sourceError = nil;
    NSString *source = [self filesystemPathForRequestTarget:request.target
                                                 mustExist:YES error:&sourceError];
    NSString *destinationHeader = [self destinationTargetFromHeader:request.headers[@"destination"]];
    NSError *destinationError = nil;
    NSString *destination = destinationHeader.length
        ? [self filesystemPathForRequestTarget:destinationHeader mustExist:NO error:&destinationError]
        : nil;
    if (!source || !destination || [source isEqualToString:self.realRootPath]) {
        [self sendTextStatus:409 reason:@"Conflict"
            message:destinationError.localizedDescription ?: sourceError.localizedDescription ?: @"源或目标无效"
            fd:fd];
        return;
    }

    BOOL overwrite = ![request.headers[@"overwrite"].uppercaseString isEqualToString:@"F"];
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:destination];
    if (exists && !overwrite) {
        [self sendStatus:412 reason:@"Precondition Failed" headers:nil body:NSData.data fd:fd head:NO];
        return;
    }

    NSError *operationError = nil;
    BOOL ok = NO;
    @synchronized (self) {
        if (exists) [NSFileManager.defaultManager removeItemAtPath:destination error:&operationError];
        if (!operationError) {
            ok = move
                ? [NSFileManager.defaultManager moveItemAtPath:source toPath:destination error:&operationError]
                : [NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:&operationError];
        }
    }
    if (!ok) {
        [self sendTextStatus:500 reason:@"Internal Server Error"
            message:operationError.localizedDescription ?: (move ? @"移动失败" : @"复制失败") fd:fd];
        return;
    }
    [self sendStatus:exists ? 204 : 201 reason:exists ? @"No Content" : @"Created"
        headers:nil body:NSData.data fd:fd head:NO];
}

@end
