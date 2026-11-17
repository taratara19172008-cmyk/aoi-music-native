import SwiftUI

enum DetailRoute: Identifiable, Hashable {
    case collection(kind: String, id: String)
    case artist(id: String)
    var id: String {
        switch self {
        case .collection(let k, let i): return "col-\(k)-\(i)"
        case .artist(let i): return "art-\(i)"
        }
    }
}

final class AppNav: ObservableObject {
    @Published var detail: DetailRoute?
    @Published var showNowPlaying = false
}

@main
struct AoiMusicApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var api: APIClient
    @StateObject private var engine: EngineBridge
    @StateObject private var player: Player
    @StateObject private var nav = AppNav()
    @StateObject private var shazam = ShazamRecognizer()

    init() {
        let api = APIClient()
        let engine = EngineBridge()
        _api = StateObject(wrappedValue: api)
        _engine = StateObject(wrappedValue: engine)
        _player = StateObject(wrappedValue: Player(engine: engine, api: api))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(api)
                .environmentObject(engine)
                .environmentObject(player)
                .environmentObject(nav)
                .environmentObject(shazam)
                .onAppear { shazam.attach(player: player, api: api, nav: nav, settings: settings) }
                .onOpenURL { url in
                    if url.scheme == "aoimusic", url.host == "shazam" { shazam.startFromWidget() }
                }
                .onReceive(engine.$userToken) { api.userToken = $0 }
                .onReceive(engine.$storefront) { sf in
                    if !sf.isEmpty { api.storefront = sf }
                }
        }
    }
}
