import SwiftUI
import WebKit
import AVKit

struct EngineHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ArtworkImage: View {
    var urlString: String?
    var size: CGFloat = 52
    var corner: CGFloat = 10
    var body: some View {
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.white.opacity(0.35)
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Marquee text (v107 rewrite)
// Her rules: titles never truncate, never shrink, at most two lines, and
// rows stay uniform. v106 measured its slot through a background
// GeometryReader attached to a group that ALSO contained the scrolling
// text — in list rows the measured width never matched the final slot
// (so it sat in the static branch and truncated with hyphens/ellipses),
// while on open pages the fixedSize scrolling text took part in layout
// and stretched the whole page wider than the screen. Now the layout
// footprint is a plain static Text and nothing else; the width is
// measured on that footprint alone, and the scrolling copy lives in an
// overlay — which by definition cannot change the layout size — clipped
// to the slot, moving only inside it.
struct MarqueeText: View {
    var text: String
    var font: Font
    var uiFont: UIFont
    var color: Color = .primary
    var maxLines: Int = 2
    @State private var slotW: CGFloat = 0
    @State private var offsetX: CGFloat = 0
    // Measurement cache (v108): `fits`/`travel` used to re-run NSString
    // text measurement on EVERY render of EVERY row — and the player
    // publishes progress twice a second, re-rendering the whole tree.
    // That steady main-thread tax is a prime suspect in her "老卡死"
    // report. Measure once per (text, slot width); renders read the cache.
    @State private var fitsCached: Bool = true
    @State private var travelCached: CGFloat = 0

    private var intrinsicW: CGFloat { (text as NSString).size(withAttributes: [.font: uiFont]).width }

    // Fits = renders inside the slot within maxLines lines WITHOUT the
    // system breaking a word: one latin word wider than the slot would
    // come back hyphenated ("Work-ing"), which she banned — those titles
    // scroll instead. (CJK wraps per character, so the height test alone
    // decides there.)
    private var fits: Bool {
        guard slotW > 1 else { return true }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: slotW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: uiFont], context: nil)
        guard rect.height <= uiFont.lineHeight * CGFloat(maxLines) + 2 else { return false }
        for word in text.split(whereSeparator: { $0 == " " || $0 == "·" }) {
            let w = String(word)
            if w.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) { continue }
            if (w as NSString).size(withAttributes: [.font: uiFont]).width > slotW { return false }
        }
        return true
    }
    private var travel: CGFloat { max(intrinsicW - slotW + 44, 0) }
    private var taskKey: String { "\(text)|\(Int(slotW))" }

    private func measure() {
        fitsCached = fits
        travelCached = travel
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(maxLines)
            .multilineTextAlignment(.leading)
            .opacity(fitsCached ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { slotW = g.size.width; measure() }
                        .onChange(of: g.size.width) { _, w in slotW = w; measure() }
                        .onChange(of: text) { _, _ in measure() }
                }
            }
            .overlay(alignment: .topLeading) {
                if !fitsCached {
                    ZStack(alignment: .leading) {
                        Text(text)
                            .font(font)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: offsetX)
                    }
                    .frame(width: max(slotW, 1), height: uiFont.lineHeight + 4, alignment: .leading)
                    .clipped()
                    .task(id: taskKey) { await scrollLoop() }
                }
            }
            // v113: the first measurement can land mid-transition
            // (detail pages slide in), caching a wrong "fits" that
            // left over-long titles ellipsized instead of scrolling -
            // the unfixed Top Songs ellipsis. Re-measure once the
            // layout has settled.
            .task(id: taskKey) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                measure()
            }
    }

    private func scrollLoop() async {
        while !Task.isCancelled {
            offsetX = 0
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if Task.isCancelled { return }
            let d = Double(travelCached) / 26.0
            if d <= 0 { return }
            withAnimation(.linear(duration: d)) { offsetX = -travelCached }
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000) + 1_200_000_000)
            if Task.isCancelled { return }
        }
    }
}

// Long-press preview cards (v106): what pops out when a song / album /
// playlist / artist is held — big artwork, title, artist.
struct SongPreview: View {
    var song: Song
    var body: some View {
        VStack(spacing: 10) {
            ArtworkImage(urlString: song.art(480, 480), size: 216, corner: 16)
            VStack(spacing: 2) {
                Text(song.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(width: 248)
    }
}

struct CollectionPreview: View {
    var item: CollectionItem
    var body: some View {
        VStack(spacing: 10) {
            ArtworkImage(urlString: item.art(480, 480), size: 216, corner: (item.type == "artists" || item.type == "library-artists") ? 108 : 16)
            VStack(spacing: 2) {
                Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if !item.sub.isEmpty {
                    Text(item.sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 248)
    }
}

struct SongRow: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    var song: Song
    var index: Int? = nil
    var onTap: () -> Void
    var onAdd: (() -> Void)? = nil
    var showFav: Bool = true
    var showShare: Bool = false
    var rail: Bool = false
    var onRemove: (() -> Void)? = nil
    @State private var shareItem: ShareItem?

    var body: some View {
        HStack(spacing: 10) {
            if let i = index {
                Text("\(i + 1)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            ArtworkImage(urlString: song.art(120, 120), size: 46, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: song.title,
                            font: .subheadline.weight(.semibold),
                            uiFont: .systemFont(ofSize: 15, weight: .semibold),
                            color: player.current?.id == song.id ? settings.accent : .primary)
                MarqueeText(text: rail ? song.artist : song.artist + (song.album.isEmpty ? "" : " · \(song.album)"),
                            font: .caption,
                            uiFont: .systemFont(ofSize: 12),
                            color: .secondary)
            }
            Spacer(minLength: 4)
            if player.current?.id == song.id {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(settings.accent)
            }
            if showShare {
                ShareButton(song: song)
            }
            if showFav {
                Button {
                    player.toggleFav(song, lang: settings.lang)
                } label: {
                    Image(systemName: player.isFav(song) ? "heart.fill" : "heart")
                        .font(.body)
                        .foregroundStyle(player.isFav(song) ? settings.accent : .secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            if let onAdd = onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onAppear { player.hydrateFav(song) }
        .contextMenu {
            Button { onTap() } label: { Label(settings.t("play"), systemImage: "play.fill") }
            Button { player.toggleFav(song, lang: settings.lang) } label: {
                Label(settings.t(player.isFav(song) ? "fav_remove" : "fav_add"),
                      systemImage: player.isFav(song) ? "heart.slash" : "heart")
            }
            if let onAdd = onAdd {
                Button { onAdd() } label: { Label(settings.t("add_to_playlist"), systemImage: "plus") }
            }
            if let onRemove = onRemove {
                Button(role: .destructive) { onRemove() } label: { Label(settings.t("remove_from_pl"), systemImage: "trash") }
            }
            Button {
                if let u = song.attributes?.url, let url = URL(string: u) { shareItem = ShareItem(url: url) }
            } label: { Label(settings.t("share"), systemImage: "square.and.arrow.up") }
        } preview: {
            SongPreview(song: song)
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }
}

// MARK: - Swipe-to-delete row (v107)
// The v106 glass rework dropped the swipe actions from her lists; this
// brings left-swipe delete back without a List (pages are ScrollView +
// glass panels). The row content slides over a red delete button; while
// displaced it picks up a frosted backing so the button never bleeds
// through the transparent row. The drag only claims clearly horizontal
// movement, so ordinary vertical scrolling still starts on a row.
struct SwipeDeleteRow<Content: View>: View {
    var label: String
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var dragX: CGFloat = 0
    @State private var open = false

    private let reveal: CGFloat = 76
    private var shown: CGFloat {
        let base = open ? -reveal : 0
        return min(10, max(-reveal - 130, base + dragX))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // v115 (her spec): Apple-native swipe action - a FLAT
            // red rectangle flush with the row's trailing edge and
            // full height (the row's own clip rounds the outer
            // corners), stretching elastically as the swipe
            // continues; a full swipe fires the action, like iOS.
            // (v107-v114 drew a rounded red square floating inside
            // the row with gaps at every edge.)
            Button {
                close()
                action()
            } label: {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: max(reveal, -shown))
                    .frame(maxHeight: .infinity)
                    .background(Color(red: 0.92, green: 0.16, blue: 0.22))
            }
            .buttonStyle(.plain)
            .opacity(shown < -2 ? 1 : 0)
            content()
                .background {
                    if shown < -1 {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(min(1, -shown / 40))
                    }
                }
                .offset(x: shown)
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in
                            if abs(v.translation.width) > abs(v.translation.height) * 1.4 {
                                dragX = v.translation.width
                            }
                        }
                        .onEnded { v in
                            let end = (open ? -reveal : 0) + v.translation.width
                            if end < -(reveal + 70) {
                                // Full swipe: fire, like the native
                                // destructive swipe action.
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    open = false
                                    dragX = 0
                                }
                                action()
                            } else {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                                    open = end < -reveal / 2
                                    dragX = 0
                                }
                            }
                        }
                )
                .overlay {
                    if open {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            open = false
            dragX = 0
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareButton: View {
    @EnvironmentObject var engine: EngineBridge
    var song: Song

    private var shareURL: URL? {
        if let u = song.attributes?.url, let url = URL(string: u) { return url }
        let sf = engine.storefront.isEmpty ? "cn" : engine.storefront
        return URL(string: "https://music.apple.com/\(sf)/song/\(song.playbackId)")
    }

    var body: some View {
        if let url = shareURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ArtworkSquare: View {
    var urlString: String?
    var corner: CGFloat = 14
    var body: some View {
        ZStack {
            Color.white.opacity(0.35)
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.clear
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct CollectionCard: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    var item: CollectionItem
    var width: CGFloat = 150
    // When set, the card handles its own tap and grows the native long-press
    // menu (v106): pop-out preview + open / play all / favorite.
    var onOpenCard: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if width > 0 {
                ArtworkImage(urlString: item.art(320, 320), size: width, corner: 14)
            } else {
                ArtworkSquare(urlString: item.art(320, 320), corner: 14)
            }
            MarqueeText(text: item.title,
                        font: .subheadline.weight(.semibold),
                        uiFont: .systemFont(ofSize: 15, weight: .semibold))
            MarqueeText(text: item.sub,
                        font: .caption,
                        uiFont: .systemFont(ofSize: 12),
                        color: .secondary)
        }
        .frame(width: width > 0 ? width : nil)
        .frame(maxWidth: width > 0 ? nil : .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(CardPressMenu(item: item, onOpenCard: onOpenCard))
    }
}

// The long-press behaviour for cards, factored out so the card body stays
// readable. Inert unless an open action was supplied.
struct CardPressMenu: ViewModifier {
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    var item: CollectionItem
    var onOpenCard: (() -> Void)?
    func body(content: Content) -> some View {
        if let open = onOpenCard {
            content
                .onTapGesture { open() }
                .contextMenu {
                    if item.type == "stations" {
                        Button { open() } label: { Label(settings.t("play"), systemImage: "play.fill") }
                    } else {
                        Button { open() } label: { Label(settings.t("open"), systemImage: "arrow.up.forward.square") }
                        if item.type == "albums" || item.type == "playlists" {
                            Button {
                                player.playCollection(item, kind: item.type == "albums" ? "album" : "playlist")
                            } label: { Label(settings.t("play_all"), systemImage: "play.fill") }
                        }
                        if item.type == "albums" {
                            Button { player.toggleFavAlbum(item, lang: settings.lang) } label: {
                                Label(settings.t(player.isFavAlbumItem(item) ? "fav_remove" : "fav_add"),
                                      systemImage: player.isFavAlbumItem(item) ? "heart.slash" : "heart")
                            }
                        }
                    }
                } preview: {
                    CollectionPreview(item: item)
                }
        } else {
            content
        }
    }
}

// v115 hero melt masks (album/playlist/artist heroes). Her spec:
// the cover's BODY stays sharp - only a narrow band at the very
// top and the very bottom blurs and fades into the page. The old
// treatment ran a full-frame blurred copy under a bottom-only
// fade, which turned the whole upper half to mush.
// heroEdgeMask: the sharp layer - opaque through the middle,
// easing out only inside the edge bands.
// heroEdgeBlurMask: the blurred layer - visible ONLY inside the
// edge bands, clear through the middle.
var heroEdgeMask: LinearGradient {
    LinearGradient(stops: [
        .init(color: .clear, location: 0.0),
        .init(color: .black.opacity(0.45), location: 0.05),
        .init(color: .black, location: 0.12),
        .init(color: .black, location: 0.86),
        .init(color: .black.opacity(0.45), location: 0.94),
        .init(color: .clear, location: 1.0),
    ], startPoint: .top, endPoint: .bottom)
}
var heroEdgeBlurMask: LinearGradient {
    LinearGradient(stops: [
        .init(color: .black, location: 0.0),
        .init(color: .black, location: 0.08),
        .init(color: .clear, location: 0.17),
        .init(color: .clear, location: 0.83),
        .init(color: .black, location: 0.92),
        .init(color: .black, location: 1.0),
    ], startPoint: .top, endPoint: .bottom)
}

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }
}

// Muted, auto-looping video used for Apple Music motion artwork (animated covers).
struct LoopingVideo: UIViewRepresentable {
    var url: URL
    // v116: readiness/failure reporting. A motion cover whose video
    // stalls or fails must not sit on screen as an invisible layer
    // hiding the static cover - the parent keeps the static artwork
    // underneath and only fades the video in once it is actually
    // ready to play.
    var onReady: (() -> Void)? = nil
    var onFail: (() -> Void)? = nil
    func makeUIView(context: Context) -> LoopingVideoView {
        let v = LoopingVideoView(url: url)
        v.onReady = onReady
        v.onFail = onFail
        return v
    }
    func updateUIView(_ uiView: LoopingVideoView, context: Context) {
        uiView.onReady = onReady
        uiView.onFail = onFail
        uiView.setURL(url)
    }
    static func dismantleUIView(_ uiView: LoopingVideoView, coordinator: ()) { uiView.stop() }
}

final class LoopingVideoView: UIView {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var curURL: URL?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var reportedFor: URL?
    var onReady: (() -> Void)?
    var onFail: (() -> Void)?
    init(url: URL) {
        super.init(frame: .zero)
        setURL(url)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
    func setURL(_ url: URL) {
        if curURL == url, player != nil { player?.play(); return }
        stop()
        curURL = url
        let item = AVPlayerItem(url: url)
        statusObs?.invalidate()
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self = self, self.curURL == url, self.reportedFor != url else { return }
            if it.status == .readyToPlay {
                self.reportedFor = url
                DispatchQueue.main.async { self.onReady?() }
            } else if it.status == .failed {
                self.reportedFor = url
                DispatchQueue.main.async { self.onFail?() }
            }
        }
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        let l = AVPlayerLayer(player: p)
        l.videoGravity = .resizeAspectFill
        l.frame = bounds
        layer.addSublayer(l)
        playerLayer = l
        player = p
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        p.play()
    }
    func stop() {
        statusObs?.invalidate()
        statusObs = nil
        player?.pause()
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        curURL = nil
    }
}

// Full-screen player for an artist's music-video previews.
struct MVPlayerView: View {
    var url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(16)
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: url) }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }
}

struct ToastOverlay: View {
    var text: String?
    var body: some View {
        if let text = text {
            VStack {
                Spacer()
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .aoiGlass(corner: 20)
                    .padding(.bottom, 110)
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: text)
        }
    }
}

struct AddToPlaylistSheet: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    var song: Song
    @Environment(\.dismiss) var dismiss
    @State private var playlists: [CollectionItem] = []
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(settings.t("playlist_name_ph"), text: $newName)
                        Button(settings.t("create")) {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            Task {
                                do {
                                    try await api.createPlaylist(name: name, song: song)
                                    player.showToast(settings.t("added_to"))
                                    dismiss()
                                } catch { player.showToast(settings.t("add_fail")) }
                            }
                        }
                        .disabled(!engine.authorized)
                    }
                }
                Section(settings.t("my_playlists")) {
                    ForEach(playlists) { pl in
                        Button(pl.title) {
                            Task {
                                do {
                                    try await api.addToPlaylist(pid: pl.id, song: song)
                                    player.showToast(settings.t("added_to"))
                                    dismiss()
                                } catch { player.showToast(settings.t("add_fail")) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(settings.t("add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(settings.t("cancel")) { dismiss() } } }
            .task { playlists = (try? await api.libraryPlaylists()) ?? [] }
        }
    }
}

struct CreatePlaylistSheet: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var onDone: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                TextField(settings.t("playlist_name_ph"), text: $name)
            }
            .navigationTitle(settings.t("new_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(settings.t("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.t("create")) {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        Task {
                            do {
                                try await api.createPlaylist(name: n, song: nil)
                                player.showToast(settings.t("created"))
                                onDone()
                                dismiss()
                            } catch { player.showToast(settings.t("op_fail")) }
                        }
                    }
                }
            }
        }
    }
}


// v114: a bare glyph made of liquid glass - no tile, disc or plate
// behind it. The system glass renders in a small field and is then
// clipped by the symbol's own silhouette, so the button IS the
// shape of its icon; a translucent tint of the same glyph sits on
// top so the symbol stays legible over any cover.
struct GlyphGlassIcon: View {
    let icon: String
    var size: CGFloat = 20
    var weight: Font.Weight = .semibold
    var tint: Color = .white

    var body: some View {
        let glyph = Image(systemName: icon)
            .font(.system(size: size, weight: weight))
        ZStack {
            if #available(iOS 26.0, *) {
                Rectangle()
                    .fill(.white.opacity(0.001))
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 2))
                    .mask { glyph }
            }
            glyph
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.92), tint.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}


// v114: pick songs INTO one of her own playlists - from Recently
// Played, Loved Songs, and the tracks of Favorite Albums. Multi-
// select with checkmarks; songs already in the playlist are marked
// and can't be picked again.
struct AddSongsSheet: View {
    let playlistId: String
    let existing: Set<String>
    var onAdded: ([Song]) -> Void
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [Song] = []
    @State private var albumTracks: [Song]?
    @State private var albumName = ""
    @State private var loadingAlbum = false
    @State private var adding = false

    private func isPicked(_ s: Song) -> Bool { picked.contains { $0.id == s.id } }
    private func isExisting(_ s: Song) -> Bool { existing.contains(s.id) || existing.contains(s.playbackId) }
    private func toggle(_ s: Song) {
        if isPicked(s) { picked.removeAll { $0.id == s.id } } else { picked.append(s) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let tr = albumTracks {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                            Text(albumName).font(.headline).lineLimit(1)
                        }
                        .foregroundStyle(settings.accent)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { albumTracks = nil }
                        ForEach(tr) { s in pickRow(s) }
                    } else {
                        if !player.history.isEmpty {
                            SectionTitle(text: settings.t("recent_played"))
                            ForEach(Array(player.history.prefix(30))) { s in pickRow(s) }
                        }
                        if !player.favSongs.isEmpty {
                            SectionTitle(text: settings.t("fav_songs"))
                            ForEach(player.favSongs) { s in pickRow(s) }
                        }
                        if !player.favAlbums.isEmpty {
                            SectionTitle(text: settings.t("lib_albums"))
                            ForEach(player.favAlbums) { a in albumRow(a) }
                        }
                        if player.history.isEmpty && player.favSongs.isEmpty && player.favAlbums.isEmpty {
                            Text(settings.t("empty")).foregroundStyle(.secondary).padding(.top, 30)
                        }
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle(settings.t("pick_songs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.t("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        addPicked()
                    } label: {
                        if adding { ProgressView() }
                        else { Text("\(settings.t("add_selected")) (\(picked.count))").fontWeight(.semibold) }
                    }
                    .disabled(picked.isEmpty || adding)
                }
            }
        }
    }

    private func pickRow(_ s: Song) -> some View {
        let ex = isExisting(s)
        return HStack(spacing: 10) {
            ArtworkImage(urlString: s.art(120, 120), size: 44, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(s.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if ex {
                Text(settings.t("in_list")).font(.caption).foregroundStyle(.tertiary)
            } else {
                Image(systemName: isPicked(s) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isPicked(s) ? settings.accent : Color.secondary)
            }
        }
        .padding(.vertical, 5)
        .opacity(ex ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !ex { toggle(s) } }
    }

    private func albumRow(_ a: CollectionItem) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(urlString: a.art(120, 120), size: 44, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(a.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if loadingAlbum {
                ProgressView()
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !loadingAlbum else { return }
            loadingAlbum = true
            Task {
                let (_, tr) = (try? await api.collectionTracks(kind: "album", id: a.id)) ?? (nil, [])
                albumTracks = tr
                albumName = a.title
                loadingAlbum = false
            }
        }
    }

    private func addPicked() {
        guard !picked.isEmpty else { return }
        adding = true
        let songs = picked
        Task {
            var done: [Song] = []
            for s in songs {
                if (try? await api.addToPlaylist(pid: playlistId, song: s)) != nil { done.append(s) }
            }
            adding = false
            if done.isEmpty {
                player.showToast(settings.t("add_fail"))
            } else {
                player.showToast(settings.t("added_to"))
                onAdded(done)
                dismiss()
            }
        }
    }
}
