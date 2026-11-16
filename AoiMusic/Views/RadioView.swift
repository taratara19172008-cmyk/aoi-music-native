import SwiftUI

struct RadioView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var items: [CollectionItem] = []
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
                if items.isEmpty && loaded {
                    Text(settings.t("empty")).foregroundStyle(.secondary).padding(.top, 30)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(items) { item in
                        CollectionCard(item: item, width: 160)
                            .onTapGesture { tap(item) }
                    }
                }
                .padding(.top, 10)
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
            items = (try? await api.recommendations()) ?? []
        }
        if items.isEmpty {
            // fallback: chart playlists, like the web version's signed-out radio page
            if let r = try? await api.charts() {
                items = r.results?.playlists?.data ?? []
            }
        }
    }
}
