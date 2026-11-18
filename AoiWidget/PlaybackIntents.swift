import AppIntents
import Foundation

// v115: playback intents, shared by BOTH targets. This file lives
// in the widget folder; the app target compiles it too (see the
// AoiWidget synchronized group in project.pbxproj), so the same
// intent types exist in the app process.
//
// Why: the v107-v114 design ran plain AppIntents in the WIDGET
// process, which wrote a command into the app group and posted a
// Darwin notification. Two facts killed it (GPT round 3, verified
// against Apple's docs): an intent that exists only in the widget
// target runs in the widget process, and the Darwin centre IGNORES
// the deliverImmediately flag - a suspended app is never woken, so
// the buttons silently did nothing. AudioPlaybackIntent is the
// protocol whose intents the system runs in the APP's process.
//
// perform() therefore usually executes right here in the app,
// where PlaybackCommandCenter.appHandler (registered by Player at
// startup) drives the real playback engine. If a copy ever runs in
// the widget process instead, appHandler is nil there and dispatch
// falls back to the group-defaults command + Darwin notification.
enum PlaybackCommandCenter {
    static var appHandler: ((String) -> Void)?

    static func dispatch(_ cmd: String) {
        if let handler = appHandler {
            handler(cmd)
            return
        }
        UserDefaults(suiteName: "group.c2bb27f0fc08e2b5.1")?.set(cmd, forKey: "np_command")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: "com.aoimusic.widget.command" as CFString),
            nil, nil, true)
    }
}

struct PrevIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous track"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.dispatch("prev")
        return .result()
    }
}

struct ToggleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or pause"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.dispatch("toggle")
        return .result()
    }
}

struct NextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next track"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.dispatch("next")
        return .result()
    }
}
