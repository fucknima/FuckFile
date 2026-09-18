import QuickLook
import SwiftUI

struct FilesView: View {
    let directory: String
    let title: String

    @StateObject private var viewModel: BrowserViewModel
    @State private var isGrid = false
    @State private var isOpenPresented = false
    @State private var openPath: String?
    @State private var namePrompt: NamePromptKind?
    @State private var nameText = ""
    @State private var pendingDeletion: [FileEntry] = []
    @State private var isDeleteConfirmPresented = false
    @State private var transferRequest: TransferRequest?
    @State private var viewerEntry: FileEntry?

    init(directory: String, title: String) {
        self.directory = directory
        self.title = title
        _viewModel = StateObject(wrappedValue: BrowserViewModel(directory: directory))
    }

    var body: some View {
        content
            .navigationTitle(viewModel.isSelecting ? "已选 \(viewModel.selectedPaths.count) 项" : title)
            .navigationDestination(for: String.self) { path in
                FilesView(directory: path, title: (path as NSString).lastPathComponent)
            }
            .navigationDestination(isPresented: $isOpenPresented) {
                if let path = openPath {
                    FilesView(directory: path, title: (path as NSString).lastPathComponent)
                }
            }
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) { batchBar }
            .task { await viewModel.load() }
            .onChange(of: viewModel.showHidden) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileActionsDidChange)) { _ in
                Task { await viewModel.load() }
            }
            .fileActionsDialogs()
            .alert(namePrompt?.title ?? "名称", isPresented: namePromptBinding) {
                TextField("名称", text: $nameText)
                    .textInputAutocapitalization(.never)
                Button("取消", role: .cancel) { namePrompt = nil }
                Button(namePrompt?.confirmTitle ?? "好") { commitNamePrompt() }
                    .disabled(trimmedName.isEmpty || trimmedName.contains("/"))
            } message: {
                if let prompt = namePrompt, !prompt.message.isEmpty {
                    Text(prompt.message)
                }
            }
            .confirmationDialog("移到回收站",
                                isPresented: $isDeleteConfirmPresented,
                                titleVisibility: .visible) {
                Button("移到回收站", role: .destructive) { commitDelete() }
                Button("取消", role: .cancel) { pendingDeletion = [] }
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $transferRequest) { request in
                DirectoryPickerView(title: request.kind.pickerTitle,
                                    rootDirectory: StorageEnvironment.documentsPath) { picked in
                    finishTransfer(request, toDirectory: picked)
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            if isGrid {
                gridContent
            } else {
                listContent
            }
        }
        .overlay { stateOverlay }
        .overlay {
            if viewModel.isLoading && viewModel.entries.isEmpty {
                ProgressView()
            }
        }
        .navigationDestination(isPresented: viewerPresented) {
            if let entry = viewerEntry {
                ViewerHostView(entry: entry, siblings: viewModel.visibleEntries)
            }
        }
    }

    private var listContent: some View {
        List {
            ForEach(viewModel.visibleEntries) { entry in
                listRow(for: entry)
                    .contextMenu { contextMenu(for: entry) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !viewModel.isSelecting {
                            Button(role: .destructive) {
                                confirmDelete([entry])
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                presentNamePrompt(.rename(entry))
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await viewModel.load() }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                      spacing: 12) {
                ForEach(viewModel.visibleEntries) { entry in
                    gridCell(for: entry)
                        .contextMenu { contextMenu(for: entry) }
                }
            }
            .padding(12)
        }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func listRow(for entry: FileEntry) -> some View {
        if viewModel.isSelecting {
            HStack(spacing: 12) {
                selectionMark(isSelected: viewModel.selectedPaths.contains(entry.path))
                EntryRow(entry: entry)
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.toggleSelection(entry) }
        } else if entry.isDirectory {
            NavigationLink(value: entry.path) {
                EntryRow(entry: entry)
            }
        } else {
            Button {
                viewerEntry = entry
            } label: {
                EntryRow(entry: entry)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func gridCell(for entry: FileEntry) -> some View {
        if viewModel.isSelecting {
            gridCellContent(entry, isSelected: viewModel.selectedPaths.contains(entry.path))
                .onTapGesture { viewModel.toggleSelection(entry) }
        } else if entry.isDirectory {
            NavigationLink(value: entry.path) {
                gridCellContent(entry, isSelected: false)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                viewerEntry = entry
            } label: {
                gridCellContent(entry, isSelected: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func gridCellContent(_ entry: FileEntry, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: EntryStyle.icon(for: entry))
                    .font(.system(size: 34))
                    .foregroundColor(EntryStyle.tint(for: entry))
                    .frame(maxWidth: .infinity)
                if viewModel.isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
            }
            Text(entry.name)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(entry.isDirectory ? "文件夹" : EntryStyle.sizeText(entry.size))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(uiColor: .secondarySystemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func selectionMark(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .imageScale(.large)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if let loadError = viewModel.loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("无法打开此文件夹")
                    .font(.headline)
                Text(loadError)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await viewModel.load() } }
            }
            .padding(32)
        } else if viewModel.visibleEntries.isEmpty && !viewModel.isLoading {
            VStack(spacing: 10) {
                Image(systemName: viewModel.entries.isEmpty
                      ? "folder" : "line.3.horizontal.decrease.circle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(viewModel.entries.isEmpty ? "此文件夹为空" : "没有匹配的文件")
                    .foregroundColor(.secondary)
            }
            .padding(32)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if viewModel.isSelecting {
                Button("取消") { exitSelection() }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if viewModel.isSelecting {
                Button("全选") { viewModel.selectAll() }
            } else {
                sortMenu
                filterMenu
                moreMenu
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FileSortMode.allCases) { mode in
                Button {
                    viewModel.sortMode = mode
                } label: {
                    if viewModel.sortMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }
            Divider()
            Button {
                viewModel.sortAscending.toggle()
            } label: {
                Label(viewModel.sortAscending ? "升序" : "降序",
                      systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("排序")
    }

    private var filterMenu: some View {
        Menu {
            ForEach(FileFilterMode.allCases) { mode in
                Button {
                    viewModel.filterMode = mode
                } label: {
                    if viewModel.filterMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("筛选")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                isGrid.toggle()
            } label: {
                Label(isGrid ? "列表" : "网格",
                      systemImage: isGrid ? "list.bullet" : "square.grid.2x2")
            }
            Toggle(isOn: $viewModel.showHidden) {
                Label("显示隐藏文件", systemImage: "eye")
            }
            Divider()
            Button {
                viewModel.isSelecting = true
            } label: {
                Label("选择", systemImage: "checkmark.circle")
            }
            Divider()
            Button {
                presentNamePrompt(.newFolder)
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                presentNamePrompt(.newFile)
            } label: {
                Label("新建文件", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多")
    }

    // MARK: - Batch bar

    @ViewBuilder
    private var batchBar: some View {
        if viewModel.isSelecting {
            HStack(spacing: 0) {
                batchButton("复制", systemImage: "doc.on.doc", enabled: hasSelection) {
                    beginTransfer(.copy, entries: viewModel.selectedEntries)
                }
                batchButton("移动", systemImage: "folder", enabled: hasSelection) {
                    beginTransfer(.move, entries: viewModel.selectedEntries)
                }
                batchButton("重命名", systemImage: "pencil",
                            enabled: viewModel.selectedPaths.count == 1) {
                    if let entry = viewModel.selectedEntries.first {
                        presentNamePrompt(.rename(entry))
                    }
                }
                batchButton("删除", systemImage: "trash", enabled: hasSelection,
                            role: .destructive) {
                    confirmDelete(viewModel.selectedEntries)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func batchButton(_ title: String, systemImage: String, enabled: Bool,
                             role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button {
                openPath = entry.path
                isOpenPresented = true
            } label: {
                Label("打开", systemImage: "folder")
            }
        } else {
            Button {
                viewerEntry = entry
            } label: {
                Label("打开", systemImage: "eye")
            }
        }
        Button {
            beginTransfer(.copy, entries: [entry])
        } label: {
            Label("复制到…", systemImage: "doc.on.doc")
        }
        Button {
            beginTransfer(.move, entries: [entry])
        } label: {
            Label("移动到…", systemImage: "folder")
        }
        Button {
            presentNamePrompt(.rename(entry))
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            confirmDelete([entry])
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private var hasSelection: Bool { !viewModel.selectedPaths.isEmpty }

    private var trimmedName: String {
        nameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deleteMessage: String {
        if pendingDeletion.count == 1, let entry = pendingDeletion.first {
            return "“\(entry.name)” 将移到回收站，可在那里恢复。"
        }
        return "\(pendingDeletion.count) 个项目将移到回收站，可在那里恢复。"
    }

    private var viewerPresented: Binding<Bool> {
        Binding(
            get: { viewerEntry != nil },
            set: { presented in
                if !presented { viewerEntry = nil }
            }
        )
    }

    private var namePromptBinding: Binding<Bool> {
        Binding(
            get: { namePrompt != nil },
            set: { isPresented in
                if !isPresented { namePrompt = nil }
            }
        )
    }

    private func presentNamePrompt(_ prompt: NamePromptKind) {
        switch prompt {
        case .rename(let entry): nameText = entry.name
        case .newFolder, .newFile: nameText = ""
        }
        namePrompt = prompt
    }

    private func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        let name = trimmedName
        guard !name.isEmpty, !name.contains("/") else { return }
        namePrompt = nil
        switch prompt {
        case .newFolder:
            FileActions.shared.createFolder(named: name, inDirectory: viewModel.directory)
        case .newFile:
            FileActions.shared.createFile(named: name, inDirectory: viewModel.directory)
        case .rename(let entry):
            FileActions.shared.rename(entry, to: name)
        }
        Task { await viewModel.load() }
    }

    private func confirmDelete(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        pendingDeletion = entries
        isDeleteConfirmPresented = true
    }

    private func commitDelete() {
        let entries = pendingDeletion
        pendingDeletion = []
        guard !entries.isEmpty else { return }
        FileActions.shared.trash(entries)
        viewModel.clearSelection()
        Task { await viewModel.load() }
    }

    private func beginTransfer(_ kind: TransferKind, entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        transferRequest = TransferRequest(kind: kind, entries: entries)
    }

    private func finishTransfer(_ request: TransferRequest, toDirectory pickedDirectory: String) {
        // 冲突策略固定 .ask：由 FileActions 经集成方的 ConflictDialog 统一询问（P2 约定）。
        switch request.kind {
        case .copy:
            FileActions.shared.copy(request.entries, toDirectory: pickedDirectory)
        case .move:
            FileActions.shared.move(request.entries, toDirectory: pickedDirectory)
        }
        viewModel.clearSelection()
        Task { await viewModel.load() }
    }

    private func exitSelection() {
        viewModel.isSelecting = false
        viewModel.clearSelection()
    }
}

// MARK: - Row

private struct EntryRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: EntryStyle.icon(for: entry))
                .foregroundColor(EntryStyle.tint(for: entry))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !entry.isDirectory {
                    Text(EntryStyle.detail(for: entry))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private enum EntryStyle {
    static func icon(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isSymlink { return "link" }
        switch FileFilterMode.category(forExtension: (entry.name as NSString).pathExtension) {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .archive: return "shippingbox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    static func tint(for entry: FileEntry) -> Color {
        entry.isDirectory ? .accentColor : .secondary
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func sizeText(_ size: UInt64) -> String {
        sizeFormatter.string(fromByteCount: Int64(clamping: size))
    }

    static func detail(for entry: FileEntry) -> String {
        var parts = [sizeText(entry.size)]
        if let date = entry.modificationDate {
            parts.append(dateFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Prompts & transfers

private enum NamePromptKind: Identifiable {
    case newFolder
    case newFile
    case rename(FileEntry)

    var id: String {
        switch self {
        case .newFolder: return "newFolder"
        case .newFile: return "newFile"
        case .rename(let entry): return "rename:\(entry.path)"
        }
    }

    var title: String {
        switch self {
        case .newFolder: return "新建文件夹"
        case .newFile: return "新建文件"
        case .rename: return "重命名"
        }
    }

    var confirmTitle: String {
        switch self {
        case .newFolder, .newFile: return "创建"
        case .rename: return "重命名"
        }
    }

    var message: String {
        switch self {
        case .newFolder, .newFile: return ""
        case .rename(let entry): return entry.name
        }
    }
}

private enum TransferKind {
    case copy
    case move

    var pickerTitle: String {
        switch self {
        case .copy: return "复制到"
        case .move: return "移动到"
        }
    }
}

private struct TransferRequest: Identifiable {
    let id = UUID()
    let kind: TransferKind
    let entries: [FileEntry]
}

// MARK: - Directory picker

private struct DirectoryPickerView: View {
    let title: String
    let rootDirectory: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentDirectory: String
    @State private var directories: [FileEntry] = []
    @State private var isLoading = false

    init(title: String, rootDirectory: String, onPick: @escaping (String) -> Void) {
        self.title = title
        self.rootDirectory = rootDirectory
        self.onPick = onPick
        _currentDirectory = State(initialValue: rootDirectory)
    }

    private var isAtRoot: Bool { currentDirectory == rootDirectory }

    var body: some View {
        NavigationStack {
            List {
                if !isAtRoot {
                    Button {
                        currentDirectory = (currentDirectory as NSString).deletingLastPathComponent
                    } label: {
                        pickerRowLabel("上一级", systemImage: "arrow.up")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(directories) { directory in
                    Button {
                        currentDirectory = directory.path
                    } label: {
                        pickerRowLabel(directory.name, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                if directories.isEmpty && !isLoading {
                    Text(isAtRoot ? "没有子文件夹" : "没有子文件夹，可直接选择当前文件夹")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("选择") {
                        onPick(currentDirectory)
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(currentDirectory)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .task(id: currentDirectory) { await load() }
        }
    }

    private func pickerRowLabel(_ text: String, systemImage: String) -> some View {
        HStack {
            Label(text, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listed = try await DirectoryLister.list(currentDirectory, includeHidden: false)
            directories = listed.filter { $0.isDirectory }
        } catch {
            directories = []
            AppLog.tag("Files", "picker list FAIL path=\(currentDirectory) error=\(error.localizedDescription)")
        }
    }
}
