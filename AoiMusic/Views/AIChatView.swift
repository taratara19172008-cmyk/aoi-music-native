import SwiftUI

struct AIChatMessage: Codable, Identifiable {
    var id = UUID()
    var role: String // user | ai
    var text: String
    var songs: [Song] = []
}

// The AI page (v106): a chat where the songs the AI names arrive as real,
// playable cards in the conversation — never links, never bare text. Every
// pick is verified against the Apple catalog before it becomes a card.
struct AIChatView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var engine: EngineBridge
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @State private var messages: [AIChatMessage] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var addSong: Song?
    @State private var saveTarget: AIChatMessage?
    @State private var playlistName = ""

    private var hasKey: Bool { !AIKeyStore.get().isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !hasKey {
                Spacer()
                keyHint
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            if messages.isEmpty { hintBubble }
                            ForEach(messages) { m in
                                bubble(m).id(m.id)
                            }
                            if thinking { thinkingRow }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                inputBar
            }
        }
        .onAppear {
            if messages.isEmpty {
                messages = Player.loadJSON("aoi-ai-chat", [AIChatMessage].self) ?? []
            }
        }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
        .alert(settings.t("ai_save_pl"), isPresented: saveAlertBinding) {
            TextField(settings.t("playlist_name_ph"), text: $playlistName)
            Button(settings.t("cancel"), role: .cancel) { saveTarget = nil }
            Button(settings.t("create")) { savePlaylist() }
        }
    }

    private var saveAlertBinding: Binding<Bool> {
        Binding(get: { saveTarget != nil }, set: { if !$0 { saveTarget = nil } })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [settings.accent, Color(red: 0.75, green: 0.35, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(settings.t("ai_title"))
                .font(.system(size: 30, weight: .bold))
            Spacer()
            if !messages.isEmpty {
                Button {
                    messages = []
                    Player.saveJSON("aoi-ai-chat", messages)
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .aoiGlass(corner: 12, interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var keyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [settings.accent, Color(red: 0.75, green: 0.35, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(settings.t("ai_need_key"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .aoiGlass(corner: 26)
        .padding(.horizontal, 16)
    }

    private var hintBubble: some View {
        HStack {
            Text(settings.t("ai_hint"))
                .font(.subheadline)
                .padding(12)
                .aoiGlass(corner: 20)
            Spacer(minLength: 46)
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(settings.t("ai_thinking"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .aoiGlass(corner: 20)
    }

    private func bubble(_ m: AIChatMessage) -> some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 46) }
            VStack(alignment: .leading, spacing: 8) {
                if !m.text.isEmpty && m.songs.isEmpty {
                    Text(m.text)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !m.songs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(m.songs.enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s, onTap: { player.playSongs(m.songs, start: i) }, onAdd: { addSong = s })
                        }
                    }
                    Button {
                        playlistName = ""
                        saveTarget = m
                    } label: {
                        Label(settings.t("ai_save_pl"), systemImage: "plus.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(settings.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background {
                if m.role == "user" {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(settings.accent.opacity(0.16))
                }
            }
            .aoiGlass(corner: 20)
            if m.role != "user" { Spacer(minLength: 46) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(settings.t("ai_ph"), text: $input)
                .onSubmit { send() }
                .submitLabel(.send)
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking ? Color.secondary.opacity(0.5) : settings.accent)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .aoiGlass(corner: 24, interactive: true)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, player.current == nil ? 14 : 86)
        .animation(.easeInOut(duration: 0.25), value: player.current == nil)
    }

    private func persist() {
        Player.saveJSON("aoi-ai-chat", Array(messages.suffix(40)))
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        input = ""
        messages.append(AIChatMessage(role: "user", text: text))
        persist()
        thinking = true
        let history: [(role: String, content: String)] = messages.suffix(8).map { m in
            if m.role == "user" { return (role: "user", content: m.text) }
            let list = m.songs.map { "\($0.title) — \($0.artist)" }.joined(separator: ", ")
            return (role: "assistant", content: list.isEmpty ? m.text : "Picked: \(list)")
        }
        Task {
            do {
                let profile = engine.authorized ? await AIClient.shared.tasteProfile(api: api) : nil
                let (_, picks) = try await AIClient.shared.chat(history: history, profile: profile)
                let songs = await AIClient.shared.resolve(picks, api: api)
                // Cards only (her call): whatever prose a model might add is
                // dropped; an empty result shows the app's own status line.
                var msg = AIChatMessage(role: "ai", text: songs.isEmpty ? settings.t("ai_no_match") : "")
                msg.songs = songs
                messages.append(msg)
            } catch {
                messages.append(AIChatMessage(role: "ai", text: settings.t("ai_fail")))
            }
            thinking = false
            persist()
        }
    }

    private func savePlaylist() {
        guard let target = saveTarget else { return }
        saveTarget = nil
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !target.songs.isEmpty else { return }
        Task {
            do {
                try await api.createPlaylistWithTracks(name: name, songs: target.songs)
                player.showToast(settings.t("created"))
            } catch {
                player.showToast(settings.t("op_fail"))
            }
        }
    }
}

// The "AI 推荐" strip under every playlist page (v106): reads the
// playlist's own songs, asks the model for more in the same spirit, and
// shows only picks that verify against the catalog. Results are cached
// per playlist so re-opening a page doesn't re-bill the API.
struct PlaylistAIRecView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    var cacheKey: String
    var seed: [Song]
    @State private var recs: [Song] = []
    @State private var loading = false
    @State private var addSong: Song?

    var body: some View {
        GlassSection(title: settings.t("ai_rec")) {
            if AIKeyStore.get().isEmpty {
                Text(settings.t("ai_need_key"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if loading && recs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(settings.t("ai_thinking"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if recs.isEmpty {
                Text(settings.t("ai_no_match"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recs.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s, onTap: { player.playSongs(recs, start: i) }, onAdd: { addSong = s })
                    }
                }
                Button {
                    Task { await fetch() }
                } label: {
                    HStack(spacing: 6) {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(settings.t("ai_more"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(settings.accent)
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .padding(.top, 6)
            }
        }
        .task { await loadCachedOrFetch() }
        .sheet(item: $addSong) { s in AddToPlaylistSheet(song: s) }
    }

    private var storeKey: String { "aoi-ai-rec-" + cacheKey }

    private func loadCachedOrFetch() async {
        if recs.isEmpty, let cached = Player.loadJSON(storeKey, [Song].self), !cached.isEmpty {
            recs = cached
            return
        }
        if recs.isEmpty { await fetch() }
    }

    private func fetch() async {
        guard !AIKeyStore.get().isEmpty, !seed.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        let shown = recs
        do {
            let picks = try await AIClient.shared.recommend(seed: seed, lang: settings.lang, avoid: shown)
            var songs = await AIClient.shared.resolve(picks, api: api)
            let seedIds = Set(seed.map { $0.id })
            let shownIds = Set(shown.map { $0.id })
            songs.removeAll { seedIds.contains($0.id) || shownIds.contains($0.id) }
            if !songs.isEmpty {
                recs = songs
                Player.saveJSON(storeKey, songs)
            } else if !shown.isEmpty {
                player.showToast(settings.t("ai_no_new"))
            }
        } catch {
            if !shown.isEmpty { player.showToast(settings.t("ai_fail")) }
        }
    }
}
