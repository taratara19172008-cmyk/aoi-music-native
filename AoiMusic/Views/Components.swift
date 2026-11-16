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
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(player.current?.id == song.id ? settings.accent : .primary)
                Text(rail ? song.artist : song.artist + (song.album.isEmpty ? "" : " · \(song.album)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
    var item: CollectionItem
    var width: CGFloat = 150
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if width > 0 {
                ArtworkImage(urlString: item.art(320, 320), size: width, corner: 14)
            } else {
                ArtworkSquare(urlString: item.art(320, 320), corner: 14)
            }
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(item.sub)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: width > 0 ? width : nil)
        .frame(maxWidth: width > 0 ? nil : .infinity, alignment: .leading)
    }
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
    func makeUIView(context: Context) -> LoopingVideoView { LoopingVideoView(url: url) }
    func updateUIView(_ uiView: LoopingVideoView, context: Context) { uiView.setURL(url) }
    static func dismantleUIView(_ uiView: LoopingVideoView, coordinator: ()) { uiView.stop() }
}

final class LoopingVideoView: UIView {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var curURL: URL?
    private var endObs: NSObjectProtocol?
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
