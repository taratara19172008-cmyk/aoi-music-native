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

    private let gridCols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

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
                    LazyVGrid(columns: gridCols, spacing: 16) {
                        ForEach(stations) { item in
                            stationCard(item)
                        }
                    }
                }
                if !playlists.isEmpty {
                    SectionTitle(text: settings.t("feat_playlists"))
                    LazyVGrid(columns: gridCols, spacing: 16) {
                        ForEach(playlists) { item in
                            CollectionCard(item: item, width: 0)
                                .onTapGesture { tap(item) }
                        }
                    }
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

    private func stationCard(_ item: CollectionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                if let u = item.art(480, 300), let url = URL(string: u) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "radio")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "radio")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !item.sub.isEmpty {
                Text(item.sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { tap(item) }
    }

    private func tap(_ item: CollectionItem) {
        switch item.type {
        case "stations":
            guard engine.authorized else { player.showToast(settings.t("radio_need")); return }
            player.playStation(item)
        case "albums":
            nav.detail = .collection(kind: "album", id: item.id)
        case "playlists":
            nav.detail = .collection(kind: "playlist", id: item.id)
        default:
            player.showToast(settings.t("np_goto_fail"))
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
