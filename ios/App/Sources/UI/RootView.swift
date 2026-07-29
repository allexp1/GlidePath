import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.startup {
            case .loading:
                ProgressView("Starting up")

            case let .needsConfiguration(problem):
                setupRequired(problem)

            case let .failed(message):
                ContentUnavailableView(
                    "GlidePath could not start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )

            case .ready:
                if model.settings.hasSeenOnboarding {
                    main
                } else {
                    OnboardingView {
                        model.settings.hasSeenOnboarding = true
                        model.startMonitoring()
                        showingSettings = true
                    }
                }
            }
        }
        .task { await model.bootstrap() }
    }

    private var main: some View {
        NavigationStack {
            HomeView()
                .navigationTitle("GlidePath")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .navigationDestination(isPresented: $showingSettings) {
                    CountryDownloadView()
                }
        }
    }

    /// The first-run failure that would otherwise be baffling: the app launches,
    /// the country list is empty, and nothing says why. Naming the file and the
    /// exact problem turns a support conversation into a ten second fix.
    private func setupRequired(_ problem: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)

                Text("Almost there")
                    .font(.title.weight(.semibold))

                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("From the repository root:")
                        .font(.subheadline.weight(.medium))
                    Text(
                        """
                        cp Config.example.xcconfig Config.xcconfig
                        # paste SUPABASE_URL and SUPABASE_ANON_KEY
                        make project
                        """
                    )
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glidePathGlass(cornerRadius: 14)
                }
            }
            .padding(24)
        }
    }
}
