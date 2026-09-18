import SwiftUI

@main
struct FuckFileApp: App {
    init() {
        AppLog.info("==== FuckFile (Swift) launch ====")
        AppLog.info("documents=\(StorageEnvironment.documentsPath)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
