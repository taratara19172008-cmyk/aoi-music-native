import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var songs: [Song] = []
    @State private var albums: [CollectionItem] = []
    @State private var loaded = false
    @State private var addSong: Song?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("favorites"))
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .padding(.top, 14)
                if !engine.authorized {
                    Text(settings.t("radio_note"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    SectionTitle(text: settings.t("fav_songs"))
                    if songs.isEmpty && loaded {
                        Text(settings.t("no_fav_songs")).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s, index: i, onTap: { player.playSongs(songs, start: i) }, onAdd: { addSong = s })
                    }
                    SectionTitle(text: settings.t("lib_albums"))
                    if albums.isEmpty && loaded {
                        Text(settings.t("empty")).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(albums) { a in
                            CollectionCard(item: a, width: 0)
                                .onTapGesture { nav.detail = .collection(kind: "album", id: a.id) }
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
        .onChange(of: engine.authorized) { _, now in
            if now { Task { await load() } }
        }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
    }

    private func load() async {
        // Do not latch "loaded" before an authorized fetch: this view can appear
        // before the engine finishes authorizing, and it must retry once it does
        // (the onChange above re-runs load when authorization lands).
        guard engine.authorized else { loaded = true; return }
        loaded = true
        let apiSongs = await api.favoriteSongs()
        // Locally persisted loves always show, even before Apple's side syncs.
        var merged = player.favSongs
        let seen = Set(merged.map { $0.playbackId })
        merged += apiSongs.filter { !seen.contains($0.playbackId) }
        songs = merged
        albums = await api.favoriteAlbums()
    }
}
