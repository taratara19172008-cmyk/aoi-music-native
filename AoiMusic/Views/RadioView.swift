import SwiftUI

struct RadioView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var stations: [CollectionItem] = []
    @State private var playlists: [CollectionItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("radio"))
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .padding(.top, 14)
                if !engine.authorized {
                    Text(settings.t("radio_note"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                if stations.isEmpty && playlists.isEmpty && loaded {
                    Text(settings.t("empty")).foregroundStyle(.secondary).padding(.top, 30)
                }
                if !stations.isEmpty {
                    SectionTitle(text: settings.t("official_stations"))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(stations) { item in
                            CollectionCard(item: item, width: 0)
                                .onTapGesture { tap(item) }
                        }
                    }
                    .padding(.top, 4)
                }
                if !playlists.isEmpty {
                    SectionTitle(text: settings.t("feat_playlists"))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(playlists) { item in
                            CollectionCard(item: item, width: 0)
                                .onTapGesture { tap(item) }
                        }
                    }
                    .padding(.top, 4)
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
    }

    private func tap(_ item: CollectionItem) {
        if item.type == "stations" {
            guard engine.authorized else { player.showToast(settings.t("radio_need")); return }
            player.playStation(item)
        } else {
            nav.detail = .collection(kind: "playlist", id: item.id)
        }
    }

    private func load() async {
        if loaded { return }
        loaded = true
        if engine.authorized {
            let recs = (try? await api.recommendations()) ?? []
            stations = recs.filter { $0.type == "stations" }
            playlists = recs.filter { $0.type == "playlists" }
        }
        if let r = try? await api.charts() {
            let chartPls = r.results?.playlists?.data ?? []
            let seen = Set(playlists.map { $0.id })
            playlists += chartPls.filter { !seen.contains($0.id) }
        }
    }
}
