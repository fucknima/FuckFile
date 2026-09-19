import Combine
import SwiftUI

/// 文件关联设置：列出已有覆盖项（按扩展名），显示当前与内置默认查看器；
/// 可新增扩展名、点条目更换查看器、左滑清除覆盖恢复默认。改动即时生效。
struct FileAssociationsView: View {
    private static let overrideKeyPrefix = "FFViewerOverride."

    @State private var extensions: [String] = []
    @State private var pendingExtension: String?
    @State private var isPickerPresented = false
    @State private var isAddAlertPresented = false
    @State private var newExtension = ""

    init() {}

    var body: some View {
        List {
            if extensions.isEmpty {
                Text("还没有覆盖项。点右上角「＋」新增扩展名并选择查看器。")
                    .foregroundColor(.secondary)
            } else {
                Section {
                    ForEach(extensions, id: \.self) { ext in
                        NavigationLink {
                            ViewerPickerView(extension: ext) { _ in reload() }
                        } label: {
                            row(for: ext)
                        }
                    }
                    .onDelete(perform: removeOverrides)
                } header: {
                    Text("已有覆盖")
                } footer: {
                    Text("点条目更换查看器；左滑删除恢复内置默认。匹配按最长后缀优先（backup.tar.gz 先试 .tar.gz 再试 .gz），大小写不敏感。")
                }
            }
        }
        .navigationTitle("文件关联")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newExtension = ""
                    isAddAlertPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增扩展名")
            }
        }
        .navigationDestination(isPresented: $isPickerPresented) {
            if let ext = pendingExtension {
                ViewerPickerView(extension: ext) { _ in reload() }
            }
        }
        .alert("新增自定义扩展名", isPresented: $isAddAlertPresented) {
            TextField("扩展名", text: $newExtension)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { newExtension = "" }
            Button("下一步") {
                let ext = normalizedExtension(newExtension)
                newExtension = ""
                guard !ext.isEmpty else { return }
                pendingExtension = ext
                isPickerPresented = true
            }
            .disabled(normalizedExtension(newExtension).isEmpty)
        } message: {
            Text("输入不带点号的扩展名，例如 mkd；随后选择查看器。")
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reload()
        }
    }

    private func row(for ext: String) -> some View {
        let overridden = FileAssociationService.override(forExtension: ext)
        let builtin = FileAssociationService.defaultViewerID(forExtension: ext)
        let effective = overridden ?? builtin
        return HStack(spacing: 12) {
            Image(systemName: effective.icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(".\(ext)")
                    .font(.body.monospaced())
                Text(subtitle(overridden: overridden, builtin: builtin))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func subtitle(overridden: ViewerID?, builtin: ViewerID) -> String {
        if let overridden = overridden {
            return "当前：\(overridden.title) · 默认：\(builtin.title)"
        }
        return "默认：\(builtin.title)"
    }

    private func reload() {
        extensions = Self.overrideExtensions()
    }

    private func removeOverrides(at offsets: IndexSet) {
        for index in offsets where index < extensions.count {
            FileAssociationService.setOverride(nil, forExtension: extensions[index])
        }
        reload()
    }

    /// 服务只提供按扩展名读取覆盖，列表由 UserDefaults 键前缀反查（与服务同一键空间）。
    private static func overrideExtensions() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .compactMap { key -> String? in
                guard key.hasPrefix(overrideKeyPrefix) else { return nil }
                let ext = String(key.dropFirst(overrideKeyPrefix.count))
                return ext.isEmpty ? nil : ext
            }
            .sorted()
    }

    private func normalizedExtension(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasPrefix(".") { key.removeFirst() }
        return key
    }
}
