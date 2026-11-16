import SwiftUI

struct HomeView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var topSongs: [Song] = []
    @State private var topAlbums: [CollectionItem] = []
    @State private var featPlaylists: [CollectionItem] = []
    @State private var groups: [(title: String, items: [CollectionItem])] = []
    @State private var appleHistory: [Song] = []
    @State private var failed = false
    @State private var loaded = false
    @State private var addSong: Song?

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 0..<6: return settings.t("good_night")
        case 6..<12: return settings.t("good_morning")
        case 12..<18: return settings.t("good_afternoon")
        default: return settings.t("good_evening")
        }
    }
    private var mergedHistory: [Song] {
        let local = player.history
        let seen = Set(local.map { $0.id })
        return Array((local + appleHistory.filter { !seen.contains($0.id) }).prefix(12))
    }
    private var colW: CGFloat { UIScreen.main.bounds.width - 138 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .padding(.top, 14)
                Text(failed ? settings.t("home_fail") : settings.t("home_sub"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !mergedHistory.isEmpty {
                    SectionTitle(text: settings.t("recent_played"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(mergedHistory.enumerated()), id: \.element.id) { i, s in
                                songCard(s) { player.playSongs(mergedHistory, start: i) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    SectionTitle(text: g.title.isEmpty ? settings.t("feat_playlists") : g.title)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(g.items) { item in
                                CollectionCard(item: item)
                                    .onTapGesture { tap(item) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                if !topSongs.isEmpty {
                    SectionTitle(text: settings.t("top_songs"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(60), spacing: 6), count: 3), spacing: 14) {
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { i, s in
                                SongRow(song: s, index: i, onTap: { player.playSongs(topSongs, start: i) }, onAdd: { addSong = s })
                                    .frame(width: colW)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !topAlbums.isEmpty {
                    SectionTitle(text: settings.t("top_albums"))
                    shelf(topAlbums) { a in nav.detail = .collection(kind: "album", id: a.id) }
                }
                if !featPlaylists.isEmpty {
                    SectionTitle(text: settings.t("feat_playlists"))
                    shelf(featPlaylists) { p in nav.detail = .collection(kind: "playlist", id: p.id) }
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
    }

    private func shelf(_ items: [CollectionItem], tap: @escaping (CollectionItem) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    CollectionCard(item: item)
                        .onTapGesture { tap(item) }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func songCard(_ s: Song, tap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ArtworkImage(urlString: s.art(300, 300), size: 118, corner: 12)
            Text(s.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(s.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 118, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
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
        do {
            let r = try await api.charts()
            topSongs = r.results?.songs?.data ?? []
            topAlbums = r.results?.albums?.data ?? []
            featPlaylists = r.results?.playlists?.data ?? []
            failed = false
        } catch { failed = true }
        loaded = true
        if engine.authorized {
            appleHistory = (try? await api.recentPlayed()) ?? []
            groups = await api.recommendationGroups()
        }
    }
}
