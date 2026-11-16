import WidgetKit
import SwiftUI
import AppIntents

// The smallest square widget (her spec, v107): the current song's cover
// fills the whole face, and three fully transparent liquid-glass buttons
// ride along the bottom — previous, play/pause, next. In the system's
// clear theme the cover itself turns to liquid glass, because the
// artwork IS the widget's container background, which is exactly the
// layer clear mode glassifies. State arrives through the app group the
// app publishes into (see WidgetShared in the app target); the buttons
// post transport commands back through the same group + a Darwin
// notification, which the app executes on its playback engine.
private let groupId = "group.com.aoimusic.app"
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

private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct AccentedDesat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.widgetAccentedRenderingMode(.desaturated)
        } else {
            content
        }
    }
}

struct NPWidgetView: View {
    var entry: NPEntry

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { artwork }
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = entry.art {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .modifier(AccentedDesat())
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

    private func glassButton<I: AppIntent>(_ icon: String, intent: I) -> some View {
        Button(intent: intent) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .modifier(GlassCircle())
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

@main
struct AoiWidgetBundle: WidgetBundle {
    var body: some Widget {
        AoiNowPlayingWidget()
    }
}
