import SwiftUI

@main
struct ZonexploApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before any UI, because autocapture cannot record a screen that has
        // already appeared. Reads the persisted preference directly rather than
        // through AppModel: the opt-out has to be honoured on the very first
        // frame, and AppModel is created alongside this.
        let enabled = UserDefaults.standard.object(forKey: "settings.analyticsEnabled") as? Bool ?? true
        MainActor.assumeIsolated { Analytics.start(enabled: enabled) }
    }

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
