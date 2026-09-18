import SwiftUI

struct LogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "（日志为空）" : text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("运行日志")
        .task {
            text = await Task.detached { AppLog.tail() }.value
        }
    }
}
