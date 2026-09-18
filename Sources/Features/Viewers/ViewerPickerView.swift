import SwiftUI

/// 查看器选择器：列出该扩展名可用的查看器并标记当前生效项；点选回调
/// onPick（由调用方决定打开还是仅记录）。「设为默认」开关写入/清除
/// 用户覆盖（FileAssociationService.setOverride），即时生效。
struct ViewerPickerView: View {
    private let extensionKey: String
    private let pickerTitle: String
    private let onPick: (ViewerID) -> Void

    @State private var viewers: [ViewerID] = []
    @State private var effectiveViewer: ViewerID = .quickLook
    @State private var defaultViewer: ViewerID = .quickLook
    @State private var hasOverride = false

    init(entry: FileEntry, onPick: @escaping (ViewerID) -> Void) {
        self.extensionKey = (entry.name as NSString).pathExtension.lowercased()
        self.pickerTitle = entry.name
        self.onPick = onPick
    }

    /// 关联设置页按扩展名使用（对应 ObjC 的 initWithExtension:，支持 tar.gz 这类复合后缀）。
    init(`extension`: String, onPick: @escaping (ViewerID) -> Void) {
        var key = `extension`.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasPrefix(".") { key.removeFirst() }
        self.extensionKey = key
        self.pickerTitle = key.isEmpty ? "选择查看器" : ".\(key) 使用"
        self.onPick = onPick
    }

    var body: some View {
        List {
            Section {
                ForEach(viewers) { viewer in
                    Button {
                        pick(viewer)
                    } label: {
                        HStack {
                            Label(viewer.title, systemImage: viewer.icon)
                                .foregroundColor(.primary)
                            Spacer()
                            if viewer == effectiveViewer {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("可用查看器")
            } footer: {
                Text("带勾的是当前生效的查看器。开启「设为默认」后点选会写入覆盖；关闭时点选只回调，不自动修改默认。")
            }

            Section {
                Toggle("设为默认", isOn: defaultBinding)
            } footer: {
                Text("关闭后清除 .\(extensionKey) 的覆盖，恢复内置默认（\(defaultViewer.title)）。")
            }
        }
        .navigationTitle(pickerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { hasOverride },
            set: { setDefaultEnabled($0) }
        )
    }

    private func pick(_ viewer: ViewerID) {
        if hasOverride {
            FileAssociationService.setOverride(viewer, forExtension: extensionKey)
        }
        AppLog.tag("ViewerPicker", "pick ext=\(extensionKey) viewer=\(viewer.rawValue) override=\(hasOverride)")
        onPick(viewer)
        reload()
    }

    private func setDefaultEnabled(_ enabled: Bool) {
        FileAssociationService.setOverride(enabled ? effectiveViewer : nil,
                                           forExtension: extensionKey)
        AppLog.tag("ViewerPicker", "default ext=\(extensionKey) enabled=\(enabled) viewer=\(effectiveViewer.rawValue)")
        reload()
    }

    private func reload() {
        defaultViewer = FileAssociationService.defaultViewerID(forExtension: extensionKey)
        hasOverride = FileAssociationService.override(forExtension: extensionKey) != nil
        effectiveViewer = FileAssociationService.override(forExtension: extensionKey) ?? defaultViewer
        viewers = FileAssociationService.supportedViewers(forExtension: extensionKey)
    }
}
