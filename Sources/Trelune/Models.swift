import Foundation
import Security

// MARK: - Storage locations

enum AppPaths {
    static var support: URL {
        // TRELUNE_DATA_DIR isolates test runs from the real workspace data.
        if let custom = ProcessInfo.processInfo.environment["TRELUNE_DATA_DIR"] {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(AppIdentity.name, isDirectory: true)
        // Data created before the rename lived in "PostOrchestrator"; move it once.
        let legacy = base.appendingPathComponent("PostOrchestrator", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.moveItem(at: legacy, to: url) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var publications: URL { support.appendingPathComponent("publications.json") }
    static var lock: URL { support.appendingPathComponent(".publications.lock") }
    static var assistant: URL { support.appendingPathComponent("assistant.json") }
    static var assistantLog: URL { support.appendingPathComponent("assistant-log.json") }
    static var covers: URL { let url = support.appendingPathComponent("covers", isDirectory: true); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
}

// MARK: - Workspace preferences shared by the app, the scheduler and the MCP server

enum Workspace {
    static let timeZoneKey = "timezone"
    static var timeZone: TimeZone { TimeZone(identifier: UserDefaults.standard.string(forKey: timeZoneKey) ?? "") ?? .current }
    static var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.locale = AppLanguage.locale; calendar.firstWeekday = 1; return calendar }
    static func format(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle = .abbreviated, time timeStyle: Date.FormatStyle.TimeStyle = .shortened) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: timeStyle)
        style.timeZone = timeZone
        style.locale = AppLanguage.locale
        return date.formatted(style)
    }
    /// "18:00" in the workspace time zone.
    static func time(_ date: Date) -> String {
        let c = calendar
        return String(format: "%02d:%02d", c.component(.hour, from: date), c.component(.minute, from: date))
    }
    /// Next full hour, at least 30 minutes ahead: the default time of a new publication.
    static var nextSlot: Date {
        let c = calendar, soon = Date().addingTimeInterval(1800)
        return c.date(bySettingHour: c.component(.hour, from: soon), minute: 0, second: 0, of: soon)?.addingTimeInterval(3600) ?? soon
    }
    static var timeZoneLabel: String {
        let zone = timeZone
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "−" : "+"
        let hours = abs(seconds) / 3600, minutes = (abs(seconds) % 3600) / 60
        return "\(zone.identifier) · UTC\(sign)\(hours)\(minutes == 0 ? "" : String(format: ":%02d", minutes))"
    }
    /// Imported files plus every image or video inside the watched folders.
    static var mediaLibrary: [String] {
        let imported = (UserDefaults.standard.string(forKey: "mediaFiles") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(Set(imported + scannedFolders())).sorted()
    }
    nonisolated(unsafe) private static var scanCache: (key: String, date: Date, files: [String])?
    /// Watched-folder contents, rescanned at most every 20 seconds.
    static func scannedFolders(force: Bool = false) -> [String] {
        let key = libraryFolders.joined(separator: "|")
        if !force, let cache = scanCache, cache.key == key, Date().timeIntervalSince(cache.date) < 20 { return cache.files }
        let files = libraryFolders.flatMap(scan)
        scanCache = (key, Date(), files)
        return files
    }
    /// Folders the library watches (chosen in Biblioteca).
    static var libraryFolders: [String] { (UserDefaults.standard.string(forKey: "libraryFolders") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty } }
    /// Images and videos inside a folder; subfolders starting with "_" (backups, drafts) are skipped.
    static func scan(_ folder: String) -> [String] {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if url.lastPathComponent.hasPrefix("_") { walker.skipDescendants(); continue }
            if MediaKind.isImage(url.path) || MediaKind.isVideo(url.path) { found.append(url.path) }
        }
        return found
    }
}

enum PostStatus {
    static let draft = "Rascunho"
    static let scheduled = "Agendado"
    static let publishing = "Publicando"
    static let published = "Publicado"
    static let partial = "Parcial"
    static let failed = "Falhou"
    static let all = [draft, scheduled, publishing, published, partial, failed]
}

enum MediaKind {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
    static func mime(_ path: String) -> String {
        ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"][URL(fileURLWithPath: path).pathExtension.lowercased()] ?? "application/octet-stream"
    }
    static func isVideo(_ path: String) -> Bool { videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    static func isImage(_ path: String) -> Bool { imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    static func isVideoURL(_ string: String) -> Bool { guard let url = URL(string: string) else { return false }; return videoExtensions.contains(url.pathExtension.lowercased()) }
}

/// Character limits applied by each network to the main text.
enum NetworkLimits {
    static func text(_ network: String) -> Int {
        switch network {
        case "X": 280
        case "Threads": 500
        case "Instagram", "TikTok": 2200
        case "YouTube": 5000
        default: 63_206
        }
    }
    /// Length as each network counts it. X weighs every link as 23 characters and most emoji and
    /// CJK characters as 2 (twitter-text rules); the others count characters.
    static func length(_ text: String, for network: String) -> Int {
        guard network == "X" else { return text.count }
        let links = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)
        let range = NSRange(text.startIndex..., in: text)
        var total = links.numberOfMatches(in: text, range: range) * 23
        let rest = links.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        for character in rest {
            if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) || (character.unicodeScalars.count > 1 && character.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF })) { total += 2; continue }
            for scalar in character.unicodeScalars {
                let v = scalar.value
                total += (v <= 4351 || (8192...8205).contains(v) || (8208...8223).contains(v) || (8242...8247).contains(v)) ? 1 : 2
            }
        }
        return total
    }
    /// Largest image file each network accepts, in bytes.
    static func imageBytes(_ network: String) -> Int64? {
        switch network {
        case "X": 5_000_000
        case "Threads", "Instagram": 8_000_000
        default: nil
        }
    }
}

// MARK: - Publication

struct PlatformResult: Codable, Hashable {
    /// "ok" (published), "inbox" (delivered for the user to finish on the platform) or "failed".
    var state: String
    var detail: String
    var remoteID: String?
    var link: String?
    var date = Date()
    var succeeded: Bool { state == "ok" || state == "inbox" }
    /// Delivered to the platform's inbox: the post only goes live after the user finishes it in the platform's app.
    var pending: Bool { state == "inbox" }
}

extension Publication {
    /// Final status from the per-network results: inbox deliveries keep the post "Parcial" until finished.
    func settledStatus() -> String {
        let done = platforms.filter { results[$0]?.succeeded == true }
        if done.count == platforms.count { return platforms.contains { results[$0]?.pending == true } ? PostStatus.partial : PostStatus.published }
        return done.isEmpty ? PostStatus.failed : PostStatus.partial
    }
}

struct Publication: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    var platforms: [String]
    var date: Date
    var status: String
    /// Ordered local files. Several images form a carousel; the order defines the cover.
    var media: [String] = []
    var publicMediaURL: String?
    /// Per-network caption/description.
    var overrides: [String: String] = [:]
    /// Per-network title (YouTube, TikTok photos, Facebook video).
    var titles: [String: String] = [:]
    var youtubePrivacy = "private"
    var tags: [String] = []
    var facebookPageID: String?
    /// "INBOX" sends to the TikTok inbox for the creator to finish; otherwise a Direct Post privacy level.
    var tiktokPrivacy = "INBOX"
    /// Direct Post interaction and disclosure settings; TikTok requires them off until the user turns them on.
    var tiktokAllowComments = false
    var tiktokAllowDuet = false
    var tiktokAllowStitch = false
    var tiktokDisclose = false
    var tiktokYourBrand = false
    var tiktokBranded = false
    /// Custom cover image, or a frame of the video (seconds) when nil.
    var coverPath: String?
    var coverTime: Double?
    var results: [String: PlatformResult] = [:]
    var created = Date()
    var updated = Date()
    /// Also share Instagram and Facebook posts to Stories.
    var stories = true
    /// Set while the post is scheduled in the cloud (EventBridge Scheduler + Lambda). Matches `updated`/`date`
    /// at the time it was sent, so an edit after that is detected and sent again.
    var cloud: CloudState?

    init(title: String, text: String, platforms: [String], date: Date, status: String, mediaPath: String? = nil, publicMediaURL: String? = nil) {
        self.title = title; self.text = text; self.platforms = platforms; self.date = date; self.status = status
        self.media = mediaPath.map { [$0] } ?? []; self.publicMediaURL = publicMediaURL
    }

    func text(for network: String) -> String {
        if let custom = overrides[network], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return custom }
        return text
    }
    func title(for network: String) -> String {
        if let custom = titles[network], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return custom }
        return title
    }
    func isCustomized(_ network: String) -> Bool {
        !(overrides[network] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || !(titles[network] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// First media file (kept for single-media code paths).
    var mediaPath: String? {
        get { media.first }
        set { if let newValue { if media.isEmpty { media = [newValue] } else { media[0] = newValue } } else { media = [] } }
    }
    var mediaURL: URL? { mediaPath.map { URL(fileURLWithPath: $0) } }
    var images: [String] { media.filter(MediaKind.isImage) }
    var videos: [String] { media.filter(MediaKind.isVideo) }

    /// Human readable format chosen automatically from the media for a network.
    func format(for network: String) -> String {
        let images = images.count, videos = videos.count
        if media.isEmpty { return network == "YouTube" ? "Vídeo" : "Texto" }
        if videos == 1 && images == 0 {
            switch network { case "Instagram": return "Reels"; case "Facebook": return "Reel"; case "YouTube": return "Vídeo"; default: return "Vídeo" }
        }
        if images == 1 && videos == 0 { return network == "TikTok" ? "Fotos" : network == "Instagram" || network == "Facebook" ? "Post" : "Imagem" }
        switch network {
        case "TikTok": return "Fotos · \(media.count)"
        case "X": return "Imagens · \(media.count)"
        case "Facebook": return "Álbum · \(media.count)"
        default: return "Carrossel · \(media.count)"
        }
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, platforms, date, status, media, mediaPath, publicMediaURL, overrides, titles, youtubePrivacy, tags, facebookPageID, tiktokPrivacy, tiktokAllowComments, tiktokAllowDuet, tiktokAllowStitch, tiktokDisclose, tiktokYourBrand, tiktokBranded, coverPath, coverTime, results, created, updated, stories, cloud }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Sem título"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        platforms = try c.decodeIfPresent([String].self, forKey: .platforms) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? PostStatus.draft
        if let list = try c.decodeIfPresent([String].self, forKey: .media) { media = list }
        else if let single = try c.decodeIfPresent(String.self, forKey: .mediaPath) { media = [single] }
        publicMediaURL = try c.decodeIfPresent(String.self, forKey: .publicMediaURL)
        overrides = try c.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        titles = try c.decodeIfPresent([String: String].self, forKey: .titles) ?? [:]
        youtubePrivacy = try c.decodeIfPresent(String.self, forKey: .youtubePrivacy) ?? "private"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        facebookPageID = try c.decodeIfPresent(String.self, forKey: .facebookPageID)
        tiktokPrivacy = try c.decodeIfPresent(String.self, forKey: .tiktokPrivacy) ?? "INBOX"
        tiktokAllowComments = try c.decodeIfPresent(Bool.self, forKey: .tiktokAllowComments) ?? true
        tiktokAllowDuet = try c.decodeIfPresent(Bool.self, forKey: .tiktokAllowDuet) ?? false
        tiktokAllowStitch = try c.decodeIfPresent(Bool.self, forKey: .tiktokAllowStitch) ?? false
        tiktokDisclose = try c.decodeIfPresent(Bool.self, forKey: .tiktokDisclose) ?? false
        tiktokYourBrand = try c.decodeIfPresent(Bool.self, forKey: .tiktokYourBrand) ?? false
        tiktokBranded = try c.decodeIfPresent(Bool.self, forKey: .tiktokBranded) ?? false
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        coverTime = try c.decodeIfPresent(Double.self, forKey: .coverTime)
        results = try c.decodeIfPresent([String: PlatformResult].self, forKey: .results) ?? [:]
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? date
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? date
        stories = try c.decodeIfPresent(Bool.self, forKey: .stories) ?? true
        cloud = try c.decodeIfPresent(CloudState.self, forKey: .cloud)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(text, forKey: .text)
        try c.encode(platforms, forKey: .platforms); try c.encode(date, forKey: .date); try c.encode(status, forKey: .status)
        try c.encode(media, forKey: .media); try c.encodeIfPresent(publicMediaURL, forKey: .publicMediaURL)
        try c.encode(overrides, forKey: .overrides); try c.encode(titles, forKey: .titles)
        try c.encode(youtubePrivacy, forKey: .youtubePrivacy); try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(facebookPageID, forKey: .facebookPageID)
        try c.encode(tiktokPrivacy, forKey: .tiktokPrivacy); try c.encode(tiktokAllowComments, forKey: .tiktokAllowComments)
        try c.encode(tiktokAllowDuet, forKey: .tiktokAllowDuet); try c.encode(tiktokAllowStitch, forKey: .tiktokAllowStitch)
        try c.encode(tiktokDisclose, forKey: .tiktokDisclose); try c.encode(tiktokYourBrand, forKey: .tiktokYourBrand); try c.encode(tiktokBranded, forKey: .tiktokBranded)
        try c.encodeIfPresent(coverPath, forKey: .coverPath); try c.encodeIfPresent(coverTime, forKey: .coverTime)
        try c.encode(results, forKey: .results); try c.encode(created, forKey: .created); try c.encode(updated, forKey: .updated)
        try c.encode(stories, forKey: .stories); try c.encodeIfPresent(cloud, forKey: .cloud)
    }
}

struct CloudState: Codable, Hashable {
    var revision: String
    var updated: Date
    var date: Date
}

// MARK: - Store (JSON file shared with the MCP server process)

@MainActor final class PostStore: ObservableObject {
    static let networks = ["YouTube", "Instagram", "Facebook", "TikTok", "Threads", "X"]
    @Published private(set) var posts: [Publication] = []
    @Published var lastError = ""
    private let file: URL
    private let lockFile: URL
    private var loadedStamp: Date?

    init(file: URL = AppPaths.publications, lockFile: URL = AppPaths.lock) {
        self.file = file; self.lockFile = lockFile
        if FileManager.default.fileExists(atPath: file.path) {
            load()
        } else if let data = UserDefaults.standard.data(forKey: "publications"), let saved = try? JSONDecoder().decode([Publication].self, from: data) {
            // One-time migration from the previous UserDefaults storage.
            posts = saved
            withFileLock { write() }
        }
    }

    func post(_ id: UUID) -> Publication? { posts.first { $0.id == id } }

    @discardableResult func add(_ post: Publication) -> Publication {
        mutate { $0.insert(post, at: 0) }
        return post
    }
    @discardableResult func add(title: String, text: String, platforms: [String], date: Date, status: String) -> Publication {
        add(Publication(title: title, text: text, platforms: platforms, date: date, status: status))
    }
    func update(_ post: Publication) {
        mutate { posts in
            var post = post; post.updated = Date()
            if let index = posts.firstIndex(where: { $0.id == post.id }) { posts[index] = post } else { posts.insert(post, at: 0) }
        }
    }
    func edit(_ id: UUID, _ change: (inout Publication) -> Void) {
        mutate { posts in
            guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
            change(&posts[index]); posts[index].updated = Date()
        }
    }
    func remove(_ id: UUID) {
        mutate { posts in
            if let post = posts.first(where: { $0.id == id }), post.cloud != nil { CloudTombstones.add(id) }
            posts.removeAll { $0.id == id }
        }
    }
    /// Records the cloud schedule state without touching `updated`, which the cloud state is compared against.
    func setCloud(_ id: UUID, _ state: CloudState?) {
        mutate { posts in if let index = posts.firstIndex(where: { $0.id == id }) { posts[index].cloud = state } }
    }
    func status(_ id: UUID, _ status: String) { edit(id) { $0.status = status } }
    func duplicate(_ id: UUID) -> Publication? {
        guard var copy = post(id) else { return nil }
        copy.id = UUID(); copy.title += " (cópia)"; copy.status = PostStatus.draft; copy.results = [:]; copy.created = Date(); copy.updated = Date()
        if copy.date < Date() { copy.date = Date().addingTimeInterval(3600) }
        return add(copy)
    }
    func removeAll() { mutate { $0.removeAll() } }
    func replaceAll(with items: [Publication]) { mutate { $0 = items } }

    /// Picks up changes written by the MCP server process.
    func reloadIfChanged() {
        guard let stamp = modificationDate(), stamp != loadedStamp else { return }
        withFileLock { load() }
    }

    private func mutate(_ change: (inout [Publication]) -> Void) {
        withFileLock {
            if let stamp = modificationDate(), stamp != loadedStamp { load() }
            var next = posts
            change(&next)
            posts = next
            write()
        }
    }
    private func load() {
        do {
            let data = try Data(contentsOf: file)
            posts = try JSONDecoder().decode([Publication].self, from: data)
            loadedStamp = modificationDate()
        } catch { lastError = "Não foi possível ler as publicações salvas: \(error.localizedDescription)" }
    }
    private func write() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(posts).write(to: file, options: .atomic)
            loadedStamp = modificationDate()
        } catch { lastError = "Não foi possível salvar as publicações: \(error.localizedDescription)" }
    }
    private func modificationDate() -> Date? { (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date }
    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        // flock does not cross into the Docker VM, so the MCP container and the app also share a directory lock.
        let directory = file.deletingLastPathComponent().appendingPathComponent(".publications.lockdir").path
        let owned = DirectoryLock.acquire(directory)
        defer { if owned { rmdir(directory) } }
        return try body()
    }
}

/// mkdir-based lock that works across the Mac and the Docker VM (virtiofs). Stale locks expire after 30 s.
enum DirectoryLock {
    static func acquire(_ path: String) -> Bool {
        for _ in 0..<100 {
            if mkdir(path, 0o700) == 0 { return true }
            if let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date, Date().timeIntervalSince(created) > 30 { rmdir(path); continue }
            usleep(50_000)
        }
        return false
    }
}

/// Posts deleted while scheduled in the cloud; their schedules are cancelled on the next sync (app or MCP).
enum CloudTombstones {
    static var file: URL { AppPaths.support.appendingPathComponent("cloud-cancel.json") }
    static func load() -> [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [] }
    static func add(_ id: UUID) { save(Array(Set(load() + [id.uuidString]))) }
    static func remove(_ id: String) { save(load().filter { $0 != id }) }
    private static func save(_ ids: [String]) { try? JSONEncoder().encode(ids.sorted()).write(to: file, options: .atomic) }
}

/// Settings the MCP container needs, written by the app (it cannot read the app's UserDefaults or Keychain).
enum SharedWorkspace {
    static var file: URL { AppPaths.support.appendingPathComponent("workspace.json") }
    @MainActor static func write(cloudPublishing: Bool) {
        let value: [String: Any] = ["timeZone": Workspace.timeZone.identifier, "cloudPublishing": cloudPublishing,
                                    "library": Workspace.mediaLibrary, "libraryFolders": Workspace.libraryFolders]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: - Assistant (MCP) permissions, shared with the MCP server process

struct AssistantSettings: Codable, Equatable {
    var enabled = false
    var allowWrite = true
    var allowSchedule = false
    var allowDelete = false

    static func load() -> AssistantSettings {
        guard let data = try? Data(contentsOf: AppPaths.assistant), let value = try? JSONDecoder().decode(AssistantSettings.self, from: data) else { return AssistantSettings() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { try? data.write(to: AppPaths.assistant, options: .atomic) } }
}

struct AssistantLogEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var tool: String
    var ok: Bool
    var summary: String

    static func load() -> [AssistantLogEntry] {
        guard let data = try? Data(contentsOf: AppPaths.assistantLog), let items = try? JSONDecoder().decode([AssistantLogEntry].self, from: data) else { return [] }
        return items
    }
    static func append(_ entry: AssistantLogEntry) {
        var items = load(); items.insert(entry, at: 0)
        if let data = try? JSONEncoder().encode(Array(items.prefix(200))) { try? data.write(to: AppPaths.assistantLog, options: .atomic) }
    }
    static func clear() { try? FileManager.default.removeItem(at: AppPaths.assistantLog) }
}

// MARK: - Keychain

struct KeychainSlot: Sendable {
    let service: String
    var account = "oauth"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func read() throws -> Data? {
        var query = query; query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AppIssue("Não foi possível ler as credenciais no Chaves do macOS (código \(status)).") }
        return item as? Data
    }
    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AppIssue("Não foi possível salvar as credenciais no Chaves do macOS.") }
        } else if status != errSecSuccess { throw AppIssue("Não foi possível atualizar as credenciais no Chaves do macOS.") }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppIssue("Não foi possível remover as credenciais locais.") }
    }
}

struct AppIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Random {
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppIssue("Não foi possível iniciar uma autorização segura.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
