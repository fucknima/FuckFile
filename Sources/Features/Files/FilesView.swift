import SwiftUI

struct FilesView: View {
    let directory: String
    let title: String

    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Text(loadError)
                    .foregroundColor(.secondary)
            } else if entries.isEmpty && !isLoading {
                Text("文件夹为空")
                    .foregroundColor(.secondary)
            }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink(value: entry.path) {
                        EntryRow(entry: entry)
                    }
                } else {
                    EntryRow(entry: entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationDestination(for: String.self) { path in
            FilesView(directory: path, title: (path as NSString).lastPathComponent)
        }
        .refreshable { await reload() }
        .task { await reload() }
        .overlay {
            if isLoading && entries.isEmpty {
                ProgressView()
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listed = try await DirectoryLister.list(directory)
            entries = listed
            loadError = nil
            AppLog.tag("Files", "list path=\(directory) count=\(listed.count)")
        } catch {
            entries = []
            loadError = "无法读取目录：\(error.localizedDescription)"
            AppLog.tag("Files", "list FAIL path=\(directory) error=\(error.localizedDescription)")
        }
    }
}

private struct EntryRow: View {
    let entry: FileEntry

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !entry.isDirectory {
                    Text(Self.detail(for: entry))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private static func detail(for entry: FileEntry) -> String {
        var parts: [String] = []
        parts.append(sizeFormatter.string(fromByteCount: Int64(entry.size)))
        if let date = entry.modificationDate {
            parts.append(date.formatted(date: .numeric, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
