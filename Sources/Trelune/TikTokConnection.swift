import SwiftUI
import AppKit
import CryptoKit
import Security
import AVFoundation

struct TikTokFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// TikTok desktop PKCE intentionally uses a HEX digest, unlike Google's base64url digest.
enum TikTokProtocol {
    static func challenge(_ verifier: String) -> String {
        SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    struct Chunk: Equatable { let offset: Int64; let size: Int64 }
    static func chunks(size: Int64) throws -> [Chunk] {
        guard size > 0, size <= 4_000_000_000 else { throw TikTokFailure(message: "O vídeo precisa ter entre 1 byte e 4 GB.") }
        let base: Int64 = 10_000_000
        let count = max(1, size / base)
        return (0..<count).map { index in Chunk(offset: index * base, size: index == count - 1 ? size - index * base : base) }
    }
}

@MainActor final class TikTokConnection: ObservableObject {
    struct Configuration: Codable {
        var key: String
        var secret: String
        var token = ""
        var refresh = ""
        var expires = Date.distantPast
        var refreshExpires = Date.distantPast
        var openID = ""
        var scope = ""
        var displayName = ""
    }
    struct Token: Decodable, Sendable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
        let refresh_expires_in: Int
        let open_id: String
        let scope: String
    }
    struct ErrorEnvelope: Decodable { struct APIError: Decodable { let code: String }; let error: APIError }
    struct Envelope<T: Decodable>: Decodable {
        struct APIError: Decodable { let code: String; let message: String? }
        let data: T?
        let error: APIError
    }
    struct Profile: Decodable {
        struct User: Decodable { let open_id: String; let display_name: String }
        let user: User
    }
    struct Creator: Decodable {
        let creator_username: String
        let creator_nickname: String
        let creator_avatar_url: String?
        let privacy_level_options: [String]
        let comment_disabled: Bool
        let duet_disabled: Bool
        let stitch_disabled: Bool
        let max_video_post_duration_sec: Int
    }
    struct InitResponse: Decodable { let publish_id: String; let upload_url: String }
    struct Status: Decodable { let status: String; let fail_reason: String? }
    struct Delivery: Codable, Identifiable {
        var id: String
        var owner: String
        var title: String
        var status: String
        var created = Date()
        var detail = ""
    }
    struct DirectOptions {
        var title: String
        var privacy: String
        var disableComment: Bool
        var disableDuet: Bool
        var disableStitch: Bool
        var ownBrand: Bool
        var paidBrand: Bool
        var aiGenerated: Bool
        var coverMs: Int? = nil
    }
    struct Stats: Decodable { let follower_count: Int?; let likes_count: Int?; let video_count: Int?; let avatar_url: String? }
    struct Video: Decodable, Identifiable { let id: String; let title: String?; let video_description: String?; let cover_image_url: String?; let share_url: String?; let view_count: Int?; let like_count: Int?; let comment_count: Int?; let share_count: Int?; let create_time: Int? }
    private struct VideoList: Decodable { let videos: [Video]? }
    private struct PublishID: Decodable { let publish_id: String }
    @Published private(set) var configured = false
    @Published private(set) var loadingConfiguration = true
    @Published private(set) var displayName = ""
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var deliveries: [Delivery] = []
    @Published var message = ""
    @Published private(set) var stats: Stats?
    @Published private(set) var videos: [Video] = []
    var canReadStats: Bool { scopes.contains("user.info.stats") }
    var canListVideos: Bool { scopes.contains("video.list") }
    private var configuration: Configuration?
    private var callback: LoopbackCallback?
    private var operation: Task<Void, Never>?
    private var refreshOperation: Task<Token, Error>?
    private let session: URLSession
    private let vault = TikTokVault()
    var canUpload: Bool { scopes.contains("video.upload") }
    var canPublish: Bool { scopes.contains("video.publish") }
    var connected: Bool { configuration?.token.isEmpty == false }
    private var scopes: Set<String> { Set((configuration?.scope ?? "").split(separator: ",").map(String.init)) }
    init(session: URLSession = .shared) {
        self.session = session
        Task {
            defer { loadingConfiguration = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try TikTokVault().read() }.value
                if let data {
                    let saved = try JSONDecoder().decode(Configuration.self, from: data)
                    configuration = saved; configured = true; displayName = saved.displayName
                }
            } catch { message = error.localizedDescription }
        }
        if let data = UserDefaults.standard.data(forKey: "tiktokDeliveries"), let items = try? JSONDecoder().decode([Delivery].self, from: data) { deliveries = items }
    }
    /// Re-reads the Keychain after the cloud refreshed the credentials.
    func reloadCredentials() async {
        guard let data = try? await Task.detached(priority: .userInitiated, operation: { try TikTokVault().read() }).value, let saved = try? JSONDecoder().decode(Configuration.self, from: data) else { return }
        configuration = saved; configured = true; displayName = saved.displayName
    }
    func configure(key: String, secret: String) throws {
        guard !busy else { throw TikTokFailure(message: "Aguarde a operação atual.") }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else { throw TikTokFailure(message: "Preencha o Client key e o Client secret do sandbox.") }
        if key == configuration?.key && secret == configuration?.secret { return }
        guard !connected else { throw TikTokFailure(message: "Desconecte a conta antes de trocar as credenciais.") }
        try save(Configuration(key: key, secret: secret))
        displayName = ""; message = "Credenciais salvas no Chaves do macOS. Autorize sua conta de teste."
    }
    func connect(direct: Bool, metrics: Bool = false) {
        guard configured, !busy else { return }
        busy = true; message = metrics ? "Aguardando autorização no Chrome… Se o TikTok mostrar erro “scope”, cancele, desmarque “Ler métricas” e tente de novo." : "Aguardando autorização no Chrome…"
        operation = Task {
            defer { callback?.cancel(); callback = nil; busy = false; operation = nil }
            do {
                let verifier = try Self.random()
                let state = try Self.random()
                let receiver = LoopbackCallback(state: state); callback = receiver
                let redirect = try await receiver.start()
                guard let config = configuration else { throw TikTokFailure(message: "Configure as credenciais.") }
                let requested = (direct ? "user.info.basic,video.upload,video.publish" : "user.info.basic,video.upload") + (metrics ? ",user.info.stats,video.list" : "")
                var url = URLComponents(string: "https://www.tiktok.com/v2/auth/authorize/")!
                url.queryItems = ["client_key": config.key, "scope": requested, "redirect_uri": redirect, "state": state, "response_type": "code", "code_challenge": TikTokProtocol.challenge(verifier), "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = url.url else { throw TikTokFailure(message: "Não foi possível preparar a autorização.") }
                try await openChrome(url)
                let code = try await receiver.code()
                try Task.checkCancellation()
                let token = try await tokenRequest(["code": code, "grant_type": "authorization_code", "redirect_uri": redirect, "code_verifier": verifier])
                try apply(token)
                try await loadProfile()
            } catch { message = error is CancellationError ? "Operação cancelada." : error.localizedDescription }
        }
    }
    func cancel() { callback?.cancel(); operation?.cancel() }
    func refreshProfile() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await loadProfile() } catch { message = error.localizedDescription }
    }
    private func loadProfile() async throws {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let profile: Profile = try await decode(request)
        guard var config = configuration, profile.user.open_id == config.openID else { throw TikTokFailure(message: "A conta retornada não corresponde à autorização.") }
        config.displayName = profile.user.display_name; try save(config); displayName = config.displayName
        message = canUpload ? "TikTok conectado. Você já pode enviar vídeos para finalizar no TikTok." : "Conta conectada, mas o envio de vídeos não foi autorizado. Reconecte e permita video.upload."
        try? await loadMetrics()
    }
    /// Follower/like counts and recent videos; available only when user.info.stats / video.list were authorized.
    private func loadMetrics() async throws {
        if canReadStats {
            var request = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/user/info/?fields=open_id,follower_count,likes_count,video_count,avatar_url")!)
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            struct Wrapper: Decodable { let user: Stats }
            stats = (try await decode(request) as Wrapper).user
        }
        if canListVideos {
            let token = try await accessToken()
            var request = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/video/list/?fields=id,title,video_description,cover_image_url,share_url,view_count,like_count,comment_count,share_count,create_time")!)
            request.httpMethod = "POST"; request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["max_count": 20])
            videos = (try await decode(request) as VideoList).videos ?? []
        }
    }

    /// Scheduler entry for videos: inbox draft, or Direct Post with the given options.
    func sendVideo(_ url: URL, title: String, direct: DirectOptions?) async throws -> (id: String, status: String) {
        guard !busy else { throw TikTokFailure(message: "O TikTok está ocupado com outra operação.") }
        busy = true; progress = 0; message = "Validando o vídeo…"
        defer { busy = false }
        return try await performUpload(url, title: title, direct: direct)
    }

    /// Photo post (1–35 public image URLs from a verified domain). privacy == nil sends to the inbox as a draft.
    func sendPhotos(_ urls: [String], title: String, description: String, privacy: String?, allowComments: Bool, coverIndex: Int) async throws -> (id: String, status: String) {
        guard !busy else { throw TikTokFailure(message: "O TikTok está ocupado com outra operação.") }
        busy = true; defer { busy = false }
        guard (1...35).contains(urls.count) else { throw TikTokFailure(message: "Posts de fotos no TikTok aceitam de 1 a 35 imagens.") }
        guard privacy == nil ? canUpload : canPublish else { throw TikTokFailure(message: "A conta não autorizou a permissão necessária para este envio.") }
        var postInfo: [String: Any] = ["title": String(title.prefix(90)), "description": String(description.prefix(4000)), "disable_comment": !allowComments, "auto_add_music": true]
        if let privacy {
            let info = try await creator()
            guard info.privacy_level_options.contains(privacy) else { throw TikTokFailure(message: "A privacidade escolhida não está disponível para esta conta (\(info.privacy_level_options.joined(separator: ", "))).") }
            postInfo["privacy_level"] = privacy
        }
        let body: [String: Any] = ["post_info": postInfo, "source_info": ["source": "PULL_FROM_URL", "photo_cover_index": min(max(coverIndex, 0), urls.count - 1), "photo_images": urls], "post_mode": privacy == nil ? "MEDIA_UPLOAD" : "DIRECT_POST", "media_type": "PHOTO"]
        let started: PublishID = try await api("post/publish/content/init/", body: body)
        deliveries.insert(Delivery(id: started.publish_id, owner: configuration?.openID ?? "", title: title, status: "PROCESSING_DOWNLOAD"), at: 0); persistDeliveries()
        for _ in 0..<30 {
            let status = try await fetchStatus(started.publish_id)
            if status.status == "FAILED" { throw TikTokFailure(message: "O TikTok recusou as fotos: \(status.fail_reason ?? "motivo não informado"). Verifique se o domínio das imagens está verificado no portal do TikTok.") }
            if ["SEND_TO_USER_INBOX", "PUBLISH_COMPLETE"].contains(status.status) { return (started.publish_id, status.status) }
            try await Task.sleep(for: .seconds(4))
        }
        return (started.publish_id, "PROCESSING")
    }
    func creator() async throws -> Creator {
        guard canPublish else { throw TikTokFailure(message: "A publicação direta exige a permissão video.publish. Ative Direct Post no portal e autorize novamente.") }
        return try await api("post/publish/creator_info/query/", body: [:])
    }
    func uploadVideo(_ url: URL, title: String, direct: DirectOptions? = nil) {
        guard !busy else { return }
        busy = true; progress = 0; message = "Validando o vídeo…"
        operation = Task {
            defer { busy = false; operation = nil }
            _ = try? await performUpload(url, title: title, direct: direct)
        }
    }
    /// Used by the scheduler: sends a video to the creator's TikTok inbox and waits for the processing result.
    func sendToInbox(_ url: URL, title: String) async throws -> (id: String, status: String) {
        guard !busy else { throw TikTokFailure(message: "O TikTok está ocupado com outra operação.") }
        busy = true; progress = 0; message = "Validando o vídeo…"
        defer { busy = false }
        return try await performUpload(url, title: title, direct: nil)
    }
    private func performUpload(_ url: URL, title: String, direct: DirectOptions?) async throws -> (id: String, status: String) {
            var deliveryID: String?
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard direct == nil ? canUpload : canPublish else { throw TikTokFailure(message: "A conta não autorizou a permissão necessária para este envio.") }
                let ext = url.pathExtension.lowercased()
                guard ["mp4", "mov", "webm"].contains(ext) else { throw TikTokFailure(message: "Selecione um vídeo MP4, MOV ou WebM.") }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize else { throw TikTokFailure(message: "Não foi possível ler o vídeo selecionado.") }
                let chunks = try TikTokProtocol.chunks(size: Int64(size))
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let limit: Int
                if let direct {
                    let info = try await creator()
                    guard info.privacy_level_options.contains(direct.privacy) else { throw TikTokFailure(message: "A privacidade escolhida não está disponível. Atualize as opções antes de enviar.") }
                    guard direct.title.utf16.count <= 2200 else { throw TikTokFailure(message: "A legenda deve ter até 2.200 caracteres.") }
                    guard !(direct.paidBrand && direct.privacy == "SELF_ONLY") else { throw TikTokFailure(message: "Conteúdo de parceria paga não pode ser privado.") }
                    limit = info.max_video_post_duration_sec
                } else { limit = 600 }
                guard duration.isFinite, duration > 0, duration <= Double(limit) else { throw TikTokFailure(message: "O vídeo excede a duração permitida de \(limit) segundos ou não pôde ser lido.") }
                var body: [String: Any] = ["source_info": ["source": "FILE_UPLOAD", "video_size": size, "chunk_size": chunks[0].size, "total_chunk_count": chunks.count]]
                if let direct {
                    var info: [String: Any] = ["title": direct.title, "privacy_level": direct.privacy, "disable_comment": direct.disableComment, "disable_duet": direct.disableDuet, "disable_stitch": direct.disableStitch, "brand_content_toggle": direct.paidBrand, "brand_organic_toggle": direct.ownBrand, "is_aigc": direct.aiGenerated]
                if let cover = direct.coverMs { info["video_cover_timestamp_ms"] = cover }
                body["post_info"] = info
                }
                let initialized: InitResponse = try await api(direct == nil ? "post/publish/inbox/video/init/" : "post/publish/video/init/", body: body)
                deliveryID = initialized.publish_id
                deliveries.insert(Delivery(id: initialized.publish_id, owner: configuration?.openID ?? "", title: title, status: "PROCESSING_UPLOAD"), at: 0); persistDeliveries()
                guard let uploadURL = URL(string: initialized.upload_url), uploadURL.scheme == "https", let host = uploadURL.host, host == "tiktokapis.com" || host.hasSuffix(".tiktokapis.com") else { throw TikTokFailure(message: "A API retornou um destino de upload inválido.") }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let mime = ext == "mov" ? "video/quicktime" : ext == "webm" ? "video/webm" : "video/mp4"
                for chunk in chunks {
                    try Task.checkCancellation()
                    try handle.seek(toOffset: UInt64(chunk.offset))
                    guard let bytes = try handle.read(upToCount: Int(chunk.size)), bytes.count == chunk.size else { throw TikTokFailure(message: "O arquivo foi alterado ou não pôde ser lido por completo.") }
                    var request = URLRequest(url: uploadURL)
                    request.httpMethod = "PUT"; request.timeoutInterval = 180
                    request.setValue(mime, forHTTPHeaderField: "Content-Type")
                    request.setValue(String(chunk.size), forHTTPHeaderField: "Content-Length")
                    request.setValue("bytes \(chunk.offset)-\(chunk.offset + chunk.size - 1)/\(size)", forHTTPHeaderField: "Content-Range")
                    message = "Enviando vídeo…"
                    let (_, response) = try await session.upload(for: request, from: bytes)
                    let expectedStatus = chunk.offset + chunk.size == size ? 201 : 206
                    guard (response as? HTTPURLResponse)?.statusCode == expectedStatus else { throw TikTokFailure(message: "O TikTok interrompeu o upload. Consulte o status antes de iniciar outro envio.") }
                    progress = Double(chunk.offset + chunk.size) / Double(size)
                }
                message = "Vídeo enviado. Aguardando processamento do TikTok…"
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    let status = try await fetchStatus(initialized.publish_id)
                    if status.status == "FAILED" { throw TikTokFailure(message: "O TikTok recusou o envio: \(status.fail_reason ?? "motivo não informado").") }
                    if ["SEND_TO_USER_INBOX", "PUBLISH_COMPLETE"].contains(status.status) { return (initialized.publish_id, status.status) }
                    try await Task.sleep(for: .seconds(4))
                }
                message = "O TikTok ainda está processando o vídeo. Use Atualizar status para consultar novamente."
                return (initialized.publish_id, "PROCESSING")
            } catch {
                message = error is CancellationError ? "Envio interrompido. Consulte o status para verificar se o TikTok recebeu o conteúdo." : error.localizedDescription
                if let id = deliveryID { setDetail(id, message) }
                throw error
            }
    }
    /// Current publish status of an upload (SEND_TO_USER_INBOX, PUBLISH_COMPLETE, FAILED…).
    func publishStatus(_ id: String) async throws -> (status: String, reason: String?) {
        let status: Status = try await api("post/publish/status/fetch/", body: ["publish_id": id])
        return (status.status, status.fail_reason)
    }
    func checkStatus(_ delivery: Delivery) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { guard delivery.owner == configuration?.openID else { throw TikTokFailure(message: "Conecte a conta que realizou este envio.") }; _ = try await fetchStatus(delivery.id) } catch { message = error.localizedDescription }
    }
    @discardableResult private func fetchStatus(_ id: String) async throws -> Status {
        let status: Status = try await api("post/publish/status/fetch/", body: ["publish_id": id])
        if let index = deliveries.firstIndex(where: { $0.id == id }) {
            deliveries[index].status = status.status; deliveries[index].detail = status.fail_reason ?? ""; persistDeliveries()
        }
        switch status.status {
        case "SEND_TO_USER_INBOX": message = "Vídeo entregue à sua caixa de entrada no TikTok. Abra a notificação no TikTok para revisar e concluir a publicação."
        case "PUBLISH_COMPLETE": message = "O TikTok confirmou que a publicação foi concluída."
        case "FAILED": message = "O TikTok recusou o envio: \(status.fail_reason ?? "motivo não informado")."
        default: break
        }
        return status
    }
    func disconnect() async {
        guard let config = configuration, !busy else { return }; busy = true; defer { busy = false }
        do {
            if !config.token.isEmpty {
                var request = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/oauth/revoke/")!)
                request.httpMethod = "POST"; request.timeoutInterval = 30
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = TikTokProtocol.form(["client_key": config.key, "client_secret": config.secret, "token": config.token])
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] == nil else { throw TikTokFailure(message: "A revogação não foi confirmada. Tente novamente.") }
            }
            try vault.delete(); configuration = nil; configured = false; displayName = ""; stats = nil; videos = []; message = "Acesso revogado e credenciais removidas deste Mac."
        } catch { message = error.localizedDescription }
    }
    private func accessToken() async throws -> String {
        guard let config = configuration, !config.token.isEmpty else { throw TikTokFailure(message: "Conecte sua conta TikTok antes de enviar.") }
        if config.expires > Date().addingTimeInterval(60) { return config.token }
        guard config.refreshExpires > Date() else { throw TikTokFailure(message: "A autorização expirou. Conecte a conta novamente.") }
        if let refreshOperation { return try await refreshOperation.value.access_token }
        let task = Task { try await tokenRequest(["grant_type": "refresh_token", "refresh_token": config.refresh]) }
        refreshOperation = task
        defer { refreshOperation = nil }
        let token = try await task.value
        try apply(token)
        return token.access_token
    }
    private func tokenRequest(_ values: [String: String]) async throws -> Token {
        guard let config = configuration else { throw TikTokFailure(message: "Configure as credenciais do TikTok.") }
        var values = values; values["client_key"] = config.key; values["client_secret"] = config.secret
        var request = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/oauth/token/")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = TikTokProtocol.form(values)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = try? JSONDecoder().decode(Token.self, from: data) else { throw TikTokFailure(message: "O TikTok não concluiu a autorização. Confirme credenciais, callback e conta de teste no sandbox, e autorize novamente.") }
        return token
    }
    private func apply(_ token: Token) throws {
        guard var config = configuration else { return }
        config.token = token.access_token; config.refresh = token.refresh_token; config.openID = token.open_id; config.scope = token.scope
        config.expires = Date().addingTimeInterval(Double(token.expires_in)); config.refreshExpires = Date().addingTimeInterval(Double(token.refresh_expires_in))
        try save(config)
    }
    private func api<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let token = try await accessToken()
        var request = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/" + path)!)
        request.httpMethod = "POST"; request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decode(request)
    }
    private func decode<T: Decodable>(_ input: URLRequest) async throws -> T {
        var request = input; request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let result = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { throw TikTokFailure(message: "O TikTok retornou uma resposta inesperada (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
        guard (response as? HTTPURLResponse)?.statusCode == 200, result.error.code == "ok" else {
            if result.error.code == "unaudited_client_can_only_post_to_private_accounts" { throw TikTokFailure(message: "O TikTok só aceita envio direto de apps não auditados quando a conta inteira é privada. Use “Rascunho · finalizar no TikTok” ou solicite a auditoria do app (Direct Post) no portal do TikTok.") }
            throw TikTokFailure(message: "O TikTok recusou a operação: \(result.error.code). Verifique as permissões e o ambiente de teste.")
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data), let value = envelope.data else { throw TikTokFailure(message: "O TikTok retornou dados incompletos para esta operação.") }
        return value
    }
    private func save(_ config: Configuration) throws { try vault.write(JSONEncoder().encode(config)); configuration = config; configured = true }
    private func setDetail(_ id: String, _ detail: String) { if let i = deliveries.firstIndex(where: { $0.id == id }) { deliveries[i].detail = detail; persistDeliveries() } }
    private func persistDeliveries() { if let data = try? JSONEncoder().encode(deliveries) { UserDefaults.standard.set(data, forKey: "tiktokDeliveries") } }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TikTokFailure(message: "Não foi possível iniciar uma autorização segura.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func openChrome(_ url: URL) async throws {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { throw TikTokFailure(message: "Instale o Chrome para abrir a autorização.") }
        let config = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: config)
    }
}

private struct TikTokVault: Sendable {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.keychainService("tiktok"), kSecAttrAccount as String: "oauth"] }
    func read() throws -> Data? { var query = query; query[kSecReturnData as String] = true; var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item); if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw TikTokFailure(message: "Não foi possível ler o Chaves do macOS.") }; return item as? Data }
    func write(_ data: Data) throws { let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary); if status == errSecItemNotFound { var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TikTokFailure(message: "Não foi possível salvar as credenciais no Chaves.") } } else if status != errSecSuccess { throw TikTokFailure(message: "Não foi possível atualizar as credenciais no Chaves.") } }
    func delete() throws { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw TikTokFailure(message: "Não foi possível remover as credenciais locais.") } }
}
