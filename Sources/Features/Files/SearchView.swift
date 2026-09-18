import SwiftUI

/// 独立搜索页：输入框 + 结果列表（阶段 3c 冻结接口）。
/// 依赖外层 NavigationStack 完成目录/文件的 push。
struct SearchView: View {
    private let rootDirectory: String

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var didCancel = false
    @State private var generation = 0
    @State private var session: SearchSession?
    @State private var debounceWorkItem: DispatchWorkItem?
    @State private var didAutoFocus = false
    @State private var pushedDirectory: String?
    @State private var viewerEntry: FileEntry?

    @FocusState private var isFieldFocused: Bool

    init(rootDirectory: String) {
        self.rootDirectory = rootDirectory
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            content
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: directoryPresented) {
            if let path = pushedDirectory {
                FilesView(directory: path, title: (path as NSString).lastPathComponent)
            }
        }
        .navigationDestination(isPresented: viewerPresented) {
            if let entry = viewerEntry {
                ViewerHostView(entry: entry, siblings: fileSiblings)
            }
        }
        .onAppear {
            guard !didAutoFocus else { return }
            didAutoFocus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isFieldFocused = true
            }
        }
        .onChange(of: query) { newValue in
            startSearch(newValue)
        }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索全部文件", text: $query)
                    .focused($isFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onSubmit { isFieldFocused = false }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))

            if isSearching {
                Button("取消") { cancelSearch() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if hits.isEmpty {
            placeholder
        } else {
            resultList
        }
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(hits) { hit in
                    resultRow(hit)
                }
            } header: {
                Text(isSearching ? "正在搜索… 已找到 \(hits.count) 个" : "\(hits.count) 个结果")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if didCancel {
                        Text("搜索已取消")
                    }
                    if hits.count >= SearchService.maxResults {
                        Text("结果过多，仅显示前 \(SearchService.maxResults) 条")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if isSearching {
                ProgressView()
                Text("正在搜索…")
                    .foregroundColor(.secondary)
            } else if didCancel {
                Image(systemName: "xmark.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("搜索已取消")
                    .foregroundColor(.secondary)
            } else if trimmedQuery.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("输入关键词搜索全部文件")
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("没有找到“\(trimmedQuery)”")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text("试试缩短关键词")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        Button {
            open(hit)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: hit))
                    .foregroundColor(hit.isDirectory ? .accentColor : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.name)
                        .lineLimit(1)
                    Text(detailText(for: hit))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if hit.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索流程

    private func startSearch(_ rawQuery: String) {
        generation += 1
        let currentGeneration = generation
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        session?.cancel()
        session = nil
        isSearching = false
        didCancel = false

        let needle = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = []
        guard !needle.isEmpty else { return }

        isSearching = true
        let workItem = DispatchWorkItem {
            guard currentGeneration == generation else { return }
            session = SearchService.search(
                query: needle,
                under: rootDirectory,
                batch: { batch in
                    guard currentGeneration == generation else { return }
                    hits.append(contentsOf: batch)
                },
                completion: { cancelled in
                    guard currentGeneration == generation else { return }
                    session = nil
                    isSearching = false
                    didCancel = cancelled
                })
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func cancelSearch() {
        generation += 1
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        session?.cancel()
        session = nil
        isSearching = false
        didCancel = true
    }

    private func open(_ hit: SearchHit) {
        isFieldFocused = false
        if hit.isDirectory {
            pushedDirectory = hit.path
        } else {
            viewerEntry = fileEntry(from: hit)
        }
    }

    // MARK: - 展示辅助

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedRoot: String {
        rootDirectory.hasSuffix("/") ? String(rootDirectory.dropLast()) : rootDirectory
    }

    private var fileSiblings: [FileEntry] {
        hits.filter { !$0.isDirectory }.map { fileEntry(from: $0) }
    }

    private func fileEntry(from hit: SearchHit) -> FileEntry {
        FileEntry(name: hit.name, path: hit.path, isDirectory: hit.isDirectory,
                  isSymlink: false, size: hit.size, modificationDate: nil)
    }

    private func iconName(for hit: SearchHit) -> String {
        if hit.isDirectory { return "folder.fill" }
        switch FileFilterMode.category(forExtension: (hit.name as NSString).pathExtension) {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .archive: return "shippingbox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private func detailText(for hit: SearchHit) -> String {
        let relative = relativeDirectory(for: hit)
        if hit.isDirectory { return relative }
        let size = Self.sizeFormatter.string(fromByteCount: Int64(clamping: hit.size))
        return "\(relative) · \(size)"
    }

    private func relativeDirectory(for hit: SearchHit) -> String {
        let parent = (hit.path as NSString).deletingLastPathComponent
        if parent == normalizedRoot { return "根目录" }
        let prefix = normalizedRoot + "/"
        guard parent.hasPrefix(prefix) else { return parent }
        return String(parent.dropFirst(prefix.count))
    }

    private var directoryPresented: Binding<Bool> {
        Binding(
            get: { pushedDirectory != nil },
            set: { presented in
                if !presented { pushedDirectory = nil }
            }
        )
    }

    private var viewerPresented: Binding<Bool> {
        Binding(
            get: { viewerEntry != nil },
            set: { presented in
                if !presented { viewerEntry = nil }
            }
        )
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
