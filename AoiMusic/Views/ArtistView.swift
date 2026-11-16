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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.96, blue: 0.99), Color(red: 0.98, green: 0.92, blue: 0.95)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button { nav.detail = nil } label: {
                            Label(settings.t("back"), systemImage: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .aoiGlass(corner: 20, interactive: true)
                        Spacer()
                    }
                    if let d = detail {
                        ZStack(alignment: .bottomLeading) {
                            AsyncImage(url: d.attributes?.artwork?.urlString(1200, 900).flatMap { URL(string: $0) }) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                default: Color.white.opacity(0.3)
                                }
                            }
                            .frame(height: 240)
                            .clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                            Text(d.attributes?.name ?? "")
                                .font(.system(size: 34, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(14)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.top, 8)
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
                            SectionTitle(text: settings.t("top_songs_a"))
                            ForEach(Array(tops.enumerated()), id: \.element.id) { i, s in
                                SongRow(song: s, index: i, onTap: { player.playSongs(tops, start: i) }, onAdd: { addSong = s })
                            }
                        }
                        if let albums = d.views?.albums?.data ?? d.relationships?.albums?.data, !albums.isEmpty {
                            SectionTitle(text: settings.t("albums"))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(albums) { a in
                                        CollectionCard(item: a)
                                            .onTapGesture { nav.detail = .collection(kind: "album", id: a.id) }
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        if let pls = d.views?.playlists?.data ?? d.relationships?.playlists?.data, !pls.isEmpty {
                            SectionTitle(text: settings.t("playlists"))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(pls) { p in
                                        CollectionCard(item: p)
                                            .onTapGesture { nav.detail = .collection(kind: "playlist", id: p.id) }
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        if let sims = d.views?.similarArtists?.data, !sims.isEmpty {
                            SectionTitle(text: settings.t("similar"))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(sims) { a in
                                        CollectionCard(item: a)
                                            .onTapGesture { nav.detail = .artist(id: a.id) }
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            ToastOverlay(text: player.toast)
        }
        .task { await load() }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
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
        if engine.authorized {
            artistFav = await api.rating(kind: "artists", id: artistId)
        }
    }
}
