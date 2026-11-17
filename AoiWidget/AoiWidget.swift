import WidgetKit
import SwiftUI
import AppIntents

// The smallest square widget (her spec): the current song's cover fills
// the whole face, and three glass buttons ride along the bottom —
// previous, play/pause, next. In the system's clear theme the cover
// itself turns to liquid glass, because the artwork IS the widget's
// container background, which is exactly the layer clear mode
// glassifies. State arrives through the app group the app publishes
// into (see WidgetShared in the app target); the buttons post transport
// commands back through the same group + a Darwin notification, which
// the app executes on its playback engine.
// v108: the buttons are plain ultraThinMaterial circles with a stroke —
// v107 put .glassEffect(.clear.interactive()) on the button labels and
// on her phone the buttons rendered as NOTHING at all (empty widget:
// gradient + note, no controls). Bog-standard materials always render.
private let groupId = "group.c2bb27f0fc08e2b5.1"
private let commandKey = "np_command"

private func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupId) }

private func postCommand(_ cmd: String) {
    sharedDefaults()?.set(cmd, forKey: commandKey)
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(rawValue: "com.aoimusic.widget.command" as CFString),
        nil, nil, true)
}

struct PrevIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous track"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        postCommand("prev")
        return .result()
    }
}

struct ToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or pause"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        postCommand("toggle")
        return .result()
    }
}

struct NextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next track"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        postCommand("next")
        return .result()
    }
}

struct NPEntry: TimelineEntry {
    var date: Date
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var art: UIImage? = nil
}

struct NPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NPEntry { NPEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (NPEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NPEntry>) -> Void) {
        // .never: the app reloads the widget itself on every track change.
        completion(Timeline(entries: [current()], policy: .never))
    }
    private func current() -> NPEntry {
        let d = sharedDefaults()
        var e = NPEntry(date: Date(),
                        title: d?.string(forKey: "np_title") ?? "",
                        artist: d?.string(forKey: "np_artist") ?? "",
                        isPlaying: d?.bool(forKey: "np_playing") ?? false)
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId),
           let data = try? Data(contentsOf: dir.appendingPathComponent("np_art.jpg")) {
            e.art = UIImage(data: data)
        }
        return e
    }
}

struct NPWidgetView: View {
    var entry: NPEntry

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                // Soft scrim so the white glyphs stay readable on light covers.
                LinearGradient(colors: [.clear, .black.opacity(0.30)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 68)
            }
            VStack {
                Spacer()
                HStack(spacing: 0) {
                    Spacer()
                    glassButton("backward.fill", intent: PrevIntent())
                    Spacer()
                    glassButton(entry.isPlaying ? "pause.fill" : "play.fill", intent: ToggleIntent())
                    Spacer()
                    glassButton("forward.fill", intent: NextIntent())
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { artwork }
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = entry.art {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.30, blue: 0.42),
                                        Color(red: 0.52, green: 0.28, blue: 0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    // v114: the button IS the glyph - system glass clipped to the
    // symbol's own silhouette, no disc or ring around it. A white
    // gradient of the same glyph rides on top for legibility.
    // glassEffect is iOS 26+; the widget target's deployment target is
    // lower than the app's, so the glass layer needs an availability
    // guard (build 16 failed without it). Her phone runs iOS 26, so
    // the glass branch is always the one taken there; older systems
    // just get the tinted glyph.
    @ViewBuilder
    private func glassGlyph<G: View>(_ glyph: G) -> some View {
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(.white.opacity(0.001))
                .glassEffect(.clear, in: .rect(cornerRadius: 2))
                .mask { glyph }
        }
    }

    private func glassButton<I: AppIntent>(_ icon: String, intent: I) -> some View {
        let glyph = Image(systemName: icon)
            .font(.system(size: 24, weight: .bold))
        return Button(intent: intent) {
            ZStack {
                glassGlyph(glyph)
                glyph
                    .foregroundStyle(
                        LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            .frame(width: 52, height: 52)
            .shadow(color: .black.opacity(0.30), radius: 5, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AoiNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AoiNowPlaying", provider: NPProvider()) { entry in
            NPWidgetView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("封面铺满的小组件，底部按键切歌。")
        .supportedFamilies([.systemSmall])
    }
}

// The app's theme colour, published into the group by the app.
// Named widgetAccent, not accentColor: inside a View, the bare name
// resolves to SwiftUI's View.accentColor member and fails to compile
// (build 16 errors at the Shazam widget call sites).
private func widgetAccent() -> Color {
    let hex = sharedDefaults()?.string(forKey: "accent_hex") ?? "#40c8e0"
    var v: UInt64 = 0
    let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard Scanner(string: clean).scanHexInt64(&v) else { return .cyan }
    return Color(red: Double((v >> 16) & 0xff) / 255,
                 green: Double((v >> 8) & 0xff) / 255,
                 blue: Double(v & 0xff) / 255)
}

// v114: Shazam launcher widget - a small square of liquid glass with
// the official glyph in the theme colour. A widget cannot record
// audio, so the tap opens the app straight into listening mode
// (aoimusic://shazam).
struct ShazamWidgetView: View {
    var body: some View {
        ZStack {
            Image(systemName: "shazam.logo")
                .font(.system(size: 62, weight: .semibold))
                .foregroundStyle(widgetAccent())
                .shadow(color: widgetAccent().opacity(0.45), radius: 12)
            VStack {
                Spacer()
                Text("听音识曲")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [widgetAccent().opacity(0.28), .clear, widgetAccent().opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .widgetURL(URL(string: "aoimusic://shazam"))
    }
}

struct AoiShazamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AoiShazam", provider: NPProvider()) { _ in
            ShazamWidgetView()
        }
        .configurationDisplayName("听音识曲")
        .description("点一下，打开应用开始识别歌曲")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct AoiWidgetBundle: WidgetBundle {
    var body: some Widget {
        AoiNowPlayingWidget()
        AoiShazamWidget()
    }
}
