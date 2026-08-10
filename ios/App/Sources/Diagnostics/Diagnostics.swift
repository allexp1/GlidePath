import Foundation
import Observation

/// What the app was doing, for a tester who says it did nothing.
///
/// The reports that arrive from a TestFlight round are all the same shape: "I
/// drove through a zone and it never said anything." That sentence is
/// compatible with a dozen different causes — the voice muted, Always never
/// granted, the country not downloaded, the zone rejected at harvest, the audio
/// session refused by another app — and no two of them are fixed the same way.
///
/// So this records the decisions rather than the data. Every place the app
/// chooses silence writes down why it chose it, and a tester can hand that
/// over instead of a description.
///
/// **Nothing here leaves the phone on its own.** There is no upload, no
/// timer, no background send. A report exists only when somebody taps share,
/// and it carries no coordinates — the whole product rests on that promise and
/// a debugging feature is not a reason to break it. Road and country names are
/// included because they are public facts about a road, not about a driver.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let category: Category
        let message: String
    }

    enum Category: String {
        case location = "Location"
        case zone = "Zone"
        case camera = "Camera"
        case voice = "Voice"
        case data = "Data"
        case app = "App"
    }

    /// Bounded, because a long drive would otherwise fill memory with its own
    /// history. Four hundred entries is roughly the last hour of an active
    /// drive, which is far more than any report needs.
    private static let limit = 400

    private(set) var entries: [Entry] = []

    private init() {}

    func record(_ category: Category, _ message: String) {
        entries.append(Entry(at: Date(), category: category, message: message))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    func clear() { entries.removeAll() }

    /// The shareable report: what the app is, what it was allowed to do, what
    /// it holds, and what it last decided.
    func report(_ snapshot: [String: String]) -> String {
        var lines: [String] = []
        lines.append("Zonexplo diagnostic report")
        lines.append(Self.stamp.string(from: Date()))
        lines.append("")
        lines.append("No location coordinates are included in this file.")
        lines.append("")

        lines.append("— State —")
        for key in snapshot.keys.sorted() {
            let label = key.padding(toLength: max(26, key.count), withPad: " ", startingAt: 0)
            lines.append("\(label) \(snapshot[key] ?? "")")
        }

        lines.append("")
        lines.append("— Recent decisions (\(entries.count)) —")
        if entries.isEmpty {
            lines.append("(nothing recorded — the app has not been watching the road this session)")
        } else {
            for entry in entries {
                let category = entry.category.rawValue
                    .padding(toLength: 8, withPad: " ", startingAt: 0)
                lines.append("\(Self.clock.string(from: entry.at))  \(category)  \(entry.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
