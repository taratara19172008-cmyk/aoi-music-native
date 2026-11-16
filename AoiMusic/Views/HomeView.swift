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
    @State private var recSongs: [Song] = []
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
    private var colW: CGFloat { UIScreen.main.bounds.width - 100 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 14)
                Text(failed ? settings.t("home_fail") : settings.t("home_sub"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !featPlaylists.isEmpty {
                    GlassSection(title: settings.t("rec_playlists")) {
                        shelf(featPlaylists) { item in tap(item) }
                    }
                }
                if !recSongs.isEmpty {
                    GlassSection(title: settings.t("rec_songs")) {
                        songRail(recSongs)
                    }
                }
                if !topSongs.isEmpty {
                    GlassSection(title: settings.t("top_songs")) {
                        songRail(topSongs)
                    }
                }
                if !topAlbums.isEmpty {
                    GlassSection(title: settings.t("top_albums")) {
                        shelf(topAlbums) { a in nav.detail = .collection(kind: "album", id: a.id) }
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    GlassSection(title: g.title.isEmpty ? settings.t("feat_playlists") : g.title) {
                        shelf(g.items) { item in tap(item) }
                    }
                }
                if !mergedHistory.isEmpty {
                    GlassSection(title: settings.t("recent_played")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(mergedHistory.enumerated()), id: \.element.id) { i, s in
                                songCard(s) { player.playSongs(mergedHistory, start: i) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    }
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

    private func songRail(_ songs: [Song]) -> some View {
        // Deterministic chunked columns, same as the Library rails (v105) —
        // no LazyHGrid measurement surprises.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(stride(from: 0, to: songs.count, by: 3)), id: \.self) { start in
                    VStack(spacing: 6) {
                        ForEach(Array(songs[start..<min(start + 3, songs.count)].enumerated()), id: \.element.id) { off, s in
                            SongRow(song: s, index: start + off, onTap: { player.playSongs(songs, start: start + off) }, onAdd: { addSong = s }, rail: true)
                                .frame(width: colW)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func songCard(_ s: Song, tap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ArtworkImage(urlString: s.art(300, 300), size: 118, corner: 12)
            Text(s.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text(s.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
            recSongs = await api.recommendationSongs()
        }
    }
}
