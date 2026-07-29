import Foundation
import GRDB
import GlidePathCore

/// Reads camera data out of the local database and hands the engine the value
/// types it expects.
///
/// Nearby lookups are a bounding box in SQL followed by an exact great-circle
/// filter in Swift. A degree of latitude is a fixed 111 km; a degree of
/// longitude shrinks with latitude, so the box widens by 1/cos(latitude). Near
/// the poles that blows up, hence the clamp, though a speed camera at 89 degrees
/// north would be a surprise.
struct LocalCameraStore: CameraDataStore {
    let database: LocalDatabase

    // MARK: - CameraDataStore

    func zones(near coordinate: Coordinate, radiusMeters: Double, limit: Int) async throws -> [Zone] {
        let box = BoundingBox(around: coordinate, radiusMeters: radiusMeters)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM zone
                    WHERE entry_latitude BETWEEN ? AND ?
                      AND entry_longitude BETWEEN ? AND ?
                      AND verified = 1
                    """,
                arguments: [box.minLatitude, box.maxLatitude, box.minLongitude, box.maxLongitude]
            )
        }

        let stops = try await restStops(forZonesIn: rows.compactMap { $0["id"] as String? })

        return rows
            .compactMap { row -> (zone: Zone, distance: Double)? in
                guard let zone = Zone(row: row, restStops: stops[row["id"] as String? ?? ""] ?? [])
                else { return nil }
                let distance = coordinate.distance(to: zone.entry)
                guard distance <= radiusMeters else { return nil }
                return (zone, distance)
            }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map(\.zone)
    }

    func cameras(near coordinate: Coordinate, radiusMeters: Double, limit: Int) async throws -> [Camera] {
        let box = BoundingBox(around: coordinate, radiusMeters: radiusMeters)

        let rows = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM camera
                    WHERE latitude BETWEEN ? AND ?
                      AND longitude BETWEEN ? AND ?
                    """,
                arguments: [box.minLatitude, box.maxLatitude, box.minLongitude, box.maxLongitude]
            )
        }

        return rows
            .compactMap { row -> (camera: Camera, distance: Double)? in
                guard let camera = Camera(row: row) else { return nil }
                let distance = coordinate.distance(to: camera.coordinate)
                guard distance <= radiusMeters else { return nil }
                return (camera, distance)
            }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map(\.camera)
    }

    func zone(id: String) async throws -> Zone? {
        let row = try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM zone WHERE id = ?", arguments: [id])
        }
        guard let row else { return nil }
        let stops = try await restStops(forZonesIn: [id])
        return Zone(row: row, restStops: stops[id] ?? [])
    }

    // MARK: - History

    func record(_ outcome: ZoneOutcome, zoneName: String?) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO zone_run
                        (zone_id, zone_name, entered_at, exited_at, average_kph, limit_kph, passed)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    outcome.zoneID,
                    zoneName,
                    outcome.enteredAt,
                    outcome.exitedAt,
                    outcome.averageKph,
                    outcome.limitKph,
                    outcome.passed
                ]
            )
        }
    }

    // MARK: - Helpers

    private func restStops(forZonesIn zoneIDs: [String]) async throws -> [String: [RestStop]] {
        guard !zoneIDs.isEmpty else { return [:] }

        let placeholders = databaseQuestionMarks(count: zoneIDs.count)
        let rows = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM rest_stop WHERE zone_id IN (\(placeholders))",
                arguments: StatementArguments(zoneIDs)
            )
        }

        var grouped: [String: [RestStop]] = [:]
        for row in rows {
            guard let stop = RestStop(row: row), let zoneID = stop.zoneID else { continue }
            grouped[zoneID, default: []].append(stop)
        }
        return grouped
    }

    private func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

/// A latitude and longitude window that certainly contains everything within
/// `radiusMeters`, and some things that are not.
struct BoundingBox {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(around coordinate: Coordinate, radiusMeters: Double) {
        let latitudeDelta = radiusMeters / 111_320

        // cos() approaches zero at the poles, which would make the box infinite.
        let latitudeRadians = coordinate.latitude * .pi / 180
        let shrink = max(cos(latitudeRadians), 0.01)
        let longitudeDelta = radiusMeters / (111_320 * shrink)

        minLatitude = coordinate.latitude - latitudeDelta
        maxLatitude = coordinate.latitude + latitudeDelta
        minLongitude = coordinate.longitude - longitudeDelta
        maxLongitude = coordinate.longitude + longitudeDelta
    }
}

// MARK: - Row decoding

extension Camera {
    init?(row: Row) {
        guard let id = row["id"] as String?,
              let countryCode = row["country_code"] as String?,
              let latitude = row["latitude"] as Double?,
              let longitude = row["longitude"] as Double?,
              let rawType = row["type"] as String?,
              let type = CameraType(rawValue: rawType) else {
            return nil
        }

        self.init(
            id: id,
            countryCode: countryCode,
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            type: type,
            directionDegrees: row["direction_degrees"] as Double?,
            speedLimitKph: row["speed_limit_kph"] as Double?,
            zoneID: row["zone_id"] as String?,
            verified: row["verified"] as Bool? ?? true,
            osmID: nil,
            updatedAt: row["updated_at"] as Date? ?? Date(timeIntervalSince1970: 0)
        )
    }
}

extension RestStop {
    init?(row: Row) {
        guard let id = row["id"] as String?,
              let latitude = row["latitude"] as Double?,
              let longitude = row["longitude"] as Double?,
              let rawKind = row["kind"] as String?,
              let kind = RestStopKind(rawValue: rawKind) else {
            return nil
        }

        self.init(
            id: id,
            name: row["name"] as String?,
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            kind: kind,
            zoneID: row["zone_id"] as String?,
            distanceAlongMeters: row["distance_along_meters"] as Double?
        )
    }
}

extension Zone {
    init?(row: Row, restStops: [RestStop]) {
        guard let id = row["id"] as String?,
              let countryCode = row["country_code"] as String?,
              let entryLatitude = row["entry_latitude"] as Double?,
              let entryLongitude = row["entry_longitude"] as Double?,
              let exitLatitude = row["exit_latitude"] as Double?,
              let exitLongitude = row["exit_longitude"] as Double?,
              let distance = row["distance_meters"] as Double?,
              let limit = row["speed_limit_kph"] as Double? else {
            return nil
        }

        self.init(
            id: id,
            countryCode: countryCode,
            name: row["name"] as String?,
            roadRef: row["road_ref"] as String?,
            entry: Coordinate(latitude: entryLatitude, longitude: entryLongitude),
            exit: Coordinate(latitude: exitLatitude, longitude: exitLongitude),
            distanceMeters: distance,
            speedLimitKph: limit,
            minimumSpeedKph: row["minimum_speed_kph"] as Double?,
            directionDegrees: row["direction_degrees"] as Double?,
            path: RoadPath(pathJSON: row["path_json"] as String?),
            restStops: restStops,
            updatedAt: row["updated_at"] as Date? ?? Date(timeIntervalSince1970: 0)
        )
    }
}

extension RoadPath {
    /// Decodes the stored polyline: a JSON array of `[latitude, longitude]`
    /// pairs. Returns nil for anything malformed, which downgrades the zone to
    /// straight-line geometry rather than failing the whole row.
    init?(pathJSON: String?) {
        guard let pathJSON, let data = pathJSON.data(using: .utf8) else { return nil }
        guard let pairs = try? JSONDecoder().decode([[Double]].self, from: data) else { return nil }

        let coordinates = pairs.compactMap { pair -> Coordinate? in
            guard pair.count == 2 else { return nil }
            return Coordinate(latitude: pair[0], longitude: pair[1])
        }
        self.init(coordinates: coordinates)
    }
}
