import ZonexploCore
import SwiftUI

/// The download manager, across every country there is.
///
/// With 250 countries in the catalogue and camera data for only a handful, the
/// job of this screen is mostly honesty. Three states have to be visually
/// distinct or people conclude the app is broken:
///
/// - **has data** and can be downloaded now
/// - **surveyed and empty**: we looked, nobody has mapped a camera there
/// - **never surveyed**: we have not looked yet, so we genuinely do not know
///
/// Hiding the empty ones would be worse. Somebody searching for their country
/// and finding nothing needs to know whether the answer is "no cameras" or "not
/// yet supported", because only one of those is worth waiting for.
struct CountryDownloadView: View {
    /// The country whose subdivisions this list is showing, or nil for the
    /// top-level list of countries.
    ///
    /// Somewhere too large to download whole is offered per state, and a state
    /// listed beside Lithuania claims to be a country. One screen, used twice.
    var parent: CountrySyncService.CountryStatus?

    @Environment(AppModel.self) private var model
    @State private var search = ""

    /// The country whose legal notice is being shown, if any. Downloading waits
    /// on the driver reading it.
    @State private var pendingLegal: CountrySyncService.CountryStatus?

    private var sync: CountrySyncService? { model.sync }
    private var all: [CountrySyncService.CountryStatus] { sync?.countries ?? [] }

    /// The rows this level owns: countries at the top, one country's
    /// subdivisions below it.
    private var scoped: [CountrySyncService.CountryStatus] {
        guard let parent else { return all.filter { !$0.isSubdivision } }
        return all.filter { $0.parentCode == parent.code }
    }

    private func children(of country: CountrySyncService.CountryStatus)
        -> [CountrySyncService.CountryStatus] {
        all.filter { $0.parentCode == country.code }
    }

    var body: some View {
        List {
            if let message = failureMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            section("Downloaded", installed, emptyHint: nil)
            section(
                "Available",
                available,
                emptyHint: search.isEmpty ? nil : "No match with camera data."
            )

            if !unsurveyed.isEmpty {
                Section {
                    ForEach(unsurveyed) { row(for: $0) }
                } header: {
                    Text("Not surveyed yet")
                } footer: {
                    Text(
                        "Nobody has pulled camera data for these yet, so the app does not know "
                            + "what is there. They are listed so you can see your country is "
                            + "recognised even when its data is not ready."
                    )
                }
            }

            if !knownEmpty.isEmpty {
                Section {
                    ForEach(knownEmpty) { row(for: $0) }
                } header: {
                    Text("No cameras mapped")
                } footer: {
                    Text("Checked against OpenStreetMap and nothing was found.")
                }
            }
        }
        .navigationTitle(parent?.name ?? "Countries")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: searchPrompt)
        .refreshable { await sync?.refreshCatalogue() }
        .task {
            if all.isEmpty { await sync?.refreshCatalogue() }
        }
        .sheet(item: $pendingLegal) { country in
            LegalNoticeSheet(country: country) { accepted in
                pendingLegal = nil
                guard accepted else { return }
                model.settings.acceptLegal(country.code)
                Task { await sync?.download(country.code) }
            }
        }
        .overlay {
            if all.isEmpty {
                ContentUnavailableView(
                    "No countries yet",
                    systemImage: "globe",
                    description: Text("Pull to refresh once you have a connection.")
                )
            } else if visible.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private var searchPrompt: String {
        if let parent { return "Search \(parent.name)" }
        // Counts countries, not rows. Offering "245 countries" when two of them
        // are American states is the same mistake as listing them side by side.
        let countries = all.filter { !$0.isSubdivision }.count
        return countries == 0 ? "Search countries" : "Search \(countries) countries"
    }

    // MARK: - Grouping

    private var visible: [CountrySyncService.CountryStatus] {
        guard !search.isEmpty else { return scoped }
        // A search at the top level looks inside subdivisions too. Somebody
        // typing "Massachusetts" should be shown Massachusetts, not told to
        // think of the United States first and drill down.
        let pool = parent == nil ? all : scoped
        let needle = search.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return pool.filter { country in
            country.name
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(needle)
                || country.code.caseInsensitiveCompare(search) == .orderedSame
        }
    }

    // A country holding subdivisions is filed by what its children are, not by
    // its own row - which is always empty, because the United States has no
    // cameras of its own. Downloading both states and still finding the country
    // under "Available" is the list contradicting the screen behind it.
    private func isDownloaded(_ country: CountrySyncService.CountryStatus) -> Bool {
        let regions = children(of: country)
        return regions.isEmpty ? country.isInstalled : regions.contains(where: \.isInstalled)
    }

    private func isOffered(_ country: CountrySyncService.CountryStatus) -> Bool {
        let regions = children(of: country)
        return regions.isEmpty ? country.hasData : regions.contains(where: \.hasData)
    }

    private var installed: [CountrySyncService.CountryStatus] {
        visible.filter { isDownloaded($0) }
    }
    private var available: [CountrySyncService.CountryStatus] {
        visible.filter { isOffered($0) && !isDownloaded($0) }
    }
    private var unsurveyed: [CountrySyncService.CountryStatus] {
        visible.filter { $0.isUnsurveyed && !isDownloaded($0) && !isOffered($0) }
    }
    private var knownEmpty: [CountrySyncService.CountryStatus] {
        visible.filter { $0.isKnownEmpty && !$0.isInstalled }
    }

    private var failureMessage: String? {
        if case let .failed(_, message) = sync?.progress { return message }
        return nil
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ countries: [CountrySyncService.CountryStatus],
        emptyHint: String?
    ) -> some View {
        if !countries.isEmpty {
            Section(title) {
                ForEach(countries) { rows(for: $0) }
            }
        } else if let emptyHint {
            Section(title) {
                Text(emptyHint).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rows

    /// A country, plus its speed limits as a second row when there are any.
    ///
    /// Two rows rather than one combined download. The limit dataset is two
    /// orders of magnitude larger than the camera data, and rolling them
    /// together would mean a driver who wants camera warnings has to take
    /// hundreds of megabytes of road network to get them.
    @ViewBuilder
    private func rows(for country: CountrySyncService.CountryStatus) -> some View {
        let regions = children(of: country)
        if regions.isEmpty {
            row(for: country)
        } else {
            regionRow(for: country, regions: regions)
        }

        if country.isInstalled, country.hasRoadLimits {
            limitRow(for: country)
        }
    }

    /// A country offered as a set of subdivisions rather than as one download.
    ///
    /// The United States is not downloadable whole - millions of tagged ways,
    /// which is neither harvestable nor a download anyone would accept - so its
    /// row is a door rather than a button. Summing the children on the way in
    /// means the driver can see whether it is worth opening.
    private func regionRow(
        for country: CountrySyncService.CountryStatus,
        regions: [CountrySyncService.CountryStatus]
    ) -> some View {
        let withData = regions.filter(\.hasData)
        let installedCount = regions.filter(\.isInstalled).count
        let cameras = regions.reduce(0) { $0 + $1.cameraCount }

        return NavigationLink {
            CountryDownloadView(parent: country)
        } label: {
            HStack(spacing: 12) {
                Text(CountryFlag.emoji(for: country.code))
                    .font(.title2)
                    .frame(width: 34)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.body)
                    Text(regionDetail(
                        available: withData.count,
                        installed: installedCount,
                        cameras: cameras
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
        .accessibilityLabel(
            "\(country.name), \(withData.count) regions available, \(installedCount) downloaded"
        )
    }

    private func regionDetail(available: Int, installed: Int, cameras: Int) -> String {
        guard available > 0 else { return "No regions surveyed yet" }

        let unit = available == 1 ? "region" : "regions"
        var parts = ["\(available) \(unit)", "\(cameras.formatted()) cameras"]

        // "2 of 2" rather than "2 downloaded", so a country whose regions are
        // all present looks finished and one with more to take does not.
        if installed == available {
            parts.append(available == 1 ? "downloaded" : "all downloaded")
        } else if installed > 0 {
            parts.append("\(installed) of \(available) downloaded")
        }
        return parts.joined(separator: " · ")
    }

    private func limitRow(for country: CountrySyncService.CountryStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Speed limits")
                    .font(.subheadline)
                Text(limitDetail(for: country))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            limitAction(for: country)
        }
        .padding(.vertical, 3)
        .padding(.leading, 12)
        .swipeActions {
            if country.roadLimitsInstalled {
                Button("Remove", role: .destructive) {
                    Task { await sync?.removeRoadLimits(country.code) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(country.name) speed limits. \(limitDetail(for: country))")
    }

    private func limitDetail(for country: CountrySyncService.CountryStatus) -> String {
        if case let .downloadingLimits(code, fraction) = sync?.progress, code == country.code {
            return "Downloading, \(Int(fraction * 100))%"
        }

        var parts = ["\(country.roadLimitCount.formatted()) roads"]
        parts.append(size(country.estimatedRoadLimitBytes))

        if country.roadLimitsHaveUpdate {
            parts.append("update available")
        } else if country.roadLimitsInstalled {
            parts.append("installed")
        } else {
            // The one download in the app worth warning about before it starts.
            parts.append("Wi-Fi recommended")
        }

        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func limitAction(for country: CountrySyncService.CountryStatus) -> some View {
        if case let .downloadingLimits(code, _) = sync?.progress, code == country.code {
            ProgressView()
        } else if country.roadLimitsHaveUpdate {
            Button("Update") { Task { await sync?.syncRoadLimits(country.code) } }
                .buttonStyle(.glass)
        } else if country.roadLimitsInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Installed")
        } else {
            Button("Get") { Task { await sync?.downloadRoadLimits(country.code) } }
                .buttonStyle(.glass)
        }
    }

    private func row(for country: CountrySyncService.CountryStatus) -> some View {
        HStack(spacing: 12) {
            Text(CountryFlag.emoji(for: country.code))
                .font(.title2)
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(country.name)
                    .font(.body)
                Text(detail(for: country))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            action(for: country)
        }
        .padding(.vertical, 3)
        .opacity(country.hasData || country.isInstalled ? 1 : 0.55)
        .swipeActions {
            if country.isInstalled {
                Button("Remove", role: .destructive) {
                    Task { await sync?.remove(country.code) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(country.name). \(detail(for: country))")
    }

    private func detail(for country: CountrySyncService.CountryStatus) -> String {
        if case let .downloading(code, fraction) = sync?.progress, code == country.code {
            return "Downloading, \(Int(fraction * 100))%"
        }

        if country.isUnsurveyed { return "Not surveyed yet" }
        if country.isKnownEmpty { return "No cameras mapped" }

        var parts = ["\(country.cameraCount.formatted()) cameras"]
        if country.zoneCount > 0 {
            parts.append("\(country.zoneCount.formatted()) zones")
        }
        parts.append(size(country.estimatedBytes))

        if country.hasUpdate {
            parts.append("update available")
        } else if country.isInstalled {
            parts.append("installed")
        }

        return parts.joined(separator: " · ")
    }

    private func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes < 1_000_000 ? [.useKB] : [.useMB]
        return "about \(formatter.string(fromByteCount: Int64(bytes)))"
    }

    @ViewBuilder
    private func action(for country: CountrySyncService.CountryStatus) -> some View {
        if case let .downloading(code, _) = sync?.progress, code == country.code {
            ProgressView()
        } else if country.hasUpdate {
            Button("Update") { Task { await sync?.sync(country.code) } }
                .buttonStyle(.glass)
        } else if country.isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Installed")
        } else if country.hasData {
            Button("Get") {
                // Somewhere restricted, the driver reads the law first. Not a
                // block: an adult in a jurisdiction we have not checked gets to
                // decide, but they decide knowing which law applies.
                if country.hasLegalNotice, !model.settings.hasAcceptedLegal(country.code) {
                    pendingLegal = country
                } else {
                    Task { await sync?.download(country.code) }
                }
            }
            .buttonStyle(.glassProminent)
        } else {
            // Nothing to offer, and a disabled button that can never be tapped
            // is just clutter.
            EmptyView()
        }
    }
}

/// The flag for an ISO 3166-1 alpha-2 code.
///
/// Derived rather than stored. Regional indicator symbols are laid out so that
/// the letters A to Z map to a contiguous block, which means every flag falls
/// out of the code arithmetically and no table can go stale.
enum CountryFlag {
    static func emoji(for code: String) -> String {
        // A subdivision flies its country's flag. Places too large to download
        // whole are listed per state as `US-NY`, and there is no regional
        // indicator sequence for a state - without this every one of them shows
        // the white flag used for "unknown", which reads as broken data rather
        // than as a deliberate subdivision.
        let country = code.split(separator: "-").first.map(String.init) ?? code

        let letters = country.uppercased().unicodeScalars
        guard letters.count == 2 else { return "🏳️" }

        var flag = ""
        for letter in letters {
            guard letter.value >= 65, letter.value <= 90,
                  let scalar = Unicode.Scalar(letter.value + 0x1F1E6 - 65) else {
                return "🏳️"
            }
            flag.unicodeScalars.append(scalar)
        }
        return flag
    }
}
