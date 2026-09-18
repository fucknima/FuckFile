import Foundation

/// 文件元信息（阶段 3c 冻结接口）。
/// 目录的 `size` 是目录自身 st_size；`itemCount` 为不递归的直接子项数。
struct FileMetadata {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let linkTarget: String?
    let size: UInt64
    let modificationDate: Date?
    let creationDate: Date?
    let modeText: String
    let uid: uid_t
    let gid: gid_t
    let itemCount: Int?
}

/// 用 lstat/stat 读取本地文件系统元信息（不跟随符号链接判断类型与权限，
/// 但符号链接的 isDirectory/size 取目标值，与 DirectoryLister 保持一致）。
enum FileMetadataService {
    static func metadata(forPath path: String) -> FileMetadata? {
        guard !path.isEmpty else { return nil }

        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }

        let fileType = info.st_mode & mode_t(S_IFMT)
        let isSymlink = fileType == mode_t(S_IFLNK)
        var isDirectory = fileType == mode_t(S_IFDIR)
        var size = UInt64(max(0, info.st_size))
        var linkTarget: String?

        if isSymlink {
            linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            var target = stat()
            if stat(path, &target) == 0 {
                isDirectory = (target.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                size = UInt64(max(0, target.st_size))
            } else {
                isDirectory = false
            }
        }

        var itemCount: Int?
        if isDirectory {
            itemCount = (try? FileManager.default.contentsOfDirectory(atPath: path))?.count
        }

        return FileMetadata(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            linkTarget: linkTarget,
            size: size,
            modificationDate: modificationDate(of: info),
            creationDate: creationDate(of: info, atPath: path),
            modeText: modeText(of: info.st_mode),
            uid: info.st_uid,
            gid: info.st_gid,
            itemCount: itemCount
        )
    }

    // MARK: - 内部

    private static func modificationDate(of info: stat) -> Date? {
#if canImport(Darwin)
        let seconds = info.st_mtimespec.tv_sec
        let nanoseconds = info.st_mtimespec.tv_nsec
#else
        let seconds = info.st_mtim.tv_sec
        let nanoseconds = info.st_mtim.tv_nsec
#endif
        return Date(timeIntervalSince1970: TimeInterval(seconds)
            + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    private static func creationDate(of info: stat, atPath path: String) -> Date? {
#if canImport(Darwin)
        return Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
#else
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.creationDate] as? Date
#endif
    }

    /// ls 风格权限文本，如 "-rw-r--r--"、"drwxr-xr-x"、"lrwxrwxrwx"。
    static func modeText(of mode: mode_t) -> String {
        let triplets = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        var text = String(typeCharacter(of: mode))
        text += triplets[Int((mode >> 6) & 0o7)]
        text += triplets[Int((mode >> 3) & 0o7)]
        text += triplets[Int(mode & 0o7)]

        var characters = Array(text)
        if mode & mode_t(S_ISUID) != 0 {
            characters[3] = characters[3] == "x" ? "s" : "S"
        }
        if mode & mode_t(S_ISGID) != 0 {
            characters[6] = characters[6] == "x" ? "s" : "S"
        }
        if mode & mode_t(S_ISVTX) != 0 {
            characters[9] = characters[9] == "x" ? "t" : "T"
        }
        return String(characters)
    }

    private static func typeCharacter(of mode: mode_t) -> Character {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return "d"
        case mode_t(S_IFLNK): return "l"
        case mode_t(S_IFCHR): return "c"
        case mode_t(S_IFBLK): return "b"
        case mode_t(S_IFSOCK): return "s"
        case mode_t(S_IFIFO): return "p"
        default: return "-"
        }
    }
}
