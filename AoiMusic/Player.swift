import Foundation
import AVFoundation
import MediaPlayer

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
    // Last play request sent to the engine, watched until the engine confirms
    // it (matching item event or playing state). One silent re-issue if the
    // confirmation never comes — a second safety net under the engine's own
    // intent runner, for calls lost before they ever reached the page.
    private var pendingPlay: (ids: [String], start: Int, station: String?, issuedAt: Date, retried: Bool)?
    private var watchdogTimer: Timer?

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.pendingPlay else { return }
            let age = Date().timeIntervalSince(p.issuedAt)
            if age > 20 {
                self.pendingPlay = nil
            } else if age > 6, !p.retried {
                self.pendingPlay = (p.ids, p.start, p.station, Date(), true)
                if let st = p.station {
                    self.engine.callStation(st)
                } else {
                    self.engine.playQueue(ids: p.ids, start: p.start, shuffle: self.shuffle, repeatMode: self.repeatMode)
                }
            }
        }
    }

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
        setupEngine()
        startWatchdog()
        setupPreview()
        setupRemote()
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
    private func setupEngine() {
        engine.onState = { [weak self] playing in
            guard let self = self, self.useEngine else { return }
            self.isPlaying = playing
            if playing { self.pendingPlay = nil }
            self.updateNowPlayingInfo()
        }
        engine.onProgress = { [weak self] t, d, playing in
            guard let self = self, self.useEngine else { return }
            self.currentTime = t
            if d > 0 { self.duration = d }
            self.isPlaying = playing
        }
        engine.onItem = { [weak self] item in
            guard let self = self, self.useEngine, let item = item else { return }
            if let p = self.pendingPlay, p.station == nil, p.ids.indices.contains(p.start), p.ids[p.start] == item.id {
                self.pendingPlay = nil
            }
            if let idx = self.queue.firstIndex(where: { $0.playbackId == item.id || $0.id == item.id }) {
                if idx != self.index { self.index = idx }
                self.current = self.queue[idx]
            } else if self.current?.id != item.id {
                var s = Song(id: item.id, type: "songs", attributes: nil)
                s.attributes = SongAttrs(name: item.title, artistName: item.artist, albumName: item.album, artwork: Artwork(url: item.artwork), previews: nil, durationInMillis: item.duration.map { Int($0 * 1000) })
                self.current = s
            }
            if let c = self.current { self.recordHistory(c) }
            self.updateNowPlayingInfo()
        }
        engine.onQueue = { [weak self] ids in
            guard let self = self, self.useEngine, !ids.isEmpty else { return }
            // The engine's queue is the truth: MusicKit may have dropped
            // items it could not resolve. Rebuild our queue in the engine's
            // order so indices and highlighting agree with what plays.
            guard let curId = self.current?.playbackId, ids.contains(curId) else { return }
            let byId = Dictionary(self.queue.map { ($0.playbackId, $0) }, uniquingKeysWith: { a, _ in a })
            let rebuilt = ids.compactMap { byId[$0] }
            guard !rebuilt.isEmpty else { return }
            self.queue = rebuilt
            if let i = rebuilt.firstIndex(where: { $0.playbackId == curId }) { self.index = i }
        }
        engine.onError = { [weak self] kind in
            // Only a failed playback attempt may surface the "playback failed" toast,
            // and only if nothing actually started playing shortly after (the engine
            // reports superseded-operation errors that are not real failures).
            guard let self = self, kind == "playQueue" || kind == "station" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self = self, self.useEngine, !self.isPlaying else { return }
                self.showToast(Strings.get("play_fail", self.lang))
            }
        }
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
    func playSongs(_ songs: [Song], start: Int) {
        guard !songs.isEmpty, songs.indices.contains(start) else { return }
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
            startAt = list.firstIndex(where: { $0.id == target.id }) ?? 0
        }
        queue = list
        index = startAt
        current = list[startAt]
        recordHistory(list[startAt])
        if engine.authorized {
            useEngine = true
            av.pause()
            let ids = list.map { $0.playbackId }
            pendingPlay = (ids, startAt, nil, Date(), false)
            engine.playQueue(ids: ids, start: startAt, shuffle: shuffle, repeatMode: repeatMode)
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
        guard queue.indices.contains(i), i != index else { return }
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
        pendingPlay = ([], 0, st.id, Date(), false)
        engine.callStation(st.id)
        isPlaying = true
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
    func hydrateFav(_ song: Song) {
        let key = favKey(song)
        if favSet.contains(key) { return }
        guard !favChecked.contains(key) else { return }
        Task {
            var known: Bool? = nil
            if let v = await api.ratingState(kind: "songs", id: song.playbackId) { known = v }
            if known != true, song.type == "library-songs" || song.id != song.playbackId {
                if let v = await api.ratingState(kind: "library-songs", id: song.id) {
                    known = (known ?? false) || v
                }
            }
            // Unknown (network/auth hiccup): do NOT mark checked and do NOT clear
            // anything — the next appearance retries. Only a definitive answer
            // is cached for the session.
            guard let loved = known else { return }
            favChecked.insert(key)
            if loved { applyFav(song, loved: true) }
        }
    }
    func toggleFav(_ song: Song, lang: String) {
        guard engine.authorized else { showToast(Strings.get("need_acct_fav", lang)); return }
        let key = favKey(song)
        let was = favSet.contains(key)
        applyFav(song, loved: !was)
        // Ratings live in two id spaces; write both so the love sticks no matter
        // which form of the song Apple checks later.
        var targets: [(String, String)] = []
        if song.type == "library-songs" {
            targets.append(("library-songs", song.id))
            if song.playbackId != song.id { targets.append(("songs", song.playbackId)) }
        } else {
            targets.append(("songs", song.playbackId))
        }
        Task {
            var ok = false
            for (kind, tid) in targets {
                if was {
                    if (try? await api.rateDelete(kind: kind, id: tid)) != nil { ok = true }
                } else {
                    if (try? await api.rateWrite(kind: kind, id: tid)) != nil { ok = true }
                }
            }
            if ok {
                showToast(Strings.get(was ? "unfaved" : "faved", lang))
            } else {
                applyFav(song, loved: was)
                showToast(Strings.get("fav_fail", lang))
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
    private func applyFavAlbum(_ item: CollectionItem, loved: Bool) {
        if loved {
            if !isFavAlbum(item.id) { favAlbums.insert(item, at: 0) }
        } else {
            favAlbums.removeAll { $0.id == item.id }
        }
        persistFavAlbums()
    }
    func toggleFavAlbum(_ item: CollectionItem, lang: String) {
        guard engine.authorized else { showToast(Strings.get("need_acct_fav", lang)); return }
        let was = isFavAlbum(item.id)
        applyFavAlbum(item, loved: !was)
        Task {
            var ok = false
            if was {
                if (try? await api.rateDelete(kind: "albums", id: item.id)) != nil { ok = true }
            } else {
                if (try? await api.rateWrite(kind: "albums", id: item.id)) != nil { ok = true }
            }
            if ok {
                showToast(Strings.get(was ? "unfaved" : "faved", lang))
            } else {
                applyFavAlbum(item, loved: was)
                showToast(Strings.get("fav_fail", lang))
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
        for a in remote where !isFavAlbum(a.id) {
            favAlbums.append(a)
            changed = true
        }
        if changed { persistFavAlbums() }
    }

    // MARK: - lock screen / remote
    private func setupRemote() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
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
        if let artStr = cur.art(512, 512), let url = URL(string: artStr) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let img = UIImage(data: data) else { return }
                var i2 = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                i2[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = i2
            }.resume()
        }
        info[MPMediaItemPropertyArtwork] = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
