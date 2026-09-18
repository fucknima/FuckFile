import SwiftUI

struct RootView: View {
    @ObservedObject private var taskManager = FileTaskManager.shared

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
    }
}
