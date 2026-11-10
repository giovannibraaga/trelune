import Foundation

/// A piece of content returned by a network API, normalized for the overview.
struct ContentItem: Identifiable {
    var id: String { "\(network)-\(remoteID)" }
    let network: String
    let remoteID: String
    let title: String
    let kind: String
    let thumbnail: String?
    let link: String?
    let date: Date?
    let views: Int?
    var likes: Int? = nil
    var comments: Int? = nil
    var shares: Int? = nil
    var interactions: Int { (likes ?? 0) + (comments ?? 0) + (shares ?? 0) }
}

/// Totals for one network in the selected period.
struct NetworkSummary: Identifiable {
    let network: String
    var id: String { network }
    var connected: Bool
    var followers: Int?
    var posts = 0
    var views: Int?
    var likes: Int?
    var comments: Int?
    var shares: Int?
}

struct Metric {
    var value: Int?
    var previous: Int?
    var sources: [String] = []
    var change: Double? { guard let value, let previous, previous > 0 else { return nil }; return Double(value - previous) / Double(previous) }
}

struct Attention: Identifiable { let id = UUID(); let network: String; let text: String }

enum APIDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        let meta = DateFormatter(); meta.locale = Locale(identifier: "en_US_POSIX"); meta.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return meta.date(from: raw)
    }
}

/// Aggregates real data from the connected networks. Disconnected networks contribute nothing.
@MainActor struct Insights {
    let center: PublishingCenter
    let network: String
    let days: Int
    private func includes(_ name: String) -> Bool { (network == "Todas" || network == name) && center.isConnected(name) }
    private var now: Date { Date() }
    private var start: Date { now.addingTimeInterval(-Double(days) * 86400) }
    private var previousStart: Date { now.addingTimeInterval(-Double(days * 2) * 86400) }

    var items: [ContentItem] {
        var list: [ContentItem] = []
        if includes("YouTube") {
            list += center.youtube.recentVideos.map { ContentItem(network: "YouTube", remoteID: $0.id, title: $0.title, kind: "Vídeo", thumbnail: $0.thumbnail, link: "https://youtu.be/\($0.id)", date: $0.published, views: $0.views, likes: $0.likes, comments: $0.comments) }
        }
        if includes("Facebook") {
            list += center.meta.pagePosts.values.flatMap { $0 }.map { post in
                ContentItem(network: "Facebook", remoteID: post.id, title: post.message ?? "Publicação", kind: post.full_picture == nil ? "Texto" : "Post", thumbnail: post.full_picture, link: post.permalink_url, date: APIDate.parse(post.created_time), views: center.meta.postViews[post.id], likes: post.reactions?.summary?.total_count, comments: post.comments?.summary?.total_count, shares: post.shares?.count ?? 0)
            }
        }
        if includes("Instagram") {
            list += center.meta.instagramMedia.map { media in
                let kind = ["CAROUSEL_ALBUM": "Carrossel", "VIDEO": "Reel", "IMAGE": "Post"][media.media_type ?? ""] ?? "Post"
                return ContentItem(network: "Instagram", remoteID: media.id, title: media.caption?.components(separatedBy: "\n").first ?? kind, kind: kind, thumbnail: media.thumbnail_url ?? media.media_url, link: media.permalink, date: APIDate.parse(media.timestamp), views: center.meta.postViews[media.id], likes: media.like_count, comments: media.comments_count)
            }
        }
        if includes("TikTok") {
            list += center.tiktok.videos.map { video in
                ContentItem(network: "TikTok", remoteID: video.id, title: video.title?.isEmpty == false ? video.title! : (video.video_description ?? "Vídeo"), kind: "Vídeo", thumbnail: video.cover_image_url, link: video.share_url, date: video.create_time.map { Date(timeIntervalSince1970: Double($0)) }, views: video.view_count, likes: video.like_count, comments: video.comment_count, shares: video.share_count)
            }
        }
        if includes("Threads") {
            list += center.threads.recent.map { post in
                let stats = center.threads.postStats[post.id]
                return ContentItem(network: "Threads", remoteID: post.id, title: post.text ?? "Publicação", kind: post.media_type == "CAROUSEL_ALBUM" ? "Carrossel" : post.media_type == "TEXT_POST" ? "Texto" : "Post", thumbnail: post.thumbnail_url ?? post.media_url, link: post.permalink, date: APIDate.parse(post.timestamp), views: stats?.views, likes: stats?.likes, comments: stats?.replies, shares: stats?.reposts)
            }
        }
        if includes("X") {
            list += center.x.recent.map { tweet in
                let m = tweet.public_metrics
                return ContentItem(network: "X", remoteID: tweet.id, title: tweet.text, kind: "Post", thumbnail: nil, link: "https://x.com/\(center.x.username)/status/\(tweet.id)", date: APIDate.parse(tweet.created_at), views: m?.impression_count, likes: m?.like_count, comments: m?.reply_count, shares: m?.retweet_count)
            }
        }
        return list
    }

    private func window(_ from: Date, _ to: Date) -> [ContentItem] { items.filter { ($0.date ?? .distantPast) >= from && ($0.date ?? .distantPast) < to } }
    private var youtubeDays: [YouTubeDay] { includes("YouTube") ? center.youtube.days : [] }

    /// Sum of a per-item value over items in the period, per network; YouTube uses Analytics when available.
    private func metric(_ value: (ContentItem) -> Int?, youtube: ((YouTubeDay) -> Int)?) -> Metric {
        var metric = Metric()
        for name in PostStore.networks where includes(name) {
            if name == "YouTube", let youtube, !youtubeDays.isEmpty {
                metric.value = (metric.value ?? 0) + youtubeDays.filter { $0.date >= start }.map(youtube).reduce(0, +)
                metric.previous = (metric.previous ?? 0) + youtubeDays.filter { $0.date >= previousStart && $0.date < start }.map(youtube).reduce(0, +)
                metric.sources.append(name); continue
            }
            let all = items.filter { $0.network == name }
            guard all.contains(where: { value($0) != nil }) else { continue }
            metric.value = (metric.value ?? 0) + window(start, now).filter { $0.network == name }.compactMap(value).reduce(0, +)
            metric.previous = (metric.previous ?? 0) + window(previousStart, start).filter { $0.network == name }.compactMap(value).reduce(0, +)
            metric.sources.append(name)
        }
        return metric
    }
    var views: Metric { metric({ $0.views }, youtube: { $0.views }) }
    var likes: Metric { metric({ $0.likes }, youtube: { $0.likes }) }
    var comments: Metric { metric({ $0.comments }, youtube: { $0.comments }) }
    var interactions: Metric { metric({ $0.likes == nil && $0.comments == nil && $0.shares == nil ? nil : $0.interactions }, youtube: { $0.likes + $0.comments }) }

    var summaries: [NetworkSummary] {
        PostStore.networks.filter { network == "Todas" || network == $0 }.map { name in
            var row = NetworkSummary(network: name, connected: center.isConnected(name))
            guard row.connected else { return row }
            let scoped = Insights(center: center, network: name, days: days)
            row.followers = scoped.followers.value
            row.posts = window(start, now).filter { $0.network == name }.count
            row.views = scoped.views.value; row.likes = scoped.likes.value; row.comments = scoped.comments.value
            let shares = window(start, now).filter { $0.network == name }.compactMap(\.shares)
            row.shares = shares.isEmpty ? nil : shares.reduce(0, +)
            return row
        }
    }

    var followers: Metric {
        var metric = Metric()
        func add(_ name: String, _ value: Int?) { guard includes(name), let value else { return }; metric.value = (metric.value ?? 0) + value; metric.sources.append(name) }
        add("YouTube", center.youtube.channel.isEmpty ? nil : Int(center.youtube.subscribers))
        add("Instagram", center.meta.instagram.isEmpty ? nil : center.meta.instagram.compactMap(\.followersCount).reduce(0, +))
        add("Facebook", center.meta.pages.compactMap(\.followers).isEmpty ? nil : center.meta.pages.compactMap(\.followers).reduce(0, +))
        add("TikTok", center.tiktok.stats?.follower_count)
        add("Threads", center.threads.followers)
        add("X", center.x.followers)
        return metric
    }
    /// Subscribers gained in the period (only YouTube reports history).
    var newFollowers: Int? { youtubeDays.isEmpty ? nil : youtubeDays.filter { $0.date >= start }.map(\.subscribers).reduce(0, +) }

    var published: Metric {
        let networks = Set(items.map(\.network))
        return Metric(value: networks.isEmpty ? nil : window(start, now).count, previous: window(previousStart, start).count, sources: Array(networks).sorted())
    }

    /// Daily views (YouTube Analytics) for the period and the period before, aligned by day index.
    var viewSeries: (current: [(Date, Int)], previous: [(Date, Int)]) {
        guard !youtubeDays.isEmpty else { return ([], []) }
        let current = youtubeDays.filter { $0.date >= start }.map { ($0.date, $0.views) }
        let previous = youtubeDays.filter { $0.date >= previousStart && $0.date < start }.map { ($0.date.addingTimeInterval(Double(days) * 86400), $0.views) }
        return (current, previous)
    }

    /// Daily series for the period and the same days of the previous period (for the dashed comparison).
    /// YouTube contributes its daily analytics; the other networks contribute each post on its publication day.
    func trend(_ metric: String) -> (current: [(Date, Int)], previous: [(Date, Int)]) {
        let calendar = Workspace.calendar
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: Int] = [:]
        switch metric {
        case "Publicações":
            for post in center.store.posts where [PostStatus.published, PostStatus.partial].contains(post.status) && (network == "Todas" || post.platforms.contains(network)) {
                byDay[calendar.startOfDay(for: post.date), default: 0] += 1
            }
        default:
            let interactions = metric == "Interações"
            for day in youtubeDays { byDay[calendar.startOfDay(for: day.date), default: 0] += interactions ? day.likes + day.comments : day.views }
            for item in items where item.network != "YouTube" || youtubeDays.isEmpty {
                guard let date = item.date else { continue }
                byDay[calendar.startOfDay(for: date), default: 0] += interactions ? item.interactions : (item.views ?? 0)
            }
        }
        let range = (0..<days).compactMap { calendar.date(byAdding: .day, value: -($0), to: today) }.reversed()
        let current = range.map { ($0, byDay[$0] ?? 0) }
        let previous = range.map { day in (day, calendar.date(byAdding: .day, value: -days, to: day).flatMap { byDay[$0] } ?? 0) }
        return (current, previous)
    }

    var highlights: [ContentItem] {
        let recent = window(start, now)
        return Array((recent.isEmpty ? items : recent).sorted { ($0.views ?? 0) + $0.interactions * 10 > ($1.views ?? 0) + $1.interactions * 10 }.prefix(5))
    }

    var attention: [Attention] {
        var list: [Attention] = []
        if center.isConnected("YouTube") && !center.youtube.analyticsNote.isEmpty { list.append(Attention(network: "YouTube", text: center.youtube.analyticsNote)) }
        for problem in center.meta.loadErrors { list.append(Attention(network: "Meta", text: problem)) }
        if center.isConnected("Facebook") && center.meta.fieldFallbacks.contains(where: { $0.contains("pages_read_user_content") }) { list.append(Attention(network: "Facebook", text: "Curtidas e comentários do Facebook exigem a permissão pages_read_user_content no token.")) }
        if (center.isConnected("Instagram") || center.isConnected("Facebook")) && !center.meta.insightsAvailable { list.append(Attention(network: "Meta", text: "Para ver visualizações do Instagram e do Facebook, gere o token também com instagram_manage_insights e read_insights.")) }
        if center.meta.connected && center.meta.pages.isEmpty { list.append(Attention(network: "Facebook", text: "Token conectado sem Páginas. Use Conexões → Facebook → Buscar Páginas.")) }
        if center.isConnected("TikTok") && !center.tiktok.canReadStats { list.append(Attention(network: "TikTok", text: "Autorize as métricas (seguidores e vídeos) em Conexões.")) }
        if !center.isConnected("YouTube") && center.youtube.configured { list.append(Attention(network: "YouTube", text: "Credenciais salvas, falta autorizar a conta.")) }
        if !center.isConnected("TikTok") && center.tiktok.configured { list.append(Attention(network: "TikTok", text: "Credenciais salvas, falta autorizar a conta.")) }
        if center.meta.configured && !center.meta.connected { list.append(Attention(network: "Facebook", text: "App Meta configurado, falta conectar.")) }
        if center.x.configured && !center.x.connected { list.append(Attention(network: "X", text: "Credenciais salvas, falta autorizar a conta.")) }
        for post in center.store.posts where post.date > now.addingTimeInterval(-7 * 86400) {
            for network in post.platforms where post.results[network]?.pending == true {
                list.append(Attention(network: network, text: "“\(post.title)” está na caixa de entrada do \(network): abra o app do \(network) e conclua a publicação."))
            }
        }
        if !center.host.configured && (center.isConnected("Instagram") || center.isConnected("Threads") || center.isConnected("TikTok")) { list.append(Attention(network: "Hospedagem", text: "Configure a hospedagem S3 para carrosséis no Instagram, Threads e fotos no TikTok.")) }
        return list
    }
}

func compact(_ value: Int) -> String {
    let number = Double(value)
    let format: (Double, String) -> String = { v, suffix in
        let formatter = NumberFormatter(); formatter.locale = AppLanguage.locale; formatter.maximumFractionDigits = v < 10 ? 2 : 1
        return (formatter.string(from: NSNumber(value: v)) ?? "\(v)") + suffix
    }
    if abs(number) >= 1_000_000 { return format(number / 1_000_000, " mi") }
    if abs(number) >= 10_000 { return format(number / 1_000, " mil") }
    return formatted(value)
}
