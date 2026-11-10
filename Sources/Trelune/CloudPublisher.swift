import Foundation
import CryptoKit

/// Hands scheduled posts to the cloud publisher (EventBridge Scheduler → Lambda) so they go out with the Mac off.
/// Media and texts go to s3://bucket/scheduled/<id>/, connection credentials to SSM Parameter Store, and the
/// results come back from scheduled/<id>/result.json.
@MainActor final class CloudPublisher: ObservableObject {
    static let enabledKey = "cloudPublishing"
    static let functionKey = "cloudFunctionArn"
    static let roleKey = "cloudSchedulerRoleArn"
    /// Connection credentials mirrored to the cloud, by Keychain service.
    static let vaults = ["youtube", "meta", "tiktok", "threads", "x"]

    let host: MediaHost
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); if enabled { lastVaultSync = .distantPast } } }
    @Published private(set) var message = ""
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// Called after credentials were refreshed in the cloud and copied back to the Keychain.
    var onCredentialsPulled: ((String) async -> Void)?

    /// Media keys already uploaded per post (an optimization; the S3 copy is the source of truth).
    private var uploaded: [String: [String]] { didSet { UserDefaults.standard.set(uploaded, forKey: "cloudUploaded") } }
    private var vaultState: [String: String] { didSet { UserDefaults.standard.set(vaultState, forKey: "cloudVault") } }
    private var lastVaultSync = Date.distantPast
    /// Explicit ARNs (Ajustes) win; otherwise they are built from the AWS account of the configured key
    /// and the resource names created by cloud/deploy.sh.
    private func override(_ key: String) -> String? { UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
    private func function() async throws -> String {
        if let value = override(Self.functionKey) { return value }
        return "arn:aws:lambda:\(host.config?.region ?? "us-east-1"):\(try await account()):function:\(CloudNames.functionName)"
    }
    private func role() async throws -> String {
        if let value = override(Self.roleKey) { return value }
        return "arn:aws:iam::\(try await account()):role/\(CloudNames.schedulerRole)"
    }
    /// AWS account of the upload key (STS GetCallerIdentity needs no IAM permission), cached per key.
    private func account() async throws -> String {
        let keyID = host.config?.accessKey ?? ""
        let cached = (UserDefaults.standard.string(forKey: CloudNames.accountKey) ?? "").split(separator: "|").map(String.init)
        if cached.count == 2, cached[0] == keyID { return cached[1] }
        let result = try await host.aws("POST", service: "sts", body: Data("Action=GetCallerIdentity&Version=2011-06-15".utf8), headers: ["content-type": "application/x-www-form-urlencoded"])
        let body = String(decoding: result.data, as: UTF8.self)
        guard result.status == 200, let start = body.range(of: "<Account>"), let end = body.range(of: "</Account>") else { throw AppIssue("Não foi possível identificar a conta AWS da chave configurada (HTTP \(result.status)).") }
        let id = String(body[start.upperBound..<end.lowerBound])
        UserDefaults.standard.set("\(keyID)|\(id)", forKey: CloudNames.accountKey)
        return id
    }
    private weak var store: PostStore?

    init(host: MediaHost) {
        self.host = host
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        uploaded = UserDefaults.standard.dictionary(forKey: "cloudUploaded") as? [String: [String]] ?? [:]
        vaultState = UserDefaults.standard.dictionary(forKey: "cloudVault") as? [String: String] ?? [:]
    }

    func attach(_ store: PostStore) { self.store = store }
    var active: Bool { enabled && host.configured }
    /// True when the cloud owns publishing this post, so the Mac must not publish it too.
    func manages(_ id: UUID) -> Bool { store?.post(id)?.cloud != nil }
    var scheduledCount: Int { store?.posts.filter { $0.cloud != nil }.count ?? 0 }
    private func current(_ post: Publication) -> Bool { post.cloud.map { $0.updated == post.updated && $0.date == post.date } ?? false }
    private func base(_ id: UUID) -> String { "scheduled/\(id.uuidString)/" }
    private func scheduleName(_ id: UUID) -> String { "po-\(id.uuidString.lowercased())" }

    /// One pass: mirror credentials, push new or edited schedules, cancel removed ones and collect results.
    func sync(store: PostStore, problems: (Publication) -> [String: String]) async {
        self.store = store
        guard !syncing else { return }
        syncing = true; defer { syncing = false }
        let now = Date()
        SharedWorkspace.write(cloudPublishing: enabled)
        shareKeyWithMCP()
        if active, now.timeIntervalSince(lastVaultSync) > 300 {
            lastVaultSync = now
            await syncVault()
        }
        guard host.configured else { return }
        // Posts deleted while scheduled in the cloud (here or through the MCP container).
        for key in CloudTombstones.load() {
            guard let id = UUID(uuidString: key) else { CloudTombstones.remove(key); continue }
            if await deleteRemote(id) { CloudTombstones.remove(key) }
        }
        for post in store.posts where post.cloud != nil {
            let due = post.date <= now && [PostStatus.scheduled, PostStatus.publishing].contains(post.status)
            if due { await collect(post, store: store); continue }
            // Unscheduled, turned into a draft, or cloud publishing switched off: take it back.
            if post.status != PostStatus.scheduled || !enabled { await cancel(post.id, store: store) }
        }
        guard active else { return }
        for post in store.posts where post.status == PostStatus.scheduled && post.date > now && !current(post) {
            // Too close to the time to replace the cloud copy safely: let the Mac publish it.
            if post.date.timeIntervalSince(now) < 60 { if post.cloud != nil { await cancel(post.id, store: store) }; continue }
            // Destinations with a configuration problem stay with the Mac, which reports them as today.
            if !problems(post).isEmpty { if post.cloud != nil { await cancel(post.id, store: store) }; continue }
            do {
                let revision = try await push(post)
                store.setCloud(post.id, CloudState(revision: revision, updated: post.updated, date: post.date))
                message = "“\(post.title)” agendado na nuvem para \(Workspace.format(post.date))."
            } catch {
                message = "Não foi possível agendar “\(post.title)” na nuvem: \(error.localizedDescription) O Mac publica este post se estiver ligado."
                if post.cloud != nil { await cancel(post.id, store: store) }
            }
        }
        lastSync = Date()
    }

    // MARK: Posts

    func push(_ post: Publication) async throws -> String {
        let id = post.id, folder = base(id)
        var keys: [String] = []
        var sent = Set(uploaded[id.uuidString] ?? [])
        func send(_ path: String, name: String) async throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let fingerprint = SigV4.sha256(Data("\(path)|\((attributes[.size] as? NSNumber)?.int64Value ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)".utf8)).prefix(12)
            let key = "\(folder)media/\(name)-\(fingerprint).\(URL(fileURLWithPath: path).pathExtension.lowercased())"
            if !sent.contains(key) {
                message = "Enviando \(URL(fileURLWithPath: path).lastPathComponent) para a nuvem…"
                try await host.putObject(file: URL(fileURLWithPath: path), key: key)
                sent.insert(key); uploaded[id.uuidString] = Array(sent)
            }
            return key
        }
        for (index, path) in post.media.enumerated() { keys.append(try await send(path, name: String(index))) }
        var cover: String?, coverIsFrame = false
        if let path = post.coverPath, FileManager.default.fileExists(atPath: path) { cover = try await send(path, name: "cover") }
        else if let time = post.coverTime, let video = post.videos.first {
            cover = try await send(try await CoverFrame.export(video: video, at: time), name: "frame"); coverIsFrame = true
        }
        let pending = post.platforms.filter { post.results[$0]?.succeeded != true }
        let revision = UUID().uuidString
        var payload: [String: Any] = [
            "id": id.uuidString, "revision": revision, "title": post.title, "text": post.text, "platforms": pending,
            "texts": Dictionary(uniqueKeysWithValues: pending.map { ($0, post.text(for: $0)) }),
            "titles": Dictionary(uniqueKeysWithValues: pending.map { ($0, post.title(for: $0)) }),
            "media": keys.map { ["key": $0] }, "coverIsFrame": coverIsFrame, "stories": post.stories,
            "youtubePrivacy": post.youtubePrivacy, "tags": post.tags, "tiktokPrivacy": post.tiktokPrivacy, "tiktokAllowComments": post.tiktokAllowComments,
            "tiktokAllowDuet": post.tiktokAllowDuet, "tiktokAllowStitch": post.tiktokAllowStitch,
            "tiktokYourBrand": post.tiktokDisclose && post.tiktokYourBrand, "tiktokBranded": post.tiktokDisclose && post.tiktokBranded,
            "date": ISO8601DateFormatter().string(from: post.date),
        ]
        if let cover { payload["cover"] = ["key": cover] }
        if let time = post.coverTime { payload["coverTimeMs"] = Int(time * 1000) }
        if let page = post.facebookPageID { payload["facebookPageID"] = page }
        try await host.putObject(try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), key: "\(folder)post.json", contentType: "application/json")
        try await host.deleteObject("\(folder)result.json")
        try await schedule(id, at: post.date, revision: revision)
        return revision
    }

    private func schedule(_ id: UUID, at date: Date, revision: String) async throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = Workspace.timeZone; formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["postId": id.uuidString, "revision": revision]), as: UTF8.self)
        let targetArn = try await function(), roleArn = try await role()
        let body = try JSONSerialization.data(withJSONObject: [
            "ScheduleExpression": "at(\(formatter.string(from: date)))", "ScheduleExpressionTimezone": Workspace.timeZone.identifier,
            "FlexibleTimeWindow": ["Mode": "OFF"], "ActionAfterCompletion": "DELETE", "Description": AppIdentity.name, "ClientToken": revision,
            "Target": ["Arn": targetArn, "RoleArn": roleArn, "Input": input, "RetryPolicy": ["MaximumRetryAttempts": 0, "MaximumEventAgeInSeconds": 3600]],
        ])
        let path = "/schedules/\(scheduleName(id))"
        var result = try await host.aws("PUT", service: "scheduler", path: path, body: body, headers: ["content-type": "application/json"])
        if result.status == 404 { result = try await host.aws("POST", service: "scheduler", path: path, body: body, headers: ["content-type": "application/json"]) }
        guard (200..<300).contains(result.status) else { throw AppIssue("O EventBridge Scheduler recusou o agendamento: \(Self.awsError(result.data, status: result.status)).") }
    }

    /// Takes a post back from the cloud (for example before publishing it now from the Mac).
    func release(_ id: UUID) async { if let store, store.post(id)?.cloud != nil { await cancel(id, store: store) } }
    private func cancel(_ id: UUID, store: PostStore) async {
        if await deleteRemote(id) { store.setCloud(id, nil) }
    }
    /// Deletes the schedule and the uploaded files. Returns false when AWS could not be reached.
    private func deleteRemote(_ id: UUID) async -> Bool {
        do {
            let result = try await host.aws("DELETE", service: "scheduler", path: "/schedules/\(scheduleName(id))", query: ["clientToken": UUID().uuidString])
            guard (200..<300).contains(result.status) || result.status == 404 else { throw AppIssue(Self.awsError(result.data, status: result.status)) }
            try await host.deleteObject("\(base(id))post.json")
            for key in uploaded[id.uuidString] ?? [] { try? await host.deleteObject(key) }
            uploaded[id.uuidString] = nil
            return true
        } catch { message = "Não foi possível cancelar o agendamento na nuvem: \(error.localizedDescription)"; return false }
    }

    private struct CloudResult: Decodable {
        struct Item: Decodable { let state: String; let detail: String; let remoteID: String?; let link: String? }
        let status: String; let results: [String: Item]; let finished: String?
    }
    private func collect(_ post: Publication, store: PostStore) async {
        guard let data = try? await host.getObject("\(base(post.id))result.json"), let result = try? JSONDecoder().decode(CloudResult.self, from: data) else {
            if Date().timeIntervalSince(post.date) > 30 * 60 {
                store.edit(post.id) { item in
                    item.status = PostStatus.failed; item.cloud = nil
                    for network in item.platforms where item.results[network]?.succeeded != true { item.results[network] = PlatformResult(state: "failed", detail: "A nuvem não respondeu no horário. Confira os registros da Lambda \(CloudNames.functionName) no CloudWatch.") }
                }
                Notifier.post(title: "Falha ao publicar", body: "“\(post.title)”: a nuvem não respondeu.", failure: true)
            }
            return
        }
        let finished = result.finished != nil
        store.edit(post.id) { item in
            for (network, value) in result.results { item.results[network] = PlatformResult(state: value.state, detail: value.detail, remoteID: value.remoteID, link: value.link) }
            item.status = finished ? result.status : PostStatus.publishing
            if finished { item.cloud = nil }
        }
        guard finished else { return }
        uploaded[post.id.uuidString] = nil
        for name in ["post.json", "result.json"] { try? await host.deleteObject("\(base(post.id))\(name)") }
        let ok = result.status == PostStatus.published
        let pending = result.results.filter { $0.value.state == "inbox" }.map(\.key).sorted()
        Notifier.post(title: ok ? (pending.isEmpty ? "Publicação enviada" : "Falta concluir no \(pending.joined(separator: ", "))") : "Falha ao publicar",
                      body: "“\(post.title)” \(ok ? (pending.isEmpty ? "publicado pela nuvem" : "foi para a caixa de entrada do \(pending.joined(separator: ", ")); abra o app para concluir") : "teve falhas na nuvem: \(result.results.filter { $0.value.state == "failed" }.map(\.key).sorted().joined(separator: ", "))").", failure: !ok || !pending.isEmpty)
    }

    // MARK: Credentials

    /// The always-on MCP container schedules in the cloud on its own; it gets the upload-only key while cloud
    /// publishing is on (file readable only by this user), and loses it when it is switched off.
    private func shareKeyWithMCP() {
        let file = AppPaths.support.appendingPathComponent("mcp-aws.json")
        guard active, let config = host.config else { try? FileManager.default.removeItem(at: file); return }
        var value = ["bucket": config.bucket, "region": config.region, "accessKey": config.accessKey, "secretKey": config.secretKey, "prefix": config.prefix]
        // The container builds the same ARNs; explicit ones from Ajustes are passed along.
        value["resourcePrefix"] = CloudNames.prefix
        if let cached = UserDefaults.standard.string(forKey: CloudNames.accountKey)?.split(separator: "|").last { value["account"] = String(cached) }
        if let arn = override(Self.functionKey) { value["functionArn"] = arn }
        if let arn = override(Self.roleKey) { value["roleArn"] = arn }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), (try? Data(contentsOf: file)) != data else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Mirrors each connection between the Keychain and SSM. The side that changed since the last sync wins;
    /// tokens refreshed by the Lambda come back to the Mac so both keep working.
    func syncVault() async {
        for name in Self.vaults {
            let slot = KeychainSlot(service: AppIdentity.keychainService(name))
            guard let local = try? await Task.detached(operation: { try slot.read() }).value else { continue }
            let localHash = SigV4.sha256(local)
            let known = (vaultState[name] ?? "").split(separator: "|").map(String.init)
            let knownVersion = known.first.flatMap(Int.init), knownHash = known.count > 1 ? known[1] : ""
            do {
                let cloud = try await getParameter(name)
                if let cloud, cloud.version != knownVersion, localHash == knownHash {
                    let data = Data(cloud.value.utf8)
                    try await Task.detached(operation: { try slot.write(data) }).value
                    vaultState[name] = "\(cloud.version)|\(SigV4.sha256(data))"
                    await onCredentialsPulled?(name)
                } else if cloud == nil || localHash != knownHash {
                    let version = try await putParameter(name, value: String(decoding: local, as: UTF8.self))
                    vaultState[name] = "\(version)|\(localHash)"
                }
            } catch { message = "Não foi possível sincronizar a conexão \(name) com a nuvem: \(error.localizedDescription)" }
        }
    }
    private func ssm(_ action: String, _ body: [String: Any]) async throws -> (data: Data, status: Int) {
        try await host.aws("POST", service: "ssm", body: try JSONSerialization.data(withJSONObject: body), headers: ["content-type": "application/x-amz-json-1.1", "x-amz-target": "AmazonSSM.\(action)"])
    }
    private func getParameter(_ name: String) async throws -> (value: String, version: Int)? {
        let result = try await ssm("GetParameter", ["Name": CloudNames.vaultPath + name, "WithDecryption": true])
        if result.status == 400, String(decoding: result.data, as: UTF8.self).contains("ParameterNotFound") { return nil }
        guard result.status == 200, let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any], let parameter = json["Parameter"] as? [String: Any],
              let value = parameter["Value"] as? String, let version = parameter["Version"] as? Int else { throw AppIssue(Self.awsError(result.data, status: result.status)) }
        return (value, version)
    }
    private func putParameter(_ name: String, value: String) async throws -> Int {
        let result = try await ssm("PutParameter", ["Name": CloudNames.vaultPath + name, "Value": value, "Type": "SecureString", "Overwrite": true, "Tier": "Intelligent-Tiering"])
        guard result.status == 200, let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any], let version = json["Version"] as? Int else { throw AppIssue(Self.awsError(result.data, status: result.status)) }
        return version
    }
    private static func awsError(_ data: Data, status: Int) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["message"] as? String) ?? (json?["Message"] as? String) ?? (json?["__type"] as? String)
        return message.map { "\($0) (HTTP \(status))" } ?? "HTTP \(status)"
    }

    /// Settings action: sends every scheduled post and all connections now.
    func syncNow(store: PostStore, problems: (Publication) -> [String: String]) async {
        lastVaultSync = .distantPast
        await sync(store: store, problems: problems)
        if active, message.isEmpty || message.hasPrefix("“") { message = "Sincronizado: \(scheduledCount) post(s) agendado(s) na nuvem e conexões atualizadas." }
    }
}
