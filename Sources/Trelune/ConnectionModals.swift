import SwiftUI
import AppKit

/// Connection dialogs from the Figma file (screens 42–53).
enum ConnectionDialog: Equatable {
    case choose, setup(String), manage(String), metaToken, metaAccounts, reconnect(String), disconnect(String)
}

/// Dimmed overlay with a centered card: title, subtitle, close button, a rule, content and a footer.
struct ModalFrame<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.system(size: 20, weight: .semibold))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                Separator().padding(.top, 18)
                VStack(alignment: .leading, spacing: 0) { content }.padding(.top, 20).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 24)
                Separator()
                HStack(spacing: 12) { footer }.padding(.top, 18)
            }
            .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 24)
            .frame(width: 616).frame(minHeight: 520, maxHeight: 640)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.stroke))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        }
    }
}

struct ModalField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Group {
                if secure { SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.muted)) }
                else { TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.muted)) }
            }.textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 14).frame(height: 44).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct ConnectionDialogs: View {
    @Binding var dialog: ConnectionDialog?
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @EnvironmentObject var youtube: YouTubeConnection
    @EnvironmentObject var tiktok: TikTokConnection
    @EnvironmentObject var meta: MetaConnection
    @EnvironmentObject var threads: ThreadsConnection
    @EnvironmentObject var x: XConnection
    @State private var first = ""
    @State private var second = ""
    @State private var token = ""
    @AppStorage("tiktokRequestDirect") private var direct = false
    @AppStorage("tiktokRequestMetrics") private var metrics = false
    @AppStorage("tiktokEnvironment") private var environment = "Sandbox"
    private static let metaScopes = "pages_show_list, pages_read_engagement, pages_read_user_content, pages_manage_posts, read_insights, business_management, instagram_basic, instagram_content_publish, instagram_manage_insights"

    var body: some View {
        if let dialog {
            Group {
                switch dialog {
                case .choose: choose
                case .setup(let network): setup(network)
                case .manage(let network): manage(network)
                case .metaToken: metaToken
                case .metaAccounts: metaAccounts
                case .reconnect(let network): reconnect(network)
                case .disconnect(let network): disconnect(network)
                }
            }
            .onChange(of: dialog) { _, _ in first = ""; second = ""; token = "" }
        }
    }

    private func close() { dialog = nil }
    private func go(_ next: ConnectionDialog) { dialog = next }
    private func key(_ network: String) -> String { network == "Instagram" || network == "Facebook" ? "Meta" : network }

    // 42 · Choose platform
    private var choose: some View {
        ModalFrame(title: "Conectar uma conta", subtitle: "Selecione a plataforma para começar.", close: close) {
            ForEach([("YouTube", "Canal do Google"), ("Instagram", "Contas e Páginas Meta"), ("TikTok", "Conta TikTok"), ("Threads", "Conta Threads"), ("X", "Conta X")], id: \.0) { item in
                Button { go(center.isConnected(item.0) ? .manage(item.0) : .setup(item.0)) } label: {
                    RuleRow(height: 66) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.0 == "Instagram" ? "Instagram e Facebook" : item.0).font(.system(size: 14, weight: .semibold))
                            Text(center.isConnected(item.0) ? center.accountLabel(item.0) : item.1).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Text("›").font(.system(size: 15)).foregroundStyle(Palette.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        } footer: { Spacer(); HeaderButton("Cancelar", primary: false, width: 150, action: close) }
    }

    // 43–46, 48 · Setup per network
    @ViewBuilder private func setup(_ network: String) -> some View {
        switch key(network) {
        case "YouTube":
            ModalFrame(title: "Conectar YouTube", subtitle: "Conecte seu canal usando uma conta Google.", close: close) {
                stepRow(1, "Importe o cliente OAuth", "Selecione o JSON de um aplicativo para computador.") { SecondaryButton(youtube.configured ? "Trocar JSON do Google" : "Importar JSON do Google") { youtube.importConfiguration() } }
                Separator().padding(.vertical, 18)
                stepRow(2, "Autorize sua conta", "O navegador será aberto para você escolher o canal.") {
                    Text(youtube.busy ? "Aguardando autorização no navegador…" : youtube.configured ? "Configuração importada" : "Aguardando arquivo de configuração").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                guide(network)
                status(youtube.message)
            } footer: {
                Spacer()
                HeaderButton("Cancelar", primary: false, width: 150) { if youtube.busy { youtube.cancel() }; close() }
                HeaderButton(youtube.busy ? "Aguardando…" : "Autorizar Google  ↗", width: 170) { Task { await youtube.connect(); if center.isConnected("YouTube") { close() } } }.disabled(!youtube.configured || youtube.busy)
            }
        case "X":
            ModalFrame(title: "Conectar X", subtitle: "Configure o acesso e autorize sua conta no navegador.", close: close) {
                VStack(alignment: .leading, spacing: 20) {
                    ModalField(label: "Client ID", placeholder: "Informe o Client ID", text: $first)
                    ModalField(label: "Client Secret · opcional", placeholder: "Necessário apenas para apps confidenciais", text: $second, secure: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Callback URI").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Button { copyToPasteboard(XConnection.callbackURL) } label: { Text("Copiar URI de retorno").font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle()) }.buttonStyle(.plain).help(XConnection.callbackURL)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ative OAuth 2.0 e as permissões de leitura e escrita no X.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text("As credenciais são salvas no Chaves do macOS.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    guide(network)
                    status(x.message)
                }
            } footer: {
                Spacer()
                HeaderButton("Cancelar", primary: false, width: 150, action: close)
                HeaderButton(x.busy ? "Aguardando…" : "Salvar e autorizar  ↗", width: 170) {
                    if !first.isEmpty { x.saveClient(id: first, secret: second) }
                    Task { await x.connect(); if x.connected { close() } }
                }.disabled(x.busy || (first.isEmpty && !x.configured))
            }
        case "TikTok":
            ModalFrame(title: "Conectar TikTok", subtitle: "Configure seu aplicativo antes de autorizar a conta.", close: close) {
                VStack(alignment: .leading, spacing: 18) {
                    ModalField(label: "Client key", placeholder: tiktok.configured ? "Salvo no Chaves · informe para trocar" : "Informe a chave do aplicativo", text: $first)
                    ModalField(label: "Client secret", placeholder: tiktok.configured ? "Salvo no Chaves · informe para trocar" : "Informe o segredo do aplicativo", text: $second, secure: true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ambiente").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Menu { Button("Sandbox") { environment = "Sandbox" }; Button("Produção") { environment = "Produção" } } label: { Text("\(L(environment))  ▾").font(.system(size: 13)).foregroundStyle(Palette.text) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    Button { direct.toggle() } label: { DotStatus(on: direct, onLabel: "Permitir publicação direta", offLabel: "Permitir publicação direta").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain)
                    Button { metrics.toggle() } label: { DotStatus(on: metrics, onLabel: "Consultar estatísticas da conta", offLabel: "Consultar estatísticas da conta").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain)
                    Text("Ative apenas os recursos habilitados no portal TikTok.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    guide(network)
                    status(tiktok.message)
                }
            } footer: {
                Spacer()
                HeaderButton("Cancelar", primary: false, width: 150) { if tiktok.busy { tiktok.cancel() }; close() }
                HeaderButton(tiktok.busy ? "Aguardando…" : "Salvar e autorizar  ↗", width: 170) {
                    do { if !first.isEmpty && !second.isEmpty { try tiktok.configure(key: first, secret: second) }; tiktok.connect(direct: direct, metrics: metrics) } catch { tiktok.message = error.localizedDescription }
                }.disabled(tiktok.busy || (!tiktok.configured && (first.isEmpty || second.isEmpty)))
            }
        case "Threads":
            ModalFrame(title: "Conectar Threads", subtitle: "Use o token da conta gerado no painel da Meta.", close: close) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("1. Gere um token de usuário no painel do seu app Meta.").font(.system(size: 12))
                    Text("2. Autorize publicação e leitura de métricas.").font(.system(size: 12))
                    Text("3. Cole o token abaixo para conectar sua conta.").font(.system(size: 12))
                    SecondaryButton("Abrir painel da Meta  ↗") { NSWorkspace.shared.open(URL(string: "https://developers.facebook.com/apps/")!) }.padding(.top, 4)
                    ModalField(label: "Token de acesso", placeholder: "Cole o token de usuário", text: $token, secure: true).padding(.top, 10)
                    Text("O token é armazenado no Chaves do macOS.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    guide(network)
                    status(threads.message)
                }
            } footer: {
                Spacer()
                HeaderButton("Cancelar", primary: false, width: 150, action: close)
                HeaderButton(threads.busy ? "Validando…" : "Conectar conta", width: 170) { Task { await threads.connect(token: token); token = ""; if threads.connected { close() } } }.disabled(threads.busy || token.isEmpty)
            }
        default:
            ModalFrame(title: "Conectar Instagram e Facebook", subtitle: "A Meta usa o Facebook para localizar Páginas e contas.", close: close) {
                Text("Credenciais do aplicativo Meta").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 16) {
                    ModalField(label: "App ID", placeholder: meta.configured ? "Salvo no Chaves · informe para trocar" : "Informe o ID do aplicativo", text: $first)
                    ModalField(label: "App secret", placeholder: meta.configured ? "Salvo no Chaves · informe para trocar" : "Informe o segredo do aplicativo", text: $second, secure: true)
                    SecondaryButton("Salvar credenciais") { meta.saveClient(appID: first, appSecret: second); first = ""; second = "" }.disabled(first.isEmpty || second.isEmpty)
                }.padding(.top, 14)
                Separator().padding(.vertical, 18)
                Text("Escolha como conectar").font(.system(size: 13, weight: .semibold))
                Text("Login pelo navegador ou token de usuário do Graph API.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 8)
                HStack(spacing: 12) {
                    SecondaryButton("Usar token") { go(.metaToken) }.disabled(!meta.configured)
                    HeaderButton(meta.busy ? "Aguardando…" : "Continuar com Facebook  ↗", width: 200) { Task { await meta.connect(); if meta.connected { go(.metaAccounts) } } }.disabled(!meta.configured || meta.busy)
                }.padding(.top, 16)
                Text("Instagram exige uma conta profissional vinculada a uma Página.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 14)
                guide(network)
                status(meta.message)
            } footer: { Spacer(); HeaderButton("Cancelar", primary: false, width: 150, action: close) }
        }
    }

    // 52 · Meta token
    private var metaToken: some View {
        ModalFrame(title: "Conectar com token", subtitle: "Use o Graph API Explorer para autorizar suas contas.", close: close) {
            VStack(alignment: .leading, spacing: 14) {
                Text("1. Abra o Graph API Explorer e selecione seu app.").font(.system(size: 12))
                Text("2. Gere um token de usuário com as permissões necessárias.").font(.system(size: 12))
                Text("3. Autorize suas Páginas e perfis profissionais.").font(.system(size: 12))
                HStack(spacing: 10) {
                    SecondaryButton("Abrir Graph API Explorer  ↗") { NSWorkspace.shared.open(URL(string: "https://developers.facebook.com/tools/explorer/")!) }
                    SecondaryButton("Copiar permissões") { copyToPasteboard(Self.metaScopes) }
                }.padding(.top, 4)
                ModalField(label: "Token de acesso do usuário", placeholder: "Cole o token de usuário", text: $token, secure: true).padding(.top, 10)
                Text("O token é armazenado no Chaves do macOS.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text("As permissões da Página e do Instagram precisam estar autorizadas.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                status(meta.message)
            }
        } footer: {
            Spacer()
            HeaderButton("Voltar", primary: false, width: 150) { go(.setup("Instagram")) }
            HeaderButton(meta.busy ? "Validando…" : "Buscar contas", width: 170) { Task { await meta.connect(userToken: token); token = ""; if meta.connected { go(.metaAccounts) } } }.disabled(meta.busy || token.isEmpty)
        }
    }

    // 49 · Meta accounts found
    private var metaAccounts: some View {
        ModalFrame(title: "Escolha suas contas", subtitle: "Selecione as Páginas e os perfis disponíveis na Meta.", close: close) {
            Text("Página do Facebook").font(.system(size: 12)).foregroundStyle(Palette.muted)
            if meta.pages.isEmpty { Text("Nenhuma Página encontrada.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 10) }
            ForEach(meta.pages) { page in accountBox(page.name, "Página do Facebook").padding(.top, 10) }
            Text("Instagram profissional vinculado").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 22)
            let profiles = meta.pages.compactMap(\.instagramUsername)
            if profiles.isEmpty { Text("Nenhum perfil profissional vinculado às Páginas.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 10) }
            ForEach(profiles, id: \.self) { name in accountBox("@\(name)", "Conta profissional").padding(.top, 10) }
            Text("Não encontrou uma conta?").font(.system(size: 13, weight: .semibold)).padding(.top, 24)
            Text("Confira os vínculos e as permissões concedidas na Meta.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 8)
            SecondaryButton("Atualizar lista") { Task { await meta.reloadPages() } }.padding(.top, 14)
        } footer: {
            Spacer()
            HeaderButton("Voltar", primary: false, width: 150) { go(.setup("Instagram")) }
            HeaderButton("Conectar selecionadas", width: 170) { Task { await meta.refreshContent() }; close() }.disabled(meta.pages.isEmpty)
        }
    }
    private func accountBox(_ name: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.square.fill").font(.system(size: 14))
            VStack(alignment: .leading, spacing: 5) { Text(name).font(.system(size: 13, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // 47 / 53 · Manage
    @ViewBuilder private func manage(_ network: String) -> some View {
        if key(network) == "Meta" {
            ModalFrame(title: "Gerenciar Meta", subtitle: "Revise suas Páginas e contas profissionais vinculadas.", close: close) {
                DotStatus(on: meta.connected, onLabel: "Conectada", offLabel: "Não conectada").font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Facebook · Páginas").font(.system(size: 13, weight: .semibold)).padding(.top, 24)
                ForEach(meta.pages) { page in RuleRow(height: 42) { Text(page.name).font(.system(size: 12)); Spacer(); Text("Conectada").font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                Text("Instagram · Contas profissionais").font(.system(size: 13, weight: .semibold)).padding(.top, 20)
                ForEach(meta.pages.compactMap(\.instagramUsername), id: \.self) { name in RuleRow(height: 42) { Text("@\(name)").font(.system(size: 12)); Spacer(); Text("Conectada").font(.system(size: 11)).foregroundStyle(Palette.muted) } }
                HStack(spacing: 12) {
                    SecondaryButton("Atualizar contas") { Task { await meta.reloadPages(); await meta.refreshContent() } }
                    SecondaryButton("Autorizar novamente") { go(.setup("Instagram")) }
                }.padding(.top, 22)
                status(meta.message)
            } footer: {
                TextLink(title: "Remover conexão local") { go(.disconnect(network)) }
                Spacer()
                HeaderButton("Concluído", width: 170, action: close)
            }
        } else {
            ModalFrame(title: "Gerenciar \(network)", subtitle: "Revise o estado da conexão e as ações disponíveis.", close: close) {
                let account = center.accountLabel(network)
                HStack(alignment: .top, spacing: 16) {
                    Text(String(account.replacingOccurrences(of: "@", with: "").prefix(1)).uppercased()).font(.system(size: 18, weight: .semibold))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(account).font(.system(size: 13, weight: .semibold))
                        DotStatus(on: center.isConnected(network), onLabel: "Conectada", offLabel: "Não conectada").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(18).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Conta e permissões").font(.system(size: 13, weight: .semibold)).padding(.top, 26)
                Text("Acesso para publicar e consultar métricas.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 10)
                Text(network == "YouTube" && !youtube.analyticsNote.isEmpty ? youtube.analyticsNote : "Atualizada recentemente").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 14)
                HStack(spacing: 12) {
                    SecondaryButton("Atualizar dados") { Task { await refresh(network) } }
                    SecondaryButton("Autorizar novamente") { go(.setup(network)) }
                }.padding(.top, 14)
                status(message(network))
            } footer: {
                TextLink(title: "Desconectar conta") { go(.disconnect(network)) }
                Spacer()
                HeaderButton("Concluído", width: 170, action: close)
            }
        }
    }

    // 50 · Needs attention
    private func reconnect(_ network: String) -> some View {
        ModalFrame(title: "Conexão precisa de atenção", subtitle: "Sua autorização expirou ou precisa ser revisada.", close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Text(network).font(.system(size: 14, weight: .semibold))
                Text(message(network).isEmpty ? "Não foi possível atualizar a conta." : message(network)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Text("Autorize novamente para retomar os envios agendados.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Os conteúdos e rascunhos permanecem no workspace.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 16)
        } footer: {
            Spacer()
            HeaderButton("Agora não", primary: false, width: 150, action: close)
            HeaderButton("Autorizar novamente  ↗", width: 190) { go(.setup(network)) }
        }
    }

    // 51 · Disconnect
    private func disconnect(_ network: String) -> some View {
        ModalFrame(title: "Desconectar conta?", subtitle: "Confirme antes de remover o acesso desta conta.", close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(center.accountLabel(network)) · \(key(network) == "Meta" ? "Instagram e Facebook" : network)").font(.system(size: 14, weight: .semibold))
                Text("Publicações agendadas para esta conta não poderão ser enviadas.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Text("Você poderá conectar a conta novamente quando quiser.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
        } footer: {
            Spacer()
            HeaderButton("Cancelar", primary: false, width: 150, action: close)
            HeaderButton("Desconectar", width: 170) {
                Task {
                    switch key(network) {
                    case "YouTube": await youtube.disconnect()
                    case "TikTok": await tiktok.disconnect()
                    case "Threads": threads.disconnect()
                    case "X": await x.disconnect()
                    default: meta.disconnect()
                    }
                    close()
                }
            }
        }
    }

    // MARK: Helpers

    private func stepRow<Accessory: View>(_ number: Int, _ title: String, _ detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)").font(.system(size: 12)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                accessory().padding(.top, 6)
            }
        }
    }
    private func guide(_ network: String) -> some View {
        HStack(spacing: 18) {
            TextLink(title: "Guia de configuração  ↗") { NSWorkspace.shared.open(AppIdentity.setupGuide(network)) }
            TextLink(title: "Portal de desenvolvedores  ↗") {
                let urls = ["YouTube": "https://console.cloud.google.com/apis/credentials", "Instagram": "https://developers.facebook.com/apps/", "Facebook": "https://developers.facebook.com/apps/", "Threads": "https://developers.facebook.com/apps/", "TikTok": "https://developers.tiktok.com/", "X": "https://developer.x.com/en/portal/dashboard"]
                if let url = URL(string: urls[network] ?? "") { NSWorkspace.shared.open(url) }
            }
        }.padding(.top, 16)
    }
    @ViewBuilder private func status(_ text: String) -> some View {
        if !text.isEmpty { Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(4).padding(.top, 12) }
    }
    private func message(_ network: String) -> String {
        switch key(network) { case "YouTube": youtube.message; case "TikTok": tiktok.message; case "Threads": threads.message; case "X": x.message; default: meta.message }
    }
    private func refresh(_ network: String) async {
        switch key(network) {
        case "YouTube": await youtube.refresh()
        case "TikTok": await tiktok.refreshProfile()
        case "Threads": await threads.refresh()
        case "X": await x.refresh()
        default: await meta.refreshContent()
        }
    }
}
