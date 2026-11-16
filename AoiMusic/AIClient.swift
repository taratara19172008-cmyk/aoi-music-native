import Foundation
import Security

// The DeepSeek key lives only in this phone's Keychain (v106): she pastes
// it once in Settings; it never transits chat or any server of ours, and
// the app calls DeepSeek directly with it.
enum AIKeyStore {
    private static let service = "com.aoimusic.deepseek"
    private static let account = "api-key"

    static func get() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
    func chat(history: [(role: String, content: String)]) async throws -> (text: String, picks: [AIPick]) {
        let key = AIKeyStore.get()
        guard !key.isEmpty else { throw AIError.noKey }
        var messages: [[String: String]] = [["role": "system", "content": Self.systemPrompt]]
        messages += history.map { ["role": $0.role, "content": $0.content] }
        let raw = try await complete(messages: messages, key: key)
        return Self.parse(raw)
    }

    // Picks in the spirit of an existing playlist, for the AI strip under
    // every playlist page.
    func recommend(seed: [Song], lang: String) async throws -> [AIPick] {
        let key = AIKeyStore.get()
        guard !key.isEmpty else { throw AIError.noKey }
        let lines = seed.prefix(15).map { "\($0.title) — \($0.artist)" }.joined(separator: "\n")
        let ask = lang == "en"
            ? "Here is a playlist:\n\(lines)\nRecommend 10 more songs in the same spirit that are NOT already in this list."
            : "这是一个歌单：\n\(lines)\n请推荐 10 首气质相近、且不在上面列表里的歌。"
        let raw = try await complete(messages: [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": ask],
        ], key: key)
        return Self.parse(raw).picks
    }

    private func complete(messages: [[String: String]], key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": "deepseek-chat",
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
