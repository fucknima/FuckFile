import SwiftUI

/// 与旧版 FFAppDelegate 一致：分享唤醒 URL 必须在 UI 出现之前就进入导入协调器，
/// 否则回环监听要等第一帧之后才 bind，分享扩展在宿主退场宽限期内来不及传完
/// （大文件表现为传到 ~88% 断流）。SwiftUI 的 .onOpenURL 只覆盖热启动。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let url = launchOptions?[.url] as? URL {
            AppLog.tag("Lifecycle", "launch URL=\(url.absoluteString)")
            ImportCoordinator.shared.handle(url)
        }
        return true
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        AppLog.tag("Lifecycle", "open URL=\(url.absoluteString)")
        ImportCoordinator.shared.handle(url)
        return true
    }
}

@main
struct FuckFileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppLog.info("==== FuckFile (Swift) launch ====")
        AppLog.info("documents=\(StorageEnvironment.documentsPath)")
        purgeExpiredTrash()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    ImportCoordinator.shared.handle(url)
                }
        }
        .onChange(of: scenePhase) { phase in
            AppLog.tag("Lifecycle", "scenePhase=\(Self.describe(phase))")
            if phase == .active {
                ImportCoordinator.shared.drainInbox()
            }
        }
    }

    private static func describe(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        default: return "unknown"
        }
    }

    /// 与旧版一致：启动时按保留天数（默认 30，0 = 关闭）后台清理回收站。
    private func purgeExpiredTrash() {
        let defaults = UserDefaults.standard
        let days = defaults.object(forKey: "FFTrashRetentionDays") == nil
            ? 30 : defaults.integer(forKey: "FFTrashRetentionDays")
        guard days > 0 else { return }
        Task.detached {
            if let purged = try? TrashService.purgeExpired(olderThanDays: days), purged > 0 {
                AppLog.tag("Trash", "launch auto-clean purged=\(purged) retention=\(days)d")
            }
        }
    }
}
