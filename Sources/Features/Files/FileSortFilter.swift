import Foundation

/// 排序方式（阶段 2 冻结接口）。
enum FileSortMode: String, CaseIterable, Identifiable {
    case name, size, date, kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .date: return "修改时间"
        case .kind: return "类型"
        }
    }

    var icon: String {
        switch self {
        case .name: return "textformat"
        case .size: return "arrow.up.arrow.down"
        case .date: return "calendar"
        case .kind: return "square.grid.2x2"
        }
    }

    /// 过滤后的排序：文件夹恒在前（不受升降序影响），主字段相同按名称兜底。
    func sort(_ entries: [FileEntry], ascending: Bool) -> [FileEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            var result = primaryComparison(left, right)
            if result == .orderedSame {
                result = left.name.localizedStandardCompare(right.name)
            }
            return (ascending ? result : result.flipped) == .orderedAscending
        }
    }

    private func primaryComparison(_ left: FileEntry, _ right: FileEntry) -> ComparisonResult {
        switch self {
        case .name:
            return left.name.localizedStandardCompare(right.name)
        case .size:
            if left.size == right.size { return .orderedSame }
            return left.size < right.size ? .orderedAscending : .orderedDescending
        case .date:
            let leftDate = left.modificationDate ?? .distantPast
            let rightDate = right.modificationDate ?? .distantPast
            return leftDate.compare(rightDate)
        case .kind:
            return Self.kindName(left).localizedStandardCompare(Self.kindName(right))
        }
    }

    /// 类型排序键（与 ObjC 版 kindName: 对齐）。
    private static func kindName(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "目录" }
        if entry.isSymlink { return "符号链接" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
    }
}

/// 筛选方式（阶段 2 冻结接口）。分类筛选按扩展名集合判断；目录在分类
/// 筛选下始终保留（与 ObjC 版一致），`.folder` 只留目录，`.other` 收
/// 未归入任何已知类别的文件。
enum FileFilterMode: String, CaseIterable, Identifiable {
    case all, folder, image, video, audio, document, archive, code, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .folder: return "文件夹"
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .document: return "文档"
        case .archive: return "压缩包"
        case .code: return "代码"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .folder: return "folder"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .archive: return "shippingbox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    func matches(_ entry: FileEntry) -> Bool {
        if self == .all { return true }
        if self == .folder { return entry.isDirectory }
        if entry.isDirectory { return true }
        return Self.category(forExtension: (entry.name as NSString).pathExtension) == self
    }

    /// 已知扩展名 → 分类；未知扩展名与无扩展名都归 `.other`。
    static func category(forExtension rawExtension: String) -> FileFilterMode {
        let ext = rawExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if archiveExtensions.contains(ext) { return .archive }
        if codeExtensions.contains(ext) { return .code }
        return .other
    }

    // 扩展名表取自 FFBrowserViewController.m 的筛选表，并合并
    // FFFileAssociationService.m 的关联分类；.deb 无解析后端，不算压缩包。
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif",
        "bmp", "ico", "car", "svg",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "3gp",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "caf", "flac",
        "aif", "aiff", "aifc", "m4b", "m4p", "m4r",
    ]
    private static let documentExtensions: Set<String> = [
        "txt", "log", "md", "mdown", "list", "json", "xml", "plist", "csv", "tsv",
        "pdf", "rtf", "rtfd", "doc", "docx", "docm", "dot", "dotx", "dotm",
        "odt", "fodt", "ott", "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx",
        "xltm", "ods", "fods", "ots", "dif", "dbf", "slk", "sylk",
        "pages", "numbers", "key", "ppt", "pptx", "pptm", "pps", "ppsx",
        "ppsm", "pot", "potx", "potm", "odp", "fodp", "otp",
        "wps", "wpt", "et", "ett", "dps", "dpt",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "ipa", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2",
        "tbz", "tbz2", "txz",
    ]
    private static let codeExtensions: Set<String> = [
        "c", "h", "m", "mm", "cpp", "cc", "swift", "sh", "py", "js", "ts",
        "html", "htm", "css", "java", "kt", "go", "rs", "rb", "php",
        "as", "as3", "clisp", "script", "applescript",
    ]
}

private extension ComparisonResult {
    var flipped: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
