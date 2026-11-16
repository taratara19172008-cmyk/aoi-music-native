import SwiftUI

struct ArtistView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @Environment(\.dismiss) var dismiss
    var artistId: String
    @State private var detail: ArtistDetailResponse.ArtistDetail?
    @State private var loaded = false
    @State private var artistFav = false
    @State private var addSong: Song?
    @State private var artistMotion: String?
    @State private var videos: [MVItem] = []
    @State private var playMV: MVItem?
    @State private var palette: CoverPalette?

    var body: some View {
        ZStack {
            // v106: the page background grows out of the artist photo's own
            // colours (same treatment as album/playlist pages), and the
            // photo melts into it — no hard seam anywhere.
            ZStack {
                LinearGradient(colors: [palette?.top ?? Color(red: 0.93, green: 0.96, blue: 0.99), palette?.bottom ?? Color(red: 0.98, green: 0.92, blue: 0.95)], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill((palette?.glow ?? Color(red: 0.45, green: 0.75, blue: 0.95)).opacity(0.38))
                    .frame(width: 300, height: 300)
                    .blur(radius: 80)
                    .offset(x: 120, y: -240)
            }
            .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let d = detail {
                        heroBanner(d)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button {
                                    toggleArtistFav()
                                } label: {
                                    Text(artistFav ? settings.t("artist_faved") : settings.t("fav_artist"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(settings.accent)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .aoiGlass(corner: 14, interactive: true)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                            }
                            .padding(.top, 10)
                            if let tops = d.views?.topSongs?.data, !tops.isEmpty {
                                GlassSection(title: settings.t("top_songs_a")) {
                                    ForEach(Array(tops.enumerated()), id: \.element.id) { i, s in
                                        SongRow(song: s, index: i, onTap: { player.playSongs(tops, start: i) }, onAdd: { addSong = s })
                                    }
                                }
                            }
                            if let albums = d.views?.albums?.data ?? d.relationships?.albums?.data, !albums.isEmpty {
                                GlassSection(title: settings.t("albums")) {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 14) {
                                            ForEach(albums) { a in
                                                CollectionCard(item: a, onOpenCard: { nav.detail = .collection(kind: "album", id: a.id) })
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                            }
                            if !videos.isEmpty {
                                GlassSection(title: settings.t("music_videos")) {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(alignment: .top, spacing: 14) {
                                            ForEach(videos) { v in
                                                mvCard(v)
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                            }
                            if let pls = d.views?.playlists?.data ?? d.relationships?.playlists?.data, !pls.isEmpty {
                                GlassSection(title: settings.t("playlists")) {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 14) {
                                            ForEach(pls) { p in
                                                CollectionCard(item: p, onOpenCard: { nav.detail = .collection(kind: "playlist", id: p.id) })
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                            }
                            if let sims = d.views?.similarArtists?.data, !sims.isEmpty {
                                GlassSection(title: settings.t("similar")) {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 14) {
                                            ForEach(sims) { a in
                                                CollectionCard(item: a, onOpenCard: { nav.detail = .artist(id: a.id) })
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    Spacer(minLength: 40)
                }
            }
            .scrollIndicators(.hidden)
            VStack {
                HStack {
                    backPill
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
            }
            ToastOverlay(text: player.toast)
        }
        .frame(width: UIScreen.main.bounds.width)
        .environment(\.colorScheme, palette?.isDark == true ? .dark : .light)
        .task { await load() }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
        .fullScreenCover(item: $playMV) { v in
            if let ps = v.previewURL, let u = URL(string: ps) {
                MVPlayerView(url: u)
            }
        }
    }

    // Like the original: the artist photo (or its motion version) fills the top
    // of the page edge to edge, the name sits on the photo, and the photo melts
    // into the page background at the bottom. No frame.
    private func heroBanner(_ d: ArtistDetailResponse.ArtistDetail) -> some View {
        let w = UIScreen.main.bounds.width
        return ZStack(alignment: .bottomLeading) {
            if let m = artistMotion, let u = URL(string: m) {
                LoopingVideo(url: u)
                    .frame(width: w, height: 360)
            } else if let urlStr = d.attributes?.artwork?.urlString(1200, 1000), let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.white.opacity(0.3)
                    }
                }
                .frame(width: w, height: 360)
                .clipped()
            } else {
                Color.white.opacity(0.3)
                    .frame(width: w, height: 360)
            }
            LinearGradient(
                stops: [
                    .init(color: (palette?.top ?? Color(red: 0.93, green: 0.96, blue: 0.99)).opacity(0.85), location: 0.0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.34),
                    .init(color: .black.opacity(0.34), location: 0.64),
                    .init(color: (palette?.bottom ?? Color(red: 0.98, green: 0.92, blue: 0.95)).opacity(0.45), location: 0.80),
                    .init(color: (palette?.bottom ?? Color(red: 0.98, green: 0.92, blue: 0.95)).opacity(0.80), location: 0.92),
                    .init(color: palette?.bottom ?? Color(red: 0.98, green: 0.92, blue: 0.95), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
            Text(d.attributes?.name ?? "")
                .font(.system(size: 28, weight: .bold))
                .lineLimit(2)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
        }
        .frame(width: w, height: 360)
        .clipped()
    }

    private func mvCard(_ v: MVItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Color.white.opacity(0.35)
                if let a = v.art(480, 270), let url = URL(string: a) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.clear
                        }
                    }
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 4)
            }
            .frame(width: 200, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(v.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: 200, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { playMV = v }
    }

    private var backPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            Text(settings.t("back")).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .aoiGlass(corner: 20)
        .contentShape(Rectangle())
        .onTapGesture { nav.detail = nil }
    }

    private func toggleArtistFav() {
        guard engine.authorized else { player.showToast(settings.t("need_acct_fav")); return }
        let was = artistFav
        artistFav = !was
        Task {
            do {
                if was { try await api.rateDelete(kind: "artists", id: artistId); player.showToast(settings.t("unfaved")) }
                else { try await api.rateWrite(kind: "artists", id: artistId); player.showToast(settings.t("faved")) }
            } catch {
                artistFav = was
                player.showToast(settings.t("fav_fail"))
            }
        }
    }

    private func load() async {
        if loaded { return }
        loaded = true
        detail = try? await api.artistDetail(id: artistId)
        palette = await CoverPaletteLoader.load(detail?.attributes?.artwork?.urlString(600, 600))
        videos = await api.artistVideos(id: artistId)
        artistMotion = await api.motionURL(kind: "artists", id: artistId)
        if engine.authorized {
            artistFav = await api.rating(kind: "artists", id: artistId)
        }
    }
}
