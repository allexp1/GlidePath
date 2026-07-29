import Foundation
import GRDB
import GlidePathCore

/// The offline copy of every downloaded country.
///
/// GlidePath has to work with no signal, because the roads where it matters most
/// are the ones without any. Nothing on the driving path ever touches the
/// network: a fix goes to this database and back, and the only time Supabase is
/// involved is a download or a delta sync at launch.
///
/// Geography is stored as plain latitude and longitude columns rather than
/// anything spatial. SQLite has no PostGIS, and a bounding-box query on indexed
/// doubles followed by an exact distance filter in Swift is both simpler and
/// fast enough: even Israel's full camera set is a few thousand rows.
final class LocalDatabase: Sendable {
    let pool: DatabasePool

    init(url: URL) throws {
        var configuration = Configuration()
        // Read-heavy and single-writer. A short busy timeout is plenty and
        // means a sync in flight never blocks a lookup while driving.
        configuration.busyMode = .timeout(2)
        configuration.maximumReaderCount = 4

        pool = try DatabasePool(path: url.path, configuration: configuration)
        try LocalDatabase.migrator.migrate(pool)
    }

    /// Where the database lives. Application Support rather than Documents:
    /// this is a cache of a server-side dataset, not user data, and it should
    /// not clutter the Files app.
    static func defaultURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = directory.appendingPathComponent("GlidePath", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("glidepath.sqlite")
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_core") { db in
            try db.create(table: "country") { table in
                table.primaryKey("code", .text)
                table.column("name", .text).notNull()

                // What the server says exists.
                table.column("dataset_version", .integer).notNull().defaults(to: 0)
                table.column("min_compatible_version", .integer).notNull().defaults(to: 1)

                // What this phone actually holds. The gap between the two is
                // what the sync closes.
                table.column("installed_version", .integer)
                table.column("installed_at", .datetime)

                table.column("camera_count", .integer).notNull().defaults(to: 0)
                table.column("zone_count", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "zone") { table in
                table.primaryKey("id", .text)
                table.column("country_code", .text).notNull().indexed()
                table.column("name", .text)
                table.column("road_ref", .text)
                table.column("entry_latitude", .double).notNull()
                table.column("entry_longitude", .double).notNull()
                table.column("exit_latitude", .double).notNull()
                table.column("exit_longitude", .double).notNull()
                table.column("distance_meters", .double).notNull()
                table.column("speed_limit_kph", .double).notNull()
                table.column("minimum_speed_kph", .double)
                table.column("direction_degrees", .double)
                table.column("verified", .boolean).notNull().defaults(to: true)
                // The polyline, as a JSON array of [lat, lon] pairs.
                table.column("path_json", .text)
                table.column("updated_at", .datetime).notNull()
            }

            // The bounding-box index. Both columns, because a query filters on
            // both and SQLite will only use one index per table scan.
            try db.create(
                index: "zone_entry_bbox",
                on: "zone",
                columns: ["entry_latitude", "entry_longitude"]
            )

            try db.create(table: "camera") { table in
                table.primaryKey("id", .text)
                table.column("country_code", .text).notNull().indexed()
                table.column("latitude", .double).notNull()
                table.column("longitude", .double).notNull()
                table.column("type", .text).notNull()
                table.column("direction_degrees", .double)
                table.column("speed_limit_kph", .double)
                table.column("zone_id", .text).indexed()
                table.column("verified", .boolean).notNull().defaults(to: true)
                table.column("updated_at", .datetime).notNull()
            }

            try db.create(index: "camera_bbox", on: "camera", columns: ["latitude", "longitude"])

            try db.create(table: "rest_stop") { table in
                table.primaryKey("id", .text)
                table.column("country_code", .text).notNull().indexed()
                table.column("zone_id", .text).indexed()
                table.column("name", .text)
                table.column("latitude", .double).notNull()
                table.column("longitude", .double).notNull()
                table.column("kind", .text).notNull()
                table.column("distance_along_meters", .double)
                table.column("updated_at", .datetime).notNull()
            }

            // One row per country per table: the high-water mark for delta sync.
            try db.create(table: "sync_cursor") { table in
                table.column("country_code", .text).notNull()
                table.column("resource", .text).notNull()
                table.column("last_updated_at", .datetime)
                table.primaryKey(["country_code", "resource"])
            }

            // Drives the driver has completed, for the history screen. Local
            // only: where somebody has been driving is not data this product
            // has any business uploading.
            try db.create(table: "zone_run") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("zone_id", .text).notNull().indexed()
                table.column("zone_name", .text)
                table.column("entered_at", .datetime).notNull()
                table.column("exited_at", .datetime).notNull()
                table.column("average_kph", .double).notNull()
                table.column("limit_kph", .double).notNull()
                table.column("passed", .boolean).notNull()
            }
        }

        return migrator
    }

    /// Throws the country away. Used by the version fallback when a delta can
    /// no longer be trusted, and by the user removing a download.
    func erase(country code: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM camera WHERE country_code = ?", arguments: [code])
            try db.execute(sql: "DELETE FROM rest_stop WHERE country_code = ?", arguments: [code])
            try db.execute(sql: "DELETE FROM zone WHERE country_code = ?", arguments: [code])
            try db.execute(sql: "DELETE FROM sync_cursor WHERE country_code = ?", arguments: [code])
            try db.execute(
                sql: "UPDATE country SET installed_version = NULL, installed_at = NULL WHERE code = ?",
                arguments: [code]
            )
        }
    }
}
