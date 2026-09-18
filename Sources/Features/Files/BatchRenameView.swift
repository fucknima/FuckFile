import SwiftUI

/// 批量重命名：规则表单 + 实时预览（冲突红色）+ 应用。
/// 自包含 NavigationStack，按 sheet 呈现使用。
struct BatchRenameView: View {
    let entries: [FileEntry]
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .replace
    @State private var find = ""
    @State private var replacement = ""
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var sequenceStart = 1
    @State private var sequenceDigits = 3
    @State private var errorMessage: String?

    init(entries: [FileEntry], onDone: @escaping () -> Void) {
        self.entries = entries
        self.onDone = onDone
    }

    private enum Mode: Int, CaseIterable, Identifiable {
        case replace
        case affix
        case sequence

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .replace: return "查找替换"
            case .affix: return "前后缀"
            case .sequence: return "序号"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("重命名方式") {
                    Picker("方式", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("参数") {
                    parameterFields
                }
                Section("预览") {
                    previewContent
                }
            }
            .navigationTitle("批量重命名（\(entries.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("应用") { apply() }
                        .disabled(!canApply)
                }
            }
            .alert("重命名失败", isPresented: errorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var parameterFields: some View {
        switch mode {
        case .replace:
            TextField("要查找的文字", text: $find)
            TextField("替换为（可留空）", text: $replacement)
        case .affix:
            TextField("前缀（可留空）", text: $prefix)
            TextField("后缀（可留空）", text: $suffix)
        case .sequence:
            TextField("序号前缀（可留空）", text: $prefix)
            TextField("起始编号", value: $sequenceStart, format: .number)
                .keyboardType(.numberPad)
            TextField("位数", value: $sequenceDigits, format: .number)
                .keyboardType(.numberPad)
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewContent: some View {
        if plan.isEmpty {
            Text("没有可重命名的项目。")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(plan.enumerated()), id: \.element.path) { _, item in
                HStack(spacing: 8) {
                    Text(item.oldName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text(item.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(color(for: item))
                }
            }
            Text(footerText)
                .font(.footnote)
                .foregroundColor(hasConflict ? .red : .secondary)
        }
    }

    private func color(for item: BatchRename.BatchRenameItem) -> Color {
        if item.conflict { return .red }
        return item.newName == item.oldName ? .secondary : .accentColor
    }

    // MARK: - Plan

    private var rule: BatchRename.Rule {
        switch mode {
        case .replace:
            return BatchRename.Rule(prefix: "", suffix: "", find: find, replace: replacement,
                                    useSequence: false, sequenceStart: 1, sequenceDigits: 3)
        case .affix:
            return BatchRename.Rule(prefix: prefix, suffix: suffix, find: "", replace: "",
                                    useSequence: false, sequenceStart: 1, sequenceDigits: 3)
        case .sequence:
            return BatchRename.Rule(prefix: prefix, suffix: "", find: "", replace: "",
                                    useSequence: true, sequenceStart: sequenceStart,
                                    sequenceDigits: sequenceDigits)
        }
    }

    private var plan: [BatchRename.BatchRenameItem] {
        BatchRename.plan(entries: entries, rule: rule)
    }

    private var hasConflict: Bool { plan.contains { $0.conflict } }
    private var hasChanges: Bool { plan.contains { $0.newName != $0.oldName } }
    private var canApply: Bool { !plan.isEmpty && !hasConflict && hasChanges }

    private var footerText: String {
        if hasConflict { return "存在冲突或无效名称，无法应用。" }
        if !hasChanges { return "没有项目需要重命名。" }
        return "共 \(plan.count) 项将重命名。"
    }

    // MARK: - Apply

    private func apply() {
        do {
            try BatchRename.apply(plan: plan)
            AppLog.tag("BatchRename", "apply OK count=\(plan.count)")
            onDone()
            dismiss()
        } catch {
            AppLog.tag("BatchRename", "apply FAIL error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented { errorMessage = nil }
            }
        )
    }
}
