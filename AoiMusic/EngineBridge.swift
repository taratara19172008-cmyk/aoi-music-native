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

// v115 (GPT review item 4): WKUserContentController retains its
// message handlers, so registering the bridge directly created a
// retain cycle (bridge -> webView -> configuration -> ucc ->
// bridge). The bridge lives for the app's whole lifetime, so the
// cycle was inert in practice, but the weak proxy costs nothing
// and removes it. The bridge must hold the proxy STRONGLY (a weak
// handler that deallocates would silently stop all messages).
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class EngineBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    static let engineBaseURL = URL(string: "https://music.apple.com")!
    let webView: WKWebView
    @Published var ready = false
    @Published var authorized = false
    // v117: false until the CURRENT page generation posts its first
    // auth state - distinguishes "engine still recovering" from a
    // genuinely unauthorized account (problem 7's false "not connected").
    @Published var authStateKnown = false
    @Published var storefront = ""
    @Published var userToken = ""
    @Published var lastError = ""
    @Published var pageLoaded = false
    @Published var engineVersion = ""
    @Published var engineSource = ""
    private var scriptProxy: WeakScriptMessageHandler?
    private var pendingAuthorize = false
    private var probeTimer: Timer?
    private var lastProbe = ""
    private var lastFrame = ""

    var onState: ((Bool) -> Void)?
    var onItem: ((EngineItem?) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onForeground: (() -> Void)?
    var onPreviewHealed: ((String, Int) -> Void)?
    var onPreviewExhausted: ((String, Int) -> Void)?

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
        // v118: stub JS dialogs in every frame (forMainFrameOnly:
        // false). MusicKit surfaces fatal errors (MEDIA_KEY,
        // "The operation was aborted.", "Load failed") through
        // window.alert in frames the delegate never saw; the stub
        // swallows them and reports each one to the Settings log.
        let dialogStub = WKUserScript(source: #"""
        (function () {
          function report(kind, msg) {
            try {
              window.webkit.messageHandlers.aoi.postMessage({ type: 'jsdialog', kind: kind, message: String(msg == null ? '' : msg), host: String(location.host || '') });
            } catch (e) {}
          }
          window.alert = function (m) { report('alert', m); };
          window.confirm = function (m) { report('confirm', m); return false; };
          window.prompt = function (m) { report('prompt', m); return null; };
        })();
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        ucc.addUserScript(dialogStub)
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        // v112: transparent - the engine page paints nothing, and the
        // SwiftUI root keeps it at full opacity so WebKit treats the
        // page as genuinely visible (see RootView).
        webView.isOpaque = false
        webView.backgroundColor = .clear
        super.init()
        let proxy = WeakScriptMessageHandler(self)
        scriptProxy = proxy
        ucc.add(proxy, name: "aoi")
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
        startProbeTimer()
    }

    // v117 (GPT round 4, problem 7): the probe used to die forever
    // once the engine first became ready (probe() invalidates it),
    // so after a WebContent process termination nobody waited for
    // the reloaded page to come back. The timer is now restartable.
    private func startProbeTimer() {
        probeTimer?.invalidate()
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
            authStateKnown = true
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
        case "foreground":
            onForeground?()
        case "error":
            logEvent(((body["where"] as? String) ?? "engine") + ": " + ((body["message"] as? String) ?? ""))
            onError?((body["where"] as? String) ?? "engine")
        case "previewHealed":
            onPreviewHealed?((body["id"] as? String) ?? "", (body["generation"] as? NSNumber)?.intValue ?? -1)
        case "previewExhausted":
            onPreviewExhausted?((body["id"] as? String) ?? "", (body["generation"] as? NSNumber)?.intValue ?? -1)
        case "jsdialog":
            // v118: a sub-frame dialog swallowed by the injected stub
            // (see init). Logged with its kind and host so a future
            // escape can be told apart from a stubbed one.
            logEvent("page dialog stubbed [\((body["kind"] as? String) ?? "?") @ \((body["host"] as? String) ?? "?")]: \((body["message"] as? String) ?? "")")
        case "pong":
            if let n = (body["nonce"] as? NSNumber)?.intValue, n == pendingPongNonce {
                pendingPongNonce = nil
                let cb = pongCompletion
                pongCompletion = nil
                let engineReady = (body["ready"] as? Bool) ?? false
                logEvent("engine health check ok (ready=\(engineReady))")
                cb?(engineReady)
            }
        default:
            break
        }
    }

    // MARK: - Swift -> JS
    private func call(_ js: String) {
        // v112: commands sent before the engine is ready are silently
        // dropped by the `window.AoiEngine &&` guard in each call -
        // log them so a lost command is at least visible in the log.
        if !ready { logEvent("call before ready (guard will drop): " + String(js.prefix(48))) }
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
    // v115: auth self-check + serialized recovery (engine 109.12).
    func requestAuthState() { call("window.AoiEngine && AoiEngine.authState()") }
    func recoverAuth() { call("window.AoiEngine && AoiEngine.recoverAuth()") }
    // v116: forced queue rebuild (engine 109.13) - the recovery
    // paths use this instead of playQueue, whose same-list shortcut
    // answered 'play only' and never re-acquired the license.
    func forceReloadQueue() { call("window.AoiEngine && AoiEngine.forceReload()") }
    func playQueue(ids: [String], start: Int, shuffle: Bool, repeatMode: Int, targetJSON: String? = nil) {
        let arr = ids.map { jsString($0) }.joined(separator: ",")
        let dataArg = targetJSON.map { ", " + jsString($0) } ?? ""
        call("window.AoiEngine && AoiEngine.playQueue([\(arr)], \(start), \(shuffle), \(repeatMode)\(dataArg))")
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

    // v116: a JS alert from either web view must never plaster a
    // raw dialog over the UI (MusicKit surfaces its fatal DRM
    // errors, e.g. "MEDIA_KEY: [object Event]", through
    // window.alert). Log the message into the Settings log and
    // dismiss it. The engine page also reroutes window.alert into
    // its own log (engine 109.13); this delegate covers both web
    // views regardless.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        logEvent("page alert suppressed [\(frame.request.url?.host ?? "?")]: \(message)")
        completionHandler()
    }

    // v117 (GPT round 4, problem 6): confirm/prompt get the same
    // treatment - logged with the originating frame's host and
    // answered with the safe default, so no engine-page dialog of
    // any kind can ever surface as a native popup.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        logEvent("page confirm suppressed [\(frame.request.url?.host ?? "?")]: \(message)")
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        logEvent("page prompt suppressed [\(frame.request.url?.host ?? "?")]: \(prompt)")
        completionHandler(nil)
    }

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
    // MARK: - v117 engine liveness (GPT round 4, problem 7)
    private var pendingPongNonce: Int? = nil
    private var pongCompletion: ((Bool) -> Void)? = nil
    private var pongNonceCounter = 0
    private var lastEngineReloadAt = Date.distantPast

    // Called when the app returns to the foreground. A healthy
    // engine answers a nonce pong within ~4s; silence means the
    // page died quietly (WebContent termination without a delegate
    // call, or a boot that stalled under background throttling) and
    // earns ONE bounded reload. The completion runs either way so
    // the caller's foreground logic is never blocked for long.
    func ensureAlive(completion: (() -> Void)? = nil) {
        guard ready else {
            logEvent("engine ensureAlive: not ready (pageLoaded=\(pageLoaded)) - probe restarted")
            startProbeTimer()
            if Date().timeIntervalSince(lastEngineReloadAt) > 30 {
                lastEngineReloadAt = Date()
                webView.reload()
            }
            completion?()
            return
        }
        pongNonceCounter += 1
        let nonce = pongNonceCounter
        pendingPongNonce = nonce
        pongCompletion = { [weak self] engineReady in
            guard let self else { completion?(); return }
            if engineReady { completion?(); return }
            // The page answered but MusicKit never became ready
            // (e.g. a configure failure the old init could not retry):
            // treat it like a dead engine - one bounded reload.
            self.logEvent("engine health check: page alive but MusicKit not ready - treating as not ready")
            self.ready = false
            self.pageLoaded = false
            self.authStateKnown = false
            if Date().timeIntervalSince(self.lastEngineReloadAt) > 30 {
                self.lastEngineReloadAt = Date()
                self.webView.reload()
            }
            self.startProbeTimer()
            completion?()
        }
        call("window.AoiEngine && AoiEngine.healthCheck && AoiEngine.healthCheck(\(nonce))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.pendingPongNonce == nonce else { return }
            self.pendingPongNonce = nil
            let cb = self.pongCompletion
            self.pongCompletion = nil
            self.logEvent("engine health check timed out - reloading engine page")
            if Date().timeIntervalSince(self.lastEngineReloadAt) > 30 {
                self.lastEngineReloadAt = Date()
                self.ready = false
                self.pageLoaded = false
                self.authStateKnown = false
                self.webView.reload()
                self.startProbeTimer()
            }
            cb?(false)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // v111: a non-visible webview's WebContent process is a prime
        // candidate for termination under memory pressure; without a
        // handler the engine would sit dead (or half-dead) until the
        // app is relaunched. Reload is the platform's prescribed
        // recovery; the probe timer and authorize queue pick up from
        // the reloaded page's boot/ready messages.
        // v115 (GPT patch 14): record what authorization looked like
        // BEFORE the reload wipes it - a termination that keeps
        // recurring is the prime suspect for the "logged out by
        // itself" reports, and the reloaded page's own snapshot
        // (auth[configure]) completes the before/after pair.
        logEvent("web content process terminated (was authorized=\(authorized) storefront=\(storefront)), reloading engine")
        ready = false
        pageLoaded = false
        // v112: the reloaded page is a NEW JS environment - do not let
        // the old page's authorization stand in for it. The engine
        // re-posts its auth state after configure.
        authorized = false
        // v117: the new generation's auth is UNKNOWN until it posts;
        // the UI must show "recovering", not "not connected". And
        // the probe restarts so somebody waits for the page to
        // finish booting (it used to stay dead after first ready).
        authStateKnown = false
        lastEngineReloadAt = Date()
        webView.reload()
        startProbeTimer()
    }
    private static func topPresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
