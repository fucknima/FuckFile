import SwiftUI

/// 回收站：列表 / 恢复 / 永久删除 / 清空。恢复后广播刷新浏览器。
struct TrashView: View {
    @State private var entries: [TrashEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isConfirmingEmpty = false

    var body: some View {
        List {
            if entries.isEmpty && !isLoading {
                Text("回收站是空的")
                    .foregroundColor(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                    Text(Self.detail(for: entry))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        restore(entry)
                    } label: {
                        Label("恢复", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        remove(entry)
                    } label: {
                        Label("永久删除", systemImage: "trash.slash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("回收站")
        .toolbar {
            if !entries.isEmpty {
                Button("清空", role: .destructive) { isConfirmingEmpty = true }
            }
        }
        .confirmationDialog("清空回收站", isPresented: $isConfirmingEmpty,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { empty() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("回收站里的项目将被永久删除，无法恢复。")
        }
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if isLoading && entries.isEmpty { ProgressView() }
        }
        .alert("操作失败", isPresented: errorPresented) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented { errorMessage = nil }
            }
        )
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await Task.detached { try TrashService.entries() }.value
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ entry: TrashEntry) {
        do {
            _ = try TrashService.restore(entry)
            NotificationCenter.default.post(name: .fileActionsDidChange, object: nil)
            Task { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ entry: TrashEntry) {
        do {
            try TrashService.removePermanently(entry)
            Task { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func empty() {
        do {
            try TrashService.emptyTrash()
            Task { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func detail(for entry: TrashEntry) -> String {
        var parts: [String] = []
        if entry.isDirectory {
            parts.append("文件夹")
        } else {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size),
                                                   countStyle: .file))
        }
        parts.append(entry.originalPath)
        parts.append(entry.trashedAt.formatted(date: .numeric, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
