import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var loaded = false
    @State private var loading = false
    @State private var addSong: Song?

    // The sections render the player's local lists directly: loves made on
    // this device appear the instant the tab opens, and remote results merge
    // in live when they land (no one-shot snapshot that can latch empty).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("favorites"))
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 14)
                if !engine.authorized {
                    Text(settings.t("radio_note"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    GlassSection(title: settings.t("fav_songs")) {
                        if player.favSongs.isEmpty {
                            Text(loaded ? settings.t("no_fav_songs") : settings.t("loading"))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(Array(player.favSongs.enumerated()), id: \.element.id) { i, s in
                                SongRow(song: s, index: i, onTap: { player.playSongs(player.favSongs, start: i) }, onAdd: { addSong = s })
                            }
                        }
                    }
                    GlassSection(title: settings.t("lib_albums")) {
                        if player.favAlbums.isEmpty {
                            Text(loaded ? settings.t("empty") : settings.t("loading"))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                ForEach(player.favAlbums) { a in
                                    CollectionCard(item: a, width: 0)
                                        .onTapGesture { nav.detail = .collection(kind: "album", id: a.id) }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                if loading && player.favSongs.isEmpty && player.favAlbums.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
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
        guard engine.authorized, !loading else { return }
        loading = true
        // Local loves are already on screen via player.favSongs/favAlbums;
        // the network fetch only supplements them.
        let apiSongs = await api.favoriteSongs()
        player.absorbFavSongs(apiSongs)
        let apiAlbums = await api.favoriteAlbums()
        player.absorbFavAlbums(apiAlbums)
        loading = false
        loaded = true
    }
}
