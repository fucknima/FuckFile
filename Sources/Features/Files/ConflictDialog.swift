import SwiftUI

/// 挂在浏览器上的统一弹窗：冲突选择 + 操作失败提示。
struct FileActionsDialogs: ViewModifier {
    @ObservedObject private var actions = FileActions.shared

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: { actions.conflictRequest != nil },
            set: { presented in
                if !presented { actions.conflictRequest = nil }
            }
        )
    }

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
            .confirmationDialog(conflictTitle,
                                isPresented: conflictPresented,
                                titleVisibility: .visible) {
                Button("替换") { actions.conflictRequest?.completion(.replace) }
                Button("保留两者") { actions.conflictRequest?.completion(.keepBoth) }
                Button("跳过", role: .cancel) { actions.conflictRequest?.completion(.skip) }
            } message: {
                Text("目标文件夹里已有同名项目；所选处理方式对本批全部同名项生效。")
            }
            .alert("操作失败", isPresented: errorPresented) {
                Button("好") { actions.errorMessage = nil }
            } message: {
                Text(actions.errorMessage ?? "")
            }
    }

    private var conflictTitle: String {
        guard let request = actions.conflictRequest else { return "目标已存在" }
        return "“\(request.name)” 已存在"
    }
}

extension View {
    func fileActionsDialogs() -> some View {
        modifier(FileActionsDialogs())
    }
}
