import SwiftUI
import AppKit

// MARK: - stdio MCP server (`Trelune --mcp`)

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// It reads and writes the same publications file as the app; the app's scheduler publishes what assistants schedule.
@MainActor final class MCPServer {
    private let store = PostStore()
    private static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let id = message["id"] else { return } // notifications need no response
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            reply(id, ["protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                       "capabilities": ["tools": ["listChanged": false]],
                       "serverInfo": ["name": "trelune", "version": "1.0.0"],
                       "instructions": "Gerencia rascunhos e agendamentos do Trelune neste Mac. Datas em ISO 8601; sem fuso, usa o fuso do workspace (\(Workspace.timeZone.identifier)). O app publica os itens agendados no horário enquanto estiver aberto."])
        case "ping": reply(id, [:])
        case "tools/list": reply(id, ["tools": tools()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try call(name, arguments)
                AssistantLogEntry.append(AssistantLogEntry(tool: name, ok: true, summary: result.summary))
                reply(id, ["content": [["type": "text", "text": json(result.payload)]], "isError": false])
            } catch {
                AssistantLogEntry.append(AssistantLogEntry(tool: name, ok: false, summary: error.localizedDescription))
                reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Método não suportado: \(method)"]])
        }
    }

    // MARK: Tools

    private func tools() -> [[String: Any]] {
        let settings = AssistantSettings.load()
        let platforms: [String: Any] = ["type": "array", "items": ["type": "string", "enum": PostStore.networks], "description": "Destinos da publicação."]
        var list: [[String: Any]] = [
            tool("list_publications", "Lista publicações do workspace, mais recentes primeiro.", ["status": ["type": "string", "enum": PostStatus.all], "platform": ["type": "string", "enum": PostStore.networks], "limit": ["type": "integer", "minimum": 1, "maximum": 200]]),
            tool("get_publication", "Retorna uma publicação pelo id, com resultados de envio por rede.", ["id": ["type": "string"]], required: ["id"]),
            tool("get_overview", "Resumo do workspace: contagem por status e próximos agendamentos.", [:]),
            tool("list_media", "Lista os arquivos da biblioteca de mídia (caminhos locais).", [:]),
            tool("get_workspace", "Consulta ajustes do workspace no app aberto.", [:]),
            tool("export_backup", "Retorna backup JSON das publicações pelo app aberto.", [:]),
            tool("export_csv", "Retorna relatório CSV das publicações pelo app aberto.", ["platform": ["type": "string", "enum": PostStore.networks], "days": ["type": "integer", "minimum": 1, "maximum": 365]]),
            tool("list_connections", "Lista contas e estado das conexões carregadas pelo app aberto.", [:]),
            tool("refresh_insights", "Inicia atualização dos dados das redes no app aberto.", [:]),
            tool("get_insights", "Consulta métricas e conteúdo carregados pelo app aberto.", ["platform": ["type": "string", "enum": PostStore.networks], "days": ["type": "integer", "minimum": 1, "maximum": 365]]),
            tool("validate_publication", "Valida destinos e requisitos com as contas do app aberto.", ["id": ["type": "string"]], required: ["id"]),
        ]
        if settings.allowManage {
            list.append(tool("import_backup", "Importa publicações de backup, preservando IDs existentes; requer app aberto.", ["publications": ["type": "array", "items": ["type": "object"]]], required: ["publications"]))
            list.append(tool("update_workspace", "Atualiza nome, usuário, fuso e publicação atrasada no app aberto.", ["name": ["type": "string"], "user_name": ["type": "string"], "timezone": ["type": "string"], "publish_overdue": ["type": "boolean"]]))
            list.append(tool("manage_library", "Importa ou remove uma mídia ou gerencia pastas monitoradas; não apaga arquivos. Requer o app aberto.", ["operation": ["type": "string", "enum": ["import", "remove", "add_folder", "remove_folder"]], "path": ["type": "string"]], required: ["operation", "path"]))
            list.append(tool("disconnect_account", "Desconecta uma conta; Facebook e Instagram compartilham a conexão Meta e exigem confirmação conjunta.", ["platform": ["type": "string", "enum": PostStore.networks], "confirm_shared_meta": ["type": "boolean"]], required: ["platform"]))
            list.append(tool("open_connection", "Abre a configuração de uma rede no app; o usuário conclui a autorização.", ["platform": ["type": "string", "enum": PostStore.networks]], required: ["platform"]))
        }
        if settings.allowWrite {
            list.append(tool("duplicate_publication", "Duplica uma publicação como rascunho, sem resultados ou agendamento na nuvem.", ["id": ["type": "string"]], required: ["id"]))
            list.append(tool("create_draft", "Cria um rascunho. Não publica nada.", ["cover_path": ["type": "string", "description": "Arquivo JPEG ou PNG da capa; vazio remove."], "cover_time_seconds": ["type": ["number", "null"], "description": "Quadro em segundos; null remove."], "title": ["type": "string"], "text": ["type": "string"], "platforms": platforms, "media_path": ["type": "string", "description": "Caminho de um arquivo local (ex.: da list_media)."], "media_paths": ["type": "array", "items": ["type": "string"], "description": "Vários arquivos locais em ordem (carrossel); não define capa de vídeo."], "titles": ["type": "object", "additionalProperties": ["type": "string"], "description": "Título por rede, ex.: {\"YouTube\": \"...\"}."], "public_media_url": ["type": "string", "description": "URL HTTPS pública, exigida por Instagram e para mídia no Threads."], "overrides": ["type": "object", "additionalProperties": ["type": "string"], "description": "Texto específico por rede, ex.: {\"X\": \"versão curta\"}."], "youtube_privacy": ["type": "string", "enum": ["private", "unlisted", "public"]]], required: ["title", "text", "platforms"]))
            list.append(tool("update_publication", "Altera um rascunho ou agendamento existente.", ["id": ["type": "string"], "cover_path": ["type": "string", "description": "Arquivo JPEG ou PNG da capa; vazio remove."], "cover_time_seconds": ["type": ["number", "null"], "description": "Quadro em segundos; null remove."], "title": ["type": "string"], "text": ["type": "string"], "platforms": platforms, "media_path": ["type": "string"], "media_paths": ["type": "array", "items": ["type": "string"]], "titles": ["type": "object", "additionalProperties": ["type": "string"]], "public_media_url": ["type": "string"], "overrides": ["type": "object", "additionalProperties": ["type": "string"]], "youtube_privacy": ["type": "string", "enum": ["private", "unlisted", "public"]]], required: ["id"]))
        }
        if settings.allowWrite {
            for i in list.indices where ["create_draft", "update_publication"].contains(list[i]["name"] as? String ?? "") {
                if var schema = list[i]["inputSchema"] as? [String: Any], var properties = schema["properties"] as? [String: Any] {
                    let extra: [String: Any] = ["stories": ["type": "boolean"], "tags": ["type": "array", "items": ["type": "string"]], "facebook_page_id": ["type": "string"], "tiktok_privacy": ["type": "string", "enum": ["INBOX", "PUBLIC_TO_EVERYONE", "MUTUAL_FOLLOW_FRIENDS", "FOLLOWER_OF_CREATOR", "SELF_ONLY"]], "tiktok_allow_comments": ["type": "boolean"], "tiktok_allow_duet": ["type": "boolean"], "tiktok_allow_stitch": ["type": "boolean"], "tiktok_disclose": ["type": "boolean"], "tiktok_your_brand": ["type": "boolean"], "tiktok_branded": ["type": "boolean"]]
                    properties.merge(extra) { _, new in new }; schema["properties"] = properties; list[i]["inputSchema"] = schema
                }
            }
        }
        if settings.allowPublish {
            list.append(tool("publish_now", "Inicia a publicação ou repete destinos que falharam no app aberto; acompanhe com get_publication.", ["id": ["type": "string"]], required: ["id"]))
        }
        if settings.allowSchedule {
            list.append(tool("schedule_publication", "Agenda uma publicação. O app a publica automaticamente no horário.", ["id": ["type": "string"], "date": ["type": "string", "description": "ISO 8601, ex.: 2026-11-10T09:30:00-03:00. Sem fuso usa o fuso do workspace."]], required: ["id", "date"]))
            list.append(tool("unschedule_publication", "Cancela um agendamento e devolve a publicação para rascunhos.", ["id": ["type": "string"]], required: ["id"]))
        }
        if settings.allowDelete {
            list.append(tool("delete_publication", "Exclui uma publicação local (não apaga conteúdo já publicado nas redes).", ["id": ["type": "string"]], required: ["id"]))
        }
        return list
    }

    private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    private func call(_ name: String, _ args: [String: Any]) throws -> (payload: Any, summary: String) {
        let settings = AssistantSettings.load()
        guard settings.enabled else { throw AppIssue("O acesso de assistentes está desativado. Ative em Trelune → MCP e assistentes.") }
        store.reloadIfChanged()
        switch name {
        case "get_workspace", "export_backup", "export_csv", "list_connections", "refresh_insights", "get_insights", "validate_publication":
            return (try appRequest(name, args), "Consultou \(name) no aplicativo")
        case "publish_now":
            guard settings.allowPublish else { throw denied() }
            return (try appRequest(name, args), "Iniciou publicação no aplicativo")
        case "import_backup", "update_workspace", "manage_library", "open_connection", "disconnect_account":
            guard settings.allowManage else { throw denied() }
            return (try appRequest(name, args), "Executou \(name) no aplicativo")
        case "list_publications":
            let limit = (args["limit"] as? Int) ?? 50
            let items = store.posts.filter { post in
                (args["status"] as? String).map { post.status == $0 } ?? true && (args["platform"] as? String).map { post.platforms.contains($0) } ?? true
            }.sorted { $0.date > $1.date }.prefix(limit)
            return (items.map(encode), "\(items.count) publicação(ões) listada(s)")
        case "get_publication":
            let post = try find(args)
            return (encode(post), "Consultou “\(post.title)”")
        case "get_overview":
            var counts: [String: Int] = [:]
            for post in store.posts { counts[post.status, default: 0] += 1 }
            let upcoming = store.posts.filter { $0.status == PostStatus.scheduled }.sorted { $0.date < $1.date }.prefix(10).map(encode)
            return (["total": store.posts.count, "by_status": counts, "upcoming": Array(upcoming), "timezone": Workspace.timeZone.identifier, "now": iso(Date())], "Resumo do workspace")
        case "list_media":
            let files = Workspace.mediaLibrary.map { ["path": $0, "name": URL(fileURLWithPath: $0).lastPathComponent, "kind": MediaKind.isVideo($0) ? "video" : "image", "exists": FileManager.default.fileExists(atPath: $0)] as [String: Any] }
            return (files, "\(files.count) mídia(s) listada(s)")
        case "create_draft":
            guard settings.allowWrite else { throw denied() }
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw AppIssue("Informe o título.") }
            var post = Publication(title: title, text: args["text"] as? String ?? "", platforms: try platforms(args["platforms"]), date: Date().addingTimeInterval(3600), status: PostStatus.draft)
            try apply(args, to: &post)
            store.add(post)
            return (encode(post), "Criou o rascunho “\(post.title)”")
        case "duplicate_publication":
            guard settings.allowWrite else { throw denied() }
            var copy = try find(args)
            copy.id = UUID(); copy.title += " (cópia)"; copy.status = PostStatus.draft; copy.results = [:]; copy.cloud = nil; copy.created = Date(); copy.updated = Date()
            if copy.date < Date() { copy.date = Date().addingTimeInterval(3600) }
            store.add(copy)
            return (encode(copy), "Duplicou “\(copy.title)”")
        case "update_publication":
            guard settings.allowWrite else { throw denied() }
            var post = try find(args)
            guard ![PostStatus.publishing, PostStatus.published].contains(post.status) else { throw AppIssue("Publicações enviadas ou em envio não podem ser alteradas.") }
            if let title = args["title"] as? String { post.title = title }
            if let text = args["text"] as? String { post.text = text }
            if args["platforms"] != nil { post.platforms = try platforms(args["platforms"]) }
            try apply(args, to: &post)
            store.update(post)
            return (encode(post), "Alterou “\(post.title)”")
        case "schedule_publication":
            guard settings.allowSchedule else { throw denied() }
            let post = try find(args)
            guard let raw = args["date"] as? String, let date = parseDate(raw) else { throw AppIssue("Data inválida. Use ISO 8601, por exemplo 2026-11-10T09:30:00-03:00.") }
            guard date > Date() else { throw AppIssue("A data precisa estar no futuro.") }
            guard !post.platforms.isEmpty else { throw AppIssue("A publicação não tem destinos.") }
            guard post.status != PostStatus.published && post.status != PostStatus.publishing else { throw AppIssue("Esta publicação já foi enviada.") }
            store.edit(post.id) { $0.date = date; $0.status = PostStatus.scheduled }
            return (encode(store.post(post.id)!), "Agendou “\(post.title)” para \(Workspace.format(date))")
        case "unschedule_publication":
            guard settings.allowSchedule else { throw denied() }
            let post = try find(args)
            guard post.status == PostStatus.scheduled else { throw AppIssue("A publicação não está agendada.") }
            store.status(post.id, PostStatus.draft)
            return (encode(store.post(post.id)!), "Cancelou o agendamento de “\(post.title)”")
        case "delete_publication":
            guard settings.allowDelete else { throw denied() }
            let post = try find(args)
            store.remove(post.id)
            return (["deleted": post.id.uuidString], "Excluiu “\(post.title)”")
        default:
            throw AppIssue("Ferramenta desconhecida: \(name)")
        }
    }

    private func appRequest(_ action: String, _ args: [String: Any]) throws -> Any {
        let dir = AppPaths.support.appendingPathComponent("assistant-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let request = dir.appendingPathComponent(id).appendingPathExtension("request")
        let response = dir.appendingPathComponent(id).appendingPathExtension("response")
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: response) }
        let data = try JSONSerialization.data(withJSONObject: ["action": action, "arguments": args, "expires": Date().timeIntervalSince1970 + 8])
        try data.write(to: request, options: .atomic)
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: response), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard result["ok"] as? Bool == true else { throw AppIssue(result["error"] as? String ?? "Falha no aplicativo.") }
                return result["value"] ?? NSNull()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AppIssue("O Trelune não respondeu. Abra o aplicativo e tente novamente. Se pediu uma publicação, verifique seu status antes de repetir: o resultado pode ser desconhecido.")
    }

    private func apply(_ args: [String: Any], to post: inout Publication) throws {
        if let path = args["media_path"] as? String {
            if path.isEmpty { post.mediaPath = nil }
            else {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else { throw AppIssue("Arquivo de mídia não encontrado: \(path)") }
                post.mediaPath = expanded
            }
        }
        if let paths = args["media_paths"] as? [String] {
            post.media = try paths.map { path in
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else { throw AppIssue("Arquivo de mídia não encontrado: \(path)") }
                return expanded
            }
        }
        if let path = args["cover_path"] as? String {
            if path.isEmpty { post.coverPath = nil }
            else {
                let expanded = (path as NSString).expandingTildeInPath
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &directory), !directory.boolValue, ["jpg", "jpeg", "png"].contains(URL(fileURLWithPath: expanded).pathExtension.lowercased()) else { throw AppIssue("A capa deve ser um arquivo JPEG ou PNG existente.") }
                post.coverPath = expanded
            }
        }
        if args["cover_time_seconds"] is NSNull { post.coverTime = nil }
        else if let time = args["cover_time_seconds"] as? Double {
            guard time.isFinite && time >= 0 else { throw AppIssue("cover_time_seconds deve ser um número não negativo.") }
            post.coverTime = time
        }
        if let titles = args["titles"] as? [String: String] {
            for key in titles.keys where !PostStore.networks.contains(key) { throw AppIssue("Rede desconhecida em titles: \(key)") }
            post.titles = titles
        }
        if let url = args["public_media_url"] as? String {
            if url.isEmpty { post.publicMediaURL = nil } else { guard URL(string: url)?.scheme == "https" else { throw AppIssue("public_media_url precisa ser HTTPS.") }; post.publicMediaURL = url }
        }
        if let overrides = args["overrides"] as? [String: String] {
            for key in overrides.keys where !PostStore.networks.contains(key) { throw AppIssue("Rede desconhecida em overrides: \(key)") }
            post.overrides = overrides
        }
        if let stories = args["stories"] as? Bool { post.stories = stories }
        if let tags = args["tags"] as? [String] { post.tags = tags }
        if let page = args["facebook_page_id"] as? String { post.facebookPageID = page.isEmpty ? nil : page }
        if let privacy = args["tiktok_privacy"] as? String {
            guard ["INBOX", "PUBLIC_TO_EVERYONE", "MUTUAL_FOLLOW_FRIENDS", "FOLLOWER_OF_CREATOR", "SELF_ONLY"].contains(privacy) else { throw AppIssue("tiktok_privacy inválido.") }; post.tiktokPrivacy = privacy
        }
        if let v = args["tiktok_allow_comments"] as? Bool { post.tiktokAllowComments = v }
        if let v = args["tiktok_allow_duet"] as? Bool { post.tiktokAllowDuet = v }
        if let v = args["tiktok_allow_stitch"] as? Bool { post.tiktokAllowStitch = v }
        if let v = args["tiktok_disclose"] as? Bool { post.tiktokDisclose = v }
        if let v = args["tiktok_your_brand"] as? Bool { post.tiktokYourBrand = v }
        if let v = args["tiktok_branded"] as? Bool { post.tiktokBranded = v }
        if let privacy = args["youtube_privacy"] as? String { guard ["private", "unlisted", "public"].contains(privacy) else { throw AppIssue("youtube_privacy inválido.") }; post.youtubePrivacy = privacy }
    }
    private func platforms(_ value: Any?) throws -> [String] {
        guard let list = value as? [String], !list.isEmpty else { throw AppIssue("Informe pelo menos um destino em platforms.") }
        for item in list where !PostStore.networks.contains(item) { throw AppIssue("Rede desconhecida: \(item). Use \(PostStore.networks.joined(separator: ", ")).") }
        return Array(NSOrderedSet(array: list)) as? [String] ?? list
    }
    private func find(_ args: [String: Any]) throws -> Publication {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw), let post = store.post(id) else { throw AppIssue("Publicação não encontrada. Use list_publications para obter o id.") }
        return post
    }
    private func denied() -> AppIssue { AppIssue("Esta ação não foi permitida para assistentes em MCP e assistentes.") }

    private func encode(_ post: Publication) -> [String: Any] {
        var value: [String: Any] = ["id": post.id.uuidString, "title": post.title, "text": post.text, "platforms": post.platforms, "status": post.status, "date": iso(post.date), "date_local": Workspace.format(post.date), "youtube_privacy": post.youtubePrivacy]
        value.merge(["stories": post.stories, "tags": post.tags, "facebook_page_id": post.facebookPageID as Any? ?? NSNull(), "tiktok_privacy": post.tiktokPrivacy, "tiktok_allow_comments": post.tiktokAllowComments, "tiktok_allow_duet": post.tiktokAllowDuet, "tiktok_allow_stitch": post.tiktokAllowStitch, "tiktok_disclose": post.tiktokDisclose, "tiktok_your_brand": post.tiktokYourBrand, "tiktok_branded": post.tiktokBranded]) { _, new in new }
        if !post.media.isEmpty { value["media_paths"] = post.media; value["formats"] = Dictionary(uniqueKeysWithValues: post.platforms.map { ($0, post.format(for: $0)) }) }
        if !post.titles.isEmpty { value["titles"] = post.titles }
        if let path = post.coverPath { value["cover_path"] = path }
        if let time = post.coverTime { value["cover_time_seconds"] = time }
        if let url = post.publicMediaURL { value["public_media_url"] = url }
        if !post.overrides.isEmpty { value["overrides"] = post.overrides }
        if !post.results.isEmpty { value["results"] = post.results.mapValues { ["state": $0.state, "detail": $0.detail, "link": $0.link ?? ""] } }
        return value
    }
    private func iso(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.timeZone = Workspace.timeZone; return f.string(from: date) }
    private func parseDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: raw) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: raw) { return date }
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = Workspace.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] { local.dateFormat = format; if let date = local.date(from: raw) { return date } }
        return nil
    }
    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    private func reply(_ id: Any, _ result: Any) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

// MARK: - Assistants page

struct AssistantsPage: View {
    @EnvironmentObject private var store: PostStore
    @State private var settings = AssistantSettings.load()
    @State private var log: [AssistantLogEntry] = []
    @State private var testResult = ""
    @State private var testing = false
    @State private var notice = ""
    @AppStorage("mcpServerMode") private var mode = "Docker"
    @AppStorage("mcpClient") private var client = "Claude Code"
    @State private var dockerStatus = ""
    @State private var copied = false
    private var snippet: (title: String, code: String, note: String, install: (() -> Void)?) {
        switch client {
        case "Claude Desktop": ("claude_desktop_config.json", jsonServer, "Adicione ao arquivo de configuração e reinicie o Claude Desktop.", { install(json: "Library/Application Support/Claude/claude_desktop_config.json", name: "Claude Desktop") })
        case "OpenAI Codex": ("~/.codex/config.toml", codexToml, "Vale para o Codex no Terminal, no app e na extensão do VS Code.", { installCodex() })
        case "Gemini CLI": ("~/.gemini/settings.json", jsonServer, "Vale para o Gemini CLI e o Gemini Code Assist (modo agente).", { install(json: ".gemini/settings.json", name: "Gemini CLI") })
        default: ("Execute no Terminal", "claude mcp add -s user trelune -- \\\n  \(shellCommand)", "Claude Desktop também pode ser configurado com JSON.", nil)
        }
    }
    private var executable: String { Bundle.main.executablePath ?? "" }
    private var bundled: Bool { executable.contains(".app/Contents/MacOS/") }
    nonisolated static let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/docker"
    /// The command an assistant runs to talk to the server: the always-on Docker container, or this app's binary.
    private var command: (path: String, args: [String]) {
        mode == "Docker" ? (Self.docker, ["exec", "-i", "trelune-mcp", "node", "/app/server.mjs", "--stdio"]) : (executable, ["--mcp"])
    }
    private var shellCommand: String { ([command.path] + command.args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }
    private var jsonServer: String {
        let args = command.args.map { "\"\($0)\"" }.joined(separator: ", ")
        return "{\n  \"mcpServers\": {\n    \"trelune\": {\n      \"command\": \"\(command.path)\",\n      \"args\": [\(args)]\n    }\n  }\n}"
    }
    private var codexToml: String { "[mcp_servers.trelune]\ncommand = \"\(command.path)\"\nargs = [\(command.args.map { "\"\($0)\"" }.joined(separator: ", "))]" }

    @State private var authorizing = false
    private var provider: String { client.hasPrefix("Claude") ? "Anthropic" : client == "OpenAI Codex" ? "OpenAI" : "Google Gemini" }

    var body: some View {
        if authorizing { authorize } else { page }
    }

    // Figma 18 · Conectar assistente
    private var authorize: some View {
        PageScroll(title: "Conectar assistente", subtitle: "Revise o acesso antes de continuar.", action: "") {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Acesso ao workspace", subtitle: "O assistente poderá usar as ações autorizadas neste workspace.", size: 18).padding(.top, 12)
                VStack(alignment: .leading, spacing: 30) {
                    permission("Consultar publicações e mídias", on: true)
                    Button { settings.allowWrite.toggle() } label: { permission("Criar e editar publicações", on: settings.allowWrite) }.buttonStyle(.plain)
                    Button { settings.allowSchedule.toggle() } label: { permission("Preparar agendamentos", on: settings.allowSchedule) }.buttonStyle(.plain)
                    Button { settings.allowManage.toggle() } label: { permission("Gerenciar biblioteca, backup e ajustes", on: settings.allowManage) }.buttonStyle(.plain)
                    Button { settings.allowPublish.toggle() } label: { permission("Publicar imediatamente", on: settings.allowPublish) }.buttonStyle(.plain)
                    Button { settings.allowDelete.toggle() } label: { permission("Excluir publicações", on: settings.allowDelete) }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.vertical, 28).frame(width: 800, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.top, 26)
                Text("Revise as permissões do assistente antes de confirmar. A publicação imediata exige permissão específica.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 34)
                HStack(spacing: 14) {
                    HeaderButton("Autorizar conexão", width: 220) { settings.enabled = true; authorizing = false }
                    HeaderButton("Cancelar", primary: false, width: 150) { authorizing = false }
                }.padding(.top, 22)
            }
        }
    }
    private func permission(_ title: String, on: Bool) -> some View {
        HStack(spacing: 16) { Image(systemName: on ? "checkmark" : "circle").font(.system(size: on ? 11 : 8, weight: .semibold)).frame(width: 14); Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Palette.text : Palette.muted) }.contentShape(Rectangle())
    }

    // Figma 11 / 29–31
    private var page: some View {
        PageScroll(title: "MCP e assistentes", subtitle: "Configure um assistente para usar seu workspace.", action: testing ? "Testando…" : "Testar servidor", primary: false, actionHandler: test) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Acesso de assistentes").font(.system(size: 18, weight: .semibold)).padding(.top, 6)
                HStack {
                    Text("Permitir acesso").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { if settings.enabled { settings.enabled = false } else { authorizing = true } } label: { DotStatus(on: settings.enabled).font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain).padding(.trailing, 100)
                }.padding(.top, 14)
                HStack(spacing: 0) {
                    check("Consultar publicações e biblioteca", on: true) {}
                    check("Criar e editar publicações", on: settings.allowWrite) { settings.allowWrite.toggle() }
                    check("Agendar e cancelar", on: settings.allowSchedule) { settings.allowSchedule.toggle() }
                }.padding(.top, 24)
                check("Gerenciar biblioteca, backup e ajustes", on: settings.allowManage) { settings.allowManage.toggle() }.padding(.top, 12)
                check("Publicar imediatamente", on: settings.allowPublish) { settings.allowPublish.toggle() }.padding(.top, 12)
                Button { settings.allowDelete.toggle() } label: {
                    HStack(spacing: 12) { Text("Excluir publicações").foregroundStyle(Palette.muted); DotStatus(on: settings.allowDelete).foregroundStyle(Palette.muted) }.font(.system(size: 11))
                }.buttonStyle(.plain).padding(.top, 6)
                Separator().padding(.top, 10)
                HStack(alignment: .firstTextBaseline) {
                    Text("Configurar assistente").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Docker · sempre ligado") { mode = "Docker" }
                        Button("App do Mac") { mode = "App" }
                    } label: { Text("Servidor:  \(mode == "Docker" ? "Docker · sempre ligado" : "App do Mac")  ▾").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 100)
                }.padding(.top, 26)
                TabBar(options: [("Anthropic", "Anthropic"), ("OpenAI", "OpenAI"), ("Google Gemini", "Google Gemini")], selection: Binding(get: { provider }, set: { client = $0 == "Anthropic" ? "Claude Code" : $0 == "OpenAI" ? "OpenAI Codex" : "Gemini CLI" })).padding(.top, 18)
                if provider == "Anthropic" {
                    Menu { Button("Claude Code") { client = "Claude Code" }; Button("Claude Desktop") { client = "Claude Desktop" } } label: { Text("\(client)  ▾").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.top, 22)
                } else {
                    Text(client).font(.system(size: 13, weight: .medium)).padding(.top, 22)
                }
                Text(snippet.title).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 22)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(snippet.code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize().padding(.horizontal, 20).padding(.vertical, 22)
                }.frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 14)
                HStack {
                    Text(snippet.note).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    if let install = snippet.install { SecondaryButton("Adicionar à configuração", install) }
                    SecondaryButton(copied ? "Copiado" : "Copiar") { copyToPasteboard(snippet.code); copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false } }
                }.padding(.top, 16)
                if mode == "Docker" { Text(dockerStatus.isEmpty ? "Verificando o contêiner…" : dockerStatus).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 10) }
                else if !bundled { Text("Você está executando o binário de desenvolvimento. Gere o app com script/build_and_run.sh para um caminho estável.").font(.system(size: 11)).foregroundStyle(Palette.warning).padding(.top, 10) }
                if !testResult.isEmpty { Text(testResult).font(.system(size: 12)).foregroundStyle(testResult.hasPrefix("✓") ? Palette.text : Palette.danger).textSelection(.enabled).padding(.top, 10) }
                Separator().padding(.top, 18)
                HStack {
                    Text("Atividade recente").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if !log.isEmpty { TextLink(title: "Limpar") { AssistantLogEntry.clear(); log = [] } }
                }.padding(.top, 26)
                if log.isEmpty { Text("Nenhuma chamada registrada.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 16) }
                ForEach(log.prefix(30)) { entry in
                    RuleRow(height: 44) {
                        Text(entry.tool).font(.system(size: 12, design: .monospaced)).frame(width: 190, alignment: .leading)
                        Text(entry.summary).font(.system(size: 12)).foregroundStyle(entry.ok ? Palette.muted : Palette.danger).lineLimit(1)
                        Spacer()
                        Text(Workspace.format(entry.date)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
            }.padding(.top, -6)
        }
        .onChange(of: settings) { _, value in value.save() }
        .task {
            while !Task.isCancelled {
                log = AssistantLogEntry.load(); store.reloadIfChanged()
                dockerStatus = await Self.containerStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .alert(L("Assistentes"), isPresented: Binding(get: { !notice.isEmpty }, set: { if !$0 { notice = "" } })) { Button("OK") { notice = "" } } message: { Text(notice) }
    }

    private func check(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) { Text(title).foregroundStyle(Palette.muted); Text(on ? "✓" : "○").foregroundStyle(Palette.muted) }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func test() {
        guard !testing else { return }
        testing = true; testResult = ""
        let (path, arguments) = command
        Task {
            let output = await Task.detached { () -> String in
                let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
                let input = Pipe(), output = Pipe(), errors = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = errors
                do { try process.run() } catch { return "erro: \(error.localizedDescription)" }
                let requests = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"self-test","version":"1"}}}"#, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#]
                input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                return text.isEmpty ? problem : text
            }.value
            testing = false
            let lines = output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if let list = lines.first(where: { ($0["id"] as? Int) == 2 }), let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]] {
                testResult = "✓ Servidor respondeu com \(tools.count) ferramenta(s): \(tools.compactMap { $0["name"] as? String }.joined(separator: ", "))."
                if !settings.enabled { testResult += " Ative o acesso para que as chamadas sejam aceitas." }
            } else { testResult = "Falha no teste do servidor MCP. Saída: \(output.prefix(300))" }
        }
    }

    /// Merges the server into a JSON settings file that uses the `mcpServers` key (Claude Desktop, Gemini CLI).
    private func install(json relative: String, name: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
        do {
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppIssue("O arquivo atual do \(name) não é um JSON válido; ajuste manualmente.") }
                root = parsed
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: "post-orchestrator") // entry written before the rename
            servers["trelune"] = ["command": command.path, "args": command.args]
            root["mcpServers"] = servers
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            notice = "Servidor adicionado ao \(name). Reinicie o \(name) para carregá-lo."
        } catch { notice = error.localizedDescription }
    }
    /// Adds or replaces the [mcp_servers.trelune] table in ~/.codex/config.toml, keeping everything else.
    private func installCodex() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n")
        // Also drops the table written before the rename.
        for table in ["[mcp_servers.trelune]", "[mcp_servers.post-orchestrator]"] {
            if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == table }) {
                let end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
                lines.removeSubrange(start..<end)
            }
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        text += (text.isEmpty ? "" : "\n\n") + codexToml + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice = "Servidor adicionado ao Codex (~/.codex/config.toml). Reinicie o Codex para carregá-lo."
        } catch { notice = error.localizedDescription }
    }
    static func containerStatus() async -> String {
        await Task.detached { () -> String in
            let process = Process(); process.executableURL = URL(fileURLWithPath: docker)
            process.arguments = ["inspect", "-f", "{{.State.Status}}", "trelune-mcp"]
            let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
            do { try process.run() } catch { return "Docker não encontrado. Instale com: brew install colima docker docker-compose" }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            if text == "running" { return "Rodando no Docker" }
            return process.terminationStatus == 0 ? "Contêiner parado (\(text)). Rode mcp/install.sh." : "Docker desligado ou contêiner não instalado. Rode mcp/install.sh."
        }.value
    }
}
