import SwiftUI

@main
struct CFPilotApp: App {
    @StateObject private var store = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Ink.seal)
                .preferredColorScheme(nil)
        }
    }
}
