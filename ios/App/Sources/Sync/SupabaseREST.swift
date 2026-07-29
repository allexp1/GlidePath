import Foundation
import GlidePathCore

/// A very small PostgREST client.
///
/// Deliberately not the supabase-swift SDK. GlidePath makes exactly four kinds
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
                return "Supabase rejected the anon key (HTTP \(status)). Check SUPABASE_ANON_KEY in Config.xcconfig. \(body)"
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
    /// Ordering by `updated_at` then `id` matters more than it looks: paging by
    /// offset over an unstable order silently skips and duplicates rows, and
    /// `updated_at` alone is not unique when a sync writes a thousand rows in
    /// one transaction.
    func fetchAll<T: Decodable & Sendable>(
        _ type: T.Type,
        from view: String,
        filters: [String: String] = [:],
        since: Date? = nil
    ) async throws -> [T] {
        var results: [T] = []
        var offset = 0

        while true {
            var query = filters
            query["select"] = "*"
            query["order"] = "updated_at.asc,id.asc"
            query["limit"] = String(Self.pageSize)
            query["offset"] = String(offset)

            if let since {
                // PostgREST wants the operator inline. Strictly greater than,
                // so a row is never fetched twice, and the cursor is only moved
                // once a page has been written.
                query["updated_at"] = "gt.\(Self.timestampFormatter.string(from: since))"
            }

            let page: [T] = try await get(view, query: query)
            results.append(contentsOf: page)

            if page.count < Self.pageSize { break }
            offset += Self.pageSize
        }

        return results
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
    let dataset_version: Int
    let min_compatible_version: Int
    let camera_count: Int
    let zone_count: Int
    let last_synced_at: Date?
}

struct CameraDTO: Decodable, Sendable {
    let id: String
    let country_code: String
    let latitude: Double
    let longitude: Double
    let type: String
    let direction_degrees: Double?
    let speed_limit_kph: Double?
    let zone_id: String?
    let verified: Bool
    let updated_at: Date
}

struct RestStopDTO: Decodable, Sendable {
    let id: String
    let country_code: String
    let zone_id: String?
    let name: String?
    let latitude: Double
    let longitude: Double
    let kind: String
    let distance_along_meters: Double?
    let updated_at: Date
}

struct ZoneDTO: Decodable, Sendable {
    let id: String
    let country_code: String
    let name: String?
    let road_ref: String?
    let entry_latitude: Double
    let entry_longitude: Double
    let exit_latitude: Double
    let exit_longitude: Double
    let distance_meters: Double
    let speed_limit_kph: Double
    let minimum_speed_kph: Double?
    let direction_degrees: Double?
    let verified: Bool
    let path_segments: [GeoJSONLineString]?
    let updated_at: Date

    /// Flattens the per-segment GeoJSON into the `[[lat, lon]]` array the local
    /// database stores.
    ///
    /// GeoJSON is `[longitude, latitude]` and everything else in this codebase
    /// is the other way round, which is the first thing to check if a zone ever
    /// behaves as though it is in the wrong hemisphere.
    var pathJSON: String? {
        guard let segments = path_segments, !segments.isEmpty else { return nil }

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
