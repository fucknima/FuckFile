import Foundation
#if canImport(Combine)
import Combine
#endif

struct BookmarkItem: Identifiable, Hashable {
    let path: String
    let name: String
    let date: Date

    var id: String { path }
}

/// 收藏 / 最近访问：UserDefaults 持久化（键 FFBookmarks / FFRecents），
/// 各限 50 条，最近按时间倒序去重；用 PropertyListEncoder 存数组。
final class BookmarksService: ObservableObject {
    static let shared = BookmarksService()

    enum Mode {
        case favorites
        case recent
    }

    @Published private(set) var favorites: [BookmarkItem] = []
    @Published private(set) var recents: [BookmarkItem] = []

    private static let favoritesKey = "FFBookmarks"
    private static let recentsKey = "FFRecents"
    private static let limit = 50

    private let defaults: UserDefaults
    private let encoder = PropertyListEncoder()

    private init() {
        defaults = .standard
        favorites = Self.load(from: defaults, key: Self.favoritesKey)
        recents = Self.load(from: defaults, key: Self.recentsKey)
    }

    // MARK: - Favorites

    func addFavorite(path: String, name: String) {
        let canonical = Self.canonical(path)
        guard !canonical.isEmpty else { return }
        var items = favorites.filter { $0.path != canonical }
        items.insert(BookmarkItem(path: canonical, name: name, date: Date()), at: 0)
        items = Self.trimmed(items)
        favorites = items
        save(items, key: Self.favoritesKey)
    }

    func removeFavorite(path: String) {
        let canonical = Self.canonical(path)
        let items = favorites.filter { $0.path != canonical }
        guard items.count != favorites.count else { return }
        favorites = items
        save(items, key: Self.favoritesKey)
    }

    func isFavorite(path: String) -> Bool {
        let canonical = Self.canonical(path)
        return favorites.contains { $0.path == canonical }
    }

    // MARK: - Recents

    func recordRecent(path: String, name: String, isDirectory: Bool) {
        let canonical = Self.canonical(path)
        guard !canonical.isEmpty else { return }
        var items = recents.filter { $0.path != canonical }
        items.insert(BookmarkItem(path: canonical, name: name, date: Date()), at: 0)
        items = Self.trimmed(items)
        recents = items
        save(items, key: Self.recentsKey)
    }

    /// 供「最近访问」左滑移除使用（冻结接口未列出，但视图需要）。
    func removeRecent(path: String) {
        let canonical = Self.canonical(path)
        let items = recents.filter { $0.path != canonical }
        guard items.count != recents.count else { return }
        recents = items
        save(items, key: Self.recentsKey)
    }

    // MARK: - Persistence

    private struct StoredItem: Codable {
        let path: String
        let name: String
        let date: Date
    }

    private static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func trimmed(_ items: [BookmarkItem]) -> [BookmarkItem] {
        items.count > limit ? Array(items.prefix(limit)) : items
    }

    private static func load(from defaults: UserDefaults, key: String) -> [BookmarkItem] {
        guard let data = defaults.data(forKey: key),
              let stored = try? PropertyListDecoder().decode([StoredItem].self, from: data) else {
            return []
        }
        return stored.map { BookmarkItem(path: $0.path, name: $0.name, date: $0.date) }
    }

    private func save(_ items: [BookmarkItem], key: String) {
        let stored = items.map { StoredItem(path: $0.path, name: $0.name, date: $0.date) }
        guard let data = try? encoder.encode(stored) else { return }
        defaults.set(data, forKey: key)
    }
}
