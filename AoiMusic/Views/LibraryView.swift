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
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(playlists) { p in
                            CollectionCard(item: p, width: 160)
                                .onTapGesture { nav.detail = .collection(kind: "lplaylist", id: p.id) }
                        }
                    }
                    if !songs.isEmpty {
                        SectionTitle(text: settings.t("lib_songs"))
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s, index: i, onTap: { player.playSongs(songs, start: i) }, onAdd: { addSong = s })
                        }
                    }
                    if !artists.isEmpty {
                        SectionTitle(text: settings.t("lib_artists"))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(artists) { a in
                                CollectionCard(item: a, width: 160)
                                    .onTapGesture { nav.detail = .artist(id: a.id) }
                            }
                        }
                    }
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
        .sheet(isPresented: $showCreate) { CreatePlaylistSheet { Task { await reload() } } }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
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
    }
}
