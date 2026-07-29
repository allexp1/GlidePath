import GlidePathCore
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
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var sync: CountrySyncService? { model.sync }
    private var all: [CountrySyncService.CountryStatus] { sync?.countries ?? [] }

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
        .navigationTitle("Countries")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: searchPrompt)
        .refreshable { await sync?.refreshCatalogue() }
        .task {
            if all.isEmpty { await sync?.refreshCatalogue() }
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
        all.isEmpty ? "Search countries" : "Search \(all.count) countries"
    }

    // MARK: - Grouping

    private var visible: [CountrySyncService.CountryStatus] {
        guard !search.isEmpty else { return all }
        let needle = search.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return all.filter { country in
            country.name
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(needle)
                || country.code.caseInsensitiveCompare(search) == .orderedSame
        }
    }

    private var installed: [CountrySyncService.CountryStatus] { visible.filter(\.isInstalled) }
    private var available: [CountrySyncService.CountryStatus] {
        visible.filter { $0.hasData && !$0.isInstalled }
    }
    private var unsurveyed: [CountrySyncService.CountryStatus] {
        visible.filter { $0.isUnsurveyed && !$0.isInstalled }
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
                ForEach(countries) { row(for: $0) }
            }
        } else if let emptyHint {
            Section(title) {
                Text(emptyHint).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rows

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

        if country.hasUpdate { parts.append("update available") }
        else if country.isInstalled { parts.append("installed") }

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
            Button("Get") { Task { await sync?.download(country.code) } }
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
        let letters = code.uppercased().unicodeScalars
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
