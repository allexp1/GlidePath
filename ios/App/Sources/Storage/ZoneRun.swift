import Foundation

/// One completed average-speed zone, as it happened.
///
/// Written by `LocalCameraStore.record` the moment a zone's exit line is
/// crossed, and read by nothing else in the app but the history screen. It
/// never leaves the phone: a list of zones with timestamps is a record of where
/// somebody drove and when, which is precisely the data this product exists
/// without.
struct ZoneRun: Identifiable, Equatable, Sendable {
    let id: Int64

    /// Nil for a zone OpenStreetMap never named, which is most of them.
    let zoneName: String?

    let enteredAt: Date
    let exitedAt: Date

    /// What the exit camera would have measured: total distance over total
    /// time, not an average of instantaneous readings.
    let averageKph: Double
    let limitKph: Double

    let passed: Bool
}
