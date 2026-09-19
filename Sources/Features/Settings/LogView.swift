import SwiftUI

struct LogView: View {
    @State private var text = ""
    @State private var isConfirmingClear = false

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "（日志为空）" : text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清除", role: .destructive) { isConfirmingClear = true }
                    .disabled(text.isEmpty)
            }
        }
        .alert("清除运行日志", isPresented: $isConfirmingClear) {
            Button("清除", role: .destructive) {
                AppLog.clear()
                text = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("日志文件将被清空，此操作不可恢复。")
        }
        .task {
            text = await Task.detached { AppLog.tail() }.value
        }
    }
}
