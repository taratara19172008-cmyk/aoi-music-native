import SwiftUI

struct CollectionView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @Environment(\.dismiss) var dismiss
    var kind: String // album | playlist | lplaylist
    var id: String
    @State private var item: CollectionItem?
    @State private var tracks: [Song] = []
    @State private var loaded = false
    @State private var palette: CoverPalette?
    @State private var showAddSongs = false
    @State private var motionURLStr: String?
    @State private var addSong: Song?
    @State private var shareItem: ShareItem?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var artistId: String?

    var body: some View {
        ZStack {
            // The whole page background grows out of the cover's dominant
            // colours (v105) — no more cover fading into blank pastel.
            LinearGradient(colors: [palette?.top ?? Color(red: 0.93, green: 0.96, blue: 0.99),
                                    palette?.bottom ?? Color(red: 0.98, green: 0.92, blue: 0.95)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Circle()
                .fill((palette?.glow ?? settings.accent).opacity(0.35))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 140, y: -320)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
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
                    Spacer()
                    // v114: her own playlists get a glass + button to
                    // add songs from recents / loved / favorite albums.
                    if kind == "lplaylist" {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .aoiGlass(corner: 20, interactive: true)
                            .contentShape(Rectangle())
                            .onTapGesture { showAddSongs = true }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                if !loaded {
                    ProgressView().padding(.top, 60)
                    Spacer()
                } else if item == nil && tracks.isEmpty {
                    Text(settings.t("empty"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            heroSection
                            if !tracks.isEmpty {
                                // ONE liquid-glass panel for the whole track
                                // list, first song to last (v106) — the hero
                                // and its info card live outside it, on the
                                // palette background. (v105 wrapped the whole
                                // page in one slab that ended mid-list and
                                // boxed the cover in with visible edges.)
                                VStack(spacing: 0) {
                                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, s in
                                        if kind == "lplaylist" {
                                            // Her own playlists: left-swipe
                                            // delete is back (v107), red
                                            // button, same removal the
                                            // long-press menu performs.
                                            SwipeDeleteRow(label: settings.t("del")) { removeTrack(s) } content: {
                                                SongRow(song: s, index: i, onTap: { player.playSongs(tracks, start: i) }, onAdd: { addSong = s }, showShare: true, onRemove: { removeTrack(s) })
                                            }
                                        } else {
                                            SongRow(song: s, index: i, onTap: { player.playSongs(tracks, start: i) }, onAdd: { addSong = s }, showShare: true)
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                                .aoiGlass(corner: 28)
                                .padding(.horizontal, 10)
                            }
                            if kind == "playlist" || kind == "lplaylist" {
                                PlaylistAIRecView(cacheKey: id, seed: tracks)
                                    .padding(.horizontal, 10)
                            }
                            Spacer(minLength: 30)
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            ToastOverlay(text: player.toast)
        }
        .environment(\.colorScheme, palette?.isDark == true ? .dark : .light)
        .task { await load() }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
        .sheet(isPresented: $showAddSongs) {
            AddSongsSheet(playlistId: id,
                          existing: Set(tracks.map { $0.id } + tracks.map { $0.playbackId })) { added in
                tracks.append(contentsOf: added)
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .alert(settings.t("edit_name"), isPresented: $showRename) {
            TextField(settings.t("playlist_name_ph"), text: $renameText)
            Button(settings.t("cancel"), role: .cancel) {}
            Button(settings.t("save")) {
                let n = renameText.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                Task {
                    do {
                        try await api.renamePlaylist(id: id, name: n)
                        player.showToast(settings.t("renamed"))
                        await load(force: true)
                    } catch { player.showToast(settings.t("op_fail")) }
                }
            }
        }
        .confirmationDialog(settings.t("confirm_del"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(settings.t("delete_playlist"), role: .destructive) {
                Task {
                    do {
                        try await api.deletePlaylist(id: id)
                        player.showToast(settings.t("deleted_pl"))
                        dismiss()
                    } catch { player.showToast(settings.t("op_fail")) }
                }
            }
            Button(settings.t("cancel"), role: .cancel) {}
        }
    }

    // v115 (GPT review item 11): every album favorite DISPLAY goes
    // through the identity-aware check, so the button can never
    // read "add" while the tap removes (or the reverse).
    private var albumFaved: Bool {
        if let it = item { return player.isFavAlbumItem(it) }
        return player.isFavAlbum(id)
    }

    @ViewBuilder
    private var heroSection: some View {
        VStack(spacing: 0) {
            heroArtwork
            VStack(spacing: 8) {
            Text(item?.title ?? "")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let sub = item?.sub, !sub.isEmpty {
                if kind == "album", let aid = artistId {
                    // The artist name under an album title jumps to the
                    // artist page (v108, her request).
                    Button { nav.detail = .artist(id: aid) } label: {
                        HStack(spacing: 3) {
                            Text(sub)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(settings.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !tracks.isEmpty {
                Text("\(tracks.count) \(settings.t("tracks_count"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                actionButton(title: "▶ " + settings.t("play_all"), filled: true) {
                    player.playSongs(tracks, start: 0)
                }
                actionButton(title: settings.t("shuffle_play"), filled: false) {
                    if !tracks.isEmpty {
                        player.shuffle = true
                        player.playSongs(tracks, start: Int.random(in: 0..<tracks.count))
                    }
                }
                if kind == "album" {
                    actionButton(title: albumFaved ? settings.t("album_faved") : settings.t("fav_album"), filled: false) {
                        toggleAlbumFav()
                    }
                }
                if kind == "lplaylist" {
                    actionButton(title: settings.t("edit_name"), filled: false) {
                        renameText = item?.title ?? ""
                        showRename = true
                    }
                    actionButton(title: settings.t("delete_playlist"), filled: false, red: true) {
                        showDeleteConfirm = true
                    }
                }
            }
            .padding(.top, 4)
            if let intro = introText {
                Text(intro)
                    .font(.subheadline)
                    .lineSpacing(5)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            }
            .padding(14)
            .aoiGlass(corner: 24)
            .padding(.horizontal, 12)
            .padding(.top, -28)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
        }
    }

    // The cover IS the header background: full-bleed, edge to edge, fading into
    // the page background at the bottom — no boxed frame. Albums with motion
    // artwork play their animated cover here.
    @ViewBuilder
    private var heroArtwork: some View {
        let w = UIScreen.main.bounds.width
        ZStack {
            // v114 melt: the artwork itself dissolves. One shared alpha
            // mask fades the sharp and blurred copies out together,
            // starting above the halfway point and reaching fully
            // transparent before the frame ends - what shows through is
            // the page's own background gradient, so no painted-over
            // bottom colour and no seam line anywhere. (v113 painted
            // palette.bottom OVER the image while the page gradient
            // below was only mid-blend at that height: a guaranteed
            // step at the boundary.)
            // v115 melt (her spec): the cover's body stays SHARP;
            // only a narrow band at the top edge and the bottom
            // edge blurs and fades into the page background. The
            // sharp layer carries the alpha fade; the blurred copy
            // shows through ONLY inside those two bands.
            Group {
                if let m = motionURLStr, let u = URL(string: m) {
                    LoopingVideo(url: u)
                        .frame(width: w, height: w)
                        .mask(heroEdgeMask)
                } else {
                    ZStack {
                        ArtworkImage(urlString: item?.art(800, 800), size: w, corner: 0)
                            .mask(heroEdgeMask)
                        ArtworkImage(urlString: item?.art(800, 800), size: w, corner: 0)
                            .blur(radius: 24)
                            .mask(heroEdgeBlurMask)
                    }
                }
            }
            // Top scrim only (status-bar legibility).
            LinearGradient(
                stops: [
                    .init(color: (palette?.top ?? Color(red: 0.93, green: 0.96, blue: 0.99)).opacity(0.85), location: 0.0),
                    .init(color: .clear, location: 0.16),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .frame(width: w, height: w)
        .clipped()
    }

    private func actionButton(title: String, filled: Bool, red: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(red ? Color(red: 0.88, green: 0.14, blue: 0.24) : (filled ? .white : settings.accent))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(settings.accent)
                    }
                }
                .aoiGlass(corner: 14, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func toggleAlbumFav() {
        // Local-first via the player: the album lands in the Favorites tab the
        // moment she taps, and the ratings write follows behind it.
        guard let it = item else { return }
        player.toggleFavAlbum(it, lang: settings.lang)
    }

    private func removeTrack(_ s: Song) {
        Task {
            do {
                try await api.removeFromPlaylist(pid: id, librarySongId: s.id)
                tracks.removeAll { $0.id == s.id }
                player.showToast(settings.t("removed_from"))
            } catch {
                player.showToast(settings.t("remove_fail"))
            }
        }
    }

    // The album/playlist editorial intro (\u4e13\u8f91\u4ecb\u7ecd\u8bed), shown as a tidy card
    // under the header when Apple provides one.
    private var introText: String? {
        let a = item?.attributes
        let s = (a?.editorialNotes?.standard ?? a?.editorialNotes?.short ?? a?.description?.standard ?? a?.description?.short ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // Resolve the album's artist (for the tappable name in the hero) by
    // searching the artist name — the same fallback pattern the rest of
    // the app uses when a payload carries no artist relationship.
    private func resolveArtist() async {
        guard artistId == nil, let name = item?.sub, !name.isEmpty else { return }
        guard let r = try? await api.search(term: name) else { return }
        let artists = r.results?.artists?.data ?? []
        artistId = (artists.first(where: { $0.title == name }) ?? artists.first)?.id
    }

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        do {
            let (head, tr) = try await api.collectionTracks(kind: kind, id: id)
            item = head
            tracks = tr
        } catch {}
        loaded = true
        palette = await CoverPaletteLoader.load(item?.art(600, 600))
        if kind == "album" || kind == "playlist" {
            motionURLStr = await api.motionURL(kind: kind == "album" ? "albums" : "playlists", id: id)
        }
        if kind == "album" { await resolveArtist() }
        if kind == "album", engine.authorized, let it = item, !player.isFavAlbumItem(it) {
            // Hydrate from Apple's ratings once; a hit joins the local list.
            if await api.rating(kind: "albums", id: id) { player.absorbFavAlbums([it]) }
        }
    }
}
