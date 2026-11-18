import SwiftUI
import MediaPlayer
import AVKit

struct VolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView() }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var nav: AppNav
    @State private var panel: Int = 0 // 0 art, 1 lyrics, 2 queue
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsNote: String = ""
    @State private var lyricsSongId: String = ""
    @State private var motionURLStr: String?
    @State private var motionSongId: String = ""
    @State private var palette: CoverPalette?
    @State private var dismissDrag: CGFloat = 0

    // Text follows the cover: white on dark covers, ink on light ones.
    private var fg: Color { palette?.isDark == false ? Color(red: 0.10, green: 0.10, blue: 0.12) : .white }
    private var fgDim: Color { fg.opacity(0.65) }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 12) {
                // v114: the grabber zone is a wide handle area - a tap
                // dismisses, and a downward drag starting here pulls
                // the whole page with the finger (not far enough =
                // springs back).
                ZStack {
                    Capsule()
                        .fill(fg.opacity(0.5))
                        .frame(width: 44, height: 5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
                .onTapGesture { nav.showNowPlaying = false }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in dismissDrag = max(v.translation.height, 0) }
                        .onEnded { v in
                            if v.translation.height > 90 {
                                nav.showNowPlaying = false
                                dismissDrag = 0
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { dismissDrag = 0 }
                            }
                        }
                )
                Spacer()
                middle
                titleRow
                seekBar
                controls
                VolumeView()
                    .frame(width: UIScreen.main.bounds.width - 88, height: 30)
                pills
                Spacer(minLength: 6)
            }
            .offset(y: max(dismissDrag, 0))
            .padding(.horizontal, 22)
            .padding(.top, 36)
            .padding(.bottom, 10)
            .frame(width: UIScreen.main.bounds.width)
            .frame(maxHeight: .infinity)
            ToastOverlay(text: player.toast)
        }
        .onChange(of: player.current?.id) { _ in loadLyrics(); loadMotion(); loadPalette() }
        .onAppear { loadLyrics(); loadMotion(); loadPalette() }
    }

    // v105: the background is a gradient grown out of the cover's dominant
    // colours (plus a soft glow of the cover's most vibrant colour) - the
    // cover itself is back to its original boxed size in the middle panel.
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [palette?.top ?? Color(red: 0.25, green: 0.20, blue: 0.30),
                         palette?.bottom ?? Color(red: 0.12, green: 0.10, blue: 0.16)],
                startPoint: .top, endPoint: .bottom)
            Circle()
                .fill((palette?.glow ?? settings.accent).opacity(0.55))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: 130, y: -300)
            Circle()
                .fill((palette?.glow ?? settings.accent).opacity(0.30))
                .frame(width: 300, height: 300)
                .blur(radius: 95)
                .offset(x: -140, y: 320)
            // Specular rake + vignette, same light language as the
            // app backdrop (v114).
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white.opacity(0.13), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 700, height: 170)
                .rotationEffect(.degrees(-24))
                .blur(radius: 26)
                .offset(y: -260)
            GeometryReader { geo in
                RadialGradient(colors: [.clear, .black.opacity(0.13)],
                               center: .center,
                               startRadius: geo.size.width * 0.40,
                               endRadius: geo.size.width * 0.95)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var middle: some View {
        // The artwork panel stays MOUNTED (only faded out) while the lyrics
        // or queue panel shows (v106): destroying and rebuilding the motion-
        // cover player on every panel switch churned the audio session and
        // paused the song. Together with the mixWithOthers session, panel
        // switches are now silent to the playback engine.
        ZStack {
            artworkPanel
                .opacity(panel == 0 ? 1 : 0)
                .allowsHitTesting(panel == 0)
            if panel == 1 { lyricsView }
            if panel == 2 { queueView }
        }
        .frame(height: 320)
    }

    private var artworkPanel: some View {
        ZStack {
            if let m = motionURLStr, let u = URL(string: m) {
                LoopingVideo(url: u)
                    .frame(width: 320, height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ArtworkImage(urlString: player.current?.art(800, 800), size: 320, corner: 24)
            }
        }
        .shadow(color: Color.black.opacity(0.30), radius: 24, y: 12)
        .frame(height: 320)
    }

    private var lyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if lyrics.isEmpty {
                        Text(lyricsNote.isEmpty ? settings.t("no_lyrics") : lyricsNote)
                            .foregroundStyle(fgDim)
                            .padding(.top, 30)
                    }
                    ForEach(lyrics) { line in
                        Text(line.text)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(currentLineId == line.id ? fg : fg.opacity(0.45))
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .frame(height: 320)
            .onChange(of: currentLineId) { id in
                if let id = id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
    private var currentLineId: Int? {
        var cur: Int? = nil
        for l in lyrics { if l.begin <= player.currentTime + 0.1 { cur = l.id } else { break } }
        return cur
    }

    private var queueView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(settings.t("queue_title")) · \(player.queue.count)")
                    .font(.headline)
                    .foregroundStyle(fg)
                    .padding(.bottom, 6)
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 10) {
                        ArtworkImage(urlString: s.art(120, 120), size: 40, corner: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                .foregroundStyle(i == player.index ? settings.accent : fg)
                            Text(s.artist).font(.caption).foregroundStyle(fgDim).lineLimit(2)
                        }
                        Spacer()
                        if i == player.index {
                            Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(settings.accent)
                        }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { player.jumpTo(i) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 320)
    }

    private func openAlbum() {
        if let aid = player.current?.relationships?.albums?.data?.first?.id {
            nav.showNowPlaying = false
            nav.detail = .collection(kind: "album", id: aid)
            return
        }
        guard let cur = player.current else { return }
        Task {
            if let s = await api.songFull(for: cur), let aid = s.relationships?.albums?.data?.first?.id {
                nav.showNowPlaying = false
                nav.detail = .collection(kind: "album", id: aid)
            } else {
                player.showToast(settings.t("np_goto_fail"))
            }
        }
    }

    private func openArtist() {
        if let aid = player.current?.relationships?.artists?.data?.first?.id {
            nav.showNowPlaying = false
            nav.detail = .artist(id: aid)
            return
        }
        guard let cur = player.current else { return }
        Task {
            if let s = await api.songFull(for: cur), let aid = s.relationships?.artists?.data?.first?.id {
                nav.showNowPlaying = false
                nav.detail = .artist(id: aid)
            } else {
                player.showToast(settings.t("np_goto_fail"))
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Button { openAlbum() } label: {
                    Text(player.current?.title ?? "—")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(fg)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { openArtist() } label: {
                    Text(player.current?.artist ?? "—")
                        .font(.system(size: 18))
                        .foregroundStyle(fgDim)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if let cur = player.current {
                // v115 (GPT review item 2): the old line force-
                // unwrapped a URL built from attributes.url - a
                // non-nil but unparseable value skipped the fallback
                // and trapped. Parse first, fall back on failure,
                // and simply omit the button if both fail.
                if let shareURL = (cur.attributes?.url.flatMap { URL(string: $0) })
                    ?? URL(string: "https://music.apple.com/\(api.storefront)/song/\(cur.playbackId)") {
                    ShareLink(item: shareURL) {
                        GlyphGlassIcon(icon: "square.and.arrow.up", size: 21, tint: fg)
                            .frame(width: 46, height: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { player.toggleFav(cur, lang: settings.lang) } label: {
                    GlyphGlassIcon(icon: player.isFav(cur) ? "heart.fill" : "heart", size: 21,
                                   tint: player.isFav(cur) ? settings.accent : fg)
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear { player.hydrateFav(cur) }
            }
        }
    }

    private var seekBar: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { scrubbing ? scrubValue : player.currentTime },
                set: { scrubValue = $0 }
            ), in: 0...max(player.duration, 1)) { editing in
                if editing { scrubbing = true; scrubValue = player.currentTime }
                else { scrubbing = false; player.seek(scrubValue) }
            }
            .tint(fg)
            HStack {
                Text(fmt(player.currentTime)).font(.caption).foregroundStyle(fg.opacity(0.7))
                Spacer()
                Text(player.useEngine && !player.isPreviewClip ? settings.t("full") : settings.t("preview"))
                    .font(.caption.weight(.medium)).foregroundStyle(fg.opacity(0.7))
                Spacer()
                Text("-" + fmt(max(player.duration - player.currentTime, 0))).font(.caption).foregroundStyle(fg.opacity(0.7))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ctlButton("shuffle", on: player.shuffle) { player.toggleShuffle(); player.showToast(settings.t(player.shuffle ? "shuffle_on" : "shuffle_off")) }
            ctlButton("backward.fill", big: false) { player.prev() }
            Button { player.togglePlay() } label: {
                GlyphGlassIcon(icon: player.isPlaying ? "pause.fill" : "play.fill", size: 34, weight: .bold, tint: fg)
                    .frame(width: 74, height: 74)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ctlButton("forward.fill", big: false) { player.next() }
            ZStack(alignment: .topTrailing) {
                ctlButton("repeat", on: player.repeatMode > 0) {
                    player.cycleRepeat()
                    player.showToast(settings.t(["repeat_off", "repeat_all", "repeat_one"][player.repeatMode]))
                }
                if player.repeatMode == 2 {
                    Text("1")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(settings.accent)
                        .offset(x: -7, y: 5)
                }
            }
        }
    }

    private func ctlButton(_ icon: String, big: Bool = false, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlyphGlassIcon(icon: icon, size: 21, tint: on ? settings.accent : fg)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pills: some View {
        HStack(spacing: 10) {
            pill(title: "♪ " + settings.t("lyrics"), active: panel == 1) { panel = panel == 1 ? 0 : 1 }
            RoutePicker()
                .frame(width: 90, height: 36)
                .aoiGlass(corner: 18, interactive: true)
            pill(title: "☰ " + settings.t("queue"), active: panel == 2) { panel = panel == 2 ? 0 : 2 }
        }
    }
    private func pill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? settings.accent : fg)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .aoiGlass(corner: 18, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func fmt(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private func loadPalette() {
        guard let cur = player.current else { return }
        let art = cur.art(600, 600)
        Task {
            if let p = await CoverPaletteLoader.load(art), player.current?.id == cur.id {
                palette = p
            }
        }
    }

    private func loadMotion() {
        guard let cur = player.current, cur.id != motionSongId else { return }
        motionSongId = cur.id
        motionURLStr = nil
        Task {
            let u = await api.motionURLForSong(cur)
            if player.current?.id == cur.id { motionURLStr = u }
        }
    }

    private func loadLyrics() {
        guard let cur = player.current, cur.id != lyricsSongId else { return }
        lyricsSongId = cur.id
        lyrics = []
        lyricsNote = ""
        guard engine.authorized else { lyricsNote = settings.t("lyrics_signin"); return }
        Task {
            do {
                let lines = try await api.lyrics(for: cur)
                if player.current?.id == cur.id { lyrics = lines }
            } catch {
                if player.current?.id == cur.id { lyricsNote = settings.t("no_lyrics") }
            }
        }
    }
}
