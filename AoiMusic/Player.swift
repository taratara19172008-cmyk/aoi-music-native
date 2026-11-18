import Foundation
import AVFoundation
import MediaPlayer
import WidgetKit

struct SearchEntity: Codable, Identifiable, Hashable {
    var kind: String // song | album | playlist | artist
    var id: String
    var name: String
    var sub: String
    var art: String?
    var song: Song?
}

final class Player: ObservableObject {
    @Published var queue: [Song] = []
    @Published var index: Int = -1
    @Published var current: Song?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    // v114: true when MusicKit substituted a ~30s preview for a song
    // whose full length is minutes (cross-storefront resource). The
    // Now Playing badge reads this instead of assuming engine = full.
    @Published var isPreviewClip = false
    private var previewTried = Set<String>()
    // v115 preview/auth recovery state (GPT rounds 2-3): the badge
    // is a small state machine now - set by detection, cleared ONLY
    // by a confirmed full-length asset or an unrelated track.
    private var previewRecoveryTargetID: String?
    private var pendingRegionToast = false
    // v116: stage bookkeeping for the two-stage preview cure - a
    // forced license reload first (timestamped per track), the
    // storefront twin swap only if the asset stays a preview.
    private var previewForceTriedAt: [String: Date] = [:]
    private var previewStorefrontTried = Set<String>()
    private var queueGeneration = 0
    private var authRecoveryBusy = false
    private var lastForegroundRecovery = Date.distantPast
    private var lastEngineErrorAt: Date?
    @Published var shuffle = false
    @Published var repeatMode = 0 // app: 0 off, 1 all, 2 one
    @Published var useEngine = false
    @Published var history: [Song] = []
    @Published var searchHistory: [SearchEntity] = []
    @Published var favSet: Set<String> = []
    @Published var favSongs: [Song] = []
    @Published var favAlbums: [CollectionItem] = []
    @Published var toast: String?

    let engine: EngineBridge
    let api: APIClient
    private let av = AVPlayer()
    private var timeObserver: Any?
    private var favChecked: Set<String> = []
    private var toastWork: DispatchWorkItem?
    // v108: the 6-second re-issue watchdog that used to live here is GONE.
    // On a slow network the engine legitimately needs longer than that to
    // start a new queue; re-sending the whole playQueue mid-load restarted
    // the load and, together with the engine's own (also removed)
    // verification jumps, broke track switching while the first play of a
    // session worked. One mechanism only now: the engine's serialized op
    // chain, exactly like the web app.

    init(engine: EngineBridge, api: APIClient) {
        self.engine = engine
        self.api = api
        history = Self.loadJSON("aoi-history", [Song].self) ?? []
        searchHistory = Self.loadJSON("aoi-search-entities", [SearchEntity].self) ?? []
        // Favorites survive relaunches: hearts are restored from local storage
        // immediately, not re-derived from the network on every cold start.
        favSongs = Self.loadJSON("aoi-fav-songs", [Song].self) ?? []
        favSet = Set(favSongs.map { "s:" + $0.playbackId })
        favAlbums = Self.loadJSON("aoi-fav-albums", [CollectionItem].self) ?? []
        let favAlbumCountBefore = favAlbums.count
        dedupeFavAlbums()
        if favAlbums.count != favAlbumCountBefore { persistFavAlbums() }
        setupEngine()
        setupPreview()
        setupRemote()
        setupWidgetCommands()
        // v115: widget transport intents (AudioPlaybackIntent) run
        // in THIS process and reach the player through this handler
        // (see PlaybackIntents.swift, shared with the widget target).
        PlaybackCommandCenter.appHandler = { [weak self] cmd in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch cmd {
                case "toggle": self.togglePlay()
                case "next": self.next()
                case "prev": self.prev()
                default: break
                }
            }
        }
    }

    // MARK: - persistence helpers
    static func loadJSON<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func saveJSON<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    var lang: String { UserDefaults.standard.string(forKey: "aoi-lang") ?? "zh" }

    func showToast(_ msg: String) {
        toast = msg
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }

    // MARK: - engine wiring
    // v111: single engine again (the v109 shape). The v110 dual-engine
    // split is reverted in full: the second (Pages) engine's queue
    // never built inside the app webview (instant CONTENT_EQUIVALENT,
    // empty queue, on every attempt from 110.0 to 110.6), and while it
    // existed its idle state/progress ticks fought the real player's
    // on the UI - the play button flickered and switches went nowhere.
    // One engine now: state, progress, items and transport all come
    // from the same place, exactly like v109.
    private func setupEngine() {
        engine.onForeground = { [weak self] in self?.foregroundBecameVisible() }
        engine.onState = { [weak self] playing in
            guard let self = self, self.useEngine else { return }
            if playing != self.isPlaying { self.isPlaying = playing }
            self.updateNowPlayingInfo()
        }
        engine.onProgress = { [weak self] t, d, playing in
            guard let self = self, self.useEngine else { return }
            // v112: progress ticks arrive twice a second; only publish
            // values that actually changed (duration/isPlaying), so the
            // shared Player stops re-rendering the whole view tree on
            // every tick (GPT review Q5.6). currentTime still updates -
            // the progress UI needs it.
            self.currentTime = t
            if d > 0, d != self.duration { self.duration = d }
            if playing != self.isPlaying { self.isPlaying = playing }
            self.checkPreviewClip(t: t, d: d)
        }
        engine.onItem = { [weak self] item in
            guard let self = self, self.useEngine, let item = item else { return }
            if let idx = self.queue.firstIndex(where: { $0.playbackId == item.id || $0.id == item.id }) {
                if idx != self.index { self.index = idx }
                self.current = self.queue[idx]
            } else if self.current?.id != item.id {
                var s = Song(id: item.id, type: "songs", attributes: nil)
                s.attributes = SongAttrs(name: item.title, artistName: item.artist, albumName: item.album, artwork: Artwork(url: item.artwork), previews: nil, durationInMillis: item.duration.map { Int($0 * 1000) })
                self.current = s
            }
            if let c = self.current {
                // v115 (GPT round 2d): an UNRELATED track taking over
                // ends the preview episode. The recovery target
                // itself - the same recording under a new id after
                // a storefront swap - must not clear the badge here;
                // only onProgress confirming a full-length asset may.
                if self.isPreviewClip, let tgt = self.previewRecoveryTargetID, c.playbackId != tgt {
                    self.isPreviewClip = false
                    self.previewRecoveryTargetID = nil
                    self.pendingRegionToast = false
                }
                self.recordHistory(c)
            }
            self.updateNowPlayingInfo()
        }
        engine.onError = { [weak self] kind in
            if kind == "playQueue" || kind == "station" { self?.lastEngineErrorAt = Date() }
            // Only a failed playback attempt may surface the "playback failed" toast,
            // and only if nothing actually started playing shortly after (the engine
            // reports superseded-operation errors that are not real failures).
            guard let self = self, kind == "playQueue" || kind == "station" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.useEngine, !self.isPlaying else { return }
                self.showToast(Strings.get("play_fail", self.lang))
            }
        }
        // v117 (GPT round 4): the engine is the single owner of
        // preview recovery - these are its verdicts, not requests.
        engine.onPreviewHealed = { [weak self] id in self?.handlePreviewHealed(id) }
        engine.onPreviewExhausted = { [weak self] id in self?.handlePreviewExhausted(id) }
    }

    // MARK: - v114 preview-substitution detection + recovery
    // A full song whose loaded asset is only ~30s long means MusicKit
    // took the preview out of a foreign-storefront resource (radio
    // lists are the usual source). Flag it honestly in the UI, then
    // once per song: resolve the same recording in the account's own
    // storefront and replay the queue with it swapped in.
    private func checkPreviewClip(t: Double, d: Double) {
        guard useEngine, let cur = current else { return }
        // Recovery confirmation: the flagged track now reports a
        // believable full-length asset - the badge clears HERE, not
        // when a fix was merely attempted (GPT round 2d).
        if isPreviewClip, let tgt = previewRecoveryTargetID, cur.playbackId == tgt,
           let exp = cur.attributes?.durationInMillis, exp > 90_000,
           d >= 45 || d >= Double(exp) / 1000 * 0.6 {
            isPreviewClip = false
            previewRecoveryTargetID = nil
            previewForceTriedAt[tgt] = nil
            engine.logEvent("preview recovery confirmed for \(tgt): asset duration \(Int(d))s")
            if pendingRegionToast {
                pendingRegionToast = false
                showToast(Strings.get("region_switched", lang))
            }
            return
        }
        guard t >= 2, d > 10, d < 45,
              let exp = cur.attributes?.durationInMillis, exp > 90_000,
              d < Double(exp) / 1000 * 0.6 else { return }
        if !isPreviewClip { isPreviewClip = true }
        previewRecoveryTargetID = cur.playbackId
        let key = cur.playbackId
        guard !previewTried.contains(key) else { return }
        previewTried.insert(key)
        // v117 (GPT round 4): OBSERVE ONLY. The engine's own heal
        // tick sees the same asset and owns the cure; Swift ordering
        // its own rebuild on top is what produced the 2026-11-18
        // 09:50 three-rebuild pile-up. The one Swift-side duty left
        // here is genuine authorization loss (the engine cannot heal
        // while unauthorized), and only when the bridge KNOWS the
        // state - an unknown state means the engine is recovering,
        // not that the account is gone.
        engine.logEvent("preview detected for \(key) - engine owns recovery")
        if engine.authStateKnown, !engine.authorized {
            runAuthRecovery(reason: "preview-clip")
        }
    }

    // v117: the engine reports the song healed - clear the badge
    // and the bookkeeping for exactly that song.
    private func handlePreviewHealed(_ id: String) {
        guard !id.isEmpty else { return }
        previewForceTriedAt[id] = Date()
        if isPreviewClip, current?.playbackId == id {
            isPreviewClip = false
            previewRecoveryTargetID = nil
            engine.logEvent("preview healed confirmed by engine for \(id)")
        } else {
            engine.logEvent("preview healed (engine) for \(id)")
        }
    }

    // v117: the engine gave up on the same-id heal - NOW the
    // storefront twin swap (v116's stage 2) may run, once per song.
    // This is the ONLY trigger for cross-storefront resolution.
    private func handlePreviewExhausted(_ id: String) {
        guard let cur = current, cur.playbackId == id, isPreviewClip else { return }
        guard !previewStorefrontTried.contains(id) else { return }
        previewStorefrontTried.insert(id)
        let keyS = id
        let genS = queueGeneration
        Task { [weak self] in
            guard let self = self else { return }
            let fixed = await self.api.resolveInStorefront(cur)
            guard self.queueGeneration == genS, self.current?.playbackId == keyS else { return }
            guard let fixed = fixed, fixed.id != cur.playbackId, fixed.id != cur.id else {
                self.showToast(Strings.get("preview_only", self.lang))
                return
            }
            var list = self.queue
            for i in list.indices where list[i].playbackId == keyS || list[i].id == cur.id {
                list[i] = fixed
            }
            self.previewTried.insert(fixed.id)
            self.previewRecoveryTargetID = fixed.playbackId
            self.pendingRegionToast = true
            self.playSongs(list, start: self.index, preservePreviewState: true)
        }
    }

    // MARK: - v115 foreground / auth recovery (GPT rounds 2-3)
    // The engine page reports every return to visibility; the app
    // scene phase says the same. Recovery is warranted only when
    // something is actually wrong (preview badge on, or a recent
    // playback error with nothing playing), throttled, and always
    // ordered: probe -> authorize ONLY if truly unauthorized ->
    // replay the CURRENT queue in the foreground. The queue and
    // position are never sacrificed, and nothing retries forever.
    func foregroundBecameVisible() {
        guard useEngine, current != nil else { return }
        // v117 (GPT round 4): foreground return no longer orders
        // queue rebuilds from the Swift side - the engine re-checks
        // its own state on visibility (and the bridge's ensureAlive
        // runs before this). Swift's only foreground duty is genuine
        // authorization loss, and only on a KNOWN state.
        if engine.authStateKnown, !engine.authorized {
            guard Date().timeIntervalSince(lastForegroundRecovery) > 20 else { return }
            lastForegroundRecovery = Date()
            engine.logEvent("foreground: engine reports unauthorized - auth recovery")
            runAuthRecovery(reason: "foreground")
        } else if isPreviewClip {
            engine.logEvent("foreground: preview badge on - engine owns recovery, no Swift rebuild")
        }
    }

    private func runAuthRecovery(reason: String) {
        guard !authRecoveryBusy else { return }
        authRecoveryBusy = true
        engine.logEvent("auth recovery started (\(reason))")
        engine.recoverAuth()
        Task { [weak self] in
            guard let self = self else { return }
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if self.engine.authorized { break }
            }
            self.authRecoveryBusy = false
            if self.engine.authorized {
                // v117: no Swift-ordered replay - the engine's own
                // recoverAuth re-acquires the current track's
                // license inside its serial chain.
                self.engine.logEvent("auth recovery: authorized again - engine re-acquires the license itself")
            } else if self.engine.authStateKnown {
                self.engine.logEvent("auth recovery: still unauthorized")
                self.showToast(Strings.get("need_acct", self.lang))
            } else {
                self.engine.logEvent("auth recovery: engine state unknown - staying quiet")
            }
        }
    }

    // v117 (GPT round 4, problem 3): the ONE place that puts the
    // shared audio session back into the Player's playback
    // configuration. Shazam's teardown calls this after
    // deactivating its recording session - v116 deactivated and
    // left the session in the recording category, which kept the
    // webview's output paused even after a force play().
    func restorePlaybackAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        engine.logEvent("audio session restored to playback")
    }

    // MARK: - preview (AVPlayer) wiring
    private func setupPreview() {
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.4, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self, !self.useEngine else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let d = self.av.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            self.isPlaying = self.av.timeControlStatus == .playing
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.useEngine else { return }
            if self.repeatMode == 2 {
                self.av.seek(to: .zero)
                self.av.play()
            } else {
                self.next(auto: true)
            }
        }
    }

    // MARK: - downloaded (local file) playback
    private var localURLs: [String: URL] = [:]

    func playDownloaded(_ items: [DownloadedSong], start: Int, manager: DownloadManager) {
        guard items.indices.contains(start) else { return }
        if useEngine { engine.pause() }
        localURLs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, manager.localURL($0)) })
        queue = items.map { manager.songStub($0) }
        index = start
        current = queue[start]
        recordHistory(queue[start])
        useEngine = false
        startLocal()
        updateNowPlayingInfo()
    }

    private func startLocal() {
        guard let cur = current else { return }
        if let u = localURLs[cur.id] {
            av.replaceCurrentItem(with: AVPlayerItem(url: u))
            av.play()
            isPlaying = true
        } else {
            startPreview()
        }
    }

    // MARK: - transport
    func playSongs(_ songs: [Song], start: Int, preservePreviewState: Bool = false) {
        guard !songs.isEmpty, songs.indices.contains(start) else { return }
        queueGeneration += 1
        // v115 (GPT round 2d): a recovery replay must not clear the
        // preview badge itself - confirmation or an unrelated track
        // does that, never the attempt.
        if !preservePreviewState {
            isPreviewClip = false
            previewRecoveryTargetID = nil
            pendingRegionToast = false
        }
        var list = songs
        var startAt = start
        if engine.authorized {
            // Songs without a catalog identity cannot be queued in the
            // engine at all: MusicKit drops them silently and every later
            // index shifts — exactly the Library/Favorites "tapped one
            // song, heard another" bug. Filter them out up front and keep
            // the tapped song's position honest.
            let target = songs[start]
            guard target.isEnginePlayable else {
                showToast(Strings.get("unplayable", lang))
                return
            }
            list = songs.filter { $0.isEnginePlayable }
            // v115 (GPT round 2c): the target's filtered position is
            // the number of playable songs BEFORE it. firstIndex
            // finds the first copy of a duplicated song and restarts
            // the queue from the wrong place.
            startAt = songs[..<start].filter { $0.isEnginePlayable }.count
        }
        queue = list
        index = startAt
        current = list[startAt]
        recordHistory(list[startAt])
        if engine.authorized {
            useEngine = true
            av.pause()
            let ids = list.map { $0.playbackId }
            // v113 (engine 109.11, GPT option D): hand the engine the
            // tapped song's full API resource so MusicKit can skip its
            // catalog fetch for the head item. Catalog songs only - a
            // library song's resource id is its library id, not the
            // playback (catalog) id the queue is addressed by.
            let tapped = list[startAt]
            var targetJSON: String? = nil
            if tapped.type == "songs", tapped.playbackId == tapped.id, tapped.attributes != nil,
               let data = try? JSONEncoder().encode(tapped),
               let js = String(data: data, encoding: .utf8) {
                targetJSON = js
            }
            engine.playQueue(ids: ids, start: startAt, shuffle: shuffle, repeatMode: repeatMode, targetJSON: targetJSON)
            isPlaying = true
        } else {
            useEngine = false
            startPreview()
        }
        updateNowPlayingInfo()
    }

    // Long-press "Play All" on album / playlist cards.
    func playCollection(_ item: CollectionItem, kind: String) {
        Task {
            let (_, tracks) = (try? await api.collectionTracks(kind: kind, id: item.id)) ?? (nil, [Song]())
            if !tracks.isEmpty { playSongs(tracks, start: 0) }
        }
    }

    private func startPreview() {
        guard let cur = current else { return }
        if let urlStr = cur.previewURL, let url = URL(string: urlStr) {
            av.replaceCurrentItem(with: AVPlayerItem(url: url))
            av.play()
            isPlaying = true
            duration = 30
        } else {
            showToast(Strings.get("no_preview", lang))
        }
    }

    // v112: one-way controls for the lock screen / Control Centre.
    // The remote Play and Pause commands used to BOTH call
    // togglePlay(), so a system Play arriving while Swift believed
    // playback was running paused the music instead (GPT review
    // Q5.8). Play only ever plays; Pause only ever pauses.
    func playOnly() {
        guard current != nil, !isPlaying else { return }
        togglePlay()
    }
    func pauseOnly() {
        guard current != nil, isPlaying else { return }
        togglePlay()
    }

    func togglePlay() {
        guard current != nil else { return }
        if useEngine {
            if isPlaying { engine.pause() } else { engine.play() }
            isPlaying.toggle()
        } else {
            if av.timeControlStatus == .playing { av.pause(); isPlaying = false }
            else { av.play(); isPlaying = true }
        }
    }

    // v116 (Shazam): quietly resume playback that an audio-session
    // activation interrupted, without toggling a state the user
    // chose themselves.
    func resumeAfterInterruption(force: Bool = false) {
        // v117: `force` exists for the Shazam interruption, where
        // the system pauses the webview's media while MusicKit
        // keeps reporting isPlaying=true - the flag cannot be
        // trusted there, and a play() on a playing item is a no-op.
        guard current != nil, force || !isPlaying else { return }
        if useEngine { engine.play(); isPlaying = true }
        else { av.play(); isPlaying = true }
    }

    func next(auto: Bool = false) {
        if useEngine {
            if !auto { engine.next() }
            return // engine advances by itself on auto
        }
        guard !queue.isEmpty else { return }
        if shuffle, queue.count > 1 {
            var n = index
            while n == index { n = Int.random(in: 0..<queue.count) }
            index = n
        } else if index < queue.count - 1 {
            index += 1
        } else if repeatMode == 1 {
            index = 0
        } else {
            av.pause(); isPlaying = false; return
        }
        current = queue[index]
        recordHistory(queue[index])
        startLocal()
        updateNowPlayingInfo()
    }

    func prev() {
        if useEngine { engine.prev(); return }
        if currentTime > 3 { seek(0); return }
        if index > 0 {
            index -= 1
            current = queue[index]
            recordHistory(queue[index])
            startLocal()
            updateNowPlayingInfo()
        }
    }

    func jumpTo(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        // Only a sure match may no-op: if our index bookkeeping drifted
        // from the engine's real position, i == index here while another
        // song is actually playing, and the tap then did nothing — the
        // first song just kept playing. When in doubt, send the jump.
        if i == index, current?.playbackId == queue[i].playbackId { return }
        if useEngine {
            engine.jumpTo(i)
            index = i
            current = queue[i]
            recordHistory(queue[i])
        } else {
            index = i
            current = queue[i]
            recordHistory(queue[i])
            startLocal()
        }
        updateNowPlayingInfo()
    }

    func seek(_ sec: Double) {
        if useEngine { engine.seek(sec) }
        else { av.seek(to: CMTime(seconds: sec, preferredTimescale: 600)) }
        currentTime = sec
    }

    func toggleShuffle() {
        shuffle.toggle()
        if useEngine { engine.setShuffle(shuffle) }
    }
    func cycleRepeat() {
        repeatMode = (repeatMode + 1) % 3
        if useEngine { engine.setRepeat(repeatMode) }
    }

    func playStation(_ st: CollectionItem) {
        // Stations play through the engine queue endpoint shape; reuse engine playQueue is for songs,
        // so stations are handled by a dedicated JS call:
        useEngine = true
        av.pause()
        engine.callStation(st.id)
        isPlaying = true
    }

    // MARK: - widget commands
    private func setupWidgetCommands() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let p = Unmanaged<Player>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { p.handleWidgetCommand() }
            },
            WidgetShared.commandNotification as CFString,
            nil,
            .deliverImmediately)
    }
    func handleWidgetCommand() {
        guard let cmd = WidgetShared.takeCommand() else { return }
        switch cmd {
        case "toggle": togglePlay()
        case "next": next()
        case "prev": prev()
        default: break
        }
    }

    // MARK: - history
    func recordHistory(_ song: Song) {
        guard song.attributes?.name != nil else { return }
        if history.first?.id == song.id { return }
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
        history = Array(history.prefix(24))
        Self.saveJSON("aoi-history", history)
    }
    func recordSearch(_ e: SearchEntity) {
        searchHistory.removeAll { $0.kind == e.kind && $0.id == e.id }
        searchHistory.insert(e, at: 0)
        searchHistory = Array(searchHistory.prefix(12))
        Self.saveJSON("aoi-search-entities", searchHistory)
    }
    func clearSearchHistory() {
        searchHistory = []
        Self.saveJSON("aoi-search-entities", searchHistory)
    }

    // MARK: - favorites
    // One canonical key per song — the catalog (playback) id — so the same song
    // keeps its heart whether it is met as a catalog row or a library row.
    func favKey(_ song: Song) -> String { "s:" + song.playbackId }
    func isFav(_ song: Song) -> Bool { favSet.contains(favKey(song)) }
    private func persistFavs() { Self.saveJSON("aoi-fav-songs", favSongs) }
    private func applyFav(_ song: Song, loved: Bool) {
        let key = favKey(song)
        if loved {
            favSet.insert(key)
            if !favSongs.contains(where: { favKey($0) == key }) { favSongs.insert(song, at: 0) }
        } else {
            favSet.remove(key)
            favSongs.removeAll { favKey($0) == key }
        }
        persistFavs()
    }
    // Hydration guards (v108): a row appearance used to fire up to two
    // ratings requests per song, and an inconclusive answer retried on
    // EVERY appearance — scrolling a long list meant a request storm
    // competing with everything else. In-flight keys are never
    // duplicated, and an unknown answer backs off for two minutes.
    private var favHydrating: Set<String> = []
    private var favUnknownAt: [String: Date] = [:]

    func hydrateFav(_ song: Song) {
        let key = favKey(song)
        if favSet.contains(key) { return }
        guard !favChecked.contains(key) else { return }
        guard !favHydrating.contains(key) else { return }
        if let t = favUnknownAt[key], Date().timeIntervalSince(t) < 120 { return }
        favHydrating.insert(key)
        Task {
            defer { favHydrating.remove(key) }
            var known: Bool? = nil
            if let v = await api.ratingState(kind: "songs", id: song.playbackId) { known = v }
            if known != true, song.type == "library-songs" || song.id != song.playbackId {
                if let v = await api.ratingState(kind: "library-songs", id: song.id) {
                    known = (known ?? false) || v
                }
            }
            // Unknown (network/auth hiccup): do NOT mark checked and do NOT
            // clear anything — but back off (favUnknownAt) instead of
            // retrying on every row appearance. Only a definitive answer
            // is cached for the session.
            guard let loved = known else { favUnknownAt[key] = Date(); return }
            favChecked.insert(key)
            if loved { applyFav(song, loved: true) }
        }
    }
    // Favorite writes serialize per song (v108): rapid heart taps used
    // to spawn a storm of racing write tasks — each with its own stale
    // snapshot of the state, each completion reverting the others — and
    // the churn froze the app until iOS killed it (her report:连点收藏
    // 卡住然后闪退). Now a tap only records the DESIRED state and flips
    // the heart at once; ONE worker per song walks Apple's state to the
    // latest desire and reports once when it settles.
    private var favDesired: [String: Bool] = [:]
    private var favBusy: Set<String> = []

    func toggleFav(_ song: Song, lang: String) {
        guard engine.authorized else { showToast(Strings.get("need_acct_fav", lang)); return }
        let key = favKey(song)
        let firstTarget = !favSet.contains(key)
        applyFav(song, loved: firstTarget)
        favDesired[key] = firstTarget
        guard !favBusy.contains(key) else { return }
        favBusy.insert(key)
        // Ratings live in two id spaces; write both so the love sticks no
        // matter which form of the song Apple checks later.
        var targets: [(String, String)] = []
        if song.type == "library-songs" {
            targets.append(("library-songs", song.id))
            if song.playbackId != song.id { targets.append(("songs", song.playbackId)) }
        } else {
            targets.append(("songs", song.playbackId))
        }
        Task {
            var written: Bool? = nil
            var failed = false
            while let want = favDesired[key] {
                favDesired.removeValue(forKey: key)
                var ok = false
                for (kind, tid) in targets {
                    if want {
                        if (try? await api.rateWrite(kind: kind, id: tid)) != nil { ok = true }
                    } else {
                        if (try? await api.rateDelete(kind: kind, id: tid)) != nil { ok = true }
                    }
                }
                if ok { written = want } else { failed = true; break }
            }
            favBusy.remove(key)
            if failed {
                favDesired.removeValue(forKey: key)
                applyFav(song, loved: written ?? !firstTarget)
                showToast(Strings.get("fav_fail", lang))
            } else if let w = written {
                showToast(Strings.get(w ? "faved" : "unfaved", lang))
            }
        }
    }

    // MARK: - favorite albums (local-first, like songs)
    // The album a user favorites in this app is persisted locally the moment
    // they tap, so the Favorites tab can always show it — Apple's ratings
    // reads only ever supplement the local list, never gate it. (Previously a
    // favorited CATALOG album could never appear at all: the favorites scan
    // only walked albums already in the library.)
    private func persistFavAlbums() { Self.saveJSON("aoi-fav-albums", favAlbums) }
    func isFavAlbum(_ id: String) -> Bool { favAlbums.contains { $0.id == id } }
    // v114: the same album reaches this list under different ids
    // (catalog id from its page, library id from a library list,
    // another edition's id from the ratings scan) - identity is
    // title+artist, not the raw id, or she sees the album twice.
    // v115 (GPT review item 10): identity is nil unless BOTH title
    // and artist are present - the old code returned "|" for a
    // metadata-less album, so every such album "matched" every
    // other and they collapsed into one favorite.
    private func albumIdentity(_ a: CollectionItem) -> String? {
        let t = a.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = a.sub.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sub.isEmpty else { return nil }
        return t + "|" + sub
    }
    func isFavAlbumItem(_ item: CollectionItem) -> Bool {
        if favAlbums.contains(where: { $0.id == item.id }) { return true }
        guard let key = albumIdentity(item) else { return false }
        return favAlbums.contains { albumIdentity($0) == key }
    }
    // v115 (GPT review item 12): catalog <-> library id pairs for
    // the same album, learned from the library scan, so an
    // un-favorite can delete the rating in BOTH id spaces, each
    // with its own id.
    private var albumLibIds: [String: String] = [:]
    func noteAlbumPairs(_ pairs: [(libId: String, item: CollectionItem)]) {
        for p in pairs where p.item.id != p.libId {
            albumLibIds[p.item.id] = p.libId
        }
    }
    // Collapse the persisted list to one entry per album: same id,
    // or same title+artist under a different id (untitled entries
    // only dedupe by id - their identity key would be meaningless).
    private func dedupeFavAlbums() {
        var seenIds = Set<String>()
        var seenKeys = Set<String>()
        favAlbums = favAlbums.filter { a in
            guard seenIds.insert(a.id).inserted else { return false }
            if let key = albumIdentity(a) {
                guard seenKeys.insert(key).inserted else { return false }
            }
            return true
        }
    }
    private func applyFavAlbum(_ item: CollectionItem, loved: Bool) {
        if loved {
            if !isFavAlbumItem(item) { favAlbums.insert(item, at: 0) }
        } else {
            let key = albumIdentity(item)
            favAlbums.removeAll { $0.id == item.id || (key != nil && albumIdentity($0) == key) }
        }
        persistFavAlbums()
    }
    private var favAlbumDesired: [String: Bool] = [:]
    private var favAlbumBusy: Set<String> = []

    func toggleFavAlbum(_ item: CollectionItem, lang: String) {
        guard engine.authorized else { showToast(Strings.get("need_acct_fav", lang)); return }
        let firstTarget = !isFavAlbumItem(item)
        applyFavAlbum(item, loved: firstTarget)
        favAlbumDesired[item.id] = firstTarget
        guard !favAlbumBusy.contains(item.id) else { return }
        favAlbumBusy.insert(item.id)
        Task {
            var written: Bool? = nil
            var failed = false
            while let want = favAlbumDesired[item.id] {
                favAlbumDesired.removeValue(forKey: item.id)
                var ok = false
                if want {
                    if (try? await api.rateWrite(kind: "albums", id: item.id)) != nil { ok = true }
                } else {
                    // v115 (GPT review item 12): delete in BOTH
                    // rating id spaces, each with its OWN id -
                    // favoriteAlbums() reads "albums" and
                    // "library-albums", and a rating left alive in
                    // either space resurrects the album. A 404 in a
                    // space counts as success (rateDelete).
                    var targets: [(String, String)] = [
                        (item.type == "library-albums" ? "library-albums" : "albums", item.id)
                    ]
                    if item.type != "library-albums", let lib = albumLibIds[item.id] {
                        targets.append(("library-albums", lib))
                    }
                    ok = true
                    for (kind, tid) in targets {
                        if (try? await api.rateDelete(kind: kind, id: tid)) == nil { ok = false }
                    }
                }
                if ok { written = want } else { failed = true; break }
            }
            favAlbumBusy.remove(item.id)
            if failed {
                favAlbumDesired.removeValue(forKey: item.id)
                applyFavAlbum(item, loved: written ?? !firstTarget)
                showToast(Strings.get("fav_fail", lang))
            } else if let w = written {
                showToast(Strings.get(w ? "faved" : "unfaved", lang))
            }
        }
    }
    // Merge remotely-fetched favorites into the local lists (add-only: a
    // remote miss must never erase a love made on this device).
    func absorbFavSongs(_ remote: [Song]) {
        var changed = false
        for s in remote where !favSet.contains(favKey(s)) {
            favSet.insert(favKey(s))
            favSongs.append(s)
            changed = true
        }
        if changed { persistFavs() }
    }
    func absorbFavAlbums(_ remote: [CollectionItem]) {
        var changed = false
        for a in remote where !isFavAlbumItem(a) {
            favAlbums.append(a)
            changed = true
        }
        if changed { persistFavAlbums() }
    }

    // MARK: - lock screen / remote
    private var lastArtworkKey = ""
    private var lastArtworkImage: UIImage?
    // v115: the iOS 26 animated artwork object, boxed as AnyObject
    // so the property itself needs no availability annotation.
    private var animatedArtworkBox: (songId: String, artworks: [String: AnyObject])?
    private func setupRemote() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.playOnly(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.pauseOnly(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
        // The lock screen must offer track changes like the official
        // app, never +/-10s seeks (the engine page registers the matching
        // media-session handlers for the web-driven side).
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let ev = e as? MPChangePlaybackPositionCommandEvent { self?.seek(ev.positionTime) }
            return .success
        }
        // mixWithOthers (v106): the silent motion-artwork AVPlayers must
        // coexist with the engine's audio instead of interrupting it — an
        // un-mixed session made every animated cover pause the song.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    func updateNowPlayingInfo() {
        guard let cur = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: cur.title,
            MPMediaItemPropertyArtist: cur.artist,
            MPMediaItemPropertyAlbumTitle: cur.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        // v112: updateNowPlayingInfo() runs on every state/item event;
        // fetch the artwork once per song, not once per event
        // (GPT review Q5.7).
        let artKey = cur.playbackId + "|" + (cur.art(512, 512) ?? "")
        if artKey != lastArtworkKey, let artStr = cur.art(512, 512), let url = URL(string: artStr) {
            lastArtworkKey = artKey
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data = data, let img = UIImage(data: data) else { return }
                WidgetShared.publishArtwork(data)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.lastArtworkImage = img
                    var i2 = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                    i2[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = i2
                    self.attachAnimatedArtwork(song: cur, preview: img)
                }
            }.resume()
        }
        // v115: republish the current song's artwork WITH the info
        // instead of wiping it - the old code nilled the artwork key
        // on every state event and only the one-shot fetch re-added
        // it, so the lock screen lost the cover on play/pause.
        if artKey == lastArtworkKey, let img = lastArtworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        if #available(iOS 26.0, *), let box = animatedArtworkBox, box.songId == cur.playbackId {
            for (k, v) in box.artworks {
                if let aa = v as? MPMediaItemAnimatedArtwork { info[k] = aa }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        WidgetShared.publish(title: cur.title, artist: cur.artist, isPlaying: isPlaying)
    }

    // v115: lock-screen ANIMATED artwork (iOS 26,
    // MPMediaItemAnimatedArtwork). The system plays a LOCAL video
    // file on the lock screen in place of the static cover; Apple's
    // motion assets are streams, so the video handler downloads and
    // remuxes the album's motion video on demand (passthrough
    // export to a cached .mp4) and returns the file. The preview
    // image is the static cover, available synchronously. Any
    // failure along the way simply leaves the static artwork.
    // v116: albums with no motion artwork are a legitimate nil -
    // remembered per song so the system's handler cannot refetch
    // (and re-log) the same miss forever.
    private var motionMissed = Set<String>()

    // Prepare the local mp4 for the lock-screen animated artwork,
    // with every step in the log. v115 did this silently, so when
    // the lock screen stayed static neither side could tell
    // whether the album had no motion cover, the HLS export had
    // failed, or the system never asked. A direct .mp4 is now
    // downloaded as-is (the reliable path); an HLS stream goes
    // through the passthrough export, best effort.
    private var motionTasks: [String: Task<URL?, Never>] = [:]

    // v117 (GPT round 4): per-aspect files with in-flight dedupe.
    // v116's prefetch and the system's own request handler could
    // download/export the SAME destination concurrently; now both
    // await one shared task per song+aspect, and exports land via
    // a temp file that moves into place atomically.
    private func prepareMotionFile(song: Song, urlString: String, aspect: String) async -> URL? {
        let key = song.playbackId + "-" + aspect
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            engine.logEvent("animated artwork: no caches directory")
            return nil
        }
        let dir = caches.appendingPathComponent("motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(key + ".mp4")
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        if motionMissed.contains(key) { return nil }
        if let t = motionTasks[key] { return await t.value }
        let task = Task<URL?, Never> { [weak self] in
            guard let self = self else { return nil }
            return await self.fetchMotionFile(src: urlString, dst: dst, key: key)
        }
        motionTasks[key] = task
        let r = await task.value
        motionTasks[key] = nil
        return r
    }

    private func fetchMotionFile(src: String, dst: URL, key: String) async -> URL? {
        guard let srcURL = URL(string: src) else {
            motionMissed.insert(key)
            return nil
        }
        if srcURL.pathExtension.lowercased() == "mp4" {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: srcURL)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
                engine.logEvent("animated artwork: mp4 downloaded for \(key)")
                return dst
            } catch {
                engine.logEvent("animated artwork: mp4 download failed for \(key)")
                return nil
            }
        }
        let asset = AVURLAsset(url: srcURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            engine.logEvent("animated artwork: no export session for \(key)")
            return nil
        }
        let tmpOut = dst.deletingPathExtension().appendingPathExtension("tmp-" + String(UUID().uuidString.prefix(8)) + ".mp4")
        export.outputURL = tmpOut
        export.outputFileType = .mp4
        await export.export()
        if export.status == .completed {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: tmpOut, to: dst)
            engine.logEvent("animated artwork: HLS exported to mp4 for \(key)")
            return dst
        }
        try? FileManager.default.removeItem(at: tmpOut)
        engine.logEvent("animated artwork: HLS export failed for \(key) (status \(export.status.rawValue))")
        return nil
    }

    // v117: per-song retry bookkeeping for the animated key. The
    // first attach attempt can run BEFORE the system registers
    // this app as the now-playing app, and in that window
    // supportedAnimatedArtworkKeys may not offer the key yet
    // (device log 2026-11-18 09:40: not offered at first attach).
    private var animatedKeyRetries: [String: Int] = [:]

    private var animatedKeysLoggedFor: String? = nil

    private func attachAnimatedArtwork(song: Song, preview: UIImage) {
        if #available(iOS 26.0, *) {
            let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            let songId = song.playbackId
            // v117 (GPT round 4): log what the system ACTUALLY
            // offers - two rounds of guessing (timing, low power)
            // went nowhere while the log only ever said "no 1x1".
            if animatedKeysLoggedFor != songId {
                animatedKeysLoggedFor = songId
                engine.logEvent("animated artwork: system offers keys [\(keys.joined(separator: ", "))]")
            }
            let hasSq = keys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork)
            let hasTall = keys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork)
            if !hasSq && !hasTall {
                let n = animatedKeyRetries[songId, default: 0]
                if n == 0 {
                    engine.logEvent("animated artwork: the system offers no animated key (will retry)")
                }
                if n < 3 {
                    animatedKeyRetries[songId] = n + 1
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let self = self, self.current?.playbackId == songId else { return }
                        self.attachAnimatedArtwork(song: song, preview: preview)
                    }
                }
                return
            }
            if let n = animatedKeyRetries[songId], n > 0 {
                engine.logEvent("animated artwork: key offered on retry \(n) for \(songId)")
                animatedKeyRetries[songId] = nil
            }
            Task { [weak self] in
                guard let self = self else { return }
                let urls = await self.api.motionURLsForSong(song)
                var jobs: [(String, String)] = []
                if hasSq, let u = urls.square { jobs.append(("sq", u)) }
                if hasTall, let u = urls.tall { jobs.append(("tall", u)) }
                if jobs.isEmpty {
                    if !self.motionMissed.contains(songId + "-sq") {
                        self.motionMissed.insert(songId + "-sq")
                        self.engine.logEvent("animated artwork: this album has no motion cover (\(songId))")
                    }
                    return
                }
                var artworks: [String: AnyObject] = [:]
                for (aspect, u) in jobs {
                    let propKey = aspect == "sq" ? MPNowPlayingInfoProperty1x1AnimatedArtwork : MPNowPlayingInfoProperty3x4AnimatedArtwork
                    let animated = MPMediaItemAnimatedArtwork(
                        artworkID: "aoi-" + songId + "-" + aspect,
                        previewImageRequestHandler: { _ in preview },
                        videoAssetFileURLRequestHandler: { _ in
                            await self.prepareMotionFile(song: song, urlString: u, aspect: aspect)
                        })
                    artworks[propKey] = animated
                }
                self.animatedArtworkBox = (songId, artworks)
                // Prefetch in the foreground (v116) so the file is
                // ready before the system asks on the lock screen.
                for (aspect, u) in jobs {
                    _ = await self.prepareMotionFile(song: song, urlString: u, aspect: aspect)
                }
                guard self.current?.playbackId == songId else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: preview.size) { _ in preview }
                for (k, v) in artworks { info[k] = v }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                self.engine.logEvent("animated artwork: attached for \(songId) (\(artworks.count) key(s))")
            }
        }
    }
}
