import SwiftUI

@main
struct RamblrMobileApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecordingView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // Handle an Action Button / Shortcut launch.
                        Task { await model.performPendingAutoStartIfNeeded() }
                    }
                }
        }
    }
}
