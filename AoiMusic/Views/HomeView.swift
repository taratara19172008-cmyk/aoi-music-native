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
        return Array((local + appleHistory.filter { !seen.contains($0.id) }).prefix(10))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .padding(.top, 14)
                Text(failed ? settings.t("home_fail") : settings.t("home_sub"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !featPlaylists.isEmpty {
                    SectionTitle(text: settings.t("feat_playlists"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(featPlaylists) { p in
                                CollectionCard(item: p)
                                    .onTapGesture { nav.detail = .collection(kind: "playlist", id: p.id) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                if !topSongs.isEmpty {
                    SectionTitle(text: settings.t("top_songs"))
                    ForEach(Array(topSongs.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s, index: i, onTap: { player.playSongs(topSongs, start: i) }, onAdd: { addSong = s })
                    }
                }
                if !topAlbums.isEmpty {
                    SectionTitle(text: settings.t("top_albums"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(topAlbums) { a in
                                CollectionCard(item: a)
                                    .onTapGesture { nav.detail = .collection(kind: "album", id: a.id) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                if !mergedHistory.isEmpty {
                    SectionTitle(text: settings.t("recent_played"))
                    ForEach(Array(mergedHistory.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s, index: i, onTap: { player.playSongs(mergedHistory, start: i) }, onAdd: { addSong = s })
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
            if let recs = try? await api.recommendations() {
                let pls = recs.filter { $0.type == "playlists" }
                let seen = Set(featPlaylists.map { $0.id })
                featPlaylists = pls.filter { !seen.contains($0.id) } + featPlaylists
            }
        }
    }
}
