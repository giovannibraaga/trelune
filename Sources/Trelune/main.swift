import SwiftUI
import AppKit

// `Trelune --mcp` runs the stdio MCP server used by assistants; otherwise the macOS app starts.
if CommandLine.arguments.contains("--mcp") {
    MCPServer().run()
    exit(0)
}
// Settings and connections from earlier builds (Post Orchestrator) are copied once, before anything reads them.
LegacyImport.runIfNeeded()
TreluneApp.main()

/// Owns every long-lived object so the scheduler keeps running while windows open and close.
@MainActor final class AppModel: ObservableObject {
    let store = PostStore()
    let youtube = YouTubeConnection()
    let meta = MetaConnection()
    let tiktok = TikTokConnection()
    let threads = ThreadsConnection()
    let x = XConnection()
    let host = MediaHost()
    let router = Router()
    let center: PublishingCenter
    init() {
        center = PublishingCenter(store: store, youtube: youtube, meta: meta, tiktok: tiktok, threads: threads, x: x, host: host)
        // A publication interrupted while sending (app quit or crash) is settled from the results already recorded.
        // Inbox deliveries are not live yet: older versions marked such posts as published.
        for post in store.posts where post.status == PostStatus.published && post.platforms.contains(where: { post.results[$0]?.pending == true }) { store.status(post.id, PostStatus.partial) }
        for post in store.posts where post.status == PostStatus.publishing && !center.cloud.manages(post.id) {
            store.edit(post.id) { post in
                for network in post.platforms where post.results[network] == nil { post.results[network] = PlatformResult(state: "failed", detail: "Envio interrompido. Use Publicar agora para tentar novamente.") }
                post.status = post.settledStatus()
            }
        }
        center.start()
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["TRELUNE_CLOUD_CHECK"] { checkCloud(to: directory) }
        else if let file = ProcessInfo.processInfo.environment["TRELUNE_HOST_CHECK"], let directory = ProcessInfo.processInfo.environment["TRELUNE_SNAPSHOT_DIR"] { checkHosting(file, to: directory) }
        else if let directory = ProcessInfo.processInfo.environment["TRELUNE_SNAPSHOT_DIR"] { captureSnapshots(to: directory) }
        #endif
    }

    #if DEBUG
    /// Development aid: mirrors the connections to the cloud and schedules a post with no destinations
    /// (nothing is published) to exercise S3, EventBridge Scheduler and the Lambda end to end.
    private func checkCloud(to directory: String) {
        Task { @MainActor in
            var report: [String: String] = [:]
            for _ in 0..<60 where center.loadingConnections { try? await Task.sleep(for: .seconds(1)) }
            await center.cloud.syncVault()
            report["vault"] = center.cloud.message.isEmpty ? "ok" : center.cloud.message
            var post = Publication(title: "Teste da nuvem (sem redes)", text: "Teste", platforms: [], date: Date().addingTimeInterval(150), status: PostStatus.scheduled)
            post.media = ProcessInfo.processInfo.environment["TRELUNE_CLOUD_MEDIA"].map { [$0] } ?? []
            do { _ = try await center.cloud.push(post); report["schedule"] = "ok \(post.id.uuidString) \(Workspace.format(post.date))" } catch { report["schedule"] = error.localizedDescription }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("cloud-check.json")) }
            NSApp.terminate(nil)
        }
    }
    /// Development aid: sends a file through the media host, checks the public link and lets Meta process it without publishing.
    private func checkHosting(_ file: String, to directory: String) {
        Task { @MainActor in
            var report: [String: String] = [:]
            for _ in 0..<60 where center.loadingConnections { try? await Task.sleep(for: .seconds(1)) }
            do {
                let started = Date()
                let link = try await host.publicURL(for: file)
                report["url"] = link; report["uploadSeconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
                let again = Date(); _ = try await host.publicURL(for: file)
                report["secondCallSeconds"] = String(format: "%.2f", Date().timeIntervalSince(again))
                if meta.connected {
                    do { report["instagramContainer"] = "FINISHED \(try await meta.probeInstagram(url: link, asReel: MediaKind.isVideo(file)))" }
                    catch { report["instagramContainer"] = "ERRO: \(error.localizedDescription)" }
                } else { report["instagramContainer"] = "Meta não conectada" }
            } catch { report["error"] = error.localizedDescription }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("host-check.json")) }
            NSApp.terminate(nil)
        }
    }
    /// Development aid: renders every page of the real window to PNG files, then quits.
    private func captureSnapshots(to directory: String) {
        let pages = ["Visão geral", "Métricas", "Calendário", "Publicações", "Biblioteca", "Conexões", "MCP e assistentes", "Ajustes", "Detalhes",
                     "destinations", "format", "individual", "content", "unified", "customize", "media", "review", "destinationsReview", "moment", "confirmNow", "scheduled", "cover", "dlg-choose", "dlg-YouTube", "dlg-X", "dlg-TikTok", "dlg-Threads", "dlg-Instagram", "dlg-manage", "dlg-disconnect", "menubar"]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["TRELUNE_SNAPSHOT_WAIT"] ?? "8") ?? 8))
            let sample = store.posts.first { $0.media.count > 0 && $0.platforms.count > 1 }?.id ?? store.posts.first?.id
            for (index, page) in pages.enumerated() {
                switch page {
                case "Detalhes": if let sample { router.detail(sample) }
                case "dlg-choose": router.page = "Conexões"; router.dialog = .choose
                case "dlg-manage": router.dialog = .manage("YouTube")
                case "dlg-disconnect": router.dialog = .disconnect("YouTube")
                case let name where name.hasPrefix("dlg-"): router.dialog = .setup(String(name.dropFirst(4)))
                case "menubar":
                    router.dialog = nil
                    let host = NSHostingView(rootView: MenuBarPanel().environmentObject(store).environmentObject(center).environmentObject(router))
                    host.frame = NSRect(x: 0, y: 0, width: 380, height: 620)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host; window.orderFrontRegardless()
                    try? await Task.sleep(for: .seconds(1.5))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "%02d-menubar.png", index)))
                    }
                    window.orderOut(nil); continue
                case let step where step.first?.isLowercase == true: router.compose(ComposerSeed(postID: ["destinations", "format"].contains(step) ? nil : sample, startStep: step))
                default: router.page = page
                }
                try? await Task.sleep(for: .seconds(2.5))
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "%02d-%@.png", index, page)))
            }
            NSApp.terminate(nil)
        }
    }
    #endif
}

struct ComposerSeed: Equatable {
    var token = UUID()
    var postID: UUID?
    var date: Date?
    var mediaPath: String?
    /// Several library files in order (carousel).
    var mediaPaths: [String] = []
    var reschedule = false
    var publishNow = false
    /// Development aid (snapshots): opens the composer directly at a step.
    var startStep: String?
}

@MainActor final class Router: ObservableObject {
    @Published var page = "Visão geral"
    @Published var composer = ComposerSeed()
    @Published var connection: String?
    @Published var search = ""
    /// Set by ⌘K; Publicações focuses its search field and clears it.
    @Published var focusSearch = false
    func compose(_ seed: ComposerSeed = ComposerSeed()) { composer = seed; page = "Criar publicação" }
    func edit(_ id: UUID) { compose(ComposerSeed(postID: id)) }
    /// Publication details (Figma 16).
    @Published var detailID: UUID?
    func detail(_ id: UUID) { detailID = id; page = "Detalhes" }
    /// Opens the "Publicar agora?" confirmation (Figma 35) for an existing publication.
    func publishNow(_ id: UUID) { compose(ComposerSeed(postID: id, publishNow: true)) }
    /// Connection dialog shown over the whole window (Figma 42–53).
    @Published var dialog: ConnectionDialog?
    func connect(_ network: String) { page = "Conexões"; dialog = .setup(network) }
}

struct TreluneApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Trelune", id: "main") {
            AppShell()
                .environmentObject(model.store).environmentObject(model.youtube).environmentObject(model.tiktok)
                .environmentObject(model.meta).environmentObject(model.threads).environmentObject(model.x)
                .environmentObject(model.center).environmentObject(model.router).environmentObject(model.host)
        }
        .windowStyle(.titleBar).defaultSize(width: 1440, height: 960)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Nova publicação") { model.router.compose() }.keyboardShortcut("n")
            }
        }
        MenuBarExtra {
            MenuBarPanel().environmentObject(model.store).environmentObject(model.center).environmentObject(model.router)
        } label: { MenuBarIcon() }
        .menuBarExtraStyle(.window)
    }
}

struct AppShell: View {
    @EnvironmentObject private var store: PostStore
    @EnvironmentObject private var router: Router
    @AppStorage("workspaceName") private var workspaceName = L("Workspace pessoal")
    @AppStorage("userName") private var userName = NSFullUserName()
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    // Order and glyphs from the Figma navigation.
    // SF Symbols that say what each section holds.
    private let nav = [("square.grid.2x2", "Visão geral"), ("calendar", "Calendário"), ("rectangle.stack", "Publicações"), ("photo.on.rectangle.angled", "Biblioteca"), ("chart.bar.xaxis", "Métricas"), ("link", "Conexões"), ("sparkles", "MCP e assistentes")]

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Group {
                switch router.page {
                case "Visão geral": Overview()
                case "Métricas": Metrics()
                case "Calendário": CalendarPage()
                case "Publicações": Posts()
                case "Biblioteca": Library()
                case "Conexões": Connections()
                case "MCP e assistentes": AssistantsPage()
                case "Ajustes": SettingsPage()
                case "Detalhes": PostDetail()
                default: Composer(seed: router.composer).id(router.composer.token)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.bg)
        }
        .overlay { ConnectionDialogs(dialog: $router.dialog) }
        .background(Palette.bg).foregroundStyle(Palette.text).tint(Palette.accent)
        .background { Button("") { router.page = "Publicações"; router.focusSearch = true }.keyboardShortcut("k").opacity(0).allowsHitTesting(false) }
        .onAppear { Appearance.apply(); InstallMetrics.start() }
        .onChange(of: appearance) { _, _ in Appearance.apply() }
        .alert(AppIdentity.name, isPresented: Binding(get: { !store.lastError.isEmpty }, set: { if !$0 { store.lastError = "" } })) { Button("OK") { store.lastError = "" } } message: { Text(store.lastError) }
    }

    private var initials: String { userName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    /// Composer pages belong to Publicações in the navigation.
    private var section: String { ["Visão geral", "Métricas", "Calendário", "Publicações", "Biblioteca", "Conexões", "MCP e assistentes", "Ajustes"].contains(router.page) ? router.page : "Publicações" }

    private func navItem(_ icon: String, _ title: String) -> some View {
        let selected = section == title
        return Button { router.page = title } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 14, weight: .regular)).symbolRenderingMode(.monochrome).frame(width: 20)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Palette.text : Palette.muted)
            .padding(.horizontal, 13).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(selected ? Palette.raised : .clear).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                AppLogo(size: 34)
                Text("trelune").font(.system(size: 24, weight: .semibold)).tracking(-0.3)
            }.padding(.leading, 12).padding(.top, 40)
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted).padding(.leading, 12).padding(.top, 40).padding(.bottom, 4)
            ForEach(nav, id: \.1) { navItem($0.0, $0.1) }
            Spacer(minLength: 16)
            Separator().padding(.horizontal, 12).padding(.bottom, 12)
            navItem("gearshape", "Ajustes")
            HStack(spacing: 12) {
                Text(initials.isEmpty ? "?" : initials).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.bg)
                    .frame(width: 34, height: 34).background(Palette.accent).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(userName.isEmpty ? "Seu nome" : userName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(workspaceName).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }.padding(.leading, 12).padding(.top, 14).padding(.bottom, 32)
        }.padding(.horizontal, 16).frame(maxHeight: .infinity).background(Palette.sidebar)
    }
}
