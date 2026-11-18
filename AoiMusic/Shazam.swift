import Foundation
import AVFoundation
import ShazamKit
import SwiftUI
import UserNotifications

// v114: in-app Shazam （听音识曲）. Mic audio is fingerprinted on the
// device by ShazamKit and matched against the Shazam catalog; a match
// carries an Apple Music id + ISRC, which the app resolves in the
// account's own storefront.
// v115 (her trial feedback + GPT round 3): the record session mixes
// with other audio instead of interrupting it (the old options: []
// made .playAndRecord non-mixable, so starting a listen killed the
// phone's music - the very thing there was to recognize), the app
// no longer pauses its own playback, and a match is delivered as a
// NOTIFICATION carrying the song card instead of auto-playing.
// Platform limit, stated plainly: the mic hears speaker output;
// audio playing into headphones is not capturable by third-party
// apps (Apple's own Shazam is a privileged system service).
@MainActor
final class ShazamRecognizer: NSObject, ObservableObject {
    @Published var isListening = false

    private weak var player: Player?
    private weak var api: APIClient?
    private weak var nav: AppNav?
    private weak var settings: AppSettings?

    private var shSession: SHSession?
    private let audioEngine = AVAudioEngine()
    private var timeoutTask: Task<Void, Never>?
    // v116 (her spec): whether music was playing when listening
    // started - recognition must not stop it, so an activation
    // that still manages to pause it gets quietly undone.
    private var wasPlayingBeforeListen = false
    private var isStarting = false
    private var startedAt = Date()

    func attach(player: Player, api: APIClient, nav: AppNav, settings: AppSettings) {
        self.player = player
        self.api = api
        self.nav = nav
        self.settings = settings
    }

    func toggle() {
        if isListening { stop() } else { start() }
    }

    // Deep-link entry (the home-screen widget): same as tapping the
    // in-app button.
    func startFromWidget() {
        if !isListening { start() }
    }

    private func start() {
        guard let settings = settings, !isListening, !isStarting else { return }
        isStarting = true
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                if !granted {
                    self.isStarting = false
                    self.player?.showToast(Strings.get("shazam_mic", settings.lang))
                    return
                }
                self.beginListening()
            }
        }
    }

    private func beginListening() {
        guard let player = player, let settings = settings else { return }
        wasPlayingBeforeListen = player.isPlaying
        do {
            let av = AVAudioSession.sharedInstance()
            // v115 (GPT round 3): .mixWithOthers is the fix for
            // "recording kills the phone's music" - without it,
            // activating a .playAndRecord session interrupts every
            // other non-mixable audio session on the phone. With
            // it, other apps keep playing through the speaker and
            // the mic hears them. Our own playback is NOT paused
            // either (the old code paused it on purpose; with the
            // mix fixed there is nothing to protect the mic from -
            // speaker output is exactly what it should hear).
            try av.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try av.setActive(true)
            try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            let session = SHSession()
            session.delegate = self
            shSession = session
            audioEngine.inputNode.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak session] buffer, time in
                session?.matchStreamingBuffer(buffer, at: time)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            let ne = error as NSError
            player.engine.logEvent("shazam: beginListening failed (\(ne.domain) \(ne.code): \(ne.localizedDescription))")
            isStarting = false
            cleanupAudio()
            player.showToast(Strings.get("shazam_fail", settings.lang))
            return
        }
        startedAt = Date()
        isListening = true
        isStarting = false
        // v118: the session switch interrupts MusicKit at the
        // activation instant - counter it in the same instant,
        // not 400ms later. The delayed force-resume loop below
        // stays as the backstop.
        if wasPlayingBeforeListen {
            player.resumeAfterInterruption(force: true)
        }
        // v115: unmistakable state feedback - a toast now, and the
        // root view shows a "listening" pill for the whole session.
        player.showToast(Strings.get("shazam_listening", settings.lang))
        // v116 (her spec): starting recognition must not stop the
        // phone's music. .mixWithOthers keeps other apps audible,
        // but the session activation itself can still pause the
        // engine's webview playback - check twice shortly after
        // and quietly resume if it did.
        if wasPlayingBeforeListen {
            Task { [weak self] in
                // v117: force the resume and do NOT consult
                // isPlaying - in the interruption state MusicKit
                // reports playing while the output is paused, so
                // the v116 checks talked themselves out of acting.
                for delay in [400_000_000, 1_300_000_000, 2_000_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard let self = self, self.isListening, self.wasPlayingBeforeListen,
                          let p = self.player else { continue }
                    p.resumeAfterInterruption(force: true)
                }
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self = self, self.isListening else { return }
            self.stop()
            if let p = self.player, let st = self.settings {
                p.showToast(Strings.get("shazam_none", st.lang))
            }
        }
    }

    // v117: ONE teardown-resume path for every exit from
    // listening. v116 had it only in stop(); the success path
    // (handleMatch) cleaned up the audio session and never
    // resumed, stranding the song paused after every successful
    // identification - the exact complaint she filed at 09:45.
    private func resumeMusicAfterTeardown() {
        guard wasPlayingBeforeListen else { return }
        wasPlayingBeforeListen = false
        Task { [weak self] in
            for delay in [300_000_000, 900_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard let p = self?.player else { continue }
                p.resumeAfterInterruption(force: true)
            }
        }
    }

    private func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanupAudio()
        isListening = false
        resumeMusicAfterTeardown()
    }

    private func cleanupAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        shSession?.delegate = nil
        shSession = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        // v117 (GPT round 4): hand the session back in the Player's
        // playback configuration BEFORE the force-resume checks
        // run - deactivating alone left the session in the
        // recording category, which kept the webview's output
        // paused even when a force play() landed.
        player?.restorePlaybackAudioSession()
    }

    private func handleMatch(_ item: SHMediaItem) {
        guard isListening else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanupAudio()
        isListening = false
        resumeMusicAfterTeardown()
        guard let api = api, let player = player, let settings = settings else { return }
        Task {
            var song: Song? = nil
            if let amid = item.appleMusicID, !amid.isEmpty {
                song = await api.songFull(id: amid)
            }
            if song == nil {
                // Cross-storefront or unresolved id: resolve the same
                // recording in the account storefront by ISRC, then
                // by name+artist (the v114 resolver).
                var probe = Song(id: item.appleMusicID ?? "", type: "songs", attributes: nil)
                probe.attributes = SongAttrs(name: item.title, artistName: item.artist ?? item.subtitle,
                                             isrc: item.isrc)
                song = await api.resolveInStorefront(probe)
            }
            guard let found = song else {
                // v115 (GPT review item 13's lesson): a failed
                // resolution must end in a clear message, never in
                // silently stranded state.
                player.showToast(Strings.get("shazam_none", settings.lang))
                return
            }
            // v115 (her spec): NO auto-play, no forced navigation -
            // the match arrives as a notification carrying the
            // song's card (cover, title, artist). Tapping it opens
            // the song in the player (see AoiMusicApp/RootView).
            await ShazamCardNotifier.post(song: found)
            player.showToast(Strings.get("shazam_found", settings.lang))
        }
    }

    private func handleNoMatch(error: Error?) {
        // Streaming sessions report per-signature misses; a miss with
        // no error just means "not this chunk" - keep listening until
        // the timeout. An error (e.g. the profile cannot run
        // ShazamKit) fails fast instead of spinning for 12s.
        guard isListening, let error = error else { return }
        let ne = error as NSError
        var desc = "shazam: match failed (\(ne.domain) \(ne.code): \(ne.localizedDescription))"
        if let she = error as? SHError, she.code == .matchAttemptFailed {
            desc += " [matchAttemptFailed: Shazam catalog service failure]"
        }
        player?.engine.logEvent(desc)
        stop()
        if let p = player, let st = settings {
            p.showToast(Strings.get("shazam_fail", st.lang))
        }
    }
}

// v115: delivers a recognized song as a local notification with
// the cover attached - the "music card" she asked for. Permission
// is requested lazily at the first match; if it is denied, the
// in-app toast still names the outcome (the caller shows it).
enum ShazamCardNotifier {
    static func post(song: Song) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = song.title
        content.body = song.artist
        content.sound = .default
        content.categoryIdentifier = "aoi.shazamSong"
        content.userInfo = ["songId": song.id]
        if let artStr = song.art(512, 512), let url = URL(string: artStr),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let file = dir.appendingPathComponent("shazam-card-\(song.id).jpg")
            if (try? data.write(to: file, options: .atomic)) != nil,
               let att = try? UNNotificationAttachment(identifier: "art", url: file, options: nil) {
                content.attachments = [att]
            }
        }
        let req = UNNotificationRequest(
            identifier: "shazam-\(song.id)-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        try? await center.add(req)
    }
}

extension ShazamRecognizer: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        Task { @MainActor in self.handleMatch(item) }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        Task { @MainActor in self.handleNoMatch(error: error) }
    }
}

// The home-page button: a native-glass disc carrying the official
// Shazam glyph in the theme colour. While listening it breathes and
// throws expanding glass ripple rings.
struct ShazamButton: View {
    @EnvironmentObject var shazam: ShazamRecognizer
    @EnvironmentObject var settings: AppSettings
    @State private var ripple = false

    var body: some View {
        Button { shazam.toggle() } label: {
            ZStack {
                if shazam.isListening {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .stroke(settings.accent.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 54, height: 54)
                            .scaleEffect(ripple ? 1.55 : 1.0)
                            .opacity(ripple ? 0 : 0.75)
                            .animation(.easeOut(duration: 1.7)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.85), value: ripple)
                    }
                }
                Image(systemName: "shazam.logo")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(settings.accent)
                    .scaleEffect(shazam.isListening ? (ripple ? 1.10 : 0.93) : 1.0)
                    .animation(shazam.isListening
                               ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                               : .default, value: ripple)
                    .frame(width: 54, height: 54)
                    .aoiGlass(corner: 27, interactive: true)
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: shazam.isListening) { _, on in ripple = on }
        .onAppear { ripple = shazam.isListening }
    }
}
