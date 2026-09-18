import SwiftUI
import UIKit

/// 文件信息页（阶段 3c 冻结接口）：分组展示名称/类型/大小/位置/时间/权限/所有者。
/// 长按任意一行可复制其文本；目录的「大小」显示为直接子项数量。
struct FileInfoView: View {
    let entry: FileEntry

    @State private var metadata: FileMetadata?
    @State private var didLoad = false

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        List {
            if let metadata = metadata {
                basicSection(metadata)
                locationSection(metadata)
                timeSection(metadata)
                ownershipSection(metadata)
            } else if didLoad {
                Section {
                    Text("无法读取文件信息")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("正在读取信息…")
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("文件信息")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Sections

    private func basicSection(_ metadata: FileMetadata) -> some View {
        Section("基本信息") {
            InfoRow(title: "名称", value: metadata.name)
            InfoRow(title: "类型", value: kindName(metadata))
            InfoRow(title: "大小", value: sizeText(metadata))
        }
    }

    private func locationSection(_ metadata: FileMetadata) -> some View {
        Section("位置") {
            InfoRow(title: "完整路径", value: metadata.path)
            if let target = metadata.linkTarget {
                InfoRow(title: "链接目标", value: target)
            }
        }
    }

    private func timeSection(_ metadata: FileMetadata) -> some View {
        Section("时间") {
            InfoRow(title: "创建时间", value: dateText(metadata.creationDate))
            InfoRow(title: "修改时间", value: dateText(metadata.modificationDate))
        }
    }

    private func ownershipSection(_ metadata: FileMetadata) -> some View {
        Section("权限与所有者") {
            InfoRow(title: "权限", value: metadata.modeText)
            InfoRow(title: "所有者", value: "\(metadata.uid):\(metadata.gid)")
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        let path = entry.path
        metadata = await Task.detached(priority: .userInitiated) {
            FileMetadataService.metadata(forPath: path)
        }.value
        didLoad = true
    }

    // MARK: - Formatting

    private func kindName(_ metadata: FileMetadata) -> String {
        if metadata.isDirectory { return "目录" }
        if metadata.isSymlink { return "符号链接" }
        let ext = (metadata.name as NSString).pathExtension
        return ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
    }

    private func sizeText(_ metadata: FileMetadata) -> String {
        if metadata.isDirectory {
            guard let count = metadata.itemCount else { return "未知" }
            return "\(count) 项"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: metadata.size),
                                         countStyle: .file)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date = date else { return "未知" }
        return FileInfoView.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Row

/// 一行「标题 + 值」，长按弹出复制菜单。
private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.footnote)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
    }
}
