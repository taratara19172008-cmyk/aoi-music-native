import Foundation

struct DownloadedSong: Codable, Identifiable, Hashable {
    var id: String // playback (catalog) id
    var title: String
    var artist: String
    var album: String
    var art: String? // artwork url template
    var fileName: String
    var date: Double
}

final class DownloadManager: ObservableObject {
    @Published var items: [DownloadedSong] = []
    @Published var active: Set<String> = []
    private let key = "aoi-downloads"

    init() {
        items = Player.loadJSON(key, [DownloadedSong].self) ?? []
    }

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloads", isDirectory: true)
    }

    func localURL(_ item: DownloadedSong) -> URL {
        dir.appendingPathComponent(item.fileName)
    }

    func isDownloaded(_ playbackId: String) -> Bool {
        items.contains { $0.id == playbackId }
    }

    func download(_ song: Song) {
        let pid = song.playbackId
        guard !isDownloaded(pid), !active.contains(pid) else { return }
        guard let urlStr = song.previewURL, let url = URL(string: urlStr) else { return }
        active.insert(pid)
        Task {
            defer { active.remove(pid) }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent("\(pid).m4a")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let item = DownloadedSong(
                    id: pid,
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    art: song.attributes?.artwork?.url,
                    fileName: "\(pid).m4a",
                    date: Date().timeIntervalSince1970
                )
                items.insert(item, at: 0)
                Player.saveJSON(key, items)
            } catch {}
        }
    }

    func remove(_ item: DownloadedSong) {
        try? FileManager.default.removeItem(at: localURL(item))
        items.removeAll { $0.id == item.id }
        Player.saveJSON(key, items)
    }

    func songStub(_ item: DownloadedSong) -> Song {
        Song(id: item.id, type: "songs", attributes: SongAttrs(
            name: item.title,
            artistName: item.artist,
            albumName: item.album,
            artwork: item.art.map { Artwork(url: $0) },
            previews: nil,
            durationInMillis: nil
        ))
    }
}
