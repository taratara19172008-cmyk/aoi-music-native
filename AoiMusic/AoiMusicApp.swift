import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let aoiShazamSongTap = Notification.Name("aoiShazamSongTap")
}

// v115: Shazam match notifications. willPresent shows the banner
// even while the app is in the foreground (a match normally lands
// while she is looking at the app); a tap routes the song id to
// RootView, which resolves and plays it. The id is ALSO parked in
// pendingSongId - a tap that cold-launches the app fires before
// RootView has subscribed to the notification.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    static var pendingSongId: String?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let id = response.notification.request.content.userInfo["songId"] as? String {
            NotificationPresenter.pendingSongId = id
            NotificationCenter.default.post(name: .aoiShazamSongTap, object: nil, userInfo: ["songId": id])
        }
    }
}

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

// v119: the app owns its root hosting controller (UIKit scene
// lifecycle instead of a SwiftUI WindowGroup). The reason is the
// search-keyboard war: safeAreaRegions lives on UIHostingController
// (NOT on UIViewController - build #25 proved it), and the only
// way to set it is to hold the hosting controller. While the
// search page is up, KeyboardRegionFixer (RootView) sets
// safeAreaRegions = .container here, which removes the keyboard
// from the SwiftUI layout system at the root; every other page
// restores .all and keeps normal keyboard behaviour.
final class AoiHostingController: UIHostingController<AnyView> {
    static weak var current: AoiHostingController?

    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        Self.current = self
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        Self.current = self
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.current = self
    }

    // Sets the regions and reports the value read BACK from the
    // controller, so the Settings log proves the state instead of
    // assuming the assignment took.
    static func setKeyboardExcluded(_ excluded: Bool, log: (String) -> Void) {
        guard let host = current else { return }
        let target: SafeAreaRegions = excluded ? .container : .all
        guard host.safeAreaRegions != target else { return }
        host.safeAreaRegions = target
        log(excluded
            ? "root keyboard safe area OFF (search page, regions=\(host.safeAreaRegions))"
            : "root keyboard safe area ON (regions=\(host.safeAreaRegions))")
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // The object graph that used to live in the SwiftUI App's
    // @StateObjects; the scene delegate owns it for the scene's
    // lifetime (single-window app).
    private var settings: AppSettings?
    private var api: APIClient?
    private var engine: EngineBridge?
    private var player: Player?
    private var nav: AppNav?
    private var shazam: ShazamRecognizer?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let settings = AppSettings()
        let api = APIClient()
        let engine = EngineBridge()
        let player = Player(engine: engine, api: api)
        let nav = AppNav()
        let shazam = ShazamRecognizer()
        self.settings = settings
        self.api = api
        self.engine = engine
        self.player = player
        self.nav = nav
        self.shazam = shazam

        let root = RootView()
            .environmentObject(settings)
            .environmentObject(api)
            .environmentObject(engine)
            .environmentObject(player)
            .environmentObject(nav)
            .environmentObject(shazam)
            .onAppear { shazam.attach(player: player, api: api, nav: nav, settings: settings) }
            .onReceive(engine.$userToken) { api.userToken = $0 }
            .onReceive(engine.$storefront) { sf in
                if !sf.isEmpty { api.storefront = sf }
            }

        let host = AoiHostingController(rootView: AnyView(root))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window

        for ctx in connectionOptions.urlContexts { handleURL(ctx.url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for ctx in URLContexts { handleURL(ctx.url) }
    }

    private func handleURL(_ url: URL) {
        if url.scheme == "aoimusic", url.host == "shazam" {
            shazam?.startFromWidget()
        }
    }
}
