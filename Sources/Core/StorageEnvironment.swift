import Foundation

/// 沙盒存储环境：只管理 App 自己的 Documents 目录，不涉及任何跨容器访问。
final class StorageEnvironment: ObservableObject {
    static let documentsPath: String = {
        let path = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                       .userDomainMask, true).first
            ?? NSHomeDirectory().appending("/Documents")
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: true)
        return path
    }()

    /// 根目录下由 App 自己维护、不在用户文件列表里展示的条目。
    static let internalEntryNames: Set<String> = [
        "FuckFile Log.txt",
        "FuckFile Log.old.txt",
        "ACCESS MAP.txt",
        ".ACCESS MAP.txt.tmp",
        "Favorites.plist",
        ".Trash",
    ]

    static func isInternalEntry(parentPath: String, name: String) -> Bool {
        parentPath == documentsPath && internalEntryNames.contains(name)
    }
}
