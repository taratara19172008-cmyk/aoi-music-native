import Foundation
import Security

// AI providers (v107): all of these speak the same OpenAI-compatible
// chat-completions format, so switching providers is just endpoint +
// model + that provider's own key. She picks one in Settings; keys are
// stored per provider in the Keychain (DeepSeek keeps its original
// service name, so a key entered back in v106 keeps working untouched),
// and the app calls the selected provider directly — keys never transit
// chat or any server of ours.
struct AIProvider: Identifiable {
    var id: String
    var name: String
    var endpoint: String
    var model: String

    static let all: [AIProvider] = [
        AIProvider(id: "deepseek", name: "DeepSeek", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-chat"),
        AIProvider(id: "qwen", name: "通义千问", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", model: "qwen-plus"),
        AIProvider(id: "glm", name: "智谱 GLM", endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions", model: "glm-4-plus"),
        AIProvider(id: "kimi", name: "Kimi", endpoint: "https://api.moonshot.cn/v1/chat/completions", model: "moonshot-v1-8k"),
        AIProvider(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o-mini"),
        AIProvider(id: "custom", name: "Custom", endpoint: "", model: ""),
    ]

    static var currentId: String {
        UserDefaults.standard.string(forKey: "ai_provider_id") ?? "deepseek"
    }

    static func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: "ai_provider_id")
    }

    static var customEndpoint: String {
        UserDefaults.standard.string(forKey: "ai_custom_endpoint") ?? ""
    }

    static var customModel: String {
        UserDefaults.standard.string(forKey: "ai_custom_model") ?? ""
    }

    static func setCustom(endpoint: String, model: String) {
        UserDefaults.standard.set(endpoint, forKey: "ai_custom_endpoint")
        UserDefaults.standard.set(model, forKey: "ai_custom_model")
    }

    static func current() -> AIProvider {
        guard var p = all.first(where: { $0.id == currentId }) else { return all[0] }
        if p.id == "custom" {
            p.endpoint = customEndpoint
            p.model = customModel
        }
        return p
    }

    var isReady: Bool { !endpoint.isEmpty && !model.isEmpty }
}

enum AIKeyStore {
    private static let account = "api-key"

    private static func service(for id: String) -> String {
        id == "deepseek" ? "com.aoimusic.deepseek" : "com.aoimusic.ai.\(id)"
    }

    static func get() -> String { get(forProvider: AIProvider.currentId) }

    static func set(_ value: String) { set(value, forProvider: AIProvider.currentId) }

    static func get(forProvider id: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ value: String, forProvider id: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

struct AIPick: Codable {
    var title: String
    var artist: String
}

enum AIError: Error {
    case noKey
    case badResponse
}

final class AIClient {
    static let shared = AIClient()

    // One chat round-trip: the model's prose plus the songs it named
    // (unresolved — resolve() checks them against the real catalog).
    func chat(history: [(role: String, content: String)], profile: String? = nil) async throws -> (text: String, picks: [AIPick]) {
        let key = AIKeyStore.get()
        guard !key.isEmpty else { throw AIError.noKey }
        var messages: [[String: String]] = [["role": "system", "content": Self.systemPrompt]]
        if let profile = profile, !profile.isEmpty {
            messages.append(["role": "system", "content": profile])
        }
        messages += history.map { ["role": $0.role, "content": $0.content] }
        let raw = try await complete(messages: messages, key: key)
        return Self.parse(raw)
    }

    // Picks in the spirit of an existing playlist, for the AI strip under
    // every playlist page.
    func recommend(seed: [Song], lang: String, avoid: [Song] = []) async throws -> [AIPick] {
        let key = AIKeyStore.get()
        guard !key.isEmpty else { throw AIError.noKey }
        let lines = seed.prefix(15).map { "\($0.title) — \($0.artist)" }.joined(separator: "\n")
        var ask = lang == "en"
            ? "Here is a playlist:\n\(lines)\nRecommend 10 more songs in the same spirit that are NOT already in this list."
            : "这是一个歌单：\n\(lines)\n请推荐 10 首气质相近、且不在上面列表里的歌。"
        if !avoid.isEmpty {
            // "换一批" used to re-ask blind: the model happily returned the
            // same batch and the button looked dead. Name the songs she
            // has already been shown so the new batch is actually new.
            let names = avoid.prefix(20).map { "\($0.title) — \($0.artist)" }.joined(separator: "; ")
            ask += lang == "en"
                ? "\nDo NOT recommend any of these — she has already been shown them: \(names)."
                : "\n不要推荐这些，她已经看过了：\(names)。"
        }
        let raw = try await complete(messages: [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": ask],
        ], key: key)
        return Self.parse(raw).picks
    }

    // MARK: - Taste profile (v107, mirrors the web app)
    // A compact picture of her listening — recent plays, loved songs,
    // playlist names — attached to CHAT requests only, so "something
    // like what I've been listening to lately" actually knows what that
    // is (the native chat used to answer blind and served generic chart
    // hits). Titles and artists only; cached for ten minutes.
    private var cachedProfile: (text: String, at: Date)?

    func tasteProfile(api: APIClient) async -> String? {
        if let c = cachedProfile, Date().timeIntervalSince(c.at) < 600 { return c.text }
        var parts: [String] = []
        let recent = (try? await api.recentPlayed(limit: 15)) ?? []
        if !recent.isEmpty {
            parts.append("Recently played: " + recent.prefix(15).map { "\($0.title) — \($0.artist)" }.joined(separator: "; "))
        }
        let favs = await api.favoriteSongs()
        if !favs.isEmpty {
            parts.append("Loved songs: " + favs.prefix(40).map { "\($0.title) — \($0.artist)" }.joined(separator: "; "))
        }
        let pls = (try? await api.libraryPlaylists()) ?? []
        if !pls.isEmpty {
            parts.append("Her playlists: " + pls.prefix(30).map { $0.title }.joined(separator: "; "))
        }
        guard !parts.isEmpty else { return nil }
        let text = "The user's own listening profile — ground your picks in what she actually listens to:\n" + parts.joined(separator: "\n")
        cachedProfile = (text, Date())
        return text
    }

    private func complete(messages: [[String: String]], key: String) async throws -> String {
        let provider = AIProvider.current()
        guard provider.isReady, let url = URL(string: provider.endpoint) else { throw AIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "temperature": 0.8,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.badResponse
        }
        struct Resp: Decodable {
            var choices: [Choice]?
            struct Choice: Decodable {
                var message: Msg?
                struct Msg: Decodable { var content: String? }
            }
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let c = r.choices?.first?.message?.content else { throw AIError.badResponse }
        return c
    }

    static let systemPrompt = """
    You are the song picker inside AoiMusic, a personal Apple Music client. \
    The user describes what they want to hear; you pick songs from the APPLE MUSIC catalog. \
    Reply with ONLY a fenced json block in exactly this shape and NOTHING else - no greeting, no explanation, no prose of any kind: \
    {"songs":[{"title":"...","artist":"..."}]} with 8 to 12 songs. \
    Every song must really exist on Apple Music, under the performing artist's common name. \
    The app verifies each pick against the Apple Music catalog and silently drops anything that does not match, so accuracy matters more than quantity.
    """

    static func parse(_ raw: String) -> (text: String, picks: [AIPick]) {
        var picks: [AIPick] = []
        var text = raw
        let start = raw.range(of: "{\"songs\"")?.lowerBound ?? raw.range(of: "{")?.lowerBound
        if let start = start, let end = raw.range(of: "}", options: .backwards) {
            let jsonStr = String(raw[start...end.lowerBound])
            struct Block: Decodable { var songs: [AIPick]? }
            if let data = jsonStr.data(using: .utf8),
               let block = try? JSONDecoder().decode(Block.self, from: data),
               let songs = block.songs {
                picks = songs
            }
        }
        if !picks.isEmpty {
            if let fence = raw.range(of: "```") {
                text = String(raw[..<fence.lowerBound])
            } else if let brace = raw.range(of: "{") {
                text = String(raw[..<brace.lowerBound])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, picks)
    }

    // Resolve model picks against the real catalog: a pick only becomes a
    // playable card when a catalog song matches its title AND artist.
    func resolve(_ picks: [AIPick], api: APIClient) async -> [Song] {
        var out: [Song] = []
        var seen = Set<String>()
        for pick in picks {
            if out.count >= 12 { break }
            guard let r = try? await api.search(term: "\(pick.artist) \(pick.title)"),
                  let songs = r.results?.songs?.data else { continue }
            let want = Self.norm(pick.title)
            let wantA = Self.norm(pick.artist)
            let match = songs.first { s in
                let t = Self.norm(s.title)
                let a = Self.norm(s.artist)
                return (t == want || t.contains(want) || want.contains(t))
                    && (a == wantA || a.contains(wantA) || wantA.contains(a))
            } ?? songs.first { s in
                let t = Self.norm(s.title)
                return t == want || t.contains(want) || want.contains(t)
            }
            if let m = match, seen.insert(m.id).inserted { out.append(m) }
        }
        return out
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
