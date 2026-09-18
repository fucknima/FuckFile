import SwiftUI
import UIKit

/// 文本查看 / 编辑器。
/// 大文件策略（对齐 FFTextEditorViewController）：
///   ≤ 2MB 正常编辑；2–8MB 可编辑（本阶段无语法高亮，行为一致）；
///   > 8MB 只读预览，仅载入前 1MB，禁止保存。
struct TextEditorView: View {
    let entry: FileEntry

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var encoding: TextEncodingKind = .utf8
    @State private var hasBOM = false
    @State private var lineEnding: LineEnding = .lf
    @State private var isLoading = true
    @State private var isReadOnly = false
    @State private var isDirty = false
    @State private var readOnlyNotice: String?
    @State private var loadError: String?
    @State private var isUnsavedAlertPresented = false
    @State private var errorMessage: String?
    @State private var isErrorAlertPresented = false

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在载入…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = loadError {
                errorState(message)
            } else {
                editor
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .task { await load() }
        .alert("未保存的修改", isPresented: $isUnsavedAlertPresented) {
            Button("保存") { saveAndDismissIfNeeded() }
            Button("放弃", role: .destructive) { dismiss() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("是否保存对此文件的修改？")
        }
    }

    // MARK: - Subviews

    private var editor: some View {
        VStack(spacing: 0) {
            if let notice = readOnlyNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
            TextEditorTextView(text: text, isEditable: !isReadOnly) { newText in
                text = newText
                isDirty = true
            }
        }
        .alert("无法保存", isPresented: $isErrorAlertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("无法打开文本")
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("返回") { backTapped() }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button("保存") { save() }
                .disabled(!isDirty || isReadOnly || isLoading || loadError != nil)
            Menu {
                ForEach(TextEncodingKind.allCases) { kind in
                    Button {
                        guard kind != encoding else { return }
                        encoding = kind
                        hasBOM = kind.writesBOM
                        isDirty = true
                    } label: {
                        if kind == encoding {
                            Label(kind.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(kind.menuTitle)
                        }
                    }
                }
            } label: {
                Label("编码", systemImage: "textformat")
            }
            .disabled(isReadOnly || isLoading || loadError != nil)

            Menu {
                ForEach(LineEnding.allCases) { ending in
                    Button {
                        guard ending != lineEnding else { return }
                        lineEnding = ending
                        isDirty = true
                    } label: {
                        if ending == lineEnding {
                            Label(ending.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(ending.menuTitle)
                        }
                    }
                }
            } label: {
                Label("换行符", systemImage: "arrow.turn.down.left")
            }
            .disabled(isReadOnly || isLoading || loadError != nil)
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        let path = entry.path
        let fallbackSize = entry.size
        let result = await Task.detached(priority: .userInitiated) {
            Self.readFile(path: path, fallbackSize: fallbackSize)
        }.value

        isLoading = false
        if let message = result.error {
            loadError = message
            return
        }
        guard let loaded = result.text else {
            loadError = "无法按支持的编码解码此文件。"
            return
        }
        text = loaded
        encoding = result.encoding
        hasBOM = result.bom
        lineEnding = result.lineEnding
        isReadOnly = result.isReadOnly
        readOnlyNotice = result.notice
        isDirty = false
    }

    private static func readFile(path: String, fallbackSize: UInt64) -> TextLoadResult {
        let editableLimit: UInt64 = 8 * 1024 * 1024
        let previewLimit = 1024 * 1024
        let url = URL(fileURLWithPath: path)
        var size = fallbackSize
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let number = attributes[.size] as? NSNumber {
            size = number.uint64Value
        }

        if size > editableLimit {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return TextLoadResult(error: "无法读取文件（可能没有访问权限）。")
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: previewLimit)) ?? Data()
            guard let decoded = decodePreview(data) else {
                return TextLoadResult(error: "无法按支持的编码解码此文件。")
            }
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: size),
                                                     countStyle: .file)
            let notice = "只读预览：文件较大（\(sizeText)），仅显示前 1 MB，不能保存。"
            return TextLoadResult(text: decoded.text,
                                  encoding: decoded.encoding,
                                  bom: decoded.bom,
                                  lineEnding: decoded.lineEnding,
                                  isReadOnly: true,
                                  notice: notice)
        }

        guard let data = try? Data(contentsOf: url) else {
            return TextLoadResult(error: "无法读取文件（可能没有访问权限）。")
        }
        guard let decoded = TextCodec.decode(data) else {
            return TextLoadResult(error: "无法按支持的编码解码此文件。")
        }
        return TextLoadResult(text: decoded.text,
                              encoding: decoded.encoding,
                              bom: decoded.bom,
                              lineEnding: decoded.lineEnding)
    }

    /// 1MB 窗口末尾可能截断多字节字符：Latin-1 兜底结果最多回退 3 字节再试。
    private static func decodePreview(_ data: Data) -> DecodedText? {
        guard let decoded = TextCodec.decode(data) else { return nil }
        guard decoded.encoding == .latin1, data.count > 4 else { return decoded }
        for trim in 1...3 {
            let trimmed = Data(data.prefix(data.count - trim))
            if let candidate = TextCodec.decode(trimmed), candidate.encoding != .latin1 {
                return candidate
            }
        }
        return decoded
    }

    // MARK: - Back / Save

    private func backTapped() {
        if isDirty && !isReadOnly {
            isUnsavedAlertPresented = true
        } else {
            dismiss()
        }
    }

    private func saveAndDismissIfNeeded() {
        if save() {
            dismiss()
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !isReadOnly else { return false }
        guard let data = TextCodec.encode(text,
                                          encoding: encoding,
                                          bom: hasBOM,
                                          lineEnding: lineEnding) else {
            presentError("无法用所选编码编码此内容（存在无法表示的字符）。")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: entry.path), options: .atomic)
            isDirty = false
            AppLog.tag("TextEditor", "save OK path=\(entry.path) bytes=\(data.count)")
            return true
        } catch {
            AppLog.tag("TextEditor", "save FAIL path=\(entry.path) error=\(error.localizedDescription)")
            presentError("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        // 前一个 alert（未保存确认）可能还在收起，稍后再弹，避免被系统丢弃。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isErrorAlertPresented = true
        }
    }
}

// MARK: - UITextView wrapper

private struct TextEditorTextView: UIViewRepresentable {
    let text: String
    let isEditable: Bool
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.delegate = context.coordinator
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onChange = onChange
        uiView.isEditable = isEditable
        uiView.isSelectable = true
        if uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textViewDidChange(_ textView: UITextView) {
            onChange(textView.text ?? "")
        }
    }
}

// MARK: - Load result & menu titles

private struct TextLoadResult {
    var text: String?
    var encoding: TextEncodingKind = .utf8
    var bom = false
    var lineEnding: LineEnding = .lf
    var isReadOnly = false
    var notice: String?
    var error: String?
}

private extension TextEncodingKind {
    var menuTitle: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 (BOM)"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return "Latin-1"
        }
    }

    /// 用户主动切换编码时默认是否写出 BOM（与 FFTextEditorViewController 一致）。
    var writesBOM: Bool {
        self == .utf8BOM || self == .utf16LE || self == .utf16BE
    }
}

private extension LineEnding {
    var menuTitle: String {
        switch self {
        case .lf: return "LF (Unix)"
        case .crlf: return "CRLF (Windows)"
        case .cr: return "CR (Mac)"
        }
    }
}
