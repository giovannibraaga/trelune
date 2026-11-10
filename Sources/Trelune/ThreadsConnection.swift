import Foundation

/// Threads API client. The access token is generated in the Meta app dashboard (Threads use case → User Token Generator)
/// because Threads only accepts HTTPS redirect URIs, which a desktop loopback callback cannot provide.
@MainActor final class ThreadsConnection: ObservableObject {
    private static let api = "https://graph.threads.net/v1.0"
    private let vault = KeychainSlot(service: AppIdentity.keychainService("threads"))
    private var config: Config?

    @Published private(set) var loading = true
    @Published private(set) var busy = false
    @Published private(set) var username = ""
    @Published private(set) var recent: [ThreadPost] = []
    /// Account insights (needs threads_manage_insights); nil when not authorized.
    @Published private(set) var followers: Int?
    @Published private(set) var views: Int?
    struct PostStats { var views: Int?; var likes: Int?; var replies: Int?; var reposts: Int? }
    @Published private(set) var postStats: [String: PostStats] = [:]
    @Published var message = ""
    var connected: Bool { config?.token.isEmpty == false }

    struct Config: Codable { var token: String; var userID: String; var username: String; var expires: Date; var refreshed: Date }
    struct ThreadPost: Decodable, Identifiable { let id: String; let text: String?; let timestamp: String?; let permalink: String?; let media_type: String?; let media_url: String?; let thumbnail_url: String? }
    private struct Me: Decodable { let id: String; let username: String? }
    private struct IDResponse: Decodable { let id: String }
    private struct Token: Decodable { let access_token: String; let expires_in: Int? }
    private struct ContainerStatus: Decodable { let status: String?; let error_message: String? }
    private struct List<T: Decodable>: Decodable { let data: [T] }
    private struct ErrorEnvelope: Decodable { struct E: Decodable { let message: String?; let code: Int? }; let error: E? }

    init() {
        Task {
            defer { loading = false }
            do {
                let slot = vault
                if let data = try await Task.detached(priority: .userInitiated, operation: { try slot.read() }).value {
                    let saved = try JSONDecoder().decode(Config.self, from: data)
                    config = saved; username = saved.username
                }
            } catch { message = error.localizedDescription }
        }
    }

    /// Re-reads the Keychain after the cloud refreshed the credentials.
    func reloadCredentials() async {
        let slot = vault
        guard let data = try? await Task.detached(operation: { try slot.read() }).value, let saved = try? JSONDecoder().decode(Config.self, from: data) else { return }
        config = saved; username = saved.username
    }
    func connect(token raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !busy else { message = "Cole o token de acesso do Threads."; return }
        busy = true; defer { busy = false }
        do {
            let me: Me = try await get("me", token: token, query: ["fields": "id,username"])
            var saved = Config(token: token, userID: me.id, username: me.username ?? "", expires: Date().addingTimeInterval(60 * 86400), refreshed: Date())
            // Exchange-free refresh extends long-lived tokens; short-lived tokens fail here and keep their own expiry.
            if let refreshed: Token = try? await get("refresh_access_token", token: token, query: ["grant_type": "th_refresh_token"], root: "https://graph.threads.net") {
                saved.token = refreshed.access_token; saved.expires = Date().addingTimeInterval(Double(refreshed.expires_in ?? 5_184_000))
            }
            try persist(saved)
            message = "Threads conectado como @\(saved.username)."
            try? await loadRecent()
        } catch { message = error.localizedDescription }
    }

    func refresh() async {
        guard connected, !busy else { return }
        busy = true; defer { busy = false }
        do { try await ensureFreshToken(); try await loadRecent(); message = "Dados do Threads atualizados." } catch { message = error.localizedDescription }
    }

    func disconnect() {
        do { try vault.delete(); config = nil; username = ""; recent = []; message = "Token do Threads removido deste Mac." } catch { message = error.localizedDescription }
    }

    /// Publishes a text, single image/video or carousel (2–20 public URLs) and returns the published media ID.
    func publish(text: String, mediaURL: String?) async throws -> String {
        try await publish(text: text, mediaURLs: mediaURL.map { [$0] } ?? [])
    }
    func publish(text: String, mediaURLs: [String]) async throws -> String {
        guard !busy else { throw AppIssue("O Threads está ocupado com outra operação.") }
        busy = true; defer { busy = false }
        try await ensureFreshToken()
        guard let config else { throw AppIssue("Conecte o Threads antes de publicar.") }
        guard text.count <= 500 else { throw AppIssue("O texto do Threads pode ter até 500 caracteres.") }
        let urls = mediaURLs.filter { !$0.isEmpty }
        guard urls.count <= 20 else { throw AppIssue("O carrossel do Threads aceita até 20 itens.") }
        for url in urls where URL(string: url)?.scheme != "https" { throw AppIssue("O Threads precisa de URLs HTTPS públicas para a mídia.") }
        func mediaFields(_ url: String) -> [String: String] { MediaKind.isVideoURL(url) ? ["media_type": "VIDEO", "video_url": url] : ["media_type": "IMAGE", "image_url": url] }
        let containerID: String
        if urls.count > 1 {
            var children: [String] = []
            for url in urls {
                var fields = mediaFields(url); fields["is_carousel_item"] = "true"
                let child: IDResponse = try await post("\(config.userID)/threads", token: config.token, fields: fields)
                try await waitReady(child.id, token: config.token, text: false)
                children.append(child.id)
            }
            let parent: IDResponse = try await post("\(config.userID)/threads", token: config.token, fields: ["media_type": "CAROUSEL", "children": children.joined(separator: ","), "text": text])
            containerID = parent.id
        } else {
            var fields = urls.first.map(mediaFields) ?? ["media_type": "TEXT"]
            fields["text"] = text
            containerID = (try await post("\(config.userID)/threads", token: config.token, fields: fields) as IDResponse).id
        }
        try await waitReady(containerID, token: config.token, text: urls.isEmpty)
        let published: IDResponse = try await post("\(config.userID)/threads_publish", token: config.token, fields: ["creation_id": containerID])
        message = "Publicado no Threads @\(config.username)."
        return published.id
    }
    /// Meta recommends waiting for the container to finish processing before publishing.
    private func waitReady(_ id: String, token: String, text: Bool) async throws {
        for _ in 0..<60 {
            let state: ContainerStatus = try await get(id, token: token, query: ["fields": "status,error_message"])
            if state.status == "FINISHED" || (state.status == nil && text) { return }
            if state.status == "ERROR" || state.status == "EXPIRED" { throw AppIssue("O Threads não processou a mídia: \(state.error_message ?? "erro não informado").") }
            try await Task.sleep(for: .seconds(text ? 1 : 5))
        }
        throw AppIssue("O Threads ainda está processando a mídia. Tente novamente em alguns minutos.")
    }

    private func loadRecent() async throws {
        guard let config else { return }
        let list: List<ThreadPost> = try await get("me/threads", token: config.token, query: ["fields": "id,text,timestamp,permalink,media_type,media_url,thumbnail_url", "limit": "10"])
        recent = list.data
        var stats: [String: PostStats] = [:]
        for post in list.data.prefix(10) {
            guard let insights: InsightList = try? await get("\(post.id)/insights", token: config.token, query: ["metric": "views,likes,replies,reposts"]) else { break }
            var row = PostStats()
            for item in insights.data {
                let value = item.total_value?.value ?? item.values?.map(\.value).reduce(0, +)
                switch item.name { case "views": row.views = value; case "likes": row.likes = value; case "replies": row.replies = value; case "reposts": row.reposts = value; default: break }
            }
            stats[post.id] = row
        }
        postStats = stats
        // Insights are optional: they require threads_manage_insights in the token.
        if let insights: InsightList = try? await get("me/threads_insights", token: config.token, query: ["metric": "views,followers_count"]) {
            for item in insights.data {
                let value = item.total_value?.value ?? item.values?.map(\.value).reduce(0, +)
                if item.name == "followers_count" { followers = value } else if item.name == "views" { views = value }
            }
        }
    }
    private struct InsightList: Decodable { struct Item: Decodable { struct Total: Decodable { let value: Int }; struct Value: Decodable { let value: Int }; let name: String; let total_value: Total?; let values: [Value]? }; let data: [Item] }
    private func ensureFreshToken() async throws {
        guard var saved = config else { throw AppIssue("Conecte o Threads antes de continuar.") }
        guard saved.expires > Date() else { throw AppIssue("O token do Threads expirou. Gere um novo token no painel da Meta e conecte novamente.") }
        // Long-lived tokens can be refreshed once they are at least 24 hours old.
        if saved.expires < Date().addingTimeInterval(10 * 86400), saved.refreshed < Date().addingTimeInterval(-86400) {
            let token: Token = try await get("refresh_access_token", token: saved.token, query: ["grant_type": "th_refresh_token"], root: "https://graph.threads.net")
            saved.token = token.access_token; saved.expires = Date().addingTimeInterval(Double(token.expires_in ?? 5_184_000)); saved.refreshed = Date()
            try persist(saved)
        }
    }
    private func get<T: Decodable>(_ path: String, token: String, query: [String: String], root: String = api) async throws -> T {
        var parts = URLComponents(string: "\(root)/\(path)")!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "access_token", value: token)]
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 60
        return try await perform(request)
    }
    private func post<T: Decodable>(_ path: String, token: String, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "\(Self.api)/\(path)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = fields; all["access_token"] = token
        request.httpBody = TikTokProtocol.form(all)
        return try await perform(request)
    }
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message ?? "HTTP \(status)"
            throw AppIssue("O Threads recusou a operação: \(detail).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw AppIssue("O Threads retornou uma resposta inesperada.") }
    }
    private func persist(_ saved: Config) throws { try vault.write(JSONEncoder().encode(saved)); config = saved; username = saved.username }
}
