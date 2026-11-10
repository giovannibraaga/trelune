import SwiftUI
import AppKit

struct MetaConnectionView: View {
    @EnvironmentObject private var meta: MetaConnection
    @State private var appID = ""
    @State private var appSecret = ""
    @State private var userToken = ""
    private static let scopes = "pages_show_list, pages_read_engagement, pages_read_user_content, pages_manage_posts, read_insights, business_management, instagram_basic, instagram_content_publish, instagram_manage_insights"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Instagram e Facebook · Meta").font(.headline)
            Text("A conexão usa o login do Facebook para listar suas Páginas e, quando vinculadas, as contas profissionais do Instagram. Crie o seu próprio app no painel da Meta (veja o guia de conexão). Em modo de desenvolvimento, só pessoas com papel no app podem autorizar até a análise da Meta.").font(.callout).foregroundStyle(Palette.muted)
            if meta.loading { ProgressView("Lendo a conexão no Chaves do macOS…") }
            InputField("ID do aplicativo Meta", text: $appID)
            SecureField("", text: $appSecret, prompt: Text("Segredo do aplicativo Meta").foregroundStyle(Palette.muted)).textFieldStyle(.plain).fieldBox()
            HStack {
                ActionButton("Salvar no Chaves do macOS") { meta.saveClient(appID: appID, appSecret: appSecret); appSecret = "" }
                if meta.configured {
                    ActionButton(meta.busy ? "Aguardando…" : meta.connected ? "Conectar novamente" : "Conectar Facebook") { Task { await meta.connect() } }.disabled(meta.busy)
                }
            }
            Text("O login pelo navegador volta para \(MetaConnection.callbackURL). Se a Meta mostrar “Can't load URL”, use a conexão por token abaixo, que não depende de endereço de retorno.").font(.caption).textSelection(.enabled).foregroundStyle(Palette.muted)
            if meta.configured {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conectar com token (recomendado)").font(.subheadline.weight(.semibold))
                    Text("1. Abra o Graph API Explorer e escolha o seu app Meta.\n2. Em “Usuário ou Página”, escolha Obter token de acesso do usuário e marque: \(Self.scopes).\n3. Clique em Generate Access Token, autorize suas Páginas e cole o token aqui.").font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecondaryButton("Abrir Graph API Explorer") { NSWorkspace.shared.open(URL(string: "https://developers.facebook.com/tools/explorer/")!) }
                        SecondaryButton("Copiar permissões") { copyToPasteboard(Self.scopes) }
                    }
                    SecureField("", text: $userToken, prompt: Text("Token de acesso do usuário").foregroundStyle(Palette.muted)).textFieldStyle(.plain).fieldBox()
                    ActionButton(meta.busy ? "Validando…" : "Conectar com token") { Task { await meta.connect(userToken: userToken); userToken = "" } }.disabled(meta.busy || userToken.isEmpty)
                    Text("Para publicar na Página, a permissão pages_manage_posts precisa estar adicionada ao caso de uso “Manage everything on your Page” no painel do app.").font(.caption).foregroundStyle(Palette.warning)
                }.padding(14).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
            }
            if meta.connected {
                HStack {
                    Text("Facebook conectado · \(meta.pages.count) Página(s) · \(meta.instagram.count) Instagram profissional(is)").foregroundStyle(Palette.accent)
                    Spacer()
                    Button(meta.pages.isEmpty ? "Buscar Páginas" : "Atualizar dados") { Task { if meta.pages.isEmpty { await meta.reloadPages() } else { await meta.refreshContent() } } }.disabled(meta.busy)
                }
                ForEach(meta.pages) { page in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Facebook · \(page.name)").font(.subheadline.weight(.semibold))
                        Text(page.instagramUsername.map { "Instagram · @\($0)" } ?? "Sem conta profissional do Instagram vinculada a esta Página")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                if meta.pages.isEmpty && !meta.lastDiagnosis.isEmpty {
                    Text("Diagnóstico: \(meta.lastDiagnosis) Gere um token novo marcando todas as permissões listadas acima e, na janela da Meta, escolha a sua Página e o Instagram (opção “Escolher tudo” ou marque cada um).").font(.caption).foregroundStyle(Palette.warning).textSelection(.enabled)
                }
                Button("Remover conexão local", role: .destructive) { meta.disconnect() }.disabled(meta.busy)
            } else {
                Text("Para publicar no Instagram, conecte uma conta Business ou Creator a uma Página e hospede a mídia em uma URL HTTPS pública. Facebook aceita texto e mídia local em uma Página administrada.").font(.caption).foregroundStyle(Palette.muted)
            }
            if !meta.message.isEmpty { Text(meta.message).font(.callout).textSelection(.enabled).foregroundStyle(.orange) }
            if meta.busy { ProgressView() }
        }
    }
}
