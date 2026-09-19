import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case files
        case tasks
        case settings
    }

    @ObservedObject private var taskManager = FileTaskManager.shared
    @ObservedObject private var importer = ImportCoordinator.shared
    @State private var selection: Tab = .files
    @State private var filesPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $filesPath) {
                FilesView(directory: StorageEnvironment.documentsPath, title: "文件")
            }
            .tabItem {
                Label("文件", systemImage: "folder")
            }
            .tag(Tab.files)

            if !taskManager.tasks.isEmpty {
                NavigationStack {
                    TasksView()
                }
                .tabItem {
                    Label("任务", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(Tab.tasks)
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .alert(item: $importer.outcome) { outcome in
            if outcome.imported > 0 {
                return Alert(title: Text("接收文件"),
                             message: Text(outcome.message),
                             primaryButton: .default(Text("前往查看")) {
                                 revealImportedDirectory()
                             },
                             secondaryButton: .cancel(Text("好")))
            }
            return Alert(title: Text("接收文件"),
                         message: Text(outcome.message),
                         dismissButton: .cancel(Text("好")))
        }
    }

    /// 「前往查看」：切回文件标签并清空导航栈，让根浏览器跳到导入目录。
    private func revealImportedDirectory() {
        selection = .files
        filesPath = NavigationPath()
        importer.revealImportedDirectory()
    }
}
