import CoreLocation
import Foundation
import ZonexploCore

/// The posted-limit half of the monitor.
///
/// Split out because DriveMonitor grew past the file limit, and this is the
/// natural seam: everything here is about the road the driver is on right now,
/// and nothing here knows what a zone is. The zone machinery in the main file
/// never reads a posted limit, and this never touches a session.
@MainActor
extension DriveMonitor {
    // MARK: - Posted speed limits

    /// How far the driver must move before the limit window is rebuilt.
    ///
    /// Much tighter than the geofence window, and it has to be: the window is
    /// only a few hundred metres wide because matching projects every candidate
    /// on every fix, so it goes stale in seconds at motorway speed.
    static let limitRefreshThreshold: Double = 500

    /// Radius of the limit window. Wide enough to survive until the next
    /// refresh, narrow enough that a city centre does not load every side
    /// street within a kilometre.
    static let limitWindowRadius: Double = 1_200

    func updateRoadLimit(fix: LocationFix) {
        guard settings.showSpeedLimit else {
            currentRoadLimit = nil
            limitMatcher.reset()
            limitMonitor.reset()
            return
        }

        if needsLimitRefresh(at: fix.coordinate) {
            refreshRoadLimits(around: fix.coordinate)
        }

        let match = limitMatcher.update(fix: fix, candidates: nearbyRoadLimits)
        currentRoadLimit = match

        // Inside a zone the coaching engine owns the voice. It is already
        // telling the driver what speed to hold, worked out from the same road
        // and aimed at a camera that is actually there; a second voice saying
        // something adjacent about the same stretch of tarmac is noise at the
        // one moment the driver most needs to hear one clear number.
        guard !isInZone else {
            _ = limitMonitor.update(fix: fix, limitKph: nil)
            return
        }

        guard let exceedance = limitMonitor.update(fix: fix, limitKph: match?.limitKph) else {
            return
        }
        guard settings.announceSpeedLimit else { return }

        speak(phrasebook.speedLimitExceeded(exceedance), urgent: false)
    }

    func needsLimitRefresh(at coordinate: Coordinate) -> Bool {
        guard let centre = lastLimitRefreshCentre else { return true }
        return centre.distance(to: coordinate) > Self.limitRefreshThreshold
    }

    func refreshRoadLimits(around coordinate: Coordinate) {
        // Claimed before the query starts, for the same reason the geofence
        // refresh does it: at 1 Hz, every fix arriving while a read is in
        // flight would launch another one.
        lastLimitRefreshCentre = coordinate

        limitRefreshTask?.cancel()
        limitRefreshTask = Task { [weak self] in
            guard let self else { return }
            let limits = (try? await store.roadLimits(
                near: coordinate,
                radiusMeters: Self.limitWindowRadius
            )) ?? []

            guard !Task.isCancelled else { return }
            self.nearbyRoadLimits = limits
            self.hasLoadedLimitWindow = true
        }
    }
}
