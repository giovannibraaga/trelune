import SwiftUI
import AppKit

// MARK: - 03 · Calendário

struct CalendarPage: View {
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var router: Router
    @AppStorage("calendarMode") private var mode = "Mês"
    @State private var anchor = Date()
    private var calendar: Calendar { var c = Workspace.calendar; c.firstWeekday = 2; return c }

    var body: some View {
        PageScroll(title: "Calendário", subtitle: "Seu conteúdo organizado no tempo.", action: "+ Nova publicação", actionHandler: { router.compose() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 22) {
                    Button { shift(-1) } label: { Text("‹") }.buttonStyle(.plain)
                    Text(title).font(.system(size: 18, weight: .semibold)).frame(minWidth: 170)
                    Button { shift(1) } label: { Text("›") }.buttonStyle(.plain)
                    TextLink(title: "Hoje") { anchor = Date() }.padding(.leading, 120)
                    Spacer()
                    HStack(spacing: 18) {
                        ForEach(["Semana", "Mês", "Lista"], id: \.self) { item in
                            Button { mode = item } label: { Text(item).font(.system(size: 13, weight: .medium)).foregroundStyle(mode == item ? Palette.text : Palette.muted) }.buttonStyle(.plain)
                        }
                    }.padding(.trailing, 110)
                }.font(.system(size: 18, weight: .semibold))
                Separator().padding(.top, 18)
                switch mode {
                case "Lista": list
                case "Semana": grid(days: weekDays, height: 420)
                default: grid(days: monthDays, height: 134)
                }
                Text("Horários em \(Workspace.timeZoneLabel).").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 14)
            }.padding(.top, -6)
        }
    }

    private var title: String {
        var style = Date.FormatStyle().month(.wide).year(); style.timeZone = Workspace.timeZone; style.locale = AppLanguage.locale
        let text = anchor.formatted(style).replacingOccurrences(of: " de ", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// Monday first, in the app language ("Seg", "Mon"…).
    private var weekdayNames: [String] { var c = calendar; c.locale = AppLanguage.locale; let names = c.shortWeekdaySymbols; return Array(names[1...] + names[..<1]).map { $0.replacingOccurrences(of: ".", with: "") } }
    private func shift(_ delta: Int) { anchor = calendar.date(byAdding: mode == "Semana" ? .weekOfYear : .month, value: delta, to: anchor) ?? anchor }
    private var weekDays: [Date?] {
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)!.start
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchor), let count = calendar.range(of: .day, in: .month, for: anchor)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let days: [Date?] = Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        return days + Array(repeating: nil, count: (7 - days.count % 7) % 7)
    }
    private func posts(on day: Date) -> [Publication] { store.posts.filter { calendar.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date } }

    private func grid(days: [Date?], height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { ColumnHeader($0.element).padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading) }
            }.frame(height: 56)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in cell(day, height: height) }
            }.overlay(Rectangle().stroke(Palette.stroke))
        }
    }

    private func cell(_ day: Date?, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let day {
                Text("\(calendar.component(.day, from: day))").font(.system(size: 11, weight: calendar.isDateInToday(day) ? .bold : .regular)).foregroundStyle(calendar.isDateInToday(day) ? Palette.text : Palette.muted)
                ForEach(posts(on: day).prefix(height > 200 ? 8 : 2)) { post in
                    Button { router.detail(post.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(Workspace.time(post.date))  \(post.title)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(post.platforms.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                        }.padding(.horizontal, 9).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 8))
                            .opacity(post.status == PostStatus.draft ? 0.55 : 1).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if posts(on: day).count > (height > 200 ? 8 : 2) { Text("+\(posts(on: day).count - 2)").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(day == nil ? Palette.bg : Palette.bg).overlay(Rectangle().stroke(Palette.stroke, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let day { newPost(on: day) } }
    }

    private var list: some View {
        let range = calendar.dateInterval(of: .month, for: anchor)!
        let items = store.posts.filter { range.contains($0.date) }.sorted { $0.date < $1.date }
        return VStack(spacing: 0) {
            if items.isEmpty { Text("Nada neste mês.").font(.system(size: 13)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24) }
            ForEach(items) { post in
                Button { router.detail(post.id) } label: {
                    RuleRow(height: 56) {
                        Text(Workspace.format(post.date, date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 190, alignment: .leading)
                        Text(post.title).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 260, alignment: .leading)
                        Text(PostLabels.status(post.status)).font(.system(size: 12)).frame(width: 110, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func newPost(on day: Date) {
        var date = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
        if date < Date() { date = Date().addingTimeInterval(3600) }
        router.compose(ComposerSeed(date: date))
    }
}

enum PostLabels {
    /// Feminine forms used in the Figma list ("Agendada", "Publicada").
    static func status(_ status: String) -> String {
        switch status {
        case PostStatus.scheduled: "Agendada"
        case PostStatus.published: "Publicada"
        case PostStatus.publishing: "Publicando"
        case PostStatus.partial: "Parcial"
        case PostStatus.failed: "Com falha"
        default: "Rascunho"
        }
    }
    static func result(_ result: PlatformResult?, status: String) -> String {
        guard let result else { return status == PostStatus.draft ? "Rascunho" : status == PostStatus.scheduled ? "Agendada" : "Aguardando" }
        if result.pending { return "Na caixa de entrada" }
        return result.succeeded ? "Publicada" : "Falhou"
    }
    static func short(_ date: Date) -> String {
        "\(Workspace.format(date, date: .abbreviated, time: .omitted).components(separatedBy: " de 20").first?.replacingOccurrences(of: " de ", with: " ").replacingOccurrences(of: ".", with: "") ?? "") · \(Workspace.time(date))"
    }
}

// MARK: - 04 · Publicações

struct Posts: View {
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @State private var filter = "Todas"
    @FocusState private var searching: Bool
    @State private var deleting: Publication?
    private var query: String { router.search }
    private let filters = [("Todas", "Todas"), (PostStatus.scheduled, "Agendadas"), (PostStatus.draft, "Rascunhos"), (PostStatus.published, "Publicadas"), ("Com falha", "Com falha")]
    var visible: [Publication] {
        store.posts.filter { post in
            let statusMatch = filter == "Todas" || post.status == filter || (filter == "Com falha" && [PostStatus.failed, PostStatus.partial].contains(post.status))
            return statusMatch && (query.isEmpty || post.title.localizedCaseInsensitiveContains(query) || post.text.localizedCaseInsensitiveContains(query) || post.platforms.joined().localizedCaseInsensitiveContains(query))
        }.sorted { $0.date > $1.date }
    }
    var body: some View {
        PageScroll(title: "Publicações", subtitle: "Planeje, revise e acompanhe seus conteúdos.", action: "+ Nova publicação", actionHandler: { router.compose() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 14) {
                        ForEach(filters, id: \.0) { item in
                            Button { filter = item.0 } label: { Text(item.1).font(.system(size: 13, weight: .medium)).foregroundStyle(filter == item.0 ? Palette.text : Palette.muted) }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    TextField("", text: $router.search, prompt: Text("Buscar publicação  ⌘K").foregroundStyle(Palette.muted)).textFieldStyle(.plain).font(.system(size: 13)).focused($searching).frame(width: 260)
                }
                Separator().padding(.top, 16)
                HStack(spacing: 0) {
                    ColumnHeader("Conteúdo").frame(maxWidth: .infinity, alignment: .leading)
                    ColumnHeader("Plataformas").frame(width: 310, alignment: .leading)
                    ColumnHeader("Data").frame(width: 210, alignment: .leading)
                    ColumnHeader("Status").frame(width: 120, alignment: .leading)
                }.padding(.top, 22).padding(.bottom, 4)
                if visible.isEmpty { Text(store.posts.isEmpty ? "Nenhuma publicação ainda. Crie a primeira em “Nova publicação”." : "Nada encontrado com este filtro.").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.vertical, 26) }
                ForEach(visible) { post in row(post) }
            }.padding(.top, -6)
        }
        .onAppear { if router.focusSearch { searching = true; router.focusSearch = false } }
        .onChange(of: router.focusSearch) { _, value in if value { searching = true; router.focusSearch = false } }
        .confirmationDialog(L("Excluir “\(deleting?.title ?? "")”?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Excluir", role: .destructive) { if let id = deleting?.id { store.remove(id) }; deleting = nil }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: { Text("A publicação é removida deste Mac. Conteúdo já enviado às redes não é apagado nelas.") }
    }

    private func row(_ post: Publication) -> some View {
        Button { router.detail(post.id) } label: {
            RuleRow(height: 92) {
                HStack(spacing: 20) {
                    Group {
                        if let first = post.media.first { Thumbnail(path: first, size: 60) }
                        else { ZStack { Palette.raised; Text("✦").font(.system(size: 16)) }.frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 9)) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(post.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(post.media.isEmpty ? "Conteúdo" : post.format(for: post.platforms.first ?? "")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).frame(width: 310, alignment: .leading)
                Text(post.status == PostStatus.draft && post.results.isEmpty ? "Sem data" : PostLabels.short(post.date)).font(.system(size: 12)).frame(width: 210, alignment: .leading)
                HStack(spacing: 6) {
                    Text(PostLabels.status(post.status)).font(.system(size: 12))
                    if center.running.contains(post.id) { ProgressView().controlSize(.mini) }
                }.frame(width: 120, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu { PostActions(post: post, deleting: $deleting) }
    }
}

/// Actions available on a publication (context menu in the list, menu in the details page).
struct PostActions: View {
    let post: Publication
    @Binding var deleting: Publication?
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    var body: some View {
        Button("Abrir detalhes") { router.detail(post.id) }
        Button("Editar") { router.edit(post.id) }
        Button(post.status == PostStatus.scheduled ? "Reagendar" : "Agendar") { router.compose(ComposerSeed(postID: post.id, reschedule: true)) }.disabled(post.status == PostStatus.published || center.running.contains(post.id))
        Button(post.status == PostStatus.partial || post.status == PostStatus.failed ? "Tentar novamente" : "Publicar agora") { router.publishNow(post.id) }.disabled(center.running.contains(post.id) || post.status == PostStatus.published)
        Button("Duplicar") { if let copy = store.duplicate(post.id) { router.edit(copy.id) } }
        if post.status == PostStatus.scheduled { Button("Cancelar agendamento") { store.status(post.id, PostStatus.draft) } }
        if post.status != PostStatus.draft && post.status != PostStatus.scheduled { Button("Mover para rascunhos") { store.status(post.id, PostStatus.draft) } }
        Divider()
        Button("Excluir", role: .destructive) { deleting = post }
    }
}

// MARK: - 16 · Detalhes da publicação

struct PostDetail: View {
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @State private var tab = "Visão geral"
    @State private var deleting: Publication?

    var body: some View {
        if let id = router.detailID, let post = store.post(id) {
            PageScroll(title: post.title, subtitle: "Publicação \(PostLabels.status(post.status).lowercased()) · \(Workspace.format(post.date, date: .abbreviated, time: .shortened))",
                       action: post.status == PostStatus.published ? "Duplicar" : post.status == PostStatus.scheduled ? "Editar agendamento" : "Editar publicação",
                       actionHandler: {
                           if post.status == PostStatus.published { if let copy = store.duplicate(post.id) { router.edit(copy.id) } }
                           else if post.status == PostStatus.scheduled { router.compose(ComposerSeed(postID: post.id, reschedule: true)) }
                           else { router.edit(post.id) }
                       }) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        TabBar(options: ["Visão geral", "Informações", "Histórico"].map { ($0, $0) }, selection: $tab)
                        Spacer()
                        Menu { PostActions(post: post, deleting: $deleting) } label: { Text("Mais ações  ▾").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Separator()
                    HStack(alignment: .top, spacing: 60) {
                        VStack(alignment: .leading, spacing: 0) {
                            switch tab {
                            case "Informações": info(post)
                            case "Histórico": historyTab(post)
                            default: overview(post)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        schedulePanel(post).frame(width: 372)
                    }.padding(.top, 30)
                }.padding(.top, -6)
            }
            .confirmationDialog(L("Excluir “\(deleting?.title ?? "")”?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Excluir", role: .destructive) { if let id = deleting?.id { store.remove(id); router.page = "Publicações" }; deleting = nil }
                Button("Cancelar", role: .cancel) { deleting = nil }
            }
        } else {
            PageScroll(title: "Publicação", subtitle: "Esta publicação não existe mais.", action: "Voltar às publicações", actionHandler: { router.page = "Publicações" }) { EmptyView() }
        }
    }

    private func overview(_ post: Publication) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conteúdo").font(.system(size: 18, weight: .semibold))
            Text(post.title).font(.system(size: 14, weight: .medium)).padding(.top, 20)
            Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
            Separator().padding(.vertical, 26)
            Text("Envio por plataforma").font(.system(size: 16, weight: .semibold))
            ForEach(post.platforms, id: \.self) { network in
                let result = post.results[network]
                RuleRow(height: 80) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(network).font(.system(size: 13, weight: .medium))
                        if let result, !result.succeeded || result.pending { Text(result.detail).font(.system(size: 11)).foregroundStyle(result.pending ? Palette.warning : Palette.danger).lineLimit(2).textSelection(.enabled) }
                    }
                    Spacer()
                    if let link = result?.link.flatMap(URL.init(string:)) { Link("Abrir  ↗", destination: link).font(.system(size: 12)).foregroundStyle(Palette.text) }
                    Text(PostLabels.result(result, status: post.status)).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 130, alignment: .leading)
                }
            }
        }
    }

    private func info(_ post: Publication) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ValueBox(label: "Texto", width: nil, height: 80) { Text(post.text.isEmpty ? "—" : post.text).font(.system(size: 13)).padding(.vertical, 12).textSelection(.enabled) }
            ValueBox(label: "Mídia", width: nil) {
                if post.media.isEmpty { Text("Sem mídia") } else {
                    ForEach(post.media.prefix(6), id: \.self) { Thumbnail(path: $0, size: 40) }
                    Text(post.media.count == 1 ? URL(fileURLWithPath: post.media[0]).lastPathComponent : "\(post.media.count) arquivos").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            ValueBox(label: "Formato por destino", width: nil) { Text(post.platforms.map { "\($0) · \(post.format(for: $0))" }.joined(separator: "   ")).font(.system(size: 13)) }
        }
    }

    private func historyTab(_ post: Publication) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RuleRow(height: 52) { Text("Criada").font(.system(size: 13)); Spacer(); Text(Workspace.format(post.created)).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            RuleRow(height: 52) { Text("Última alteração").font(.system(size: 13)); Spacer(); Text(Workspace.format(post.updated)).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            ForEach(post.platforms.filter { post.results[$0] != nil }, id: \.self) { network in
                RuleRow(height: 52) { Text("Envio para \(network)").font(.system(size: 13)); Spacer(); Text(PostLabels.result(post.results[network], status: post.status)).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        }
    }

    private func schedulePanel(_ post: Publication) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agendamento").font(.system(size: 15, weight: .semibold))
            Text(post.status == PostStatus.draft ? "Sem data" : Workspace.format(post.date, date: .abbreviated, time: .omitted)).font(.system(size: 13)).padding(.top, 22)
            Text("\(Workspace.time(post.date)) · \(Workspace.timeZoneLabel.components(separatedBy: " · ").last ?? "")").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
            HStack(spacing: 10) {
                if post.status != PostStatus.published { SecondaryButton(post.status == PostStatus.scheduled ? "Reagendar" : "Agendar") { router.compose(ComposerSeed(postID: post.id, reschedule: true)) } }
                if post.status == PostStatus.failed || post.status == PostStatus.partial { SecondaryButton("Tentar novamente") { router.publishNow(post.id) } }
            }.padding(.top, 30)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
