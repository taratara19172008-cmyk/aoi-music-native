import Foundation

struct Artwork: Codable, Hashable {
    var url: String?
    func urlString(_ w: Int, _ h: Int) -> String? {
        guard let u = url else { return nil }
        return u.replacingOccurrences(of: "{w}", with: "\(w)").replacingOccurrences(of: "{h}", with: "\(h)")
    }
}

struct SongAttrs: Codable, Hashable {
    var name: String?
    var url: String?
    var artistName: String?
    var albumName: String?
    var artwork: Artwork?
    var previews: [Preview]?
    var durationInMillis: Int?
    var playParams: PlayParams?
    struct PlayParams: Codable, Hashable { var id: String?; var catalogId: String?; var isLibrary: Bool? }
    struct Preview: Codable, Hashable { var url: String? }
}

struct Song: Codable, Identifiable, Hashable {
    var id: String
    var type: String?
    var attributes: SongAttrs?
    var relationships: Relationships?
    struct Relationships: Codable, Hashable {
        var albums: RelData?
        var artists: RelData?
        struct RelData: Codable, Hashable { var data: [RelItem]? }
        struct RelItem: Codable, Hashable { var id: String; var type: String? }
    }
    var title: String { attributes?.name ?? "" }
    var artist: String { attributes?.artistName ?? "" }
    var album: String { attributes?.albumName ?? "" }
    var previewURL: String? { attributes?.previews?.first?.url }
    var playbackId: String { attributes?.playParams?.catalogId ?? id }
    func art(_ w: Int, _ h: Int) -> String? { attributes?.artwork?.urlString(w, h) }
}

struct CollectionAttrs: Codable, Hashable {
    var name: String?
    var artistName: String?
    var curatorName: String?
    var artwork: Artwork?
    var description: Desc?
    var trackCount: Int?
    struct Desc: Codable, Hashable { var standard: String?; var short: String? }
}

struct CollectionItem: Codable, Identifiable, Hashable {
    var id: String
    var type: String?
    var attributes: CollectionAttrs?
    var title: String { attributes?.name ?? "" }
    var sub: String { attributes?.artistName ?? attributes?.curatorName ?? "" }
    func art(_ w: Int, _ h: Int) -> String? { attributes?.artwork?.urlString(w, h) }
}

struct ListResponse<T: Codable>: Codable {
    var data: [T]?
}

struct SearchResponse: Codable {
    var results: Results?
    struct Results: Codable {
        var songs: ListResponse<Song>?
        var albums: ListResponse<CollectionItem>?
        var artists: ListResponse<CollectionItem>?
        var playlists: ListResponse<CollectionItem>?
    }
}

struct TracksResponse: Codable {
    var data: [Song]?
    var relationships: Rels?
    struct Rels: Codable { var tracks: ListResponse<Song>? }
}

struct ArtistDetailResponse: Codable {
    var data: [ArtistDetail]?
    struct ArtistDetail: Codable {
        var id: String
        var attributes: CollectionAttrs?
        var views: Views?
        var relationships: Rels?
        struct Views: Codable {
            var topSongs: ListResponse<Song>?
            var albums: ListResponse<CollectionItem>?
            var playlists: ListResponse<CollectionItem>?
            var similarArtists: ListResponse<CollectionItem>?
            enum CodingKeys: String, CodingKey {
                case topSongs = "top-songs"
                case albums, playlists
                case similarArtists = "similar-artists"
            }
        }
        struct Rels: Codable {
            var albums: ListResponse<CollectionItem>?
            var playlists: ListResponse<CollectionItem>?
        }
    }
}

struct RatingResponse: Codable {
    var data: RatingData?
    struct RatingData: Codable { var attributes: RatingAttrs? }
    struct RatingAttrs: Codable { var value: Int? }
}

struct RecentPlayedResponse: Codable { var data: [Song]? }
