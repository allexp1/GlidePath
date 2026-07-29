import GlidePathCore
import SwiftUI

/// The download manager.
///
/// Downloading is the one moment GlidePath needs the network, so this screen
/// has to be honest about size and state. A driver who thinks Israel is
/// installed when it is not gets no warnings and no explanation, which is the
/// worst failure the app has.
struct CountryDownloadView: View {
    @Environment(AppModel.self) private var model

    private var sync: CountrySyncService? { model.sync }

    var body: some View {
        List {
            Section {
                ForEach(sync?.countries ?? []) { country in
                    row(for: country)
                }
            } header: {
                Text("Countries")
            } footer: {
                Text(
                    "Downloaded countries work with no signal. "
                        + "Updates are small and happen automatically when you open the app."
                )
            }

            if case let .failed(_, message) = sync?.progress {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let checked = sync?.lastCheckedAt {
                Section {
                    LabeledContent("Last checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Offline data")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sync?.refreshCatalogue() }
        .task {
            if sync?.countries.isEmpty ?? true {
                await sync?.refreshCatalogue()
            }
        }
        .overlay {
            if (sync?.countries ?? []).isEmpty {
                ContentUnavailableView(
                    "No countries yet",
                    systemImage: "globe",
                    description: Text("Pull to refresh once you have a connection.")
                )
            }
        }
    }

    private func row(for country: CountrySyncService.CountryStatus) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(country.name)
                    .font(.headline)

                Text(detail(for: country))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            action(for: country)
        }
        .padding(.vertical, 4)
        .swipeActions {
            if country.isInstalled {
                Button("Remove", role: .destructive) {
                    Task { await sync?.remove(country.code) }
                }
            }
        }
    }

    private func detail(for country: CountrySyncService.CountryStatus) -> String {
        if case let .downloading(code, fraction) = sync?.progress, code == country.code {
            return "Downloading, \(Int(fraction * 100))%"
        }

        let contents = "\(country.cameraCount) cameras, \(country.zoneCount) zones"

        guard country.isInstalled else { return contents }
        if country.hasUpdate { return "\(contents). Update available" }
        guard let installedAt = country.installedAt else { return "\(contents). Installed" }
        return "\(contents). Updated \(installedAt.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private func action(for country: CountrySyncService.CountryStatus) -> some View {
        if case let .downloading(code, _) = sync?.progress, code == country.code {
            ProgressView()
        } else if country.hasUpdate {
            Button("Update") {
                Task { await sync?.sync(country.code) }
            }
            .buttonStyle(.glass)
        } else if country.isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Installed")
        } else {
            Button("Get") {
                Task { await sync?.download(country.code) }
            }
            .buttonStyle(.glassProminent)
        }
    }
}
