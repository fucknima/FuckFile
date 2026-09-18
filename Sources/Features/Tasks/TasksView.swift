import SwiftUI

struct TasksView: View {
    @ObservedObject private var manager = FileTaskManager.shared

    var body: some View {
        List {
            if manager.tasks.isEmpty {
                Text("还没有任务")
                    .foregroundColor(.secondary)
            }
            ForEach(manager.tasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(task.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(task.state.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if task.state == .running {
                        ProgressView(value: min(max(task.progress, 0), 1))
                    }
                    if let errorText = task.errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务")
        .toolbar {
            if !manager.tasks.isEmpty {
                Button("清除已完成") { manager.removeFinished() }
            }
        }
    }
}
