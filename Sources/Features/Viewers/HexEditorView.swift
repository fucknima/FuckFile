import Foundation
import SwiftUI
import UIKit

/// Hex 查看 / 编辑器。
/// 分页读取（64 KiB/页，16 字节/行），只保留当前页，文件再大内存也有界；
/// 修改先进入内存补丁表，显式保存时用「同目录临时文件 + fsync + inode 校验 + rename」
/// 原子写回，行为对齐 FFHexEditorViewController。
struct HexEditorView: View {
    let entry: FileEntry

    @StateObject private var model: HexEditorModel

    @State private var prompt: HexPrompt?
    @State private var promptText = ""
    @State private var isPromptPresented = false
    @State private var isDiscardPresented = false

    init(entry: FileEntry) {
        self.entry = entry
        _model = StateObject(wrappedValue: HexEditorModel(path: entry.path))
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.loadError {
                errorState(message)
            } else {
                editor
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("保存失败", isPresented: saveErrorBinding) {
            Button("好", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "未知错误")
        }
        .overlay(alignment: .bottom) { toastView }
        .task { model.start() }
    }

    // MARK: - Subviews

    private var editor: some View {
        VStack(spacing: 0) {
            header
            Divider()
            hexList
            Divider()
            pageBar
        }
        .alert(promptTitle, isPresented: $isPromptPresented) {
            TextField(promptPlaceholder, text: $promptText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(prompt == .find ? .none : .characters)
                .keyboardType(.asciiCapable)
            Button("取消", role: .cancel) { prompt = nil }
            if prompt == .find && !model.searchMatches.isEmpty {
                Button("下一处") { nextMatchTapped() }
            }
            Button(promptConfirmTitle) { confirmPrompt() }
        } message: {
            Text(promptMessage)
        }
    }

    private var header: some View {
        Text(model.headerText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
    }

    private var hexList: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.rowCount == 0 {
                        Text("文件为空")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(16)
                    } else {
                        ForEach(0..<model.rowCount, id: \.self) { row in
                            rowView(row)
                                .id(row)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.scrollRequest) { request in
                guard let request = request else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(request.row, anchor: .top)
                }
            }
        }
    }

    private func rowView(_ row: Int) -> some View {
        let line = model.line(at: row)
        return Text(line.text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(line.isModified ? .red : .primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture { beginEdit(row: row) }
    }

    private var pageBar: some View {
        HStack {
            Button("上一页") { model.goToPreviousPage() }
                .disabled(!model.canGoPreviousPage)
            Spacer()
            Button("下一页") { model.goToNextPage() }
                .disabled(!model.canGoNextPage)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .alert("放弃修改", isPresented: $isDiscardPresented) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃", role: .destructive) { model.discardPatches() }
        } message: {
            Text("将丢弃 \(model.patches.count) 处未保存的字节修改。")
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("无法打开文件")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { model.reload() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.footnote)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(.bottom, 56)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button("跳转") { presentPrompt(.jump) }
            Button("查找") { presentPrompt(.find) }
            Button("保存") { model.save() }
                .disabled(!model.canSave)
            Button("放弃", role: .destructive) { isDiscardPresented = true }
                .disabled(!model.canSave)
        }
    }

    // MARK: - Prompts

    private var promptTitle: String {
        switch prompt {
        case .edit(let base, _): return String(format: "编辑偏移 0x%08llX", base)
        case .jump: return "跳转到偏移"
        case .find: return "查找"
        case nil: return ""
        }
    }

    private var promptMessage: String {
        switch prompt {
        case .edit(_, let length):
            return "输入新的十六进制字节（每字节两位，必须保持本行 \(length) 字节）"
        case .jump:
            return "支持十进制（1048576）或十六进制（0x100000）"
        case .find:
            if !model.searchMatches.isEmpty {
                return "已找到 \(model.searchMatches.count) 处，当前第 \(model.searchIndex + 1) 处"
            }
            return "输入文本，或十六进制字节（如 1F 8B / 0x1F8B）"
        case nil:
            return ""
        }
    }

    private var promptPlaceholder: String {
        switch prompt {
        case .edit: return ""
        case .jump: return "0x100000"
        case .find: return model.searchMatches.isEmpty ? "查找内容" : "新关键词"
        case nil: return ""
        }
    }

    private var promptConfirmTitle: String {
        switch prompt {
        case .edit: return "应用"
        case .jump: return "跳转"
        case .find: return "查找"
        case nil: return "好"
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { model.saveError != nil },
            set: { presented in if !presented { model.saveError = nil } }
        )
    }

    private func presentPrompt(_ newPrompt: HexPrompt) {
        prompt = newPrompt
        promptText = ""
        DispatchQueue.main.async { isPromptPresented = true }
    }

    private func beginEdit(row: Int) {
        guard !model.isSaving, let current = model.currentHex(row: row) else { return }
        prompt = .edit(base: current.base, length: current.length)
        promptText = current.hex
        DispatchQueue.main.async { isPromptPresented = true }
    }

    private func confirmPrompt() {
        guard let active = prompt else { return }
        let text = promptText
        prompt = nil
        switch active {
        case .edit(let base, let length):
            if let error = model.applyHex(text, base: base, length: length) {
                model.showToast(error)
            }
        case .jump:
            if let target = Self.parseOffset(text) {
                model.jump(to: target)
            } else {
                model.showToast("无法识别的偏移")
            }
        case .find:
            model.search(query: text)
        }
    }

    private func nextMatchTapped() {
        prompt = nil
        model.showNextMatch()
    }

    private static func parseOffset(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") {
            let hex = String(trimmed.dropFirst(2))
            guard !hex.isEmpty else { return nil }
            return UInt64(hex, radix: 16)
        }
        return UInt64(trimmed)
    }
}

// MARK: - Prompt state

private enum HexPrompt: Equatable {
    case edit(base: UInt64, length: Int)
    case jump
    case find
}

private struct HexScrollRequest: Equatable {
    let id = UUID()
    let row: Int
}

private struct HexLine {
    let text: String
    let isModified: Bool
}

// MARK: - Model

@MainActor
private final class HexEditorModel: ObservableObject {
    static let pageSize: UInt64 = 64 * 1024
    static let bytesPerRow = 16

    let path: String

    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var fileSize: UInt64 = 0
    @Published private(set) var pageIndex: UInt64 = 0
    @Published private(set) var pageCount: UInt64 = 1
    @Published private(set) var patches: [UInt64: UInt8] = [:]
    @Published private(set) var isSaving = false
    @Published private(set) var searchMatches: [UInt64] = []
    @Published private(set) var searchIndex = 0
    @Published private(set) var scrollRequest: HexScrollRequest?
    @Published var toast: String?
    @Published var saveError: String?

    private var fd: Int32 = -1
    private var deviceID: dev_t = 0
    private var inodeID: ino_t = 0
    private var pageData: [UInt8] = []
    private var cachedPageIndex: UInt64 = .max
    private var hasStarted = false
    private var searchGeneration = 0
    private var toastGeneration = 0

    init(path: String) {
        self.path = path
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    // MARK: Derived state

    var rowCount: Int {
        let start = pageIndex * Self.pageSize
        let remaining = fileSize > start ? fileSize - start : 0
        let pageBytes = min(remaining, Self.pageSize)
        return Int((pageBytes + UInt64(Self.bytesPerRow) - 1) / UInt64(Self.bytesPerRow))
    }

    var headerText: String {
        let start = pageIndex * Self.pageSize
        let end = min(start + Self.pageSize, fileSize)
        return String(format: "页 %llu/%llu · 偏移 0x%llX–0x%llX · 共 %llu 字节 · 待保存修改 %ld",
                      pageIndex + 1, pageCount, start, end, fileSize, patches.count)
    }

    var canSave: Bool { !patches.isEmpty && !isSaving }
    var canGoPreviousPage: Bool { pageIndex > 0 }
    var canGoNextPage: Bool { pageIndex + 1 < pageCount }

    // MARK: Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        reload()
    }

    func reload() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        isLoading = true
        loadError = nil
        patches.removeAll()
        searchMatches = []
        searchIndex = 0
        pageIndex = 0
        pageCount = 1
        fileSize = 0
        pageData = []
        cachedPageIndex = .max

        guard let opened = Self.openRegularFile(path) else {
            isLoading = false
            loadError = FileManager.default.fileExists(atPath: path)
                ? "无法读取文件（可能没有访问权限）。"
                : "文件不存在或已被移动。"
            AppLog.tag("HexEditor", "open FAIL path=\(path)")
            return
        }
        fd = opened.fd
        deviceID = opened.device
        inodeID = opened.inode
        fileSize = opened.size
        pageCount = max(1, (fileSize + Self.pageSize - 1) / Self.pageSize)
        loadPage()
        isLoading = false
        AppLog.tag("HexEditor", "open path=\(path) size=\(fileSize)")
    }

    private static func openRegularFile(_ path: String)
        -> (fd: Int32, device: dev_t, inode: ino_t, size: UInt64)? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor)
            return nil
        }
        return (descriptor, info.st_dev, info.st_ino, UInt64(max(0, info.st_size)))
    }

    // MARK: Page reading

    func loadPage() {
        guard fd >= 0, cachedPageIndex != pageIndex else { return }
        let offset = pageIndex * Self.pageSize
        let remaining = fileSize > offset ? fileSize - offset : 0
        let want = Int(min(Self.pageSize, remaining))
        var buffer = [UInt8](repeating: 0, count: want)
        var done = 0
        while done < want {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return pread(fd, base.advanced(by: done), want - done,
                             off_t(offset) + off_t(done))
            }
            if count <= 0 { break }
            done += count
        }
        if done < buffer.count {
            buffer.removeLast(buffer.count - done)
        }
        pageData = buffer
        cachedPageIndex = pageIndex
    }

    func line(at row: Int) -> HexLine {
        let lineStart = row * Self.bytesPerRow
        let length = max(0, min(Self.bytesPerRow, pageData.count - lineStart))
        let base = pageIndex * Self.pageSize + UInt64(lineStart)
        var hex = ""
        var ascii = ""
        var modified = false
        for i in 0..<length {
            let patched = patches[base + UInt64(i)]
            let byte = patched ?? pageData[lineStart + i]
            modified = modified || patched != nil
            hex += String(format: "%02x ", byte)
            if i == 7 { hex += " " }
            ascii.append(byte >= 0x20 && byte != 0x7F
                ? Character(UnicodeScalar(byte))
                : ".")
        }
        let text = String(format: "%08llX  ", base) + hex + "| " + ascii
        return HexLine(text: text, isModified: modified)
    }

    // MARK: Editing

    func currentHex(row: Int) -> (base: UInt64, length: Int, hex: String)? {
        let lineStart = row * Self.bytesPerRow
        guard lineStart < pageData.count else { return nil }
        let length = min(Self.bytesPerRow, pageData.count - lineStart)
        let base = pageIndex * Self.pageSize + UInt64(lineStart)
        var hex = ""
        for i in 0..<length {
            hex += String(format: "%02x", patches[base + UInt64(i)] ?? pageData[lineStart + i])
        }
        return (base, length, hex)
    }

    /// 校验失败返回错误文案，成功返回 nil。
    func applyHex(_ input: String, base: UInt64, length: Int) -> String? {
        guard !isSaving else { return "保存进行中，无法编辑" }
        let compact = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count == length * 2, compact.allSatisfy({ $0.isHexDigit }) else {
            return "格式无效：需要本行 \(length) 字节（\(length * 2) 位十六进制字符）"
        }
        var index = compact.startIndex
        for i in 0..<length {
            let next = compact.index(index, offsetBy: 2)
            guard let value = UInt8(compact[index..<next], radix: 16) else {
                return "格式无效：包含非十六进制字符"
            }
            patches[base + UInt64(i)] = value
            index = next
        }
        return nil
    }

    func discardPatches() {
        guard !isSaving else { return }
        patches.removeAll()
    }

    // MARK: Navigation

    func goToPreviousPage() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        loadPage()
        scrollRequest = HexScrollRequest(row: 0)
    }

    func goToNextPage() {
        guard pageIndex + 1 < pageCount else { return }
        pageIndex += 1
        loadPage()
        scrollRequest = HexScrollRequest(row: 0)
    }

    func jump(to target: UInt64) {
        guard target < fileSize else {
            let maximum = fileSize > 0 ? fileSize - 1 : 0
            showToast(String(format: "超出文件范围（最大 0x%llX）", maximum))
            return
        }
        pageIndex = target / Self.pageSize
        loadPage()
        scrollRequest = HexScrollRequest(
            row: Int((target % Self.pageSize) / UInt64(Self.bytesPerRow)))
    }

    // MARK: Search

    func search(query: String) {
        guard let needle = HexSearcher.needle(from: query) else {
            showToast("请输入查找内容")
            return
        }
        let path = self.path
        searchGeneration += 1
        let generation = searchGeneration
        Task {
            let matches = await Task.detached(priority: .userInitiated) {
                HexSearcher.search(path: path, needle: needle, limit: 500)
            }.value
            guard generation == searchGeneration else { return }
            searchMatches = matches
            searchIndex = 0
            guard let first = matches.first else {
                showToast("未找到匹配内容")
                return
            }
            jump(to: first)
            showToast("第 1 / \(matches.count) 处，偏移 \(Self.offsetText(first))")
        }
    }

    func showNextMatch() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchMatches.count
        let offset = searchMatches[searchIndex]
        jump(to: offset)
        showToast("第 \(searchIndex + 1) / \(searchMatches.count) 处，偏移 \(Self.offsetText(offset))")
    }

    // MARK: Save

    func save() {
        guard !isSaving, !patches.isEmpty else { return }
        let snapshot = patches
        let path = self.path
        let fileSize = self.fileSize
        let deviceID = self.deviceID
        let inodeID = self.inodeID
        isSaving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                HexSaver.writePatches(snapshot, to: path, fileSize: fileSize,
                                      deviceID: deviceID, inodeID: inodeID)
            }.value
            finishSave(result, snapshot: snapshot)
        }
    }

    private func finishSave(_ result: HexSaveResult, snapshot: [UInt64: UInt8]) {
        isSaving = false
        switch result {
        case .success(let applied):
            for (offset, byte) in snapshot where patches[offset] == byte {
                patches.removeValue(forKey: offset)
            }
            if reopenAfterSave() {
                AppLog.tag("HexEditor", "saved path=\(path) patches=\(applied)")
                showToast("已写入 \(applied) 处修改")
            } else {
                AppLog.tag("HexEditor", "saved but reopen FAIL path=\(path)")
                showToast("已保存，但重新打开文件失败，请退出后重进")
            }
        case .failure(let message):
            AppLog.tag("HexEditor", "save FAIL path=\(path) error=\(message)")
            saveError = message
        }
    }

    private func reopenAfterSave() -> Bool {
        guard let opened = Self.openRegularFile(path) else { return false }
        if fd >= 0 { close(fd) }
        fd = opened.fd
        deviceID = opened.device
        inodeID = opened.inode
        fileSize = opened.size
        pageCount = max(1, (fileSize + Self.pageSize - 1) / Self.pageSize)
        if pageIndex >= pageCount { pageIndex = pageCount - 1 }
        pageData = []
        cachedPageIndex = .max
        loadPage()
        return true
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toast = message
        toastGeneration += 1
        let generation = toastGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, generation == self.toastGeneration else { return }
            self.toast = nil
        }
    }

    static func offsetText(_ offset: UInt64) -> String {
        String(format: "0x%llX", offset)
    }
}

// MARK: - Atomic save

private enum HexSaveResult {
    case success(applied: Int)
    case failure(String)
}

private enum HexSaver {
    /// 先把原文件整份复制成同目录临时文件，在临时文件上打补丁并 fsync，
    /// 确认原文件未被替换后 rename 覆盖。任何失败都清理临时文件，原文件不变。
    static func writePatches(_ patches: [UInt64: UInt8], to path: String,
                             fileSize: UInt64, deviceID: dev_t,
                             inodeID: ino_t) -> HexSaveResult {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).ffhex-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try manager.copyItem(at: url, to: tempURL)
        } catch {
            return .failure("无法创建临时文件：\(error.localizedDescription)")
        }

        let descriptor = open(tempURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let message = String(cString: strerror(errno))
            try? manager.removeItem(at: tempURL)
            return .failure("打开临时文件失败：\(message)")
        }

        var failure: String?
        var applied = 0
        for (offset, byte) in patches {
            guard offset < fileSize else { continue }
            var value = byte
            if pwrite(descriptor, &value, 1, off_t(offset)) != 1 {
                failure = "写入 \(offsetText(offset)) 失败：\(String(cString: strerror(errno)))"
                break
            }
            applied += 1
        }
        if failure == nil && fsync(descriptor) != 0 {
            failure = "fsync 失败：\(String(cString: strerror(errno)))"
        }
        close(descriptor)

        if failure == nil {
            var current = stat()
            if lstat(path, &current) != 0
                || current.st_dev != deviceID
                || current.st_ino != inodeID {
                failure = "目标文件已被其他程序替换，拒绝覆盖。"
            }
        }
        if failure == nil && rename(tempURL.path, path) != 0 {
            failure = "替换原文件失败：\(String(cString: strerror(errno)))"
        }
        if let failure = failure {
            try? manager.removeItem(at: tempURL)
            return .failure(failure)
        }
        return .success(applied: applied)
    }

    private static func offsetText(_ offset: UInt64) -> String {
        String(format: "0x%llX", offset)
    }
}

// MARK: - Cross-page search

private enum HexSearcher {
    /// 以 0x 开头或含空格的纯十六进制串按字节处理，否则按 UTF-8 文本。
    static func needle(from query: String) -> Data? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") || trimmed.contains(" ") {
            let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
            var body = compact
            if body.lowercased().hasPrefix("0x") {
                body = String(body.dropFirst(2))
            }
            if !body.isEmpty, body.count % 2 == 0, body.allSatisfy({ $0.isHexDigit }) {
                var data = Data()
                var index = body.startIndex
                while index < body.endIndex {
                    let next = body.index(index, offsetBy: 2)
                    if let value = UInt8(body[index..<next], radix: 16) {
                        data.append(value)
                    }
                    index = next
                }
                if !data.isEmpty { return data }
            }
        }
        return trimmed.data(using: .utf8)
    }

    static func search(path: String, needle: Data, limit: Int) -> [UInt64] {
        let needleBytes = [UInt8](needle)
        let needleLength = needleBytes.count
        guard needleLength > 0 else { return [] }

        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return [] }
        let fileSize = UInt64(max(0, info.st_size))

        let chunk = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk + max(needleLength, 1))
        var matches: [UInt64] = []
        var offset: UInt64 = 0
        var carry = 0

        while matches.count < limit && offset < fileSize {
            let count = pread(descriptor, &buffer[carry], chunk, off_t(offset))
            if count <= 0 { break }
            let total = carry + count
            buffer.withUnsafeBufferPointer { file in
                needleBytes.withUnsafeBufferPointer { pattern in
                    guard let fileBase = file.baseAddress,
                          let patternBase = pattern.baseAddress else { return }
                    var index = 0
                    while index + needleLength <= total {
                        if memcmp(fileBase + index, patternBase, needleLength) == 0 {
                            matches.append(offset - UInt64(carry) + UInt64(index))
                            if matches.count >= limit { break }
                        }
                        index += 1
                    }
                }
            }
            if needleLength > 1 {
                carry = min(needleLength - 1, total)
                buffer.replaceSubrange(0..<carry, with: buffer[(total - carry)..<total])
            } else {
                carry = 0
            }
            offset += UInt64(count)
        }
        return matches
    }
}
