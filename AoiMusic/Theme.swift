import SwiftUI

struct AccentPreset: Identifiable {
    var id: Int
    var hex: String
    var zh: String
    var en: String
}

enum Accents {
    static let presets: [AccentPreset] = [
        .init(id: 0, hex: "#fa2d48", zh: "原版红", en: "Original Red"),
        .init(id: 1, hex: "#0a84ff", zh: "海蓝", en: "Ocean Blue"),
        .init(id: 2, hex: "#bf5af2", zh: "葡萄紫", en: "Grape Purple"),
        .init(id: 3, hex: "#30d158", zh: "薄荷绿", en: "Mint Green"),
        .init(id: 4, hex: "#ff9f0a", zh: "落日橙", en: "Sunset Orange"),
        .init(id: 5, hex: "#ff6482", zh: "樱花粉", en: "Sakura Pink"),
        .init(id: 6, hex: "#40c8e0", zh: "天空青", en: "Sky Cyan"),
    ]
    static func color(hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

final class AppSettings: ObservableObject {
    @Published var accentHex: String { didSet { UserDefaults.standard.set(accentHex, forKey: "aoi-accent") } }
    @Published var lang: String { didSet { UserDefaults.standard.set(lang, forKey: "aoi-lang") } }
    @Published var bgImage: UIImage? {
        didSet {
            if let img = bgImage, let data = img.jpegData(compressionQuality: 0.85) {
                try? data.write(to: Self.bgURL)
            } else {
                try? FileManager.default.removeItem(at: Self.bgURL)
            }
        }
    }
    static var bgURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("aoi-bg.jpg") }

    init() {
        accentHex = UserDefaults.standard.string(forKey: "aoi-accent") ?? "#40c8e0"
        lang = UserDefaults.standard.string(forKey: "aoi-lang") ?? "zh"
        if let data = try? Data(contentsOf: Self.bgURL), let img = UIImage(data: data) { bgImage = img }
    }
    var accent: Color { Accents.color(hex: accentHex) }
    func t(_ key: String) -> String { Strings.get(key, lang) }
}

enum Strings {
    static let zh: [String: String] = [
        "home": "首页", "search": "搜索", "radio": "电台", "library": "资料库", "settings": "设置",
        "good_morning": "上午好", "good_afternoon": "下午好", "good_evening": "晚上好", "good_night": "夜深了",
        "home_sub": "为你精选的热门音乐", "home_fail": "加载失败，检查网络后刷新",
        "np_goto_fail": "找不到对应页面", "official_stations": "官方电台", "feat_playlists": "精选歌单", "top_songs": "热门歌曲", "top_albums": "热门专辑", "recent_played": "最近播放", "rec_playlists": "推荐歌单", "rec_songs": "推荐歌曲", "music_videos": "音乐视频",
        "search_ph": "搜歌曲、歌手、专辑、歌单", "recent_search": "最近搜索", "clear": "清除",
        "songs": "歌曲", "albums": "专辑", "artists": "歌手", "playlists": "歌单",
        "play_all": "播放全部", "shuffle_play": "随机播放", "fav_album": "收藏专辑", "album_faved": "已收藏专辑",
        "fav_artist": "收藏歌手", "artist_faved": "已收藏歌手", "top_songs_a": "热门歌曲",
        "similar": "相似歌手", "back": "返回",
        "my_playlists": "我的歌单", "lib_songs": "资料库歌曲", "lib_artists": "资料库歌手", "lib_albums": "收藏的专辑", "downloads": "下载", "no_downloads": "还没有下载的歌曲", "downloaded": "已下载到本地", "downloading": "开始下载", "favorites": "喜爱", "fav_songs": "喜爱的歌曲", "no_fav_songs": "还没有喜爱的歌曲", "share": "分享", "new_playlist": "新建歌单",
        "edit_name": "修改名称", "delete_playlist": "删除歌单", "del": "删除",
        "radio_note": "登录后这里会显示为你推荐的歌单和电台", "radio_need": "先到设置里连接 Apple 账户",
        "lyrics": "歌词", "queue": "队列", "no_lyrics": "暂无歌词", "lyrics_signin": "连接 Apple 账户后可看歌词",
        "theme": "主题色", "custom_color": "自定义", "background": "背景", "pick_bg": "选择图片", "reset_bg": "恢复默认",
        "language": "语言", "account": "Apple 账户", "connect": "连接 Apple 账户", "disconnect": "断开连接",
        "connected": "已连接", "not_connected": "未连接", "storefront": "商店地区",
        "about": "关于", "about_text": "あおいミュージック AoiMusic · 第三方 Apple Music 客户端",
        "need_acct": "先到设置里连接 Apple 账户", "need_acct_fav": "先连接 Apple 账户才能收藏",
        "faved": "已收藏", "unfaved": "已取消收藏", "fav_fail": "收藏操作失败，再试一次",
        "added_to": "已添加到歌单", "add_fail": "添加失败，再试一次", "removed_from": "已从歌单移除", "remove_fail": "移除失败",
        "created": "歌单已创建", "renamed": "已改名", "deleted_pl": "歌单已删除", "op_fail": "操作失败，再试一次",
        "playlist_name_ph": "歌单名称", "create": "创建", "cancel": "取消", "save": "保存", "confirm_del": "确定删除这个歌单？",
        "add_to_playlist": "添加到歌单", "pick_song_first": "先选一首歌吧", "no_preview": "这首歌没有试听片段",
        "play_fail": "播放失败，可能是地区限制", "full": "完整版", "preview": "试听",
        "repeat_off": "循环关", "repeat_all": "循环全部", "repeat_one": "单曲循环",
        "shuffle_on": "随机播放开", "shuffle_off": "随机播放关",
        "loading": "加载中…", "empty": "这里还没有内容", "tracks_count": "首歌",
        "queue_title": "播放队列", "searching": "搜索中…", "no_results": "没有找到结果",
        "bg_saved": "背景已换好", "bg_too_big": "图片太大了，换一张试试",
        "ai": "AI", "ai_title": "AI 推荐", "play": "播放", "open": "打开", "fav_add": "收藏", "fav_remove": "取消收藏", "remove_from_pl": "从歌单移除", "unplayable": "这首歌暂时放不了",
        "ai_hint": "跟我说你想听什么：心情、场景、年代、风格都行。挑好的歌会直接摆在这里，点一下就能放。",
        "ai_ph": "想听点什么？", "ai_thinking": "正在为你挑歌…", "ai_save_pl": "存为歌单", "ai_rec": "AI 推荐", "ai_more": "换一批",
        "ai_provider": "AI 服务商", "ai_custom": "自定义", "ai_endpoint_ph": "接口地址，如 https://example.com/v1/chat/completions", "ai_model_ph": "模型名，如 gpt-4o-mini", "ai_key": "API Key", "ai_key_ph": "粘贴所选服务商的 key", "ai_key_saved": "Key 已保存",
        "ai_key_note": "每个服务商的 key 分开保存，只存这台手机，应用直连所选服务商生成推荐。不填的话 AI 功能不可用，其他功能不受影响。",
        "more_by": "更多%@的作品", "latest_from": "%@的最新发行", "fans_also": "%@的粉丝也喜欢", "ai_need_key": "先在设置里选好服务商并填入它的 API Key，AI 推荐才能工作", "ai_fail": "AI 刚才没回应，再试一次", "ai_no_match": "这次没在曲库里找到合适的歌，换个说法试试", "ai_no_new": "没有更多新歌了",
    ]
    static let en: [String: String] = [
        "home": "Home", "search": "Search", "radio": "Radio", "library": "Library", "settings": "Settings",
        "good_morning": "Good morning", "good_afternoon": "Good afternoon", "good_evening": "Good evening", "good_night": "Up late",
        "home_sub": "Top picks for you", "home_fail": "Couldn't load. Check your connection and retry.",
        "np_goto_fail": "Could not open that page", "official_stations": "Official Stations", "feat_playlists": "Featured Playlists", "top_songs": "Top Songs", "top_albums": "Top Albums", "recent_played": "Recently Played", "rec_playlists": "Recommended Playlists", "rec_songs": "Recommended Songs", "music_videos": "Music Videos",
        "search_ph": "Songs, artists, albums, playlists", "recent_search": "Recent Searches", "clear": "Clear",
        "songs": "Songs", "albums": "Albums", "artists": "Artists", "playlists": "Playlists",
        "play_all": "Play All", "shuffle_play": "Shuffle", "fav_album": "Favorite Album", "album_faved": "Favorited",
        "fav_artist": "Favorite Artist", "artist_faved": "Favorited", "top_songs_a": "Top Songs",
        "similar": "Similar Artists", "back": "Back",
        "my_playlists": "My Playlists", "lib_songs": "Library Songs", "lib_artists": "Library Artists", "lib_albums": "Favorite Albums", "downloads": "Downloads", "no_downloads": "No downloads yet", "downloaded": "Saved to this device", "downloading": "Downloading", "favorites": "Favorites", "fav_songs": "Loved Songs", "no_fav_songs": "No loved songs yet", "share": "Share", "new_playlist": "New Playlist",
        "edit_name": "Edit Name", "delete_playlist": "Delete Playlist", "del": "Delete",
        "radio_note": "Sign in to see recommended playlists and stations", "radio_need": "Connect your Apple account in Settings first",
        "lyrics": "Lyrics", "queue": "Queue", "no_lyrics": "No lyrics", "lyrics_signin": "Connect your Apple account to see lyrics",
        "theme": "Theme Color", "custom_color": "Custom", "background": "Background", "pick_bg": "Choose Photo", "reset_bg": "Reset",
        "language": "Language", "account": "Apple Account", "connect": "Connect Apple Account", "disconnect": "Disconnect",
        "connected": "Connected", "not_connected": "Not connected", "storefront": "Storefront",
        "about": "About", "about_text": "あおいミュージック AoiMusic · a third-party Apple Music client",
        "need_acct": "Connect your Apple account in Settings first", "need_acct_fav": "Connect your Apple account to favorite",
        "faved": "Added to favorites", "unfaved": "Removed from favorites", "fav_fail": "Favorite failed. Try again.",
        "added_to": "Added to playlist", "add_fail": "Add failed. Try again.", "removed_from": "Removed from playlist", "remove_fail": "Remove failed",
        "created": "Playlist created", "renamed": "Renamed", "deleted_pl": "Playlist deleted", "op_fail": "Failed. Try again.",
        "playlist_name_ph": "Playlist name", "create": "Create", "cancel": "Cancel", "save": "Save", "confirm_del": "Delete this playlist?",
        "add_to_playlist": "Add to Playlist", "pick_song_first": "Pick a song first", "no_preview": "No preview for this song",
        "play_fail": "Playback failed, possibly region-locked", "full": "Full", "preview": "Preview",
        "repeat_off": "Repeat off", "repeat_all": "Repeat all", "repeat_one": "Repeat one",
        "shuffle_on": "Shuffle on", "shuffle_off": "Shuffle off",
        "loading": "Loading…", "empty": "Nothing here yet", "tracks_count": "songs",
        "queue_title": "Queue", "searching": "Searching…", "no_results": "No results",
        "bg_saved": "Background updated", "bg_too_big": "Image too large, try another",
        "ai": "AI", "ai_title": "AI Picks", "play": "Play", "open": "Open", "fav_add": "Favorite", "fav_remove": "Unfavorite", "remove_from_pl": "Remove from Playlist", "unplayable": "This song can't be played right now",
        "ai_hint": "Tell me what you feel like hearing — a mood, a scene, an era, a style. The songs I pick appear right here, ready to play.",
        "ai_ph": "What do you want to hear?", "ai_thinking": "Picking songs for you…", "ai_save_pl": "Save as Playlist", "ai_rec": "AI Picks", "ai_more": "Show Another Batch",
        "ai_provider": "AI provider", "ai_custom": "Custom", "ai_endpoint_ph": "Endpoint URL, e.g. https://example.com/v1/chat/completions", "ai_model_ph": "Model name, e.g. gpt-4o-mini", "ai_key": "API Key", "ai_key_ph": "Paste the selected provider's key", "ai_key_saved": "Key saved",
        "ai_key_note": "Each provider's key is stored separately, only on this phone; the app calls the selected provider directly for recommendations. Without a key the AI features stay off; everything else works as before.",
        "more_by": "More by %@", "latest_from": "Latest from %@", "fans_also": "Fans of %@ also like", "ai_need_key": "Pick a provider and add its API key in Settings to use AI picks", "ai_fail": "The AI didn't answer just now — try again", "ai_no_match": "No matching songs in the catalog this time — try describing it differently", "ai_no_new": "No more new songs to show",
    ]
    static func get(_ key: String, _ lang: String) -> String {
        if lang == "en" { return en[key] ?? zh[key] ?? key }
        return zh[key] ?? key
    }
}

// MARK: - Liquid Glass (real on iOS 26, material fallback below)
struct GlassModifier: ViewModifier {
    var corner: CGFloat = 18
    var interactive: Bool = false
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .clear.interactive() : .clear, in: .rect(cornerRadius: corner))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        }
    }
}
extension View {
    func aoiGlass(corner: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(GlassModifier(corner: corner, interactive: interactive))
    }
}

// MARK: - Cover colour palette (dominant-colour gradients, v105)
// Pages no longer fade a cover into blank pastel: the whole background is a
// gradient grown out of the cover's own dominant colours, and text flips
// light/dark with the cover's luminance.
struct CoverPalette {
    var top: Color
    var bottom: Color
    var glow: Color
    var isDark: Bool
    static let fallback = CoverPalette(
        top: Color(red: 0.93, green: 0.96, blue: 0.99),
        bottom: Color(red: 0.98, green: 0.92, blue: 0.95),
        glow: Color(red: 0.45, green: 0.75, blue: 0.95),
        isDark: false)
}

enum CoverPaletteLoader {
    private static var cache: [String: CoverPalette] = [:]

    static func load(_ urlString: String?) async -> CoverPalette? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        if let hit = cache[s] { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return nil }
        let p = palette(from: img)
        cache[s] = p
        return p
    }

    static func palette(from image: UIImage) -> CoverPalette {
        // v107 sampling: three signals instead of one blended average.
        // (1) The dominant colour CLUSTER (quantized histogram) — the old
        // whole-image average mixed subject and background into grey.
        // (2) The cover's own EDGE colours — the page top continues the
        // cover's top edge and the melt at the hero's foot continues its
        // bottom edge, so image and page read as one surface.
        // (3) The most vibrant cluster, kept for the page glow.
        // v113: sample through an EXPLICIT RGBA bitmap context. The
        // old code read a UIGraphicsImageRenderer's bytes as if they
        // were R,G,B in memory - on device they are B,G,R
        // (byteOrder32Little), so every palette came out with red
        // and blue swapped: a red cover painted the Now Playing page
        // blue, a teal cover painted it olive. byteOrder32Big +
        // premultipliedLast pins the memory layout to R,G,B,A.
        let W = 32, H = 32
        guard let src = image.cgImage else { return .fallback }
        let rawPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H * 4)
        defer { rawPtr.deallocate() }
        rawPtr.initialize(repeating: 0, count: W * H * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: rawPtr, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return .fallback }
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: W, height: H))
        func px(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let o = (y * W + x) * 4
            return (Double(rawPtr[o]) / 255, Double(rawPtr[o + 1]) / 255, Double(rawPtr[o + 2]) / 255)
        }
        var buckets: [Int: (r: Double, g: Double, b: Double, n: Double)] = [:]
        var vR = 0.0, vG = 0.0, vB = 0.0, vW = 0.0
        for y in 0..<H {
            for x in 0..<W {
                let (r, g, b) = px(x, y)
                let key = Int(r * 5.99) * 36 + Int(g * 5.99) * 6 + Int(b * 5.99)
                var bk = buckets[key] ?? (0, 0, 0, 0)
                bk.r += r; bk.g += g; bk.b += b; bk.n += 1
                buckets[key] = bk
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                let w = sat * sat * (0.35 + mx)
                vR += r * w; vG += g * w; vB += b * w; vW += w
            }
        }
        func lumOf(_ bk: (r: Double, g: Double, b: Double, n: Double)) -> Double {
            (0.2126 * bk.r + 0.7152 * bk.g + 0.0722 * bk.b) / bk.n
        }
        let byCount = buckets.values.sorted { $0.n > $1.n }
        var dom = (0.5, 0.5, 0.5)
        if let first = byCount.first {
            dom = (first.r / first.n, first.g / first.n, first.b / first.n)
            let fl = lumOf(first)
            if fl > 0.92 || fl < 0.05,
               let alt = byCount.first(where: { bk in
                   let l = lumOf(bk)
                   return l <= 0.92 && l >= 0.05 && bk.n >= first.n * 0.4
               }) {
                // A giant near-white/near-black field (plain covers) should
                // not wash the whole page out when a real colour is close.
                dom = (alt.r / alt.n, alt.g / alt.n, alt.b / alt.n)
            }
        }
        let vib = vW > 0.01 ? (vR / vW, vG / vW, vB / vW) : dom
        func edgeAvg(_ rows: [Int]) -> (Double, Double, Double) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in rows { for x in 0..<W { let c = px(x, y); r += c.0; g += c.1; b += c.2; n += 1 } }
            return (r / n, g / n, b / n)
        }
        let edgeTop = edgeAvg([0, 1])
        let edgeBot = edgeAvg([H - 2, H - 1])
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        func shade(_ c: (Double, Double, Double), _ f: Double) -> (Double, Double, Double) {
            (min(max(c.0 * f, 0), 1), min(max(c.1 * f, 0), 1), min(max(c.2 * f, 0), 1))
        }
        func col(_ c: (Double, Double, Double)) -> Color { Color(red: c.0, green: c.1, blue: c.2) }
        let white = (1.0, 1.0, 1.0)
        let topC = mix(mix(edgeTop, dom, 0.35), white, 0.12)
        let botC = shade(mix(edgeBot, dom, 0.45), 0.70)
        let lum = 0.2126 * dom.0 + 0.7152 * dom.1 + 0.0722 * dom.2
        return CoverPalette(top: col(topC), bottom: col(botC), glow: col(vib), isDark: lum < 0.42)
    }
}

// MARK: - Glass section (v105): every section on every page sits on its own
// native liquid-glass panel; the title lives at the top of the panel.
struct GlassSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                Text(title)
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aoiGlass(corner: 26)
        .padding(.vertical, 7)
    }
}
