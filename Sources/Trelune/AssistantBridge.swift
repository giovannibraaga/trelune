import Foundation
import AppKit

/// Local request bridge: the app owns connections, Keychain access and the publisher.
/// Requests expire quickly, so an offline app never executes an old instruction on launch.
@MainActor final class AssistantBridge {
    private let center: PublishingCenter
    private let router: Router
    private var timer: Timer?
    private var pending: Set<UUID> = []
    private var directory: URL { AppPaths.support.appendingPathComponent("assistant-requests", isDirectory: true) }
    init(center: PublishingCenter, router: Router) { self.center = center; self.router = router }
    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.process() }
        }
    }
    func process() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["response", "processing"].contains(file.pathExtension) {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(modified) > 60 { try? FileManager.default.removeItem(at: file) }
        }
        for file in files where file.pathExtension == "request" {
            let claimed = file.deletingPathExtension().appendingPathExtension("processing")
            do { try FileManager.default.moveItem(at: file, to: claimed) } catch { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard let data = try? Data(contentsOf: claimed), let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let expires = request["expires"] as? Double, expires > Date().timeIntervalSince1970 else { continue }
            let result: [String: Any]
            do { result = ["ok": true, "value": try execute(request)] }
            catch { result = ["ok": false, "error": error.localizedDescription] }
            let response = file.deletingPathExtension().appendingPathExtension("response")
            if let output = try? JSONSerialization.data(withJSONObject: result) { try? output.write(to: response, options: .atomic) }
        }
    }
    func execute(_ request: [String: Any]) throws -> Any {
        let settings = AssistantSettings.load()
        guard settings.enabled else { throw AppIssue("O acesso de assistentes está desativado.") }
        let action = request["action"] as? String ?? "", args = request["arguments"] as? [String: Any] ?? [:]
        center.store.reloadIfChanged()
        switch action {
        case "list_connections":
            guard !center.loadingConnections else { throw AppIssue("As conexões ainda estão carregando. Tente novamente.") }
            return PostStore.networks.map { ["network": $0, "connected": center.isConnected($0), "account": center.accountLabel($0)] as [String: Any] }
        case "get_insights":
            guard !center.loadingConnections else { throw AppIssue("As conexões ainda estão carregando. Tente novamente.") }
            let network = args["platform"] as? String ?? "Todas", days = args["days"] as? Int ?? 30
            guard (network == "Todas" || PostStore.networks.contains(network)), (1...365).contains(days) else { throw AppIssue("Rede ou período inválido.") }
            let insights = Insights(center: center, network: network, days: days)
            func number(_ value: Int?) -> Any { value as Any? ?? NSNull() }
            func metric(_ m: Metric) -> [String: Any] { ["value": number(m.value), "previous": number(m.previous), "sources": m.sources] }
            let rows: [[String: Any]] = insights.summaries.map { ["network": $0.network, "connected": $0.connected, "followers": number($0.followers), "posts": $0.posts, "views": number($0.views), "likes": number($0.likes), "comments": number($0.comments), "shares": number($0.shares)] }
            let items: [[String: Any]] = insights.items.map { ["network": $0.network, "remote_id": $0.remoteID, "title": $0.title, "kind": $0.kind, "date": $0.date.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "link": $0.link as Any? ?? NSNull(), "views": number($0.views), "likes": number($0.likes), "comments": number($0.comments), "shares": number($0.shares)] }
            return ["days": days, "platform": network, "views": metric(insights.views), "likes": metric(insights.likes), "comments": metric(insights.comments), "interactions": metric(insights.interactions), "followers": metric(insights.followers), "published": metric(insights.published), "networks": rows, "content": items, "attention": insights.attention.map { ["network": $0.network, "text": $0.text] }, "note": "Dados carregados pelo app; a disponibilidade depende das redes e permissões."]
        case "validate_publication", "publish_now":
            guard !center.loadingConnections else { throw AppIssue("As conexões ainda estão carregando. Tente novamente.") }
            guard let raw = args["id"] as? String, let id = UUID(uuidString: raw), let post = center.store.post(id) else { throw AppIssue("Publicação não encontrada.") }
            let problems = center.problems(for: post)
            if action == "validate_publication" { return ["id": id.uuidString, "valid": problems.isEmpty && !post.platforms.isEmpty, "problems": problems] }
            guard settings.allowPublish else { throw AppIssue("A permissão de publicar imediatamente está desativada.") }
            guard !post.platforms.isEmpty, ![PostStatus.published, PostStatus.publishing].contains(post.status), !pending.contains(id), !center.running.contains(id) else { throw AppIssue("Publicação já enviada, em envio ou sem destinos.") }
            guard problems.isEmpty else { throw AppIssue("Corrija os problemas antes de publicar: \(problems)") }
            if post.cloud != nil && post.date <= Date() { throw AppIssue("A nuvem já pode estar publicando este item. Aguarde o resultado.") }
            pending.insert(id)
            Task { @MainActor in await center.publish(id); self.pending.remove(id) }
            return ["id": id.uuidString, "accepted": true, "message": "Solicitação aceita pelo aplicativo. Consulte get_publication para acompanhar o envio e o resultado."]
        case "export_backup":
            let data = try JSONEncoder().encode(center.store.posts)
            return try JSONSerialization.jsonObject(with: data)
        case "import_backup":
            guard settings.allowManage else { throw AppIssue("A permissão de gerenciar workspace está desativada.") }
            guard let input = args["publications"] as? [[String: Any]] else { throw AppIssue("Informe a lista de publicações do backup.") }
            let data = try JSONSerialization.data(withJSONObject: input)
            let items = try JSONDecoder().decode([Publication].self, from: data)
            let added = center.store.mergeBackup(items)
            return ["imported": added, "skipped": items.count - added]
        case "export_csv":
            let days = args["days"] as? Int ?? 30, network = args["platform"] as? String ?? "Todas"
            guard (1...365).contains(days), network == "Todas" || PostStore.networks.contains(network) else { throw AppIssue("Rede ou período inválido.") }
            func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let posts = center.store.posts.filter { (network == "Todas" || $0.platforms.contains(network)) && $0.date > Date().addingTimeInterval(-Double(days) * 86400) }.sorted { $0.date < $1.date }
            let rows = posts.map { post in
                [Workspace.format(post.date), post.title, post.status, post.platforms.joined(separator: "; "), post.platforms.map { "\($0): \(post.results[$0].map { $0.succeeded ? "ok" : "falha – \($0.detail)" } ?? "pendente")" }.joined(separator: "; "), post.mediaPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "", post.text].map(cell).joined(separator: ",")
            }
            return ["csv": (["Data,Título,Status,Destinos,Resultados,Mídia,Texto"] + rows).joined(separator: "\n"), "count": posts.count]
        case "get_workspace":
            return ["name": UserDefaults.standard.string(forKey: "workspaceName") ?? "Workspace pessoal", "user_name": UserDefaults.standard.string(forKey: "userName") ?? NSFullUserName(), "timezone": Workspace.timeZone.identifier, "publish_overdue": UserDefaults.standard.object(forKey: "publishOverdue") as? Bool ?? true, "cloud_publishing": center.cloud.enabled, "library_folders": Workspace.libraryFolders] as [String: Any]
        case "update_workspace":
            guard settings.allowManage else { throw AppIssue("A permissão de gerenciar workspace está desativada.") }
            if let zone = args["timezone"] as? String, TimeZone(identifier: zone) == nil { throw AppIssue("Fuso horário inválido.") }
            for (arg, key) in [("name", "workspaceName"), ("user_name", "userName"), ("timezone", Workspace.timeZoneKey)] { if let value = args[arg] as? String { UserDefaults.standard.set(value, forKey: key) } }
            if let overdue = args["publish_overdue"] as? Bool { UserDefaults.standard.set(overdue, forKey: "publishOverdue") }
            SharedWorkspace.write(cloudPublishing: center.cloud.enabled)
            return ["updated": true, "timezone": Workspace.timeZone.identifier]
        case "disconnect_account":
            guard settings.allowManage else { throw AppIssue("A permissão de gerenciar workspace está desativada.") }
            guard let network = args["platform"] as? String, PostStore.networks.contains(network) else { throw AppIssue("Rede inválida.") }
            if network == "Facebook" || network == "Instagram" {
                guard args["confirm_shared_meta"] as? Bool == true else { throw AppIssue("Facebook e Instagram compartilham a conexão Meta. Informe confirm_shared_meta=true para desconectar ambos.") }
            }
            Task { @MainActor in
                switch network {
                case "YouTube": await center.youtube.disconnect()
                case "TikTok": await center.tiktok.disconnect()
                case "Threads": center.threads.disconnect()
                case "X": await center.x.disconnect()
                default: center.meta.disconnect()
                }
            }
            return ["accepted": true, "platform": network, "message": "Desconexão iniciada; consulte list_connections para acompanhar."]
        case "refresh_insights":
            Task { @MainActor in
                await center.youtube.refresh()
                await center.meta.refreshContent()
                await center.tiktok.refreshProfile()
                await center.threads.refresh()
                await center.x.refresh()
            }
            return ["accepted": true, "message": "Atualização iniciada; consulte get_insights após a conclusão."]
        case "open_connection":
            guard settings.allowManage else { throw AppIssue("A permissão de gerenciar workspace está desativada.") }
            guard let network = args["platform"] as? String, PostStore.networks.contains(network) else { throw AppIssue("Rede inválida.") }
            router.connect(network)
            NSApp.activate(ignoringOtherApps: true)
            return ["opened": network, "message": "Conclua a autorização na janela do Trelune."]
        case "manage_library":
            guard settings.allowManage else { throw AppIssue("A permissão de gerenciar workspace está desativada.") }
            guard let operation = args["operation"] as? String, let raw = args["path"] as? String, !raw.contains("\n") else { throw AppIssue("Operação ou caminho inválido.") }
            let path = (raw as NSString).expandingTildeInPath
            let folder = operation == "add_folder" || operation == "remove_folder"
            guard folder || operation == "import" || operation == "remove" else { throw AppIssue("Operação inválida.") }
            if operation == "import" || operation == "add_folder" {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), folder == isDirectory.boolValue, folder || MediaKind.isImage(path) || MediaKind.isVideo(path) else { throw AppIssue("Arquivo ou pasta não encontrado, ou formato de mídia não suportado.") }
            }
            let key = folder ? "libraryFolders" : "mediaFiles"
            var paths = (UserDefaults.standard.string(forKey: key) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
            if operation == "import" || operation == "add_folder" { if !paths.contains(path) { paths.append(path) } } else { paths.removeAll { $0 == path } }
            UserDefaults.standard.set(paths.joined(separator: "\n"), forKey: key)
            SharedWorkspace.write(cloudPublishing: center.cloud.enabled)
            return ["operation": operation, "path": path, "message": "A biblioteca foi atualizada; arquivos não são apagados."]
        default: throw AppIssue("Ação não suportada pelo aplicativo.")
        }
    }
}
