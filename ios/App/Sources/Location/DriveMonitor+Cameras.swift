import Foundation
import ZonexploCore

/// The point-camera half of the drive loop.
///
/// Split out of DriveMonitor when that file passed its length limit. It is a
/// clean seam rather than an arbitrary cut: everything here is about a single
/// camera on the road ahead, and nothing in it touches the zone session, which
/// is the other half of what the monitor does.
extension DriveMonitor {
    func announceApproachingCameras(fix: LocationFix) {
        let approaches = approachMonitor.update(fix: fix, cameras: nearbyCameras)

        // The nearest thing ahead is what the banner shows, whether or not it
        // was announced: the announcement is rate limited and rearmed, and a
        // driver looking at the screen should still see what is coming.
        let visible = approaches
            .filter { shouldAnnounce($0.camera) }
            .min { $0.distanceMeters < $1.distanceMeters }
        if let visible { currentApproach = visible }
        if approaches.isEmpty { currentApproach = nil }

        for approach in approaches {
            announce(approach)
        }
    }

    func announce(_ approach: CameraApproach) {
        guard shouldAnnounce(approach.camera) else { return }
        guard let line = phrasebook.cameraApproach(approach) else { return }
        speak(line, urgent: approach.urgency == .imminent)
    }
}
