import Foundation
import GRDB
import GlidePathCore
import Observation

/// Downloads countries and keeps them current.
///
/// Two modes, and the decision between them is the interesting part:
///
/// - **Delta.** Ask for everything changed since the last cursor. A few rows on
///   a normal day, which is what makes syncing on launch acceptable on mobile
///   data.
/// - **Full.** Wipe the country and download it again. Used for a first
///   install, and whenever a delta can no longer be trusted.
///
/// A delta stops being trustworthy when the server raises
/// `min_compatible_version` above what this phone holds. That happens when a
/// change is not expressible as a row update, such as zones being re-split or a
/// systematic geometry fix. Without the check, an install left in a drawer for a
/// year would apply a delta on top of a dataset whose meaning had changed
/// underneath it, and would be confidently wrong rather than obviously stale.
@MainActor
@Observable
final class CountrySyncService {
    enum Progress: Equatable, Sendable {
        case idle
        case checking
        case downloading(country: String, fraction: Double)
        /// Its own case rather than a flag on `downloading`: the two are offered
        /// as separate rows on the same screen, and a shared case leaves the UI
        /// unable to say which of them the spinner belongs to.
        case downloadingLimits(country: String, fraction: Double)
        case failed(country: String, message: String)
    }

    private(set) var countries: [CountryStatus] = []
    private(set) var progress: Progress = .idle
    private(set) var lastCheckedAt: Date?

    // Internal rather than private: the road-limit half of this type lives in
    // CountrySyncService+RoadLimits.swift, and `private` is file scope.
    let database: LocalDatabase
    let client: SupabaseREST

    init(database: LocalDatabase, client: SupabaseREST) {
        self.database = database
        self.client = client
    }

    /// Setters for the two published properties, for the same reason.
    ///
    /// Methods rather than dropping `private(set)`, so the only code that can
    /// move either one is still inside this type.
    func report(_ progress: Progress) {
        self.progress = progress
    }

    func reloadStatuses() async {
        countries = (try? await loadStatuses()) ?? []
    }

    // MARK: - Catalogue

    /// Refreshes the download list. Falls back to whatever is on disk when
    /// there is no signal, so the screen is never empty in a dead spot.
    func refreshCatalogue() async {
        progress = .checking

        do {
            let remote: [CountryDTO] = try await client.fetchAll(
                CountryDTO.self,
                from: "countries_public",
                // Keyed on code, not id.
                uniqueColumn: "code"
            )
            try await storeCatalogue(remote)
            lastCheckedAt = Date()
            progress = .idle
        } catch {
            // Deliberately not reset to .idle afterwards: the screen needs to
            // keep showing why the list is stale. Whatever is already
            // downloaded still works, which is the entire point of the design.
            progress = .failed(country: "", message: error.localizedDescription)
        }

        countries = (try? await loadStatuses()) ?? []
    }

    private func storeCatalogue(_ remote: [CountryDTO]) async throws {
        try await database.pool.write { db in
            for country in remote {
                try db.execute(
                    sql: """
                        INSERT INTO country
                            (code, name, dataset_version, min_compatible_version,
                             camera_count, zone_count, last_synced_at,
                             road_limit_version, road_limit_count)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(code) DO UPDATE SET
                            name = excluded.name,
                            dataset_version = excluded.dataset_version,
                            min_compatible_version = excluded.min_compatible_version,
                            camera_count = excluded.camera_count,
                            zone_count = excluded.zone_count,
                            last_synced_at = excluded.last_synced_at,
                            road_limit_version = excluded.road_limit_version,
                            road_limit_count = excluded.road_limit_count
                        """,
                    arguments: [
                        country.code,
                        country.name,
                        country.datasetVersion,
                        country.minCompatibleVersion,
                        country.cameraCount,
                        country.zoneCount,
                        country.lastSyncedAt,
                        // Nil on a project that has not applied the road-limit
                        // migration, which reads correctly as "none available".
                        country.roadLimitVersion ?? 0,
                        country.roadLimitCount ?? 0
                    ]
                )
            }
        }
    }

    private func loadStatuses() async throws -> [CountryStatus] {
        try await database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM country ORDER BY name").map { row in
                CountryStatus(
                    code: row["code"],
                    name: row["name"],
                    serverVersion: row["dataset_version"],
                    installedVersion: row["installed_version"],
                    cameraCount: row["camera_count"],
                    zoneCount: row["zone_count"],
                    installedAt: row["installed_at"],
                    lastSyncedAt: row["last_synced_at"],
                    roadLimitVersion: row["road_limit_version"] ?? 0,
                    roadLimitCount: row["road_limit_count"] ?? 0,
                    roadLimitsInstalledVersion: row["road_limits_installed_version"]
                )
            }
        }
    }

    // MARK: - Syncing

    /// Brings every installed country up to date. Called on launch.
    func syncInstalledCountries() async {
        await refreshCatalogue()
        for country in countries where country.isInstalled {
            await sync(country.code)
        }
    }

    func download(_ code: String) async {
        await sync(code, forceFull: true)
    }

    func remove(_ code: String) async {
        try? await database.erase(country: code)
        countries = (try? await loadStatuses()) ?? []
    }

    func sync(_ code: String, forceFull: Bool = false) async {
        do {
            let plan = try await plan(for: code, forceFull: forceFull)

            switch plan {
            case .upToDate:
                return

            case .full:
                progress = .downloading(country: code, fraction: 0)
                try await database.erase(country: code)
                try await pull(code, since: nil)

            case let .delta(since):
                progress = .downloading(country: code, fraction: 0)
                try await pull(code, since: since)
            }

            try await markInstalled(code)
            countries = (try? await loadStatuses()) ?? []
            progress = .idle
        } catch {
            progress = .failed(country: code, message: error.localizedDescription)
        }
    }

    private enum SyncPlan {
        case upToDate
        case full
        /// Ask for everything changed strictly after this timestamp.
        case delta(since: Date)
    }

    private func plan(for code: String, forceFull: Bool) async throws -> SyncPlan {
        if forceFull { return .full }

        let row = try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM country WHERE code = ?", arguments: [code])
        }
        guard let row, let installed = row["installed_version"] as Int? else {
            return .full
        }

        let serverVersion: Int = row["dataset_version"]
        let minimumCompatible: Int = row["min_compatible_version"]

        // The stale-install fallback.
        if installed < minimumCompatible { return .full }
        if installed >= serverVersion { return .upToDate }

        // The cursor is the oldest of the three, because a partial sync may
        // have written one resource and not another. Starting from the oldest
        // re-fetches a few rows rather than missing any.
        let cursors = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT resource, last_updated_at FROM sync_cursor WHERE country_code = ?",
                arguments: [code]
            )
        }

        let timestamps = cursors.compactMap { $0["last_updated_at"] as Date? }
        guard timestamps.count == Resource.allCases.count, let oldest = timestamps.min() else {
            return .full
        }
        return .delta(since: oldest)
    }

    private enum Resource: String, CaseIterable {
        case zones
        case cameras
        case restStops
    }

    /// Pulls each resource and writes it, advancing that resource's cursor only
    /// after its rows are committed. A sync interrupted half way therefore
    /// resumes rather than silently losing the rows it had not reached.
    private func pull(_ code: String, since: Date?) async throws {
        let filters = ["country_code": "eq.\(code)"]

        progress = .downloading(country: code, fraction: 0.05)
        let zones: [ZoneDTO] = try await client.fetchAll(
            ZoneDTO.self, from: "zones_public", filters: filters, since: since
        )
        try await write(zones: zones, country: code)

        progress = .downloading(country: code, fraction: 0.4)
        let cameras: [CameraDTO] = try await client.fetchAll(
            CameraDTO.self, from: "cameras_public", filters: filters, since: since
        )
        try await write(cameras: cameras, country: code)

        progress = .downloading(country: code, fraction: 0.85)
        let stops: [RestStopDTO] = try await client.fetchAll(
            RestStopDTO.self, from: "rest_stops_public", filters: filters, since: since
        )
        try await write(restStops: stops, country: code)

        progress = .downloading(country: code, fraction: 1)
    }

    private func write(zones: [ZoneDTO], country: String) async throws {
        try await database.pool.write { db in
            for zone in zones {
                try db.execute(
                    sql: """
                        INSERT INTO zone
                            (id, country_code, name, road_ref,
                             entry_latitude, entry_longitude, exit_latitude, exit_longitude,
                             distance_meters, speed_limit_kph, minimum_speed_kph, direction_degrees,
                             verified, path_json, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            road_ref = excluded.road_ref,
                            entry_latitude = excluded.entry_latitude,
                            entry_longitude = excluded.entry_longitude,
                            exit_latitude = excluded.exit_latitude,
                            exit_longitude = excluded.exit_longitude,
                            distance_meters = excluded.distance_meters,
                            speed_limit_kph = excluded.speed_limit_kph,
                            minimum_speed_kph = excluded.minimum_speed_kph,
                            direction_degrees = excluded.direction_degrees,
                            verified = excluded.verified,
                            path_json = excluded.path_json,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        zone.id, zone.countryCode, zone.name, zone.roadRef,
                        zone.entryLatitude, zone.entryLongitude,
                        zone.exitLatitude, zone.exitLongitude,
                        zone.distanceMeters, zone.speedLimitKph,
                        zone.minimumSpeedKph, zone.directionDegrees,
                        zone.verified, zone.pathJSON, zone.updatedAt
                    ]
                )
            }

            if let latest = zones.map(\.updatedAt).max() {
                try Self.advanceCursor(db, country: country, resource: .zones, to: latest)
            } else {
                try Self.ensureCursor(db, country: country, resource: .zones)
            }
        }
    }

    private func write(cameras: [CameraDTO], country: String) async throws {
        try await database.pool.write { db in
            for camera in cameras {
                try db.execute(
                    sql: """
                        INSERT INTO camera
                            (id, country_code, latitude, longitude, type,
                             direction_degrees, speed_limit_kph, zone_id, verified, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            latitude = excluded.latitude,
                            longitude = excluded.longitude,
                            type = excluded.type,
                            direction_degrees = excluded.direction_degrees,
                            speed_limit_kph = excluded.speed_limit_kph,
                            zone_id = excluded.zone_id,
                            verified = excluded.verified,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        camera.id, camera.countryCode, camera.latitude, camera.longitude,
                        camera.type, camera.directionDegrees, camera.speedLimitKph,
                        camera.zoneId, camera.verified, camera.updatedAt
                    ]
                )
            }

            if let latest = cameras.map(\.updatedAt).max() {
                try Self.advanceCursor(db, country: country, resource: .cameras, to: latest)
            } else {
                try Self.ensureCursor(db, country: country, resource: .cameras)
            }
        }
    }

    private func write(restStops: [RestStopDTO], country: String) async throws {
        try await database.pool.write { db in
            for stop in restStops {
                try db.execute(
                    sql: """
                        INSERT INTO rest_stop
                            (id, country_code, zone_id, name, latitude, longitude,
                             kind, distance_along_meters, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            zone_id = excluded.zone_id,
                            name = excluded.name,
                            latitude = excluded.latitude,
                            longitude = excluded.longitude,
                            kind = excluded.kind,
                            distance_along_meters = excluded.distance_along_meters,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        stop.id, stop.countryCode, stop.zoneId, stop.name,
                        stop.latitude, stop.longitude, stop.kind,
                        stop.distanceAlongMeters, stop.updatedAt
                    ]
                )
            }

            if let latest = restStops.map(\.updatedAt).max() {
                try Self.advanceCursor(db, country: country, resource: .restStops, to: latest)
            } else {
                try Self.ensureCursor(db, country: country, resource: .restStops)
            }
        }
    }

    private func markInstalled(_ code: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE country
                       SET installed_version = dataset_version,
                           installed_at = ?
                     WHERE code = ?
                    """,
                arguments: [Date(), code]
            )
        }
    }

    // MARK: - Cursors

    // nonisolated because these run inside GRDB's write closure, which is a
    // plain synchronous context off the main actor. Without it the whole type's
    // @MainActor isolation follows the static methods in and the call is a
    // concurrency error.
    nonisolated private static func advanceCursor(
        _ db: Database,
        country: String,
        resource: Resource,
        to date: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_cursor (country_code, resource, last_updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(country_code, resource) DO UPDATE SET
                    last_updated_at = max(excluded.last_updated_at, sync_cursor.last_updated_at)
                """,
            arguments: [country, resource.rawValue, date]
        )
    }

    /// An empty result still needs a cursor row, or the next sync sees an
    /// incomplete cursor set and falls back to a full download for nothing.
    nonisolated private static func ensureCursor(
        _ db: Database,
        country: String,
        resource: Resource
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_cursor (country_code, resource, last_updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(country_code, resource) DO NOTHING
                """,
            arguments: [country, resource.rawValue, Date(timeIntervalSince1970: 0)]
        )
    }
}
