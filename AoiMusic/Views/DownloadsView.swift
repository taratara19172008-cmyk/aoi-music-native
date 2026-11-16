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
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
    }

    private func load() async {
        if loaded { return }
        loaded = true
        guard engine.authorized else { return }
        songs = await api.favoriteSongs()
        albums = (try? await api.libraryAlbums()) ?? []
    }
}
