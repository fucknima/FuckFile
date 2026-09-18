import Compression
import CoreFoundation
import Foundation

/// ZIP 读取用桥接头暴露的 minizip C API，写入用 Apple Compression（裸 DEFLATE）或 store。
/// 安全校验与原子提交对齐 src/FFZipExtract.m、src/FFZipCreate.m：
/// 拒绝 `..`/绝对路径/反斜杠逃逸、符号链接与特殊文件条目；目标目录唯一化；
/// 写入走临时文件 + rename；解压总量超 4 GiB 中止。
enum ZipArchive {

    /// 解压总量安全上限（对齐 ObjC 的 4 GiB）。
    static let maxTotalUncompressedSize: UInt64 = 4 * 1024 * 1024 * 1024
    /// 单包最大条目数（对齐 ObjC 的 100000）。
    static let maxEntryCount = 100_000

    private static let maxNameBytes = 64 * 1024
    private static let maxEntryNameLength = 1024
    private static let fileTypeMask: mode_t = 0o170000
    private static let fileTypeDirectory: mode_t = 0o040000
    private static let fileTypeRegular: mode_t = 0o100000
    private static let fileTypeSymlink: mode_t = 0o120000
    private static let ioBufferSize = 256 * 1024
    /// 单文件超过此大小走 store，避免整文件读入内存。
    /// ponytail: 需要压缩大文件时改用 compression_stream 流式 DEFLATE。
    private static let deflateMemoryLimit: UInt64 = 64 * 1024 * 1024

    // MARK: - 公开 API

    /// 列出归档条目。加密包也能列出（中央目录不加密），密码只在读取数据时需要。
    static func entries(at archivePath: String) throws -> [ZipArchiveEntry] {
        let zip = try openArchive(archivePath)
        defer { _ = unzClose(zip) }
        return try listEntries(zip)
    }

    /// 提取单个文件条目，返回实际落盘路径（同名时唯一化为 `xxx (2)`）。
    @discardableResult
    static func extract(at archivePath: String,
                        entry entryName: String,
                        toDirectory: String,
                        password: String? = nil) throws -> String {
        guard !entryName.isEmpty, !entryName.hasSuffix("/") else {
            throw ZipArchiveError.io("目录条目无法直接提取为文件")
        }
        guard isSafeEntryName(entryName) else {
            throw ZipArchiveError.unsafeEntry("不安全的条目名，已拒绝提取")
        }
        let zip = try openArchive(archivePath)
        defer { _ = unzClose(zip) }
        let plan = try buildPlan(zip)
        guard let entry = plan.first(where: { $0.name == entryName }) else {
            throw ZipArchiveError.io("归档中不存在该条目")
        }
        if entry.isEncrypted && (password?.isEmpty ?? true) {
            throw ZipArchiveError.passwordRequired
        }
        let manager = FileManager.default
        try manager.createDirectory(atPath: toDirectory, withIntermediateDirectories: true)
        let base = (entryName as NSString).lastPathComponent
        let destination = uniqueExtractionPath(
            (toDirectory as NSString).appendingPathComponent(base.isEmpty ? "entry" : base))
        try extractEntryData(zip, entry: entry, destination: destination,
                             password: password, progress: nil, shouldCancel: nil)
        return destination
    }

    /// 提取全部条目：目标目录唯一化后原子提交，返回实际使用的目录路径。
    @discardableResult
    static func extractAll(at archivePath: String,
                           toDirectory: String,
                           password: String? = nil,
                           progress: ((Double, String) -> Void)? = nil,
                           shouldCancel: (() -> Bool)? = nil) throws -> String {
        guard !archivePath.isEmpty, !toDirectory.isEmpty else {
            throw ZipArchiveError.invalidArchive("归档或目标路径无效")
        }
        let zip = try openArchive(archivePath)
        defer { _ = unzClose(zip) }
        let plan = try buildPlan(zip)
        guard !plan.isEmpty else {
            throw ZipArchiveError.invalidArchive("归档为空或无法解析任何条目")
        }
        if plan.contains(where: { $0.isEncrypted }) && (password?.isEmpty ?? true) {
            throw ZipArchiveError.passwordRequired
        }

        let manager = FileManager.default
        let parent = (toDirectory as NSString).deletingLastPathComponent
        let base = (toDirectory as NSString).lastPathComponent
        let safeBase = base.isEmpty ? "archive" : base
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let destination = uniqueExtractionPath(
            (parent as NSString).appendingPathComponent(safeBase))
        let tempDir = (parent as NSString).appendingPathComponent(
            ".\(safeBase).\(String(UUID().uuidString.prefix(8))).tmp")
        try manager.createDirectory(atPath: tempDir, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? manager.removeItem(atPath: tempDir) } }

        let total = plan.reduce(UInt64(0)) { $0 + $1.size }
        var completed: UInt64 = 0
        for entry in plan {
            if shouldCancel?() == true { throw ZipArchiveError.cancelled }
            if entry.isDirectory {
                try manager.createDirectory(
                    atPath: (tempDir as NSString).appendingPathComponent(entry.name),
                    withIntermediateDirectories: true)
                continue
            }
            let target = (tempDir as NSString).appendingPathComponent(entry.name)
            try manager.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
            try extractEntryData(zip, entry: entry, destination: target, password: password,
                                 progress: { produced in
                progress?(total > 0 ? Double(completed + produced) / Double(total) : 0, entry.name)
            }, shouldCancel: shouldCancel)
            completed += entry.size
        }

        if manager.fileExists(atPath: destination) {
            let fallback = uniqueExtractionPath(
                (parent as NSString).appendingPathComponent(safeBase))
            try manager.moveItem(atPath: tempDir, toPath: fallback)
            committed = true
            progress?(1, "")
            return fallback
        }
        try manager.moveItem(atPath: tempDir, toPath: destination)
        committed = true
        progress?(1, "")
        return destination
    }

    /// 把若干文件/目录压缩为标准 ZIP（临时文件 + rename 原子提交）。
    static func createZip(from sources: [String],
                          to destination: String,
                          progress: ((Double, String) -> Void)? = nil,
                          shouldCancel: (() -> Bool)? = nil) throws {
        guard !sources.isEmpty, !destination.isEmpty else {
            throw ZipArchiveError.io("没有要压缩的文件")
        }
        let standardizedDestination = (destination as NSString).standardizingPath
        for source in sources where (source as NSString).standardizingPath == standardizedDestination {
            throw ZipArchiveError.io("压缩目标不能是源文件本身")
        }

        var plan: [SourceEntry] = []
        var names = Set<String>()
        for source in sources {
            try collectEntries(source, prefix: "", entries: &plan, names: &names)
        }
        guard !plan.isEmpty else { throw ZipArchiveError.io("没有可压缩的文件") }
        let targetName = (destination as NSString).lastPathComponent
        guard !plan.contains(where: { $0.relativeName == targetName }) else {
            throw ZipArchiveError.io("压缩目标与源文件同名")
        }
        guard plan.count < Int(UInt16.max) else {
            throw ZipArchiveError.tooLarge("归档条目过多（超过 65535 个）")
        }
        let total = plan.reduce(UInt64(0)) { $0 + $1.size }

        let manager = FileManager.default
        let parent = (destination as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let safeName = targetName.isEmpty ? "archive.zip" : targetName
        let tempPath = (parent as NSString).appendingPathComponent(
            ".\(safeName).\(String(UUID().uuidString.prefix(8))).tmp")
        guard manager.createFile(atPath: tempPath, contents: nil) else {
            throw ZipArchiveError.io("创建压缩临时文件失败")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        } catch {
            try? manager.removeItem(atPath: tempPath)
            throw ZipArchiveError.io("创建压缩临时文件失败：\(error.localizedDescription)")
        }

        var records: [WrittenEntry] = []
        var completed: UInt64 = 0
        do {
            for source in plan {
                if shouldCancel?() == true { throw ZipArchiveError.cancelled }
                records.append(try writeLocalEntry(handle, source, completed: &completed,
                                                   total: total, progress: progress,
                                                   shouldCancel: shouldCancel))
            }
            let centralOffset = handle.offsetInFile
            guard centralOffset < UInt64(UInt32.max) else {
                throw ZipArchiveError.tooLarge("压缩包超出 ZIP32 支持范围（4 GiB），已中止")
            }
            for record in records { try writeCentralEntry(handle, record) }
            let centralSize = handle.offsetInFile - centralOffset
            guard centralSize < UInt64(UInt32.max) else {
                throw ZipArchiveError.tooLarge("压缩包目录超出 ZIP32 支持范围（4 GiB），已中止")
            }
            try writeEndRecord(handle, count: UInt64(records.count),
                               centralOffset: centralOffset, centralSize: centralSize)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? manager.removeItem(atPath: tempPath)
            throw error
        }

        guard rename(tempPath, destination) == 0 else {
            try? manager.removeItem(atPath: tempPath)
            throw ZipArchiveError.io("替换压缩目标失败：\(safeName)")
        }
        progress?(1, "")
    }

    // MARK: - 打开与列目录

    /// 解压目标唯一化：`xxx (2)`、`xxx (3)`…（对齐 P3B 约定）。
    private static func uniqueExtractionPath(_ path: String) -> String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return path }
        let parent = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let fileExtension = (base as NSString).pathExtension
        var index = 2
        while index < 1000 {
            var candidateName = "\(stem) (\(index))"
            if !fileExtension.isEmpty { candidateName += ".\(fileExtension)" }
            let candidate = (parent as NSString).appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate) { return candidate }
            index += 1
        }
        return (parent as NSString).appendingPathComponent("\(stem) (\(index))")
    }

    private static func openArchive(_ path: String) throws -> unzFile {
        let handle = path.withCString { unzOpen64($0) }
        guard let handle else {
            throw ZipArchiveError.invalidArchive("无法打开归档（不是有效的 ZIP 或已损坏）")
        }
        return handle
    }

    private static func listEntries(_ zip: unzFile) throws -> [ZipArchiveEntry] {
        var result: [ZipArchiveEntry] = []
        var status = unzGoToFirstFile(zip)
        while status == UNZ_OK {
            if let (name, info, _) = currentEntryName(zip) {
                result.append(ZipArchiveEntry(
                    name: name,
                    size: UInt64(info.uncompressed_size),
                    compressedSize: UInt64(info.compressed_size),
                    isDirectory: name.hasSuffix("/"),
                    isEncrypted: (info.flag & 0x1) != 0))
                if result.count >= maxEntryCount { break }
            }
            status = unzGoToNextFile(zip)
        }
        guard status == UNZ_END_OF_LIST_OF_FILE || status == UNZ_OK else {
            throw ZipArchiveError.invalidArchive("读取归档目录失败（文件可能已损坏）")
        }
        return result
    }

    /// 读取当前条目的文件名（UTF-8 / Info-ZIP Unicode Path / GB18030 / Latin-1 回退）。
    private static func currentEntryName(_ zip: unzFile)
        -> (name: String, info: unz_file_info64, position: unz64_file_pos)? {
        var info = unz_file_info64()
        guard unzGetCurrentFileInfo64(zip, &info, nil, 0, nil, 0, nil, 0) == UNZ_OK else {
            return nil
        }
        guard info.size_filename > 0, info.size_filename <= UInt(maxNameBytes),
              info.size_file_extra <= UInt(maxNameBytes) else { return nil }

        var rawName = [UInt8](repeating: 0, count: Int(info.size_filename))
        var extra = [UInt8](repeating: 0, count: Int(info.size_file_extra))
        let readResult: Int32 = rawName.withUnsafeMutableBytes { nameBuffer in
            extra.withUnsafeMutableBytes { extraBuffer in
                unzGetCurrentFileInfo64(
                    zip,
                    &info,
                    nameBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    UInt(nameBuffer.count),
                    extraBuffer.baseAddress,
                    UInt(extraBuffer.count),
                    nil,
                    0)
            }
        }
        guard readResult == UNZ_OK else { return nil }

        let nameData = Data(rawName)
        var decoded: String?
        if (info.flag & 0x800) != 0 {
            decoded = String(data: nameData, encoding: .utf8)
        } else {
            decoded = unicodePath(from: nameData, extra: Data(extra))
            if decoded == nil { decoded = String(data: nameData, encoding: .utf8) }
            if decoded == nil { decoded = String(data: nameData, encoding: gb18030Encoding) }
            if decoded == nil { decoded = String(data: nameData, encoding: .isoLatin1) }
        }
        guard let name = decoded, !name.isEmpty else { return nil }

        var position = unz64_file_pos()
        guard unzGetFilePos64(zip, &position) == UNZ_OK else { return nil }
        return (name, info, position)
    }

    private static let gb18030Encoding: String.Encoding = {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }()

    /// Info-ZIP Unicode Path Extra Field（0x7075）。
    private static func unicodePath(from rawName: Data, extra: Data) -> String? {
        let bytes = [UInt8](extra)
        var offset = 0
        while offset + 4 <= bytes.count {
            let headerID = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let payloadSize = Int(UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8))
            offset += 4
            guard payloadSize <= bytes.count - offset else { break }
            if headerID == 0x7075, payloadSize >= 5, bytes[offset] == 1 {
                let expectedCRC = UInt32(bytes[offset + 1])
                    | (UInt32(bytes[offset + 2]) << 8)
                    | (UInt32(bytes[offset + 3]) << 16)
                    | (UInt32(bytes[offset + 4]) << 24)
                let actualCRC = rawName.withUnsafeBytes { crc32($0) }
                if actualCRC == expectedCRC {
                    let payload = Data(bytes[(offset + 5)..<(offset + payloadSize)])
                    if let decoded = String(data: payload, encoding: .utf8), !decoded.isEmpty {
                        return decoded
                    }
                }
            }
            offset += payloadSize
        }
        return nil
    }

    // MARK: - 解压计划与安全校验

    private struct PlannedEntry {
        let name: String
        let size: UInt64
        let compressedSize: UInt64
        let isDirectory: Bool
        let isEncrypted: Bool
        let position: unz64_file_pos
    }

    private static func buildPlan(_ zip: unzFile) throws -> [PlannedEntry] {
        var plan: [PlannedEntry] = []
        var seen = Set<String>()
        var total: UInt64 = 0
        var status = unzGoToFirstFile(zip)
        while status == UNZ_OK {
            guard let (name, info, position) = currentEntryName(zip) else {
                throw ZipArchiveError.invalidArchive("归档包含无法解码的文件名条目")
            }
            guard isSafeEntryName(name) else {
                throw ZipArchiveError.unsafeEntry("不安全的归档路径，已拒绝解压：\(name)")
            }
            let isDirectory = name.hasSuffix("/")
            let unixMode = mode_t((info.external_fa >> 16) & 0xFFFF)
            let fileType = unixMode & fileTypeMask
            if unixMode != 0 && fileType != fileTypeDirectory && fileType != fileTypeRegular {
                throw ZipArchiveError.unsafeEntry("归档包含符号链接或特殊文件条目，已拒绝解压")
            }
            if !isDirectory {
                if info.compression_method == 99 {
                    throw ZipArchiveError.unsupportedCompression("该压缩包使用 WinZip AES 加密，暂不支持解压")
                }
                if info.compression_method != 0 && info.compression_method != 8 {
                    throw ZipArchiveError.unsupportedCompression(
                        "不支持的 ZIP 压缩方式：\(info.compression_method)")
                }
            }
            guard seen.insert(name).inserted else {
                throw ZipArchiveError.unsafeEntry("归档包含重复路径，已拒绝覆盖：\(name)")
            }
            let entrySize = UInt64(info.uncompressed_size)
            if entrySize > maxTotalUncompressedSize
                || total > maxTotalUncompressedSize - entrySize {
                throw ZipArchiveError.tooLarge("归档解压后体积过大（超过 4 GiB 安全上限）")
            }
            total += entrySize
            plan.append(PlannedEntry(
                name: name,
                size: entrySize,
                compressedSize: UInt64(info.compressed_size),
                isDirectory: isDirectory,
                isEncrypted: (info.flag & 0x1) != 0,
                position: position))
            if plan.count > maxEntryCount {
                throw ZipArchiveError.tooLarge("归档条目过多（超过 100000 个）")
            }
            status = unzGoToNextFile(zip)
        }
        guard status == UNZ_END_OF_LIST_OF_FILE else {
            throw ZipArchiveError.invalidArchive("读取归档目录失败（文件可能已损坏）")
        }
        return plan
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxEntryNameLength else { return false }
        guard !name.hasPrefix("/"), !name.hasPrefix("\\") else { return false }
        guard !name.contains("\0") else { return false }
        let slashed = name.replacingOccurrences(of: "\\", with: "/")
        for component in slashed.split(separator: "/", omittingEmptySubsequences: false)
        where component == ".." || component == "." {
            return false
        }
        return true
    }

    /// 定位并解压当前计划条目；先写 `.part` 临时文件，成功后才 rename 到目标。
    private static func extractEntryData(_ zip: unzFile,
                                         entry: PlannedEntry,
                                         destination: String,
                                         password: String?,
                                         progress: ((UInt64) -> Void)?,
                                         shouldCancel: (() -> Bool)?) throws {
        var position = entry.position
        guard unzGoToFilePos64(zip, &position) == UNZ_OK else {
            throw ZipArchiveError.io("无法定位归档条目：\(entry.name)")
        }

        let openResult: Int32
        if entry.isEncrypted {
            guard let password, !password.isEmpty else {
                throw ZipArchiveError.passwordRequired
            }
            openResult = password.withCString { unzOpenCurrentFilePassword(zip, $0) }
        } else {
            openResult = unzOpenCurrentFile(zip)
        }
        guard openResult == UNZ_OK else {
            throw entry.isEncrypted
                ? ZipArchiveError.wrongPassword
                : ZipArchiveError.io("无法打开归档条目：\(entry.name)")
        }

        let tempPath = destination + ".part" + String(UUID().uuidString.prefix(8))
        let descriptor = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            _ = unzCloseCurrentFile(zip)
            throw ZipArchiveError.io("创建解压文件失败：\(entry.name)")
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: ioBufferSize)
        defer { buffer.deallocate() }
        var produced: UInt64 = 0
        var failure: ZipArchiveError?
        while true {
            if shouldCancel?() == true { failure = .cancelled; break }
            let bytesRead = unzReadCurrentFile(zip, buffer, UInt32(ioBufferSize))
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                failure = entry.isEncrypted
                    ? ZipArchiveError.wrongPassword
                    : ZipArchiveError.io("读取压缩数据失败：\(entry.name)")
                break
            }
            if !writeAll(descriptor, buffer, Int(bytesRead)) {
                failure = ZipArchiveError.io("写入解压文件失败：\(entry.name)")
                break
            }
            produced += UInt64(bytesRead)
            if produced > entry.size || produced > maxTotalUncompressedSize {
                failure = ZipArchiveError.tooLarge("解压数据超出声明大小，已中止")
                break
            }
            progress?(produced)
        }
        close(descriptor)
        let closeResult = unzCloseCurrentFile(zip)
        if failure == nil && closeResult != UNZ_OK {
            failure = entry.isEncrypted
                ? ZipArchiveError.wrongPassword
                : ZipArchiveError.invalidArchive("CRC 校验失败：\(entry.name)")
        }
        if failure == nil && produced != entry.size {
            failure = entry.isEncrypted
                ? ZipArchiveError.wrongPassword
                : ZipArchiveError.invalidArchive("解压后大小与声明不符：\(entry.name)")
        }
        if let failure {
            _ = unlink(tempPath)
            throw failure
        }
        guard rename(tempPath, destination) == 0 else {
            _ = unlink(tempPath)
            throw ZipArchiveError.io("提交解压文件失败：\(entry.name)")
        }
    }

    private static func writeAll(_ descriptor: Int32,
                                 _ buffer: UnsafeMutablePointer<UInt8>,
                                 _ length: Int) -> Bool {
        var offset = 0
        while offset < length {
            let written = write(descriptor, buffer + offset, length - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    // MARK: - 压缩（Apple Compression / store）

    private struct SourceEntry {
        let relativeName: String
        let absolutePath: String
        let isDirectory: Bool
        let size: UInt64
        let mode: mode_t
        let modified: Date
    }

    private struct WrittenEntry {
        let source: SourceEntry
        let localOffset: UInt64
        let crc: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
    }

    /// 与 ObjC 一致：已压缩格式、小文件直接 store。
    private static let storedExtensions: Set<String> = [
        "zip", "ipa", "deb", "7z", "rar", "gz", "xz", "bz2",
        "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff",
        "mp3", "m4a", "aac", "flac", "mp4", "mov", "m4v",
    ]

    private static func collectEntries(_ path: String,
                                       prefix: String,
                                       entries: inout [SourceEntry],
                                       names: inout Set<String>) throws {
        guard entries.count < maxEntryCount else {
            throw ZipArchiveError.tooLarge("归档条目过多（超过 100000 个）")
        }
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw ZipArchiveError.io("读取源文件失败：\((path as NSString).lastPathComponent)")
        }
        let fileType = status.st_mode & fileTypeMask
        if fileType == fileTypeSymlink { return }
        guard fileType == fileTypeDirectory || fileType == fileTypeRegular else { return }

        let name = (path as NSString).lastPathComponent
        let relative = prefix.isEmpty ? name : (prefix as NSString).appendingPathComponent(name)
        guard !relative.isEmpty, !relative.hasPrefix("/") else {
            throw ZipArchiveError.unsafeEntry("源文件包含不安全的归档路径")
        }
        let isDirectory = fileType == fileTypeDirectory
        let archiveName = isDirectory ? relative + "/" : relative
        guard archiveName.utf8.count <= Int(UInt16.max) else {
            throw ZipArchiveError.io("归档路径过长：\(archiveName)")
        }
        guard names.insert(archiveName).inserted else {
            throw ZipArchiveError.unsafeEntry("归档中出现重复路径：\(archiveName)")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date()
        entries.append(SourceEntry(relativeName: archiveName,
                                   absolutePath: path,
                                   isDirectory: isDirectory,
                                   size: isDirectory ? 0 : UInt64(max(0, status.st_size)),
                                   mode: status.st_mode,
                                   modified: modified))
        guard isDirectory else { return }
        let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        for child in children {
            try collectEntries((path as NSString).appendingPathComponent(child),
                               prefix: relative, entries: &entries, names: &names)
        }
    }

    private static func writeLocalEntry(_ handle: FileHandle,
                                        _ source: SourceEntry,
                                        completed: inout UInt64,
                                        total: UInt64,
                                        progress: ((Double, String) -> Void)?,
                                        shouldCancel: (() -> Bool)?) throws -> WrittenEntry {
        let nameData = Data(source.relativeName.utf8)
        let localOffset = handle.offsetInFile
        guard localOffset < UInt64(UInt32.max) else {
            throw ZipArchiveError.tooLarge("压缩包超出 ZIP32 支持范围（4 GiB），已中止")
        }
        let extensionName = (source.relativeName as NSString).pathExtension.lowercased()
        let useDeflate = !source.isDirectory
            && source.size >= 128
            && source.size <= deflateMemoryLimit
            && !storedExtensions.contains(extensionName)

        var method: UInt16 = 0
        var crc: UInt32 = 0
        var payload: Data?
        if useDeflate {
            let data = try Data(contentsOf: URL(fileURLWithPath: source.absolutePath),
                                options: .mappedIfSafe)
            guard UInt64(data.count) == source.size else {
                throw ZipArchiveError.io("压缩期间源文件大小发生变化：\(source.relativeName)")
            }
            crc = data.withUnsafeBytes { crc32($0) }
            if let compressed = deflate(data), compressed.count < data.count {
                method = 8
                payload = compressed
            } else {
                method = 0
                payload = data
            }
        }

        let (dosTime, dosDate) = dosDateTime(source.modified)
        var header = Data()
        header.appendUInt32(0x04034b50)
        header.appendUInt16(20)
        header.appendUInt16(0x0800)
        header.appendUInt16(method)
        header.appendUInt16(dosTime)
        header.appendUInt16(dosDate)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt16(UInt16(nameData.count))
        header.appendUInt16(0)
        header.append(nameData)
        try handle.write(contentsOf: header)

        var compressedSize: UInt64 = 0
        var uncompressedSize: UInt64 = 0
        if source.isDirectory {
            // 目录条目没有数据。
        } else if let payload {
            try handle.write(contentsOf: payload)
            compressedSize = UInt64(payload.count)
            uncompressedSize = method == 8 ? source.size : UInt64(payload.count)
            completed += source.size
            progress?(total > 0 ? Double(completed) / Double(total) : 0, source.relativeName)
        } else {
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.absolutePath))
            defer { try? input.close() }
            var rollingCRC: UInt32 = 0
            while true {
                if shouldCancel?() == true { throw ZipArchiveError.cancelled }
                let chunk = try input.read(upToCount: ioBufferSize) ?? Data()
                if chunk.isEmpty { break }
                rollingCRC = chunk.withUnsafeBytes { crc32($0, seed: rollingCRC) }
                try handle.write(contentsOf: chunk)
                let count = UInt64(chunk.count)
                compressedSize += count
                uncompressedSize += count
                completed += count
                progress?(total > 0 ? Double(completed) / Double(total) : 0, source.relativeName)
            }
            crc = rollingCRC
            guard uncompressedSize == source.size else {
                throw ZipArchiveError.io("压缩期间源文件大小发生变化：\(source.relativeName)")
            }
        }

        guard compressedSize < UInt64(UInt32.max), uncompressedSize < UInt64(UInt32.max) else {
            throw ZipArchiveError.tooLarge("单个条目超出 ZIP32 支持范围（4 GiB）：\(source.relativeName)")
        }
        let end = handle.offsetInFile
        try handle.seek(toOffset: localOffset + 14)
        var patch = Data()
        patch.appendUInt32(crc)
        patch.appendUInt32(UInt32(compressedSize))
        patch.appendUInt32(UInt32(uncompressedSize))
        try handle.write(contentsOf: patch)
        try handle.seek(toOffset: end)

        return WrittenEntry(source: source,
                            localOffset: localOffset,
                            crc: crc,
                            compressedSize: compressedSize,
                            uncompressedSize: uncompressedSize,
                            method: method,
                            dosTime: dosTime,
                            dosDate: dosDate)
    }

    private static func writeCentralEntry(_ handle: FileHandle, _ record: WrittenEntry) throws {
        let nameData = Data(record.source.relativeName.utf8)
        let external = (UInt32(record.source.mode & 0xFFFF) << 16)
            | (record.source.isDirectory ? 0x10 : 0)
        var data = Data()
        data.appendUInt32(0x02014b50)
        data.appendUInt16((3 << 8) | 20)
        data.appendUInt16(20)
        data.appendUInt16(0x0800)
        data.appendUInt16(record.method)
        data.appendUInt16(record.dosTime)
        data.appendUInt16(record.dosDate)
        data.appendUInt32(record.crc)
        data.appendUInt32(UInt32(record.compressedSize))
        data.appendUInt32(UInt32(record.uncompressedSize))
        data.appendUInt16(UInt16(nameData.count))
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt32(external)
        data.appendUInt32(UInt32(record.localOffset))
        data.append(nameData)
        try handle.write(contentsOf: data)
    }

    private static func writeEndRecord(_ handle: FileHandle,
                                       count: UInt64,
                                       centralOffset: UInt64,
                                       centralSize: UInt64) throws {
        var data = Data()
        data.appendUInt32(0x06054b50)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(UInt16(count))
        data.appendUInt16(UInt16(count))
        data.appendUInt32(UInt32(centralSize))
        data.appendUInt32(UInt32(centralOffset))
        data.appendUInt16(0)
        try handle.write(contentsOf: data)
    }

    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + max(64 * 1024, data.count / 1000) + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let month = components.month ?? 1
        let dayOfMonth = components.day ?? 1
        let timeValue = (hour & 31) << 11 | (minute & 63) << 5 | (second / 2) & 31
        let dayValue = ((year - 1980) & 0x7F) << 9 | (month & 15) << 5 | (dayOfMonth & 31)
        return (UInt16(timeValue), UInt16(dayValue))
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ bytes: UnsafeRawBufferPointer, seed: UInt32 = 0) -> UInt32 {
        var crc = seed ^ 0xFFFFFFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - 条目与错误

struct ZipArchiveEntry: Hashable {
    let name: String
    let size: UInt64
    let compressedSize: UInt64
    let isDirectory: Bool
    let isEncrypted: Bool
}

enum ZipArchiveError: LocalizedError, Equatable {
    case invalidArchive(String)
    case unsafeEntry(String)
    case unsupportedCompression(String)
    case tooLarge(String)
    case passwordRequired
    case wrongPassword
    case io(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let message),
             .unsafeEntry(let message),
             .unsupportedCompression(let message),
             .tooLarge(let message),
             .io(let message):
            return message
        case .passwordRequired:
            return "该 ZIP 已加密，需要输入密码"
        case .wrongPassword:
            return "ZIP 密码错误或加密数据已损坏"
        case .cancelled:
            return "操作已取消"
        }
    }

    /// 密码相关错误：UI 据此弹密码输入框。
    var needsPassword: Bool {
        switch self {
        case .passwordRequired, .wrongPassword: return true
        default: return false
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
