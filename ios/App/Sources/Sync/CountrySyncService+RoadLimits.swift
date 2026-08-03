import Foundation
import GRDB
import GlidePathCore

/// The speed-limit half of `CountrySyncService`.
///
/// A separate download from the cameras, and separate code because almost none
/// of the camera sync's assumptions survive the size difference. A country's
/// cameras are a few hundred rows fetched in one go on launch; its speed limits
/// are hundreds of thousands of rows carrying polylines, fetched only when a
/// driver asks and written page by page because they do not fit in memory.
///
/// The two also version independently. A camera moving must not re-check a
/// dataset three orders of magnitude larger, and a road being retagged must not
/// re-check the cameras.
extension CountrySyncService {
    /// Downloads the speed limits for one country. Never triggered by launch:
    /// this is tens of megabytes and it happens when somebody asks for it.
    func downloadRoadLimits(_ code: String) async {
        await syncRoadLimits(code, forceFull: true)
    }

    func removeRoadLimits(_ code: String) async {
        try? await database.eraseRoadLimits(country: code)
        await reloadStatuses()
    }

    func syncRoadLimits(_ code: String, forceFull: Bool = false) async {
        do {
            guard let plan = try await planRoadLimits(code, forceFull: forceFull) else { return }
            try await pullRoadLimits(code, plan: plan)
            await reloadStatuses()
        } catch {
            report(.failed(country: code, message: error.localizedDescription))
        }
    }

    // MARK: - Planning

    struct RoadLimitPlan {
        let serverVersion: Int
        /// Rows the server says exist, for the progress bar.
        let expectedRows: Int
        /// Fetch only what changed after this, or everything when nil.
        let since: Date?
    }

    /// Decides what to fetch, or nil when there is nothing to do.
    private func planRoadLimits(_ code: String, forceFull: Bool) async throws -> RoadLimitPlan? {
        let row = try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM country WHERE code = ?", arguments: [code])
        }
        guard let row else { return nil }

        let serverVersion: Int = row["road_limit_version"] ?? 0
        let expected: Int = row["road_limit_count"] ?? 0
        let installed: Int? = row["road_limits_installed_version"]
        let cursor = row["road_limits_cursor"] as Date?

        if let installed, !forceFull {
            guard serverVersion > installed else { return nil }
            return RoadLimitPlan(serverVersion: serverVersion, expectedRows: expected, since: cursor)
        }

        if installed == nil, let cursor {
            // A first download that got part way and stopped: lost signal, app
            // killed, driver got out of the car. The rows it did write are good
            // and the cursor says where it reached, so carry on from there.
            // Re-fetching a hundred megabytes because the last attempt ended at
            // 90% is how a feature gets abandoned.
            //
            // Removing the limits clears the cursor, which is the way back to a
            // clean download if one is ever wanted.
            return RoadLimitPlan(serverVersion: serverVersion, expectedRows: expected, since: cursor)
        }

        try await database.eraseRoadLimits(country: code)
        return RoadLimitPlan(serverVersion: serverVersion, expectedRows: expected, since: nil)
    }

    // MARK: - Fetching

    private func pullRoadLimits(_ code: String, plan: RoadLimitPlan) async throws {
        report(.downloadingLimits(country: code, fraction: 0))

        var written = 0
        var newest: Date?

        while true {
            let page: [RoadLimitDTO] = try await client.fetchPage(
                RoadLimitDTO.self,
                from: "road_limits_public",
                filters: ["country_code": "eq.\(code)"],
                since: plan.since,
                offset: written
            )

            try await write(roadLimits: page, country: code)
            written += page.count

            if let pageNewest = page.map(\.updatedAt).max() {
                // Pages arrive in updated_at order so this only ever moves
                // forwards, but taking the max costs nothing and means a change
                // of ordering upstream cannot rewind the cursor.
                let latest = max(newest ?? pageNewest, pageNewest)
                newest = latest
                // Advanced per page, not at the end. A download that dies at 80%
                // then resumes from 80%, which on a dataset this size is the
                // difference between an inconvenience and a reason to give up on
                // the feature.
                try await advanceRoadLimitCursor(code, to: latest)
            }

            if plan.expectedRows > 0 {
                report(.downloadingLimits(
                    country: code,
                    fraction: min(Double(written) / Double(plan.expectedRows), 0.99)
                ))
            }

            if page.count < SupabaseREST.pageSize { break }
        }

        try await markRoadLimitsInstalled(code, version: plan.serverVersion)
        report(.idle)

        // Only for a download that asked for everything and got nothing. A delta
        // or a resumed run legitimately returns zero rows, and reporting that as
        // a failure would cry wolf on the happy path.
        if written == 0, plan.since == nil {
            report(.failed(
                country: code,
                message: "No speed limits came back for \(code). "
                    + "Has anyone run `make seed-limits CODE=\(code)` for it?"
            ))
        }
    }

    // MARK: - Writing

    /// Writes one page, cutting each way into grid-indexed chunks.
    ///
    /// Chunks are replaced wholesale per way rather than matched up: a re-traced
    /// road changes its point count, so its old chunks have no counterpart among
    /// the new ones and updating in place would leave orphans behind.
    private func write(roadLimits: [RoadLimitDTO], country: String) async throws {
        try await database.pool.write { db in
            for limit in roadLimits {
                try db.execute(
                    sql: "DELETE FROM road_limit WHERE way_id = ?",
                    arguments: [limit.id]
                )

                // An unverified limit is one that vanished from OpenStreetMap.
                // Unlike a camera - which is still drawn, faded, because it may
                // well still be bolted to its gantry - a limit is a claim about
                // a sign, and a claim nobody can source is one the app should
                // stop making.
                guard limit.verified else { continue }

                let coordinates = limit.coordinates
                guard coordinates.count >= 2 else { continue }

                for (index, chunk) in RoadLimitGrid.chunk(coordinates).enumerated() {
                    guard let pathJSON = Self.encodePath(chunk.coordinates) else { continue }
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO road_limit
                                (id, way_id, country_code, cell, path_json,
                                 limit_kph, forward_limit_kph, backward_limit_kph,
                                 name, road_ref, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            "\(limit.id)#\(index)",
                            limit.id,
                            country,
                            chunk.cell,
                            pathJSON,
                            limit.limitKph,
                            limit.forwardLimitKph,
                            limit.backwardLimitKph,
                            limit.name,
                            limit.roadRef,
                            limit.updatedAt
                        ]
                    )
                }
            }
        }
    }

    /// The same `[[latitude, longitude]]` encoding `zone.path_json` uses.
    ///
    /// nonisolated because it runs inside GRDB's write closure, which is a plain
    /// synchronous context off the main actor.
    nonisolated static func encodePath(_ coordinates: [Coordinate]) -> String? {
        let pairs = coordinates.map { [$0.latitude, $0.longitude] }
        guard let data = try? JSONEncoder().encode(pairs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func advanceRoadLimitCursor(_ code: String, to date: Date) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE country SET road_limits_cursor = ? WHERE code = ?",
                arguments: [date, code]
            )
        }
    }

    private func markRoadLimitsInstalled(_ code: String, version: Int) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE country
                       SET road_limits_installed_version = ?,
                           road_limits_installed_at = ?
                     WHERE code = ?
                    """,
                arguments: [version, Date(), code]
            )
        }
    }
}
