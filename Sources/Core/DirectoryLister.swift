import Foundation

/// 目录列举：lstat 语义（不跟随符号链接判断类型），文件夹优先排序。
enum DirectoryLister {
    static func list(_ path: String, includeHidden: Bool = false) async throws -> [FileEntry] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try listSync(path,
                                                               includeHidden: includeHidden))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func listSync(_ path: String, includeHidden: Bool = false) throws -> [FileEntry] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: path)
        var entries: [FileEntry] = []
        entries.reserveCapacity(names.count)

        for name in names {
            if !includeHidden && name.hasPrefix(".") { continue }
            if StorageEnvironment.isInternalEntry(parentPath: path, name: name) { continue }
            let childPath = (path as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(childPath, &info) == 0 else { continue }

            let mode = info.st_mode & mode_t(S_IFMT)
            let isSymlink = mode == mode_t(S_IFLNK)
            var isDirectory = mode == mode_t(S_IFDIR)
            var size = UInt64(max(0, info.st_size))
#if canImport(Darwin)
            let modifiedSeconds = info.st_mtimespec.tv_sec
#else
            // Linux 仅供本地 swiftc 静态检查；真机走 Darwin 分支。
            let modifiedSeconds = info.st_mtim.tv_sec
#endif

            if isSymlink {
                var target = stat()
                if stat(childPath, &target) == 0 {
                    isDirectory = (target.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                    size = UInt64(max(0, target.st_size))
                }
            }

            entries.append(FileEntry(
                name: name,
                path: childPath,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedSeconds))
            ))
        }

        entries.sort { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return entries
    }
}
