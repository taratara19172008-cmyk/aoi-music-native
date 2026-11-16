import SwiftUI
import WebKit

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
                    .lineLimit(1)
                    .foregroundStyle(player.current?.id == song.id ? settings.accent : .primary)
                Text(song.artist + (song.album.isEmpty ? "" : " · \(song.album)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if player.current?.id == song.id {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(settings.accent)
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

struct CollectionCard: View {
    var item: CollectionItem
    var width: CGFloat = 150
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(urlString: item.art(320, 320), size: width, corner: 14)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(item.sub)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width)
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
