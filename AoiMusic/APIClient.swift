import Foundation

enum APIError: Error {
    case http(Int, String)
    case badData
}

final class APIClient: ObservableObject {
    static let devToken = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6IldlYlBsYXlLaWQifQ.eyJpc3MiOiJBTVBXZWJQbGF5IiwiaWF0IjoxNzkzOTAwNzA4LCJleHAiOjE3OTk5NDg3MDgsInJvb3RfaHR0cHNfb3JpZ2luIjpbImFwcGxlLmNvbSJdfQ.7L-PYJHjO8PpFdhKS-OSkf_snyFvg5cq-JDERUs_N_UcUX9Vk0kf1WLatgDeEvhB_Arg1b5Tl-99G1v6hUwH0A"
    @Published var userToken: String = ""
    @Published var storefront: String = "cn"

    private func request(path: String, amp: Bool = false, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let useAmp = amp || method == "DELETE" || method == "PATCH"
        let host = useAmp ? "https://amp-api.music.apple.com" : "https://api.music.apple.com"
        guard let url = URL(string: host + path) else { throw APIError.badData }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(Self.devToken)", forHTTPHeaderField: "Authorization")
        if !userToken.isEmpty { req.setValue(userToken, forHTTPHeaderField: "Music-User-Token") }
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 204 { return Data() }
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, amp: Bool = false) async throws -> T {
        let data = try await request(path: path, amp: amp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Catalog / home
    func charts() async throws -> SearchResponse {
        // The charts endpoint does NOT return a top-level data array: the payload is
        // { results: { songs: [ { chart, data: [...] } ], albums: [...], playlists: [...] } }.
        // Decoding it as ListResponse silently yielded nil for every section, which is
        // why Home's Top Songs / Top Albums / playlists were always empty.
        struct ChartEntry<T: Codable>: Codable { var data: [T]? }
        struct ChartResults: Codable {
            var songs: [ChartEntry<Song>]?
            var albums: [ChartEntry<CollectionItem>]?
            var playlists: [ChartEntry<CollectionItem>]?
        }
        struct ChartsResponse: Codable { var results: ChartResults? }
        let r: ChartsResponse = try await get("/v1/catalog/\(storefront)/charts?types=songs,albums,playlists&limit=12")
        var out = SearchResponse()
        out.results = SearchResponse.Results(
            songs: ListResponse(data: r.results?.songs?.first?.data),
            albums: ListResponse(data: r.results?.albums?.first?.data),
            artists: nil,
            playlists: ListResponse(data: r.results?.playlists?.first?.data))
        return out
    }

    func songFull(id: String) async -> Song? {
        let r: ListResponse<Song>? = try? await get("/v1/catalog/\(storefront)/songs/\(id)?include=albums,artists")
        return r?.data?.first
    }

    func songFull(for song: Song) async -> Song? {
        let cid = (try? await resolveCatalogId(song)) ?? song.playbackId
        var tried = Set<String>()
        for sf in [storefront, "cn", "us"] where !tried.contains(sf) {
            tried.insert(sf)
            let r: ListResponse<Song>? = try? await get("/v1/catalog/\(sf)/songs/\(cid)?include=albums,artists")
            if let s = r?.data?.first,
               (s.relationships?.albums?.data?.first != nil) || (s.relationships?.artists?.data?.first != nil) {
                return s
            }
        }
        return nil
    }

    // v115 (GPT review item 7): .urlQueryAllowed leaves &, =, +, #
    // and % UNESCAPED, so a search term like "R&B" silently splits
    // the query and corrupts the request. Query VALUES go through
    // this stricter set everywhere.
    static let queryValueAllowed = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&=+#%"))

    func search(term: String) async throws -> SearchResponse {
        let q = term.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? term
        let r: SearchResponse = try await get("/v1/catalog/\(storefront)/search?term=\(q)&types=songs,albums,artists,playlists&limit=25")
        return r
    }

    func collectionTracks(kind: String, id: String) async throws -> (CollectionItem?, [Song]) {
        if kind == "lplaylist" {
            let head: ListResponse<CollectionItem> = try await get("/v1/me/library/playlists/\(id)")
            let tr: TracksResponse = try await get("/v1/me/library/playlists/\(id)/tracks?limit=100")
            return (head.data?.first, tr.data ?? [])
        }
        let isAlbum = kind == "album"
        let path = isAlbum ? "/v1/catalog/\(storefront)/albums/\(id)" : "/v1/catalog/\(storefront)/playlists/\(id)"
        struct IncludeTracksResponse: Codable {
            var data: [Item]?
            struct Item: Codable { var relationships: R? }
            struct R: Codable { var tracks: ListResponse<Song>? }
        }
        let tr: IncludeTracksResponse = try await get(path + "?include=tracks")
        let head: ListResponse<CollectionItem> = try await get(path)
        let tracks = tr.data?.first?.relationships?.tracks?.data ?? []
        return (head.data?.first, tracks)
    }

    func artistDetail(id: String) async throws -> ArtistDetailResponse.ArtistDetail? {
        let r: ArtistDetailResponse = try await get("/v1/catalog/\(storefront)/artists/\(id)?views=top-songs,albums,playlists,similar-artists")
        guard var d = r.data?.first else { return nil }
        // views/relationships return id-only stubs for albums & playlists (no name/artwork);
        // fetch the full resources from the relationship endpoints instead.
        if d.views?.albums?.data?.first?.attributes?.artwork?.url == nil {
            let albums: ListResponse<CollectionItem>? = try? await get("/v1/catalog/\(storefront)/artists/\(id)/albums?limit=24")
            if let albums = albums, !(albums.data ?? []).isEmpty {
                if d.views == nil { d.views = ArtistDetailResponse.ArtistDetail.Views() }
                d.views?.albums = albums
            }
        }
        if d.views?.playlists?.data?.first?.attributes?.artwork?.url == nil {
            let pls: ListResponse<CollectionItem>? = try? await get("/v1/catalog/\(storefront)/artists/\(id)/playlists?limit=12")
            if let pls = pls, !(pls.data ?? []).isEmpty {
                if d.views == nil { d.views = ArtistDetailResponse.ArtistDetail.Views() }
                d.views?.playlists = pls
            }
        }
        return d
    }

    func recentPlayed(limit: Int = 10) async throws -> [Song] {
        let r: RecentPlayedResponse = try await get("/v1/me/recent/played/tracks?limit=\(limit)")
        return r.data ?? []
    }

    func recommendations() async throws -> [CollectionItem] {
        struct RecResponse: Codable {
            var data: [RecGroup]?
            struct RecGroup: Codable { var relationships: GRels? }
            struct GRels: Codable { var contents: ListResponse<CollectionItem>? }
        }
        let r: RecResponse = try await get("/v1/me/recommendations")
        var out: [CollectionItem] = []
        for g in r.data ?? [] { out += g.relationships?.contents?.data ?? [] }
        // The same playlist can appear in several recommendation groups, and some
        // entries carry neither artwork nor a name — both render as ghost cells in
        // grids (duplicate ids break ForEach layout). Keep the first of each id
        // and drop contentless entries.
        var seen = Set<String>()
        return out.filter { item in
            guard !item.id.isEmpty, seen.insert(item.id).inserted else { return false }
            // v113: require a title - artwork-only entries rendered as
            // ghost cells in the grids.
            return !item.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Library
    func recommendationGroups() async -> [(title: String, items: [CollectionItem])] {
        struct GAttrs: Codable { var name: String?; var title: String? }
        struct G2: Codable { var attributes: GAttrs?; var relationships: GRels? }
        struct GRels: Codable { var contents: ListResponse<CollectionItem>? }
        struct Resp: Codable { var data: [G2]? }
        let r: Resp? = try? await get("/v1/me/recommendations")
        var seen = Set<String>()
        var groups: [(title: String, items: [CollectionItem])] = []
        for g in r?.data ?? [] {
            let items = (g.relationships?.contents?.data ?? []).filter { item in
                guard !item.id.isEmpty, item.type != "songs", seen.insert(item.id).inserted else { return false }
                // v113: require a title - artwork-only entries rendered as
            // ghost cells in the grids.
            return !item.title.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if !items.isEmpty {
                groups.append((g.attributes?.title ?? g.attributes?.name ?? "", items))
            }
        }
        return groups
    }

    func recommendationSongs() async -> [Song] {
        struct G: Codable { var relationships: GRels? }
        struct GRels: Codable { var contents: ListResponse<Song>? }
        struct Resp: Codable { var data: [G]? }
        let r: Resp? = try? await get("/v1/me/recommendations")
        var seen = Set<String>()
        var out: [Song] = []
        for g in r?.data ?? [] {
            for s in g.relationships?.contents?.data ?? [] where s.type == "songs" {
                guard seen.insert(s.id).inserted, s.attributes?.name != nil else { continue }
                out.append(s)
            }
        }
        return Array(out.prefix(12))
    }

    // Batch-check which of the given ids carry a rating, in one request per 50 ids.
    // Returns the ids that are rated (and not disliked). Empty on any failure.
    func ratingsBatch(kind: String, ids: [String]) async -> Set<String> {
        struct R: Codable { var id: String; var attributes: RAttrs? }
        struct RAttrs: Codable { var value: Int? }
        var loved = Set<String>()
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 50, ids.count)])
            i += 50
            let r: ListResponse<R>? = try? await get("/v1/me/ratings/\(kind)?ids=\(chunk.joined(separator: ","))")
            for it in r?.data ?? [] where it.attributes?.value != -1 {
                loved.insert(it.id)
            }
        }
        return loved
    }

    func favoriteSongs() async -> [Song] {
        var ordered: [Song] = []
        var seenPid = Set<String>()
        func add(_ s: Song) {
            guard seenPid.insert(s.playbackId).inserted else { return }
            ordered.append(s)
        }
        // Channel 1: the ratings list endpoint (only some accounts/storefronts honor it).
        struct Rating: Codable { var id: String }
        let list: ListResponse<Rating>? = try? await get("/v1/me/ratings/songs?limit=100")
        let listIds = (list?.data ?? []).map { $0.id }
        if !listIds.isEmpty {
            var byId: [String: Song] = [:]
            let lib: ListResponse<Song>? = try? await get("/v1/me/library/songs?ids=\(listIds.joined(separator: ","))")
            for s in lib?.data ?? [] { byId[s.id] = s; byId[s.playbackId] = s }
            for sf in [storefront, "cn", "us"] {
                let missing = listIds.filter { byId[$0] == nil }
                if missing.isEmpty { break }
                let cat: ListResponse<Song>? = try? await get("/v1/catalog/\(sf)/songs?ids=\(missing.joined(separator: ","))")
                for s in cat?.data ?? [] { byId[s.id] = s }
            }
            for id in listIds { if let s = byId[id] { add(s) } }
        }
        // Channel 2: scan the library and batch-check ratings in both rating spaces
        // (catalog "songs" ids and "library-songs" ids are rated separately).
        var libSongs: [Song] = []
        var offset = 0
        while offset < 200 {
            let page: ListResponse<Song>? = try? await get("/v1/me/library/songs?limit=100&offset=\(offset)")
            let items = page?.data ?? []
            libSongs += items
            if items.count < 100 { break }
            offset += 100
        }
        if !libSongs.isEmpty {
            let lovedCat = await ratingsBatch(kind: "songs", ids: Array(Set(libSongs.map { $0.playbackId })))
            let lovedLib = await ratingsBatch(kind: "library-songs", ids: libSongs.map { $0.id })
            for s in libSongs where lovedCat.contains(s.playbackId) || lovedLib.contains(s.id) { add(s) }
        }
        return ordered
    }

    func libraryPlaylists() async throws -> [CollectionItem] {
        // v118: paginate - the old single limit=50 page silently
        // truncated bigger libraries (GPT round 5).
        var all: [CollectionItem] = []
        var offset = 0
        while offset < 500 {
            let r: ListResponse<CollectionItem> = try await get("/v1/me/library/playlists?limit=100&offset=\(offset)")
            let items = r.data ?? []
            all += items
            if items.count < 100 { break }
            offset += 100
        }
        return all
    }
    func librarySongs() async throws -> [Song] {
        // Resolve every library song to its catalog counterpart (v106), the
        // same treatment libraryArtists() already had. Without this, songs
        // whose playParams carry no catalogId fell back to their library id,
        // which the playback engine cannot queue — it dropped them silently
        // and every index behind them shifted.
        struct LibSong: Codable {
            var id: String
            var attributes: SongAttrs?
            var relationships: LibRels?
        }
        struct LibRels: Codable { var catalog: CatRel? }
        struct CatRel: Codable { var data: [CatStub]? }
        struct CatStub: Codable { var id: String }
        // v118: paginate - the old single limit=50 page silently
        // truncated bigger libraries (GPT round 5).
        var libs: [LibSong] = []
        var loffset = 0
        while loffset < 1000 {
            let page: ListResponse<LibSong>? = try? await get("/v1/me/library/songs?include=catalog&limit=100&offset=\(loffset)")
            let items = page?.data ?? []
            libs += items
            if items.count < 100 { break }
            loffset += 100
        }
        let catIds = libs.compactMap { $0.relationships?.catalog?.data?.first?.id }
        var catMap: [String: Song] = [:]
        if !catIds.isEmpty {
            for chunkStart in stride(from: 0, to: catIds.count, by: 100) {
                let chunk = Array(catIds[chunkStart..<min(chunkStart + 100, catIds.count)])
                let cr: ListResponse<Song>? = try? await get("/v1/catalog/\(storefront)/songs?ids=\(chunk.joined(separator: ","))")
                for s in cr?.data ?? [] { catMap[s.id] = s }
            }
        }
        return libs.map { lib in
            if let cid = lib.relationships?.catalog?.data?.first?.id, let cat = catMap[cid] {
                return cat
            }
            return Song(id: lib.id, type: "library-songs", attributes: lib.attributes)
        }
    }
    func libraryAlbums() async throws -> [CollectionItem] {
        let pairs = try await libraryAlbumPairs()
        return pairs.map { $0.item }
    }
    // Library albums paired with their library id (ratings live in two id spaces,
    // so the Favorites scan needs both the catalog item and the library id).
    func libraryAlbumPairs() async throws -> [(libId: String, item: CollectionItem)] {
        struct LibAlbum: Codable {
            var id: String
            var attributes: CollectionAttrs?
            var relationships: LibRels?
        }
        struct LibRels: Codable { var catalog: CatRel? }
        struct CatRel: Codable { var data: [CatStub]? }
        struct CatStub: Codable { var id: String }
        let r: ListResponse<LibAlbum> = try await get("/v1/me/library/albums?include=catalog&limit=50")
        let libs = r.data ?? []
        let catIds = libs.compactMap { $0.relationships?.catalog?.data?.first?.id }
        var catMap: [String: CollectionItem] = [:]
        if !catIds.isEmpty {
            let cr: ListResponse<CollectionItem>? = try? await get("/v1/catalog/\(storefront)/albums?ids=\(catIds.joined(separator: ","))")
            for a in cr?.data ?? [] { catMap[a.id] = a }
        }
        return libs.map { lib in
            if let cid = lib.relationships?.catalog?.data?.first?.id, let cat = catMap[cid] {
                return (lib.id, cat)
            }
            return (lib.id, CollectionItem(id: lib.id, type: "library-albums", attributes: lib.attributes))
        }
    }
    // Albums she actually favorited (rated), in either rating space.
    // Channel 1 is the ratings list itself, resolved straight through the
    // catalog — a favorited album does NOT have to be in her library to show
    // up (the old library-only scan structurally hid those). Channel 2 checks
    // the library pairs in both rating spaces. No "all library albums"
    // fallback: unfavorited albums are not favorites.
    func favoriteAlbums() async -> [CollectionItem] {
        var ordered: [CollectionItem] = []
        var seen = Set<String>()
        func add(_ a: CollectionItem) {
            guard seen.insert(a.id).inserted else { return }
            ordered.append(a)
        }
        struct Rating: Codable { var id: String }
        let list: ListResponse<Rating>? = try? await get("/v1/me/ratings/albums?limit=100")
        let listIds = (list?.data ?? []).map { $0.id }
        if !listIds.isEmpty {
            var byId: [String: CollectionItem] = [:]
            for sf in [storefront, "cn", "us"] {
                let missing = listIds.filter { byId[$0] == nil }
                if missing.isEmpty { break }
                let cat: ListResponse<CollectionItem>? = try? await get("/v1/catalog/\(sf)/albums?ids=\(missing.joined(separator: ","))")
                for a in cat?.data ?? [] { byId[a.id] = a }
            }
            for id in listIds { if let a = byId[id] { add(a) } }
        }
        let pairs = (try? await libraryAlbumPairs()) ?? []
        if !pairs.isEmpty {
            let lovedCat = await ratingsBatch(kind: "albums", ids: pairs.map { $0.item.id })
            let lovedLib = await ratingsBatch(kind: "library-albums", ids: pairs.map { $0.libId })
            for p in pairs where lovedCat.contains(p.item.id) || lovedLib.contains(p.libId) { add(p.item) }
        }
        return ordered
    }
    func libraryArtists() async throws -> [CollectionItem] {
        struct LibArtist: Codable {
            var id: String
            var attributes: CollectionAttrs?
            var relationships: LibRels?
        }
        struct LibRels: Codable { var catalog: CatRel? }
        struct CatRel: Codable { var data: [CatStub]? }
        struct CatStub: Codable { var id: String }
        let r: ListResponse<LibArtist> = try await get("/v1/me/library/artists?include=catalog&limit=50")
        let libs = r.data ?? []
        let catIds = libs.compactMap { $0.relationships?.catalog?.data?.first?.id }
        var catMap: [String: CollectionItem] = [:]
        if !catIds.isEmpty {
            let cr: ListResponse<CollectionItem>? = try? await get("/v1/catalog/\(storefront)/artists?ids=\(catIds.joined(separator: ","))")
            for a in cr?.data ?? [] { catMap[a.id] = a }
        }
        // One row per person (v106): the library can hold several records
        // for the same artist (one per source album), and they all resolve
        // to the same catalog artist — dedupe by catalog id, then by name.
        var seen = Set<String>()
        var out: [CollectionItem] = []
        for lib in libs {
            let item: CollectionItem
            let key: String
            if let cid = lib.relationships?.catalog?.data?.first?.id, let cat = catMap[cid] {
                item = cat
                key = "id:" + cid
            } else {
                item = CollectionItem(id: lib.id, type: "library-artists", attributes: lib.attributes)
                key = "name:" + (lib.attributes?.name ?? lib.id).lowercased()
            }
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    func createPlaylist(name: String, song: Song?) async throws {
        var body: [String: Any] = ["attributes": ["name": name]]
        if let s = song {
            let cid = (try? await resolveCatalogId(s)) ?? s.id
            body["relationships"] = ["tracks": ["data": [["id": cid, "type": "songs"]]]]
        }
        _ = try await request(path: "/v1/me/library/playlists", method: "POST", body: body)
    }
    func renamePlaylist(id: String, name: String) async throws {
        _ = try await request(path: "/v1/me/library/playlists/\(id)", method: "PATCH", body: ["attributes": ["name": name]])
    }
    func deletePlaylist(id: String) async throws {
        _ = try await request(path: "/v1/me/library/playlists/\(id)", method: "DELETE")
    }
    func addToPlaylist(pid: String, song: Song) async throws {
        let cid = (try? await resolveCatalogId(song)) ?? song.id
        _ = try await request(path: "/v1/me/library/playlists/\(pid)/tracks", method: "POST", body: ["data": [["id": cid, "type": "songs"]]])
    }
    // Create a playlist with all its tracks in one call (the AI chat's
    // "save as playlist"); songs are catalog songs, so playbackId is the id
    // the create endpoint expects.
    func createPlaylistWithTracks(name: String, songs: [Song]) async throws {
        var body: [String: Any] = ["attributes": ["name": name]]
        if !songs.isEmpty {
            let data: [[String: String]] = songs.map { ["id": $0.playbackId, "type": "songs"] }
            body["relationships"] = ["tracks": ["data": data]]
        }
        _ = try await request(path: "/v1/me/library/playlists", method: "POST", body: body)
    }

    func removeFromPlaylist(pid: String, librarySongId: String) async throws {
        let q = "?ids[library-songs]=\(librarySongId.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? librarySongId)&mode=all"
        _ = try await request(path: "/v1/me/library/playlists/\(pid)/tracks\(q)", method: "DELETE")
    }

    func resolveCatalogId(_ song: Song) async throws -> String {
        if song.type != "library-songs" { return song.id }
        struct CatResp: Codable {
            var data: [Item]?
            struct Item: Codable { var relationships: R? }
            struct R: Codable { var catalog: ListResponse<RefItem>? }
            struct RefItem: Codable { var id: String }
        }
        let r: CatResp = try await get("/v1/me/library/songs/\(song.id)?include=catalog")
        if let cid = r.data?.first?.relationships?.catalog?.data?.first?.id { return cid }
        return song.id
    }

    // v114: find the SAME recording in the account's own storefront.
    // A song object fetched from another storefront (radio lists are
    // the usual source) carries foreign playParams; MusicKit then
    // silently substitutes the 30s preview for the full track. ISRC
    // identifies the recording across storefronts; fall back to a
    // name+artist search match when no ISRC is present.
    func resolveInStorefront(_ song: Song) async -> Song? {
        let sf = storefront
        if sf.isEmpty { return nil }
        if let isrc = song.attributes?.isrc, !isrc.isEmpty,
           let enc = isrc.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) {
            let r: ListResponse<Song>? = try? await get("/v1/catalog/\(sf)/songs?filter[isrc]=\(enc)")
            if let hit = r?.data?.first { return hit }
        }
        let term = (song.title + " " + song.artist)
            .addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? ""
        if term.isEmpty { return nil }
        let r: SearchResponse? = try? await get("/v1/catalog/\(sf)/search?term=\(term)&types=songs&limit=25")
        let wantT = song.title.lowercased().trimmingCharacters(in: .whitespaces)
        let wantA = song.artist.lowercased().trimmingCharacters(in: .whitespaces)
        // v115 (GPT review item 8): an empty candidate artist made
        // contains("") true, so any same-title song "matched".
        // Both sides normalized; empty artists never match.
        let cands = (r?.results?.songs?.data ?? []).filter { cand in
            cand.title.lowercased().trimmingCharacters(in: .whitespaces) == wantT && !wantA.isEmpty
        }
        // v118: prefer an exact normalized artist match; the old
        // bidirectional substring test alone could pick a same-title
        // song by a different artist whose name merely contains (or
        // is contained in) the wanted one (GPT round 5).
        if let exact = cands.first(where: { cand in
            cand.artist.lowercased().trimmingCharacters(in: .whitespaces) == wantA
        }) { return exact }
        return cands.first(where: { cand in
            let ca = cand.artist.lowercased().trimmingCharacters(in: .whitespaces)
            guard !ca.isEmpty else { return false }
            return ca.contains(wantA) || wantA.contains(ca)
        })
    }

    // v115: one lightweight authenticated probe so the preview /
    // auth recovery can tell "token is dead" (401) from "token fine,
    // license path failed" (200) from "network unreachable" (nil).
    func probeLibraryStatus() async -> Int? {
        do {
            _ = try await request(path: "/v1/me/library/songs?limit=1")
            return 200
        } catch APIError.http(let code, _) {
            return code
        } catch {
            return nil
        }
    }

    // MARK: - Ratings / favorites
    // Tri-state: true = loved, false = definitively not loved (incl. 404 = no rating),
    // nil = unknown (network/auth failure) — callers must NOT cache nil as "not loved".
    func ratingState(kind: String, id: String) async -> Bool? {
        do {
            let r: RatingResponse = try await get("/v1/me/ratings/\(kind)/\(id)")
            return r.data?.attributes?.value == 1
        } catch {
            if case APIError.http(let code, _) = error, code == 404 { return false }
            return nil
        }
    }
    func rating(kind: String, id: String) async -> Bool {
        await ratingState(kind: kind, id: id) ?? false
    }
    func rateWrite(kind: String, id: String) async throws {
        // PUT is the documented write. Try the standard host, then the amp host;
        // an accepted (2xx) PUT counts as success — ratings propagate asynchronously
        // on Apple's side, so a verify-GET can lag and must not veto the write.
        let body: [String: Any] = ["type": "ratings", "attributes": ["value": 1]]
        let path = "/v1/me/ratings/\(kind)/\(id)"
        var lastError: Error?
        for amp in [false, true] {
            do {
                _ = try await request(path: path, amp: amp, method: "PUT", body: body)
                return
            } catch { lastError = error }
        }
        throw lastError ?? APIError.badData
    }
    func rateDelete(kind: String, id: String) async throws {
        // v115 (GPT review item 12): deleting a rating that does not
        // exist in this id space answers 404 - that IS the desired
        // end state of an un-favorite, not a failure.
        do {
            _ = try await request(path: "/v1/me/ratings/\(kind)/\(id)", method: "DELETE")
        } catch APIError.http(let code, _) where code == 404 {
            return
        }
        if await rating(kind: kind, id: id) {
            _ = try await request(path: "/v1/me/ratings/\(kind)/\(id)", method: "DELETE")
        }
    }

    // MARK: - Motion artwork (in-app animated headers) + artist videos
    // editorialVideo lives behind ?extend=editorialVideo and is served by the amp
    // host; the value shape varies, so walk it like the web app does: preferred
    // variant keys first, then any video-looking URL in the object.
    // (v120: the LOCK-SCREEN animated-artwork pipeline that also
    // lived here - motionURLs/pickMotionURLs and Player's HLS
    // fetch/export machinery - was removed wholesale at her
    // decision; what remains serves only the in-app headers.)
    func motionURL(kind: String, id: String) async -> String? {
        for amp in [true, false] {
            if let data = try? await request(path: "/v1/catalog/\(storefront)/\(kind)/\(id)?extend=editorialVideo", amp: amp),
               let u = Self.pickMotionURL(data) { return u }
        }
        return nil
    }
    func motionURLForSong(_ song: Song) async -> String? {
        if let aid = song.relationships?.albums?.data?.first?.id {
            return await motionURL(kind: "albums", id: aid)
        }
        if let full = await songFull(for: song), let aid = full.relationships?.albums?.data?.first?.id {
            return await motionURL(kind: "albums", id: aid)
        }
        return nil
    }
    static func pickMotionURL(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let attrs = arr.first?["attributes"] as? [String: Any],
              let ev = attrs["editorialVideo"] as? [String: Any] else { return nil }
        for k in ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailTall", "motionTallVideo3x4"] {
            if let v = (ev[k] as? [String: Any])?["video"] as? String, !v.isEmpty { return v }
        }
        return findVideoURL(ev)
    }
    static func findVideoURL(_ o: Any) -> String? {
        if let s = o as? String {
            let l = s.lowercased()
            return (l.contains(".mp4") || l.contains(".m4v") || l.contains(".mov") || l.contains(".m3u8")) ? s : nil
        }
        if let d = o as? [String: Any] { for v in d.values { if let r = findVideoURL(v) { return r } } }
        if let a = o as? [Any] { for v in a { if let r = findVideoURL(v) { return r } } }
        return nil
    }
    func artistVideos(id: String) async -> [MVItem] {
        let r: ListResponse<MVItem>? = try? await get("/v1/catalog/\(storefront)/artists/\(id)/music-videos?limit=12")
        return (r?.data ?? []).filter { $0.attributes?.name != nil }
    }

    // MARK: - Lyrics (TTML, 4-channel fallback like the web app)
    func lyrics(for song: Song) async throws -> [LyricLine] {
        let cid = try await resolveCatalogId(song)
        let paths: [(String, Bool)] = [
            ("/v1/catalog/\(storefront)/songs/\(cid)/lyrics", false),
            ("/v1/catalog/\(storefront)/songs/\(cid)?include=lyrics", false),
            ("/v1/catalog/\(storefront)/songs/\(cid)/lyrics", true),
            ("/v1/catalog/\(storefront)/songs/\(cid)/syllable-lyrics", false),
        ]
        var lastError: Error?
        for (p, amp) in paths {
            do {
                let data = try await request(path: p, amp: amp)
                if let lines = TTMLParser.parse(data: data), !lines.isEmpty { return lines }
                // ?include=lyrics shape: data[0].relationships.lyrics.data[0].attributes.ttml
                if let lines = TTMLParser.parseIncludeLyrics(data: data), !lines.isEmpty { return lines }
            } catch { lastError = error }
        }
        throw lastError ?? APIError.badData
    }
}

struct LyricLine: Identifiable, Hashable {
    var id: Int
    var begin: Double
    var text: String
}

enum TTMLParser {
    static func parse(data: Data) -> [LyricLine]? {
        // Direct TTML document (lyrics endpoint returns data[0].attributes.ttml)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["data"] as? [[String: Any]],
           let attrs = arr.first?["attributes"] as? [String: Any],
           let ttml = attrs["ttml"] as? String {
            return parseTTML(ttml)
        }
        if let s = String(data: data, encoding: .utf8), s.contains("<tt") { return parseTTML(s) }
        return nil
    }
    static func parseIncludeLyrics(data: Data) -> [LyricLine]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let rels = arr.first?["relationships"] as? [String: Any],
              let lyr = rels["lyrics"] as? [String: Any],
              let ldata = lyr["data"] as? [[String: Any]],
              let attrs = ldata.first?["attributes"] as? [String: Any],
              let ttml = attrs["ttml"] as? String else { return nil }
        return parseTTML(ttml)
    }
    static func parseTTML(_ ttml: String) -> [LyricLine] {
        let delegate = TTMLDelegate()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return delegate.lines
    }
    static func timeOf(_ s: String?) -> Double {
        guard let s = s else { return 0 }
        if s.hasSuffix("s") { return Double(s.dropLast()) ?? 0 }
        let parts = s.split(separator: ":").map { Double($0) ?? 0 }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts.first ?? 0
    }
}

final class TTMLDelegate: NSObject, XMLParserDelegate {
    var lines: [LyricLine] = []
    private var curBegin: Double = 0
    private var curText: String = ""
    private var inP = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "p" { inP = true; curBegin = TTMLParser.timeOf(attributeDict["begin"]); curText = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inP { curText += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "p" {
            inP = false
            let t = curText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(LyricLine(id: lines.count, begin: curBegin, text: t)) }
        }
    }
}
