import Foundation
import ZonexploCore

/// A very small PostgREST client.
///
/// Deliberately not the supabase-swift SDK. Zonexplo makes exactly four kinds
/// of request, all of them anonymous reads against views, and the whole surface
/// fits on two screens. A dependency here would be more code to audit than the
/// code it replaced, and this way the offline path has no third-party failure
/// modes at all.
struct SupabaseREST: Sendable {
    let baseURL: URL
    let anonKey: String
    let session: URLSession

    init(baseURL: URL, anonKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
    }

    static func fromAppConfig() throws -> SupabaseREST {
        SupabaseREST(baseURL: try AppConfig.supabaseURL, anonKey: try AppConfig.supabaseAnonKey)
    }

    enum SyncError: LocalizedError {
        case http(status: Int, body: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case let .http(status, body) where status == 401 || status == 403:
                return "Supabase rejected the anon key (HTTP \(status)). "
                    + "Check SUPABASE_ANON_KEY in Config.xcconfig. \(body)"
            case let .http(status, body):
                return "Supabase returned HTTP \(status). \(body)"
            case let .transport(message):
                return message
            }
        }
    }

    /// Page size. Large enough that a country is a handful of round trips,
    /// small enough that a dropped connection on a rural road does not throw
    /// away much work.
    static let pageSize = 1_000

    /// Fetches every row of a view, paging until a short page comes back.
    ///
    /// Ordering by `updated_at` then a unique column matters more than it looks:
    /// paging by offset over an unstable order silently skips and duplicates
    /// rows, and `updated_at` alone is not unique when a sync writes a thousand
    /// rows in one transaction.
    ///
    /// - Parameter uniqueColumn: the column that makes the sort total. Every
    ///   view has one but they are not all called `id` - `countries_public` is
    ///   keyed on `code` - and naming a column the view does not have earns a
    ///   PostgREST 400 rather than a silently different order.
    func fetchAll<T: Decodable & Sendable>(
        _ type: T.Type,
        from view: String,
        filters: [String: String] = [:],
        since: Date? = nil,
        uniqueColumn: String = "id"
    ) async throws -> [T] {
        var results: [T] = []
        var offset = 0

        while true {
            let page: [T] = try await fetchPage(
                type,
                from: view,
                filters: filters,
                since: since,
                uniqueColumn: uniqueColumn,
                offset: offset
            )
            results.append(contentsOf: page)
            offset += page.count

            if page.count < Self.pageSize { break }
        }

        return results
    }

    /// One page of a view, for callers that cannot afford to hold all of them.
    ///
    /// This exists for road limits and only for road limits. Every other view
    /// here is a few thousand rows and `fetchAll` is simpler; a country's speed
    /// limits are hundreds of thousands of rows each carrying a polyline, and
    /// holding the whole download in memory before writing any of it is how an
    /// app gets killed by the watchdog on a phone with other things open.
    ///
    /// Returning a page rather than taking a per-page closure is deliberate. The
    /// caller writing each page is main-actor work, and a callback would have to
    /// carry that isolation across this nonisolated boundary; letting the caller
    /// own the loop keeps every crossing to a plain `await` on a value type.
    ///
    /// A page shorter than `pageSize` is the last one.
    func fetchPage<T: Decodable & Sendable>(
        _ type: T.Type,
        from view: String,
        filters: [String: String] = [:],
        since: Date? = nil,
        uniqueColumn: String = "id",
        offset: Int
    ) async throws -> [T] {
        var query = filters
        query["select"] = "*"
        query["order"] = "updated_at.asc,\(uniqueColumn).asc"
        query["limit"] = String(Self.pageSize)
        query["offset"] = String(offset)

        if let since {
            // PostgREST wants the operator inline. Strictly greater than, so a
            // row is never fetched twice, and the cursor is only moved once a
            // page has been written.
            query["updated_at"] = "gt.\(Self.timestampFormatter.string(from: since))"
        }

        return try await get(view, query: query)
    }

    func get<T: Decodable & Sendable>(_ view: String, query: [String: String]) async throws -> [T] {
        var components = URLComponents(
            url: baseURL.appending(path: "rest/v1/\(view)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components?.url else {
            throw SyncError.transport("could not build a URL for \(view)")
        }

        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.http(status: http.statusCode, body: String(body.prefix(400)))
        }

        return try Self.decoder.decode([T].self, from: data)
    }

    // MARK: - Coding

    /// PostgreSQL emits timestamps with microsecond precision and a `+00:00`
    /// offset. `.iso8601` handles neither reliably, so parse both shapes and
    /// fall back rather than failing a whole download over a timestamp.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Postgres columns are snake_case and Swift properties are not.
        // Converting here beats a CodingKeys block on every wire type.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = timestampFormatter.date(from: raw) { return date }
            if let date = plainFormatter.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unrecognised timestamp: \(raw)"
                )
            )
        }
        return decoder
    }()

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Wire types

/// These mirror the `*_public` views. They are intentionally separate from the
/// engine's value types: the wire format is the server's to change, and the
/// engine's model is the app's.
struct CountryDTO: Decodable, Sendable {
    let code: String
    let name: String
    let datasetVersion: Int
    let minCompatibleVersion: Int
    let cameraCount: Int
    let zoneCount: Int
    let lastSyncedAt: Date?

    // Speed limits carry their own version line so a phone does not re-check
    // tens of megabytes because a camera moved. Optional so a build talking to
    // a project that has not applied the road-limit migration still decodes.
    let roadLimitVersion: Int?
    let roadLimitCount: Int?
    let roadLimitsSyncedAt: Date?
}

struct RoadLimitDTO: Decodable, Sendable {
    let id: String
    let countryCode: String
    let name: String?
    let roadRef: String?
    let limitKph: Double
    let forwardLimitKph: Double?
    let backwardLimitKph: Double?
    let verified: Bool
    let path: GeoJSONLineString?
    let updatedAt: Date

    /// The polyline as `[latitude, longitude]` pairs.
    ///
    /// GeoJSON is `[longitude, latitude]` and everything else in this codebase
    /// is the other way round, which is the first thing to check if a limit ever
    /// matches a road in the wrong hemisphere.
    var coordinates: [Coordinate] {
        guard let path else { return [] }
        return path.coordinates
            .filter { $0.count >= 2 }
            .map { Coordinate(latitude: $0[1], longitude: $0[0]) }
    }
}

struct CameraDTO: Decodable, Sendable {
    let id: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
    let type: String
    let directionDegrees: Double?
    let speedLimitKph: Double?
    let zoneId: String?
    let verified: Bool
    let updatedAt: Date
}

struct RestStopDTO: Decodable, Sendable {
    let id: String
    let countryCode: String
    let zoneId: String?
    let name: String?
    let latitude: Double
    let longitude: Double
    let kind: String
    let distanceAlongMeters: Double?
    let updatedAt: Date
}

struct ZoneDTO: Decodable, Sendable {
    let id: String
    let countryCode: String
    let name: String?
    let roadRef: String?
    let entryLatitude: Double
    let entryLongitude: Double
    let exitLatitude: Double
    let exitLongitude: Double
    let distanceMeters: Double
    let speedLimitKph: Double
    let minimumSpeedKph: Double?
    let directionDegrees: Double?
    let verified: Bool
    let pathSegments: [GeoJSONLineString]?
    let updatedAt: Date

    /// Flattens the per-segment GeoJSON into the `[[lat, lon]]` array the local
    /// database stores.
    ///
    /// GeoJSON is `[longitude, latitude]` and everything else in this codebase
    /// is the other way round, which is the first thing to check if a zone ever
    /// behaves as though it is in the wrong hemisphere.
    var pathJSON: String? {
        guard let segments = pathSegments, !segments.isEmpty else { return nil }

        var coordinates: [[Double]] = []
        for segment in segments {
            for point in segment.coordinates where point.count >= 2 {
                let pair = [point[1], point[0]]
                // Consecutive segments share their junction node. A repeated
                // point is harmless for distance but pointless to store.
                if coordinates.last != pair {
                    coordinates.append(pair)
                }
            }
        }

        guard coordinates.count >= 2 else { return nil }
        guard let data = try? JSONEncoder().encode(coordinates) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct GeoJSONLineString: Decodable, Sendable {
    let type: String
    let coordinates: [[Double]]
}
