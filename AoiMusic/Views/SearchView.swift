import SwiftUI

struct SearchView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: AppNav
    @State private var term = ""
    @State private var songs: [Song] = []
    @State private var albums: [CollectionItem] = []
    @State private var artists: [CollectionItem] = []
    @State private var playlists: [CollectionItem] = []
    @State private var searched = false
    @State private var searching = false
    @State private var addSong: Song?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(settings.t("search_ph"), text: $term)
                        .onSubmit { runSearch() }
                        .submitLabel(.search)
                    if !term.isEmpty {
                        Button { term = ""; searched = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .aoiGlass(corner: 22)
                .padding(.top, 14)

                if !searched {
                    if !player.searchHistory.isEmpty {
                        HStack {
                            SectionTitle(text: settings.t("recent_search"))
                            Spacer()
                            Button(settings.t("clear")) { player.clearSearchHistory() }
                                .font(.subheadline)
                                .foregroundStyle(settings.accent)
                                .padding(.top, 18)
                        }
                        ForEach(player.searchHistory) { e in
                            historyRow(e)
                        }
                    }
                } else if searching {
                    ProgressView(settings.t("searching")).frame(maxWidth: .infinity).padding(.top, 40)
                } else if songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty {
                    Text(settings.t("no_results")).foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                } else {
                    if !artists.isEmpty {
                        SectionTitle(text: settings.t("artists"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(artists) { a in
                                    CollectionCard(item: a)
                                        .onTapGesture {
                                            player.recordSearch(.init(kind: "artist", id: a.id, name: a.title, sub: a.sub, art: a.art(160, 160), song: nil))
                                            nav.detail = .artist(id: a.id)
                                        }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                    if !songs.isEmpty {
                        SectionTitle(text: settings.t("songs"))
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s, index: i, onTap: {
                                player.recordSearch(.init(kind: "song", id: s.id, name: s.title, sub: s.artist, art: s.art(160, 160), song: s))
                                player.playSongs(songs, start: i)
                            }, onAdd: { addSong = s })
                        }
                    }
                    if !albums.isEmpty {
                        SectionTitle(text: settings.t("albums"))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(albums) { a in
                                CollectionCard(item: a, width: 0)
                                    .onTapGesture {
                                        player.recordSearch(.init(kind: "album", id: a.id, name: a.title, sub: a.sub, art: a.art(160, 160), song: nil))
                                        nav.detail = .collection(kind: "album", id: a.id)
                                    }
                            }
                        }
                    }
                    if !playlists.isEmpty {
                        SectionTitle(text: settings.t("playlists"))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(playlists) { p in
                                CollectionCard(item: p, width: 0)
                                    .onTapGesture {
                                        player.recordSearch(.init(kind: "playlist", id: p.id, name: p.title, sub: p.sub, art: p.art(160, 160), song: nil))
                                        nav.detail = .collection(kind: "playlist", id: p.id)
                                    }
                            }
                        }
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
    }

    private func historyRow(_ e: SearchEntity) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(urlString: e.art, size: 46, corner: e.kind == "artist" ? 23 : 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(e.sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            switch e.kind {
            case "song": if let s = e.song { player.playSongs([s], start: 0) }
            case "album": nav.detail = .collection(kind: "album", id: e.id)
            case "playlist": nav.detail = .collection(kind: "playlist", id: e.id)
            case "artist": nav.detail = .artist(id: e.id)
            default: break
            }
        }
    }

    private func runSearch() {
        let q = term.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        searched = true
        Task {
            do {
                let r = try await api.search(term: q)
                songs = r.results?.songs?.data ?? []
                albums = r.results?.albums?.data ?? []
                artists = r.results?.artists?.data ?? []
                playlists = r.results?.playlists?.data ?? []
            } catch {
                songs = []; albums = []; artists = []; playlists = []
            }
            searching = false
        }
    }
}
