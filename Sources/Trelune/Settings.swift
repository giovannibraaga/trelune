import SwiftUI
import AppKit

// MARK: - Ajustes (Figma 12, 37–41)

struct SettingsPage: View {
    @EnvironmentObject var store: PostStore
    @EnvironmentObject var host: MediaHost
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @AppStorage("workspaceName") var name = L("Workspace pessoal")
    @AppStorage("userName") var userName = NSFullUserName()
    @AppStorage(Workspace.timeZoneKey) var timezone = TimeZone.current.identifier
    @AppStorage("publishOverdue") var publishOverdue = true
    @AppStorage("notifyScheduled") var notifyScheduled = true
    @AppStorage("notifyFailed") var notifyFailed = true
    @AppStorage(Appearance.key) var appearance = Appearance.system.rawValue
    @AppStorage(CloudNames.prefixKey) var cloudPrefix = ""
    @AppStorage("libraryFolders") var foldersSerialized = ""
    @AppStorage("settingsTab") var tab = "Geral"

    // Drafts, committed by "Salvar alterações".
    @State private var draftName = ""
    @State private var draftUser = ""
    @State private var draftZone = ""
    @State private var draftOverdue = true
    @State private var draftCloud = false
    @State private var draftPrefix = ""
    @State private var draftNotifyDone = true
    @State private var draftNotifyFail = true
    @State private var draftAppearance = ""
    @State private var loaded = false
    @State private var notice = ""
    @State private var confirmErase = false
    @State private var hostDraft = MediaHost.Config()
    @State private var hostIAMUser = CloudNames.uploaderUser

    private let tabs = ["Geral", "Agendamento", "Notificações", "Aparência", "Armazenamento", "Privacidade"]

    var body: some View {
        PageScroll(title: "Ajustes", subtitle: "Personalize seu workspace.", action: "") {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tabs, id: \.self) { item in
                        Button { tab = item } label: {
                            Text(item).font(.system(size: 13, weight: current == item ? .semibold : .medium)).foregroundStyle(current == item ? Palette.text : Palette.muted)
                                .frame(width: 178, height: 48, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, -8)
                Separator(vertical: true).frame(height: 1).opacity(0).frame(width: 72)
                VStack(alignment: .leading, spacing: 0) {
                    if tab == "Hospedagem" { hosting } else { section }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.top, 2)
        }
        .onAppear(perform: load)
        .onChange(of: host.config) { _, config in if let config { hostDraft = config } }
        .alert(L("Ajustes"), isPresented: Binding(get: { !notice.isEmpty }, set: { if !$0 { notice = "" } })) { Button("OK") { notice = "" } } message: { Text(notice) }
        .confirmationDialog(L("Apagar todas as \(store.posts.count) publicações deste Mac?"), isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) { store.removeAll(); notice = "Publicações locais apagadas." }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Esta ação não pode ser desfeita. Conteúdo já publicado nas redes não é afetado.") }
    }

    private var current: String { tab == "Hospedagem" ? "Agendamento" : tab }

    @ViewBuilder private var section: some View {
        Text(current).font(.system(size: 20, weight: .semibold))
        switch current {
        case "Agendamento":
            intro("Os agendamentos usam o fuso do workspace.")
            VStack(alignment: .leading, spacing: 32) {
                ValueBox(label: "Publicação automática", action: { draftOverdue.toggle() }) { DotStatus(on: draftOverdue, onLabel: "Ativada", offLabel: "Desativada"); Spacer(); Text("Inclui agendamentos atrasados ao abrir o app").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                ValueBox(label: "Publicação pela nuvem", action: { if host.configured { draftCloud.toggle() } else { tab = "Hospedagem" } }) {
                    DotStatus(on: draftCloud, onLabel: "Ativada", offLabel: "Desativada"); Spacer()
                    Text(host.configured ? "Publica com o Mac desligado (sua conta AWS)" : "Configure a hospedagem primeiro").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                ValueBox(label: "Hospedagem de mídia e nuvem", action: { tab = "Hospedagem" }) { Text(host.configured ? "\(host.config?.bucket ?? "") · \(host.config?.region ?? "")" : "Não configurada"); Text("›") }
                if draftCloud || center.cloud.enabled {
                    ValueBox(label: "Prefixo dos recursos AWS (NAME do cloud/deploy.sh)") { TextField("", text: $draftPrefix, prompt: Text("trelune").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
                    if !center.cloud.message.isEmpty { Text(center.cloud.message).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: 640, alignment: .leading).textSelection(.enabled) }
                }
            }.padding(.top, 30)
            saveButton
        case "Notificações":
            intro("Receba avisos sobre o andamento dos envios.")
            VStack(alignment: .leading, spacing: 32) {
                ValueBox(label: "Publicações concluídas", action: { draftNotifyDone.toggle() }) { DotStatus(on: draftNotifyDone, onLabel: "Ativadas", offLabel: "Desativadas") }
                ValueBox(label: "Falhas de envio", action: { draftNotifyFail.toggle() }) { DotStatus(on: draftNotifyFail, onLabel: "Ativadas", offLabel: "Desativadas") }
                if Notifier.available {
                    ValueBox(label: "Teste", action: { Notifier.requestIfNeeded(); Notifier.post(title: AppIdentity.name, body: "As notificações estão funcionando.", failure: false) }) { Text("Enviar notificação de teste"); Text("›") }
                } else { Text("Notificações exigem o app empacotado (script/build_and_run.sh).").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }.padding(.top, 30)
            saveButton
        case "Aparência":
            intro("Escolha como o Trelune aparece.")
            VStack(alignment: .leading, spacing: 32) {
                ValueBox(label: "Tema") {
                    ForEach(Appearance.allCases, id: \.rawValue) { option in
                        Button { draftAppearance = option.rawValue } label: {
                            Text(option.rawValue).font(.system(size: 14, weight: draftAppearance == option.rawValue ? .semibold : .regular)).foregroundStyle(draftAppearance == option.rawValue ? Palette.text : Palette.muted).padding(.trailing, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                ValueBox(label: "Prévia") { Text(draftAppearance == Appearance.system.rawValue ? "O tema acompanha o macOS." : "O tema acompanha sua escolha.") }
            }.padding(.top, 30)
            saveButton
        case "Armazenamento":
            intro("Arquivos novos nas pastas monitoradas aparecem automaticamente.")
            VStack(alignment: .leading, spacing: 32) {
                ValueBox(label: "Pastas monitoradas", action: { router.page = "Biblioteca" }) {
                    let folders = foldersSerialized.components(separatedBy: "\n").filter { !$0.isEmpty }
                    Text(folders.isEmpty ? "Nenhuma pasta" : folders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") + "  ·  Monitorando").lineLimit(1)
                }
                ValueBox(label: "Arquivos locais", action: { router.page = "Biblioteca" }) { Text("Gerenciar biblioteca"); Text("›") }
                ValueBox(label: "Dados do app", action: { NSWorkspace.shared.open(AppPaths.support) }) { Text("\(store.posts.count) publicações · abrir pasta de dados"); Text("›") }
                HStack(spacing: 10) {
                    SecondaryButton("Exportar backup") { exportBackup() }
                    SecondaryButton("Importar backup") { importBackup() }
                    SecondaryButton("Importar configuração anterior") {
                        let report = LegacyImport.run()
                        notice = report.source.isEmpty && report.connections.isEmpty ? "Nenhuma configuração anterior encontrada." : "Importado de \(report.source.isEmpty ? "Chaves" : report.source): \(report.preferences) preferência(s) e \(report.connections.count) conexão(ões). Reabra o app para recarregar as conexões."
                        load(force: true)
                    }
                }
            }.padding(.top, 30)
            saveButton
        case "Privacidade":
            intro("Controle os dados e acessos do workspace.")
            VStack(alignment: .leading, spacing: 32) {
                ValueBox(label: "Dados do workspace", action: { NSWorkspace.shared.open(AppPaths.support) }) { Text("Armazenados neste dispositivo") }
                ValueBox(label: "Acesso de assistentes", action: { router.page = "MCP e assistentes" }) { Text("Gerenciar permissões"); Text("›") }
                ValueBox(label: "Credenciais das redes") { Text("No Chaves do macOS, separadas por serviço") }
                HStack(spacing: 10) {
                    SecondaryButton("Limpar histórico de assistentes") { AssistantLogEntry.clear(); notice = "Histórico de assistentes apagado." }
                    SecondaryButton("Apagar publicações locais", role: .destructive) { confirmErase = true }
                }
            }.padding(.top, 30)
            saveButton
        default:
            VStack(alignment: .leading, spacing: 32) {
                ValueBox(label: "Nome do workspace") { TextField("", text: $draftName, prompt: Text("Workspace").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
                ValueBox(label: "Seu nome") { TextField("", text: $draftUser, prompt: Text("Nome").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
                ValueBox(label: "Fuso horário") { ZoneMenu(identifier: $draftZone) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Idioma").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                    HStack(spacing: 10) {
                        Text(verbatim: AppLanguage.isPortuguese ? "Português (Brasil)" : "English").font(.system(size: 14))
                        Text("Segue o idioma do macOS").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
            }.padding(.top, 36)
            saveButton
        }
    }

    private func intro(_ text: String) -> some View { Text(text).font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 18) }
    private var saveButton: some View { HeaderButton("Salvar alterações", width: 190) { save() }.padding(.top, 34) }

    private func load() { load(force: false) }
    private func load(force: Bool) {
        guard force || !loaded else { return }
        loaded = true
        draftName = name; draftUser = userName; draftZone = timezone; draftOverdue = publishOverdue; draftCloud = center.cloud.enabled
        draftPrefix = cloudPrefix; draftNotifyDone = notifyScheduled; draftNotifyFail = notifyFailed; draftAppearance = appearance
        if let config = host.config { hostDraft = config }
    }
    private func save() {
        name = draftName; userName = draftUser; timezone = draftZone; publishOverdue = draftOverdue
        cloudPrefix = draftPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        notifyScheduled = draftNotifyDone; notifyFailed = draftNotifyFail; appearance = draftAppearance
        if center.cloud.enabled != draftCloud && host.configured { center.cloud.enabled = draftCloud; Task { await center.tick() } }
        notice = "Alterações salvas."
    }

    // Media hosting (reached from Agendamento).
    @ViewBuilder private var hosting: some View {
        TextLink(title: "‹  Agendamento") { tab = "Agendamento" }
        Text("Hospedagem de mídia").font(.system(size: 20, weight: .semibold)).padding(.top, 16)
        intro("Instagram, Threads e fotos do TikTok só aceitam mídia por URL pública. O app envia os arquivos para o seu bucket S3 na hora de publicar. Guia: docs/CLOUD.md.")
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                ValueBox(label: "Bucket", width: nil) { TextField("", text: $hostDraft.bucket, prompt: Text("meu-bucket-de-midia").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
                ValueBox(label: "Região", width: 180) { TextField("", text: $hostDraft.region, prompt: Text("us-east-1").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
            }.frame(maxWidth: 640)
            HStack(spacing: 14) {
                ValueBox(label: "Access key ID", width: nil) { TextField("", text: $hostDraft.accessKey, prompt: Text("AKIA…").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
                ValueBox(label: "Secret access key", width: nil) { SecureField("", text: $hostDraft.secretKey).textFieldStyle(.plain) }
            }.frame(maxWidth: 640)
            HStack(spacing: 14) {
                ValueBox(label: "Prefixo", width: 200) { TextField("", text: $hostDraft.prefix, prompt: Text(CloudNames.mediaPrefix).foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
                ValueBox(label: "URL pública (opcional)", width: nil) { TextField("", text: $hostDraft.publicBaseURL, prompt: Text("https://midia.seudominio.com").foregroundStyle(Palette.muted)).textFieldStyle(.plain) }
            }.frame(maxWidth: 640)
            ValueBox(label: "Gerar chave com a AWS CLI deste Mac (a chave secreta não é exibida)") {
                TextField("", text: $hostIAMUser).textFieldStyle(.plain)
                Button(host.provisioning ? "Gerando…" : "Gerar chave") { Task { await host.provisionWithAWSCLI(bucket: hostDraft.bucket, region: hostDraft.region, prefix: hostDraft.prefix, user: hostIAMUser) } }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).disabled(host.provisioning || hostDraft.bucket.isEmpty)
            }
            if !host.message.isEmpty { Text(host.message).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: 640, alignment: .leading).textSelection(.enabled) }
        }.padding(.top, 30)
        HStack(spacing: 12) {
            HeaderButton("Salvar hospedagem", width: 190) { host.save(hostDraft) }
            HeaderButton("Testar envio e leitura", primary: false, width: 190) { Task { await host.test() } }.disabled(!host.configured)
            if host.configured { SecondaryButton("Remover", role: .destructive) { host.remove(); hostDraft = MediaHost.Config() } }
        }.padding(.top, 34)
    }

    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "trelune-backup.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted; try encoder.encode(store.posts).write(to: url); notice = "Backup exportado com \(store.posts.count) publicação(ões)." } catch { notice = error.localizedDescription }
    }
    private func importBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let items = try JSONDecoder().decode([Publication].self, from: Data(contentsOf: url))
            let existing = Set(store.posts.map(\.id))
            let merged = store.posts + items.filter { !existing.contains($0.id) }
            store.replaceAll(with: merged); notice = "\(merged.count - existing.count) publicação(ões) importada(s)."
        } catch { notice = "Não foi possível ler o backup: \(error.localizedDescription)" }
    }
}
