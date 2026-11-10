import SwiftUI
import AppKit

/// Template image of the Trelune mark for the menu bar.
struct MenuBarIcon: View {
    private static let image: NSImage? = {
        guard let source = Bundle.main.image(forResource: "TreluneMark") else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in source.draw(in: rect); return true }
        image.isTemplate = true
        return image
    }()
    var body: some View {
        if let image = Self.image { Image(nsImage: image) } else { Image(systemName: "circle.hexagonpath") }
    }
}

/// Menu bar panel (Figma 54 agenda · 55 empty · 56 attention).
struct MenuBarPanel: View {
    @EnvironmentObject private var store: PostStore
    @EnvironmentObject private var center: PublishingCenter
    @EnvironmentObject private var router: Router
    @Environment(\.openWindow) private var openWindow
    @AppStorage("workspaceName") private var workspaceName = L("Workspace pessoal")
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

    private var upcoming: [Publication] { store.posts.filter { $0.status == PostStatus.scheduled && $0.date > Date().addingTimeInterval(-60) }.sorted { $0.date < $1.date } }
    /// First publication that failed, or a connection that lost its authorization.
    private var attention: (title: String, detail: String, action: () -> Void)? {
        if let post = store.posts.filter({ $0.status == PostStatus.failed || $0.status == PostStatus.partial }).max(by: { $0.updated < $1.updated }), Date().timeIntervalSince(post.updated) < 3 * 86400,
           let network = post.platforms.first(where: { post.results[$0].map { !$0.succeeded && !$0.pending } ?? false }) {
            return (L("Falha ao publicar no %@").replacingOccurrences(of: "%@", with: network), post.title, { open { router.detail(post.id) } })
        }
        for network in PostStore.networks where configuredButDisconnected(network) {
            return (L("Conexão com %@ expirada").replacingOccurrences(of: "%@", with: network), L("Autorize novamente para retomar os envios."), { open { router.page = "Conexões"; router.dialog = .reconnect(network) } })
        }
        return nil
    }
    private func configuredButDisconnected(_ network: String) -> Bool {
        switch network {
        case "YouTube": center.youtube.configured && !center.isConnected(network)
        case "TikTok": center.tiktok.configured && !center.tiktok.connected
        case "X": center.x.configured && !center.x.connected
        case "Instagram": center.meta.configured && !center.meta.connected
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppLogo(size: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trelune").font(.system(size: 15, weight: .semibold))
                    Text(workspaceName).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Menu {
                    Button("Ajustes") { open { router.page = "Ajustes" } }
                    Button("Calendário") { open { router.page = "Calendário" } }
                    Button("Conexões") { open { router.page = "Conexões" } }
                    Divider()
                    Button("Sair do Trelune") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Separator().padding(.top, 16)
            if let attention {
                ColumnHeader("Precisa de atenção").padding(.top, 18)
                VStack(alignment: .leading, spacing: 10) {
                    Text(attention.title).font(.system(size: 13, weight: .semibold))
                    Text(attention.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    Button(action: attention.action) { Text("Revisar conexão  ↗").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain).padding(.top, 10)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 14)
                if let next = upcoming.first {
                    ColumnHeader("Próxima publicação").padding(.top, 22)
                    item(next, chevron: false).padding(.top, 6)
                }
            } else {
                HStack {
                    ColumnHeader("Próximas publicações")
                    Spacer()
                    if !upcoming.isEmpty { Button { open { router.page = "Calendário" } } label: { Text("Ver todas  ↗").font(.system(size: 11)).foregroundStyle(Palette.muted) }.buttonStyle(.plain) }
                }.padding(.top, 18)
                if upcoming.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.system(size: 16, weight: .light)).foregroundStyle(Palette.muted)
                        Text("Nenhum agendamento").font(.system(size: 13, weight: .semibold))
                        Text("Suas próximas publicações aparecem aqui.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity).frame(height: 150).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 14)
                } else {
                    ForEach(Array(upcoming.prefix(3).enumerated()), id: \.element.id) { index, post in
                        item(post, chevron: true)
                        if index < min(upcoming.count, 3) - 1 { Separator() }
                    }
                }
                HStack(spacing: 8) { Circle().fill(Palette.secondary).frame(width: 7, height: 7); Text("Agenda ativa").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary) }.padding(.top, 22)
                Text(!center.lastMessage.isEmpty ? center.lastMessage : upcoming.isEmpty ? "Pronto para sua próxima ideia" : center.cloud.active ? "Envio automático pela nuvem" : "Envio automático disponível")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).padding(.top, 8)
            }
            Separator().padding(.top, 18)
            Button { open { router.compose() } } label: {
                Text("＋  Nova publicação").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.bg).frame(maxWidth: .infinity).frame(height: 36).background(Palette.accent).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.top, 14)
            HStack {
                Button { open {} } label: { Text("Abrir Trelune").font(.system(size: 13)) }.buttonStyle(.plain)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Text("Sair").font(.system(size: 13)).foregroundStyle(Palette.muted) }.buttonStyle(.plain).keyboardShortcut("q")
            }.padding(.top, 16)
        }
        .padding(20).frame(width: 380).background(Palette.panel)
        .foregroundStyle(Palette.text)
        .onAppear { Appearance.apply() }
    }

    private func item(_ post: Publication, chevron: Bool) -> some View {
        Button { open { router.detail(post.id) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dayLabel(post.date)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    Text(post.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer()
                if chevron { Text("›").foregroundStyle(Palette.muted) }
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Workspace.calendar
        let day: String
        if calendar.isDateInToday(date) { day = L("Hoje") }
        else if calendar.isDateInTomorrow(date) { day = L("Amanhã") }
        else { var style = Date.FormatStyle().day().month(.abbreviated); style.timeZone = Workspace.timeZone; style.locale = AppLanguage.locale; day = date.formatted(style).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " de ", with: " ") }
        return "\(day) · \(Workspace.time(date))".uppercased(with: AppLanguage.locale)
    }

    private func open(_ then: () -> Void) {
        then()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
