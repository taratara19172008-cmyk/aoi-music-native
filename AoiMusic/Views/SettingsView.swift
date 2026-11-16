import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @State private var customColor: Color = .red
    @State private var pickerItem: PhotosPickerItem?
    @State private var aiKeyText = ""

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

                SectionTitle(text: settings.t("ai_key"))
                VStack(alignment: .leading, spacing: 8) {
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
                            AIKeyStore.set(aiKeyText.trimmingCharacters(in: .whitespacesAndNewlines))
                            player.showToast(settings.t("ai_key_saved"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.accent)
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .aoiGlass(corner: 18)
                .onAppear { aiKeyText = AIKeyStore.get() }

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
                            settings.bgImage = downscale(img)
                            player.showToast(settings.t("bg_saved"))
                        } else {
                            player.showToast(settings.t("bg_too_big"))
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
        if !engine.lastError.isEmpty { s += "\n" + engine.lastError }
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
