import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @State private var customColor: Color = .red
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropImage: UIImage?
    @State private var showCrop = false
    @State private var aiKeyText = ""
    @State private var aiProviderId = AIProvider.currentId
    @State private var aiCustomEndpoint = ""
    @State private var aiCustomModel = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.t("settings"))
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 14)

                SectionTitle(text: settings.t("account"))
                HStack(spacing: 10) {
                    Image(systemName: engine.authorized ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.title3)
                        .foregroundStyle(engine.authorized ? Color.green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(engine.authorized ? settings.t("connected") : settings.t("not_connected"))
                            .font(.subheadline.weight(.semibold))
                        Text("\(settings.t("storefront")): \(api.storefront)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(engine.authorized ? settings.t("disconnect") : settings.t("connect")) {
                        if engine.authorized { engine.unauthorize() } else { engine.authorize() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .aoiGlass(corner: 14, interactive: true)
                    .buttonStyle(.plain)
                }
                .padding(12)
                .aoiGlass(corner: 18)
                Text(engineDiag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                SectionTitle(text: settings.t("ai_provider"))
                VStack(alignment: .leading, spacing: 8) {
                    Picker(settings.t("ai_provider"), selection: $aiProviderId) {
                        ForEach(AIProvider.all) { p in
                            Text(p.id == "custom" ? settings.t("ai_custom") : p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: aiProviderId) { id in
                        AIProvider.select(id)
                        aiKeyText = AIKeyStore.get(forProvider: id)
                    }
                    if aiProviderId == "custom" {
                        TextField(settings.t("ai_endpoint_ph"), text: $aiCustomEndpoint)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField(settings.t("ai_model_ph"), text: $aiCustomModel)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField(settings.t("ai_key_ph"), text: $aiKeyText)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(alignment: .bottom, spacing: 10) {
                        Text(settings.t("ai_key_note"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(settings.t("save")) {
                            AIProvider.select(aiProviderId)
                            if aiProviderId == "custom" {
                                AIProvider.setCustom(endpoint: aiCustomEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     model: aiCustomModel.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            AIKeyStore.set(aiKeyText.trimmingCharacters(in: .whitespacesAndNewlines), forProvider: aiProviderId)
                            player.showToast(settings.t("ai_key_saved"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.accent)
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .aoiGlass(corner: 18)
                .onAppear {
                    aiProviderId = AIProvider.currentId
                    aiKeyText = AIKeyStore.get()
                    aiCustomEndpoint = AIProvider.customEndpoint
                    aiCustomModel = AIProvider.customModel
                }

                SectionTitle(text: settings.t("theme"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Accents.presets) { p in
                        Button { settings.accentHex = p.hex } label: {
                            Circle()
                                .fill(Accents.color(hex: p.hex))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if settings.accentHex.lowercased() == p.hex.lowercased() {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: customColor) { c in
                            if let hex = hexOf(c) { settings.accentHex = hex }
                        }
                }
                .padding(12)
                .aoiGlass(corner: 18)

                SectionTitle(text: settings.t("background"))
                HStack(spacing: 12) {
                    if let img = settings.bgImage {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text(settings.t("pick_bg"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(settings.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .aoiGlass(corner: 14, interactive: true)
                    }
                    if settings.bgImage != nil {
                        Button(settings.t("reset_bg")) { settings.bgImage = nil }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .aoiGlass(corner: 18)
                .onChange(of: pickerItem) { item in
                    guard let item = item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            // v114: framing step first - she picks the
                            // exact region that becomes the background.
                            cropImage = img
                            showCrop = true
                        } else {
                            player.showToast(settings.t("bg_too_big"))
                        }
                    }
                }
                .fullScreenCover(isPresented: $showCrop) {
                    if let img = cropImage {
                        BgCropView(image: img) { result in
                            if let r = result {
                                settings.bgImage = downscale(r)
                                player.showToast(settings.t("bg_saved"))
                            }
                            showCrop = false
                            cropImage = nil
                            pickerItem = nil
                        }
                    }
                }

                SectionTitle(text: settings.t("language"))
                GeometryReader { geo in
                    HStack(spacing: 10) {
                        langPill("中文", "zh")
                        langPill("English", "en")
                        Spacer()
                    }
                    .padding(12)
                    .aoiGlass(corner: 18)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { v in settings.lang = v.location.x < geo.size.width * 0.4 ? "zh" : "en" }
                    )
                }
                .frame(height: 60)

                SectionTitle(text: settings.t("about"))
                Text(settings.t("about_text"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aoiGlass(corner: 18)
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onAppear { customColor = settings.accent }
    }

    private var engineDiag: String {
        var s = "Engine ready: \(engine.ready ? "yes" : "no") · Page loaded: \(engine.pageLoaded ? "yes" : "no")"
        s += "\n引擎版本: v" + engine.engineVersion + "（" + engine.engineSource + "）"
        if !engine.lastError.isEmpty { s += "\n" + engine.lastError }
        // Widget data channel (v108): the now-playing widget reads through
        // the app group; if the sideload signature dropped the group, this
        // says so plainly instead of the widget silently showing nothing.
        let groupOK = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.c2bb27f0fc08e2b5.1") != nil
        let hasSong = UserDefaults(suiteName: "group.c2bb27f0fc08e2b5.1")?.string(forKey: "np_title") != nil
        s += "\n小组件通道: " + (groupOK ? (hasSong ? "正常 · 已有歌曲数据" : "正常 · 暂无歌曲数据") : "不可用（签名未包含 App Group）")
        return s
    }

    private func langPill(_ title: String, _ code: String) -> some View {
        Button { settings.lang = code } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.lang == code ? .white : .primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background {
                    if settings.lang == code {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(settings.accent)
                    }
                }
                .aoiGlass(corner: 14, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func hexOf(_ color: Color) -> String? {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func downscale(_ img: UIImage) -> UIImage {
        let maxSide: CGFloat = 1170
        let w = img.size.width, h = img.size.height
        let scale = min(1, maxSide / max(w, h))
        if scale >= 1 { return img }
        let size = CGSize(width: w * scale, height: h * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}


// v114: background framing step. The picked photo is shown inside a
// frame with the screen's own aspect; drag to pan, pinch to zoom
// (the photo always covers the frame), and "use" renders exactly
// the framed region as the new background.
struct BgCropView: View {
    let image: UIImage
    var onDone: (UIImage?) -> Void
    @EnvironmentObject var settings: AppSettings
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var screenAspect: CGFloat {
        let b = UIScreen.main.bounds
        return b.height / max(b.width, 1)
    }

    private func baseScale(frameW: CGFloat, frameH: CGFloat) -> CGFloat {
        max(frameW / max(image.size.width, 1), frameH / max(image.size.height, 1))
    }

    private func clamped(_ o: CGSize, frameW: CGFloat, frameH: CGFloat, z: CGFloat) -> CGSize {
        let bs = baseScale(frameW: frameW, frameH: frameH) * z
        let maxX = max((image.size.width * bs - frameW) / 2, 0)
        let maxY = max((image.size.height * bs - frameH) / 2, 0)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }

    var body: some View {
        GeometryReader { geo in
            let frameW = geo.size.width - 36
            let frameH = min(frameW * screenAspect, geo.size.height - 190)
            let bs = baseScale(frameW: frameW, frameH: frameH) * zoom
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(settings.t("crop_title"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.top, 14)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: image.size.width * bs, height: image.size.height * bs)
                            .offset(offset)
                    }
                    .frame(width: frameW, height: frameH)
                    .clipped()
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.65), lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                offset = clamped(CGSize(width: lastOffset.width + v.translation.width,
                                                        height: lastOffset.height + v.translation.height),
                                                 frameW: frameW, frameH: frameH, z: zoom)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in
                                zoom = min(max(lastZoom * v.magnification, 1), 4)
                                offset = clamped(offset, frameW: frameW, frameH: frameH, z: zoom)
                            }
                            .onEnded { _ in
                                lastZoom = zoom
                                lastOffset = offset
                            }
                    )
                    Text(settings.t("crop_hint"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                    HStack(spacing: 14) {
                        Button(settings.t("cancel")) { onDone(nil) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .aoiGlass(corner: 16, interactive: true)
                        Button(settings.t("crop_use")) {
                            onDone(render(frameW: frameW, frameH: frameH))
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(settings.accent))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // Render exactly the framed region: the editor shows the image at
    // baseScale*zoom with `offset`; replay that transform at 2x into
    // a bitmap of the frame's aspect.
    private func render(frameW: CGFloat, frameH: CGFloat) -> UIImage {
        let out = CGSize(width: frameW * 2, height: frameH * 2)
        let k = out.width / frameW
        let bs = baseScale(frameW: frameW, frameH: frameH) * zoom * k
        let renderer = UIGraphicsImageRenderer(size: out)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: out))
            let drawSize = CGSize(width: image.size.width * bs, height: image.size.height * bs)
            let origin = CGPoint(x: out.width / 2 - drawSize.width / 2 + offset.width * k,
                                 y: out.height / 2 - drawSize.height / 2 + offset.height * k)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
