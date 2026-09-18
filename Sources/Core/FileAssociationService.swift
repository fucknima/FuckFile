import Foundation

/// 扩展名 → 查看器关联。内置默认写在代码里；用户改动只以覆盖项存
/// UserDefaults（键 `FFViewerOverride.<ext>`，值为 ViewerID.rawValue）。
///
/// 匹配按最长后缀优先（backup.tar.gz 先试 tar.gz 再试 gz），大小写不敏感，
/// 前导点与首尾空白会被规整。同一后缀上覆盖项优先于内置默认。
enum FileAssociationService {
    private static let overrideKeyPrefix = "FFViewerOverride."

    /// 内置默认表，照抄 FFDefaultAssociations()。键为小写、不带点；
    /// tar.gz 这类复合键参与最长后缀匹配。.deb 刻意不收录（无专用查看器，
    /// 也不按压缩包处理），会走未知扩展名 → quickLook。
    private static let defaultAssociations: [String: ViewerID] = [
        // 文本编辑器（.sh/.script/.applescript 仅按文本打开，不执行）
        "txt": .text, "log": .text, "md": .text,
        "mdown": .text, "json": .text, "xml": .text,
        "c": .text, "h": .text, "m": .text, "mm": .text,
        "cpp": .text, "cc": .text, "py": .text, "php": .text,
        "js": .text, "css": .text, "as": .text, "as3": .text,
        "clisp": .text, "sh": .text, "script": .text,
        "applescript": .text, "list": .text,
        "plist": .plist,
        "sqlite": .sqlite, "sqlite3": .sqlite, "sqlitedb": .sqlite, "db": .sqlite,
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image,
        "heic": .image, "webp": .image, "bmp": .image, "tif": .image,
        "tiff": .image, "ico": .image, "car": .image,
        "mp3": .media, "wav": .media, "m4a": .media, "aac": .media,
        "aif": .media, "aiff": .media, "aifc": .media, "caf": .media,
        "m4b": .media, "m4p": .media, "m4r": .media, "flac": .media,
        "mov": .media, "mp4": .media, "m4v": .media, "3gp": .media,
        "avi": .media, "mkv": .media,
        "html": .web, "htm": .web, "url": .web, "webloc": .web,
        "hex": .hex, "dat": .hex,
        "dylib": .macho, "so": .macho,
        "ipa": .archive,
        "zip": .archive, "tar": .archive, "tar.gz": .archive,
        "tgz": .archive, "tar.bz2": .archive, "tbz": .archive,
        "tbz2": .archive, "tar.xz": .archive, "txz": .archive,
        "gz": .archive, "7z": .archive, "rar": .archive,
        "xz": .archive, "bz2": .archive,

        // 离线 Office 阅读器；docx 家族与 doc/ppt 等共用统一查看器。
        "docx": .office, "docm": .office,
        "dotx": .office, "dotm": .office,
        "xls": .spreadsheet, "xlsx": .spreadsheet, "xlsm": .spreadsheet,
        "xlsb": .spreadsheet, "xlt": .spreadsheet, "xltx": .spreadsheet,
        "xltm": .spreadsheet, "csv": .spreadsheet, "tsv": .spreadsheet,
        "ods": .spreadsheet, "dif": .spreadsheet, "dbf": .spreadsheet,
        "slk": .spreadsheet, "sylk": .spreadsheet,

        "doc": .office, "dot": .office,
        "rtf": .office, "rtfd": .office,
        "odt": .office, "fodt": .office, "ott": .office,
        "ppt": .office, "pptx": .office, "pptm": .office,
        "pps": .office, "ppsx": .office, "ppsm": .office,
        "pot": .office, "potx": .office, "potm": .office,
        "odp": .office, "fodp": .office, "otp": .office,
        "fods": .office, "ots": .office,
        "pages": .office, "numbers": .office, "key": .office,
        "wps": .office, "wpt": .office,
        "et": .office, "ett": .office,
        "dps": .office, "dpt": .office,

        // PDF 默认仍是系统 Quick Look，PDFKit 阅读器可由用户手动关联。
        "pdf": .quickLook,
    ]

    /// 扩展名（小写、不带点）→ 默认查看器；未知或空扩展名 → .quickLook。
    static func defaultViewerID(forExtension ext: String) -> ViewerID {
        defaultViewerID(forNormalizedKey: normalize(ext)) ?? .quickLook
    }

    /// 用户覆盖优先，其次默认；按路径最长后缀匹配，均无 → .quickLook。
    static func viewerID(forPath path: String) -> ViewerID {
        let name = (path as NSString).lastPathComponent.lowercased()
        for suffix in suffixCandidates(in: name) {
            if let viewer = override(forExtension: suffix) { return viewer }
            if let viewer = defaultViewerID(forNormalizedKey: suffix) { return viewer }
        }
        return .quickLook
    }

    /// 读取该扩展名的用户覆盖；未设置或存的是非法 ViewerID → nil。
    static func override(forExtension ext: String) -> ViewerID? {
        let key = normalize(ext)
        guard !key.isEmpty,
              let raw = UserDefaults.standard.string(forKey: overrideKeyPrefix + key)
        else { return nil }
        return ViewerID(rawValue: raw)
    }

    /// 设置用户覆盖；viewer 为 nil 时删除该键，恢复内置默认。
    static func setOverride(_ viewer: ViewerID?, forExtension ext: String) {
        let key = normalize(ext)
        guard !key.isEmpty else { return }
        let defaults = UserDefaults.standard
        if let viewer = viewer {
            defaults.set(viewer.rawValue, forKey: overrideKeyPrefix + key)
        } else {
            defaults.removeObject(forKey: overrideKeyPrefix + key)
        }
    }

    /// 该扩展名可选的查看器：当前生效的默认在前，其余已实现的去重后追加；
    /// 默认查看器尚未实现时以 quickLook 兜底（与路由回退一致）。
    static func supportedViewers(forExtension ext: String) -> [ViewerID] {
        let key = normalize(ext)
        let effective = override(forExtension: key) ?? defaultViewerID(forExtension: key)
        var viewers = [effective.isImplemented ? effective : .quickLook]
        for viewer in ViewerID.allCases where viewer.isImplemented && !viewers.contains(viewer) {
            viewers.append(viewer)
        }
        return viewers
    }

    // MARK: - 匹配细节

    /// 小写、去首尾空白、去掉前导点；与 ObjC normalizedExtension 一致。
    private static func normalize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasPrefix(".") { key.removeFirst() }
        return key
    }

    /// 内置默认的复合键最长后缀匹配（tar.gz → tar.gz，其次 gz）。
    private static func defaultViewerID(forNormalizedKey key: String) -> ViewerID? {
        guard !key.isEmpty else { return nil }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for start in parts.indices {
            let suffix = parts[start...].joined(separator: ".")
            if let viewer = defaultAssociations[suffix] { return viewer }
        }
        return nil
    }

    /// 文件名的全部点后缀，最长在前（backup.tar.gz → tar.gz、gz）。
    /// 与 ObjC viewerIDForFileName 相同：从第 2 个字符起找点，隐藏文件不参与。
    private static func suffixCandidates(in name: String) -> [String] {
        let characters = Array(name)
        guard characters.count > 1 else { return [] }
        var result: [String] = []
        for index in 1..<characters.count where characters[index] == "." {
            let suffix = String(characters[(index + 1)...])
            if !suffix.isEmpty { result.append(suffix) }
        }
        return result
    }
}
