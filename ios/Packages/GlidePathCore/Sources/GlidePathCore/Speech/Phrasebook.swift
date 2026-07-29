import Foundation

public enum DistanceUnits: String, Sendable, Codable, CaseIterable {
    case metric
    case imperial
}

/// Turns engine state into the exact words the driver hears.
///
/// Kept in the core package on purpose. Phrasing is product logic - how blunt to
/// be, when to admit defeat, whether to say a number at all - and it belongs
/// under test rather than buried in an audio class.
///
/// House rules, learned from the fact that the driver is doing something else:
/// lead with the instruction, never the explanation; one number per sentence;
/// no filler; and never say something that will be false in four seconds.
public struct Phrasebook: Sendable {
    public let units: DistanceUnits

    public init(units: DistanceUnits = .metric) {
        self.units = units
    }

    // MARK: - Zone lifecycle

    public func zoneEntry(_ zone: Zone) -> String {
        let length = distancePhrase(zone.distanceMeters)
        return "Average speed zone. \(length) at \(speedPhrase(zone.speedLimitKph))."
    }

    public func zoneExit(_ outcome: ZoneOutcome) -> String {
        let average = speedPhrase(outcome.averageKph.rounded())
        if outcome.passed {
            return "Zone clear. You averaged \(average)."
        }
        let over = (outcome.averageKph - outcome.limitKph).rounded()
        return "Zone ended. You averaged \(average), about \(Int(over)) over."
    }

    public func zoneAbandoned(_ reason: AbandonReason) -> String? {
        switch reason {
        case .leftTheRoad:
            return "Zone cancelled, you have left the road."
        case .lostSignal:
            return "Lost signal, zone tracking stopped."
        case .cancelled:
            // The user did this deliberately. They do not need telling.
            return nil
        }
    }

    // MARK: - Coaching

    /// The line to speak for a coaching update, or nil when the right thing to
    /// do is stay quiet.
    public func coaching(_ advice: CoachingAdvice) -> String? {
        guard !advice.isSuppressed else { return nil }

        switch advice.tier {
        case .normal:
            guard let target = advice.targetSpeedKph else { return nil }
            return "You are fine. Hold \(speedPhrase(target))."

        case .tight:
            guard let target = advice.targetSpeedKph else { return nil }
            let remaining = distancePhrase(advice.distanceRemainingMeters)
            return "Hold \(speedPhrase(target)) for the next \(remaining)."

        case .impossible:
            return impossiblePhrase(advice)
        }
    }

    private func impossiblePhrase(_ advice: CoachingAdvice) -> String {
        switch advice.recovery {
        case let .pause(seconds, stop, distanceToStop)?:
            let place = stop.name ?? placeNoun(for: stop.kind)
            let away = distancePhrase(distanceToStop)
            let pause = durationPhrase(seconds)
            return "You cannot make this one by driving. "
                + "There is a \(place) in \(away). A \(pause) stop puts you back under."

        case .unrecoverable?:
            let over = max(advice.allowance.projectedFinalAverageKph - advice.speedLimitKph, 0)
            let overText = over >= 1 ? " You will be about \(Int(over.rounded())) over." : ""
            return "This zone is already lost, and there is nowhere to stop before the exit camera."
                + overText
                + " Drive normally."

        case nil:
            return "Slow to \(speedPhrase(advice.safetyFloorKph)). This zone may already be lost."
        }
    }

    // MARK: - Point cameras

    public func cameraApproach(_ approach: CameraApproach) -> String? {
        let noun = cameraNoun(for: approach.camera.type)

        switch approach.urgency {
        case .advance:
            let away = distancePhrase(approach.distanceMeters)
            if approach.camera.type.isAdvisory {
                return "Mobile camera spot in \(away)."
            }
            if let limit = approach.camera.speedLimitKph {
                return "\(noun) in \(away), \(speedPhrase(limit))."
            }
            return "\(noun) in \(away)."

        case .imminent:
            if let over = approach.overLimitByKph, over >= 3 {
                return "\(noun) ahead. Ease off, you are \(Int(over.rounded())) over."
            }
            switch approach.camera.type {
            case .redLight:
                return "Red light camera ahead."
            case .seatbeltPhone:
                return "Seat belt and phone camera ahead."
            case .busLane:
                return "Bus lane camera ahead."
            default:
                return "\(noun) ahead."
            }
        }
    }

    // MARK: - Vocabulary

    private func cameraNoun(for type: CameraType) -> String {
        switch type {
        case .fixed: return "Speed camera"
        case .redLight: return "Red light camera"
        case .combined: return "Speed and red light camera"
        case .seatbeltPhone: return "Seat belt and phone camera"
        case .busLane: return "Bus lane camera"
        case .mobileHotspot: return "Mobile camera spot"
        case .zoneEntry: return "Zone entry camera"
        case .zoneExit: return "Zone exit camera"
        }
    }

    private func placeNoun(for kind: RestStopKind) -> String {
        switch kind {
        case .restArea: return "rest area"
        case .fuelStation: return "petrol station"
        case .services: return "services"
        case .parking: return "parking area"
        case .viewpoint: return "viewpoint"
        }
    }

    // MARK: - Numbers

    /// Speeds are spoken bare. A driver hearing "hold eighty" while looking at a
    /// speedometer in the same units does not need the unit said out loud every
    /// few seconds, and the repetition is what makes voice guidance grating.
    public func speedPhrase(_ kph: Double) -> String {
        switch units {
        case .metric:
            return "\(Int(kph.rounded()))"
        case .imperial:
            return "\(Int((kph * 0.621371).rounded()))"
        }
    }

    public func distancePhrase(_ meters: Double) -> String {
        switch units {
        case .metric:
            if meters < 1000 {
                let rounded = (meters / 100).rounded() * 100
                return "\(max(Int(rounded), 100)) metres"
            }
            return decimalPhrase(meters / 1000, singular: "kilometre", plural: "kilometres")

        case .imperial:
            let miles = meters / 1609.344
            if miles < 0.5 {
                let yards = (meters * 1.09361 / 50).rounded() * 50
                return "\(Int(yards)) yards"
            }
            return decimalPhrase(miles, singular: "mile", plural: "miles")
        }
    }

    /// One decimal place, but only when it carries information. "4 kilometres"
    /// is easier to hear at speed than "4.0 kilometres".
    private func decimalPhrase(_ value: Double, singular: String, plural: String) -> String {
        let rounded = value < 10 ? (value * 10).rounded() / 10 : value.rounded()

        if rounded == rounded.rounded(.down) {
            let whole = Int(rounded)
            return "\(whole) \(whole == 1 ? singular : plural)"
        }
        return "\(String(format: "%.1f", rounded)) \(plural)"
    }

    public func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            // To the nearest ten seconds. Nobody can act on "37 seconds", and
            // the floor of ten stops a trivial pause sounding like nothing.
            let rounded = max(Int((Double(total) / 10).rounded()) * 10, 10)
            return "\(rounded) second"
        }
        let minutes = Int((Double(total) / 60).rounded())
        return minutes == 1 ? "one minute" : "\(minutes) minute"
    }
}
