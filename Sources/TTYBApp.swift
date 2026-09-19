import SwiftUI

@main
struct TTYBApp: App {
    @StateObject private var store = ConfigStore()

    init() {
        // 最早时机挂上崩溃捕获（信号 + 未捕获异常），真机闪退才有凭据可查
        Diag.install()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
