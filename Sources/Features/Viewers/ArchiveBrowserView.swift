import SwiftUI

/// 压缩包浏览器：条目树（目录/文件、大小）、单个解压、全部解压。
/// 解压统一进 FileTaskManager 任务队列；密码只在本次运行内存中保存。
struct ArchiveBrowserView: View {
    let entry: FileEntry

    @State private var entries: [ZipArchiveEntry] = []
    @State private var nodes: [ArchiveNode] = []
    @State private var pathStack: [String] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var password: String?
    @State private var passwordInput = ""
    @State private var isPasswordRetry = false
    @State private var pendingExtraction: ((String?) -> Void)?
    @State private var alertKind: AlertKind = .result
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var isAlertPresented = false

    private enum AlertKind {
        case password
        case result
    }

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取归档…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorState(loadError)
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await load() }
        .alert(alertTitle, isPresented: $isAlertPresented) {
            if alertKind == .password {
                SecureField("密码", text: $passwordInput)
                    .textContentType(.password)
                Button("取消", role: .cancel) { pendingExtraction = nil }
                Button("继续") { submitPassword() }
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 列表

    private var content: some View {
        List {
            Section {
                if !pathStack.isEmpty {
                    Button { goUp() } label: {
                        Label("返回上级", systemImage: "arrow.up.left")
                    }
                }
                ForEach(nodes) { node in
                    row(node)
                }
            } header: {
                if pathStack.isEmpty {
                    Text("\(entries.count) 个条目")
                } else {
                    Text(pathStack.joined(separator: " / "))
                }
            } footer: {
                if nodes.isEmpty {
                    Text(pathStack.isEmpty ? "该压缩包内没有文件" : "该文件夹内没有文件")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func row(_ node: ArchiveNode) -> some View {
        if node.isDirectory {
            Button { openDirectory(node) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundColor(.accentColor)
                        .frame(width: 22)
                    Text(node.name)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(byteCount(node.size))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if node.isEncrypted {
                            Label("加密", systemImage: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
                Spacer(minLength: 8)
                Button("解压") { extractSingle(node) }
                    .buttonStyle(.borderless)
            }
            .swipeActions(edge: .trailing) {
                Button { extractSingle(node) } label: {
                    Label("解压", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { extractAll() } label: {
                Label("全部解压", systemImage: "shippingbox")
            }
            .disabled(isLoading || loadError != nil || entries.isEmpty)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("无法读取归档")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load() } }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 载入

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        let path = entry.path
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<[ZipArchiveEntry], Error> in
            do {
                return .success(try ZipArchive.entries(at: path))
            } catch {
                return .failure(error)
            }
        }.value

        isLoading = false
        switch result {
        case .success(let list):
            entries = list
            pathStack = []
            rebuildNodes()
            AppLog.tag("Archive", "list \(path) entries=\(list.count)")
        case .failure(let error):
            entries = []
            nodes = []
            loadError = error.localizedDescription
            AppLog.tag("Archive", "list FAIL \(path) \(error.localizedDescription)")
        }
    }

    private func rebuildNodes() {
        let prefix = pathStack.isEmpty ? "" : pathStack.joined(separator: "/") + "/"
        var map: [String: ArchiveNode] = [:]
        for item in entries {
            guard item.name.hasPrefix(prefix) else { continue }
            let rest = String(item.name.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                let segment = String(rest[..<slash])
                guard !segment.isEmpty else { continue }
                let fullPath = prefix + segment
                if map[fullPath] == nil {
                    map[fullPath] = ArchiveNode(id: fullPath, name: segment, fullPath: fullPath,
                                                isDirectory: true, size: 0, isEncrypted: false)
                }
            } else {
                let fullPath = prefix + rest
                map[fullPath] = ArchiveNode(id: fullPath, name: rest, fullPath: fullPath,
                                            isDirectory: item.isDirectory,
                                            size: item.size, isEncrypted: item.isEncrypted)
            }
        }
        nodes = map.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - 解压

    private var archiveStem: String {
        let stem = (entry.name as NSString).deletingPathExtension
        return stem.isEmpty ? "archive" : stem
    }

    private var desiredExtractDirectory: String {
        let parent = (entry.path as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent("\(archiveStem) (解压)")
    }

    private func extractAll() {
        let destination = desiredExtractDirectory
        requestExtraction(requiresPassword: entries.contains { $0.isEncrypted }) { password in
            runExtractAll(toDirectory: destination, password: password)
        }
    }

    private func extractSingle(_ node: ArchiveNode) {
        requestExtraction(requiresPassword: node.isEncrypted) { password in
            runExtractSingle(node: node, password: password)
        }
    }

    /// 需要密码且本次运行还没有密码时，先弹密码框；否则直接执行。
    private func requestExtraction(requiresPassword: Bool,
                                   _ action: @escaping (String?) -> Void) {
        if requiresPassword && (password ?? "").isEmpty {
            pendingExtraction = action
            passwordInput = ""
            isPasswordRetry = false
            alertKind = .password
            isAlertPresented = true
        } else {
            action(password)
        }
    }

    private func runExtractAll(toDirectory: String, password: String?) {
        var thrown: ZipArchiveError?
        var destination: String?
        FileTaskManager.shared.enqueue(kind: .extract, displayName: "解压 \(archiveStem)") { task in
            do {
                destination = try ZipArchive.extractAll(
                    at: entry.path,
                    toDirectory: toDirectory,
                    password: password,
                    progress: { value, name in
                        DispatchQueue.main.async {
                            task.progress = value
                            task.detail = name
                        }
                    },
                    shouldCancel: { task.cancelled })
            } catch let error as ZipArchiveError {
                thrown = error
                throw error
            }
        } completion: { task in
            finishExtraction(task: task, error: thrown, destination: destination,
                             retry: { newPassword in
                                 runExtractAll(toDirectory: toDirectory, password: newPassword)
                             },
                             successTitle: "解压完成")
        }
    }

    private func runExtractSingle(node: ArchiveNode, password: String?) {
        var thrown: ZipArchiveError?
        var destination: String?
        FileTaskManager.shared.enqueue(kind: .extract, displayName: "解压 \(node.name)") { task in
            do {
                destination = try ZipArchive.extract(
                    at: entry.path,
                    entry: node.fullPath,
                    toDirectory: desiredExtractDirectory,
                    password: password)
            } catch let error as ZipArchiveError {
                thrown = error
                throw error
            }
        } completion: { task in
            finishExtraction(task: task, error: thrown, destination: destination,
                             retry: { newPassword in
                                 runExtractSingle(node: node, password: newPassword)
                             },
                             successTitle: "解压完成")
        }
    }

    private func finishExtraction(task: FileTask,
                                  error: ZipArchiveError?,
                                  destination: String?,
                                  retry: @escaping (String?) -> Void,
                                  successTitle: String) {
        NotificationCenter.default.post(name: .fileActionsDidChange, object: nil)
        if let error, error.needsPassword {
            password = nil
            pendingExtraction = retry
            passwordInput = ""
            isPasswordRetry = true
            // 前一个密码 alert 可能还在收起，稍后再弹，避免被系统丢弃。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                alertKind = .password
                isAlertPresented = true
            }
            return
        }
        if task.state == .completed {
            resultTitle = successTitle
            resultMessage = "已解压到：\n\(destination ?? "")"
        } else {
            resultTitle = "解压失败"
            resultMessage = task.errorText ?? error?.localizedDescription ?? "未知错误"
        }
        pendingExtraction = nil
        alertKind = .result
        isAlertPresented = true
    }

    private func submitPassword() {
        guard !passwordInput.isEmpty else { return }
        let value = passwordInput
        password = value
        let action = pendingExtraction
        isAlertPresented = false
        action?(value)
    }

    // MARK: - 辅助

    private var title: String {
        pathStack.last ?? entry.name
    }

    private var alertTitle: String {
        if alertKind == .password {
            return isPasswordRetry ? "密码错误" : "加密压缩包"
        }
        return resultTitle
    }

    private var alertMessage: String {
        if alertKind == .password {
            return isPasswordRetry
                ? "密码错误，请重新输入。密码只保存在本次 App 运行内存中。"
                : "需要密码才能读取此压缩包。密码只保存在本次 App 运行内存中。"
        }
        return resultMessage
    }

    private func openDirectory(_ node: ArchiveNode) {
        pathStack.append(node.name)
        rebuildNodes()
    }

    private func goUp() {
        guard !pathStack.isEmpty else { return }
        pathStack.removeLast()
        rebuildNodes()
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

private struct ArchiveNode: Identifiable {
    let id: String
    let name: String
    let fullPath: String
    let isDirectory: Bool
    let size: UInt64
    let isEncrypted: Bool
}
