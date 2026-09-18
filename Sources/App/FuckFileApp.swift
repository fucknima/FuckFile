import SwiftUI

@main
struct FuckFileApp: App {
    init() {
        AppLog.info("==== FuckFile (Swift) launch ====")
        AppLog.info("documents=\(StorageEnvironment.documentsPath)")
        purgeExpiredTrash()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
