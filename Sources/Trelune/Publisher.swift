import Foundation
import Combine
import UserNotifications

/// Publishes publications to every selected network, both on demand and when a scheduled time arrives.
@MainActor final class PublishingCenter: ObservableObject {
    let store: PostStore
    let youtube: YouTubeConnection
    let meta: MetaConnection
    let tiktok: TikTokConnection
    let threads: ThreadsConnection
    let x: XConnection
    let host: MediaHost
    let cloud: CloudPublisher
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var lastRun: Date?
    @Published var lastMessage = ""
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private let launched = Date()

    init(store: PostStore, youtube: YouTubeConnection, meta: MetaConnection, tiktok: TikTokConnection, threads: ThreadsConnection, x: XConnection, host: MediaHost) {
        self.store = store; self.youtube = youtube; self.meta = meta; self.tiktok = tiktok; self.threads = threads; self.x = x; self.host = host
        cloud = CloudPublisher(host: host)
        cloud.attach(store)
        // Re-render views that read connection state through this object.
        let forward: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.objectWillChange.send() } }
        youtube.objectWillChange.sink { _ in forward() }.store(in: &bag)
        meta.objectWillChange.sink { _ in forward() }.store(in: &bag)
        tiktok.objectWillChange.sink { _ in forward() }.store(in: &bag)
        threads.objectWillChange.sink { _ in forward() }.store(in: &bag)
        x.objectWillChange.sink { _ in forward() }.store(in: &bag)
        store.objectWillChange.sink { _ in forward() }.store(in: &bag)
        host.objectWillChange.sink { _ in forward() }.store(in: &bag)
        cloud.objectWillChange.sink { _ in forward() }.store(in: &bag)
        cloud.onCredentialsPulled = { [weak self] name in
            guard let self else { return }
            switch name {
            case "youtube": await self.youtube.reloadCredentials()
            case "meta": await self.meta.reloadCredentials()
            case "tiktok": await self.tiktok.reloadCredentials()
            case "threads": await self.threads.reloadCredentials()
            case "x": await self.x.reloadCredentials()
            default: break
            }
        }
    }

    func start() {
        // Development captures run next to the real app and must never publish.
        guard timer == nil, ProcessInfo.processInfo.environment["TRELUNE_NO_SCHEDULER"] == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
        Notifier.requestIfNeeded()
    }

    var loadingConnections: Bool { youtube.loadingConfiguration || meta.loading || tiktok.loadingConfiguration || threads.loading || x.loading || host.loading }

    func isConnected(_ network: String) -> Bool {
        switch network {
        case "YouTube": !youtube.channel.isEmpty
        case "TikTok": tiktok.connected
        case "Facebook": !meta.pages.isEmpty
        case "Instagram": !meta.instagram.isEmpty
        case "Threads": threads.connected
        case "X": x.connected
        default: false
        }
    }
    func accountLabel(_ network: String) -> String {
        switch network {
        case "YouTube": youtube.loadingConfiguration ? "Lendo o Chaves…" : youtube.channel.isEmpty ? (youtube.configured ? "Credenciais prontas · autorize" : "Não conectada") : youtube.channel
        case "TikTok": tiktok.loadingConfiguration ? "Lendo o Chaves…" : tiktok.connected ? (tiktok.displayName.isEmpty ? "Conta autorizada" : tiktok.displayName) : tiktok.configured ? "Credenciais prontas · autorize" : "Não conectada"
        case "Facebook": meta.loading ? "Lendo o Chaves…" : meta.pages.isEmpty ? (meta.connected ? "Sem Páginas autorizadas" : meta.configured ? "App configurado · autorize" : "Não conectada") : meta.pages.map(\.name).joined(separator: ", ")
        case "Instagram": meta.loading ? "Lendo o Chaves…" : meta.instagram.isEmpty ? (meta.connected ? "Nenhum perfil profissional vinculado" : "Não conectada") : meta.instagram.map { "@\($0.username)" }.joined(separator: ", ")
        case "Threads": threads.loading ? "Lendo o Chaves…" : threads.connected ? "@\(threads.username)" : "Não conectada"
        case "X": x.loading ? "Lendo o Chaves…" : x.connected ? (x.username.isEmpty ? "Conta autorizada" : "@\(x.username)") : x.configured ? "Credenciais prontas · autorize" : "Não conectada"
        default: "Não conectada"
        }
    }

    /// Returns a problem description for a destination that cannot be published as configured, or nil when ready.
    func problem(for network: String, in post: Publication) -> String? {
        guard isConnected(network) else { return "Conta não conectada." }
        if let missing = post.media.first(where: { !FileManager.default.fileExists(atPath: $0) }) { return "Arquivo não encontrado: \(URL(fileURLWithPath: missing).lastPathComponent)." }
        let text = post.text(for: network)
        if NetworkLimits.length(text, for: network) > NetworkLimits.text(network) { return "Texto acima de \(NetworkLimits.text(network)) caracteres\(network == "X" ? " (no X, cada link conta 23 e emoji conta 2)" : "")." }
        let size = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        if let maxImage = NetworkLimits.imageBytes(network), let big = post.images.first(where: { size($0) > maxImage }) { return "\(URL(fileURLWithPath: big).lastPathComponent) passa de \(maxImage / 1_000_000) MB, limite do \(network)." }
        let images = post.images.count, videos = post.videos.count, total = post.media.count
        let ext = { (path: String) in URL(fileURLWithPath: path).pathExtension.lowercased() }
        let canHost = host.configured || (total <= 1 && URL(string: post.publicMediaURL ?? "")?.scheme == "https")
        switch network {
        case "YouTube":
            guard videos == 1, images == 0, ["mp4", "mov", "m4v"].contains(ext(post.videos[0])) else { return "Exige exatamente um vídeo MP4, MOV ou M4V." }
            if post.title(for: network).utf16.count > 100 { return "Título acima de 100 caracteres." }
            if post.title(for: network).trimmingCharacters(in: .whitespaces).isEmpty { return "Informe um título." }
        case "TikTok":
            if videos == 1 && images == 0 {
                guard ["mp4", "mov", "webm"].contains(ext(post.videos[0])) else { return "Use vídeo MP4, MOV ou WebM." }
            } else if videos == 0 && (1...35).contains(images) {
                guard host.configured else { return "Fotos no TikTok precisam da hospedagem de mídia (Ajustes → Hospedagem)." }
            } else { return "Use um vídeo ou de 1 a 35 imagens (sem misturar)." }
            if !tiktok.canUpload { return "Reautorize o TikTok com a permissão video.upload." }
            if post.tiktokPrivacy != "INBOX" && !tiktok.canPublish { return "Publicação direta exige video.publish; reautorize o TikTok ou envie como rascunho." }
            if post.tiktokPrivacy.isEmpty { return "Escolha quem pode ver o post no TikTok." }
            if post.tiktokDisclose && !post.tiktokYourBrand && !post.tiktokBranded { return "Na divulgação comercial do TikTok, marque “Sua marca” e/ou “Conteúdo de marca”." }
            if post.tiktokDisclose && post.tiktokBranded && post.tiktokPrivacy == "SELF_ONLY" { return "Conteúdo de marca no TikTok não pode ser “Somente eu”." }
        case "Instagram":
            if total == 0 && (post.publicMediaURL ?? "").isEmpty { return "O Instagram exige imagem, carrossel ou vídeo." }
            if total > 10 { return "Carrossel do Instagram aceita até 10 itens." }
            if !canHost { return "Configure a hospedagem de mídia (Ajustes → Hospedagem) para enviar arquivos do Mac." }
            if instagramPage(for: post) == nil { return "Nenhuma Página com Instagram profissional vinculado." }
        case "Facebook":
            if videos > 1 || (videos == 1 && images > 0) { return "Use até 10 imagens ou um único vídeo." }
            if images > 10 { return "Use até 10 imagens." }
            if videos == 1 && !["mp4", "mov"].contains(ext(post.videos[0])) { return "Use vídeo MP4 ou MOV." }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && total == 0 { return "Escreva um texto ou anexe uma mídia." }
        case "Threads":
            if total > 20 { return "Carrossel do Threads aceita até 20 itens." }
            if let image = post.images.first(where: { !["jpg", "jpeg", "png"].contains(ext($0)) }) { return "O Threads aceita imagens JPG ou PNG (\(URL(fileURLWithPath: image).lastPathComponent))." }
            if let video = post.videos.first(where: { !["mp4", "mov"].contains(ext($0)) }) { return "O Threads aceita vídeo MP4 ou MOV (\(URL(fileURLWithPath: video).lastPathComponent))." }
            if let video = post.videos.first(where: { size($0) > 1_000_000_000 }) { return "\(URL(fileURLWithPath: video).lastPathComponent) passa de 1 GB, limite do Threads." }
            if links(in: text) > 5 { return "O Threads aceita até 5 links por post." }
            if total > 0 && !canHost { return "Configure a hospedagem de mídia (Ajustes → Hospedagem) para enviar arquivos do Mac." }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && total == 0 && (post.publicMediaURL ?? "").isEmpty { return "Escreva um texto ou adicione mídia." }
        case "X":
            if videos > 0 { return "O X recebe só imagens por esta integração; remova o vídeo ou desmarque o X." }
            if images > 4 { return "O X aceita até 4 imagens (há \(images)); desmarque o X ou reduza o carrossel." }
            if let image = post.images.first(where: { !["jpg", "jpeg", "png", "gif", "webp"].contains(ext($0)) }) { return "O X aceita imagens JPG, PNG, GIF ou WebP (\(URL(fileURLWithPath: image).lastPathComponent))." }
            if images > 1 && post.images.contains(where: { ext($0) == "gif" }) { return "No X, um GIF precisa ir sozinho, sem outras imagens." }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images == 0 { return "Escreva o texto do post." }
        default: return "Rede sem integração."
        }
        return nil
    }
    func problems(for post: Publication) -> [String: String] {
        var result: [String: String] = [:]
        for network in post.platforms where post.results[network]?.succeeded != true {
            if let issue = problem(for: network, in: post) { result[network] = issue }
        }
        return result
    }

    // MARK: Scheduler

    func tick() async {
        store.reloadIfChanged()
        guard !loadingConnections else { return }
        lastRun = Date()
        let publishOverdue = UserDefaults.standard.object(forKey: "publishOverdue") as? Bool ?? true
        await cloud.sync(store: store, problems: { [unowned self] in self.problems(for: $0) })
        // Posts handed to the cloud are published there; the Mac only collects their results.
        let due = store.posts.filter { $0.status == PostStatus.scheduled && $0.date <= Date() && !running.contains($0.id) && !cloud.manages($0.id) }
            .sorted { $0.date < $1.date }
        for post in due {
            // A post that became due while the app was closed is only sent when the user allows late publishing.
            if !publishOverdue && post.date < launched.addingTimeInterval(-60) {
                store.edit(post.id) { $0.status = PostStatus.failed; for network in $0.platforms where $0.results[network]?.succeeded != true { $0.results[network] = PlatformResult(state: "failed", detail: "Horário perdido com o app fechado. Publique manualmente ou reagende.") } }
                Notifier.post(title: "Agendamento perdido", body: post.title, failure: true)
                continue
            }
            await publish(post.id)
        }
        await prepareHosting()
        await checkPending()
    }

    private var lastPendingCheck = Date.distantPast
    /// Inbox deliveries go live only when the user finishes them in the TikTok app; follow them for 7 days.
    private func checkPending() async {
        guard Date().timeIntervalSince(lastPendingCheck) > 600, tiktok.connected else { return }
        lastPendingCheck = Date()
        for post in store.posts where post.date > Date().addingTimeInterval(-7 * 86400) {
            guard let result = post.results["TikTok"], result.pending, let id = result.remoteID, !id.isEmpty else { continue }
            guard let state = try? await tiktok.publishStatus(id) else { continue }
            if state.status == "PUBLISH_COMPLETE" || state.status == "FAILED" {
                store.edit(post.id) { item in
                    item.results["TikTok"] = state.status == "FAILED"
                        ? PlatformResult(state: "failed", detail: "O TikTok descartou o envio da caixa de entrada: \(state.reason ?? "motivo não informado").", remoteID: id)
                        : PlatformResult(state: "ok", detail: "Publicado no TikTok (concluído no app).", remoteID: id)
                    item.status = item.settledStatus()
                }
            }
        }
    }

    /// Posts whose media was already sent to the host ahead of time, keyed by post version.
    private var prepared: Set<String> = []
    /// True when a destination of the post receives its media through a public link instead of a direct upload.
    func needsHosting(_ post: Publication) -> Bool {
        guard !post.media.isEmpty else { return false }
        return post.platforms.contains { network in
            guard post.results[network]?.succeeded != true else { return false }
            return network == "Instagram" || network == "Threads" || (network == "TikTok" && post.videos.isEmpty)
        }
    }
    /// Sends the media of posts due within two days to the host, so publishing only hands the link to each network
    /// and an upload problem shows up before the scheduled time. Hosted files expire after a week, so later posts wait.
    func prepareHosting() async {
        guard host.configured else { return }
        let now = Date(), soon = now.addingTimeInterval(2 * 86400)
        for post in store.posts where post.status == PostStatus.scheduled && post.date > now && post.date <= soon && needsHosting(post) {
            guard post.media.allSatisfy({ FileManager.default.fileExists(atPath: $0) }), prepared.insert("\(post.id)|\(post.updated.timeIntervalSince1970)").inserted else { continue }
            do {
                _ = try await publicURLs(post)
                if post.platforms.contains("Instagram"), post.videos.count == 1, let cover = post.coverPath, FileManager.default.fileExists(atPath: cover) { _ = try await host.publicURL(for: cover) }
                lastMessage = "Mídia de “\(post.title)” já está na hospedagem, pronta para o horário agendado."
            } catch {
                lastMessage = "Não foi possível enviar a mídia de “\(post.title)” à hospedagem: \(error.localizedDescription)"
                Notifier.post(title: "Falha ao preparar a mídia", body: lastMessage, failure: true)
            }
        }
    }

    /// Publishes every destination that has not succeeded yet. Safe to call again to retry failures.
    func publish(_ id: UUID) async {
        guard !running.contains(id), let initial = store.post(id) else { return }
        running.insert(id); defer { running.remove(id) }
        if cloud.manages(id) {
            guard initial.date > Date() else { lastMessage = "“\(initial.title)” já está sendo publicado pela nuvem."; return }
            await cloud.release(id)
            guard !cloud.manages(id) else { lastMessage = "Não foi possível cancelar o agendamento na nuvem; o envio local não foi iniciado."; return }
        }
        let previousStatus = initial.status
        store.status(id, PostStatus.publishing)
        for network in initial.platforms {
            guard let post = store.post(id) else { return }
            if post.results[network]?.succeeded == true { continue }
            let result: PlatformResult
            if let issue = problem(for: network, in: post) {
                result = PlatformResult(state: "failed", detail: issue)
            } else {
                do { result = try await send(network, post) }
                catch { result = PlatformResult(state: "failed", detail: error.localizedDescription) }
            }
            store.edit(id) { $0.results[network] = result }
        }
        guard let finished = store.post(id) else { return }
        let succeeded = finished.platforms.filter { finished.results[$0]?.succeeded == true }
        let status = finished.settledStatus()
        store.edit(id) { $0.status = status }
        let failures = finished.platforms.filter { finished.results[$0]?.succeeded != true }
        let pending = finished.platforms.filter { finished.results[$0]?.pending == true }
        lastMessage = !failures.isEmpty ? "“\(finished.title)”: falha em \(failures.joined(separator: ", "))."
            : !pending.isEmpty ? "“\(finished.title)” publicado em \(succeeded.filter { !pending.contains($0) }.joined(separator: ", ")); falta concluir no app do \(pending.joined(separator: ", ")) (caixa de entrada)."
            : "“\(finished.title)” publicado em \(succeeded.joined(separator: ", "))."
        if previousStatus == PostStatus.scheduled || status != PostStatus.published {
            Notifier.post(title: !failures.isEmpty ? "Falha ao publicar" : !pending.isEmpty ? "Falta concluir no \(pending.joined(separator: ", "))" : "Publicação enviada", body: lastMessage, failure: status != PostStatus.published)
        }
    }

    private func send(_ network: String, _ post: Publication) async throws -> PlatformResult {
        let text = post.text(for: network)
        let title = post.title(for: network)
        switch network {
        case "YouTube":
            try await waitIdle { self.youtube.busy }
            let video = post.videos[0]
            let thumbnail = try await coverImage(post, video: video)
            let id = try await youtube.publishVideo(URL(fileURLWithPath: video), title: title, description: text, privacy: post.youtubePrivacy, tags: post.tags, thumbnail: thumbnail)
            let note = thumbnail == nil ? "" : " \(youtube.thumbnailNote)"
            return PlatformResult(state: "ok", detail: "Vídeo enviado (\(privacyLabel(post.youtubePrivacy))).\(note)", remoteID: id, link: id.isEmpty ? nil : "https://youtu.be/\(id)")
        case "Facebook":
            try await waitIdle { self.meta.busy }
            guard let page = facebookPage(for: post) else { throw AppIssue("Nenhuma Página do Facebook autorizada.") }
            let id = post.images.count > 1
                ? try await meta.postPhotosToFacebook(pageID: page.id, text: text, photos: post.images.map { URL(fileURLWithPath: $0) })
                : try await meta.postToFacebook(pageID: page.id, text: text, localMedia: post.mediaURL)
            var detail = "Publicado na Página \(page.name)."
            if post.stories, let first = post.media.first {
                do { _ = try await meta.postStoryToFacebook(pageID: page.id, media: URL(fileURLWithPath: first)); detail += " Story publicado." }
                catch { detail += " Story não publicado: \(error.localizedDescription)" }
            }
            return PlatformResult(state: "ok", detail: detail, remoteID: id, link: "https://www.facebook.com/\(id)")
        case "Instagram":
            guard let page = instagramPage(for: post) else { throw AppIssue("Instagram sem Página vinculada.") }
            let urls = try await publicURLs(post)
            try await waitIdle { self.meta.busy }
            let id: String
            if urls.count > 1 {
                id = try await meta.postCarouselToInstagram(pageID: page.id, caption: text, urls: urls)
            } else {
                let isVideo = post.videos.count == 1 || MediaKind.isVideoURL(urls[0])
                var coverURL: String?
                if isVideo, let cover = post.coverPath { coverURL = try await host.publicURL(for: cover) }
                id = try await meta.postToInstagram(pageID: page.id, caption: text, publicMediaURL: urls[0], asReel: isVideo, coverURL: coverURL, thumbOffsetMs: post.coverTime.map { Int($0 * 1000) })
            }
            var detail = "Publicado em @\(page.instagramUsername ?? "") · \(post.format(for: network))."
            if post.stories, let first = urls.first {
                do { try await waitIdle { self.meta.busy }; _ = try await meta.postStoryToInstagram(pageID: page.id, mediaURL: first); detail += " Story publicado." }
                catch { detail += " Story não publicado: \(error.localizedDescription)" }
            }
            return PlatformResult(state: "ok", detail: detail, remoteID: id)
        case "TikTok":
            let draft = post.tiktokPrivacy == "INBOX"
            let result: (id: String, status: String)
            if post.videos.count == 1 {
                try await waitIdle { self.tiktok.busy }
                let options = draft ? nil : TikTokConnection.DirectOptions(title: text, privacy: post.tiktokPrivacy, disableComment: !post.tiktokAllowComments, disableDuet: !post.tiktokAllowDuet, disableStitch: !post.tiktokAllowStitch, ownBrand: post.tiktokDisclose && post.tiktokYourBrand, paidBrand: post.tiktokDisclose && post.tiktokBranded, aiGenerated: false, coverMs: post.coverTime.map { Int($0 * 1000) })
                result = try await tiktok.sendVideo(URL(fileURLWithPath: post.videos[0]), title: title, direct: options)
            } else {
                let urls = try await publicURLs(post)
                try await waitIdle { self.tiktok.busy }
                result = try await tiktok.sendPhotos(urls, title: title, description: text, privacy: draft ? nil : post.tiktokPrivacy, allowComments: post.tiktokAllowComments, coverIndex: 0)
            }
            let done = result.status == "PUBLISH_COMPLETE"
            return PlatformResult(state: done ? "ok" : "inbox", detail: done ? "Publicado no TikTok." : draft ? "Entregue na caixa de entrada do TikTok. Finalize a publicação no app do TikTok." : "Enviado ao TikTok; o processamento continua no TikTok.", remoteID: result.id)
        case "Threads":
            let urls = post.media.isEmpty ? (post.publicMediaURL.map { [$0] } ?? []) : try await publicURLs(post)
            try await waitIdle { self.threads.busy }
            let id = try await threads.publish(text: text, mediaURLs: urls)
            return PlatformResult(state: "ok", detail: "Publicado em @\(threads.username).", remoteID: id)
        case "X":
            try await waitIdle { self.x.busy }
            let id = try await x.post(text: text, images: post.images.map { URL(fileURLWithPath: $0) })
            return PlatformResult(state: "ok", detail: "Publicado em @\(x.username).", remoteID: id, link: "https://x.com/\(x.username)/status/\(id)")
        default:
            throw AppIssue("Rede sem integração.")
        }
    }

    /// Public URLs for every media file, uploading to the media host when configured.
    private func publicURLs(_ post: Publication) async throws -> [String] {
        if post.media.isEmpty, let url = post.publicMediaURL, !url.isEmpty { return [url] }
        if !host.configured, post.media.count == 1, let url = post.publicMediaURL, URL(string: url)?.scheme == "https" { return [url] }
        var urls: [String] = []
        for path in post.media { urls.append(try await host.publicURL(for: path)) }
        return urls
    }
    /// Custom cover image, or the chosen video frame exported as JPEG.
    private func coverImage(_ post: Publication, video: String) async throws -> String? {
        if let path = post.coverPath, FileManager.default.fileExists(atPath: path) { return path }
        if let time = post.coverTime { return try await CoverFrame.export(video: video, at: time) }
        return nil
    }

    func facebookPage(for post: Publication) -> MetaConnection.Page? {
        meta.pages.first { $0.id == post.facebookPageID } ?? meta.pages.first
    }
    func instagramPage(for post: Publication) -> MetaConnection.Page? {
        if let chosen = meta.pages.first(where: { $0.id == post.facebookPageID }), chosen.instagramID != nil { return chosen }
        return meta.pages.first { $0.instagramID != nil }
    }
    private func links(in text: String) -> Int {
        (try? NSRegularExpression(pattern: #"https?://[^\s]+"#))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }
    private func waitIdle(_ busy: @escaping @MainActor () -> Bool) async throws {
        var waited = 0
        while busy() {
            guard waited < 600 else { throw AppIssue("A conexão permaneceu ocupada por muito tempo. Tente novamente.") }
            try await Task.sleep(for: .seconds(2)); waited += 2
        }
    }
    private func privacyLabel(_ value: String) -> String { value == "public" ? "público" : value == "unlisted" ? "não listado" : "privado" }
}

enum Notifier {
    /// Notifications need a bundled app; the raw SwiftPM binary has no bundle identifier.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    static func requestIfNeeded() {
        guard available else { return }
        let defaults = UserDefaults.standard
        let wanted = (defaults.object(forKey: "notifyScheduled") as? Bool ?? true) || (defaults.object(forKey: "notifyFailed") as? Bool ?? true)
        guard wanted else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(title: String, body: String, failure: Bool) {
        guard available else { return }
        let key = failure ? "notifyFailed" : "notifyScheduled"
        guard UserDefaults.standard.object(forKey: key) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = L(title); content.body = L(body); content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

