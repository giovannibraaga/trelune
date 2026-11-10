import SwiftUI
import AppKit
import Network
import CryptoKit
import Security
import AVFoundation

// Google desktop OAuth uses the external browser, PKCE and a loopback callback.
@MainActor final class YouTubeConnection: ObservableObject {
    @Published private(set) var channel = ""
    @Published private(set) var totalViews: Int64 = 0
    @Published private(set) var subscribers: Int64 = 0
    @Published private(set) var videoCount: Int64 = 0
    @Published private(set) var configured = false
    @Published private(set) var loadingConfiguration = true
    @Published private(set) var busy = false
    @Published var message = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var dailyViews: [DailyValue] = []
    /// Daily analytics for the last 180 days (views, likes, comments, subscribers gained).
    @Published private(set) var days: [YouTubeDay] = []
    @Published private(set) var recentVideos: [YouTubeVideo] = []
    @Published private(set) var analyticsNote = ""
    private var credentials: Credentials?
    private var callback: LoopbackCallback?

    struct Credentials: Codable {
        var clientID: String
        var clientSecret: String
        var accessToken = ""
        var refreshToken = ""
        var expires = Date.distantPast
        var channel = ""
    }
    private struct ClientFile: Decodable {
        struct Installed: Decodable { let client_id: String; let client_secret: String? }
        let installed: Installed?
    }
    private struct Token: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }
    private struct ChannelResponse: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable { let title: String }
            struct Statistics: Decodable { let viewCount: String?; let subscriberCount: String?; let videoCount: String? }
            let id: String
            let snippet: Snippet
            let statistics: Statistics?
        }
        let items: [Item]
    }
    private struct UploadInit: Decodable { let id: String? }
    init() {
        Task {
            defer { loadingConfiguration = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try CredentialVault.read() }.value
                if let data {
                    let saved = try JSONDecoder().decode(Credentials.self, from: data)
                    credentials = saved; configured = true; channel = saved.channel
                }
            } catch { message = error.localizedDescription }
        }
    }
    /// Re-reads the Keychain after the cloud refreshed the credentials.
    func reloadCredentials() async {
        guard let data = try? await Task.detached(priority: .userInitiated, operation: { try CredentialVault.read() }).value, let saved = try? JSONDecoder().decode(Credentials.self, from: data) else { return }
        credentials = saved; configured = true; channel = saved.channel
    }
    func importConfiguration() {
        guard !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.message = "Selecione o JSON do cliente OAuth do tipo Aplicativo para computador."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let config = try JSONDecoder().decode(ClientFile.self, from: Data(contentsOf: url))
            guard let installed = config.installed, installed.client_id.hasSuffix(".apps.googleusercontent.com") else {
                throw ConnectionError.message("Use um cliente OAuth do tipo Aplicativo para computador, baixado no Google Cloud.")
            }
            let new = Credentials(clientID: installed.client_id, clientSecret: installed.client_secret ?? "")
            try persist(new)
            configured = true; channel = ""; message = "Credenciais importadas. Agora clique em Autorizar YouTube."
        } catch { message = error.localizedDescription }
    }
    func connect() async {
        guard var config = credentials, !busy else { return }
        busy = true; message = "Aguardando autorização no navegador…"
        defer { callback?.cancel(); callback = nil; busy = false }
        do {
            let verifier = try Self.random()
            let state = try Self.random()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            let receiver = LoopbackCallback(state: state)
            callback = receiver
            let redirect = try await receiver.start()
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = ["client_id": config.clientID, "redirect_uri": redirect, "response_type": "code", "scope": "https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/yt-analytics.readonly", "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"].map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let authorizationURL = url.url, NSWorkspace.shared.open(authorizationURL) else { throw ConnectionError.message("Não foi possível abrir o navegador.") }
            let code = try await receiver.code()
            let token = try await tokenRequest(["code": code, "client_id": config.clientID, "client_secret": config.clientSecret, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier])
            config.accessToken = token.access_token
            config.refreshToken = token.refresh_token ?? ""
            config.expires = Date().addingTimeInterval(Double(token.expires_in))
            // Save authorized tokens before fetching the channel so a transient API failure is recoverable.
            try persist(config)
            try await loadChannel()
        } catch { message = error.localizedDescription }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await loadChannel() } catch { message = error.localizedDescription }
    }
    func cancel() { callback?.cancel() }
    func disconnect() async {
        guard let config = credentials, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let token = config.refreshToken.isEmpty ? config.accessToken : config.refreshToken
            if !token.isEmpty {
                var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.form(["token": token])
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 400 else { throw ConnectionError.message("Não foi possível revogar o acesso. Tente novamente.") }
            }
            try CredentialVault.delete()
            credentials = nil; channel = ""; totalViews = 0; subscribers = 0; videoCount = 0; dailyViews = []; days = []; recentVideos = []; configured = false; message = "Acesso revogado e credenciais locais removidas."
        } catch { message = error.localizedDescription }
    }
    private func loadChannel() async throws {
        guard var config = credentials else { throw ConnectionError.message("Importe as credenciais do Google Cloud.") }
        if config.expires < Date().addingTimeInterval(30) {
            guard !config.refreshToken.isEmpty else { throw ConnectionError.message("Autorize o YouTube para continuar.") }
            let token = try await tokenRequest(["client_id": config.clientID, "client_secret": config.clientSecret, "grant_type": "refresh_token", "refresh_token": config.refreshToken])
            config.accessToken = token.access_token; config.expires = Date().addingTimeInterval(Double(token.expires_in))
            try persist(config)
        }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics&mine=true")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(config.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.message("Não foi possível consultar o canal. Verifique se a YouTube Data API v3 está ativada e autorize novamente se o acesso expirou.") }
        let result = try JSONDecoder().decode(ChannelResponse.self, from: data)
        guard let item = result.items.first else { throw ConnectionError.message("A conta autorizada não possui um canal do YouTube.") }
        config.channel = item.snippet.title; try persist(config)
        channel = config.channel; totalViews = Int64(item.statistics?.viewCount ?? "0") ?? 0; subscribers = Int64(item.statistics?.subscriberCount ?? "0") ?? 0; videoCount = Int64(item.statistics?.videoCount ?? "0") ?? 0
        message = "Canal conectado. Dados públicos do canal atualizados."
        await loadDailyViews(token: config.accessToken)
        await loadRecentVideos(token: config.accessToken)
    }

    /// Daily analytics from the YouTube Analytics API. Requires the yt-analytics.readonly scope and the API enabled in Google Cloud.
    private func loadDailyViews(token: String) async {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let end = Date(), start = calendar.date(byAdding: .day, value: -179, to: end)!
        var url = URLComponents(string: "https://youtubeanalytics.googleapis.com/v2/reports")!
        url.queryItems = [URLQueryItem(name: "ids", value: "channel==MINE"), URLQueryItem(name: "startDate", value: formatter.string(from: start)), URLQueryItem(name: "endDate", value: formatter.string(from: end)), URLQueryItem(name: "metrics", value: "views,likes,comments,subscribersGained,subscribersLost"), URLQueryItem(name: "dimensions", value: "day"), URLQueryItem(name: "sort", value: "day")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                let reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (error?["status"] as? String) ?? ""
                let detail = error?["message"] as? String ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                if reason == "accessNotConfigured" || detail.contains("has not been used") || detail.contains("is disabled") {
                    analyticsNote = "Ative a YouTube Analytics API no projeto do Google Cloud para ver visualizações diárias."
                } else if reason == "insufficientPermissions" || reason == "PERMISSION_DENIED" || detail.localizedCaseInsensitiveContains("scope") || (response as? HTTPURLResponse)?.statusCode == 403 {
                    analyticsNote = "Autorize o YouTube de novo (Conexões → YouTube → Autorizar novamente) para liberar o acesso ao Analytics."
                } else {
                    analyticsNote = "YouTube Analytics indisponível: \(detail)"
                }
                return
            }
            let rows = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["rows"] as? [[Any]]) ?? []
            func int(_ value: Any) -> Int { (value as? NSNumber)?.intValue ?? 0 }
            days = rows.compactMap { row in
                guard row.count >= 6, let day = row[0] as? String, let date = formatter.date(from: day) else { return nil }
                return YouTubeDay(date: date, views: int(row[1]), likes: int(row[2]), comments: int(row[3]), subscribers: int(row[4]) - int(row[5]))
            }
            dailyViews = days.map { DailyValue(date: $0.date, value: $0.views) }
            analyticsNote = days.isEmpty ? "O YouTube ainda não tem dados diários para este período." : ""
        } catch { analyticsNote = "Histórico diário indisponível: \(error.localizedDescription)" }
    }

    /// Latest uploads with their statistics.
    private func loadRecentVideos(token: String) async {
        func get(_ url: String) async -> [String: Any]? {
            var request = URLRequest(url: URL(string: url)!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let channel = await get("https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true"),
              let uploads = (((channel["items"] as? [[String: Any]])?.first?["contentDetails"] as? [String: Any])?["relatedPlaylists"] as? [String: Any])?["uploads"] as? String,
              let playlist = await get("https://www.googleapis.com/youtube/v3/playlistItems?part=contentDetails&maxResults=12&playlistId=\(uploads)") else { return }
        let ids = ((playlist["items"] as? [[String: Any]]) ?? []).compactMap { ($0["contentDetails"] as? [String: Any])?["videoId"] as? String }
        guard !ids.isEmpty, let videos = await get("https://www.googleapis.com/youtube/v3/videos?part=snippet,statistics&id=\(ids.joined(separator: ","))") else { return }
        let iso = ISO8601DateFormatter()
        recentVideos = ((videos["items"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String, let snippet = item["snippet"] as? [String: Any] else { return nil }
            let stats = item["statistics"] as? [String: Any] ?? [:]
            let thumbs = snippet["thumbnails"] as? [String: Any] ?? [:]
            let thumb = ((thumbs["medium"] ?? thumbs["default"]) as? [String: Any])?["url"] as? String
            func n(_ key: String) -> Int { Int(stats[key] as? String ?? "") ?? 0 }
            return YouTubeVideo(id: id, title: snippet["title"] as? String ?? "", thumbnail: thumb, published: iso.date(from: snippet["publishedAt"] as? String ?? ""), views: n("viewCount"), likes: n("likeCount"), comments: n("commentCount"))
        }
    }

    func uploadVideo(_ file: URL, title: String, description: String, privacy: String) async {
        do { _ = try await publishVideo(file, title: title, description: description, privacy: privacy) } catch { message = error.localizedDescription }
    }
    /// Uploads a video and returns the YouTube video ID.
    func publishVideo(_ file: URL, title: String, description: String, privacy: String, tags: [String] = [], thumbnail: String? = nil) async throws -> String {
        guard !busy else { throw ConnectionError.message("O YouTube está ocupado com outra operação.") }
        busy = true; progress = 0
        defer { busy = false }
        let scoped = file.startAccessingSecurityScopedResource(); defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            guard let ext = ["mp4", "mov", "m4v"].first(where: { $0 == file.pathExtension.lowercased() }) else { throw ConnectionError.message("Escolha um vídeo MP4 ou MOV para publicar no YouTube.") }
            _ = ext
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw ConnectionError.message("Não foi possível ler o vídeo selecionado.") }
            guard title.utf16.count <= 100 else { throw ConnectionError.message("O título do YouTube pode ter até 100 caracteres.") }
            try await ensureFreshToken()
            guard let config = credentials else { throw ConnectionError.message("Conecte o YouTube antes de publicar.") }
            let access = config.accessToken
            var snippet: [String: Any] = ["title": title, "description": description]
            if !tags.isEmpty { snippet["tags"] = tags }
            let meta: [String: Any] = ["snippet": snippet, "status": ["privacyStatus": privacy, "selfDeclaredMadeForKids": false]]
            let body = try JSONSerialization.data(withJSONObject: meta)
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
            request.httpMethod = "POST"; request.timeoutInterval = 60; request.httpBody = body
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization"); request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length"); request.setValue("video/\(ext == "mov" ? "quicktime" : "mp4")", forHTTPHeaderField: "X-Upload-Content-Type")
            let (_, initResponse) = try await URLSession.shared.data(for: request)
            guard let http = initResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location), uploadURL.scheme == "https", uploadURL.host == "www.googleapis.com" else { throw ConnectionError.message("O YouTube não iniciou o envio. Confirme a permissão de upload e a cota diária do canal.") }
            var upload = URLRequest(url: uploadURL); upload.httpMethod = "PUT"; upload.timeoutInterval = 3600; upload.setValue("video/\(ext == "mov" ? "quicktime" : "mp4")", forHTTPHeaderField: "Content-Type")
            upload.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.upload(for: upload, fromFile: file)
            guard let result = response as? HTTPURLResponse, result.statusCode == 200 || result.statusCode == 201 else { throw ConnectionError.message("O YouTube não concluiu o envio. Confira o formato e tente novamente.") }
            let videoID = (try? JSONDecoder().decode(UploadInit.self, from: data))?.id ?? ""
            progress = 1
            if let thumbnail, !videoID.isEmpty { thumbnailNote = await setThumbnail(videoID: videoID, image: thumbnail, token: access) }
            message = "Vídeo enviado ao YouTube como \(privacy == "public" ? "público" : privacy == "unlisted" ? "não listado" : "privado")."
            try? await loadChannel()
            return videoID
        }
    }
    /// Result of the last custom thumbnail attempt (custom thumbnails require a verified channel).
    private(set) var thumbnailNote = ""
    private func setThumbnail(videoID: String, image: String, token: String) async -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: image)), data.count <= 2_000_000 else { return "Miniatura não enviada: use uma imagem JPG/PNG de até 2 MB." }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=\(videoID)&uploadType=media")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120; request.httpBody = data
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue(MediaKind.mime(image), forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return "O vídeo foi enviado, mas o YouTube recusou a miniatura (o canal precisa estar verificado para miniaturas personalizadas)." }
        return "Miniatura personalizada aplicada."
    }
    private func ensureFreshToken() async throws {
        guard var config = credentials else { throw ConnectionError.message("Importe as credenciais do Google Cloud.") }
        if config.expires < Date().addingTimeInterval(30) {
            guard !config.refreshToken.isEmpty else { throw ConnectionError.message("A autorização expirou. Autorize novamente.") }
            let token = try await tokenRequest(["client_id": config.clientID, "client_secret": config.clientSecret, "grant_type": "refresh_token", "refresh_token": config.refreshToken])
            config.accessToken = token.access_token; config.expires = Date().addingTimeInterval(Double(token.expires_in)); try persist(config)
        }
    }
    private func tokenRequest(_ values: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(values)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.message("A autorização não foi concluída. Confirme o cliente Desktop, o usuário de teste e tente novamente.") }
        return try JSONDecoder().decode(Token.self, from: data)
    }
    private func persist(_ config: Credentials) throws { try CredentialVault.write(JSONEncoder().encode(config)); credentials = config }
    private static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ConnectionError.message("Não foi possível iniciar uma autorização segura.") }
        return Data(bytes).base64URL
    }
}

struct DailyValue: Identifiable, Hashable { var date: Date; var value: Int; var id: Date { date } }
struct YouTubeDay: Hashable { var date: Date; var views: Int; var likes: Int; var comments: Int; var subscribers: Int }
struct YouTubeVideo: Identifiable, Hashable { var id: String; var title: String; var thumbnail: String?; var published: Date?; var views: Int; var likes: Int; var comments: Int }

enum ConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
private extension Data { var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }

private enum CredentialVault {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.keychainService("youtube"), kSecAttrAccount as String: "oauth"] }
    static func read() throws -> Data? {
        var query = query; query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ConnectionError.message("Não foi possível ler as credenciais no Chaves do macOS.") }
        return item as? Data
    }
    static func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.message("Não foi possível salvar as credenciais no Chaves do macOS.") }
        } else if status != errSecSuccess { throw ConnectionError.message("Não foi possível atualizar as credenciais no Chaves do macOS.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionError.message("Não foi possível remover as credenciais locais.") }
    }
}

@MainActor final class LoopbackCallback {
    private let state: String
    private let fixedPort: UInt16?
    private let hostName: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<String, Error>?
    private var pending: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: Task<Void, Never>?
    /// `hostName` "localhost" listens on every loopback address (IPv4 and IPv6), as browsers may resolve localhost to ::1.
    init(state: String, fixedPort: UInt16? = nil, hostName: String = "127.0.0.1") { self.state = state; self.fixedPort = fixedPort; self.hostName = hostName }
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        let port = fixedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        let listener: NWListener
        if hostName == "localhost" {
            parameters.requiredInterfaceType = .loopback
            parameters.acceptLocalOnly = true
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] status in Task { @MainActor in
            guard let self else { return }
            switch status {
            case .ready:
                if let port = self.listener?.port { self.ready?.resume(returning: "http://\(self.hostName):\(port.rawValue)/oauth/callback"); self.ready = nil }
            case .failed: self.finish(.failure(ConnectionError.message("Não foi possível abrir o retorno local da autorização.")))
            default: break
            }
        } }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection) } }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish(.failure(ConnectionError.message("O tempo de autorização expirou. Tente novamente.")))
        }
        return try await withCheckedThrowingContinuation { continuation in ready = continuation; listener.start(queue: .main) }
    }
    func code() async throws -> String { if let result { return try result.get() }; return try await withCheckedThrowingContinuation { pending = $0 } }
    func cancel() { finish(.failure(ConnectionError.message("Autorização cancelada."))) }
    private func finish(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value; timeout?.cancel(); timeout = nil
        if let ready { ready.resume(throwing: ConnectionError.message("Autorização interrompida.")); self.ready = nil }
        pending?.resume(with: value); pending = nil; listener?.cancel(); listener = nil
    }
    private func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in Task { @MainActor in
            guard let self else { connection.cancel(); return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 16384 else { connection.cancel(); return }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                let path = request.components(separatedBy: " ").dropFirst().first ?? ""
                let components = URLComponents(string: "http://localhost" + path)
                let items = components?.queryItems ?? []
                let returnedState = items.first { $0.name == "state" }?.value
                guard request.hasPrefix("GET "), components?.path == "/oauth/callback", returnedState == self.state else { self.respond(connection, status: "400 Bad Request", body: "Retorno de autorizacao invalido."); return }
                if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                    self.respond(connection, status: "200 OK", body: "Autorizacao recebida. Volte ao Trelune para confirmar a conexao.")
                    self.finish(.success(code))
                } else {
                    self.respond(connection, status: "200 OK", body: "Autorizacao recusada. Volte ao Trelune.")
                    self.finish(.failure(ConnectionError.message("A autorização foi recusada.")))
                }
            } else if complete || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
        } }
    }
    private func respond(_ connection: NWConnection, status: String, body: String) {
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
