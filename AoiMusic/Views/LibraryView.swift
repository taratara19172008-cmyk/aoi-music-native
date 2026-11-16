import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var playlists: [CollectionItem] = []
    @State private var songs: [Song] = []
    @State private var artists: [CollectionItem] = []
    @State private var albums: [CollectionItem] = []
    @State private var loaded = false
    @State private var showCreate = false
    @State private var addSong: Song?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("library"))
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .padding(.top, 14)
                if !engine.authorized {
                    Text(settings.t("radio_note"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    HStack {
                        SectionTitle(text: settings.t("my_playlists"))
                        Spacer()
                        Button {
                            showCreate = true
                        } label: {
                            Label(settings.t("new_playlist"), systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(settings.accent)
                        .padding(.top, 18)
                    }
                    hGrid(playlists) { p in
                        libRow(p) { nav.detail = .collection(kind: "lplaylist", id: p.id) }
                    }
                    if !albums.isEmpty {
                        SectionTitle(text: settings.t("lib_albums"))
                        hGrid(albums) { a in
                            libRow(a) { nav.detail = .collection(kind: "album", id: a.id) }
                        }
                    }
                    if !songs.isEmpty {
                        SectionTitle(text: settings.t("lib_songs"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: Array(repeating: GridItem(.fixed(60), spacing: 6), count: 3), spacing: 14) {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                                    SongRow(song: s, index: i, onTap: { player.playSongs(songs, start: i) }, onAdd: { addSong = s })
                                        .frame(width: colW)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if !artists.isEmpty {
                        SectionTitle(text: settings.t("lib_artists"))
                        hGrid(artists) { a in
                            libRow(a, artist: true) { nav.detail = .artist(id: a.id) }
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
        .sheet(isPresented: $showCreate) { CreatePlaylistSheet { Task { await reload() } } }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
    }

    private var colW: CGFloat { UIScreen.main.bounds.width - 138 }

    private func hGrid(_ items: [CollectionItem], cell: @escaping (CollectionItem) -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 3), spacing: 14) {
                ForEach(items) { item in cell(item) }
            }
            .padding(.vertical, 4)
        }
    }

    private func libRow(_ item: CollectionItem, artist: Bool = false, tap: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(urlString: item.art(120, 120), size: 46, corner: artist ? 23 : 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !item.sub.isEmpty {
                    Text(item.sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: colW, height: 58, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
    }

    private func load() async {
        if loaded { return }
        loaded = true
        await reload()
    }
    private func reload() async {
        guard engine.authorized else { return }
        playlists = (try? await api.libraryPlaylists()) ?? []
        songs = (try? await api.librarySongs()) ?? []
        artists = (try? await api.libraryArtists()) ?? []
        albums = (try? await api.libraryAlbums()) ?? []
    }
}
