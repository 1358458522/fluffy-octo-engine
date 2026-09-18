import SwiftUI

@main
struct TTYBApp: App {
    @StateObject private var store = ConfigStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
