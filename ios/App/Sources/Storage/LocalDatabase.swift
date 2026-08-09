import Foundation
import GRDB
import ZonexploCore

/// The offline copy of every downloaded country.
///
/// Zonexplo has to work with no signal, because the roads where it matters most
/// are the ones without any. Nothing on the driving path ever touches the
/// network: a fix goes to this database and back, and the only time Supabase is
/// involved is a download or a delta sync at launch.
///
/// Geography is stored as plain latitude and longitude columns rather than
/// anything spatial. SQLite has no PostGIS, and a bounding-box query on indexed
/// doubles followed by an exact distance filter in Swift is both simpler and
/// fast enough: even Israel's full camera set is a few thousand rows.
/// `@unchecked` because the guarantee comes from GRDB rather than from the
/// compiler: a `DatabasePool` is documented as safe to use concurrently from
/// any thread, and this type adds no mutable state of its own on top of it.
final class LocalDatabase: @unchecked Sendable {
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
        let folder = directory.appendingPathComponent("Zonexplo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("zonexplo.sqlite")
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

        // With every country in the catalogue, most of them have no data. The
        // download list has to distinguish "nobody has mapped any cameras here"
        // from "we have never looked", and only the server knows which.
        migrator.registerMigration("v2_country_last_synced") { db in
            try db.alter(table: "country") { table in
                table.add(column: "last_synced_at", .datetime)
            }
        }

        // Posted speed limits for ordinary roads.
        //
        // This table is three orders of magnitude larger than everything above
        // it - a country is hundreds of thousands of rows, not hundreds - and
        // that changes how it has to be queried. The bounding-box scan the
        // cameras use is fine over a few thousand rows and hopeless here: it
        // reads every row in a band of latitude across the whole country.
        //
        // So limits are indexed by grid cell instead. Each row carries the cell
        // its midpoint falls in, a lookup asks for the nine cells around the
        // driver, and SQLite answers from the index without touching anything
        // else. Long ways are cut into chunks on the way in so that a row is
        // always small enough for its midpoint to represent it - see
        // RoadLimitChunk.
        migrator.registerMigration("v3_road_limits") { db in
            try db.create(table: "road_limit") { table in
                // "<server row id>#<chunk index>". Chunking happens on the
                // phone, so one server row becomes several of these.
                table.primaryKey("id", .text)

                // The server row this chunk came from. A way that is re-traced
                // upstream changes its point count, so an update replaces every
                // chunk rather than trying to match them up.
                table.column("way_id", .text).notNull().indexed()

                table.column("country_code", .text).notNull().indexed()
                table.column("cell", .text).notNull()

                // The polyline, as a JSON array of [lat, lon] pairs, same
                // encoding as zone.path_json.
                table.column("path_json", .text).notNull()

                table.column("limit_kph", .double).notNull()
                table.column("forward_limit_kph", .double)
                table.column("backward_limit_kph", .double)
                table.column("name", .text)
                table.column("road_ref", .text)
                table.column("updated_at", .datetime).notNull()
            }

            try db.create(index: "road_limit_cell", on: "road_limit", columns: ["cell"])

            // Limits are downloaded per country, separately from cameras and
            // with their own version line, so they need their own high-water
            // mark rather than a row in sync_cursor.
            try db.alter(table: "country") { table in
                table.add(column: "road_limit_version", .integer).notNull().defaults(to: 0)
                table.add(column: "road_limit_count", .integer).notNull().defaults(to: 0)
                table.add(column: "road_limits_installed_version", .integer)
                table.add(column: "road_limits_installed_at", .datetime)
                table.add(column: "road_limits_cursor", .datetime)
            }
        }

        return migrator
    }

    /// Throws the country's camera data away. Used by the version fallback when
    /// a delta can no longer be trusted, and by the user removing a download.
    ///
    /// Leaves road limits alone: they are a separate download with their own
    /// version line, and re-fetching tens of megabytes because a camera moved is
    /// exactly what keeping them separate was for.
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

    /// Throws the country's speed limits away, which is the larger half of a
    /// download and the one a driver short of space will want back first.
    ///
    /// The freed pages stay in the database file rather than being handed back
    /// to the filesystem. SQLite reuses them, so the file stops growing rather
    /// than shrinking, and a driver who removed a country to save space will not
    /// see the space appear until they download something else. Vacuuming would
    /// fix that and would rewrite the entire file to do it, which is the wrong
    /// thing to start doing to a phone that is short of room.
    func eraseRoadLimits(country code: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM road_limit WHERE country_code = ?", arguments: [code])
            try db.execute(
                sql: """
                    UPDATE country
                       SET road_limits_installed_version = NULL,
                           road_limits_installed_at = NULL,
                           road_limits_cursor = NULL
                     WHERE code = ?
                    """,
                arguments: [code]
            )
        }
    }
}
