import Foundation

/// One row of the download list.
///
/// Split out of `CountrySyncService` so the service file stays about syncing.
/// Still nested inside it: every reference in the UI reads
/// `CountrySyncService.CountryStatus`, which is the right name for it.
extension CountrySyncService {
    struct CountryStatus: Identifiable, Equatable, Sendable {
        let code: String
        let name: String

        /// The country this row belongs to, when it is a subdivision of one.
        let parentCode: String?

        let serverVersion: Int
        let installedVersion: Int?
        let cameraCount: Int
        let zoneCount: Int
        let installedAt: Date?

        /// When the server last pulled this country from OpenStreetMap. Nil
        /// means never, which is a different thing from "mapped and empty".
        let lastSyncedAt: Date?

        /// Road speed limits are a separate download with their own version
        /// line: they are the largest dataset the app offers by a wide margin,
        /// and re-checking them because a camera moved would be absurd.
        let roadLimitVersion: Int
        let roadLimitCount: Int
        let roadLimitsInstalledVersion: Int?

        /// Raw so an unknown value from a newer server degrades to "no notice"
        /// rather than failing to decode the whole catalogue.
        let legalStance: String?
        let legalNote: String?

        /// Somewhere the driver should be told the law before downloading.
        var hasLegalNotice: Bool {
            legalNote != nil && legalStance != nil && legalStance != "unrestricted"
        }

        /// The strongest wording is reserved for where the device itself is
        /// banned, because "you may be fined" and "this is illegal to own" are
        /// not the same warning.
        var isProhibited: Bool { legalStance == "prohibited" }

        var id: String { code }
        var isInstalled: Bool { installedVersion != nil }

        /// A state, province or region rather than a country.
        var isSubdivision: Bool { parentCode != nil }
        var hasUpdate: Bool {
            guard let installedVersion else { return false }
            return serverVersion > installedVersion
        }

        /// Somebody has harvested limits for this country.
        var hasRoadLimits: Bool { roadLimitCount > 0 }
        var roadLimitsInstalled: Bool { roadLimitsInstalledVersion != nil }
        var roadLimitsHaveUpdate: Bool {
            guard let installed = roadLimitsInstalledVersion else { return false }
            return roadLimitVersion > installed
        }

        /// Something worth downloading.
        var hasData: Bool { cameraCount > 0 || zoneCount > 0 }

        /// Checked, and genuinely nothing there. Worth saying out loud so the
        /// driver does not think the app is broken.
        var isKnownEmpty: Bool { lastSyncedAt != nil && !hasData }

        /// Nobody has pulled this country yet, so we simply do not know.
        var isUnsurveyed: Bool { lastSyncedAt == nil && !hasData }

        /// A crude size estimate for the download. Each camera is a handful of
        /// doubles and a UUID; zones add a polyline, which dominates. Deliberately
        /// generous, because promising 2 MB and using 6 is the annoying direction.
        var estimatedBytes: Int {
            cameraCount * 180 + zoneCount * 2_400
        }

        /// The same estimate for speed limits, where it matters far more: this
        /// is the one download a driver might reasonably decline, and the one
        /// they will notice on a metered connection.
        ///
        /// A limit row is a short simplified polyline plus a handful of columns.
        /// Measured at around 700 bytes over the wire on Lithuanian data.
        var estimatedRoadLimitBytes: Int {
            roadLimitCount * 700
        }
    }
}
