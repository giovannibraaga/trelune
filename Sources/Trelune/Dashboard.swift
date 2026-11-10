import SwiftUI
import AppKit

/// Shared body of Visão geral (Figma 01) and Métricas (Figma 02).
struct DashboardBody: View {
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var router: Router
    @Binding var network: String
    @Binding var days: Int
    @Binding var chartMetric: String
    var metrics: [(String, Metric)]
    var showsFooter: Bool
    var tableTitle = "Desempenho por rede"
    var upperCaseHeaders = true

    var body: some View {
        let data = Insights(center: center, network: network, days: days)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TabBar(options: [("Todas", "Todas")] + PostStore.networks.map { ($0, $0) }, selection: $network)
                Spacer()
                Menu {
                    ForEach([7, 30, 90], id: \.self) { value in Button("Últimos \(value) dias") { days = value } }
                } label: { Text("Últimos \(days) dias  ▾").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Separator().padding(.top, 8)
            if network != "Todas" && !center.isConnected(network) {
                HStack { Text("\(network) não está conectada.").font(.system(size: 13)).foregroundStyle(Palette.muted); TextLink(title: "Conectar  ↗", muted: false) { router.connect(network) }; Spacer() }.padding(.top, 18)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Separator(vertical: true).frame(height: 74).padding(.horizontal, 40) }
                    metric(item.0, item.1)
                }
            }.padding(.vertical, 24)
            Separator()
            HStack(alignment: .firstTextBaseline) {
                Text("Evolução no período").font(.system(size: 18, weight: .semibold))
                Spacer()
                let trend = data.trend(chartMetric)
                legend("Atual", compact(trend.current.map(\.1).reduce(0, +)), Palette.text)
                legend("Anterior", compact(trend.previous.map(\.1).reduce(0, +)), Palette.muted).padding(.leading, 34)
            }.padding(.top, 28)
            TabBar(options: ["Visualizações", "Interações", "Publicações"].map { ($0, $0) }, selection: $chartMetric, size: 12).padding(.top, 10)
            TrendChart(series: trendSeries(data.trend(chartMetric), days: days), height: 190, minimal: true).padding(.top, 18)
            Separator().padding(.top, 22)
            HStack(alignment: .firstTextBaseline) {
                Text(tableTitle).font(.system(size: 18, weight: .semibold))
                Spacer()
                if showsFooter { TextLink(title: "Ver métricas  ↗") { router.page = "Métricas" } }
            }.padding(.top, 28)
            table(data)
            if showsFooter {
                HStack(spacing: 40) {
                    let active = store.posts.contains { $0.status == PostStatus.scheduled }
                    DotStatus(on: active, onLabel: "Agendamento ativo", offLabel: "Nenhum agendamento").font(.system(size: 11, weight: .medium))
                    Text(center.cloud.active ? "Publica pela nuvem, mesmo com o Mac desligado" : "Publica no horário enquanto o app estiver aberto").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.padding(.top, 20)
            }
        }
    }

    private func metric(_ title: String, _ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(metric.value.map(compact) ?? "—").font(.system(size: 25, weight: .semibold))
            HStack(spacing: 8) {
                if let change = metric.change {
                    Text("\(change >= 0 ? "↑" : "↓") \(String(format: "%.1f%%", abs(change) * 100).replacingOccurrences(of: ".", with: ","))").foregroundStyle(change >= 0 ? Palette.text : Palette.secondary)
                } else if metric.value != nil, let previous = metric.previous, let value = metric.value {
                    Text(value - previous >= 0 ? "+\(value - previous)" : "\(value - previous)")
                } else { Text("—") }
                Text("vs. período anterior").foregroundStyle(Palette.text)
            }.font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) { Circle().fill(color).frame(width: 7, height: 7); Text(name).foregroundStyle(color == Palette.text ? Palette.text : Palette.muted); Text(value).foregroundStyle(color == Palette.text ? Palette.text : Palette.muted) }.font(.system(size: 12, weight: .medium))
    }

    private func table(_ data: Insights) -> some View {
        let rows = data.summaries.filter { $0.connected && (network == "Todas" || $0.network == network) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                head("Rede").frame(maxWidth: .infinity, alignment: .leading)
                head("Visualizações").frame(width: 240, alignment: .leading)
                head("Curtidas").frame(width: 236, alignment: .leading)
                head("Publicações").frame(width: 190, alignment: .leading)
            }.padding(.top, 26).padding(.bottom, 14)
            if rows.isEmpty {
                RuleRow(height: 46) { Text(PostStore.networks.contains(where: center.isConnected) ? "Nenhum dado neste período." : "Conecte suas redes para ver o desempenho.").font(.system(size: 13)).foregroundStyle(Palette.muted); Spacer(); if !PostStore.networks.contains(where: center.isConnected) { TextLink(title: "Conexões  ↗", muted: false) { router.page = "Conexões" } } }
            }
            ForEach(rows) { row in
                RuleRow(height: 45) {
                    HStack(spacing: 0) {
                        Text(row.network).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.views.map(formatted) ?? "—").frame(width: 240, alignment: .leading)
                        Text(row.likes.map(formatted) ?? "—").frame(width: 236, alignment: .leading)
                        Text("\(row.posts)").frame(width: 190, alignment: .leading)
                    }.font(.system(size: 13))
                }
            }
        }
    }
    private func head(_ text: String) -> some View { upperCaseHeaders ? AnyView(ColumnHeader(text)) : AnyView(Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)) }
}

// MARK: - 01 · Visão geral

struct Overview: View {
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State var network = "Todas"
    @State var days = 30
    @AppStorage("overviewChartMetric") var chartMetric = "Visualizações"
    private var today: String {
        var style = Date.FormatStyle().weekday(.wide).day().month(.wide); style.timeZone = Workspace.timeZone; style.locale = AppLanguage.locale
        return Date().formatted(style).uppercased()
    }

    var body: some View {
        if !onboardingDone && !PostStore.networks.contains(where: center.isConnected) && !center.loadingConnections {
            Onboarding()
        } else {
            let data = Insights(center: center, network: network, days: days)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(today).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                            Text("Seu espaço criativo.").font(.system(size: 32, weight: .semibold)).tracking(-0.4)
                        }
                        Spacer()
                        HeaderButton("＋  Nova publicação", width: 205) { router.compose() }.padding(.top, 16)
                    }.padding(.bottom, 64)
                    DashboardBody(network: $network, days: $days, chartMetric: $chartMetric,
                                  metrics: [("Visualizações", data.views), ("Curtidas", data.likes), ("Comentários", data.comments), ("Publicações", data.published)], showsFooter: true)
                }.padding(.horizontal, 50).padding(.top, 52).padding(.bottom, 32)
            }
            .background(Palette.bg)
            .task(id: PostStore.networks.filter(center.isConnected).joined(separator: ",")) { await DashboardRefresh.run(center: center, force: false) }
        }
    }
}

enum DashboardRefresh {
    @MainActor static func run(center: PublishingCenter, force: Bool) async {
        if center.isConnected("YouTube") && (force || center.youtube.recentVideos.isEmpty) { await center.youtube.refresh() }
        if center.meta.connected && (force || center.meta.pagePosts.isEmpty) { await center.meta.refreshContent() }
        if center.tiktok.connected && (force || center.tiktok.displayName.isEmpty || (center.tiktok.canReadStats && center.tiktok.stats == nil)) { await center.tiktok.refreshProfile() }
        if center.threads.connected && (force || center.threads.recent.isEmpty) { await center.threads.refresh() }
        if center.x.connected && (force || center.x.followers == nil) { await center.x.refresh() }
    }
}

// MARK: - 02 · Métricas

struct Metrics: View {
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var center: PublishingCenter
    @State var network = "Todas"
    @State var days = 30
    @State var notice = ""
    @AppStorage("metricsChartMetric") var chartMetric = "Visualizações"
    var posts: [Publication] { store.posts.filter { (network == "Todas" || $0.platforms.contains(network)) && $0.date > Date().addingTimeInterval(-Double(days) * 86400) } }

    var body: some View {
        let data = Insights(center: center, network: network, days: days)
        PageScroll(title: "Métricas", subtitle: "Entenda o desempenho do seu conteúdo.", action: "Exportar relatório", actionHandler: export) {
            DashboardBody(network: $network, days: $days, chartMetric: $chartMetric,
                          metrics: [("Visualizações", data.views), ("Interações", data.interactions), ("Seguidores", data.followers), ("Publicações", data.published)], showsFooter: false, upperCaseHeaders: false)
                .padding(.top, -8)
        }
        .task { await DashboardRefresh.run(center: center, force: false) }
        .alert(L("Relatório"), isPresented: Binding(get: { !notice.isEmpty }, set: { if !$0 { notice = "" } })) { Button("OK") { notice = "" } } message: { Text(notice) }
    }
    func export() {
        let picker = NSSavePanel(); picker.nameFieldStringValue = "relatorio-trelune.csv"; picker.allowedContentTypes = [.commaSeparatedText]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "Data,Título,Status,Destinos,Resultados,Mídia,Texto"
        let rows = posts.sorted { $0.date < $1.date }.map { post in
            [Workspace.format(post.date), post.title, post.status, post.platforms.joined(separator: "; "),
             post.platforms.map { "\($0): \(post.results[$0].map { $0.succeeded ? "ok" : "falha – \($0.detail)" } ?? "pendente")" }.joined(separator: "; "),
             post.mediaPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "", post.text].map(cell).joined(separator: ",")
        }
        do { try ([header] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8); notice = "Relatório exportado com \(rows.count) publicação(ões)." }
        catch { notice = error.localizedDescription }
    }
}

// MARK: - 13 · Primeiro acesso

struct Onboarding: View {
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @AppStorage("onboardingDone") private var onboardingDone = false
    var body: some View {
        PageScroll(title: "Bem-vindo ao Trelune", subtitle: "Tudo para organizar sua presença, em um só lugar.", action: "") {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Comece conectando suas plataformas", subtitle: "Conecte agora ou faça isso depois em Conexões.", size: 18).padding(.top, 20)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 26), count: 3), spacing: 24) {
                    ForEach(PostStore.networks, id: \.self) { network in
                        VStack(alignment: .leading, spacing: 20) {
                            Text(network).font(.system(size: 15, weight: .semibold))
                            if center.isConnected(network) { DotStatus(on: true, onLabel: "Conectada").font(.system(size: 12, weight: .medium)).frame(height: 42) }
                            else { SecondaryButton("Conectar") { router.connect(network) }.frame(width: 140) }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.top, 30)
                HStack(spacing: 30) {
                    HeaderButton("Continuar para o workspace  →", width: 300) { onboardingDone = true; router.page = "Visão geral" }
                    TextLink(title: "Fazer isso depois") { onboardingDone = true }
                }.padding(.top, 96)
            }
        }
    }
}
