import SwiftUI

/// 挂在浏览器上的统一弹窗：冲突选择 + 操作失败提示。
/// 冲突选择用 UIKit 锚定弹窗（跟随触发条目；SwiftUI confirmationDialog
/// 挂行上会被左滑/长按菜单的收起动画连带关闭）。
struct FileActionsDialogs: ViewModifier {
    @ObservedObject private var actions = FileActions.shared
    @State private var presentedRequestID: UUID?

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { actions.errorMessage != nil },
            set: { presented in
                if !presented { actions.errorMessage = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: actions.conflictRequest?.id) { _ in
                presentConflictIfNeeded()
            }
            .onAppear { presentConflictIfNeeded() }
            .alert("操作失败", isPresented: errorPresented) {
                Button("好") { actions.errorMessage = nil }
            } message: {
                Text(actions.errorMessage ?? "")
            }
    }

    private func presentConflictIfNeeded() {
        guard let request = actions.conflictRequest, request.id != presentedRequestID else {
            return
        }
        presentedRequestID = request.id
        let anchor = RowAnchors.view(for: request.sourcePath)
        ActionSheetPresenter.present(
            title: "“\(request.name)” 已存在",
            message: "目标文件夹里已有同名项目；所选处理方式对本批全部同名项生效。",
            actions: [
                ("替换", false, { request.completion(.replace) }),
                ("保留两者", false, { request.completion(.keepBoth) }),
                ("跳过", true, { request.completion(.skip) }),
            ],
            onCancel: { request.completion(.skip) },
            anchor: anchor)
    }
}

extension View {
    func fileActionsDialogs() -> some View {
        modifier(FileActionsDialogs())
    }
}
