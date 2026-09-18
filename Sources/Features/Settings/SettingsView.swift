import SwiftUI

struct SettingsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        List {
            Section("关于") {
                LabeledContent("名称", value: "FuckFile")
                LabeledContent("版本", value: "\(version) (\(build))")
            }
            Section("存储") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Documents")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(StorageEnvironment.documentsPath)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section("诊断") {
                NavigationLink("运行日志") {
                    LogView()
                }
            }
            Section("数据") {
                NavigationLink("回收站") {
                    TrashView()
                }
            }
            Section {
                Text("Swift 重写进行中：当前为阶段 1（App 骨架 / 存储环境 / 日志 / 任务模型）。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
    }
}
