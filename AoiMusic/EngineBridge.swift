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
    static let engineURL = URL(string: "https://taratara19172008-cmyk.github.io/aoi-music/engine.html")!
    let webView: WKWebView
    @Published var ready = false
    @Published var authorized = false
    @Published var storefront = ""
    @Published var userToken = ""
    @Published var lastError = ""
    @Published var pageLoaded = false
    private var pendingAuthorize = false
    private var probeTimer: Timer?
    private var lastProbe = ""
    private var lastFrame = ""

    var onState: ((Bool) -> Void)?
    var onItem: ((EngineItem?) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onError: ((String) -> Void)?

    func logEvent(_ s: String) {
        var lines = lastError.isEmpty ? [] : lastError.components(separatedBy: "\n")
        lines.append(s)
        if lines.count > 10 { lines = Array(lines.suffix(10)) }
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
        webView.load(URLRequest(url: Self.engineURL, cachePolicy: .reloadIgnoringLocalCacheData))
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

    // MARK: - JS -> Swift
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "boot":
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
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
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
    func jumpTo(_ i: Int) { call("window.AoiEngine && AoiEngine.jumpTo(\(i))") }
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
    private static func topPresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
