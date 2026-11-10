import SwiftUI
import AppKit
import AVFoundation

enum NetworkCopy {
    static func description(_ network: String) -> String {
        switch network {
        case "YouTube": "Vídeo longo ou vertical (Short), com título, descrição e miniatura."
        case "Instagram": "Imagem, carrossel de até 10 itens ou Reels."
        case "Facebook": "Texto, fotos em álbum ou Reel na Página."
        case "TikTok": "Vídeo ou sequência de fotos."
        case "Threads": "Texto, mídia única ou carrossel."
        default: "Texto com até 4 imagens."
        }
    }
    static func formats(_ network: String) -> [String] {
        switch network {
        case "YouTube": ["Vídeo", "Short"]
        case "Instagram": ["Post", "Carrossel", "Reels"]
        case "Facebook": ["Post", "Álbum", "Reel"]
        case "TikTok": ["Vídeo", "Fotos"]
        case "Threads": ["Texto", "Imagem", "Vídeo", "Carrossel"]
        default: ["Texto", "Imagens"]
        }
    }
    static func fields(_ network: String) -> String {
        switch network {
        case "YouTube": "Título, descrição, visibilidade e miniatura"
        case "Instagram": "Legenda e capa"
        case "Facebook": "Legenda e Página"
        case "TikTok": "Título, legenda e privacidade"
        case "Threads": "Texto"
        default: "Texto de até 280 caracteres"
        }
    }
    static func textLabel(_ network: String) -> String {
        switch network { case "YouTube": "Descrição"; case "Threads", "X": "Texto"; default: "Legenda" }
    }
    static func hasTitle(_ network: String) -> Bool { network == "YouTube" || network == "TikTok" }
}

struct IdentifiedString: Identifiable { let value: String; var id: String { value } }

// MARK: - Per-network options

struct NetworkOptions: View {
    let network: String
    @Binding var draft: Publication
    @EnvironmentObject private var center: PublishingCenter
    @EnvironmentObject private var host: MediaHost
    @EnvironmentObject private var router: Router

    @MainActor static func hasOptions(_ network: String, meta: MetaConnection, host: MediaHost) -> Bool {
        switch network {
        case "YouTube", "TikTok", "Facebook", "Instagram": true
        case "Threads": !host.configured
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch network {
            case "YouTube":
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) { FieldLabel("Visibilidade"); SelectField([("private", "Privado"), ("unlisted", "Não listado"), ("public", "Público")], selection: $draft.youtubePrivacy) }
                    VStack(alignment: .leading, spacing: 6) { FieldLabel("Tags"); InputField("criatividade, processo", text: Binding(get: { draft.tags.joined(separator: ", ") }, set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })) }
                }
            case "TikTok":
                PillPicker(options: [("INBOX", "Caixa de entrada · rascunho"), ("DIRECT", "Publicar direto")], selection: Binding(get: { draft.tiktokPrivacy == "INBOX" ? "INBOX" : "DIRECT" }, set: { draft.tiktokPrivacy = $0 == "INBOX" ? "INBOX" : "" }))
                if draft.tiktokPrivacy == "INBOX" {
                    Text("O conteúdo chega como notificação na caixa de entrada do app TikTok no celular; toque nela para editar e publicar.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    TikTokDirectPost(draft: $draft)
                }
            case "Facebook":
                if center.meta.pages.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Página")
                        SelectField(center.meta.pages.map { ($0.id, $0.name) }, selection: Binding(get: { draft.facebookPageID ?? center.meta.pages.first?.id ?? "" }, set: { draft.facebookPageID = $0 }))
                    }
                }
                storiesToggle
            case "Instagram":
                storiesToggle
            default: EmptyView()
            }
            if (network == "Instagram" || network == "Threads") && !host.configured {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Mídia por URL pública")
                    InputField("https://… (necessário sem hospedagem configurada)", text: Binding(get: { draft.publicMediaURL ?? "" }, set: { draft.publicMediaURL = $0.isEmpty ? nil : $0 }))
                    HStack(spacing: 4) {
                        Text("\(network) busca a mídia por URL. Configure a hospedagem S3 para enviar arquivos e carrosséis do Mac automaticamente.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Button("Configurar") { router.page = "Ajustes"; UserDefaults.standard.set("Hospedagem", forKey: "settingsTab") }.font(.system(size: 11))
                    }
                }
            }
        }
    }
}

extension NetworkOptions {
    /// Shared between Instagram and Facebook: the same post goes to both Stories.
    var storiesToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Também publicar nos Stories", isOn: $draft.stories).toggleStyle(.switch).font(.system(size: 12))
            Text(draft.media.isEmpty ? "Stories precisam de imagem ou vídeo; posts só de texto não vão para os Stories." : "A \(draft.media.count > 1 ? "primeira mídia do carrossel" : "mídia") vai também para os Stories do Instagram e do Facebook.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

/// Direct Post settings laid out as TikTok's content sharing guidelines require: the posting account,
/// privacy chosen by the user (no default), interactions off until enabled, commercial disclosure and the
/// music usage declaration.
struct TikTokDirectPost: View {
    @Binding var draft: Publication
    @EnvironmentObject private var center: PublishingCenter
    @State private var creator: TikTokConnection.Creator?
    @State private var problem = ""
    @State private var duration: Double = 0
    private static let labels = ["PUBLIC_TO_EVERYONE": "Todos", "MUTUAL_FOLLOW_FRIENDS": "Amigos", "FOLLOWER_OF_CREATOR": "Seguidores", "SELF_ONLY": "Somente eu"]
    private var photos: Bool { draft.videos.isEmpty && !draft.images.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let creator {
                HStack(spacing: 10) {
                    RemoteThumb(url: creator.creator_avatar_url, width: 28, height: 28).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Publicando como \(creator.creator_nickname)").font(.system(size: 12, weight: .semibold))
                        Text("@\(creator.creator_username) no TikTok").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Quem pode ver este post")
                    let options = creator.privacy_level_options.filter { !(draft.tiktokDisclose && draft.tiktokBranded && $0 == "SELF_ONLY") }
                    SelectField([("", "Selecione…")] + options.map { ($0, Self.labels[$0] ?? $0) }, selection: $draft.tiktokPrivacy)
                    if draft.tiktokDisclose && draft.tiktokBranded { Text("Conteúdo de marca não pode ser privado.").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Permitir que os usuários")
                    HStack(spacing: 16) {
                        Toggle("Comentem", isOn: $draft.tiktokAllowComments).disabled(creator.comment_disabled)
                        if !photos {
                            Toggle("Façam Dueto", isOn: $draft.tiktokAllowDuet).disabled(creator.duet_disabled)
                            Toggle("Façam Costura", isOn: $draft.tiktokAllowStitch).disabled(creator.stitch_disabled)
                        }
                    }.toggleStyle(.checkbox).font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Divulgar conteúdo comercial", isOn: $draft.tiktokDisclose).toggleStyle(.switch).font(.system(size: 12))
                    if draft.tiktokDisclose {
                        Toggle("Sua marca — promove você ou seu próprio negócio", isOn: $draft.tiktokYourBrand).toggleStyle(.checkbox).font(.system(size: 12))
                        Toggle("Conteúdo de marca — promove outra marca ou terceiro", isOn: $draft.tiktokBranded).toggleStyle(.checkbox).font(.system(size: 12))
                        Text(draft.tiktokBranded ? "O post será rotulado como “Parceria paga”." : draft.tiktokYourBrand ? "O post será rotulado como “Conteúdo promocional”." : "Marque pelo menos uma opção para divulgar.")
                            .font(.system(size: 11)).foregroundStyle(draft.tiktokYourBrand || draft.tiktokBranded ? Palette.muted : Palette.warning)
                    }
                }
                if !photos, duration > Double(creator.max_video_post_duration_sec) {
                    Text("O vídeo tem \(Int(duration)) s; esta conta aceita até \(creator.max_video_post_duration_sec) s.").font(.system(size: 11)).foregroundStyle(Palette.danger)
                }
                (Text("Ao publicar, você concorda com a ") + Text("[Confirmação de Uso de Música](https://www.tiktok.com/legal/page/global/music-usage-confirmation/en)") + Text(draft.tiktokDisclose && draft.tiktokBranded ? " e a [Política de Conteúdo de Marca](https://www.tiktok.com/legal/page/global/bc-policy/en) do TikTok." : " do TikTok."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).tint(Palette.accent)
                Text("Depois do envio, o TikTok pode levar alguns minutos para processar e mostrar o post no perfil.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else if !problem.isEmpty {
                Text(problem).font(.system(size: 11)).foregroundStyle(Palette.warning)
            } else {
                ProgressView("Consultando a conta do TikTok…").controlSize(.small)
            }
        }
        .task {
            do { creator = try await center.tiktok.creator() } catch { problem = error.localizedDescription }
            if let video = draft.videos.first { duration = await CoverFrame.duration(video) }
            if let creator {
                if creator.comment_disabled { draft.tiktokAllowComments = false }
                if creator.duet_disabled { draft.tiktokAllowDuet = false }
                if creator.stitch_disabled { draft.tiktokAllowStitch = false }
                if !creator.privacy_level_options.contains(draft.tiktokPrivacy) { draft.tiktokPrivacy = "" }
            }
        }
        .onChange(of: draft.tiktokBranded) { _, branded in if branded && draft.tiktokPrivacy == "SELF_ONLY" { draft.tiktokPrivacy = "" } }
    }
}

// MARK: - Preview

struct NetworkPreview: View {
    let network: String
    let post: Publication
    @AppStorage("userName") private var userName = NSFullUserName()
    @State private var page = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader("Prévia")
            Text("\(network) · \(post.format(for: network))").font(.system(size: 13, weight: .medium)).padding(.top, 18)
            if !post.media.isEmpty {
                ZStack(alignment: .bottom) {
                    Thumbnail(path: post.media[min(page, post.media.count - 1)], height: network == "YouTube" ? 190 : 300, fit: true)
                    if post.media.count > 1 {
                        HStack(spacing: 5) { ForEach(0..<min(post.media.count, 20), id: \.self) { i in Circle().fill(Color.white.opacity(i == page ? 1 : 0.45)).frame(width: 6, height: 6) } }.padding(8)
                    }
                }.padding(.top, 18)
                if post.media.count > 1 {
                    HStack {
                        Button { page = max(page - 1, 0) } label: { Text("‹") }.buttonStyle(.plain).disabled(page == 0)
                        Spacer(); Text("\(page + 1) de \(post.media.count)").font(.system(size: 11)).foregroundStyle(Palette.muted); Spacer()
                        Button { page = min(page + 1, post.media.count - 1) } label: { Text("›") }.buttonStyle(.plain).disabled(page >= post.media.count - 1)
                    }.padding(.top, 10)
                }
            }
            if NetworkCopy.hasTitle(network) && !post.title(for: network).isEmpty { Text(post.title(for: network)).font(.system(size: 15, weight: .semibold)).padding(.top, 16) }
            Text(post.text(for: network).isEmpty ? "Sua publicação aparecerá aqui." : post.text(for: network)).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(10).padding(.top, 14)
            Text(userName).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 14)
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: post.media.count) { _, count in if page >= count { page = max(count - 1, 0) } }
    }
}
