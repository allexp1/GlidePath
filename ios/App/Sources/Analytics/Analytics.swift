import Foundation
import PostHog

/// Product analytics, and the boundary that keeps them out of the one thing
/// this app must never send anywhere.
///
/// Everything else in Zonexplo is built so that where somebody drives stays on
/// their phone. Analytics is the one component that talks to a third party, so
/// the rules live here rather than at each call site, where they would be one
/// forgotten parameter away from being broken:
///
/// - **No coordinates, ever.** No latitude, no longitude, no camera id, no zone
///   id, no road name. A zone id plus a timestamp is a location, and a sequence
///   of them is a journey. Events describe *what kind of thing* happened, never
///   where.
/// - **No identify().** There are no accounts, so there is no user to name. The
///   SDK's anonymous id is the whole identity, and calling `identify` with
///   anything derived from the device would turn an anonymous counter into a
///   tracked person.
/// - **Off is honoured everywhere.** `Settings > Share anonymous usage` gates
///   the SDK itself rather than the call sites, so nothing leaks from a path
///   that forgot to check.
/// Main-actor isolated rather than locked: every call site is already there -
/// the app model, the sync service, the views - and a mutex around a flag only
/// ever touched from one actor is ceremony.
@MainActor
enum Analytics {
    /// Set from Config.xcconfig so a fork ships without phoning anywhere.
    private static let host = "https://us.i.posthog.com"

    private(set) static var isStarted = false

    static func start(enabled: Bool) {
        guard enabled, !isStarted, let key = apiKey else { return }

        let config = PostHogConfig(apiKey: key, host: host)

        // How much the app is used, and nothing else.
        //
        // Launches and screen views answer "is anyone driving with this", which
        // is the question worth asking. They carry no position and no content.
        config.captureScreenViews = true
        config.captureApplicationLifecycleEvents = true

        // Individual taps are off. They would record the sequence of controls
        // somebody touched, which is a behavioural trace rather than a usage
        // count, and screen views already answer which screens earn their keep.
        config.captureElementInteractions = false

        // Session replay is off and must stay off.
        //
        // The home screen is a live map centred on the driver. A replay of it
        // is a recording of where they went, whatever the feature is called,
        // and masking does not help because the position is the map itself
        // rather than anything drawn on top. This app's headline promise is
        // that location never leaves the phone; replay would make that false
        // in the most literal way available.
        config.sessionReplay = false

        PostHogSDK.shared.setup(config)
        isStarted = true
    }

    /// Stops collection and throws away the anonymous id, so turning the
    /// setting off is not merely "stop sending" - the next opt-in is a new
    /// anonymous person rather than a resumed one.
    static func stop() {
        guard isStarted else { return }
        PostHogSDK.shared.reset()
        PostHogSDK.shared.close()
        isStarted = false
    }

    static func capture(_ event: Event, _ properties: [String: Any] = [:]) {
        guard isStarted else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    /// The events worth having, named for what they say about the product
    /// rather than for the code that fires them.
    enum Event: String {
        /// Did the driver ever get past the permission wall? Everything else is
        /// meaningless for someone who did not.
        case onboardingFinished = "onboarding_finished"
        case locationPermissionResolved = "location_permission_resolved"

        /// Watching is the app doing its job. Sessions that never start are the
        /// single most important failure to be able to see.
        case watchStarted = "watch_started"
        case watchStopped = "watch_stopped"

        /// Which countries are worth harvesting next. The code is the same
        /// fact the download list already shows on screen.
        case countryDownloaded = "country_downloaded"
        case roadLimitsDownloaded = "road_limits_downloaded"

        case cameraReported = "camera_reported"
        case analyticsOptOut = "analytics_opt_out"

        // Deliberately absent: anything fired per camera or per zone. A count
        // of camera announcements is harmless once and a movement trace at a
        // thousand timestamps, and the difference between those is only volume.
        // "How much is the app used" does not need them.
    }

    private static var apiKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String,
              !value.isEmpty,
              !value.hasPrefix("YOUR-") else { return nil }
        return value
    }
}
