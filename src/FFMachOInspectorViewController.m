#import "FFMachOInspectorViewController.h"

#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/machine.h>

static const NSUInteger kFFMachOMaxSlices = 64;
static const NSUInteger kFFMachOMaxCommands = 16384;
static const NSUInteger kFFMachOMaxCommandBytes = 16 * 1024 * 1024;
static const NSUInteger kFFMachOMaxSignatureSlots = 64;
static const NSUInteger kFFMachOMaxStringBytes = 4096;

@interface FFMachORow : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value;
@end
@implementation FFMachORow @end

@interface FFMachOSection : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) NSArray<FFMachORow *> *rows;
@end
@implementation FFMachOSection @end

@interface FFMachOSlice : NSObject
@property(nonatomic, copy) NSString *architecture;
@property(nonatomic) uint64_t offset;
@property(nonatomic) uint64_t size;
@end
@implementation FFMachOSlice @end

static uint32_t FFReadBE32(const uint8_t *p)
{
    uint32_t v = 0;
    memcpy(&v, p, sizeof(v));
    return OSSwapBigToHostInt32(v);
}

static NSString *FFFixedCString(const char *bytes, NSUInteger count)
{
    NSUInteger length = 0;
    while (length < count && bytes[length]) length++;
    NSData *data = [NSData dataWithBytes:bytes length:length];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static NSString *FFMachOCPUName(cpu_type_t type, cpu_subtype_t subtype)
{
    cpu_subtype_t base = subtype & ~CPU_SUBTYPE_MASK;
    if (type == CPU_TYPE_ARM64) {
#ifdef CPU_SUBTYPE_ARM64E
        if (base == CPU_SUBTYPE_ARM64E) return @"arm64e";
#endif
        return @"arm64";
    }
    if (type == CPU_TYPE_ARM) return @"arm";
    if (type == CPU_TYPE_X86_64) return @"x86_64";
    if (type == CPU_TYPE_X86) return @"i386";
    return [NSString stringWithFormat:@"CPU %d / subtype %d", type, base];
}

static NSString *FFMachOFileTypeName(uint32_t type)
{
    switch (type) {
        case MH_OBJECT: return @"Object File";
        case MH_EXECUTE: return @"Executable";
        case MH_FVMLIB: return @"Fixed VM Library";
        case MH_CORE: return @"Core Dump";
        case MH_PRELOAD: return @"Preload";
        case MH_DYLIB: return @"Dynamic Library";
        case MH_DYLINKER: return @"Dynamic Linker";
        case MH_BUNDLE: return @"Bundle";
        case MH_DYLIB_STUB: return @"Library Stub";
        case MH_DSYM: return @"Debug Symbols";
        case MH_KEXT_BUNDLE: return @"Kernel Extension";
#ifdef MH_FILESET
        case MH_FILESET: return @"File Set";
#endif
        default: return [NSString stringWithFormat:@"0x%X", type];
    }
}

static NSString *FFMachOVersion(uint32_t value)
{
    return [NSString stringWithFormat:@"%u.%u.%u",
        (value >> 16) & 0xffff, (value >> 8) & 0xff, value & 0xff];
}

static NSString *FFMachOPlatform(uint32_t platform)
{
    switch (platform) {
#ifdef PLATFORM_MACOS
        case PLATFORM_MACOS: return @"macOS";
#endif
#ifdef PLATFORM_IOS
        case PLATFORM_IOS: return @"iOS";
#endif
#ifdef PLATFORM_TVOS
        case PLATFORM_TVOS: return @"tvOS";
#endif
#ifdef PLATFORM_WATCHOS
        case PLATFORM_WATCHOS: return @"watchOS";
#endif
#ifdef PLATFORM_BRIDGEOS
        case PLATFORM_BRIDGEOS: return @"bridgeOS";
#endif
#ifdef PLATFORM_MACCATALYST
        case PLATFORM_MACCATALYST: return @"Mac Catalyst";
#endif
#ifdef PLATFORM_IOSSIMULATOR
        case PLATFORM_IOSSIMULATOR: return @"iOS Simulator";
#endif
#ifdef PLATFORM_TVOSSIMULATOR
        case PLATFORM_TVOSSIMULATOR: return @"tvOS Simulator";
#endif
#ifdef PLATFORM_WATCHOSSIMULATOR
        case PLATFORM_WATCHOSSIMULATOR: return @"watchOS Simulator";
#endif
#ifdef PLATFORM_DRIVERKIT
        case PLATFORM_DRIVERKIT: return @"DriverKit";
#endif
        default: return [NSString stringWithFormat:@"Platform %u", platform];
    }
}

static NSString *FFMachOProtection(vm_prot_t protection)
{
    NSMutableString *s = [NSMutableString string];
    [s appendString:(protection & VM_PROT_READ) ? @"r" : @"-"];
    [s appendString:(protection & VM_PROT_WRITE) ? @"w" : @"-"];
    [s appendString:(protection & VM_PROT_EXECUTE) ? @"x" : @"-"];
    return s;
}

static NSString *FFMachOFlags(uint32_t flags)
{
    struct { uint32_t flag; __unsafe_unretained NSString *name; } values[] = {
        {MH_NOUNDEFS, @"NOUNDEFS"}, {MH_DYLDLINK, @"DYLDLINK"},
        {MH_TWOLEVEL, @"TWOLEVEL"}, {MH_PIE, @"PIE"},
        {MH_NO_HEAP_EXECUTION, @"NO_HEAP_EXECUTION"},
        {MH_APP_EXTENSION_SAFE, @"APP_EXTENSION_SAFE"},
#ifdef MH_HAS_TLV_DESCRIPTORS
        {MH_HAS_TLV_DESCRIPTORS, @"HAS_TLV_DESCRIPTORS"},
#endif
#ifdef MH_WEAK_DEFINES
        {MH_WEAK_DEFINES, @"WEAK_DEFINES"},
#endif
    };
    NSMutableArray *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < sizeof(values)/sizeof(values[0]); i++)
        if (flags & values[i].flag) [names addObject:values[i].name];
    return names.count ? [names componentsJoinedByString:@", "] :
        [NSString stringWithFormat:@"0x%08X", flags];
}

static NSString *FFMachOLoadCommandName(uint32_t command)
{
    uint32_t plain = command & ~LC_REQ_DYLD;
    switch (plain) {
        case LC_SEGMENT: return @"LC_SEGMENT";
        case LC_SYMTAB: return @"LC_SYMTAB";
        case LC_DYSYMTAB: return @"LC_DYSYMTAB";
        case LC_LOAD_DYLIB: return @"LC_LOAD_DYLIB";
        case LC_ID_DYLIB: return @"LC_ID_DYLIB";
        case LC_LOAD_DYLINKER: return @"LC_LOAD_DYLINKER";
#ifdef LC_RPATH
        case (LC_RPATH & ~LC_REQ_DYLD): return @"LC_RPATH";
#endif
        case LC_UUID: return @"LC_UUID";
#ifdef LC_CODE_SIGNATURE
        case LC_CODE_SIGNATURE: return @"LC_CODE_SIGNATURE";
#endif
#ifdef LC_ENCRYPTION_INFO
        case LC_ENCRYPTION_INFO: return @"LC_ENCRYPTION_INFO";
#endif
#ifdef LC_ENCRYPTION_INFO_64
        case LC_ENCRYPTION_INFO_64: return @"LC_ENCRYPTION_INFO_64";
#endif
#ifdef LC_MAIN
        case (LC_MAIN & ~LC_REQ_DYLD): return @"LC_MAIN";
#endif
#ifdef LC_BUILD_VERSION
        case LC_BUILD_VERSION: return @"LC_BUILD_VERSION";
#endif
#ifdef LC_SOURCE_VERSION
        case LC_SOURCE_VERSION: return @"LC_SOURCE_VERSION";
#endif
#ifdef LC_VERSION_MIN_IPHONEOS
        case LC_VERSION_MIN_IPHONEOS: return @"LC_VERSION_MIN_IPHONEOS";
#endif
#ifdef LC_REEXPORT_DYLIB
        case (LC_REEXPORT_DYLIB & ~LC_REQ_DYLD): return @"LC_REEXPORT_DYLIB";
#endif
#ifdef LC_LOAD_WEAK_DYLIB
        case (LC_LOAD_WEAK_DYLIB & ~LC_REQ_DYLD): return @"LC_LOAD_WEAK_DYLIB";
#endif
        default: return [NSString stringWithFormat:@"0x%X", command];
    }
}

static BOOL FFRangeInside(uint64_t offset, uint64_t length, uint64_t total)
{
    return offset <= total && length <= total - offset;
}

static NSString *FFLoadCommandString(const uint8_t *base, NSUInteger commandSize,
                                     uint32_t stringOffset)
{
    if (stringOffset >= commandSize) return nil;
    NSUInteger available = MIN(commandSize - stringOffset, kFFMachOMaxStringBytes);
    const char *text = (const char *)(base + stringOffset);
    NSUInteger length = strnlen(text, available);
    if (length == available) return nil;
    return [[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
}

static void FFSetMachOError(NSError **error, NSInteger code, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:@"FFMachO" code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Mach-O 结构无效"}];
}

static FFMachORow *FFRow(NSString *label, NSString *value)
{
    FFMachORow *row = [FFMachORow new];
    row.label = label ?: @"";
    row.value = value ?: @"";
    return row;
}

static NSString *FFCodeDirectoryCString(const uint8_t *blob, NSUInteger length, uint32_t offset)
{
    if (offset >= length) return nil;
    NSUInteger max = MIN(length - offset, kFFMachOMaxStringBytes);
    const char *bytes = (const char *)(blob + offset);
    NSUInteger count = strnlen(bytes, max);
    if (count == max) return nil;
    return [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
}

static NSDictionary *FFParseCodeSignature(const uint8_t *bytes, NSUInteger length)
{
    if (length < 12) return @{};
    uint32_t magic = FFReadBE32(bytes);
    if (magic != 0xfade0cc0) return @{@"状态":@"存在代码签名数据"};
    uint32_t totalLength = FFReadBE32(bytes + 4);
    uint32_t count = FFReadBE32(bytes + 8);
    if (totalLength > length || count > kFFMachOMaxSignatureSlots ||
        12ULL + (uint64_t)count * 8ULL > totalLength)
        return @{@"状态":@"代码签名索引损坏或超限"};

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"状态"] = @"Signed";
    for (uint32_t i = 0; i < count; i++) {
        uint32_t type = FFReadBE32(bytes + 12 + i * 8);
        uint32_t offset = FFReadBE32(bytes + 16 + i * 8);
        if (offset + 8 > totalLength) continue;
        const uint8_t *blob = bytes + offset;
        uint32_t blobMagic = FFReadBE32(blob);
        uint32_t blobLength = FFReadBE32(blob + 4);
        if (blobLength < 8 || offset + blobLength > totalLength) continue;

        if (blobMagic == 0xfade0c02 && blobLength >= 44) {
            uint32_t version = FFReadBE32(blob + 8);
            uint32_t flags = FFReadBE32(blob + 12);
            uint32_t identifierOffset = FFReadBE32(blob + 20);
            NSString *identifier = FFCodeDirectoryCString(blob, blobLength, identifierOffset);
            if (identifier.length) result[@"Signing Identifier"] = identifier;
            result[@"Signature Flags"] = [NSString stringWithFormat:@"0x%08X", flags];
            if (version >= 0x20200 && blobLength >= 52) {
                uint32_t teamOffset = FFReadBE32(blob + 48);
                NSString *team = FFCodeDirectoryCString(blob, blobLength, teamOffset);
                if (team.length) result[@"Team Identifier"] = team;
            }
        } else if (blobMagic == 0xfade7171 || type == 5) {
            NSData *payload = [NSData dataWithBytes:blob + 8 length:blobLength - 8];
            NSError *plistError = nil;
            id plist = [NSPropertyListSerialization propertyListWithData:payload
                options:NSPropertyListImmutable format:nil error:&plistError];
            if ([plist isKindOfClass:NSDictionary.class]) {
                NSDictionary *dict = plist;
                NSMutableArray *pairs = [NSMutableArray array];
                for (NSString *key in [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                    id value = dict[key];
                    NSString *rendered = [value isKindOfClass:NSString.class] ? value :
                        ([value isKindOfClass:NSNumber.class] ? [value description] :
                         ([value isKindOfClass:NSArray.class] ? [(NSArray *)value componentsJoinedByString:@", "] :
                          [value description]));
                    [pairs addObject:[NSString stringWithFormat:@"%@ = %@", key, rendered ?: @""]];
                }
                if (pairs.count) result[@"Entitlements"] = [pairs componentsJoinedByString:@"\n"];
            } else if (payload.length) {
                NSString *xml = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
                if (xml.length) result[@"Entitlements"] = xml;
            }
        }
    }
    return result;
}

@interface FFMachOInspectorViewController ()
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) NSData *mappedData;
@property(nonatomic, strong) NSArray<FFMachOSection *> *sections;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation FFMachOInspectorViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    BOOL directory = NO;
    if (!path.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] ||
        directory)
        return nil;
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _filePath = [path copy];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;

    NSString *path = self.filePath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:&error];
        NSArray *sections = data ? [weakSelf parseData:data error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.spinner stopAnimating];
            self.tableView.backgroundView = nil;
            if (!sections) {
                [self showFailure:error.localizedDescription ?: @"无法解析 Mach-O"];
                return;
            }
            self.mappedData = data;
            self.sections = sections;
            [self.tableView reloadData];
        });
    });
}

- (NSArray<FFMachOSection *> *)parseData:(NSData *)data error:(NSError **)error
{
    if (data.length < 4) {
        if (error) *error = [NSError errorWithDomain:@"FFMachO" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"文件过短，不是有效 Mach-O"}];
        return nil;
    }

    const uint8_t *bytes = data.bytes;
    uint32_t magic = 0;
    memcpy(&magic, bytes, 4);
    NSMutableArray<FFMachOSlice *> *slices = [NSMutableArray array];

    if (magic == FAT_MAGIC || magic == FAT_CIGAM ||
#ifdef FAT_MAGIC_64
        magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64 ||
#endif
        NO) {
        BOOL swap = (magic == FAT_CIGAM
#ifdef FAT_CIGAM_64
            || magic == FAT_CIGAM_64
#endif
        );
#ifdef FAT_MAGIC_64
        BOOL fat64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
#else
        BOOL fat64 = NO;
#endif
        if (data.length < sizeof(struct fat_header)) { FFSetMachOError(error, 3, @"Mach-O 结构越界或已损坏"); return nil; }
        const struct fat_header *header = (const struct fat_header *)bytes;
        uint32_t count = swap ? OSSwapInt32(header->nfat_arch) : header->nfat_arch;
        if (count == 0 || count > kFFMachOMaxSlices) {
            if (error) *error = [NSError errorWithDomain:@"FFMachO" code:2
                userInfo:@{NSLocalizedDescriptionKey:@"Universal Mach-O 切片数量无效或超过 64"}];
            return nil;
        }

        uint64_t tableOffset = sizeof(struct fat_header);
        uint64_t stride = fat64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
        if (!FFRangeInside(tableOffset, (uint64_t)count * stride, data.length)) { FFSetMachOError(error, 3, @"Mach-O 结构越界或已损坏"); return nil; }

        for (uint32_t i = 0; i < count; i++) {
            cpu_type_t cpu = 0;
            cpu_subtype_t subtype = 0;
            uint64_t offset = 0, size = 0;
            if (fat64) {
#ifdef FAT_MAGIC_64
                const struct fat_arch_64 *arch =
                    (const struct fat_arch_64 *)(bytes + tableOffset + i * stride);
                cpu = swap ? (cpu_type_t)OSSwapInt32(arch->cputype) : arch->cputype;
                subtype = swap ? (cpu_subtype_t)OSSwapInt32(arch->cpusubtype) : arch->cpusubtype;
                offset = swap ? OSSwapInt64(arch->offset) : arch->offset;
                size = swap ? OSSwapInt64(arch->size) : arch->size;
#endif
            } else {
                const struct fat_arch *arch =
                    (const struct fat_arch *)(bytes + tableOffset + i * stride);
                cpu = swap ? (cpu_type_t)OSSwapInt32(arch->cputype) : arch->cputype;
                subtype = swap ? (cpu_subtype_t)OSSwapInt32(arch->cpusubtype) : arch->cpusubtype;
                offset = swap ? OSSwapInt32(arch->offset) : arch->offset;
                size = swap ? OSSwapInt32(arch->size) : arch->size;
            }
            if (!size || !FFRangeInside(offset, size, data.length)) { FFSetMachOError(error, 3, @"Mach-O 结构越界或已损坏"); return nil; }
            FFMachOSlice *slice = [FFMachOSlice new];
            slice.architecture = FFMachOCPUName(cpu, subtype);
            slice.offset = offset;
            slice.size = size;
            [slices addObject:slice];
        }
    } else {
        FFMachOSlice *slice = [FFMachOSlice new];
        slice.architecture = @"Mach-O";
        slice.offset = 0;
        slice.size = data.length;
        [slices addObject:slice];
    }

    NSMutableArray<FFMachOSection *> *sections = [NSMutableArray array];
    for (NSUInteger index = 0; index < slices.count; index++) {
        FFMachOSection *section = [self parseSlice:slices[index] data:data
            universal:slices.count > 1 error:error];
        if (!section) return nil;
        [sections addObject:section];
    }
    return sections;
}

- (FFMachOSection *)parseSlice:(FFMachOSlice *)slice
                          data:(NSData *)data
                     universal:(BOOL)universal
                         error:(NSError **)error
{
    const uint8_t *file = data.bytes;
    const uint8_t *base = file + slice.offset;
    if (slice.size < sizeof(uint32_t)) { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }

    uint32_t magic = 0;
    memcpy(&magic, base, 4);
    BOOL is64 = magic == MH_MAGIC_64;
    BOOL is32 = magic == MH_MAGIC;
    if (!is64 && !is32) {
        if (error) *error = [NSError errorWithDomain:@"FFMachO" code:10
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"%@ 切片不是受支持的本机字节序 Mach-O",
                    slice.architecture]}];
        return nil;
    }

    uint32_t ncmds = 0, sizeofcmds = 0, filetype = 0, flags = 0;
    cpu_type_t cpu = 0;
    cpu_subtype_t subtype = 0;
    NSUInteger headerSize = is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    if (slice.size < headerSize) { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }

    if (is64) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)base;
        cpu = h->cputype; subtype = h->cpusubtype; filetype = h->filetype;
        ncmds = h->ncmds; sizeofcmds = h->sizeofcmds; flags = h->flags;
    } else {
        const struct mach_header *h = (const struct mach_header *)base;
        cpu = h->cputype; subtype = h->cpusubtype; filetype = h->filetype;
        ncmds = h->ncmds; sizeofcmds = h->sizeofcmds; flags = h->flags;
    }
    if (ncmds > kFFMachOMaxCommands || sizeofcmds > kFFMachOMaxCommandBytes ||
        !FFRangeInside(headerSize, sizeofcmds, slice.size))
        { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }

    NSMutableArray<FFMachORow *> *rows = [NSMutableArray array];
    NSString *architecture = FFMachOCPUName(cpu, subtype);
    [rows addObject:FFRow(@"类型", FFMachOFileTypeName(filetype))];
    [rows addObject:FFRow(@"架构", architecture)];
    if (universal)
        [rows addObject:FFRow(@"切片", [NSString stringWithFormat:@"offset 0x%llX · %@",
            slice.offset, [NSByteCountFormatter stringFromByteCount:(long long)slice.size
                countStyle:NSByteCountFormatterCountStyleFile]])];
    [rows addObject:FFRow(@"Flags", FFMachOFlags(flags))];

    NSMutableArray<NSString *> *libraries = [NSMutableArray array];
    NSMutableArray<NSString *> *rpaths = [NSMutableArray array];
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    NSMutableArray<NSString *> *commandNames = [NSMutableArray array];
    NSString *uuid = nil, *platform = nil, *minimum = nil, *sdk = nil;
    NSString *sourceVersion = nil, *entryOffset = nil, *encryption = @"未加密";
    uint64_t signatureOffset = 0, signatureSize = 0;
    uint32_t symbolCount = 0;
    BOOL hasSymbolCount = NO;

    uint64_t cursor = headerSize;
    for (uint32_t index = 0; index < ncmds; index++) {
        if (!FFRangeInside(cursor, sizeof(struct load_command), slice.size)) { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }
        const struct load_command *lc = (const struct load_command *)(base + cursor);
        uint32_t cmd = lc->cmd, cmdsize = lc->cmdsize;
        if (cmdsize < sizeof(struct load_command) ||
            !FFRangeInside(cursor, cmdsize, headerSize + sizeofcmds))
            { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }
        const uint8_t *commandBase = base + cursor;
        [commandNames addObject:FFMachOLoadCommandName(cmd)];

        uint32_t plain = cmd & ~LC_REQ_DYLD;
        if (cmd == LC_UUID && cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uc = (const struct uuid_command *)commandBase;
            NSUUID *value = [[NSUUID alloc] initWithUUIDBytes:uc->uuid];
            uuid = value.UUIDString;
#ifdef LC_BUILD_VERSION
        } else if (cmd == LC_BUILD_VERSION && cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *bc =
                (const struct build_version_command *)commandBase;
            platform = FFMachOPlatform(bc->platform);
            minimum = FFMachOVersion(bc->minos);
            sdk = FFMachOVersion(bc->sdk);
#endif
#ifdef LC_VERSION_MIN_IPHONEOS
        } else if (cmd == LC_VERSION_MIN_IPHONEOS && cmdsize >= sizeof(struct version_min_command)) {
            const struct version_min_command *vc =
                (const struct version_min_command *)commandBase;
            platform = @"iOS";
            minimum = FFMachOVersion(vc->version);
            sdk = FFMachOVersion(vc->sdk);
#endif
#ifdef LC_SOURCE_VERSION
        } else if (cmd == LC_SOURCE_VERSION && cmdsize >= sizeof(struct source_version_command)) {
            const struct source_version_command *sc =
                (const struct source_version_command *)commandBase;
            uint64_t v = sc->version;
            sourceVersion = [NSString stringWithFormat:@"%llu.%llu.%llu.%llu.%llu",
                (v >> 40) & 0xffffff, (v >> 30) & 0x3ff, (v >> 20) & 0x3ff,
                (v >> 10) & 0x3ff, v & 0x3ff];
#endif
#ifdef LC_MAIN
        } else if (plain == (LC_MAIN & ~LC_REQ_DYLD) &&
                   cmdsize >= sizeof(struct entry_point_command)) {
            const struct entry_point_command *ec =
                (const struct entry_point_command *)commandBase;
            entryOffset = [NSString stringWithFormat:@"0x%llX", ec->entryoff];
#endif
        } else if (cmd == LC_SYMTAB && cmdsize >= sizeof(struct symtab_command)) {
            const struct symtab_command *sc = (const struct symtab_command *)commandBase;
            symbolCount = sc->nsyms;
            hasSymbolCount = YES;
#ifdef LC_CODE_SIGNATURE
        } else if (cmd == LC_CODE_SIGNATURE && cmdsize >= sizeof(struct linkedit_data_command)) {
            const struct linkedit_data_command *cc =
                (const struct linkedit_data_command *)commandBase;
            signatureOffset = cc->dataoff;
            signatureSize = cc->datasize;
#endif
#ifdef LC_ENCRYPTION_INFO
        } else if (cmd == LC_ENCRYPTION_INFO && cmdsize >= sizeof(struct encryption_info_command)) {
            const struct encryption_info_command *ec =
                (const struct encryption_info_command *)commandBase;
            if (ec->cryptid)
                encryption = [NSString stringWithFormat:@"已加密 · cryptid %u · offset 0x%X · %u bytes",
                    ec->cryptid, ec->cryptoff, ec->cryptsize];
#endif
#ifdef LC_ENCRYPTION_INFO_64
        } else if (cmd == LC_ENCRYPTION_INFO_64 && cmdsize >= sizeof(struct encryption_info_command_64)) {
            const struct encryption_info_command_64 *ec =
                (const struct encryption_info_command_64 *)commandBase;
            if (ec->cryptid)
                encryption = [NSString stringWithFormat:@"已加密 · cryptid %u · offset 0x%X · %u bytes",
                    ec->cryptid, ec->cryptoff, ec->cryptsize];
#endif
        }

        BOOL dylibCommand = plain == LC_LOAD_DYLIB || plain == LC_ID_DYLIB;
#ifdef LC_LOAD_WEAK_DYLIB
        dylibCommand = dylibCommand || plain == (LC_LOAD_WEAK_DYLIB & ~LC_REQ_DYLD);
#endif
#ifdef LC_REEXPORT_DYLIB
        dylibCommand = dylibCommand || plain == (LC_REEXPORT_DYLIB & ~LC_REQ_DYLD);
#endif
        if (dylibCommand && cmdsize >= sizeof(struct dylib_command)) {
            const struct dylib_command *dc = (const struct dylib_command *)commandBase;
            NSString *name = FFLoadCommandString(commandBase, cmdsize, dc->dylib.name.offset);
            if (name.length) [libraries addObject:name];
        }

#ifdef LC_RPATH
        if (plain == (LC_RPATH & ~LC_REQ_DYLD) && cmdsize >= sizeof(struct rpath_command)) {
            const struct rpath_command *rc = (const struct rpath_command *)commandBase;
            NSString *value = FFLoadCommandString(commandBase, cmdsize, rc->path.offset);
            if (value.length) [rpaths addObject:value];
        }
#endif

        if (cmd == LC_SEGMENT_64 && cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)commandBase;
            uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
            if (sizeof(*seg) + sectionBytes > cmdsize) { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }
            NSMutableArray *names = [NSMutableArray array];
            const struct section_64 *sections =
                (const struct section_64 *)(commandBase + sizeof(*seg));
            for (uint32_t i = 0; i < seg->nsects; i++) {
                NSString *sectionName = FFFixedCString(sections[i].sectname, 16);
                if (sectionName.length) [names addObject:sectionName];
            }
            NSString *segName = FFFixedCString(seg->segname, 16);
            [segments addObject:[NSString stringWithFormat:
                @"%@ · %@ · VM 0x%llX + 0x%llX · File 0x%llX + 0x%llX%@",
                segName, FFMachOProtection(seg->initprot), seg->vmaddr, seg->vmsize,
                seg->fileoff, seg->filesize,
                names.count ? [NSString stringWithFormat:@" · [%@]",
                    [names componentsJoinedByString:@", "]] : @""]];
        } else if (cmd == LC_SEGMENT && cmdsize >= sizeof(struct segment_command)) {
            const struct segment_command *seg =
                (const struct segment_command *)commandBase;
            uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section);
            if (sizeof(*seg) + sectionBytes > cmdsize) { FFSetMachOError(error, 11,
    [NSString stringWithFormat:@"%@ Mach-O Load Commands 越界或已损坏",
        slice.architecture]); return nil; }
            NSMutableArray *names = [NSMutableArray array];
            const struct section *sections =
                (const struct section *)(commandBase + sizeof(*seg));
            for (uint32_t i = 0; i < seg->nsects; i++) {
                NSString *sectionName = FFFixedCString(sections[i].sectname, 16);
                if (sectionName.length) [names addObject:sectionName];
            }
            NSString *segName = FFFixedCString(seg->segname, 16);
            [segments addObject:[NSString stringWithFormat:
                @"%@ · %@ · VM 0x%X + 0x%X · File 0x%X + 0x%X%@",
                segName, FFMachOProtection(seg->initprot), seg->vmaddr, seg->vmsize,
                seg->fileoff, seg->filesize,
                names.count ? [NSString stringWithFormat:@" · [%@]",
                    [names componentsJoinedByString:@", "]] : @""]];
        }

        cursor += cmdsize;
    }

    if (uuid.length) [rows addObject:FFRow(@"UUID", uuid)];
    if (platform.length) [rows addObject:FFRow(@"平台", platform)];
    if (minimum.length) [rows addObject:FFRow(@"最低系统", minimum)];
    if (sdk.length) [rows addObject:FFRow(@"SDK", sdk)];
    if (sourceVersion.length) [rows addObject:FFRow(@"Source Version", sourceVersion)];
    if (entryOffset.length) [rows addObject:FFRow(@"Entry Offset", entryOffset)];
    if (hasSymbolCount) [rows addObject:FFRow(@"Symbols", [NSString stringWithFormat:@"%u", symbolCount])];
    [rows addObject:FFRow(@"Encryption", encryption)];
    [rows addObject:FFRow(@"Linked Libraries",
        libraries.count ? [libraries componentsJoinedByString:@"\n"] : @"无")];
    [rows addObject:FFRow(@"Runpaths",
        rpaths.count ? [rpaths componentsJoinedByString:@"\n"] : @"无")];
    [rows addObject:FFRow(@"Segments / Sections",
        segments.count ? [segments componentsJoinedByString:@"\n"] : @"无")];
    [rows addObject:FFRow(@"Load Commands",
        commandNames.count ? [commandNames componentsJoinedByString:@", "] : @"无")];

    if (signatureSize &&
        FFRangeInside(signatureOffset, signatureSize, slice.size)) {
        NSDictionary *signature = FFParseCodeSignature(base + signatureOffset,
            (NSUInteger)signatureSize);
        [rows addObject:FFRow(@"Code Signature",
            [NSString stringWithFormat:@"offset 0x%llX · %@",
                signatureOffset,
                [NSByteCountFormatter stringFromByteCount:(long long)signatureSize
                    countStyle:NSByteCountFormatterCountStyleFile]])];
        for (NSString *key in @[@"Signing Identifier", @"Team Identifier",
                                @"Signature Flags", @"Entitlements", @"状态"]) {
            NSString *value = [signature[key] isKindOfClass:NSString.class] ? signature[key] : nil;
            if (value.length) [rows addObject:FFRow(key, value)];
        }
    } else {
        [rows addObject:FFRow(@"Code Signature", @"无")];
    }

    FFMachOSection *result = [FFMachOSection new];
    result.title = universal ? architecture : @"Mach-O";
    result.rows = rows;
    return result;
}

- (void)showFailure:(NSString *)message
{
    UILabel *label = [UILabel new];
    label.text = message;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.frame = CGRectMake(24, 0, MAX(0, self.tableView.bounds.size.width - 48), 140);
    self.tableView.backgroundView = label;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section < self.sections.count ? self.sections[section].rows.count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return section < self.sections.count ? self.sections[section].title : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MachO"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"MachO"];
    FFMachORow *row = self.sections[indexPath.section].rows[indexPath.row];
    cell.textLabel.text = row.label;
    cell.detailTextLabel.text = row.value;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                      point:(CGPoint)point
{
    (void)tableView; (void)point;
    FFMachORow *row = self.sections[indexPath.section].rows[indexPath.row];
    if (!row.value.length) return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggested) {
            (void)suggested;
            UIAction *copy = [UIAction actionWithTitle:@"复制"
                image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                handler:^(__unused UIAction *action) {
                    UIPasteboard.generalPasteboard.string = row.value;
                }];
            return [UIMenu menuWithTitle:@"" children:@[copy]];
        }];
}

@end
