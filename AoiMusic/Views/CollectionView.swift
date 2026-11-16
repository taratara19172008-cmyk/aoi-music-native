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
    @State private var albumFav = false
    @State private var addSong: Song?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.96, blue: 0.99), Color(red: 0.98, green: 0.92, blue: 0.95)], startPoint: .top, endPoint: .bottom)
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
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                if !loaded {
                    ProgressView().padding(.top, 60)
                    Spacer()
                } else {
                    List {
                        heroSection
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s, index: i, onTap: { player.playSongs(tracks, start: i) }, onAdd: { addSong = s })
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if kind == "lplaylist" {
                                        Button(role: .destructive) { removeTrack(s) } label: {
                                            Label(settings.t("del"), systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            ToastOverlay(text: player.toast)
        }
        .task { await load() }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
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

    @ViewBuilder
    private var heroSection: some View {
        VStack(spacing: 10) {
            ArtworkImage(urlString: item?.art(600, 600), size: 190, corner: 18)
            Text(item?.title ?? "")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let sub = item?.sub, !sub.isEmpty {
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
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
                    actionButton(title: albumFav ? settings.t("album_faved") : settings.t("fav_album"), filled: false) {
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
        guard engine.authorized else { player.showToast(settings.t("need_acct_fav")); return }
        let was = albumFav
        albumFav = !was
        Task {
            do {
                if was { try await api.rateDelete(kind: "albums", id: id); player.showToast(settings.t("unfaved")) }
                else { try await api.rateWrite(kind: "albums", id: id); player.showToast(settings.t("faved")) }
            } catch {
                albumFav = was
                player.showToast(settings.t("fav_fail"))
            }
        }
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

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        do {
            let (head, tr) = try await api.collectionTracks(kind: kind, id: id)
            item = head
            tracks = tr
        } catch {}
        loaded = true
        if kind == "album", engine.authorized {
            albumFav = await api.rating(kind: "albums", id: id)
        }
    }
}
