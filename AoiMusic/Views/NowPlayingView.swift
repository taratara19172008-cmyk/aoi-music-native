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
    @EnvironmentObject var downloads: DownloadManager
    @State private var panel: Int = 0 // 0 art, 1 lyrics, 2 queue
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsNote: String = ""
    @State private var lyricsSongId: String = ""

    var body: some View {
        ZStack {
            background
                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            VStack(spacing: 12) {
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 44, height: 5)
                    .padding(.top, 10)
                    .onTapGesture { nav.showNowPlaying = false }
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
            .padding(.horizontal, 22)
            .padding(.top, 36)
            .padding(.bottom, 10)
            .frame(width: UIScreen.main.bounds.width)
            .frame(maxHeight: .infinity)
            ToastOverlay(text: player.toast)
        }
        .onChange(of: player.current?.id) { _ in loadLyrics() }
        .onAppear { loadLyrics() }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.16, green: 0.12, blue: 0.18)
            if let s = player.current?.art(200, 200), let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Color.clear
                    }
                }
                .blur(radius: 60)
                .opacity(0.85)
            }
            Color.black.opacity(0.18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var middle: some View {
        switch panel {
        case 1: lyricsView
        case 2: queueView
        default:
            ArtworkImage(urlString: player.current?.art(640, 640), size: 300, corner: 16)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .scaleEffect(player.isPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: player.isPlaying)
                .frame(height: 320)
        }
    }

    private var lyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if lyrics.isEmpty {
                        Text(lyricsNote.isEmpty ? settings.t("no_lyrics") : lyricsNote)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.top, 30)
                    }
                    ForEach(lyrics) { line in
                        Text(line.text)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(currentLineId == line.id ? Color.white : Color.white.opacity(0.45))
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
                    .foregroundStyle(.white)
                    .padding(.bottom, 6)
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 10) {
                        ArtworkImage(urlString: s.art(120, 120), size: 40, corner: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .foregroundStyle(i == player.index ? settings.accent : .white)
                            Text(s.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
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
            if let s = await api.songFull(id: cur.id), let aid = s.relationships?.albums?.data?.first?.id {
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
            if let s = await api.songFull(id: cur.id), let aid = s.relationships?.artists?.data?.first?.id {
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
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { openArtist() } label: {
                    Text(player.current?.artist ?? "—")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if let cur = player.current {
                Button {
                    if downloads.isDownloaded(cur.playbackId) {
                        player.showToast(settings.t("downloaded"))
                    } else {
                        downloads.download(cur)
                        player.showToast(settings.t("downloading"))
                    }
                } label: {
                    Group {
                        if downloads.active.contains(cur.playbackId) {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: downloads.isDownloaded(cur.playbackId) ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(downloads.isDownloaded(cur.playbackId) ? settings.accent : .white)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .aoiGlass(corner: 14, interactive: true)
                }
                .buttonStyle(.plain)
                Button { player.toggleFav(cur, lang: settings.lang) } label: {
                    Image(systemName: player.isFav(cur) ? "heart.fill" : "heart")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(player.isFav(cur) ? settings.accent : .white)
                        .frame(width: 46, height: 46)
                        .aoiGlass(corner: 14, interactive: true)
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
            .tint(.white)
            HStack {
                Text(fmt(player.currentTime)).font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(player.useEngine ? settings.t("full") : settings.t("preview"))
                    .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("-" + fmt(max(player.duration - player.currentTime, 0))).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ctlButton("shuffle", on: player.shuffle) { player.toggleShuffle(); player.showToast(settings.t(player.shuffle ? "shuffle_on" : "shuffle_off")) }
            ctlButton("backward.fill", big: false) { player.prev() }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 74, height: 74)
                    .aoiGlass(corner: 24, interactive: true)
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
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? settings.accent : .white)
                .frame(width: 52, height: 52)
                .aoiGlass(corner: 17, interactive: true)
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
                .foregroundStyle(active ? settings.accent : .white)
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
