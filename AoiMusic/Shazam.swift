import Foundation
import AVFoundation
import ShazamKit
import SwiftUI

// v114: in-app Shazam （听音识曲）. Mic audio is fingerprinted on the
// device by ShazamKit and matched against the Shazam catalog; a match
// carries an Apple Music id + ISRC, which the app resolves in the
// account's own storefront and plays at once (Now Playing opens by
// itself). While listening, the app's own playback pauses so the mic
// hears the room, not the speaker feed; it resumes if nothing was
// found. If the signing profile cannot run ShazamKit, the session
// error lands in the same "not available" toast - nothing else in
// the app is touched by a failure here.
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
    private var wasPlaying = false
    private var startedAt = Date()

    func attach(player: Player, api: APIClient, nav: AppNav, settings: AppSettings) {
        self.player = player
        self.api = api
        self.nav = nav
        self.settings = settings
    }

    func toggle() {
        if isListening { stop(restorePlayback: true) } else { start() }
    }

    // Deep-link entry (the home-screen widget): same as tapping the
    // in-app button.
    func startFromWidget() {
        if !isListening { start() }
    }

    private func start() {
        guard let settings = settings else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                if !granted {
                    self.player?.showToast(Strings.get("shazam_mic", settings.lang))
                    return
                }
                self.beginListening()
            }
        }
    }

    private func beginListening() {
        guard let player = player, let settings = settings else { return }
        wasPlaying = player.isPlaying
        if player.isPlaying { player.pauseOnly() }
        do {
            let av = AVAudioSession.sharedInstance()
            try av.setCategory(.playAndRecord, mode: .default, options: [])
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
            cleanupAudio()
            player.showToast(Strings.get("shazam_fail", settings.lang))
            if wasPlaying { player.playOnly() }
            return
        }
        startedAt = Date()
        isListening = true
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self = self, self.isListening else { return }
            self.stop(restorePlayback: true)
            if let p = self.player, let st = self.settings {
                p.showToast(Strings.get("shazam_none", st.lang))
            }
        }
    }

    private func stop(restorePlayback: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanupAudio()
        isListening = false
        if restorePlayback, wasPlaying { player?.playOnly() }
        wasPlaying = false
    }

    private func cleanupAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        shSession?.delegate = nil
        shSession = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handleMatch(_ item: SHMediaItem) {
        guard isListening else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanupAudio()
        isListening = false
        wasPlaying = false
        guard let api = api, let player = player, let nav = nav, let settings = settings else { return }
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
                player.showToast(Strings.get("shazam_none", settings.lang))
                return
            }
            player.playSongs([found], start: 0)
            nav.showNowPlaying = true
        }
    }

    private func handleNoMatch(error: Error?) {
        // Streaming sessions report per-signature misses; a miss with
        // no error just means "not this chunk" - keep listening until
        // the timeout. An error (e.g. the profile cannot run
        // ShazamKit) fails fast instead of spinning for 12s.
        guard isListening, let error = error else { return }
        _ = error
        stop(restorePlayback: true)
        if let p = player, let st = settings {
            p.showToast(Strings.get("shazam_fail", st.lang))
        }
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
