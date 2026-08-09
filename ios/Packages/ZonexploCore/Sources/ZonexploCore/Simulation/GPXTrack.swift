import Foundation

/// A GPX track read into location fixes.
///
/// Hand-rolled rather than XMLParser-based: GPX track points are a fixed,
/// boring shape, and a string scan keeps the core package free of
/// FoundationXML, which is not uniformly available across platforms. It reads
/// `<trkpt lat= lon=>` with optional `<time>` and `<speed>` children and
/// ignores everything else in the file.
public struct GPXTrack: Sendable {
    public let fixes: [LocationFix]

    public enum ParseError: Error, Equatable {
        case noTrackPoints
        case missingTimestamps
    }

    /// - Parameters:
    ///   - horizontalAccuracy: accuracy stamped onto every fix. GPX carries no
    ///     accuracy, and tests want to control whether fixes are usable.
    ///   - startDate: used when the file has no `<time>` elements, with fixes
    ///     spaced one second apart.
    public init(
        gpx: String,
        horizontalAccuracy: Double = 5,
        startDate: Date? = nil
    ) throws {
        let points = GPXTrack.scanTrackPoints(in: gpx)
        guard !points.isEmpty else { throw ParseError.noTrackPoints }

        let timestamps: [Date]
        if points.allSatisfy({ $0.time != nil }) {
            timestamps = points.map { $0.time ?? Date(timeIntervalSince1970: 0) }
        } else if let start = startDate {
            timestamps = points.indices.map { start.addingTimeInterval(Double($0)) }
        } else {
            throw ParseError.missingTimestamps
        }

        var built: [LocationFix] = []
        built.reserveCapacity(points.count)

        for (index, point) in points.enumerated() {
            let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)

            // GPX rarely carries speed, so derive it from the previous point.
            // The first point has nothing to derive from and gets the second
            // point's speed once it is known.
            var speed = point.speed
            if speed == nil, index > 0 {
                let previous = points[index - 1]
                let previousCoordinate = Coordinate(latitude: previous.latitude, longitude: previous.longitude)
                let interval = timestamps[index].timeIntervalSince(timestamps[index - 1])
                if interval > 0 {
                    speed = previousCoordinate.distance(to: coordinate) / interval
                }
            }

            built.append(
                LocationFix(
                    coordinate: coordinate,
                    timestamp: timestamps[index],
                    speedMps: speed,
                    horizontalAccuracy: horizontalAccuracy,
                    courseDegrees: index > 0
                        ? Coordinate(latitude: points[index - 1].latitude, longitude: points[index - 1].longitude)
                            .bearing(to: coordinate)
                        : nil
                )
            )
        }

        if built.count > 1, built[0].speedMps == nil {
            let second = built[1]
            built[0] = LocationFix(
                coordinate: built[0].coordinate,
                timestamp: built[0].timestamp,
                speedMps: second.speedMps,
                horizontalAccuracy: horizontalAccuracy,
                courseDegrees: built[0].coordinate.bearing(to: second.coordinate)
            )
        }

        self.fixes = built
    }

    // MARK: - Scanning

    private struct RawPoint {
        let latitude: Double
        let longitude: Double
        let time: Date?
        let speed: Double?
    }

    // ISO8601DateFormatter is not marked Sendable, but these two are configured
    // once and only ever read afterwards, which is what nonisolated(unsafe)
    // asserts. Building a formatter per track point instead would allocate tens
    // of thousands of times on a long GPX file.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func scanTrackPoints(in gpx: String) -> [RawPoint] {
        var points: [RawPoint] = []
        var cursor = gpx.startIndex

        while let openTag = gpx.range(of: "<trkpt", range: cursor..<gpx.endIndex) {
            // The element runs to its own close tag, or to the next trkpt for
            // self-closing points.
            let searchStart = openTag.upperBound
            let closeTag = gpx.range(of: "</trkpt>", range: searchStart..<gpx.endIndex)
            let nextOpen = gpx.range(of: "<trkpt", range: searchStart..<gpx.endIndex)

            let elementEnd: String.Index
            if let closeTag, let nextOpen {
                elementEnd = min(closeTag.upperBound, nextOpen.lowerBound)
            } else if let closeTag {
                elementEnd = closeTag.upperBound
            } else if let nextOpen {
                elementEnd = nextOpen.lowerBound
            } else {
                elementEnd = gpx.endIndex
            }

            let chunk = String(gpx[openTag.lowerBound..<elementEnd])
            cursor = elementEnd

            guard let latitude = attribute("lat", in: chunk),
                  let longitude = attribute("lon", in: chunk) else { continue }

            points.append(
                RawPoint(
                    latitude: latitude,
                    longitude: longitude,
                    time: childText("time", in: chunk).flatMap(parseDate),
                    speed: childText("speed", in: chunk).flatMap(Double.init)
                )
            )
        }

        return points
    }

    private static func attribute(_ name: String, in element: String) -> Double? {
        for quote in ["\"", "'"] {
            let needle = "\(name)=\(quote)"
            guard let start = element.range(of: needle) else { continue }
            guard let end = element.range(of: quote, range: start.upperBound..<element.endIndex) else { continue }
            if let value = Double(element[start.upperBound..<end.lowerBound]) { return value }
        }
        return nil
    }

    private static func childText(_ name: String, in chunk: String) -> String? {
        guard let start = chunk.range(of: "<\(name)>"),
              let end = chunk.range(of: "</\(name)>", range: start.upperBound..<chunk.endIndex) else {
            return nil
        }
        return String(chunk[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(_ raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? isoFormatterNoFraction.date(from: raw)
    }
}
