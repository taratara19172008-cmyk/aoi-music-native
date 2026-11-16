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

final class EngineBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate {
    static let engineURL = URL(string: "https://taratara19172008-cmyk.github.io/aoi-music/engine.html")!
    let webView: WKWebView
    @Published var ready = false
    @Published var authorized = false
    @Published var storefront = ""
    @Published var userToken = ""

    var onState: ((Bool) -> Void)?
    var onItem: ((EngineItem?) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private var popupVC: UIViewController?
    private var popupWebView: WKWebView?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(self, name: "aoi")
        webView.uiDelegate = self
        webView.isHidden = true
        webView.load(URLRequest(url: Self.engineURL))
    }

    // MARK: - JS -> Swift
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
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
    func authorize() { call("window.AoiEngine && AoiEngine.authorize()") }
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
    private static func topPresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
