import SwiftUI

struct RootView: View {
    @ObservedObject private var taskManager = FileTaskManager.shared
    @ObservedObject private var importer = ImportCoordinator.shared

    var body: some View {
        TabView {
            NavigationStack {
                FilesView(directory: StorageEnvironment.documentsPath, title: "文件")
            }
            .tabItem {
                Label("文件", systemImage: "folder")
            }

            if !taskManager.tasks.isEmpty {
                NavigationStack {
                    TasksView()
                }
                .tabItem {
                    Label("任务", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
        }
        .alert(item: $importer.outcome) { outcome in
            if outcome.imported > 0 {
                return Alert(title: Text("接收文件"),
                             message: Text(outcome.message),
                             primaryButton: .default(Text("前往查看")) {
                                 importer.revealImportedDirectory()
                             },
                             secondaryButton: .cancel(Text("好")))
            }
            return Alert(title: Text("接收文件"),
                         message: Text(outcome.message),
                         dismissButton: .cancel(Text("好")))
        }
    }
}
