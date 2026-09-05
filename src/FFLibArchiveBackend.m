#import "FFLibArchiveBackend.h"

#import "FFArchiveService.h"
#import "FFZipExtract.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

typedef struct archive FFArchiveHandle;
typedef struct archive_entry FFArchiveNativeEntry;
typedef long long FFArchiveInt64;
typedef long FFArchiveSSize;

enum {
    FF_ARCHIVE_OK = 0,
    FF_ARCHIVE_EOF = 1,
    FF_ARCHIVE_WARN = -20,
};

#define FF_AE_IFMT 0170000
#define FF_AE_IFREG 0100000
#define FF_AE_IFDIR 0040000
#define FF_AE_IFLNK 0120000

static const NSUInteger kFFLibArchiveMaxEntries = 100000;
static const unsigned long long kFFLibArchiveMaxSingleEntry = 2ULL * 1024 * 1024 * 1024;
static const unsigned long long kFFLibArchiveMaxTotal = 4ULL * 1024 * 1024 * 1024;

typedef struct {
    void *handle;
    FFArchiveHandle *(*read_new)(void);
    int (*read_support_filter_all)(FFArchiveHandle *);
    int (*read_support_format_all)(FFArchiveHandle *);
    int (*read_support_format_raw)(FFArchiveHandle *);
    int (*read_add_passphrase)(FFArchiveHandle *, const char *);
    int (*read_open_filename)(FFArchiveHandle *, const char *, size_t);
    int (*read_next_header)(FFArchiveHandle *, FFArchiveNativeEntry **);
    FFArchiveSSize (*read_data)(FFArchiveHandle *, void *, size_t);
    int (*read_data_skip)(FFArchiveHandle *);
    int (*read_free)(FFArchiveHandle *);
    const char *(*error_string)(FFArchiveHandle *);
    const char *(*entry_pathname_utf8)(FFArchiveNativeEntry *);
    const char *(*entry_pathname)(FFArchiveNativeEntry *);
    FFArchiveInt64 (*entry_size)(FFArchiveNativeEntry *);
    unsigned int (*entry_filetype)(FFArchiveNativeEntry *);
    int (*entry_is_encrypted)(FFArchiveNativeEntry *);
} FFLibArchiveAPI;

static FFLibArchiveAPI *FFLibArchiveAPIShared(void)
{
    static FFLibArchiveAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *candidates[] = {
            "/usr/lib/libarchive.2.dylib",
            "/usr/lib/libarchive.dylib",
            "libarchive.2.dylib",
            "libarchive.dylib",
        };
        for (NSUInteger i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
            api.handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
            if (api.handle) break;
        }
        if (!api.handle) return;

#define FF_LOAD_REQUIRED(field, symbol) do { \
    api.field = (__typeof__(api.field))dlsym(api.handle, symbol); \
    if (!api.field) { dlclose(api.handle); memset(&api, 0, sizeof(api)); return; } \
} while (0)
#define FF_LOAD_OPTIONAL(field, symbol) \
    api.field = (__typeof__(api.field))dlsym(api.handle, symbol)

        FF_LOAD_REQUIRED(read_new, "archive_read_new");
        FF_LOAD_REQUIRED(read_support_filter_all, "archive_read_support_filter_all");
        FF_LOAD_REQUIRED(read_support_format_all, "archive_read_support_format_all");
        FF_LOAD_REQUIRED(read_open_filename, "archive_read_open_filename");
        FF_LOAD_REQUIRED(read_next_header, "archive_read_next_header");
        FF_LOAD_REQUIRED(read_data, "archive_read_data");
        FF_LOAD_REQUIRED(read_data_skip, "archive_read_data_skip");
        FF_LOAD_REQUIRED(read_free, "archive_read_free");
        FF_LOAD_REQUIRED(error_string, "archive_error_string");
        FF_LOAD_REQUIRED(entry_pathname, "archive_entry_pathname");
        FF_LOAD_REQUIRED(entry_size, "archive_entry_size");
        FF_LOAD_REQUIRED(entry_filetype, "archive_entry_filetype");

        FF_LOAD_OPTIONAL(read_support_format_raw, "archive_read_support_format_raw");
        FF_LOAD_OPTIONAL(read_add_passphrase, "archive_read_add_passphrase");
        FF_LOAD_OPTIONAL(entry_pathname_utf8, "archive_entry_pathname_utf8");
        FF_LOAD_OPTIONAL(entry_is_encrypted, "archive_entry_is_encrypted");

#undef FF_LOAD_REQUIRED
#undef FF_LOAD_OPTIONAL
    });
    return api.handle ? &api : NULL;
}

BOOL FFLibArchiveBackendAvailable(void)
{
    return FFLibArchiveAPIShared() != NULL;
}

static NSError *FFLibArchiveError(FFArchiveHandle *archive, NSString *fallback,
                                  NSString *password)
{
    FFLibArchiveAPI *api = FFLibArchiveAPIShared();
    const char *raw = api && api->error_string ? api->error_string(archive) : NULL;
    NSString *message = raw ? [NSString stringWithUTF8String:raw] : nil;
    if (!message.length) message = fallback.length ? fallback : @"归档读取失败";

    NSString *lower = message.lowercaseString;
    BOOL passwordProblem =
        [lower containsString:@"passphrase"] ||
        [lower containsString:@"password"] ||
        [lower containsString:@"encrypted"] ||
        [lower containsString:@"encryption"];
    FFZipExtractErrorCode code = FFZipExtractErrorInvalidArchive;
    if (passwordProblem)
        code = password.length ? FFZipExtractErrorWrongPassword : FFZipExtractErrorPasswordRequired;
    else if ([lower containsString:@"unsupported"] || [lower containsString:@"not supported"])
        code = FFZipExtractErrorUnsupportedCompression;

    return [NSError errorWithDomain:FFZipExtractErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *FFLibArchiveSimpleError(FFZipExtractErrorCode code, NSString *message)
{
    return [NSError errorWithDomain:FFZipExtractErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"归档处理失败"}];
}

static NSString *FFLibArchiveNormalizedPath(NSString *name)
{
    if (!name.length) return nil;
    NSString *path = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([path hasPrefix:@"./"]) path = [path substringFromIndex:2];
    while ([path hasSuffix:@"//"]) path = [path substringToIndex:path.length - 1];
    return path.length ? path : nil;
}

static BOOL FFLibArchiveSafeEntryName(NSString *name)
{
    NSString *path = FFLibArchiveNormalizedPath(name);
    if (!path.length || path.length > 1024) return NO;
    if ([path hasPrefix:@"/"] || [path containsString:@"\0"]) return NO;
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    for (NSString *component in parts) {
        if ([component isEqualToString:@".."]) return NO;
    }
    return YES;
}

static BOOL FFLibArchiveIsRawCompressedPath(NSString *archivePath)
{
    NSString *lower = archivePath.lastPathComponent.lowercaseString;
    if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tar.bz2"] ||
        [lower hasSuffix:@".tar.xz"] || [lower hasSuffix:@".tgz"] ||
        [lower hasSuffix:@".tbz"] || [lower hasSuffix:@".tbz2"] ||
        [lower hasSuffix:@".txz"])
        return NO;
    return [lower hasSuffix:@".gz"] || [lower hasSuffix:@".bz2"] ||
           [lower hasSuffix:@".xz"];
}

static NSString *FFLibArchiveRawSyntheticName(NSString *archivePath)
{
    NSString *name = archivePath.lastPathComponent;
    NSString *lower = name.lowercaseString;
    for (NSString *suffix in @[@".bz2", @".gz", @".xz"]) {
        if ([lower hasSuffix:suffix] && name.length > suffix.length)
            return [name substringToIndex:name.length - suffix.length];
    }
    return name.stringByDeletingPathExtension.length
        ? name.stringByDeletingPathExtension : @"data";
}

static NSString *FFLibArchiveEntryPath(FFArchiveNativeEntry *entry, NSString *archivePath)
{
    FFLibArchiveAPI *api = FFLibArchiveAPIShared();
    const char *raw = NULL;
    if (api->entry_pathname_utf8) raw = api->entry_pathname_utf8(entry);
    if (!raw) raw = api->entry_pathname(entry);
    NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;
    name = FFLibArchiveNormalizedPath(name);
    if (FFLibArchiveIsRawCompressedPath(archivePath) &&
        (!name.length || [name isEqualToString:@"data"]))
        name = FFLibArchiveRawSyntheticName(archivePath);
    return name;
}

static FFArchiveHandle *FFLibArchiveOpen(NSString *archivePath, NSString *password,
                                        NSError **error)
{
    FFLibArchiveAPI *api = FFLibArchiveAPIShared();
    if (!api) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsupportedCompression,
            @"当前系统没有可用的 libarchive 后端");
        return NULL;
    }

    FFArchiveHandle *archive = api->read_new();
    if (!archive) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorIO,
            @"无法创建归档读取器");
        return NULL;
    }
    api->read_support_filter_all(archive);
    api->read_support_format_all(archive);
    if (api->read_support_format_raw) api->read_support_format_raw(archive);
    if (password.length && api->read_add_passphrase)
        api->read_add_passphrase(archive, password.UTF8String);

    int rc = api->read_open_filename(archive, archivePath.fileSystemRepresentation, 1024 * 64);
    if (rc < FF_ARCHIVE_WARN) {
        if (error) *error = FFLibArchiveError(archive, @"无法打开归档", password);
        api->read_free(archive);
        return NULL;
    }
    return archive;
}

static BOOL FFLibArchiveEnsureParent(NSString *root, NSString *relative, NSError **error)
{
    NSString *parent = [[root stringByAppendingPathComponent:relative]
        stringByDeletingLastPathComponent];
    NSError *mkdirError = nil;
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:&mkdirError];
    if (!ok && error) *error = mkdirError;
    return ok;
}

static BOOL FFLibArchiveWriteAll(int fd, const uint8_t *bytes, size_t length,
                                 NSString *path, NSError **error)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, bytes + offset, length - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        int saved = errno ?: EIO;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                @"写入解压文件失败：%@ (%s)", path.lastPathComponent, strerror(saved)]}];
        return NO;
    }
    return YES;
}

static BOOL FFLibArchiveCommitTempDirectory(NSString *tempPath, NSString *destination,
                                            NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:destination]) {
        NSError *moveError = nil;
        if ([fm moveItemAtPath:tempPath toPath:destination error:&moveError]) return YES;
        if (error) *error = moveError;
        return NO;
    }

    NSString *backup = [NSString stringWithFormat:@"%@.old%@", destination,
        [NSUUID.UUID.UUIDString substringToIndex:8]];
    NSError *backupError = nil;
    if (![fm moveItemAtPath:destination toPath:backup error:&backupError]) {
        if (error) *error = backupError;
        return NO;
    }

    NSError *commitError = nil;
    if (![fm moveItemAtPath:tempPath toPath:destination error:&commitError]) {
        NSError *rollbackError = nil;
        BOOL restored = [fm moveItemAtPath:backup toPath:destination error:&rollbackError];
        if (!restored) {
            NSString *message = [NSString stringWithFormat:
                @"解压提交失败且回滚失败。原目标保存在：%@。提交错误：%@；回滚错误：%@",
                backup, commitError.localizedDescription ?: @"未知",
                rollbackError.localizedDescription ?: @"未知"];
            if (error) *error = [NSError errorWithDomain:@"FFArchiveCommit" code:2
                userInfo:@{NSLocalizedDescriptionKey:message,
                           NSUnderlyingErrorKey:rollbackError ?: commitError}];
        } else if (error) {
            *error = commitError;
        }
        return NO;
    }

    NSError *cleanupError = nil;
    if (![fm removeItemAtPath:backup error:&cleanupError]) {
        // Extraction succeeded; stale backup cleanup is non-fatal.
    }
    return YES;
}

NSArray<FFArchiveEntry *> *FFLibArchiveListEntries(NSString *archivePath,
                                                    NSString *password,
                                                    NSError **error)
{
    if (error) *error = nil;
    FFArchiveHandle *archive = FFLibArchiveOpen(archivePath, password, error);
    if (!archive) return nil;
    FFLibArchiveAPI *api = FFLibArchiveAPIShared();

    NSMutableArray<FFArchiveEntry *> *entries = [NSMutableArray array];
    FFArchiveNativeEntry *native = NULL;
    for (;;) {
        int rc = api->read_next_header(archive, &native);
        if (rc == FF_ARCHIVE_EOF) break;
        if (rc < FF_ARCHIVE_WARN) {
            if (error) *error = FFLibArchiveError(archive, @"无法读取归档目录", password);
            api->read_free(archive);
            return nil;
        }

        NSString *name = FFLibArchiveEntryPath(native, archivePath);
        if (!FFLibArchiveSafeEntryName(name)) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsafeEntry,
                [NSString stringWithFormat:@"不安全的归档路径，已拒绝读取：%@", name ?: @"(null)"]);
            api->read_free(archive);
            return nil;
        }

        FFArchiveInt64 nativeSize = api->entry_size(native);
        FFArchiveEntry *entry = [FFArchiveEntry new];
        entry.entryPath = name;
        unsigned int type = api->entry_filetype(native) & FF_AE_IFMT;
        entry.isDirectory = type == FF_AE_IFDIR;
        entry.encrypted = api->entry_is_encrypted ? api->entry_is_encrypted(native) > 0 : NO;
        entry.size = nativeSize > 0 ? (unsigned long long)nativeSize : 0;
        entry.compressedSize = 0;
        [entries addObject:entry];

        if (entries.count > kFFLibArchiveMaxEntries) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorTooLarge,
                @"归档条目过多（超过 100000 个）");
            api->read_free(archive);
            return nil;
        }
        api->read_data_skip(archive);
    }
    api->read_free(archive);
    return entries;
}

NSString *FFLibArchiveExtractEntry(NSString *entryName, NSString *archivePath,
                                   NSString *destinationDirectory, NSString *password,
                                   NSError **error)
{
    if (error) *error = nil;
    if (!FFLibArchiveSafeEntryName(entryName)) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsafeEntry,
            @"不安全的条目名，已拒绝提取");
        return nil;
    }

    FFArchiveHandle *archive = FFLibArchiveOpen(archivePath, password, error);
    if (!archive) return nil;
    FFLibArchiveAPI *api = FFLibArchiveAPIShared();
    FFArchiveNativeEntry *native = NULL;
    BOOL found = NO;
    FFArchiveInt64 declaredSize = 0;

    for (;;) {
        int rc = api->read_next_header(archive, &native);
        if (rc == FF_ARCHIVE_EOF) break;
        if (rc < FF_ARCHIVE_WARN) {
            if (error) *error = FFLibArchiveError(archive, @"读取归档失败", password);
            api->read_free(archive);
            return nil;
        }
        NSString *name = FFLibArchiveEntryPath(native, archivePath);
        if ([name isEqualToString:FFLibArchiveNormalizedPath(entryName)]) {
            found = YES;
            break;
        }
        api->read_data_skip(archive);
    }

    if (!found) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorInvalidArchive,
            @"归档中不存在该条目");
        api->read_free(archive);
        return nil;
    }

    unsigned int type = api->entry_filetype(native) & FF_AE_IFMT;
    if (type == FF_AE_IFDIR) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorInvalidArchive,
            @"目录条目无法直接提取为文件");
        api->read_free(archive);
        return nil;
    }
    if (type == FF_AE_IFLNK || (type != 0 && type != FF_AE_IFREG)) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsafeEntry,
            @"符号链接或特殊文件条目已拒绝提取");
        api->read_free(archive);
        return nil;
    }

    declaredSize = api->entry_size(native);
    if (declaredSize > (FFArchiveInt64)kFFLibArchiveMaxSingleEntry) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorTooLarge,
            @"条目过大（超过 2 GiB），拒绝单独提取");
        api->read_free(archive);
        return nil;
    }

    NSError *mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:destinationDirectory
        withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
        if (error) *error = mkdirError;
        api->read_free(archive);
        return nil;
    }

    NSString *destination = [destinationDirectory stringByAppendingPathComponent:
        FFLibArchiveNormalizedPath(entryName).lastPathComponent];
    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (output < 0) {
        int saved = errno;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                @"创建提取文件失败：%s", strerror(saved)]}];
        api->read_free(archive);
        return nil;
    }

    uint8_t *buffer = malloc(256 * 1024);
    BOOL ok = buffer != NULL;
    unsigned long long produced = 0;
    if (!buffer && error)
        *error = FFLibArchiveSimpleError(FFZipExtractErrorIO, @"无法分配解压缓冲区");

    while (ok) {
        FFArchiveSSize count = api->read_data(archive, buffer, 256 * 1024);
        if (count == 0) break;
        if (count < 0) {
            if (error) *error = FFLibArchiveError(archive, @"解压数据读取失败", password);
            ok = NO;
            break;
        }
        if (!FFLibArchiveWriteAll(output, buffer, (size_t)count, destination, error)) {
            ok = NO;
            break;
        }
        produced += (unsigned long long)count;
        if (produced > kFFLibArchiveMaxSingleEntry ||
            (declaredSize >= 0 && produced > (unsigned long long)declaredSize)) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorTooLarge,
                @"解压数据超出声明大小，已中止");
            ok = NO;
        }
    }

    if (buffer) free(buffer);
    close(output);
    api->read_free(archive);
    if (!ok) {
        unlink(destination.fileSystemRepresentation);
        return nil;
    }
    if (declaredSize >= 0 && produced != (unsigned long long)declaredSize) {
        unlink(destination.fileSystemRepresentation);
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorInvalidArchive,
            @"解压后大小与声明不符");
        return nil;
    }
    return destination;
}

BOOL FFLibArchiveExtractAll(NSString *archivePath, NSString *destinationDirectory,
                            NSString *password, NSArray<NSString *> **entryNames,
                            void (^progressBlock)(double, NSString *),
                            BOOL (^shouldCancel)(void), NSError **error)
{
    if (error) *error = nil;
    NSArray<FFArchiveEntry *> *plan = FFLibArchiveListEntries(archivePath, password, error);
    if (!plan) return NO;
    if (plan.count == 0) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorInvalidArchive,
            @"归档为空或无法解析任何条目");
        return NO;
    }

    unsigned long long declaredTotal = 0;
    for (FFArchiveEntry *entry in plan) {
        if (entry.size > kFFLibArchiveMaxTotal ||
            declaredTotal > kFFLibArchiveMaxTotal - entry.size) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorTooLarge,
                @"归档解压后体积过大（超过 4 GiB 安全上限）");
            return NO;
        }
        declaredTotal += entry.size;
    }

    NSString *parent = destinationDirectory.stringByDeletingLastPathComponent;
    NSError *parentError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:&parentError]) {
        if (error) *error = parentError;
        return NO;
    }
    NSString *temp = [[parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.tmp", destinationDirectory.lastPathComponent,
            [NSUUID.UUID.UUIDString substringToIndex:8]]] stringByStandardizingPath];
    NSError *tempError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:temp
        withIntermediateDirectories:YES attributes:nil error:&tempError]) {
        if (error) *error = tempError;
        return NO;
    }

    FFArchiveHandle *archive = FFLibArchiveOpen(archivePath, password, error);
    if (!archive) {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        return NO;
    }
    FFLibArchiveAPI *api = FFLibArchiveAPIShared();
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *extracted = [NSMutableArray array];
    unsigned long long producedTotal = 0;
    NSUInteger completedEntries = 0;
    BOOL ok = YES;
    uint8_t *buffer = malloc(256 * 1024);
    if (!buffer) {
        if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorIO,
            @"无法分配解压缓冲区");
        ok = NO;
    }

    FFArchiveNativeEntry *native = NULL;
    while (ok) {
        if (shouldCancel && shouldCancel()) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"解压已取消"}];
            ok = NO;
            break;
        }

        int rc = api->read_next_header(archive, &native);
        if (rc == FF_ARCHIVE_EOF) break;
        if (rc < FF_ARCHIVE_WARN) {
            if (error) *error = FFLibArchiveError(archive, @"读取归档失败", password);
            ok = NO;
            break;
        }

        NSString *name = FFLibArchiveEntryPath(native, archivePath);
        if (!FFLibArchiveSafeEntryName(name)) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsafeEntry,
                [NSString stringWithFormat:@"不安全的归档路径，已拒绝解压：%@", name ?: @"(null)"]);
            ok = NO;
            break;
        }
        NSString *duplicateKey = [name hasSuffix:@"/"] ?
            [name substringToIndex:name.length - 1] : name;
        if ([seen containsObject:duplicateKey]) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsafeEntry,
                [NSString stringWithFormat:@"归档包含重复路径，已拒绝覆盖：%@", name]);
            ok = NO;
            break;
        }
        [seen addObject:duplicateKey];

        unsigned int type = api->entry_filetype(native) & FF_AE_IFMT;
        if (type == FF_AE_IFLNK || (type != 0 && type != FF_AE_IFREG && type != FF_AE_IFDIR)) {
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorUnsafeEntry,
                [NSString stringWithFormat:@"归档包含符号链接或特殊文件，已拒绝解压：%@", name]);
            ok = NO;
            break;
        }

        if (type == FF_AE_IFDIR) {
            NSError *mkdirError = nil;
            NSString *directory = [temp stringByAppendingPathComponent:name];
            if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
                if (error) *error = mkdirError;
                ok = NO;
                break;
            }
            [extracted addObject:name];
            completedEntries++;
            if (progressBlock) progressBlock(declaredTotal
                ? (double)producedTotal / (double)declaredTotal
                : (double)completedEntries / (double)plan.count, name);
            api->read_data_skip(archive);
            continue;
        }

        if (!FFLibArchiveEnsureParent(temp, name, error)) {
            ok = NO;
            break;
        }
        NSString *destination = [temp stringByAppendingPathComponent:name];
        int output = open(destination.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (output < 0) {
            int saved = errno;
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved
                userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                    @"创建解压文件失败：%@ (%s)", name, strerror(saved)]}];
            ok = NO;
            break;
        }

        FFArchiveInt64 declared = api->entry_size(native);
        unsigned long long entryProduced = 0;
        while (ok) {
            if (shouldCancel && shouldCancel()) {
                if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                    code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"解压已取消"}];
                ok = NO;
                break;
            }
            FFArchiveSSize count = api->read_data(archive, buffer, 256 * 1024);
            if (count == 0) break;
            if (count < 0) {
                if (error) *error = FFLibArchiveError(archive, @"解压数据读取失败", password);
                ok = NO;
                break;
            }
            if (!FFLibArchiveWriteAll(output, buffer, (size_t)count, destination, error)) {
                ok = NO;
                break;
            }
            entryProduced += (unsigned long long)count;
            producedTotal += (unsigned long long)count;
            if (entryProduced > kFFLibArchiveMaxSingleEntry ||
                producedTotal > kFFLibArchiveMaxTotal ||
                (declared >= 0 && entryProduced > (unsigned long long)declared)) {
                if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorTooLarge,
                    @"解压数据超出安全上限或声明大小，已中止");
                ok = NO;
                break;
            }
            if (progressBlock) progressBlock(declaredTotal
                ? MIN(1.0, (double)producedTotal / (double)declaredTotal)
                : (double)completedEntries / (double)plan.count, name);
        }
        close(output);
        if (!ok) {
            unlink(destination.fileSystemRepresentation);
            break;
        }
        if (declared >= 0 && entryProduced != (unsigned long long)declared) {
            unlink(destination.fileSystemRepresentation);
            if (error) *error = FFLibArchiveSimpleError(FFZipExtractErrorInvalidArchive,
                [NSString stringWithFormat:@"解压后大小与声明不符：%@", name]);
            ok = NO;
            break;
        }
        [extracted addObject:name];
        completedEntries++;
    }

    if (buffer) free(buffer);
    api->read_free(archive);

    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        return NO;
    }
    if (!FFLibArchiveCommitTempDirectory(temp, destinationDirectory, error)) {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        return NO;
    }

    if (entryNames) *entryNames = extracted.copy;
    if (progressBlock) progressBlock(1.0, @"");
    return YES;
}
