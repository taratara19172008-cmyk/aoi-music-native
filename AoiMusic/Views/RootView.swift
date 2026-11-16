import SwiftUI

enum Page: String, CaseIterable {
    case home, search, radio, library, settings
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .radio: return "dot.radiowaves.left.and.right"
        case .library: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        }
    }
    var key: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: Player
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @State private var page: Page = .home
    @State private var railDrag: Page? = nil

    var body: some View {
        ZStack {
            background
            HStack(spacing: 10) {
                rail
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                if player.current != nil {
                    MiniPlayer()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }
            if let route = nav.detail {
                Group {
                    switch route {
                    case .collection(let kind, let id):
                        CollectionView(kind: kind, id: id)
                    case .artist(let id):
                        ArtistView(artistId: id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .trailing))
                .zIndex(5)
            }
            ToastOverlay(text: player.toast)
            EngineHost(webView: engine.webView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.28), value: nav.detail)
        .fullScreenCover(isPresented: $nav.showNowPlaying) {
            NowPlayingView()
        }
    }

    private var background: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.93, green: 0.96, blue: 0.99), Color(red: 0.98, green: 0.92, blue: 0.95), Color(red: 0.94, green: 0.93, blue: 0.99)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let img = settings.bgImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    Color.white.opacity(0.22)
                }
                Circle().fill(settings.accent.opacity(0.20)).frame(width: 300, height: 300).blur(radius: 70).offset(x: -130, y: -260)
                Circle().fill(Color(red: 0.45, green: 0.75, blue: 0.95).opacity(0.22)).frame(width: 280, height: 280).blur(radius: 70).offset(x: 150, y: 240)
                Circle().fill(Color(red: 1.0, green: 0.72, blue: 0.55).opacity(0.16)).frame(width: 240, height: 240).blur(radius: 70).offset(x: 120, y: -180)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    private var railH: CGFloat { min(620, UIScreen.main.bounds.height * 0.66) }

    private func railCenter(_ p: Page) -> CGFloat {
        switch p {
        case .home: return 98
        case .search: return 160
        case .radio: return 222
        case .library: return 284
        case .settings: return railH - 40
        }
    }

    private func railPage(atY y: CGFloat) -> Page {
        [Page.home, .search, .radio, .library, .settings].min(by: { abs(railCenter($0) - y) < abs(railCenter($1) - y) }) ?? .home
    }

    private var rail: some View {
        let target = railDrag ?? page
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(settings.accent.opacity(0.16))
                .frame(width: 62, height: 56)
                .offset(y: railCenter(target) - 28)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: railCenter(target))
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(settings.accent.opacity(0.85))
                        .frame(width: 46, height: 46)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 12)
                .padding(.bottom, 6)
                ForEach([Page.home, .search, .radio, .library], id: \.self) { p in
                    railButton(p)
                }
                Spacer(minLength: 8)
                railButton(.settings)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 74)
        .frame(height: railH)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in railDrag = railPage(atY: v.location.y) }
                .onEnded { v in
                    page = railPage(atY: v.location.y)
                    railDrag = nil
                }
        )
        .aoiGlass(corner: 37)
        .padding(.vertical, 20)
    }

    private func railButton(_ p: Page) -> some View {
        Button {
            page = p
        } label: {
            VStack(spacing: 3) {
                Image(systemName: p.icon)
                    .font(.system(size: 21, weight: .semibold))
                Text(settings.t(p.key))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle((railDrag ?? page) == p ? settings.accent : Color.primary.opacity(0.75))
            .frame(width: 62, height: 56)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home: HomeView()
        case .search: SearchView()
        case .radio: RadioView()
        case .library: LibraryView()
        case .settings: SettingsView()
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: AppNav

    var body: some View {
        HStack(spacing: 10) {
            Button { nav.showNowPlaying = true } label: {
                HStack(spacing: 10) {
                    ArtworkImage(urlString: player.current?.art(120, 120), size: 44, corner: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.current?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(player.current?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            transportButton("backward.fill") { player.prev() }
            transportButton(player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlay() }
            transportButton("forward.fill") { player.next() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .aoiGlass(corner: 26, interactive: true)
    }
    private func transportButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }
}
