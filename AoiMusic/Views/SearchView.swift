import SwiftUI

struct SearchView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: AppNav
    @Binding var term: String
    @State private var searchSeq = 0
    @State private var songs: [Song] = []
    @State private var albums: [CollectionItem] = []
    @State private var artists: [CollectionItem] = []
    @State private var playlists: [CollectionItem] = []
    @State private var searched = false
    @State private var searching = false
    @State private var addSong: Song?

    var body: some View {
        // v118 (B1): the field itself is NOT in this layout flow any
        // more - after the v115 in-flow attempt and the v116 root
        // shield both failed on device, the field now lives in a
        // RootView overlay pinned to the top safe area (see
        // SearchFieldView below and RootView). This clear spacer
        // reserves exactly its height so results start where they
        // always did.
        VStack(spacing: 10) {
            Color.clear
                .frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {

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
                        GlassSection {
                            ForEach(player.searchHistory) { e in
                                historyRow(e)
                            }
                        }
                    }
                } else if searching {
                    ProgressView(settings.t("searching")).frame(maxWidth: .infinity).padding(.top, 40)
                } else if songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty {
                    Text(settings.t("no_results")).foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                } else {
                    if !artists.isEmpty {
                        GlassSection(title: settings.t("artists")) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(artists) { a in
                                        CollectionCard(item: a, onOpenCard: {
                                            player.recordSearch(.init(kind: "artist", id: a.id, name: a.title, sub: a.sub, art: a.art(160, 160), song: nil))
                                            nav.detail = .artist(id: a.id)
                                        })
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                    }
                    if !songs.isEmpty {
                        GlassSection(title: settings.t("songs")) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                                SongRow(song: s, index: i, onTap: {
                                    player.recordSearch(.init(kind: "song", id: s.id, name: s.title, sub: s.artist, art: s.art(160, 160), song: s))
                                    player.playSongs(songs, start: i)
                                }, onAdd: { addSong = s })
                            }
                        }
                    }
                    if !albums.isEmpty {
                        GlassSection(title: settings.t("albums")) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                ForEach(albums) { a in
                                    CollectionCard(item: a, width: 0, onOpenCard: {
                                        player.recordSearch(.init(kind: "album", id: a.id, name: a.title, sub: a.sub, art: a.art(160, 160), song: nil))
                                        nav.detail = .collection(kind: "album", id: a.id)
                                    })
                                }
                            }
                        }
                    }
                    if !playlists.isEmpty {
                        GlassSection(title: settings.t("playlists")) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                ForEach(playlists) { p in
                                    CollectionCard(item: p, width: 0, onOpenCard: {
                                        player.recordSearch(.init(kind: "playlist", id: p.id, name: p.title, sub: p.sub, art: p.art(160, 160), song: nil))
                                        nav.detail = .collection(kind: "playlist", id: p.id)
                                    })
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
        }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
        .onReceive(NotificationCenter.default.publisher(for: .aoiRunSearch)) { _ in runSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .aoiClearSearch)) { _ in searched = false }
    }

    private func openHistory(_ e: SearchEntity) {
        switch e.kind {
        case "song": if let s = e.song { player.playSongs([s], start: 0) }
        case "album": nav.detail = .collection(kind: "album", id: e.id)
        case "playlist": nav.detail = .collection(kind: "playlist", id: e.id)
        case "artist": nav.detail = .artist(id: e.id)
        default: break
        }
    }

    private func historyRow(_ e: SearchEntity) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(urlString: e.art, size: 46, corner: e.kind == "artist" ? 23 : 8)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: e.name,
                            font: .subheadline.weight(.semibold),
                            uiFont: .systemFont(ofSize: 15, weight: .semibold))
                MarqueeText(text: e.sub,
                            font: .caption,
                            uiFont: .systemFont(ofSize: 12),
                            color: .secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { openHistory(e) }
        .contextMenu {
            Button { openHistory(e) } label: {
                Label(settings.t(e.kind == "song" ? "play" : "open"), systemImage: e.kind == "song" ? "play.fill" : "arrow.up.forward.square")
            }
        } preview: {
            VStack(spacing: 10) {
                ArtworkImage(urlString: e.art, size: 216, corner: e.kind == "artist" ? 108 : 16)
                VStack(spacing: 2) {
                    Text(e.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                    Text(e.sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            .frame(width: 248)
        }
    }

    private func runSearch() {
        let q = term.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchSeq += 1
        let seq = searchSeq
        searching = true
        searched = true
        Task {
            do {
                let r = try await api.search(term: q)
                guard seq == searchSeq else { return }
                songs = r.results?.songs?.data ?? []
                albums = r.results?.albums?.data ?? []
                artists = r.results?.artists?.data ?? []
                playlists = r.results?.playlists?.data ?? []
            } catch {
                guard seq == searchSeq else { return }
                songs = []; albums = []; artists = []; playlists = []
            }
            if seq == searchSeq { searching = false }
        }
    }
}


extension Notification.Name {
    static let aoiRunSearch = Notification.Name("aoiRunSearch")
    static let aoiClearSearch = Notification.Name("aoiClearSearch")
}

// v118 (B1): the search field, hosted by RootView as an overlay
// pinned to the top safe area while the search page is up. Two
// rounds of in-flow placement (v115, v116) still rode up with the
// keyboard on device; as an out-of-flow sibling anchored like the
// Shazam button overlay - which never moved - it cannot be shoved
// by the page's own layout. Submit/clear reach SearchView through
// notifications so the results state stays where it lives.
struct SearchFieldView: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var term: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(settings.t("search_ph"), text: $term)
                .onSubmit { NotificationCenter.default.post(name: .aoiRunSearch, object: nil) }
                .submitLabel(.search)
            if !term.isEmpty {
                Button {
                    term = ""
                    NotificationCenter.default.post(name: .aoiClearSearch, object: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .aoiGlass(corner: 22)
    }
}
