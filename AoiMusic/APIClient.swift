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
        let sf = storefront
        async let songs: ListResponse<Song> = get("/v1/catalog/\(sf)/charts?types=songs&limit=12")
        async let albums: ListResponse<CollectionItem> = get("/v1/catalog/\(sf)/charts?types=albums&limit=10")
        async let pls: ListResponse<CollectionItem> = get("/v1/catalog/\(sf)/charts?types=playlists&limit=10")
        var r = SearchResponse()
        r.results = SearchResponse.Results(songs: try? await songs, albums: try? await albums, artists: nil, playlists: try? await pls)
        return r
    }

    func songFull(id: String) async -> Song? {
        let r: ListResponse<Song>? = try? await get("/v1/catalog/\(storefront)/songs/\(id)?include=albums,artists")
        return r?.data?.first
    }

    func search(term: String) async throws -> SearchResponse {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
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

    func recentPlayed() async throws -> [Song] {
        let r: RecentPlayedResponse = try await get("/v1/me/recent/played/tracks?limit=10")
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
        return out
    }

    // MARK: - Library
    func libraryPlaylists() async throws -> [CollectionItem] {
        let r: ListResponse<CollectionItem> = try await get("/v1/me/library/playlists?limit=50")
        return r.data ?? []
    }
    func librarySongs() async throws -> [Song] {
        let r: ListResponse<Song> = try await get("/v1/me/library/songs?limit=50")
        return r.data ?? []
    }
    func libraryArtists() async throws -> [CollectionItem] {
        let r: ListResponse<CollectionItem> = try await get("/v1/me/library/artists?limit=50")
        return r.data ?? []
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
    func removeFromPlaylist(pid: String, librarySongId: String) async throws {
        let q = "?ids[library-songs]=\(librarySongId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? librarySongId)&mode=all"
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

    // MARK: - Ratings / favorites
    func rating(kind: String, id: String) async -> Bool {
        do {
            let r: RatingResponse = try await get("/v1/me/ratings/\(kind)/\(id)")
            return r.data?.attributes?.value == 1
        } catch { return false }
    }
    func rateWrite(kind: String, id: String) async throws {
        let body: [String: Any] = ["type": "ratings", "attributes": ["value": 1]]
        do { _ = try await request(path: "/v1/me/ratings/\(kind)/\(id)", method: "PUT", body: body) }
        catch { _ = try await request(path: "/v1/me/ratings/\(kind)/\(id)", method: "POST", body: body) }
    }
    func rateDelete(kind: String, id: String) async throws {
        _ = try await request(path: "/v1/me/ratings/\(kind)/\(id)", method: "DELETE")
        if await rating(kind: kind, id: id) {
            _ = try await request(path: "/v1/me/ratings/\(kind)/\(id)", method: "DELETE")
        }
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
