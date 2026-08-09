import CoreMotion
import Foundation
import Observation

/// Notices that the driver has started driving, so they do not have to.
///
/// The likeliest way this app fails in the field is not a bug: it is somebody
/// getting in the car and not pressing start. Everything downstream - the
/// geofences, the interpolated crossings, the safety floor - is worth nothing
/// if the app was idle for the drive.
///
/// Core Motion's automotive classification is the cheapest way to know. It is
/// derived from sensors iOS is already running for the pedometer, so it costs
/// no additional wake-ups and no GPS.
///
/// Deliberately one-way: it starts watching and never stops it. Stopping on
/// `stationary` would kill the session at every red light, and a confident
/// automotive reading is evidence the driver wants this on, while its absence
/// is not evidence they want it off.
@MainActor
@Observable
final class DrivingDetector {
    /// True once Core Motion has said "automotive" with at least medium
    /// confidence. Low confidence is excluded: it fires on a brisk walk.
    private(set) var isDriving = false

    private let activityManager = CMMotionActivityManager()
    private var isMonitoring = false

    /// Called when driving begins. Set by AppModel rather than observed, so the
    /// start is a single explicit call rather than a view reacting to a flag.
    var onDrivingStarted: (() -> Void)?

    static var isSupported: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start() {
        guard Self.isSupported, !isMonitoring else { return }
        isMonitoring = true

        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }

            // `automotive` alone is not enough. Core Motion reports it while a
            // phone sits on a passenger seat at a services, and the confidence
            // is what separates "in a car" from "might be in a car".
            let driving = activity.automotive && activity.confidence != .low
            guard driving, !self.isDriving else {
                self.isDriving = driving && self.isDriving
                return
            }

            self.isDriving = true
            self.onDrivingStarted?()
        }
    }

    func stop() {
        guard isMonitoring else { return }
        activityManager.stopActivityUpdates()
        isMonitoring = false
        isDriving = false
    }
}
