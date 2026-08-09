import SwiftUI

@main
struct ZonexploApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.cyan)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // The app can be relaunched into the background by a geofence
                // while the driver is already inside a monitored region.
                // Re-asserting state on every activation is what stops a
                // relaunch mid-zone from sitting there doing nothing.
                if model.settings.hasSeenOnboarding {
                    model.startMonitoring()
                }
            default:
                // Deliberately no teardown. Background monitoring is the whole
                // product: an app that stops watching when you put the phone
                // down is an app that never warns you about anything.
                break
            }
        }
    }
}
