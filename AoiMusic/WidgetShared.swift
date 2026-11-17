import Foundation
import WidgetKit

// Shared state with the home-screen widget (v107): the app publishes the
// now-playing snapshot into the app group; the widget renders it and
// sends transport commands back through the same group plus a Darwin
// notification (see Player.handleWidgetCommand). The group id and keys
// are duplicated in the widget target — keep them in sync.
enum WidgetShared {
    static let groupId = "group.c2bb27f0fc08e2b5.1"
    static let commandKey = "np_command"
    static let commandNotification = "com.aoimusic.widget.command"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupId) }
    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId)
    }

    static func publish(title: String, artist: String, isPlaying: Bool) {
        defaults?.set(title, forKey: "np_title")
        defaults?.set(artist, forKey: "np_artist")
        defaults?.set(isPlaying, forKey: "np_playing")
        WidgetCenter.shared.reloadAllTimelines()
    }

    // v114: the widgets tint their glass with the app's theme colour.
    static func publishAccent(_ hex: String) {
        defaults?.set(hex, forKey: "accent_hex")
    }

    static func publishArtwork(_ data: Data) {
        guard let dir = container else { return }
        try? data.write(to: dir.appendingPathComponent("np_art.jpg"), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func takeCommand() -> String? {
        guard let d = defaults, let c = d.string(forKey: commandKey), !c.isEmpty else { return nil }
        d.removeObject(forKey: commandKey)
        return c
    }
}
