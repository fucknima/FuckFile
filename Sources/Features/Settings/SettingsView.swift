import SwiftUI

struct SettingsView: View {
    @State private var storageSummary = ""

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
                NavigationLink {
                    StorageAnalysisView()
                } label: {
                    LabeledContent("存储空间",
                                   value: storageSummary.isEmpty ? "正在计算…" : storageSummary)
                }
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
                NavigationLink("文件关联") {
                    FileAssociationsView()
                }
            }
            Section {
                Text("Swift 重写进行中：当前为阶段 1（App 骨架 / 存储环境 / 日志 / 任务模型）。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            storageSummary = await Task.detached { Self.deviceSummary() }.value
        }
    }

    private static func deviceSummary() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage else { return "" }
        let used = max(0, Int64(total) - Int64(available))
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "已用 \(usedText) / 共 \(totalText)"
    }
}
