import Foundation
import AppKit
import CryptoKit

/// X (Twitter) API v2 client using OAuth 2.0 Authorization Code with PKCE and a fixed loopback callback.
@MainActor final class XConnection: ObservableObject {
    static let callbackPort: UInt16 = 49683
    static let callbackURL = "http://127.0.0.1:49683/oauth/callback"
    private static let scopes = "tweet.read tweet.write users.read media.write offline.access"
    private let vault = KeychainSlot(service: AppIdentity.keychainService("x"))
    private var config: Config?
    private var callback: LoopbackCallback?

    @Published private(set) var loading = true
    @Published private(set) var busy = false
    @Published private(set) var configured = false
    @Published private(set) var username = ""
    @Published private(set) var followers: Int?
    @Published private(set) var recent: [Tweet] = []
    struct Tweet: Decodable, Identifiable { struct Metrics: Decodable { let like_count: Int?; let reply_count: Int?; let retweet_count: Int?; let impression_count: Int? }; let id: String; let text: String; let created_at: String?; let public_metrics: Metrics? }
    private struct TweetList: Decodable { let data: [Tweet]? }
    @Published var message = ""
    var connected: Bool { config?.accessToken.isEmpty == false }

    struct Config: Codable {
        var clientID: String
        var clientSecret: String
        var accessToken = ""
        var refreshToken = ""
        var expires = Date.distantPast
        var username = ""
    }
    private struct Token: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int? }
    private struct Me: Decodable { struct Data: Decodable { struct Metrics: Decodable { let followers_count: Int? }; let id: String; let username: String; let public_metrics: Metrics? }; let data: Data }
    private struct Created: Decodable { struct Data: Decodable { let id: String }; let data: Data }
    private struct Media: Decodable { struct Data: Decodable { let id: String }; let data: Data?; let media_id_string: String? }

    init() {
        Task {
            defer { loading = false }
            do {
                let slot = vault
                if let data = try await Task.detached(priority: .userInitiated, operation: { try slot.read() }).value {
                    let saved = try JSONDecoder().decode(Config.self, from: data)
                    config = saved; configured = true; username = saved.username
                }
            } catch { message = error.localizedDescription }
        }
    }

    /// Re-reads the Keychain after the cloud refreshed the credentials.
    func reloadCredentials() async {
        let slot = vault
        guard let data = try? await Task.detached(operation: { try slot.read() }).value, let saved = try? JSONDecoder().decode(Config.self, from: data) else { return }
        config = saved; configured = true; username = saved.username
    }
    func saveClient(id: String, secret: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines), secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { message = "Informe o Client ID OAuth 2.0 do app no portal do X."; return }
        do { try persist(Config(clientID: id, clientSecret: secret)); username = ""; followers = nil; message = "Credenciais do X salvas no Chaves. Agora autorize a conta." } catch { message = error.localizedDescription }
    }

    func connect() async {
        guard var saved = config, !busy else { return }
        busy = true; message = "Aguardando autorização do X no navegador…"
        defer { callback?.cancel(); callback = nil; busy = false }
        do {
            let verifier = try Random.token(), state = try Random.token()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let receiver = LoopbackCallback(state: state, fixedPort: Self.callbackPort)
            callback = receiver
            let redirect = try await receiver.start()
            var url = URLComponents(string: "https://x.com/i/oauth2/authorize")!
            url.queryItems = ["response_type": "code", "client_id": saved.clientID, "redirect_uri": redirect, "scope": Self.scopes, "state": state, "code_challenge": challenge, "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let authURL = url.url, NSWorkspace.shared.open(authURL) else { throw AppIssue("Não foi possível abrir o navegador.") }
            let code = try await receiver.code()
            let token = try await tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "code_verifier": verifier], config: saved)
            apply(token, to: &saved)
            try persist(saved)
            try await loadProfile()
        } catch { message = error.localizedDescription }
    }

    func refresh() async {
        guard connected, !busy else { return }
        busy = true; defer { busy = false }
        do { try await loadProfile() } catch { message = error.localizedDescription }
    }

    func disconnect() async {
        guard let saved = config, !busy else { return }
        busy = true; defer { busy = false }
        if !saved.accessToken.isEmpty {
            var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/revoke")!)
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            authorizeClient(&request, config: saved)
            request.httpBody = TikTokProtocol.form(["token": saved.accessToken, "token_type_hint": "access_token", "client_id": saved.clientID])
            _ = try? await URLSession.shared.data(for: request)
        }
        do { try vault.delete(); config = nil; configured = false; username = ""; followers = nil; message = "Acesso ao X revogado e credenciais removidas deste Mac." } catch { message = error.localizedDescription }
    }

    /// Posts a text with up to four images and returns the post ID.
    func post(text: String, image: URL?) async throws -> String { try await post(text: text, images: image.map { [$0] } ?? []) }
    func post(text: String, images: [URL]) async throws -> String {
        guard !busy else { throw AppIssue("O X está ocupado com outra operação.") }
        busy = true; defer { busy = false }
        guard NetworkLimits.length(text, for: "X") <= 280 else { throw AppIssue("O texto do X passa de 280 caracteres. Personalize a versão do X com um texto mais curto.") }
        guard images.count <= 4 else { throw AppIssue("O X aceita até 4 imagens por post.") }
        let token = try await accessToken()
        var body: [String: Any] = ["text": text]
        if !images.isEmpty {
            var ids: [String] = []
            for image in images {
                guard MediaKind.isImage(image.path) else { throw AppIssue("O envio para o X aceita imagens JPG, PNG, GIF ou WebP. Vídeos não são enviados por esta integração.") }
                ids.append(try await uploadImage(image, token: token))
            }
            body["media"] = ["media_ids": ids]
        }
        var request = URLRequest(url: URL(string: "https://api.x.com/2/tweets")!)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let created: Created = try await perform(request)
        message = "Publicado no X @\(username)."
        return created.data.id
    }

    private func uploadImage(_ file: URL, token: String) async throws -> String {
        let data = try Data(contentsOf: file)
        guard data.count <= 5_000_000 else { throw AppIssue("A imagem para o X deve ter até 5 MB.") }
        let ext = file.pathExtension.lowercased()
        let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"][ext] ?? "application/octet-stream"
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"media_category\"\r\n\r\n\(ext == "gif" ? "tweet_gif" : "tweet_image")\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"\(file.lastPathComponent.replacingOccurrences(of: "\"", with: ""))\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.x.com/2/media/upload")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let media: Media = try await perform(request)
        guard let id = media.data?.id ?? media.media_id_string else { throw AppIssue("O X não retornou o identificador da imagem.") }
        return id
    }
    private func loadProfile() async throws {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://api.x.com/2/users/me?user.fields=public_metrics")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let me: Me = try await perform(request)
        guard var saved = config else { return }
        saved.username = me.data.username; try persist(saved)
        username = me.data.username; followers = me.data.public_metrics?.followers_count
        message = "X conectado como @\(username)."
        // Recent posts with public metrics; plans without read access just leave the list empty.
        var timeline = URLRequest(url: URL(string: "https://api.x.com/2/users/\(me.data.id)/tweets?max_results=10&tweet.fields=public_metrics,created_at&exclude=replies,retweets")!)
        timeline.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let list: TweetList = try? await perform(timeline) { recent = list.data ?? [] }
    }
    private func accessToken() async throws -> String {
        guard var saved = config, !saved.accessToken.isEmpty else { throw AppIssue("Conecte a conta do X antes de continuar.") }
        if saved.expires > Date().addingTimeInterval(60) { return saved.accessToken }
        guard !saved.refreshToken.isEmpty else { throw AppIssue("A autorização do X expirou. Autorize novamente.") }
        let token = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": saved.refreshToken], config: saved)
        apply(token, to: &saved); try persist(saved)
        return saved.accessToken
    }
    private func apply(_ token: Token, to saved: inout Config) {
        saved.accessToken = token.access_token
        if let refresh = token.refresh_token { saved.refreshToken = refresh }
        saved.expires = Date().addingTimeInterval(Double(token.expires_in ?? 7200))
    }
    private func tokenRequest(_ values: [String: String], config: Config) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authorizeClient(&request, config: config)
        var all = values; all["client_id"] = config.clientID
        request.httpBody = TikTokProtocol.form(all)
        return try await perform(request)
    }
    /// Confidential clients authenticate with HTTP Basic; public (native) clients send only client_id.
    private func authorizeClient(_ request: inout URLRequest, config: Config) {
        guard !config.clientSecret.isEmpty else { return }
        let credentials = Data("\(config.clientID):\(config.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    }
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (json?["detail"] as? String) ?? (json?["error_description"] as? String) ?? (json?["title"] as? String) ?? "HTTP \(status)"
            throw AppIssue("O X recusou a operação: \(detail).\(status == 403 ? " Confira o nível de acesso do app e as permissões de escrita." : "")")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw AppIssue("O X retornou uma resposta inesperada.") }
    }
    private func persist(_ saved: Config) throws { try vault.write(JSONEncoder().encode(saved)); config = saved; configured = true }
}
