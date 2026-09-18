import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 一条搜索结果（阶段 3c 冻结接口）。
struct SearchHit: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64

    var id: String { path }
}

/// 一次搜索的句柄：可取消，遍历线程与主线程都能安全读写。
final class SearchSession {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 递归搜索（后台线程、可取消、分批回调）。回调都在主线程。
enum SearchService {
    static let maxResults = 5000
    static let maxDepth = 12
    static let batchSize = 50
    static let batchInterval: TimeInterval = 0.2

    /// 在 root 下递归查找名字包含 query 的条目（大小写/全半角/变音不敏感）。
    /// batch 分批回传（主线程），completion 结束时回调（主线程，参数为 true 表示被取消）。
    @discardableResult
    static func search(query: String, under root: String,
                       batch: @escaping ([SearchHit]) -> Void,
                       completion: @escaping (Bool) -> Void) -> SearchSession {
        let session = SearchSession()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            DispatchQueue.main.async { completion(false) }
            return session
        }

        let work = SearchWork(session: session, needle: needle, root: root,
                              batch: batch, completion: completion)
        DispatchQueue.global(qos: .userInitiated).async {
            work.run()
        }
        return session
    }
}

private final class SearchWork {
    private let session: SearchSession
    private let needle: String
    private let root: String
    private let batch: ([SearchHit]) -> Void
    private let completion: (Bool) -> Void

    private var pending: [SearchHit] = []
    private var total = 0
    private var lastFlush = Date()

    init(session: SearchSession, needle: String, root: String,
         batch: @escaping ([SearchHit]) -> Void,
         completion: @escaping (Bool) -> Void) {
        self.session = session
        self.needle = needle
        self.root = root
        self.batch = batch
        self.completion = completion
    }

    func run() {
        let started = Date()
        scan(root, depth: 0)
        flushPending()
        let cancelled = session.isCancelled
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        AppLog.tag("Search", "query=\(needle) root=\(root) results=\(total) " +
            "cancelled=\(cancelled) elapsed=\(elapsed)s")
        DispatchQueue.main.async {
            self.completion(cancelled)
        }
    }

    private func scan(_ path: String, depth: Int) {
        guard !session.isCancelled, total < SearchService.maxResults else { return }
        guard depth <= SearchService.maxDepth else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            AppLog.tag("Search", "list FAIL path=\(path)")
            return
        }

        var subdirectories: [String] = []
        for name in names {
            if session.isCancelled || total >= SearchService.maxResults { break }
            if name.hasPrefix(".") { continue }
            if StorageEnvironment.isInternalEntry(parentPath: path, name: name) { continue }

            let child = (path as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(child, &info) == 0 else { continue }
            let mode = info.st_mode & mode_t(S_IFMT)
            let isSymlink = mode == mode_t(S_IFLNK)
            let isDirectory = mode == mode_t(S_IFDIR)

            if matches(name) {
                let size = mode == mode_t(S_IFREG) ? UInt64(max(0, info.st_size)) : 0
                pending.append(SearchHit(name: name, path: child,
                                         isDirectory: isDirectory, size: size))
                total += 1
            }

            // 符号链接一律不下钻；不跟随也就不会绕出 root 或形成环。
            if isDirectory && !isSymlink && depth < SearchService.maxDepth {
                subdirectories.append(child)
            }

            if !pending.isEmpty {
                if pending.count >= SearchService.batchSize
                    || Date().timeIntervalSince(lastFlush) >= SearchService.batchInterval {
                    flushPending()
                }
            }
        }

        for subdirectory in subdirectories {
            if session.isCancelled || total >= SearchService.maxResults { break }
            scan(subdirectory, depth: depth + 1)
        }
    }

    private func matches(_ name: String) -> Bool {
        name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive,
                                         .widthInsensitive]) != nil
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let hits = pending
        pending.removeAll(keepingCapacity: true)
        lastFlush = Date()
        DispatchQueue.main.async {
            if !self.session.isCancelled { self.batch(hits) }
        }
    }
}
