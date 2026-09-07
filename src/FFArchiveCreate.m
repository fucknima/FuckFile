#import "FFArchiveCreate.h"
#import "FFZipCreate.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <zlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

typedef struct archive FFWriteArchive;
typedef struct archive_entry FFWriteEntry;
typedef long FFArchiveSSize;

enum { FF_ARCHIVE_OK = 0, FF_ARCHIVE_WARN = -20 };

typedef struct {
    void *handle;
    FFWriteArchive *(*write_new)(void);
    int (*write_set_format_zip)(FFWriteArchive *);
    int (*write_set_format_pax_restricted)(FFWriteArchive *);
    int (*write_add_filter_none)(FFWriteArchive *);
    int (*write_set_options)(FFWriteArchive *, const char *);
    int (*write_set_passphrase)(FFWriteArchive *, const char *);
    int (*write_open_filename)(FFWriteArchive *, const char *);
    int (*write_header)(FFWriteArchive *, FFWriteEntry *);
    FFArchiveSSize (*write_data)(FFWriteArchive *, const void *, size_t);
    int (*write_finish_entry)(FFWriteArchive *);
    int (*write_close)(FFWriteArchive *);
    int (*write_free)(FFWriteArchive *);
    const char *(*error_string)(FFWriteArchive *);

    FFWriteEntry *(*entry_new)(void);
    void (*entry_free)(FFWriteEntry *);
    void (*entry_set_pathname_utf8)(FFWriteEntry *, const char *);
    void (*entry_set_filetype)(FFWriteEntry *, unsigned int);
    void (*entry_set_perm)(FFWriteEntry *, int);
    void (*entry_set_mtime)(FFWriteEntry *, long long, long);
    void (*entry_set_size)(FFWriteEntry *, long long);
} FFArchiveWriterAPI;

static FFArchiveWriterAPI *FFWriter(void)
{
    static FFArchiveWriterAPI api;
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

#define FF_REQ(field, symbol) do {     api.field = (__typeof__(api.field))dlsym(api.handle, symbol);     if (!api.field) { dlclose(api.handle); memset(&api, 0, sizeof(api)); return; } } while (0)
        FF_REQ(write_new, "archive_write_new");
        FF_REQ(write_set_format_zip, "archive_write_set_format_zip");
        FF_REQ(write_set_format_pax_restricted, "archive_write_set_format_pax_restricted");
        FF_REQ(write_add_filter_none, "archive_write_add_filter_none");
        FF_REQ(write_set_options, "archive_write_set_options");
        FF_REQ(write_set_passphrase, "archive_write_set_passphrase");
        FF_REQ(write_open_filename, "archive_write_open_filename");
        FF_REQ(write_header, "archive_write_header");
        FF_REQ(write_data, "archive_write_data");
        FF_REQ(write_finish_entry, "archive_write_finish_entry");
        FF_REQ(write_close, "archive_write_close");
        FF_REQ(write_free, "archive_write_free");
        FF_REQ(error_string, "archive_error_string");
        FF_REQ(entry_new, "archive_entry_new");
        FF_REQ(entry_free, "archive_entry_free");
        FF_REQ(entry_set_pathname_utf8, "archive_entry_set_pathname_utf8");
        FF_REQ(entry_set_filetype, "archive_entry_set_filetype");
        FF_REQ(entry_set_perm, "archive_entry_set_perm");
        FF_REQ(entry_set_mtime, "archive_entry_set_mtime");
        FF_REQ(entry_set_size, "archive_entry_set_size");
#undef FF_REQ
    });
    return api.handle ? &api : NULL;
}

@implementation FFArchiveCreateOptions
- (instancetype)init
{
    self = [super init];
    if (self) {
        _format = FFArchiveCreateFormatZIP;
        _zipCompression = FFZipCompressionLevelBalanced;
        _zipEncryption = FFZipEncryptionModeNone;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone
{
    FFArchiveCreateOptions *copy = [[[self class] allocWithZone:zone] init];
    copy.format = self.format;
    copy.zipCompression = self.zipCompression;
    copy.zipEncryption = self.zipEncryption;
    copy.password = self.password;
    return copy;
}
@end

static NSError *FFCreateError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"FFArchiveCreate" code:code userInfo:@{
        NSLocalizedDescriptionKey: message ?: @"创建压缩包失败"
    }];
}

BOOL FFArchiveEncryptedZIPWriterAvailable(void)
{
    return FFWriter() != NULL;
}

@interface FFCreatePlanEntry : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL directory;
@property(nonatomic) unsigned long long size;
@property(nonatomic) mode_t mode;
@property(nonatomic) time_t modified;
@end
@implementation FFCreatePlanEntry @end

static BOOL FFCollectCreateEntries(NSString *path, NSString *prefix,
                                   NSMutableArray<FFCreatePlanEntry *> *entries,
                                   NSMutableSet<NSString *> *seen, NSError **error)
{
    if (entries.count >= 100000) {
        if (error) *error = FFCreateError(EFBIG, @"归档条目过多（超过 100000 个）");
        return NO;
    }
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        if (error) *error = FFCreateError(errno ?: EIO,
            [NSString stringWithFormat:@"读取源文件失败：%@", path.lastPathComponent]);
        return NO;
    }
    if (S_ISLNK(st.st_mode)) return YES;
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) return YES;

    NSString *component = path.lastPathComponent;
    NSString *relative = prefix.length ? [prefix stringByAppendingPathComponent:component] : component;
    if (!relative.length || [relative hasPrefix:@"/"] ||
        [[relative pathComponents] containsObject:@".."]) {
        if (error) *error = FFCreateError(EINVAL, @"源文件包含不安全路径");
        return NO;
    }

    BOOL directory = S_ISDIR(st.st_mode);
    NSString *archiveName = directory ? [relative stringByAppendingString:@"/"] : relative;
    if ([seen containsObject:archiveName]) {
        if (error) *error = FFCreateError(EEXIST,
            [NSString stringWithFormat:@"归档中出现重复路径：%@", archiveName]);
        return NO;
    }
    [seen addObject:archiveName];

    FFCreatePlanEntry *entry = [FFCreatePlanEntry new];
    entry.path = path;
    entry.name = archiveName;
    entry.directory = directory;
    entry.size = directory ? 0 : (unsigned long long)MAX((off_t)0, st.st_size);
    entry.mode = st.st_mode & 0777;
#if defined(__APPLE__)
    entry.modified = st.st_mtimespec.tv_sec;
#else
    entry.modified = st.st_mtime;
#endif
    [entries addObject:entry];

    if (!directory) return YES;
    NSError *listError = nil;
    NSArray<NSString *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:path error:&listError];
    if (!children) {
        if (error) *error = listError ?: FFCreateError(EIO, @"读取源目录失败");
        return NO;
    }
    children = [children sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *child in children) {
        if (!FFCollectCreateEntries([path stringByAppendingPathComponent:child], relative,
                                    entries, seen, error))
            return NO;
    }
    return YES;
}

static NSError *FFWriterError(FFArchiveWriterAPI *api, FFWriteArchive *archive,
                              NSString *fallback)
{
    const char *raw = api->error_string ? api->error_string(archive) : NULL;
    NSString *message = raw ? [NSString stringWithUTF8String:raw] : nil;
    return FFCreateError(EIO, message.length ? message : fallback);
}

static BOOL FFWriteWithLibArchive(NSArray<NSString *> *sourcePaths,
                                  NSString *destinationPath,
                                  FFArchiveCreateOptions *options,
                                  void (^progressBlock)(double, NSString *),
                                  BOOL (^shouldCancel)(void), NSError **error)
{
    FFArchiveWriterAPI *api = FFWriter();
    if (!api) {
        if (error) *error = FFCreateError(ENOTSUP,
            @"当前系统没有可用的 libarchive 写入后端");
        return NO;
    }

    NSMutableArray<FFCreatePlanEntry *> *plan = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *source in sourcePaths) {
        if (!FFCollectCreateEntries(source, @"", plan, seen, error)) return NO;
    }
    if (!plan.count) {
        if (error) *error = FFCreateError(ENOENT, @"没有可压缩的文件");
        return NO;
    }

    unsigned long long total = 0;
    for (FFCreatePlanEntry *entry in plan) {
        if (ULLONG_MAX - total < entry.size) {
            if (error) *error = FFCreateError(EFBIG, @"源文件总大小超出支持范围");
            return NO;
        }
        total += entry.size;
    }

    NSString *parent = destinationPath.stringByDeletingLastPathComponent;
    NSString *temp = [parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.tmp", destinationPath.lastPathComponent,
            [NSUUID.UUID.UUIDString substringToIndex:8]]];
    [NSFileManager.defaultManager removeItemAtPath:temp error:nil];

    FFWriteArchive *archive = api->write_new();
    if (!archive) {
        if (error) *error = FFCreateError(ENOMEM, @"无法创建归档写入器");
        return NO;
    }

    BOOL ok = YES;
    int rc = FF_ARCHIVE_OK;
    if (options.format == FFArchiveCreateFormatZIP) {
        rc = api->write_set_format_zip(archive);
        if (rc >= FF_ARCHIVE_WARN) rc = api->write_add_filter_none(archive);
        if (rc >= FF_ARCHIVE_WARN) {
            NSString *compression = @"zip:compression=deflate,zip:compression-level=6";
            if (options.zipCompression == FFZipCompressionLevelSmallest)
                compression = @"zip:compression=deflate,zip:compression-level=9";
            else if (options.zipCompression == FFZipCompressionLevelStore)
                compression = @"zip:compression=store";
            NSMutableString *writerOptions = [compression mutableCopy];
            if (options.zipEncryption == FFZipEncryptionModeAES256 && options.password.length)
                [writerOptions appendString:@",zip:encryption=aes256"];
            rc = api->write_set_options(archive, writerOptions.UTF8String);
        }
        if (rc >= FF_ARCHIVE_WARN && options.password.length)
            rc = api->write_set_passphrase(archive, options.password.UTF8String);
    } else {
        if (options.password.length) {
            if (error) *error = FFCreateError(EINVAL, @"TAR 不支持密码加密");
            api->write_free(archive);
            return NO;
        }
        rc = api->write_set_format_pax_restricted(archive);
        if (rc >= FF_ARCHIVE_WARN) rc = api->write_add_filter_none(archive);
    }

    if (rc < FF_ARCHIVE_WARN) {
        if (error) *error = FFWriterError(api, archive, @"配置归档写入器失败");
        api->write_free(archive);
        return NO;
    }

    rc = api->write_open_filename(archive, temp.fileSystemRepresentation);
    if (rc < FF_ARCHIVE_WARN) {
        if (error) *error = FFWriterError(api, archive, @"创建归档文件失败");
        api->write_free(archive);
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        return NO;
    }

    uint8_t *buffer = malloc(256 * 1024);
    if (!buffer) {
        if (error) *error = FFCreateError(ENOMEM, @"无法分配压缩缓冲区");
        ok = NO;
    }

    unsigned long long completed = 0;
    for (FFCreatePlanEntry *item in plan) {
        if (!ok) break;
        if (shouldCancel && shouldCancel()) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"压缩已取消"}];
            ok = NO;
            break;
        }

        FFWriteEntry *entry = api->entry_new();
        if (!entry) {
            if (error) *error = FFCreateError(ENOMEM, @"无法创建归档条目");
            ok = NO;
            break;
        }
        api->entry_set_pathname_utf8(entry, item.name.UTF8String);
        api->entry_set_filetype(entry, item.directory ? S_IFDIR : S_IFREG);
        api->entry_set_perm(entry, (int)item.mode);
        api->entry_set_mtime(entry, item.modified, 0);
        api->entry_set_size(entry, item.directory ? 0 : (long long)item.size);

        rc = api->write_header(archive, entry);
        if (rc < FF_ARCHIVE_WARN) {
            if (error) *error = FFWriterError(api, archive,
                [NSString stringWithFormat:@"写入条目头失败：%@", item.name]);
            api->entry_free(entry);
            ok = NO;
            break;
        }

        if (!item.directory) {
            int fd = open(item.path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            if (fd < 0) {
                if (error) *error = FFCreateError(errno ?: EIO,
                    [NSString stringWithFormat:@"打开源文件失败：%@", item.name]);
                api->entry_free(entry);
                ok = NO;
                break;
            }

            unsigned long long sentForEntry = 0;
            while (ok) {
                if (shouldCancel && shouldCancel()) {
                    if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                        code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"压缩已取消"}];
                    ok = NO;
                    break;
                }
                ssize_t got;
                do { got = read(fd, buffer, 256 * 1024); } while (got < 0 && errno == EINTR);
                if (got < 0) {
                    if (error) *error = FFCreateError(errno ?: EIO,
                        [NSString stringWithFormat:@"读取源文件失败：%@", item.name]);
                    ok = NO;
                    break;
                }
                if (got == 0) break;

                size_t offset = 0;
                while (offset < (size_t)got) {
                    FFArchiveSSize written = api->write_data(archive,
                        buffer + offset, (size_t)got - offset);
                    if (written <= 0) {
                        if (error) *error = FFWriterError(api, archive,
                            [NSString stringWithFormat:@"写入压缩数据失败：%@", item.name]);
                        ok = NO;
                        break;
                    }
                    offset += (size_t)written;
                }
                sentForEntry += (unsigned long long)got;
                completed += (unsigned long long)got;
                if (progressBlock)
                    progressBlock(total ? MIN(1.0, (double)completed / (double)total) : 0,
                                  item.name);
            }
            close(fd);
            if (ok && sentForEntry != item.size) {
                if (error) *error = FFCreateError(EIO,
                    [NSString stringWithFormat:@"压缩期间源文件大小发生变化：%@", item.name]);
                ok = NO;
            }
        }

        if (ok && api->write_finish_entry(archive) < FF_ARCHIVE_WARN) {
            if (error) *error = FFWriterError(api, archive,
                [NSString stringWithFormat:@"结束归档条目失败：%@", item.name]);
            ok = NO;
        }
        api->entry_free(entry);
    }

    if (buffer) free(buffer);

    int closeStatus = api->write_close(archive);
    if (ok && closeStatus < FF_ARCHIVE_WARN) {
        if (error) *error = FFWriterError(api, archive, @"写入归档结束记录失败");
        ok = NO;
    }
    api->write_free(archive);

    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
        return NO;
    }

    int syncFD = open(temp.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (syncFD >= 0) {
        (void)fsync(syncFD);
        close(syncFD);
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backup = nil;
    if ([fm fileExistsAtPath:destinationPath]) {
        backup = [NSString stringWithFormat:@"%@.old%@", destinationPath,
            [NSUUID.UUID.UUIDString substringToIndex:8]];
        NSError *moveOld = nil;
        if (![fm moveItemAtPath:destinationPath toPath:backup error:&moveOld]) {
            [fm removeItemAtPath:temp error:nil];
            if (error) *error = moveOld;
            return NO;
        }
    }

    NSError *commit = nil;
    if (![fm moveItemAtPath:temp toPath:destinationPath error:&commit]) {
        if (backup.length) [fm moveItemAtPath:backup toPath:destinationPath error:nil];
        [fm removeItemAtPath:temp error:nil];
        if (error) *error = commit;
        return NO;
    }
    if (backup.length) [fm removeItemAtPath:backup error:nil];

    if (progressBlock) progressBlock(1.0, @"");
    return YES;
}

BOOL FFCreateArchive(NSArray<NSString *> *sourcePaths,
                     NSString *destinationPath,
                     FFArchiveCreateOptions *options,
                     void (^progressBlock)(double, NSString *),
                     BOOL (^shouldCancel)(void),
                     NSError **error)
{
    if (error) *error = nil;
    if (!options) options = [FFArchiveCreateOptions new];
    if (!sourcePaths.count || !destinationPath.length) {
        if (error) *error = FFCreateError(EINVAL, @"没有要压缩的文件");
        return NO;
    }

    if (options.format == FFArchiveCreateFormatTAR ||
        (options.format == FFArchiveCreateFormatZIP && options.password.length)) {
        return FFWriteWithLibArchive(sourcePaths, destinationPath, options,
                                     progressBlock, shouldCancel, error);
    }

    NSInteger zlibLevel = Z_DEFAULT_COMPRESSION;
    if (options.zipCompression == FFZipCompressionLevelSmallest) zlibLevel = 9;
    else if (options.zipCompression == FFZipCompressionLevelStore) zlibLevel = 0;
    return FFCreateZipArchiveWithLevel(sourcePaths, destinationPath, zlibLevel,
                                       progressBlock, shouldCancel, error);
}
