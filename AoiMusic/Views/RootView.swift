import SwiftUI

enum Page: String, CaseIterable {
    case home, search, radio, library, favorites, settings, ai
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .radio: return "dot.radiowaves.left.and.right"
        case .library: return "square.grid.2x2.fill"
        case .favorites: return "heart.fill"
        case .settings: return "gearshape.fill"
        case .ai: return "sparkles"
        }
    }
    var key: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: Player
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var nav: AppNav
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var shazam: ShazamRecognizer
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Page = .home
    @State private var searchTerm = ""
    private let mainPages: [Page] = [.home, .search, .radio, .library]

    var body: some View {
        ZStack {
            background
            // v119: while the search page is up, the keyboard safe
            // area is excluded at the root hosting controller (see
            // KeyboardRegionFixer below) - three rounds of in-layout
            // shields (v115/v116/v118) all failed because the
            // keyboard kept re-laying-out branches of this ZStack.
            // With the keyboard out of the root layout entirely,
            // every branch shares one stable coordinate system.
            KeyboardRegionFixer(active: page == .search) { engine.logEvent($0) }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
            // The engine's web view hosts at FULL size behind everything
            // (v108): at 1x1 WebKit treats the page as barely visible and
            // may throttle its timers and media pipeline, which the
            // playback engine depends on. v112: opacity is back to 1 -
            // GPT's review flagged 0.01 as a throttling suspect in its
            // own right (a nearly-transparent page reads as not-visible
            // to WebKit's heuristics). The page renders nothing and the
            // web view is transparent (EngineBridge sets isOpaque =
            // false), so full opacity still shows nothing.
            EngineHost(webView: engine.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
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
            // v119: the search field is a DIRECT child of the root
            // ZStack, pinned by an explicit full-frame top-leading
            // placement - no full-height VStack + Spacer anywhere
            // in its ancestry (v118's overlay VStack received
            // unstable layout rects during keyboard transitions:
            // widened to the screen edge, clipped at the top, once
            // even landed at the bottom of the screen).
            if page == .search {
                SearchFieldView(term: $searchTerm)
                    .padding(.leading, 98)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
            // v115 (her spec): the Shazam button lives at the top
            // of the left rail - the uppermost-left of the screen -
            // not beside the Home greeting where v114 put it. The
            // rail column starts at x=8 and is 74 wide, so 18pt of
            // leading centres the 54pt button over it.
            VStack {
                HStack {
                    ShazamButton()
                        .padding(.leading, 18)
                        .padding(.top, 2)
                    Spacer()
                }
                Spacer()
            }
            // v115: while Shazam is listening, an unmistakable
            // status pill rides the top centre - animated bars and
            // the word Listening - so she always knows the state.
            VStack {
                if shazam.isListening {
                    HStack(spacing: 8) {
                        ListeningBars()
                        Text(settings.t("shazam_listening"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .aoiGlass(corner: 20)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: shazam.isListening)
            ToastOverlay(text: player.toast)
        }
        .animation(.easeInOut(duration: 0.28), value: nav.detail)
        // v119: the old conditional .ignoresSafeArea(.keyboard)
        // shield is gone - KeyboardRegionFixer (in the ZStack
        // above) now excludes the keyboard at the hosting-
        // controller level while the search page is up, and
        // restores normal keyboard behaviour on every other page
        // (the AI chat input still needs to ride the keyboard).
        .onChange(of: scenePhase) { _, phase in
            // v115: the app returning to the foreground is a
            // recovery trigger alongside the engine page's own
            // visibility signal (Player decides if anything is
            // actually wrong before acting).
            if phase == .active {
                // v117 (GPT round 4, problem 7): bridge liveness
                // first - if the engine page died in the background
                // it is revived (or its recovery started) BEFORE
                // the player's foreground logic reads its state.
                player.engine.ensureAlive { player.foregroundBecameVisible() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aoiShazamSongTap)) { note in
            if let sid = note.userInfo?["songId"] as? String {
                NotificationPresenter.pendingSongId = nil
                playShazamSong(sid)
            }
        }
        .fullScreenCover(isPresented: $nav.showNowPlaying) {
            NowPlayingView()
        }
        .onAppear {
            WidgetShared.publishAccent(settings.accentHex)
            if let sid = NotificationPresenter.pendingSongId {
                NotificationPresenter.pendingSongId = nil
                playShazamSong(sid)
            }
        }
        .onChange(of: settings.accentHex) { _, hex in WidgetShared.publishAccent(hex) }
    }

    private var background: some View {
        GeometryReader { geo in
            ZStack {
                // v114: the theme colour is IN the gradient now, not
                // just in the blooms - the whole backdrop carries it.
                LinearGradient(colors: [Color(red: 0.93, green: 0.96, blue: 0.99),
                                        settings.accent.opacity(0.30),
                                        Color(red: 0.98, green: 0.92, blue: 0.95),
                                        settings.accent.opacity(0.20)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let img = settings.bgImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    Color.white.opacity(0.14)
                }
                // Light blooms （光晕）: stronger, wider, and one more
                // in the theme colour low in the frame.
                Circle().fill(settings.accent.opacity(0.52)).frame(width: 340, height: 340).blur(radius: 85).offset(x: -130, y: -260)
                Circle().fill(Color(red: 0.45, green: 0.75, blue: 0.95).opacity(0.40)).frame(width: 320, height: 320).blur(radius: 85).offset(x: 150, y: 240)
                Circle().fill(Color(red: 1.0, green: 0.72, blue: 0.55).opacity(0.34)).frame(width: 280, height: 280).blur(radius: 85).offset(x: 120, y: -180)
                Circle().fill(settings.accent.opacity(0.30)).frame(width: 300, height: 300).blur(radius: 95).offset(x: -60, y: 330)
                // Specular streak: a soft diagonal band of light, the
                // way light rakes across a sheet of glass.
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, .white.opacity(0.20), .white.opacity(0.05), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * 1.5, height: 190)
                    .rotationEffect(.degrees(-24))
                    .blur(radius: 26)
                    .offset(y: -geo.size.height * 0.28)
                // Vignette （晕影）: the edges fall gently away so the
                // glass content floats in a pool of light.
                RadialGradient(colors: [.clear, .black.opacity(0.10)],
                               center: .center,
                               startRadius: geo.size.width * 0.42,
                               endRadius: geo.size.width * 0.98)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    private var railH: CGFloat { min(620, UIScreen.main.bounds.height * 0.66) }

    private var rail: some View { railBody }

    private var railBody: some View {
        VStack(spacing: 0) {
            RailSegment(pages: mainPages, firstCenter: 98, topPad: 0, bottomPad: 6, selection: $page, showsLogo: true)
            Spacer(minLength: 32)
            RailSegment(pages: [.ai, .favorites, .settings], firstCenter: 38, topPad: 10, bottomPad: 10, selection: $page)
        }
        .frame(width: 74)
        .frame(height: railH)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .home: HomeView()
        case .search: SearchView(term: $searchTerm)
        case .radio: RadioView()
        case .library: LibraryView()
        case .favorites: FavoritesView()
        case .settings: SettingsView()
        case .ai: AIChatView()
        }
    }
}

// v119: excludes the keyboard safe area at the ROOT hosting
// controller while `active` (the search page), and restores the
// default regions otherwise. Three rounds of SwiftUI-level
// keyboard shields failed because the keyboard kept participating
// in the root layout and re-laying-out individual branches (the
// search overlay received widened / clipped / bottom-docked rects
// in her recordings; the mini player floated up too). Setting
// safeAreaRegions = .container on the hosting controller removes
// the keyboard from SwiftUI layout entirely for as long as it is
// set - the container regions (notch, status bar, home indicator)
// are untouched. The regions are applied to the window's root
// view controller and its children (whichever of them is the
// hosting controller), and only logged when they actually change.
struct KeyboardRegionFixer: UIViewRepresentable {
    var active: Bool
    var onApply: (String) -> Void

    func makeUIView(context: Context) -> FixerView {
        let v = FixerView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: FixerView, context: Context) {
        uiView.active = active
        uiView.onApply = onApply
        uiView.applyRegions()
    }

    final class FixerView: UIView {
        var active = false
        var onApply: ((String) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyRegions()
        }

        func applyRegions() {
            guard let root = window?.rootViewController else { return }
            let target: UIViewController.SafeAreaRegions = active ? .container : .all
            var changed = false
            func walk(_ vc: UIViewController) {
                if vc.safeAreaRegions != target {
                    vc.safeAreaRegions = target
                    changed = true
                }
                vc.children.forEach(walk)
            }
            walk(root)
            if changed {
                onApply?(active
                    ? "root keyboard safe area OFF (search page)"
                    : "root keyboard safe area ON")
            }
        }
    }
}

// A tapped Shazam notification lands here: resolve the song in
// the account storefront and play it, Now Playing open - the tap
// IS her asking to hear it.
extension RootView {
    func playShazamSong(_ id: String) {
        Task {
            if let s = await api.songFull(id: id) {
                player.playSongs([s], start: 0)
                nav.showNowPlaying = true
            }
        }
    }
}

// Four little bars that dance while Shazam listens.
struct ListeningBars: View {
    @EnvironmentObject var settings: AppSettings
    @State private var on = false
    private let up: [CGFloat] = [0.45, 1.0, 0.6, 0.85]
    private let down: [CGFloat] = [0.9, 0.5, 1.0, 0.55]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(settings.accent)
                    .frame(width: 3.5, height: 14)
                    .scaleEffect(y: on ? up[i] : down[i])
                    .animation(.easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.13), value: on)
            }
        }
        .onAppear { on = true }
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
                        MarqueeText(text: player.current?.title ?? "",
                                    font: .subheadline.weight(.semibold),
                                    uiFont: .systemFont(ofSize: 15, weight: .semibold))
                        MarqueeText(text: player.current?.artist ?? "",
                                    font: .caption,
                                    uiFont: .systemFont(ofSize: 12),
                                    color: .secondary)
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
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { nav.showNowPlaying = true }
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

// One droplet rail segment, used identically for the top (Home/Search/Radio/
// Library) and bottom (Favorites/Settings) groups. The glass lens rides BEHIND
// the item content — content drawn over glass gets optically doubled by the
// backdrop refraction — follows the finger 1:1, grows elastically while the
// finger holds it, stretches a little toward the drag, and springs onto the
// chosen item on release. Clearest official glass tier (.clear) throughout.
struct RailSegment: View {
    @EnvironmentObject var settings: AppSettings
    var pages: [Page]
    var firstCenter: CGFloat
    var topPad: CGFloat
    var bottomPad: CGFloat
    @Binding var selection: Page
    var showsLogo: Bool = false
    @State private var dragY: CGFloat? = nil
    @State private var target: Page? = nil
    private let step: CGFloat = 62

    private func center(of p: Page) -> CGFloat {
        firstCenter + CGFloat(pages.firstIndex(of: p) ?? 0) * step
    }
    private func pageAt(y: CGFloat) -> Page {
        pages.min(by: { abs(center(of: $0) - y) < abs(center(of: $1) - y) }) ?? pages[0]
    }
    private var dragging: Bool { dragY != nil }
    private var shown: Page { target ?? selection }
    private var lensCenter: CGFloat {
        dragY ?? center(of: pages.contains(selection) ? selection : pages[0])
    }

    var body: some View {
        ZStack(alignment: .top) {
            lens
            VStack(spacing: 6) {
                if showsLogo {
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
                }
                ForEach(pages, id: \.self) { p in item(p) }
            }
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
        }
        .frame(width: 74)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragY = min(max(v.location.y, center(of: pages[0])), center(of: pages[pages.count - 1]))
                    target = pageAt(y: v.location.y)
                }
                .onEnded { v in
                    selection = pageAt(y: v.location.y)
                    target = nil
                    dragY = nil
                }
        )
        .aoiGlass(corner: 37)
    }

    private var lens: some View {
        let cy = lensCenter
        let near = pageAt(y: cy)
        let stretch = dragging ? min(0.22, abs(cy - center(of: near)) / 320.0) : 0
        let rr = RoundedRectangle(cornerRadius: 19, style: .continuous)
        return Group {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.clear.interactive(), in: rr)
            } else {
                rr.fill(.white.opacity(0.30))
            }
        }
        .frame(width: 66, height: 56)
        .scaleEffect(x: (dragging ? 1.20 : 1.0) + stretch * 0.3, y: (dragging ? 1.20 : 1.0) + stretch)
        .offset(y: cy - 28)
        .opacity(pages.contains(selection) || dragging ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: dragging)
        .animation(dragging ? nil : .spring(response: 0.38, dampingFraction: 0.62), value: cy)
    }

    private func item(_ p: Page) -> some View {
        let sel = shown == p
        return VStack(spacing: 3) {
            Image(systemName: p.icon)
                .font(.system(size: 21, weight: .semibold))
            Text(settings.t(p.key))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(p == .ai
            ? AnyShapeStyle(LinearGradient(colors: [settings.accent, Color(red: 0.75, green: 0.35, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(sel ? settings.accent : Color.primary.opacity(0.75)))
        .frame(width: 62, height: 56)
        .scaleEffect(sel && dragging ? 1.14 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: sel && dragging)
    }
}
