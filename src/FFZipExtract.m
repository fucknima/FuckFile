#import "FFZipExtract.h"

#import "unzip.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

// Extracts a zip-family archive via minizip (third_party/minizip).
// Function signature preserved from the original implementation so the
// task center keeps calling this unchanged.
//
// Safety rules carried over:
//  - entry count cap (100k) and total uncompressed size cap (4 GiB)
//    against zip bombs
//  - entry-name sanitization (".." / absolute paths rejected)
//  - duplicate entry names rejected (overwrite attack vector)
//  - symlink entries rejected
//  - extraction into a sibling temp dir, committed with a rename;
//    failed/cancelled runs clean up, existing destinations are backed
//    up to ".old*" and restored on any failure

#define FFX_MAX_ENTRIES 100000
#define FFX_MAX_TOTAL (4ULL * 1024 * 1024 * 1024)

static BOOL FFXSafeEntryName(NSString *name)
{
    if (name.length == 0 || name.length > 1024) return NO;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    if ([name rangeOfString:@".."].location != NSNotFound) return NO;
    return YES;
}

static BOOL FFXEnsureParent(NSString *directory, NSString *relative)
{
    NSString *parent = [directory stringByAppendingPathComponent:relative]
        .stringByDeletingLastPathComponent;
    return [[NSFileManager defaultManager] createDirectoryAtPath:parent
        withIntermediateDirectories:YES attributes:nil error:nil];
}

BOOL FFZipExtract(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  NSError * _Nullable * _Nullable error)
{
    return FFZipExtractWithProgress(archivePath, destDir, entryNames, nil, nil, error);
}

typedef struct {
    NSString *name;      // sanitized full path inside archive
    unsigned long long uncompressedSize;
    BOOL isDirectory;
} FFXEntry;

BOOL FFZipExtractWithProgress(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> **entryNames,
                  void (^progressBlock)(double, NSString *),
                  BOOL (^shouldCancel)(void),
                  NSError **error)
{
    if (entryNames) *entryNames = nil;

    unzFile zip = unzOpen64(archivePath.fileSystemRepresentation);
    if (!zip) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
            userInfo:@{NSLocalizedDescriptionKey:@"无法打开归档（不是有效的 ZIP 或已损坏）"}];
        return NO;
    }

    // ---- 第一遍：收集条目、累计总量，执行安全上限检查 ----
    NSMutableArray<FFXEntry *> *plan = [NSMutableArray array];
    unsigned long long totalUncompressed = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    int rc = unzGoToFirstFile(zip);
    while (rc == UNZ_OK) {
        char nameBuffer[2048];
        unz_file_info64 info;
        if (unzGetCurrentFileInfo64(zip, &info, nameBuffer, sizeof(nameBuffer),
                                    NULL, 0, NULL, 0) != UNZ_OK) {
            rc = UNZ_ERRNO;
            break;
        }
        NSString *name = [[NSString alloc] initWithBytes:nameBuffer
            length:strlen(nameBuffer) encoding:NSUTF8StringEncoding];
        if (!name.length) { rc = unzGoToNextFile(zip); continue; }

        // 符号链接条目：external attrs 高 16 位为 unix mode。
        mode_t unixMode = (mode_t)((info.external_fa >> 16) & 0xFFFF);
        if ((unixMode & S_IFMT) == S_IFLNK && unixMode != 0) {
            unzClose(zip);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
                userInfo:@{NSLocalizedDescriptionKey:@"归档包含符号链接条目，已拒绝解压"}];
            return NO;
        }
        if (!name.hasSuffix("/") && !FFXSafeEntryName(name)) {
            unzClose(zip);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"unsafe entry name: %@", name]}];
            return NO;
        }
        if (![seen containsObject:name]) {
            [seen addObject:name];
            FFXEntry *entry = [FFXEntry new];
            entry.name = name;
            entry.uncompressedSize = info.uncompressed_size;
            entry.isDirectory = [name hasSuffix:@"/"];
            [plan addObject:entry];
            totalUncompressed += info.uncompressed_size;
        }
        if (plan.count > FFX_MAX_ENTRIES || totalUncompressed > FFX_MAX_TOTAL) {
            unzClose(zip);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFBIG
                userInfo:@{NSLocalizedDescriptionKey:@"归档条目过多或解压后体积过大（疑似 ZIP 炸弹）"}];
            return NO;
        }
        rc = unzGoToNextFile(zip);
    }

    if (rc != UNZ_END_OF_LIST_OF_FILE && rc != UNZ_OK) {
        unzClose(zip);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey:@"读取归档目录失败（文件可能已损坏）"}];
        return NO;
    }
    if (plan.count == 0) {
        unzClose(zip);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EFTYPE
            userInfo:@{NSLocalizedDescriptionKey:@"归档为空或无法解析任何条目"}];
        return NO;
    }

    // ---- 提取到兄弟临时目录，成功后 rename 提交 ----
    NSString *tempDir = [NSString stringWithFormat:@"%@.%@.tmp", destDir,
        [[[NSUUID UUID] UUIDString] substringToIndex:8]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
        withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSString *> *extracted = [NSMutableArray array];
    unsigned long long producedTotal = 0;
    BOOL ok = YES;

    for (FFXEntry *entry in plan) {
        if ([entry.name hasSuffix:@"/"]) {
            if (!FFXSafeEntryName(entry.name)) {
                ok = NO;
                break;
            }
            [[NSFileManager defaultManager] createDirectoryAtPath:
                [tempDir stringByAppendingPathComponent:entry.name]
                withIntermediateDirectories:YES attributes:nil error:nil];
        } else {
            if (!FFXEnsureParent(tempDir, entry.name)) {
                ok = NO;
                break;
            }
            if (unzLocateFile(zip, entry.name.fileSystemRepresentation, 1) != UNZ_OK &&
                unzLocateFile(zip, entry.name.fileSystemRepresentation, 2) != UNZ_OK) {
                ok = NO;
                break;
            }
            if (unzOpenCurrentFilePassword(zip, NULL) != UNZ_OK) {
                ok = NO;
                break;
            }
            NSString *destination =
                [tempDir stringByAppendingPathComponent:entry.name];
            int output = open(destination.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_TRUNC | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
            if (output < 0) {
                unzCloseCurrentFile(zip);
                ok = NO;
                break;
            }
            static uint8_t buffer[64 * 1024];
            for (;;) {
                int bytesRead = unzReadCurrentFile(zip, buffer, sizeof(buffer));
                if (bytesRead == 0) break;
                if (bytesRead < 0) { ok = NO; break; }
                ssize_t written = write(output, buffer, (size_t)bytesRead);
                if (written != bytesRead) { ok = NO; break; }
                producedTotal += (unsigned long long)bytesRead;
            }
            close(output);
            // minizip 关闭当前文件时校验 CRC。
            if (ok && unzCloseCurrentFile(zip) != UNZ_OK) ok = NO;
            if (ok) {
                [extracted addObject:entry.name];
                if (progressBlock)
                    progressBlock(totalUncompressed > 0 ?
                        (double)producedTotal / (double)totalUncompressed : 0.0,
                        entry.name);
            } else {
                unlink(destination.fileSystemRepresentation);
            }
        }
        if (!ok) break;
        if (shouldCancel && shouldCancel()) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSUserCancelledError userInfo:@{
                    NSLocalizedDescriptionKey:@"解压已取消"}];
            ok = NO;
            break;
        }
    }

    unzClose(zip);

    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
        return NO;
    }

    // ---- 提交：备份旧目录 → 放入新目录 → 清理备份；失败恢复原状 ----
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *backupPath = nil;
    if ([manager fileExistsAtPath:destDir]) {
        backupPath = [NSString stringWithFormat:@"%@.old%@", destDir,
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        if (![manager moveItemAtPath:destDir toPath:backupPath error:error]) {
            [manager removeItemAtPath:tempDir error:nil];
            return NO;
        }
    }
    NSError *moveError = nil;
    if (![manager moveItemAtPath:tempDir toPath:destDir error:&moveError]) {
        if (backupPath)
            [manager moveItemAtPath:backupPath toPath:destDir error:nil];
        [manager removeItemAtPath:tempDir error:nil];
        if (error) *error = moveError;
        return NO;
    }
    if (backupPath)
        [manager removeItemAtPath:backupPath error:nil];

    if (entryNames) *entryNames = extracted;
    return YES;
}
