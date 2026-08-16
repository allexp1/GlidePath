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
        if approaches.isEmpty {
            // Hand the camera being dropped to the "was it there?" window
            // before losing it. This is the only moment the driver knows the
            // answer: while a camera is ahead they are guessing, and thirty
            // seconds later they have stopped thinking about it.
            if let passed = currentApproach?.camera, shouldAnnounce(passed) {
                notePassed(passed, at: fix.timestamp)
            }
            currentApproach = nil
        }

        for approach in approaches {
            announce(approach)
        }
    }

    /// How long after passing a camera the driver is still asked about it.
    ///
    /// Short on purpose. Long enough to react to something that was not there,
    /// short enough that the chip never lingers into the next thing on the road
    /// - and short enough that it cannot be tapped about a camera the driver
    /// has already forgotten, which would make the report worth less than the
    /// silence it replaced.
    static let passedWindow: TimeInterval = 25

    func notePassed(_ camera: Camera, at timestamp: Date) {
        // Zone entry and exit markers are the section's own cameras and are
        // reported by reporting the section, not the post.
        guard !camera.type.isZoneMarker else { return }
        recentlyPassed = camera
        passedAt = timestamp
        Diagnostics.shared.record(.camera, "passed \(camera.type) - offering the 'not there' chip")
    }

    /// The camera just driven past, while it is still worth asking about.
    var passedCamera: Camera? {
        guard let recentlyPassed, let passedAt else { return nil }
        guard Date().timeIntervalSince(passedAt) < Self.passedWindow else { return nil }
        return recentlyPassed
    }

    func clearPassed() {
        recentlyPassed = nil
        passedAt = nil
    }

    func announce(_ approach: CameraApproach) {
        guard shouldAnnounce(approach.camera) else { return }
        guard let line = phrasebook.cameraApproach(approach) else { return }
        speak(line, urgent: approach.urgency == .imminent)
    }
}
