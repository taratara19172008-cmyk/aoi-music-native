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
                    .font(.system(size: 30, weight: .bold))
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
                    GlassSection {
                        railGrid(playlists) { p in
                            libRow(p, kind: "lplaylist") { nav.detail = .collection(kind: "lplaylist", id: p.id) }
                        }
                    }
                    if !songs.isEmpty {
                        GlassSection(title: settings.t("lib_songs")) {
                            songRail(songs)
                        }
                    }
                    if !artists.isEmpty {
                        GlassSection(title: settings.t("lib_artists")) {
                            railGrid(artists) { a in
                                libRow(a, artist: true, kind: "artist") { nav.detail = .artist(id: a.id) }
                            }
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

    private var colW: CGFloat { UIScreen.main.bounds.width - 100 }

    // Deterministic 3-row rails (v105): chunked columns in a plain HStack.
    // The old LazyHGrid measured itself against the page's leftover height,
    // which is what scattered the artists down the page with a huge blank
    // gap under the title. Fixed chunks cannot drift.
    private func railGrid(_ items: [CollectionItem], cell: @escaping (CollectionItem) -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                    VStack(spacing: 8) {
                        ForEach(items[start..<min(start + 3, items.count)]) { item in
                            cell(item)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func songRail(_ songs: [Song]) -> some View {
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

    private func libRow(_ item: CollectionItem, artist: Bool = false, kind: String = "", tap: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            if artist && item.art(120, 120) == nil {
                // No catalog photo for this artist: a tinted initial medallion
                // instead of the bare note placeholder.
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [settings.accent.opacity(0.8), settings.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(String(item.title.prefix(1)))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
            } else {
                ArtworkImage(urlString: item.art(120, 120), size: 46, corner: artist ? 23 : 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: item.title,
                            font: .subheadline.weight(.medium),
                            uiFont: .systemFont(ofSize: 15, weight: .medium))
                if !item.sub.isEmpty {
                    MarqueeText(text: item.sub,
                                font: .caption,
                                uiFont: .systemFont(ofSize: 12),
                                color: .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: colW, height: 64, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .contextMenu {
            Button { tap() } label: { Label(settings.t("open"), systemImage: "arrow.up.forward.square") }
            if kind == "lplaylist" {
                Button { player.playCollection(item, kind: "lplaylist") } label: { Label(settings.t("play_all"), systemImage: "play.fill") }
            }
        } preview: {
            CollectionPreview(item: item)
        }
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
