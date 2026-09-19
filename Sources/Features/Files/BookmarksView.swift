import SwiftUI

/// 收藏 / 最近访问共用列表：点目录 push FilesView，点文件进 ViewerHostView；
/// 左滑移除；条目不存在时提示并支持移除记录。
struct BookmarksView: View {
    let mode: BookmarksService.Mode

    @ObservedObject private var service = BookmarksService.shared
    @State private var destination: Destination?
    @State private var unavailable: BookmarkItem?

    init(mode: BookmarksService.Mode) {
        self.mode = mode
    }

    private enum Destination {
        case folder(path: String, title: String)
        case file(FileEntry)
    }

    private var items: [BookmarkItem] {
        mode == .favorites ? service.favorites : service.recents
    }

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    open(item)
                } label: {
                    row(for: item)
                }
                .buttonStyle(.plain)
            }
            .onDelete { remove(at: $0) }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if items.isEmpty {
                emptyState
            }
        }
        .navigationTitle(mode == .favorites ? "收藏" : "最近访问")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: destinationBinding) {
            if let destination {
                switch destination {
                case .folder(let path, let title):
                    FilesView(directory: path, title: title)
                case .file(let entry):
                    ViewerHostView(entry: entry, siblings: [])
                }
            }
        }
        .alert("文件不可用", isPresented: unavailableBinding, presenting: unavailable) { item in
            Button("移除记录", role: .destructive) { remove(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("“\(displayName(item))”已不存在。")
        }
    }

    // MARK: - Row

    private func row(for item: BookmarkItem) -> some View {
        let isDir = isDirectory(item.path)
        return HStack(spacing: 12) {
            Image(systemName: isDir ? "folder.fill" : "doc")
                .foregroundColor(isDir ? .accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(item))
                    .lineLimit(1)
                Text(item.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if mode == .recent {
                Text(Self.relativeFormatter.localizedString(for: item.date, relativeTo: Date()))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: mode == .favorites ? "star" : "clock")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(mode == .favorites ? "还没有收藏\n长按文件或文件夹即可收藏"
                                    : "还没有最近访问记录")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - Actions

    private func open(_ item: BookmarkItem) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else {
            unavailable = item
            return
        }
        let name = displayName(item)
        if isDir.boolValue {
            service.recordRecent(path: item.path, name: name, isDirectory: true)
            destination = .folder(path: item.path, title: name)
        } else if let entry = makeEntry(item, name: name, isDirectory: false) {
            service.recordRecent(path: item.path, name: name, isDirectory: false)
            destination = .file(entry)
        } else {
            unavailable = item
        }
    }

    private func remove(at offsets: IndexSet) {
        for index in offsets {
            guard items.indices.contains(index) else { continue }
            remove(items[index])
        }
    }

    private func remove(_ item: BookmarkItem) {
        if mode == .favorites {
            service.removeFavorite(path: item.path)
        } else {
            service.removeRecent(path: item.path)
        }
    }

    // MARK: - Helpers

    private func displayName(_ item: BookmarkItem) -> String {
        item.name.isEmpty ? (item.path as NSString).lastPathComponent : item.name
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func makeEntry(_ item: BookmarkItem, name: String, isDirectory: Bool) -> FileEntry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.path) else {
            return nil
        }
        return FileEntry(
            name: name,
            path: item.path,
            isDirectory: isDirectory,
            isSymlink: (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date)
    }

    private var destinationBinding: Binding<Bool> {
        Binding(
            get: { destination != nil },
            set: { presented in
                if !presented { destination = nil }
            }
        )
    }

    private var unavailableBinding: Binding<Bool> {
        Binding(
            get: { unavailable != nil },
            set: { presented in
                if !presented { unavailable = nil }
            }
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
