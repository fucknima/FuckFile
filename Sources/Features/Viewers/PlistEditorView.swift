import SwiftUI
import UIKit

/// plist 树形编辑器（对齐 FFPlistEditorViewController 的核心行为）：
/// 字典/数组可展开，叶子值可编辑，支持新增/删除键与数组元素；
/// 保存前检测外部修改并给出覆盖/另存副本/取消；
/// 超过 2MB 只读浏览并禁用编辑与保存。
struct PlistEditorView: View {
    let entry: FileEntry

    @Environment(\.dismiss) private var dismiss

    @State private var document: PlistDocument?
    @State private var rows: [PlistRow] = []
    @State private var expanded: Set<PlistPath> = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var editorTarget: ValueEditorTarget?
    @State private var isUnsavedAlertPresented = false
    @State private var isConflictAlertPresented = false

    @State private var pendingDelete: PlistRow?
    @State private var isDeleteAlertPresented = false

    @State private var pendingAddKind: PlistNewValueKind?
    @State private var addContainerPath: PlistPath = []
    @State private var newKey = ""
    @State private var isAddKeyAlertPresented = false

    @State private var messageTitle = ""
    @State private var messageText = ""
    @State private var isMessageAlertPresented = false

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
                content
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .task { await load() }
        .sheet(item: $editorTarget) { target in
            PlistValueEditorSheet(title: target.name, original: target.value) { newValue in
                document?.setValue(newValue, at: target.path)
                rebuildRows()
            }
        }
        .alert("未保存的修改", isPresented: $isUnsavedAlertPresented) {
            Button("保存") { saveAndDismissIfNeeded() }
            Button("放弃", role: .destructive) { dismiss() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("是否保存对此 plist 的修改？")
        }
        .alert("文件已被外部修改", isPresented: $isConflictAlertPresented) {
            Button("覆盖", role: .destructive) { save(force: true) }
            Button("另存副本") { saveEditedCopy() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("打开此 plist 后，磁盘内容发生了变化。为避免覆盖 App 或系统刚写入的数据，请选择处理方式。")
        }
        .alert("删除条目？", isPresented: $isDeleteAlertPresented, presenting: pendingDelete) { row in
            Button("删除", role: .destructive) { performDelete(row) }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { row in
            Text("将删除 \(row.name)。此操作在保存文件前仍可通过放弃修改撤销。")
        }
        .alert(addAlertTitle, isPresented: $isAddKeyAlertPresented) {
            TextField("Key", text: $newKey)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) { pendingAddKind = nil }
            Button("添加") { commitAddWithKey() }
        } message: {
            Text("添加到 \(addContainerPath.displayString)；已有 Key 不会被覆盖。")
        }
        .alert(messageTitle, isPresented: $isMessageAlertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(messageText)
        }
    }

    // MARK: - Subviews

    private var content: some View {
        VStack(spacing: 0) {
            if let document, !document.isEditable {
                Text(readOnlyNotice(document))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
            List {
                ForEach(rows) { row in
                    rowView(row)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canEdit && !row.isRoot {
                                Button(role: .destructive) {
                                    pendingDelete = row
                                    isDeleteAlertPresented = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu { contextMenu(for: row) }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func rowView(_ row: PlistRow) -> some View {
        HStack(spacing: 8) {
            if row.value.isContainer {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Image(systemName: row.value.symbolName)
                .foregroundColor(row.value.tintColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(rowTitleFont(row))
                    .lineLimit(1)
                Text("\(row.value.typeName) · \(row.value.summary)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(min(row.depth, 12)) * 18)
        .contentShape(Rectangle())
        .onTapGesture { tap(row) }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("无法打开属性表")
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

    @ViewBuilder
    private func contextMenu(for row: PlistRow) -> some View {
        if canEdit {
            if row.value.isContainer {
                Menu {
                    ForEach(PlistNewValueKind.allCases) { kind in
                        Button(kind.title) { beginAdd(kind, to: row.path) }
                    }
                } label: {
                    Label("添加子项", systemImage: "plus")
                }
            } else {
                Button {
                    editorTarget = ValueEditorTarget(path: row.path,
                                                     name: row.name,
                                                     value: row.value)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("返回") { backTapped() }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if canEdit {
                Menu {
                    ForEach(PlistNewValueKind.allCases) { kind in
                        Button(kind.title) { beginAdd(kind, to: []) }
                    }
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
            Button("保存") { save(force: false) }
                .disabled(!canEdit || document?.isDirty != true)
        }
    }

    // MARK: - State

    private var canEdit: Bool {
        document?.isEditable == true
    }

    private var addAlertTitle: String {
        "添加\(pendingAddKind?.title ?? "条目")"
    }

    private func rowTitleFont(_ row: PlistRow) -> Font {
        if row.isRoot { return .headline }
        if row.value.isContainer { return .body.weight(.semibold) }
        return .body
    }

    private func readOnlyNotice(_ document: PlistDocument) -> String {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: document.fileSize),
                                                 countStyle: .file)
        return "只读浏览：文件较大（\(sizeText)），已禁用编辑与保存。"
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        let path = entry.path
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PlistDocument.load(path: path) }
        }.value

        isLoading = false
        switch result {
        case .success(let loaded):
            document = loaded
            expanded = [[]]
            rebuildRows()
        case .failure(let error):
            document = nil
            rows = []
            loadError = error.localizedDescription
        }
    }

    // MARK: - Tree

    private func rebuildRows() {
        guard let root = document?.root else {
            rows = []
            return
        }
        var result: [PlistRow] = []
        appendRows(for: root, path: [], name: "Root", depth: 0, isRoot: true, into: &result)
        rows = result
    }

    private func appendRows(for value: PlistValue,
                            path: PlistPath,
                            name: String,
                            depth: Int,
                            isRoot: Bool,
                            into result: inout [PlistRow]) {
        let isExpanded = expanded.contains(path)
        result.append(PlistRow(path: path,
                               name: name,
                               value: value,
                               depth: depth,
                               isRoot: isRoot,
                               isExpanded: isExpanded))
        guard value.isContainer, isExpanded else { return }

        switch value {
        case .dictionary(let values):
            let keys = values.keys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            for key in keys {
                guard let child = values[key] else { continue }
                appendRows(for: child,
                           path: path + [.key(key)],
                           name: key,
                           depth: depth + 1,
                           isRoot: false,
                           into: &result)
            }
        case .array(let values):
            for (index, child) in values.enumerated() {
                appendRows(for: child,
                           path: path + [.index(index)],
                           name: "[\(index)]",
                           depth: depth + 1,
                           isRoot: false,
                           into: &result)
            }
        default:
            break
        }
    }

    private func tap(_ row: PlistRow) {
        if row.value.isContainer {
            if expanded.contains(row.path) {
                expanded.remove(row.path)
            } else {
                expanded.insert(row.path)
            }
            rebuildRows()
        } else if canEdit {
            editorTarget = ValueEditorTarget(path: row.path, name: row.name, value: row.value)
        }
    }

    // MARK: - Mutations

    private func beginAdd(_ kind: PlistNewValueKind, to path: PlistPath) {
        guard canEdit else { return }
        if case .dictionary? = document?.root.value(at: path) {
            pendingAddKind = kind
            addContainerPath = path
            newKey = ""
            isAddKeyAlertPresented = true
        } else {
            document?.addValue(kind.defaultValue, toContainerAt: path, key: nil)
            expanded.insert(path)
            rebuildRows()
        }
    }

    private func commitAddWithKey() {
        guard let kind = pendingAddKind else { return }
        pendingAddKind = nil
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            presentMessage("无法添加", "Key 不能为空。")
            return
        }
        let path = addContainerPath
        if case .dictionary(let values)? = document?.root.value(at: path), values[key] != nil {
            presentMessage("无法添加", "同名 Key 已存在，不会覆盖原值。")
            return
        }
        document?.addValue(kind.defaultValue, toContainerAt: path, key: key)
        expanded.insert(path)
        rebuildRows()
    }

    private func performDelete(_ row: PlistRow) {
        document?.removeValue(at: row.path)
        pendingDelete = nil
        if let last = row.path.last, case .key = last {
            expanded = expanded.filter { !isPrefix(row.path, of: $0) }
        } else {
            let parentPath = Array(row.path.dropLast())
            expanded = expanded.filter { candidate in
                candidate.count <= parentPath.count || !isPrefix(parentPath, of: candidate)
            }
        }
        rebuildRows()
    }

    private func isPrefix(_ prefix: PlistPath, of path: PlistPath) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }

    // MARK: - Save

    private func backTapped() {
        if document?.isDirty == true {
            isUnsavedAlertPresented = true
        } else {
            dismiss()
        }
    }

    private func saveAndDismissIfNeeded() {
        save(force: false) { success in
            if success { dismiss() }
        }
    }

    private func save(force: Bool, completion: ((Bool) -> Void)? = nil) {
        guard var updated = document else {
            completion?(false)
            return
        }
        do {
            try updated.save(force: force)
            document = updated
            rebuildRows()
            completion?(true)
        } catch PlistDocument.DocumentError.externalModification {
            presentConflict()
            completion?(false)
        } catch {
            presentMessage("保存失败", error.localizedDescription)
            completion?(false)
        }
    }

    /// 冲突弹窗可能紧跟在「未保存的修改」弹窗之后出现，延迟一拍避免被系统丢弃。
    private func presentConflict() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isConflictAlertPresented = true
        }
    }

    private func saveEditedCopy() {
        guard let document else { return }
        let copyPath = PlistDocument.editedCopyPath(for: document.filePath)
        do {
            try FileManager.default.createDirectory(
                atPath: (copyPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try document.saveCopy(to: copyPath)
            presentMessage("副本已保存", copyPath)
        } catch {
            presentMessage("副本保存失败", error.localizedDescription)
        }
    }

    private func presentMessage(_ title: String, _ message: String) {
        messageTitle = title
        messageText = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isMessageAlertPresented = true
        }
    }
}

// MARK: - Row model

private struct PlistRow: Identifiable {
    let path: PlistPath
    let name: String
    let value: PlistValue
    let depth: Int
    let isRoot: Bool
    let isExpanded: Bool

    var id: PlistPath { path }
}

private struct ValueEditorTarget: Identifiable {
    let path: PlistPath
    let name: String
    let value: PlistValue

    var id: PlistPath { path }
}

private enum PlistNewValueKind: String, CaseIterable, Identifiable {
    case string, boolean, integer, real, date, data, dictionary, array

    var id: String { rawValue }

    var title: String {
        switch self {
        case .string: return "字符串"
        case .boolean: return "布尔"
        case .integer: return "整数"
        case .real: return "实数"
        case .date: return "日期"
        case .data: return "数据"
        case .dictionary: return "字典"
        case .array: return "数组"
        }
    }

    var defaultValue: PlistValue {
        switch self {
        case .string: return .string("")
        case .boolean: return .boolean(false)
        case .integer: return .integer(0)
        case .real: return .real(0)
        case .date: return .date(Date())
        case .data: return .data(Data())
        case .dictionary: return .dictionary([:])
        case .array: return .array([])
        }
    }
}

// MARK: - Presentation

private extension PlistValue {
    var symbolName: String {
        switch self {
        case .dictionary: return "curlybraces.square"
        case .array: return "list.number"
        case .string: return "text.quote"
        case .data: return "tray.full"
        case .date: return "calendar"
        case .boolean(let value): return value ? "checkmark.circle.fill" : "xmark.circle"
        case .integer: return "number.square"
        case .real: return "function"
        }
    }

    var tintColor: Color {
        switch self {
        case .dictionary: return .orange
        case .array: return .purple
        case .string: return .blue
        case .data: return .gray
        case .date: return .red
        case .boolean(let value): return value ? .green : .gray
        case .integer: return .teal
        case .real: return .indigo
        }
    }
}

// MARK: - Value editor sheet

private struct PlistValueEditorSheet: View {
    let title: String
    let original: PlistValue
    let onCommit: (PlistValue) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var stringText = ""
    @State private var numberText = ""
    @State private var booleanValue = false
    @State private var dateValue = Date()
    @State private var dataMode = 0
    @State private var dataText = ""

    @State private var errorMessage = ""
    @State private var isErrorPresented = false

    init(title: String, original: PlistValue, onCommit: @escaping (PlistValue) -> Void) {
        self.title = title
        self.original = original
        self.onCommit = onCommit

        switch original {
        case .string(let value):
            _stringText = State(initialValue: value)
        case .integer(let value):
            _numberText = State(initialValue: String(value))
        case .real(let value):
            _numberText = State(initialValue: String(value))
        case .boolean(let value):
            _booleanValue = State(initialValue: value)
        case .date(let value):
            _dateValue = State(initialValue: value)
        case .data(let value):
            _dataText = State(initialValue: PlistValueEditorSheet.hexString(from: value))
        default:
            break
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                editorFields
                if let hint = hintText {
                    Section {
                        Text(hint)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit() }
                }
            }
            .alert("无法保存", isPresented: $isErrorPresented) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    @ViewBuilder
    private var editorFields: some View {
        switch original {
        case .string:
            Section("字符串（String）") {
                TextEditor(text: $stringText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }
        case .boolean:
            Section("布尔（Boolean）") {
                Toggle("值", isOn: $booleanValue)
            }
        case .integer:
            Section("整数（Integer）") {
                numberField(placeholder: "整数")
            }
        case .real:
            Section("实数（Real）") {
                numberField(placeholder: "实数")
            }
        case .date:
            Section("日期（Date）") {
                DatePicker("值", selection: $dateValue, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
            }
        case .data:
            Section("数据（Data）") {
                Picker("格式", selection: dataModeBinding) {
                    Text("HEX").tag(0)
                    Text("Base64").tag(1)
                }
                .pickerStyle(.segmented)
                TextEditor(text: $dataText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 200)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }
        default:
            Section {
                Text("此类型不能直接编辑。")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func numberField(placeholder: String) -> some View {
        TextField(placeholder, text: $numberText)
            .font(.system(.body, design: .monospaced))
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
    }

    private var hintText: String? {
        switch original {
        case .integer:
            return "只接受完整的十进制整数；非法输入不会被替换成 0。"
        case .real:
            return "只接受完整的十进制实数；非法输入不会被替换成 0。"
        case .data:
            return dataMode == 1
                ? "Base64 必须完整有效；空白字符会被忽略。"
                : "HEX 可包含空格和换行；必须由完整的两位十六进制字节组成。"
        default:
            return nil
        }
    }

    /// 切换格式时先把当前内容按旧格式解析，成功后重新编码（与 ObjC 版一致）。
    private var dataModeBinding: Binding<Int> {
        Binding(
            get: { dataMode },
            set: { newMode in
                guard newMode != dataMode else { return }
                switch parseData(dataText, base64: dataMode == 1) {
                case .success(let data):
                    dataMode = newMode
                    dataText = newMode == 1
                        ? data.base64EncodedString()
                        : PlistValueEditorSheet.hexString(from: data)
                case .failure(let message):
                    presentError(message)
                }
            }
        )
    }

    private func commit() {
        switch original {
        case .string:
            onCommit(.string(stringText))
        case .boolean:
            onCommit(.boolean(booleanValue))
        case .integer:
            let text = numberText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int64(text) else {
                presentError("请输入完整的十进制整数。")
                return
            }
            onCommit(.integer(value))
        case .real:
            let text = numberText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(text), value.isFinite else {
                presentError("请输入完整、有限的十进制实数。")
                return
            }
            onCommit(.real(value))
        case .date:
            onCommit(.date(dateValue))
        case .data:
            switch parseData(dataText, base64: dataMode == 1) {
            case .success(let data):
                onCommit(.data(data))
            case .failure(let message):
                presentError(message)
                return
            }
        default:
            presentError("此类型不能直接编辑。")
            return
        }
        dismiss()
    }

    private func presentError(_ message: String) {
        errorMessage = message
        isErrorPresented = true
    }

    private func parseData(_ text: String, base64: Bool) -> Result<Data, String> {
        if base64 {
            let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
            if compact.isEmpty { return .success(Data()) }
            guard let data = Data(base64Encoded: compact) else {
                return .failure("Base64 内容无效。")
            }
            return .success(data)
        }

        var compact = ""
        for character in text where !character.isWhitespace && character != "<" && character != ">" {
            compact.append(character)
        }
        if compact.isEmpty { return .success(Data()) }
        guard compact.count % 2 == 0 else {
            return .failure("HEX 字符数必须为偶数。")
        }

        var data = Data(capacity: compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            let pair = compact[index..<next]
            guard let byte = UInt8(pair, radix: 16) else {
                return .failure("“\(pair)” 不是有效的 HEX 字节。")
            }
            data.append(byte)
            index = next
        }
        return .success(data)
    }

    private static func hexString(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var parts: [String] = []
        parts.reserveCapacity(data.count)
        for (index, byte) in data.enumerated() {
            if index > 0 {
                parts.append(index % 16 == 0 ? "\n" : " ")
            }
            parts.append(String(format: "%02X", byte))
        }
        return parts.joined()
    }
}
