import Foundation
import WebKit
import UIKit

struct EngineItem: Decodable {
    var id: String
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?
    var duration: Double?
}

final class EngineBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    static let engineBaseURL = URL(string: "https://music.apple.com")!
    let webView: WKWebView
    @Published var ready = false
    @Published var authorized = false
    @Published var storefront = ""
    @Published var userToken = ""
    @Published var lastError = ""
    @Published var pageLoaded = false
    @Published var engineVersion = ""
    @Published var engineSource = ""
    private var pendingAuthorize = false
    private var probeTimer: Timer?
    private var lastProbe = ""
    private var lastFrame = ""

    var onState: ((Bool) -> Void)?
    var onItem: ((EngineItem?) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onQueue: (([String]) -> Void)?

    func logEvent(_ s: String) {
        var lines = lastError.isEmpty ? [] : lastError.components(separatedBy: "\n")
        lines.append(s)
        if lines.count > 80 { lines = Array(lines.suffix(80)) }
        lastError = lines.joined(separator: "\n")
    }

    private var popupVC: UIViewController?
    private var popupWebView: WKWebView?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(self, name: "aoi")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // v109: load the newest engine available - the online-updated
        // cache if one was downloaded, else the bundled page - always
        // through the same loadHTMLString + music.apple.com base URL
        // the login depends on, then refresh the cache in the
        // background for the next launch.
        let bundled = Bundle.main.url(forResource: "engine", withExtension: "html")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let html: String
        if let cached = Self.cachedEngineHTML(), Self.isValidEngineHTML(cached) {
            html = cached
            engineSource = "在线更新"
        } else {
            html = bundled
            engineSource = "内置"
        }
        engineVersion = Self.parseEngineVersion(html)
        webView.loadHTMLString(html, baseURL: Self.engineBaseURL)
        logEvent("engine v" + engineVersion + " (" + engineSource + ")")
        fetchEngineUpdate(currentHTML: html)
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.probe() }
    }

    private func probe() {
        if ready { probeTimer?.invalidate(); probeTimer = nil; return }
        let frame = "frame: " + (webView.url?.absoluteString ?? "nil")
        if frame != lastFrame { lastFrame = frame; logEvent(frame) }
        webView.evaluateJavaScript("window.__mkScript + '|' + (typeof window.MusicKit) + '|' + (window.__aoiHasMusic ? 'music' : 'nomusic')") { [weak self] result, error in
            guard let self else { return }
            let text: String
            if let error { text = "probe error: " + error.localizedDescription }
            else if let str = result as? String { text = "probe: " + str }
            else { text = "probe: nil result" }
            if text != self.lastProbe { self.lastProbe = text; self.logEvent(text) }
        }
    }

    // MARK: - Engine online update (v109)
    // The playback engine is an HTML/JS page; iOS forbids downloading
    // native code, but a web engine may refresh itself. At launch the
    // bridge loads the newest cached copy (bundle as fallback) and
    // fetches the repo's latest engine.html in the background; a newer
    // copy applies on the NEXT launch, so playback fixes ship without
    // reinstalling the app.
    private static let engineRemoteURL = URL(string: "https://raw.githubusercontent.com/taratara19172008-cmyk/aoi-music-native/main/AoiMusic/engine.html")!
    private static func engineCacheURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("engine-cache.html")
    }
    private static func cachedEngineHTML() -> String? {
        guard let url = engineCacheURL() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    private static func isValidEngineHTML(_ s: String) -> Bool {
        s.contains("window.AoiEngine") && s.contains("AOI_CONFIG") && s.contains("ENGINE_VERSION")
    }
    private static func parseEngineVersion(_ html: String) -> String {
        guard let r = html.range(of: "ENGINE_VERSION = '") else { return "?" }
        let rest = html[r.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return "?" }
        return String(rest[..<end])
    }
    private func fetchEngineUpdate(currentHTML: String) {
        var req = URLRequest(url: Self.engineRemoteURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self, let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let s = String(data: data, encoding: .utf8),
                  Self.isValidEngineHTML(s), s != currentHTML,
                  let url = Self.engineCacheURL() else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: url, options: .atomic)) != nil {
                let v = Self.parseEngineVersion(s)
                DispatchQueue.main.async { self.logEvent("engine update v" + v + " downloaded, applies next launch") }
            }
        }.resume()
    }

    // MARK: - JS -> Swift
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "boot":
            if let v = body["version"] as? String, !v.isEmpty { engineVersion = v }
            logEvent("boot ok, waiting for MusicKit")
        case "log":
            logEvent((body["message"] as? String) ?? "")
        case "ready":
            ready = true
            logEvent("engine ready")
            if pendingAuthorize { pendingAuthorize = false; authorize() }
        case "auth":
            authorized = (body["authorized"] as? Bool) ?? false
            storefront = (body["storefront"] as? String) ?? ""
            userToken = (body["token"] as? String) ?? ""
        case "state":
            onState?((body["isPlaying"] as? Bool) ?? false)
        case "item":
            if let raw = body["item"], !(raw is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let item = try? JSONDecoder().decode(EngineItem.self, from: data) {
                onItem?(item)
            } else {
                onItem?(nil)
            }
        case "progress":
            onProgress?((body["t"] as? Double) ?? 0, (body["d"] as? Double) ?? 0, (body["isPlaying"] as? Bool) ?? false)
        case "queue":
            onQueue?((body["ids"] as? [String]) ?? [])
        case "error":
            logEvent(((body["where"] as? String) ?? "engine") + ": " + ((body["message"] as? String) ?? ""))
            onError?((body["where"] as? String) ?? "engine")
        default:
            break
        }
    }

    // MARK: - Swift -> JS
    private func call(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            // void(): engine methods return Promises, and evaluateJavaScript
            // cannot bridge a Promise result - it reported "unsupported
            // type" for every transport call and drowned the v108
            // diagnostics in noise. The commands always executed; only
            // the result value was unreturnable. Discard it explicitly.
            self?.webView.evaluateJavaScript("void (" + js + ")") { [weak self] _, err in
                if let err = err { self?.logEvent("call failed: " + err.localizedDescription) }
            }
        }
    }
    private func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]), let arr = String(data: data, encoding: .utf8) {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\(s)\""
    }
    func authorize() {
        if !ready {
            if !pendingAuthorize { logEvent("tap connect: engine not ready, queued") }
            pendingAuthorize = true
            if !pageLoaded { webView.reload() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("void (window.AoiEngine && AoiEngine.authorize())", completionHandler: { _, err in
                if let err = err {
                    DispatchQueue.main.async { self?.logEvent("call failed: " + err.localizedDescription) }
                }
            })
        }
    }
    func unauthorize() { call("window.AoiEngine && AoiEngine.unauthorize()") }
    func playQueue(ids: [String], start: Int, shuffle: Bool, repeatMode: Int) {
        let arr = ids.map { jsString($0) }.joined(separator: ",")
        call("window.AoiEngine && AoiEngine.playQueue([\(arr)], \(start), \(shuffle), \(repeatMode))")
    }
    func play() { call("window.AoiEngine && AoiEngine.play()") }
    func pause() { call("window.AoiEngine && AoiEngine.pause()") }
    func next() { call("window.AoiEngine && AoiEngine.next()") }
    func prev() { call("window.AoiEngine && AoiEngine.prev()") }
    func jumpTo(_ i: Int) {
        call("window.AoiEngine && AoiEngine.jumpTo(\(i))")
    }
    func seek(_ sec: Double) { call("window.AoiEngine && AoiEngine.seek(\(sec))") }
    func callStation(_ id: String) { call("window.AoiEngine && AoiEngine.playStation(\(jsString(id)))") }
    func setShuffle(_ b: Bool) { call("window.AoiEngine && AoiEngine.setShuffle(\(b))") }
    func setRepeat(_ m: Int) { call("window.AoiEngine && AoiEngine.setRepeat(\(m))") }

    // MARK: - Authorize popup (MusicKit JS opens a window)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popupWebView = popup
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        popup.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            popup.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            popup.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closePopup))
        if let presenter = Self.topPresenter() {
            presenter.present(nav, animated: true)
        }
        popupVC = nav
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView { closePopup() }
    }
    @objc private func closePopup() {
        popupVC?.dismiss(animated: true)
        popupVC = nil
        popupWebView = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        logEvent("page load failed: " + error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        logEvent("page load failed: " + error.localizedDescription)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // v111: a non-visible webview's WebContent process is a prime
        // candidate for termination under memory pressure; without a
        // handler the engine would sit dead (or half-dead) until the
        // app is relaunched. Reload is the platform's prescribed
        // recovery; the probe timer and authorize queue pick up from
        // the reloaded page's boot/ready messages.
        logEvent("web content process terminated, reloading engine")
        ready = false
        pageLoaded = false
        webView.reload()
    }
    private static func topPresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
