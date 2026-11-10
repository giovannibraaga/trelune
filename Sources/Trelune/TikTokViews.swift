import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

struct TikTokConfigurationView: View {
    @EnvironmentObject var tiktok: TikTokConnection
    @State private var key = ""
    @State private var secret = ""
    @AppStorage("tiktokRequestDirect") private var direct = false
    @AppStorage("tiktokRequestMetrics") private var metrics = false
    @State private var exporting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TikTok · ambiente de teste").font(.headline)
            Text("Use o client key e o client secret do seu app no portal TikTok for Developers (sandbox ou produção). No sandbox, a conta precisa estar na lista Target Users.").font(.callout).foregroundStyle(Palette.muted)
            if tiktok.loadingConfiguration {
                ProgressView("Lendo a configuração no Chaves do macOS…")
            } else if !tiktok.configured {
                InputField("Client key do sandbox", text: $key)
                SecureField("", text: $secret, prompt: Text("Client secret do sandbox").foregroundStyle(Palette.muted)).textFieldStyle(.plain).fieldBox()
                ActionButton("Salvar credenciais no Mac") {
                    do { try tiktok.configure(key: key, secret: secret); key = ""; secret = "" } catch { tiktok.message = error.localizedDescription }
                }
            } else {
                Text(tiktok.connected ? "Conta: \(tiktok.displayName.isEmpty ? "Autorizada" : tiktok.displayName)" : "Credenciais configuradas").foregroundStyle(Palette.accent)
                Toggle("Solicitar publicação direta (Direct Post)", isOn: $direct)
                Text("Ative esta opção somente após habilitar Direct Post no portal do TikTok.").font(.caption).foregroundStyle(Palette.muted)
                Toggle("Ler métricas da conta (seguidores, curtidas e vídeos)", isOn: $metrics)
                Text("Requer os escopos user.info.stats (Login Kit) e video.list (Display API) adicionados ao app no portal do TikTok — sem eles o TikTok mostra o erro “scope”; nesse caso desmarque esta opção e autorize de novo.\(tiktok.connected ? (tiktok.canReadStats ? " Já autorizado." : " Ainda não autorizado.") : "")").font(.caption).foregroundStyle(Palette.muted)
                if tiktok.connected && (direct != tiktok.canPublish || metrics != tiktok.canReadStats) {
                    Label("Opções salvas. Clique em Autorizar TikTok para aplicar as novas permissões à conta.", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(Palette.warning)
                }
                HStack {
                    ActionButton(tiktok.busy ? "Aguarde…" : "Autorizar TikTok") { tiktok.connect(direct: direct, metrics: metrics) }.disabled(tiktok.busy)
                    if tiktok.connected { Button("Atualizar conta") { Task { await tiktok.refreshProfile() } }.disabled(tiktok.busy) }
                }
                if tiktok.busy { ProgressView(); Button("Cancelar operação") { tiktok.cancel() } }
                if tiktok.connected {
                    ActionButton("Preparar envio de vídeo") { exporting = true }.disabled(tiktok.busy || (!tiktok.canUpload && !tiktok.canPublish))
                    Button("Revogar acesso e desconectar", role: .destructive) { Task { await tiktok.disconnect() } }.disabled(tiktok.busy)
                } else { Button("Remover configuração local") { Task { await tiktok.disconnect() } }.disabled(tiktok.busy) }
            }
            if !tiktok.message.isEmpty { Text(tiktok.message).font(.callout).textSelection(.enabled) }
            Color.clear.frame(height: 0).onAppear {
                // First open after connecting: reflect what the account already granted.
                if tiktok.connected && !UserDefaults.standard.bool(forKey: "tiktokOptionsInitialized") {
                    direct = tiktok.canPublish; metrics = tiktok.canReadStats
                    UserDefaults.standard.set(true, forKey: "tiktokOptionsInitialized")
                }
            }
            if !tiktok.deliveries.isEmpty {
                Text("Envios recentes").font(.headline).padding(.top, 6)
                ForEach(tiktok.deliveries.prefix(8)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.callout).lineLimit(1)
                            Text("\(TikTokDeliveryStatus.label(item.status)) · \(item.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Palette.muted)
                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(Palette.warning).lineLimit(2) }
                        }
                        Spacer()
                        Button("Atualizar") { Task { await tiktok.checkStatus(item) } }.disabled(tiktok.busy || !tiktok.connected)
                    }.padding(10).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }.sheet(isPresented: $exporting) { TikTokExportView().environmentObject(tiktok) }
    }
}

enum TikTokDeliveryStatus {
    static func label(_ status: String) -> String {
        switch status {
        case "PROCESSING_UPLOAD": "Recebendo o arquivo"
        case "PROCESSING_DOWNLOAD": "Baixando o arquivo"
        case "SEND_TO_USER_INBOX": "Entregue no TikTok · finalize a publicação no celular"
        case "PUBLISH_COMPLETE": "Publicado · confirmado pelo TikTok"
        case "FAILED": "Envio recusado pelo TikTok"
        default: "Em processamento · \(status)"
        }
    }
}

struct TikTokExportView: View {
    @EnvironmentObject var tiktok: TikTokConnection
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var caption: String
    @State private var player: AVPlayer?
    @State private var mode = "draft"
    @State private var creator: TikTokConnection.Creator?
    @State private var loading = false
    @State private var error = ""
    @State private var privacy = ""
    @State private var comments = false
    @State private var duet = false
    @State private var stitch = false
    @State private var ownBrand = false
    @State private var paidBrand = false
    @State private var ai = false
    @State private var consent = false
    @State private var confirming = false
    init(initialURL: URL? = nil, initialCaption: String = "") {
        _file = State(initialValue: initialURL); _caption = State(initialValue: initialCaption)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Enviar vídeo para TikTok").font(.title2.bold()); Spacer(); Button("Fechar") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Conta: \(tiktok.displayName.isEmpty ? "Nenhuma conta conectada" : tiktok.displayName)").foregroundStyle(Palette.accent)
                    if let player { VideoPlayer(player: player).frame(height: 220) }
                    HStack { Text(file?.lastPathComponent ?? "Selecione um vídeo MP4, MOV ou WebM").lineLimit(2); Spacer(); ActionButton("Escolher vídeo") { chooseFile() }.disabled(tiktok.busy) }
                    PillPicker(options: tiktok.canPublish ? [("draft", "Rascunho"), ("direct", "Publicar diretamente")] : [("draft", "Rascunho")], selection: $mode).disabled(tiktok.busy)
                    if mode == "draft" {
                        Text("O vídeo será enviado à caixa de entrada da conta. Abra a notificação no TikTok para editar e concluir a publicação. O envio não publica o vídeo automaticamente.").font(.callout).foregroundStyle(Palette.muted)
                    } else {
                        Text("Legenda").font(.headline)
                        TextArea(text: $caption, height: 100)
                        Text("\(caption.utf16.count)/2200").font(.caption)
                        if loading { ProgressView("Consultando opções da conta…") }
                        if let creator {
                            Text("Publicando como @\(creator.creator_username)").font(.headline)
                            FieldLabel("Quem pode ver?")
                            SelectField([("", "Selecione a privacidade")] + creator.privacy_level_options.map { ($0, privacyLabel($0)) }, selection: $privacy)
                            Toggle("Permitir comentários", isOn: $comments).disabled(creator.comment_disabled)
                            Toggle("Permitir Dueto", isOn: $duet).disabled(creator.duet_disabled)
                            Toggle("Permitir Costurar", isOn: $stitch).disabled(creator.stitch_disabled)
                            Toggle("Divulga minha própria marca", isOn: $ownBrand)
                            Toggle("Parceria paga com outra marca", isOn: $paidBrand)
                            Toggle("Conteúdo gerado por IA", isOn: $ai)
                            if paidBrand || ownBrand { Text("O conteúdo comercial será identificado no TikTok.").font(.caption) }
                            if paidBrand && privacy == "SELF_ONLY" { Text("Parcerias pagas não podem usar visibilidade privada.").foregroundStyle(.orange) }
                        }
                        Button("Atualizar opções da conta") { Task { await loadCreator() } }.disabled(loading || tiktok.busy)
                    }
                    Toggle(mode == "draft" ? "Autorizo enviar este vídeo à caixa de entrada da conta acima." : "Revisei o conteúdo e autorizo publicar este vídeo na conta acima.", isOn: $consent).disabled(tiktok.busy)
                    if mode == "direct" {
                        Text("Ao publicar, confirme sua concordância com as regras de uso de música do TikTok e, para conteúdo comercial, com as regras de conteúdo de marca.").font(.caption).foregroundStyle(Palette.muted)
                        Link("Regras de música", destination: URL(string: "https://www.tiktok.com/legal/page/global/music-usage-confirmation/en")!)
                        if ownBrand || paidBrand { Link("Conteúdo de marca", destination: URL(string: "https://www.tiktok.com/legal/page/global/bc-policy/en")!) }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if !tiktok.message.isEmpty { Text(tiktok.message).font(.callout).textSelection(.enabled) }
                    if tiktok.busy { ProgressView(value: tiktok.progress); Button("Interromper") { tiktok.cancel() } }
                }.padding(.trailing, 8)
            }
            HStack { Spacer(); ActionButton(tiktok.busy ? "Enviando…" : mode == "draft" ? "Enviar ao TikTok" : "Publicar no TikTok") { confirming = true }.disabled(!ready) }
        }.padding(28).frame(width: 700, height: 780)
        .task { if let file { player = AVPlayer(url: file) } }
        .onChange(of: mode) { _, value in consent = false; if value == "direct" { Task { await loadCreator() } } }
        .onDisappear { player?.pause() }
        .confirmationDialog(mode == "draft" ? "Enviar o vídeo para \(tiktok.displayName)? Você finalizará a publicação no TikTok." : "Publicar o vídeo em \(tiktok.displayName) com a visibilidade \(privacyLabel(privacy))?", isPresented: $confirming, titleVisibility: .visible) {
            Button(mode == "draft" ? "Enviar vídeo" : "Publicar vídeo") { send() }
            Button("Cancelar", role: .cancel) {}
        }
    }
    private var ready: Bool {
        file != nil && tiktok.connected && !tiktok.busy && consent && (mode == "draft" ? tiktok.canUpload : tiktok.canPublish && creator != nil && !loading && !privacy.isEmpty && caption.utf16.count <= 2200 && !(paidBrand && privacy == "SELF_ONLY"))
    }
    private func chooseFile() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        if picker.runModal() == .OK, let url = picker.url { file = url; player?.pause(); player = AVPlayer(url: url); consent = false; error = "" }
    }
    private func loadCreator() async {
        loading = true; creator = nil; privacy = ""; consent = false; error = ""
        defer { loading = false }
        do { creator = try await tiktok.creator(); comments = false; duet = false; stitch = false } catch { self.error = error.localizedDescription }
    }
    private func send() {
        guard ready, let file else { return }
        player?.pause()
        let options: TikTokConnection.DirectOptions? = mode == "direct" ? .init(title: caption, privacy: privacy, disableComment: !comments || creator?.comment_disabled == true, disableDuet: !duet || creator?.duet_disabled == true, disableStitch: !stitch || creator?.stitch_disabled == true, ownBrand: ownBrand, paidBrand: paidBrand, aiGenerated: ai) : nil
        tiktok.uploadVideo(file, title: file.lastPathComponent, direct: options)
        consent = false
    }
    private func privacyLabel(_ value: String) -> String {
        switch value { case "PUBLIC_TO_EVERYONE": "Público"; case "MUTUAL_FOLLOW_FRIENDS": "Amigos"; case "FOLLOWER_OF_CREATOR": "Seguidores"; case "SELF_ONLY": "Somente eu"; default: value }
    }
}
