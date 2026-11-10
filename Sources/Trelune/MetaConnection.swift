import SwiftUI
import AppKit
import Network
import Security
import CryptoKit

struct MetaIssue: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class MetaConnection: ObservableObject {
    static let callbackPort: UInt16 = 49682
    /// Meta allows http://localhost redirects automatically while the app is in development mode.
    static let callbackURL = "http://localhost:49682/oauth/callback"
    private static let api = "https://graph.facebook.com/v26.0"
    private static let login = "https://www.facebook.com/v26.0/dialog/oauth"
    private let keychain = MetaVault()
    private var config: Config?
    private var callback: LoopbackCallback?

    @Published private(set) var loading = true
    @Published private(set) var busy = false
    @Published private(set) var configured = false
    @Published private(set) var connected = false
    @Published private(set) var pages: [Page] = []
    @Published private(set) var instagram: [InstagramProfile] = []
    @Published private(set) var recentPosts: [PagePost] = []
    @Published private(set) var pagePosts: [String: [PagePost]] = [:]
    @Published private(set) var instagramMedia: [InstagramMedia] = []
    @Published var message = ""
    /// Errors from the last content refresh, one per Page/Instagram account.
    @Published private(set) var loadErrors: [String] = []
    /// Views per post/media ID from the insights edges (needs read_insights / instagram_manage_insights).
    @Published private(set) var postViews: [String: Int] = [:]
    /// Queries that were refused before a simpler one worked (diagnostics).
    @Published private(set) var fieldFallbacks: [String] = []
    @Published private(set) var insightsAvailable = true
    private struct InsightResponse: Decodable {
        struct Item: Decodable { struct Value: Decodable { let value: Int? }; struct Total: Decodable { let value: Int? }; let name: String; let values: [Value]?; let total_value: Total? }
        let data: [Item]
        var total: Int? { data.first.flatMap { $0.total_value?.value ?? $0.values?.compactMap(\.value).reduce(0, +) } }
    }

    struct Page: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var accessToken: String
        var tasks: [String] = []
        var instagramID: String?
        var instagramUsername: String?
        var instagramFollowers: Int?
        var instagramMediaCount: Int?
        var followers: Int?
    }
    struct InstagramProfile: Codable, Identifiable, Hashable {
        var id: String
        var username: String
        var followersCount: Int?
        var mediaCount: Int?
        var pageName: String
    }
    struct PagePost: Decodable, Identifiable {
        struct Summary: Decodable { let total_count: Int? }
        struct Reactions: Decodable { let summary: Summary? }
        struct Comments: Decodable { let summary: Summary? }
        struct Shares: Decodable { let count: Int? }
        var id: String
        var message: String?
        var created_time: String?
        var permalink_url: String?
        var full_picture: String?
        var shares: Shares?
        var reactions: Reactions?
        var comments: Comments?
    }
    struct InstagramMedia: Decodable, Identifiable {
        var id: String
        var caption: String?
        var media_type: String?
        var media_url: String?
        var permalink: String?
        var timestamp: String?
        var like_count: Int?
        var comments_count: Int?
        var thumbnail_url: String?
    }
    private struct Config: Codable {
        var appID: String
        var appSecret: String
        var userToken = ""
        var tokenExpiry = Date.distantPast
        var userName = ""
        var pages: [Page] = []
    }
    private struct Token: Decodable { let access_token: String; let expires_in: Int? }
    private struct PageList: Decodable { let data: [PageRecord] }
    private struct PageRecord: Decodable {
        struct IG: Decodable { let id: String; let username: String?; let followers_count: Int?; let media_count: Int? }
        let id: String; let name: String; let access_token: String; let tasks: [String]?; let followers_count: Int?
        let instagram_business_account: IG?
    }
    private struct User: Decodable { let id: String; let name: String? }
    private struct ProfileResponse: Decodable { let id: String; let username: String; let followers_count: Int?; let media_count: Int? }
    private struct List<T: Decodable>: Decodable { let data: [T] }
    private struct IDResponse: Decodable { let id: String }
    private struct ReelStart: Decodable { let video_id: String; let upload_url: String? }
    private struct Success: Decodable { let success: Bool }
    private struct StoryResult: Decodable { let success: Bool?; let post_id: String? }
    private struct Container: Decodable { let id: String }
    private struct ContainerState: Decodable { let status_code: String?; let status: String? }
    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String?; let code: Int?; let error_subcode: Int?; let type: String? }
        let error: APIError?
    }
    private struct Envelope<T: Decodable>: Decodable { let data: T? }

    init() {
        Task {
            defer { loading = false }
            do {
                if let data = try await Task.detached(priority: .userInitiated, operation: { try MetaVault().read() }).value {
                    let saved = try JSONDecoder().decode(Config.self, from: data)
                    config = saved; configured = !saved.appID.isEmpty && !saved.appSecret.isEmpty; connected = !saved.userToken.isEmpty; pages = saved.pages
                    rebuildInstagram()
                }
            } catch { message = error.localizedDescription }
        }
    }

    /// Re-reads the Keychain after the cloud refreshed the credentials.
    func reloadCredentials() async {
        guard let data = try? await Task.detached(priority: .userInitiated, operation: { try MetaVault().read() }).value, let saved = try? JSONDecoder().decode(Config.self, from: data) else { return }
        config = saved; configured = !saved.appID.isEmpty && !saved.appSecret.isEmpty; connected = !saved.userToken.isEmpty; pages = saved.pages
        rebuildInstagram()
    }
    func saveClient(appID: String, appSecret: String) {
        do {
            let normalizedID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty, !normalizedSecret.isEmpty else { throw MetaIssue(message: "Informe o ID e o segredo do aplicativo Meta.") }
            var next = config ?? Config(appID: normalizedID, appSecret: normalizedSecret)
            next.appID = normalizedID; next.appSecret = normalizedSecret
            try persist(next)
            configured = true; message = "Aplicativo Meta configurado com armazenamento seguro no Chaves."
        } catch { message = error.localizedDescription }
    }

    func connect() async {
        guard var saved = config, !busy else { return }
        busy = true; message = "Aguardando autorização do Facebook no navegador…"
        defer { callback?.cancel(); callback = nil; busy = false }
        do {
            let state = Self.random()
            let receiver = LoopbackCallback(state: state, fixedPort: Self.callbackPort, hostName: "localhost")
            callback = receiver
            let redirect = try await receiver.start()
            var parts = URLComponents(string: Self.login)!
            parts.queryItems = [
                "client_id": saved.appID,
                "redirect_uri": redirect,
                "response_type": "code",
                "state": state,
                "scope": "public_profile,pages_show_list,pages_read_engagement,pages_manage_posts,instagram_basic,instagram_content_publish",
                "auth_type": "rerequest",
                "display": "popup"
            ].map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let loginURL = parts.url, NSWorkspace.shared.open(loginURL) else { throw MetaIssue(message: "Não foi possível abrir a autorização Meta.") }
            let code = try await receiver.code()
            let short = try await tokenRequest([
                "client_id": saved.appID,
                "client_secret": saved.appSecret,
                "redirect_uri": redirect,
                "code": code
            ])
            let long = try await tokenRequest([
                "grant_type": "fb_exchange_token",
                "client_id": saved.appID,
                "client_secret": saved.appSecret,
                "fb_exchange_token": short.access_token
            ])
            saved.userToken = long.access_token
            saved.tokenExpiry = Date().addingTimeInterval(Double(long.expires_in ?? 5_184_000))
            saved.userName = try await fetchUserName(long.access_token)
            saved.pages = try await fetchPages(long.access_token)
            try persist(saved)
            pages = saved.pages; connected = true; rebuildInstagram()
            message = pages.isEmpty ? "Facebook autorizou, mas não retornou Páginas administradas. Verifique se seu perfil tem acesso às Páginas." : "Facebook conectado. Páginas e contas profissionais do Instagram carregadas."
            await refreshContent()
        } catch { message = error.localizedDescription }
    }

    /// Connects with a user access token generated in the Graph API Explorer (no OAuth redirect needed).
    /// The token is exchanged for a long-lived one; Page tokens obtained from it do not expire.
    func connect(userToken raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var saved = config, !busy else { message = "Salve o ID e o segredo do app antes de conectar."; return }
        guard !token.isEmpty else { message = "Cole o token de acesso gerado no Graph API Explorer."; return }
        busy = true
        do {
            let long = try await tokenRequest(["grant_type": "fb_exchange_token", "client_id": saved.appID, "client_secret": saved.appSecret, "fb_exchange_token": token])
            saved.userToken = long.access_token
            saved.tokenExpiry = Date().addingTimeInterval(Double(long.expires_in ?? 5_184_000))
            saved.userName = try await fetchUserName(long.access_token)
            saved.pages = try await fetchPages(long.access_token)
            try persist(saved)
            pages = saved.pages; connected = true; rebuildInstagram()
            message = pages.isEmpty ? "Token aceito, mas nenhuma Página foi encontrada. \(lastDiagnosis)" : "Conectado como \(saved.userName): \(pages.count) Página(s) e \(instagram.count) Instagram profissional(is)."
            busy = false
            await refreshContent()
        } catch { busy = false; message = error.localizedDescription }
    }

    func refreshContent() async {
        guard connected, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await ensureFreshToken()
            if pages.isEmpty, let token = config?.userToken, var saved = config {
                saved.pages = try await fetchPages(token); try persist(saved); pages = saved.pages; rebuildInstagram()
            }
            guard !pages.isEmpty else { throw MetaIssue(message: "Nenhuma Página encontrada. \(lastDiagnosis)") }
            var loadedPosts: [String: [PagePost]] = [:]
            var problems: [String] = []
            var fallbacks: [String] = []
            // Each Page and Instagram account loads independently; a refused field falls back to a simpler query.
            let fullFields = "id,message,created_time,permalink_url,full_picture,shares,reactions.limit(0).summary(true),comments.limit(0).summary(true)"
            let basicFields = "id,message,created_time,permalink_url,full_picture"
            for page in pages {
                var lastError: Error?
                for (edge, fields) in [("published_posts", fullFields), ("posts", fullFields), ("posts", basicFields)] {
                    do {
                        loadedPosts[page.id] = try await request("\(page.id)/\(edge)", token: page.accessToken, query: [URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "limit", value: "25")])
                        lastError = nil; break
                    } catch { lastError = error; fallbacks.append("\(edge) [\(fields.prefix(40))…]: \(error.localizedDescription)") }
                }
                if let lastError { problems.append("Facebook (\(page.name)): \(lastError.localizedDescription)") }
            }
            var media: [InstagramMedia] = []
            for account in instagram {
                guard let page = pages.first(where: { $0.instagramID == account.id }) else { continue }
                var lastError: Error?
                for fields in ["id,caption,media_type,media_url,permalink,timestamp,like_count,comments_count,thumbnail_url", "id,caption,media_type,media_url,permalink,timestamp"] {
                    do {
                        media += try await request("\(account.id)/media", token: page.accessToken, query: [URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "limit", value: "25")]) as [InstagramMedia]
                        lastError = nil; break
                    } catch { lastError = error }
                }
                if let lastError { problems.append("Instagram (@\(account.username)): \(lastError.localizedDescription)") }
            }
            pagePosts = loadedPosts
            recentPosts = pages.first.flatMap { loadedPosts[$0.id] } ?? []
            instagramMedia = media
            await loadViews(posts: loadedPosts, media: media)
            loadErrors = problems
            fieldFallbacks = fallbacks
            let total = loadedPosts.values.reduce(0) { $0 + $1.count } + media.count
            message = problems.isEmpty ? "Dados atualizados: \(pages.count) Página(s), \(instagram.count) Instagram profissional(is), \(total) publicações recentes carregadas." : problems.joined(separator: "\n")
        } catch { message = error.localizedDescription }
    }

    /// Optional per-item views; stops at the first permission error and flags it.
    private func loadViews(posts: [String: [PagePost]], media: [InstagramMedia]) async {
        var views: [String: Int] = [:]
        var available = true
        for item in media.prefix(25) {
            guard let page = pages.first(where: { $0.instagramID != nil }) else { break }
            do {
                let result: InsightResponse = try await get("\(item.id)/insights", token: page.accessToken, query: [URLQueryItem(name: "metric", value: "views")])
                if let total = result.total { views[item.id] = total }
            } catch { if "\(error)".contains("(#10)") || "\(error)".contains("permission") || "\(error)".contains("(código 10") { available = false; break } }
        }
        for page in pages {
            for post in (posts[page.id] ?? []).prefix(25) {
                var found = false
                for metric in ["post_media_view", "post_impressions"] {
                    if let result: InsightResponse = try? await get("\(post.id)/insights", token: page.accessToken, query: [URLQueryItem(name: "metric", value: metric)]), let total = result.total { views[post.id] = total; found = true; break }
                }
                if !found { break }
            }
        }
        postViews = views
        insightsAvailable = available && !(media.isEmpty == false && views.isEmpty)
    }

    func publishFacebook(pageID: String, text: String, localMedia: URL?) async {
        do { _ = try await postToFacebook(pageID: pageID, text: text, localMedia: localMedia) } catch { message = error.localizedDescription }
    }
    /// Publishes several photos as one Page post (album-style) and returns the post ID.
    func postPhotosToFacebook(pageID: String, text: String, photos: [URL]) async throws -> String {
        if photos.count == 1 { return try await postToFacebook(pageID: pageID, text: text, localMedia: photos[0]) }
        guard !busy else { throw MetaIssue(message: "A conexão Meta está ocupada com outra operação.") }
        busy = true; defer { busy = false }
        try await ensureFreshToken()
        guard let page = pages.first(where: { $0.id == pageID }) else { throw MetaIssue(message: "A Página escolhida não está autorizada nesta conexão.") }
        var ids: [String] = []
        for photo in photos {
            guard MediaKind.isImage(photo.path) else { throw MetaIssue(message: "Posts com várias mídias no Facebook aceitam apenas imagens.") }
            ids.append(try await uploadLocal(media: photo, page: page, text: "", published: false).id)
        }
        var fields = ["message": text]
        for (index, id) in ids.enumerated() { fields["attached_media[\(index)]"] = #"{"media_fbid":"\#(id)"}"# }
        let result: IDResponse = try await post("\(pageID)/feed", token: page.accessToken, fields: fields)
        message = "Publicado na Página \(page.name) com \(ids.count) fotos."
        return result.id
    }
    /// Publishes on a Facebook Page and returns the created object ID.
    func postToFacebook(pageID: String, text: String, localMedia: URL?) async throws -> String {
        guard !busy else { throw MetaIssue(message: "A conexão Meta está ocupada com outra operação.") }
        busy = true; defer { busy = false }
        do {
            try await ensureFreshToken()
            guard let page = pages.first(where: { $0.id == pageID }) else { throw MetaIssue(message: "A Página escolhida não está autorizada nesta conexão.") }
            let result: IDResponse
            if let localMedia {
                let ext = localMedia.pathExtension.lowercased()
                guard ["jpg", "jpeg", "png", "gif", "mp4", "mov"].contains(ext) else { throw MetaIssue(message: "Escolha uma imagem JPG/PNG/GIF ou um vídeo MP4/MOV.") }
                result = (ext == "mp4" || ext == "mov") ? try await publishFacebookReel(media: localMedia, page: page, caption: text) : try await uploadLocal(media: localMedia, page: page, text: text)
            } else {
                result = try await post("\(pageID)/feed", token: page.accessToken, fields: ["message": text])
            }
            message = "Publicado na Página \(page.name). ID: \(result.id)"
            return result.id
        }
    }

    func publishInstagram(pageID: String, caption: String, publicMediaURL: String, asReel: Bool) async {
        do { _ = try await postToInstagram(pageID: pageID, caption: caption, publicMediaURL: publicMediaURL, asReel: asReel) } catch { message = error.localizedDescription }
    }
    /// Publishes a carousel (2–10 public image/video URLs) and returns the media ID.
    func postCarouselToInstagram(pageID: String, caption: String, urls: [String]) async throws -> String {
        if urls.count == 1 { return try await postToInstagram(pageID: pageID, caption: caption, publicMediaURL: urls[0], asReel: MediaKind.isVideoURL(urls[0])) }
        guard (2...10).contains(urls.count) else { throw MetaIssue(message: "O carrossel do Instagram aceita de 2 a 10 itens.") }
        guard !busy else { throw MetaIssue(message: "A conexão Meta está ocupada com outra operação.") }
        busy = true; defer { busy = false }
        try await ensureFreshToken()
        guard let page = pages.first(where: { $0.id == pageID }), let igID = page.instagramID else { throw MetaIssue(message: "Vincule uma conta profissional do Instagram à Página selecionada.") }
        guard caption.utf16.count <= 2200 else { throw MetaIssue(message: "A legenda do Instagram pode ter até 2.200 caracteres.") }
        var children: [String] = []
        for url in urls {
            var fields = ["is_carousel_item": "true"]
            if MediaKind.isVideoURL(url) { fields["media_type"] = "VIDEO"; fields["video_url"] = url } else { fields["image_url"] = url }
            let child: Container = try await post("\(igID)/media", token: page.accessToken, fields: fields)
            try await waitContainer(child.id, token: page.accessToken, attempts: MediaKind.isVideoURL(url) ? 120 : 24)
            children.append(child.id)
        }
        let parent: Container = try await post("\(igID)/media", token: page.accessToken, fields: ["media_type": "CAROUSEL", "children": children.joined(separator: ","), "caption": caption])
        try await waitContainer(parent.id, token: page.accessToken, attempts: 60)
        let published: IDResponse = try await post("\(igID)/media_publish", token: page.accessToken, fields: ["creation_id": parent.id])
        message = "Carrossel publicado no Instagram @\(page.instagramUsername ?? "") (\(urls.count) itens)."
        return published.id
    }
    private func waitContainer(_ id: String, token: String, attempts: Int) async throws {
        for _ in 0..<attempts {
            let state: ContainerState = try await get(id, token: token, query: [URLQueryItem(name: "fields", value: "status_code,status")])
            if state.status_code == "FINISHED" { return }
            if state.status_code == "ERROR" || state.status_code == "EXPIRED" { throw MetaIssue(message: state.status ?? "A Meta não processou esta mídia do Instagram.") }
            try await Task.sleep(for: .seconds(5))
        }
        throw MetaIssue(message: "A Meta ainda está processando a mídia. Tente novamente em alguns minutos.")
    }
    /// Publishes an image or Reel on the Instagram professional account linked to the Page and returns the media ID.
    /// Creates an Instagram media container and waits until Meta has fetched and processed the file.
    private func instagramContainer(igID: String, token: String, fields: [String: String], asReel: Bool) async throws -> String {
        let container: Container = try await post("\(igID)/media", token: token, fields: fields)
        for _ in 0..<(asReel ? 120 : 24) {
            let state: ContainerState = try await get("\(container.id)", token: token, query: [URLQueryItem(name: "fields", value: "status_code,status")])
            if state.status_code == "FINISHED" { return container.id }
            if state.status_code == "ERROR" || state.status_code == "EXPIRED" { throw MetaIssue(message: state.status ?? "A Meta não processou esta mídia do Instagram.") }
            try await Task.sleep(for: .seconds(5))
        }
        throw MetaIssue(message: "A Meta ainda está processando a mídia. Tente novamente em alguns minutos.")
    }
    #if DEBUG
    /// Development aid: asks Meta to fetch and process a hosted file without publishing it (the container expires unused).
    func probeInstagram(url: String, asReel: Bool) async throws -> String {
        try await ensureFreshToken()
        guard let page = pages.first(where: { $0.instagramID != nil }), let igID = page.instagramID else { throw MetaIssue(message: "Sem Instagram vinculado.") }
        let fields = asReel ? ["media_type": "REELS", "video_url": url] : ["image_url": url]
        return try await instagramContainer(igID: igID, token: page.accessToken, fields: fields, asReel: asReel)
    }
    #endif

    func postToInstagram(pageID: String, caption: String, publicMediaURL: String, asReel: Bool, coverURL: String? = nil, thumbOffsetMs: Int? = nil) async throws -> String {
        guard !busy else { throw MetaIssue(message: "A conexão Meta está ocupada com outra operação.") }
        busy = true; defer { busy = false }
        do {
            try await ensureFreshToken()
            guard let page = pages.first(where: { $0.id == pageID }), let igID = page.instagramID else { throw MetaIssue(message: "Vincule uma conta profissional do Instagram à Página selecionada.") }
            guard let remote = URL(string: publicMediaURL), remote.scheme == "https", remote.host != nil else { throw MetaIssue(message: "O Instagram precisa de uma URL HTTPS pública que permita à Meta buscar a mídia.") }
            guard caption.utf16.count <= 2200 else { throw MetaIssue(message: "A legenda do Instagram pode ter até 2.200 caracteres.") }
            var fields: [String: String] = ["caption": caption]
            if asReel {
                fields["media_type"] = "REELS"; fields["video_url"] = remote.absoluteString
                if let coverURL { fields["cover_url"] = coverURL } else if let thumbOffsetMs { fields["thumb_offset"] = String(thumbOffsetMs) }
            }
            else { fields["image_url"] = remote.absoluteString }
            let container = try await instagramContainer(igID: igID, token: page.accessToken, fields: fields, asReel: asReel)
            let published: IDResponse = try await post("\(igID)/media_publish", token: page.accessToken, fields: ["creation_id": container])
            message = "Publicado no Instagram @\(page.instagramUsername ?? "") (ID: \(published.id))."
            return published.id
        }
    }

    /// Shares a public image or video URL to the Instagram Stories of the account linked to the Page.
    func postStoryToInstagram(pageID: String, mediaURL: String) async throws -> String {
        guard !busy else { throw MetaIssue(message: "A conexão Meta está ocupada com outra operação.") }
        busy = true; defer { busy = false }
        try await ensureFreshToken()
        guard let page = pages.first(where: { $0.id == pageID }), let igID = page.instagramID else { throw MetaIssue(message: "Vincule uma conta profissional do Instagram à Página selecionada.") }
        let video = MediaKind.isVideoURL(mediaURL)
        let container = try await instagramContainer(igID: igID, token: page.accessToken, fields: ["media_type": "STORIES", video ? "video_url" : "image_url": mediaURL], asReel: video)
        let published: IDResponse = try await post("\(igID)/media_publish", token: page.accessToken, fields: ["creation_id": container])
        return published.id
    }
    /// Shares a local image or video to the Facebook Page Stories.
    func postStoryToFacebook(pageID: String, media: URL) async throws -> String {
        guard !busy else { throw MetaIssue(message: "A conexão Meta está ocupada com outra operação.") }
        busy = true; defer { busy = false }
        try await ensureFreshToken()
        guard let page = pages.first(where: { $0.id == pageID }) else { throw MetaIssue(message: "A Página escolhida não está autorizada nesta conexão.") }
        let result: StoryResult
        if MediaKind.isVideo(media.path) {
            let size = (try media.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let start: ReelStart = try await post("\(page.id)/video_stories", token: page.accessToken, fields: ["upload_phase": "start"])
            guard let uploadURL = URL(string: start.upload_url ?? "https://rupload.facebook.com/video-upload/v26.0/\(start.video_id)"), uploadURL.host == "rupload.facebook.com" else { throw MetaIssue(message: "A Meta retornou um destino de vídeo inválido.") }
            var upload = URLRequest(url: uploadURL); upload.httpMethod = "POST"; upload.timeoutInterval = 1800
            upload.setValue("OAuth \(page.accessToken)", forHTTPHeaderField: "Authorization"); upload.setValue("0", forHTTPHeaderField: "offset"); upload.setValue(String(size), forHTTPHeaderField: "file_size"); upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: upload, fromFile: media)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw MetaIssue(message: "A Meta não recebeu o vídeo do Story.") }
            result = try await post("\(page.id)/video_stories", token: page.accessToken, fields: ["video_id": start.video_id, "upload_phase": "finish"])
        } else {
            let photo = try await uploadLocal(media: media, page: page, text: "", published: false)
            result = try await post("\(page.id)/photo_stories", token: page.accessToken, fields: ["photo_id": photo.id])
        }
        guard result.success != false else { throw MetaIssue(message: "A Meta não confirmou o Story.") }
        return result.post_id ?? ""
    }

    func disconnect() {
        do {
            try keychain.delete(); config = nil; configured = false; connected = false; pages = []; instagram = []; recentPosts = []; pagePosts = [:]; instagramMedia = []
            message = "Acesso Meta removido do Chaves. Revogue também o app nas configurações do Facebook se desejar encerrar a autorização."
        } catch { message = error.localizedDescription }
    }

    private func fetchUserName(_ token: String) async throws -> String {
        let user: User = try await get("me", token: token, query: [URLQueryItem(name: "fields", value: "id,name")])
        return user.name ?? "Facebook"
    }
    private static let pageFields = "id,name,access_token,tasks,followers_count,instagram_business_account{id,username,followers_count,media_count}"
    private struct DebugToken: Decodable {
        struct Granular: Decodable { let scope: String; let target_ids: [String]? }
        struct Info: Decodable { let is_valid: Bool?; let scopes: [String]?; let granular_scopes: [Granular]? }
        let data: Info
    }
    private struct Business: Decodable { let id: String; let name: String? }

    /// Pages the token can manage. `me/accounts` misses Pages granted only through granular permissions
    /// or owned by a Business Portfolio, so those are looked up by ID as well.
    private func fetchPages(_ token: String) async throws -> [Page] {
        var records: [String: PageRecord] = [:]
        if let list: PageList = try? await get("me/accounts", token: token, query: [URLQueryItem(name: "fields", value: Self.pageFields)]) {
            for page in list.data { records[page.id] = page }
        }
        let debug = try? await inspect(token)
        let granted = Set(debug?.scopes ?? [])
        var ids = Set((debug?.granular_scopes ?? []).filter { $0.scope.hasPrefix("pages_") }.flatMap { $0.target_ids ?? [] })
        if granted.contains("business_management"), let businesses: List<Business> = try? await get("me/businesses", token: token) {
            for business in businesses.data {
                for edge in ["owned_pages", "client_pages"] {
                    if let owned: List<IDResponse> = try? await get("\(business.id)/\(edge)", token: token, query: [URLQueryItem(name: "fields", value: "id")]) { ids.formUnion(owned.data.map(\.id)) }
                }
            }
        }
        for id in ids where records[id] == nil {
            if let page: PageRecord = try? await get(id, token: token, query: [URLQueryItem(name: "fields", value: Self.pageFields)]) { records[id] = page }
        }
        if records.isEmpty {
            let required = ["pages_show_list", "pages_read_engagement", "pages_manage_posts", "business_management"]
            let missing = required.filter { !granted.contains($0) }
            lastDiagnosis = debug == nil ? "Não foi possível inspecionar o token." : "Permissões no token: \(granted.sorted().joined(separator: ", "))." + (missing.isEmpty ? " Nenhuma Página foi selecionada ao gerar o token." : " Faltam: \(missing.joined(separator: ", ")).")
        } else { lastDiagnosis = "" }
        return records.values.sorted { $0.name < $1.name }.map { Page(id: $0.id, name: $0.name, accessToken: $0.access_token, tasks: $0.tasks ?? [], instagramID: $0.instagram_business_account?.id, instagramUsername: $0.instagram_business_account?.username, instagramFollowers: $0.instagram_business_account?.followers_count, instagramMediaCount: $0.instagram_business_account?.media_count, followers: $0.followers_count) }
    }
    /// Explains why no Page came back (shown in the connection sheet).
    @Published private(set) var lastDiagnosis = ""
    private func inspect(_ token: String) async throws -> DebugToken.Info {
        guard let config else { throw MetaIssue(message: "App Meta não configurado.") }
        let result: DebugToken = try await get("debug_token", token: "\(config.appID)|\(config.appSecret)", query: [URLQueryItem(name: "input_token", value: token)])
        return result.data
    }
    /// Reloads the Page list with the saved user token (e.g. after granting more Pages).
    func reloadPages() async {
        guard var saved = config, !saved.userToken.isEmpty, !busy else { return }
        busy = true
        do {
            saved.pages = try await fetchPages(saved.userToken)
            try persist(saved); pages = saved.pages; rebuildInstagram()
            message = pages.isEmpty ? "Nenhuma Página encontrada. \(lastDiagnosis)" : "\(pages.count) Página(s) e \(instagram.count) Instagram profissional(is) carregados."
        } catch { message = error.localizedDescription }
        busy = false
        if !pages.isEmpty { await refreshContent() }
    }
    private func rebuildInstagram() {
        instagram = pages.compactMap { page in guard let id = page.instagramID, let name = page.instagramUsername else { return nil }; return InstagramProfile(id: id, username: name, followersCount: page.instagramFollowers, mediaCount: page.instagramMediaCount, pageName: page.name) }
    }
    private func ensureFreshToken() async throws {
        guard var saved = config, !saved.userToken.isEmpty else { throw MetaIssue(message: "Conecte Facebook e carregue as Páginas administradas.") }
        if saved.tokenExpiry < Date().addingTimeInterval(3600) {
            let refreshed = try await tokenRequest(["grant_type": "fb_exchange_token", "client_id": saved.appID, "client_secret": saved.appSecret, "fb_exchange_token": saved.userToken])
            saved.userToken = refreshed.access_token; saved.tokenExpiry = Date().addingTimeInterval(Double(refreshed.expires_in ?? 5_184_000)); saved.pages = try await fetchPages(saved.userToken)
            try persist(saved); pages = saved.pages; rebuildInstagram()
        }
    }
    private func uploadLocal(media: URL, page: Page, text: String, published: Bool = true) async throws -> IDResponse {
        let scoped = media.startAccessingSecurityScopedResource(); defer { if scoped { media.stopAccessingSecurityScopedResource() } }
        let ext = media.pathExtension.lowercased()
        let endpoint = ext == "mp4" || ext == "mov" ? "\(page.id)/videos" : "\(page.id)/photos"
        let fileData = try Data(contentsOf: media, options: .mappedIfSafe)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        if !text.isEmpty { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\n\(text)\r\n") }
        if endpoint.hasSuffix("photos") { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"published\"\r\n\r\n\(published)\r\n") }
        let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "mp4": "video/mp4", "mov": "video/quicktime"][ext] ?? "application/octet-stream"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"source\"; filename=\"\(media.lastPathComponent.replacingOccurrences(of: "\"", with: ""))\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(fileData); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "\(Self.api)/\(endpoint)")!); request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue("Bearer \(page.accessToken)", forHTTPHeaderField: "Authorization"); request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        return try await perform(request)
    }
    private func publishFacebookReel(media: URL, page: Page, caption: String) async throws -> IDResponse {
        let scoped = media.startAccessingSecurityScopedResource(); defer { if scoped { media.stopAccessingSecurityScopedResource() } }
        let values = try media.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw MetaIssue(message: "Não foi possível ler o vídeo selecionado.") }
        guard size <= 1_000_000_000 else { throw MetaIssue(message: "O Reel selecionado excede 1 GB.") }
        let start: ReelStart = try await post("\(page.id)/video_reels", token: page.accessToken, fields: ["upload_phase": "start"])
        guard let uploadURL = URL(string: start.upload_url ?? "https://rupload.facebook.com/video-upload/v26.0/\(start.video_id)"), uploadURL.scheme == "https", uploadURL.host == "rupload.facebook.com" else { throw MetaIssue(message: "A Meta retornou um destino de vídeo inválido.") }
        var upload = URLRequest(url: uploadURL); upload.httpMethod = "POST"; upload.timeoutInterval = 1800
        upload.setValue("OAuth \(page.accessToken)", forHTTPHeaderField: "Authorization"); upload.setValue("0", forHTTPHeaderField: "offset"); upload.setValue(String(size), forHTTPHeaderField: "file_size"); upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: upload, fromFile: media)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw MetaIssue(message: "A Meta não concluiu o recebimento do Reel. Confira o formato do vídeo e tente novamente.") }
        let finished: Success = try await post("\(page.id)/video_reels", token: page.accessToken, fields: ["video_id": start.video_id, "upload_phase": "finish", "video_state": "PUBLISHED", "description": caption])
        guard finished.success else { throw MetaIssue(message: "A Meta recebeu o vídeo, mas não confirmou a publicação do Reel.") }
        return IDResponse(id: start.video_id)
    }
    private func request<T: Decodable>(_ path: String, token: String, query: [URLQueryItem] = []) async throws -> [T] {
        let list: List<T> = try await get(path, token: token, query: query)
        return list.data
    }
    private func tokenRequest(_ values: [String: String]) async throws -> Token {
        var parts = URLComponents(string: "\(Self.api)/oauth/access_token")!
        parts.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 30
        return try await perform(request)
    }
    private func get<T: Decodable>(_ path: String, token: String, query: [URLQueryItem] = []) async throws -> T {
        var parts = URLComponents(string: "\(Self.api)/\(path)")!; parts.queryItems = query
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 60; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }
    private func post<T: Decodable>(_ path: String, token: String, fields: [String: String]) async throws -> T {
        var parts = URLComponents(string: "\(Self.api)/\(path)")!
        parts.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]!) }
        var request = URLRequest(url: parts.url!); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data()
        return try await perform(request)
    }
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetaIssue(message: "A Meta não retornou uma resposta HTTP.") }
        guard (200..<300).contains(http.statusCode) else {
            let details = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let apiError = details?.error
            let detail = apiError?.message ?? "HTTP \(http.statusCode)"
            let suffix = apiError?.code.map { " (código \($0)\(apiError?.error_subcode.map { ".\($0)" } ?? ""))" } ?? ""
            throw MetaIssue(message: "A Meta recusou a operação: \(detail)\(suffix). Confira o modo de desenvolvimento e as permissões do app.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MetaIssue(message: "A Meta retornou dados incompatíveis com a resposta esperada. Atualize o app e tente novamente.") }
    }
    private func persist(_ saved: Config) throws { try keychain.write(JSONEncoder().encode(saved)); config = saved }
    private static func random() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString }
}

private struct MetaVault: Sendable {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.keychainService("meta"), kSecAttrAccount as String: "oauth"] }
    func read() throws -> Data? { var q = query; q[kSecReturnData as String] = true; var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item); if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw MetaIssue(message: "Não foi possível ler as credenciais Meta no Chaves.") }; return item as? Data }
    func write(_ data: Data) throws { let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary); if status == errSecItemNotFound { var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw MetaIssue(message: "Não foi possível salvar as credenciais Meta no Chaves.") } } else if status != errSecSuccess { throw MetaIssue(message: "Não foi possível atualizar as credenciais Meta no Chaves.") } }
    func delete() throws { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw MetaIssue(message: "Não foi possível remover credenciais Meta do Chaves.") } }
}
