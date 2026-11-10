import SwiftUI
import AppKit

struct YouTubeConnectionView: View {
    @EnvironmentObject private var youtube: YouTubeConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if youtube.loadingConfiguration { ProgressView("Lendo a configuração no Chaves do macOS…") }
            Text("O app consulta o canal, o histórico diário de visualizações (YouTube Analytics) e envia vídeos MP4/MOV/M4V com a privacidade escolhida. Importe o JSON do cliente OAuth do tipo Aplicativo para computador e autorize a conta Google.").font(.callout).foregroundStyle(Palette.muted)
            HStack {
                ActionButton("Importar JSON do Google") { youtube.importConfiguration() }.disabled(youtube.busy)
                if youtube.configured { ActionButton(youtube.busy ? "Aguardando…" : youtube.channel.isEmpty ? "Autorizar YouTube" : "Autorizar novamente") { Task { await youtube.connect() } }.disabled(youtube.busy) }
            }
            if youtube.busy { ProgressView(); Button("Cancelar autorização") { youtube.cancel() } }
            if !youtube.channel.isEmpty {
                Text("Canal: " + youtube.channel).foregroundStyle(Palette.accent)
                Text("\(formatted(youtube.totalViews)) visualizações · \(formatted(youtube.subscribers)) inscritos · \(youtube.videoCount) vídeos").font(.caption).foregroundStyle(Palette.muted)
                if !youtube.analyticsNote.isEmpty { Text(youtube.analyticsNote).font(.caption).foregroundStyle(Palette.warning) }
                HStack { Button("Atualizar dados") { Task { await youtube.refresh() } }; Button("Revogar e desconectar", role: .destructive) { Task { await youtube.disconnect() } } }.disabled(youtube.busy)
            }
            if !youtube.message.isEmpty { Text(youtube.message).font(.callout).textSelection(.enabled) }
        }
    }
}

struct ThreadsConnectionView: View {
    @EnvironmentObject private var threads: ThreadsConnection
    @State private var token = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Threads · Meta").font(.headline)
            if threads.loading { ProgressView("Lendo o Chaves do macOS…") }
            Text("A API do Threads só aceita retorno OAuth em HTTPS, por isso a conexão usa um token de usuário gerado no painel da Meta: app → Casos de uso → Acessar a API do Threads → Configurações → Gerador de token de usuário. A conta precisa ser testadora do app (convite aceito em threads.com → Configurações → Mais configurações → Permissões de sites → Convites). Marque threads_basic, threads_content_publish e threads_manage_insights. O app renova o token antes de expirar.").font(.callout).foregroundStyle(Palette.muted)
            if threads.connected {
                Text("Conectado como @\(threads.username)").foregroundStyle(Palette.accent)
                ForEach(threads.recent.prefix(5)) { post in
                    HStack { Text(post.text ?? post.media_type ?? "Publicação").lineLimit(2); Spacer(); if let link = post.permalink.flatMap(URL.init(string:)) { Link(destination: link) { Image(systemName: "arrow.up.right.square") } } }
                        .font(.caption).padding(10).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack { Button("Atualizar") { Task { await threads.refresh() } }.disabled(threads.busy); Button("Remover conexão", role: .destructive) { threads.disconnect() } }
            }
            SecureField("", text: $token, prompt: Text(threads.connected ? "Substituir token de acesso" : "Token de acesso do Threads").foregroundStyle(Palette.muted)).textFieldStyle(.plain).fieldBox()
            ActionButton(threads.busy ? "Validando…" : "Salvar e conectar") { Task { await threads.connect(token: token); token = "" } }.disabled(threads.busy || token.isEmpty)
            Text("Regras do Threads: até 500 caracteres e 5 links; imagens JPG/PNG até 8 MB; vídeo MP4/MOV até 5 min e 1 GB; carrossel de 2 a 20 itens; até 250 posts por dia. A mídia sai do Mac pela hospedagem S3.").font(.caption).foregroundStyle(Palette.muted)
            if !threads.message.isEmpty { Text(threads.message).font(.callout).textSelection(.enabled) }
        }
    }
}

struct XConnectionView: View {
    @EnvironmentObject private var x: XConnection
    @State private var clientID = ""
    @State private var secret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("X · OAuth 2.0").font(.headline)
            if x.loading { ProgressView("Lendo o Chaves do macOS…") }
            Text("No portal do X, em User authentication settings, ative OAuth 2.0 com permissão Read and write, tipo Native App (ou Web App, informando o Client Secret abaixo) e cadastre exatamente esta Callback URI:").font(.callout).foregroundStyle(Palette.muted)
            HStack { Text(XConnection.callbackURL).font(.callout.monospaced()).textSelection(.enabled); Button("Copiar") { copyToPasteboard(XConnection.callbackURL) } }
            if x.connected {
                Text("Conectado como @\(x.username)\(x.followers.map { " · \(formatted($0)) seguidores" } ?? "")").foregroundStyle(Palette.accent)
                HStack {
                    Button("Atualizar") { Task { await x.refresh() } }
                    Button("Autorizar novamente") { Task { await x.connect() } }
                    Button("Revogar e desconectar", role: .destructive) { Task { await x.disconnect() } }
                }.disabled(x.busy)
            } else {
                InputField("Client ID (OAuth 2.0)", text: $clientID)
                SecureField("", text: $secret, prompt: Text("Client Secret (somente para apps confidenciais)").foregroundStyle(Palette.muted)).textFieldStyle(.plain).fieldBox()
                HStack {
                    ActionButton("Salvar no Chaves do macOS") { x.saveClient(id: clientID, secret: secret); secret = "" }.disabled(clientID.isEmpty || x.busy)
                    if x.configured { ActionButton(x.busy ? "Aguardando…" : "Autorizar X") { Task { await x.connect() } }.disabled(x.busy) }
                }
                if x.configured { Button("Remover credenciais", role: .destructive) { Task { await x.disconnect() } }.disabled(x.busy) }
            }
            if x.busy { ProgressView() }
            Text("Regras do X: até 280 caracteres (link conta 23, emoji conta 2); até 4 imagens JPG/PNG/WebP de 5 MB, ou 1 GIF sozinho; vídeo não é enviado por esta integração. O app no X precisa de permissão Read and write.").font(.caption).foregroundStyle(Palette.muted)
            if !x.message.isEmpty { Text(x.message).font(.callout).textSelection(.enabled) }
        }
    }
}
