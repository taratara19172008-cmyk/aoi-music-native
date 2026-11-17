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
                                // Left-swipe delete (v107): the red
                                // button takes the song out of Favorites.
                                SwipeDeleteRow(label: settings.t("del")) { player.toggleFav(s, lang: settings.lang) } content: {
                                    SongRow(song: s, index: i, onTap: { player.playSongs(player.favSongs, start: i) }, onAdd: { addSong = s })
                                }
                            }
                        }
                    }
                    GlassSection(title: settings.t("lib_albums")) {
                        if player.favAlbums.isEmpty {
                            Text(loaded ? settings.t("empty") : settings.t("loading"))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            albumRail(player.favAlbums)
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

    private var colW: CGFloat { UIScreen.main.bounds.width - 100 }

    // v113: favorite albums ride the same deterministic 3-row rail
    // as the Library (her standing layout for collections) instead
    // of the old two-column grid.
    private func albumRail(_ albums: [CollectionItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(stride(from: 0, to: albums.count, by: 3)), id: \.self) { start in
                    VStack(spacing: 8) {
                        ForEach(albums[start..<min(start + 3, albums.count)]) { a in
                            albumRow(a)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func albumRow(_ a: CollectionItem) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(urlString: a.art(120, 120), size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: a.title,
                            font: .subheadline.weight(.medium),
                            uiFont: .systemFont(ofSize: 15, weight: .medium))
                if !a.sub.isEmpty {
                    MarqueeText(text: a.sub,
                                font: .caption,
                                uiFont: .systemFont(ofSize: 12),
                                color: .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: colW, height: 64, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { nav.detail = .collection(kind: "album", id: a.id) }
        .contextMenu {
            Button { nav.detail = .collection(kind: "album", id: a.id) } label: { Label(settings.t("open"), systemImage: "arrow.up.forward.square") }
            Button { player.playCollection(a, kind: "album") } label: { Label(settings.t("play_all"), systemImage: "play.fill") }
            Button { player.toggleFavAlbum(a, lang: settings.lang) } label: {
                Label(settings.t("fav_remove"), systemImage: "heart.slash")
            }
        } preview: {
            CollectionPreview(item: a)
        }
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
