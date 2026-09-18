import SwiftUI

/// 查看器统一工具栏动作：分享 / 文件信息 / 删除。
/// 用 ToolbarItem 追加，查看器自身的保存等按钮不受影响。
struct ViewerActionsModifier: ViewModifier {
    let entry: FileEntry

    @Environment(\.dismiss) private var dismiss
    @State private var isSharing = false
    @State private var isShowingInfo = false
    @State private var isConfirmingTrash = false

    init(entry: FileEntry) {
        self.entry = entry
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isShowingInfo = true
                    } label: {
                        Label("文件信息", systemImage: "info.circle")
                    }

                    Button {
                        isConfirmingTrash = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: [URL(fileURLWithPath: entry.path)])
            }
            .sheet(isPresented: $isShowingInfo) {
                NavigationStack {
                    FileInfoView(entry: entry)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { isShowingInfo = false }
                            }
                        }
                }
            }
            .confirmationDialog("移到回收站",
                                isPresented: $isConfirmingTrash,
                                titleVisibility: .visible) {
                Button("移到回收站", role: .destructive) {
                    AppLog.tag("Viewer", "trash requested from viewer path=\(entry.path)")
                    FileActions.shared.trash([entry])
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("“\(entry.name)” 将移到回收站，可在那里恢复。")
            }
    }
}

extension View {
    func viewerActions(for entry: FileEntry) -> some View {
        modifier(ViewerActionsModifier(entry: entry))
    }
}
