import SwiftUI
import UIKit

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

// v120: back to a SwiftUI App + WindowGroup. v119's hand-rolled
// UIKit scene lifecycle (the app-owned AoiHostingController) did
// fix the search keyboard, but it regressed the root layout -
// blank bands appeared at the top and bottom edges and the UI no
// longer painted edge-to-edge the way it had under WindowGroup.
// The keyboard fix survives the revert through a runtime probe:
// SwiftUI's own hosting controller is reached via the window,
// and IF it exposes safeAreaRegions to the Objective-C runtime,
// the regions are set through it (and read back via KVC) exactly
// as v119 set them directly. If a future iOS stops exposing the
// property, the Settings log says so plainly instead of the fix
// silently not applying. The launch geometry is logged once for
// the same reason: the bands question gets numbers, not guesses.
enum KeyboardRegionController {
    private static var lastApplied: UInt?
    private static var geometryLogged = false

    static func setKeyboardExcluded(_ excluded: Bool, window: UIWindow?, log: (String) -> Void) {
        guard let window = window, let root = window.rootViewController else { return }
        if !geometryLogged {
            geometryLogged = true
            let f = root.view.frame
            let ins = root.view.safeAreaInsets
            log("root geometry: host frame \(Int(f.width))x\(Int(f.height)) safeInsets t\(Int(ins.top)) b\(Int(ins.bottom))")
        }
        // SafeAreaRegions raw values: .container = 1<<0,
        // .keyboard = 1<<1, .all = 3.
        let target: UInt = excluded ? 1 : 3
        if lastApplied == target { return }
        let setter = NSSelectorFromString("setSafeAreaRegions:")
        guard type(of: root).instancesRespond(to: setter) else {
            if lastApplied != UInt.max {
                lastApplied = UInt.max
                log("root keyboard safe area: hosting controller does not expose safeAreaRegions - keyboard exclusion unavailable on the WindowGroup path")
            }
            return
        }
        _ = root.perform(setter, with: NSNumber(value: target))
        lastApplied = target
        let getter = NSSelectorFromString("safeAreaRegions")
        if type(of: root).instancesRespond(to: getter),
           let v = root.value(forKey: "safeAreaRegions") as? NSNumber {
            log(excluded
                ? "root keyboard safe area OFF (search page, regions=\(v.uintValue))"
                : "root keyboard safe area ON (regions=\(v.uintValue))")
        } else {
            log(excluded
                ? "root keyboard safe area OFF (search page, set via runtime, no read-back)"
                : "root keyboard safe area ON (set via runtime, no read-back)")
        }
    }
}

@main
struct AoiMusicApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var api: APIClient
    @StateObject private var engine: EngineBridge
    @StateObject private var player: Player
    @StateObject private var nav = AppNav()

    init() {
        let engine = EngineBridge()
        let api = APIClient()
        _engine = StateObject(wrappedValue: engine)
        _api = StateObject(wrappedValue: api)
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
                .onReceive(engine.$userToken) { api.userToken = $0 }
                .onReceive(engine.$storefront) { sf in
                    if !sf.isEmpty { api.storefront = sf }
                }
        }
    }
}
