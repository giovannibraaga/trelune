import SwiftUI
import AppKit
import AVFoundation

/// Formats offered in "Escolha o formato" (Figma 14). The published format still follows the media;
/// the choice filters the media picker and, for Story, turns on the Stories option.
enum FormatChoice {
    static func options(_ network: String) -> [(String, String)] {
        switch network {
        case "Instagram": [("Reels", "Vídeo vertical"), ("Post", "Imagem ou carrossel"), ("Story", "Conteúdo temporário")]
        case "YouTube": [("Vídeo", "Vídeo horizontal ou longo"), ("Short", "Vídeo vertical curto")]
        case "Facebook": [("Post", "Texto, imagem ou álbum"), ("Reel", "Vídeo vertical"), ("Story", "Conteúdo temporário")]
        case "TikTok": [("Vídeo", "Vídeo vertical"), ("Fotos", "Sequência de imagens")]
        case "Threads": [("Texto", "Somente texto"), ("Imagem", "Uma imagem"), ("Vídeo", "Um vídeo"), ("Carrossel", "De 2 a 20 itens")]
        default: [("Texto", "Até 280 caracteres"), ("Imagens", "Até 4 imagens")]
        }
    }
    static func wantsVideo(_ format: String) -> Bool? {
        switch format { case "Reels", "Reel", "Vídeo", "Short": true; case "Post", "Fotos", "Imagem", "Imagens", "Carrossel": false; default: nil }
    }
}

struct Composer: View {
    enum Step: Hashable { case destinations, format, individual, content, unified, customize(String), media, cover, review, destinationsReview, moment, confirmNow, scheduled, sent }
    @EnvironmentObject private var store: PostStore
    @EnvironmentObject private var center: PublishingCenter
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var host: MediaHost
    @AppStorage("mediaFiles") private var library = ""
    @AppStorage(Workspace.timeZoneKey) private var timezone = TimeZone.current.identifier
    let seed: ComposerSeed
    @State private var draft = Publication(title: "", text: "", platforms: [], date: Workspace.nextSlot, status: PostStatus.draft)
    @State private var loaded = false
    @State private var step: Step = .destinations
    @State private var history: [Step] = []
    @State private var single: String?
    @State private var formats: [String: String] = [:]
    @State private var publishNow = false
    @State private var message = ""
    @State private var preview = ""
    @State private var destinationsOpen = false
    @State private var dropTargeted = false
    // Media picker
    @State private var picks: [String] = []
    @State private var mediaFilter = "Todos"
    @State private var mediaQuery = ""

    var body: some View {
        page
            .onAppear(perform: load)
            .background { Button("") { back() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false) }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, MediaKind.isImage(url.path) || MediaKind.isVideo(url.path) else { return }
                        let path = url.path
                        Task { @MainActor in addMedia([path]) }
                    }
                }
                return true
            }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .destinations:
            PageScroll(title: "Nova publicação", subtitle: "Escolha onde seu conteúdo vai aparecer.", action: "Continuar  →", actionHandler: continueFromDestinations) { destinations }
        case .format:
            PageScroll(title: "Escolha o formato", subtitle: "Defina como publicar em cada plataforma.", action: "") { formatStep }
        case .individual:
            PageScroll(title: "Criar para \(single ?? "")", subtitle: "Publicação individual · personalize os detalhes deste destino.", action: "Salvar rascunho", primary: false, actionHandler: { save(PostStatus.draft) }) { individual }
        case .content:
            PageScroll(title: "Crie sua publicação", subtitle: "Prepare o conteúdo para as plataformas selecionadas.", action: "Salvar rascunho", actionHandler: { save(PostStatus.draft) }) { content }
        case .unified:
            PageScroll(title: "Uma ideia, várias redes.", subtitle: "Crie uma base e ajuste cada versão individualmente.", action: "Salvar rascunho", primary: false, actionHandler: { save(PostStatus.draft) }) { unified }
        case .customize(let network):
            PageScroll(title: "Personalizar conteúdo", subtitle: "Ajuste a versão para cada destino.", action: "") { customize(network) }
        case .media:
            PageScroll(title: "Escolher mídia", subtitle: "Selecione arquivos para sua publicação.", action: "") { mediaStep }
        case .cover:
            PageScroll(title: "Escolha a capa.", subtitle: "Defina o quadro ou envie uma imagem personalizada.", action: "") { CoverStep(video: draft.videos.first ?? "", coverTime: $draft.coverTime, coverPath: $draft.coverPath) { back() } }
        case .review:
            PageScroll(title: "Revise e agende", subtitle: "Confira os detalhes antes de publicar.", action: "Salvar rascunho", actionHandler: { save(PostStatus.draft) }) { review }
        case .destinationsReview:
            PageScroll(title: "Revise seus destinos", subtitle: "Cada versão pode ser ajustada antes de agendar.", action: "") { destinationsReview }
        case .moment:
            PageScroll(title: "Escolha o momento.", subtitle: "Agende no fuso do workspace ou publique agora.", action: "") { moment }
        case .confirmNow:
            PageScroll(title: "Publicar agora?", subtitle: "Revise antes de enviar o conteúdo às plataformas.", action: "") { confirmNow }
        case .scheduled:
            PageScroll(title: "Tudo pronto.", subtitle: "Sua publicação está agendada.", action: "") { scheduled }
        case .sent:
            let post = store.post(draft.id) ?? draft
            if attention(post) != nil {
                PageScroll(title: "Publicação precisa de atenção", subtitle: "Uma das plataformas não concluiu o envio.", action: "") { attentionCard(post) }
            } else {
                PageScroll(title: center.running.contains(post.id) ? "Enviando publicação…" : "Publicação enviada.", subtitle: "Acompanhe o resultado em cada plataforma.", action: "") { sent(post) }
            }
        }
    }

    // MARK: 06 · Destinations

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 0) {
            trail(1)
            SectionTitle(title: "Selecione as plataformas", subtitle: "Você pode publicar em uma ou em várias redes.").padding(.top, 34)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 26), count: 3), spacing: 24) {
                ForEach(PostStore.networks, id: \.self) { network in
                    let connected = center.isConnected(network)
                    SelectCard(title: network, subtitle: connected ? "Conta conectada" : "Não conectada",
                               state: connected ? (draft.platforms.contains(network) ? .selected : .available) : .connect) {
                        if connected { toggle(network) } else { router.connect(network) }
                    }
                }
            }.padding(.top, 26)
            HStack {
                let count = draft.platforms.filter(center.isConnected).count
                Text("\(count) \(count == 1 ? "plataforma selecionada" : "plataformas selecionadas")").font(.system(size: 12)).foregroundStyle(Palette.muted)
                if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(Palette.warning) }
                Spacer()
                HeaderButton("Continuar para conteúdo  →", width: 260, action: continueFromDestinations)
            }.padding(.top, 46)
            HStack(spacing: 22) {
                HeaderButton("Criar post unificado", width: 260) { startUnified() }
                Text("Uma ideia, várias redes. Ajuste cada versão depois.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }.padding(.top, 22)
        }
    }

    // MARK: 14 · Format

    private var formatStep: some View {
        let network = single ?? draft.platforms.first ?? "Instagram"
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: network, subtitle: "Escolha um formato")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 26), count: 3), spacing: 24) {
                ForEach(FormatChoice.options(network), id: \.0) { option in
                    SelectCard(title: option.0, subtitle: option.1, state: currentFormat(network) == option.0 ? .selected : .available, selectedLabel: "Selecionado") { formats[network] = option.0 }
                }
            }.padding(.top, 30)
            HStack { Spacer(); HeaderButton("Continuar  →", width: 240) { applyFormat(network); go(.individual) } }.padding(.top, 46)
        }
    }

    // MARK: 23–28 · Individual post

    private var individual: some View {
        let network = single ?? draft.platforms.first ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(FormatChoice.options(network).enumerated()), id: \.offset) { index, option in
                    if index > 0 { Text("/").foregroundStyle(Palette.muted) }
                    Button { formats[network] = option.0; applyFormat(network) } label: { Text(option.0).foregroundStyle(currentFormat(network) == option.0 ? Palette.text : Palette.muted) }.buttonStyle(.plain)
                }
            }.font(.system(size: 13, weight: .medium))
            HStack(alignment: .top, spacing: 34) {
                VStack(alignment: .leading, spacing: 20) {
                    if NetworkCopy.hasTitle(network) {
                        field(network == "YouTube" ? "Título  ·  até 100 caracteres" : "Título") { PlainInput(placeholder: "Adicione título…", text: $draft.title) }
                    }
                    field(NetworkCopy.textLabel(network), trailing: AnyView(counter(draft.text, network: network))) { PlainEditor(placeholder: "Escreva ou selecione o conteúdo…", text: $draft.text, height: 84) }
                    if NetworkOptions.hasOptions(network, meta: center.meta, host: host) {
                        field("Opções") { NetworkOptions(network: network, draft: $draft).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9)) }
                    }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    mediaPanel(network)
                    SocialPreview(networks: [network], post: prepared(), network: .constant(network))
                }.frame(width: 392)
            }.padding(.top, 26)
            footer(note: "Formato e disponibilidade dependem da plataforma.", button: "Continuar para agendar  →") { if validate() { go(.moment) } }
        }
    }

    private func mediaPanel(_ network: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mídia").font(.system(size: 13, weight: .semibold))
            Button { openMedia() } label: {
                Group {
                    if let first = draft.media.first { Thumbnail(path: first, height: 156, fit: true) } else { MediaPlaceholder(height: 156) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.top, 14)
            if draft.media.count > 1 { mediaStrip.padding(.top, 10) }
            HStack {
                TextLink(title: draft.media.isEmpty ? "Escolher da biblioteca" : "Trocar mídia") { openMedia() }
                Spacer()
                TextLink(title: "Importar do Mac") { chooseFiles() }
            }.padding(.top, 12)
            if !draft.videos.isEmpty {
                Text(network == "TikTok" ? "Capa do vídeo" : "Capa / miniatura").font(.system(size: 12, weight: .medium)).padding(.top, 20)
                SecondaryButton(draft.coverPath != nil || draft.coverTime != nil ? "Alterar capa" : "Escolher capa") { go(.cover) }.padding(.top, 12)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var mediaStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(draft.media.enumerated()), id: \.offset) { index, path in
                    VStack(spacing: 5) {
                        Thumbnail(path: path, size: 76)
                        Text(index == 0 && draft.media.count > 1 ? "Capa" : "\(index + 1)").font(.system(size: 10, weight: index == 0 && draft.media.count > 1 ? .semibold : .regular)).foregroundStyle(Palette.muted)
                    }
                    .contextMenu {
                        if index > 0 { Button("Mover para a esquerda") { draft.media.swapAt(index, index - 1) }; Button("Tornar capa") { let item = draft.media.remove(at: index); draft.media.insert(item, at: 0) } }
                        if index < draft.media.count - 1 { Button("Mover para a direita") { draft.media.swapAt(index, index + 1) } }
                        Button("Remover", role: .destructive) { draft.media.remove(at: index); if draft.videos.isEmpty { draft.coverTime = nil } }
                    }
                }
            }
        }.scrollIndicators(.hidden)
    }

    // MARK: 07 · Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            trail(2)
            HStack(alignment: .top, spacing: 38) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Conteúdo").font(.system(size: 16, weight: .semibold))
                    field("Legenda") { PlainEditor(placeholder: "Escreva uma legenda para sua publicação…", text: $draft.text, height: 120) }
                    field("Mídia") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 18) {
                                Button { openMedia() } label: { Text("+   Adicionar da biblioteca").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain)
                                Button { chooseFiles() } label: { Text("ou importar").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
                            }
                            if !draft.media.isEmpty { mediaStrip }
                        }.padding(14).frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(dropTargeted ? Palette.text : .clear, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    }
                }.frame(maxWidth: .infinity)
                previewPanel.frame(width: 376)
            }.padding(.top, 34)
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.platforms.joined(separator: "   ·   ")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                HStack {
                    SecondaryButton("Personalizar por rede") { if let first = draft.platforms.first { go(.customize(first)) } }
                    if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(Palette.warning) }
                    Spacer()
                    HeaderButton("Revisar publicação  →", width: 236) { if validate() { go(.review) } }
                }
            }.padding(.top, 40)
        }
    }

    private var previewPanel: some View {
        SocialPreview(networks: draft.platforms, post: prepared(), network: $preview)
    }

    // MARK: 19 · Unified post

    private var unified: some View {
        let post = prepared()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Post unificado").font(.system(size: 13, weight: .medium))
                Text("·").foregroundStyle(Palette.muted)
                Button { destinationsOpen.toggle() } label: { Text("\(draft.platforms.count) \(draft.platforms.count == 1 ? "rede selecionada" : "redes selecionadas")  ▾").font(.system(size: 13, weight: .medium)) }.buttonStyle(.plain)
                    .popover(isPresented: $destinationsOpen, arrowEdge: .bottom) { destinationsPopover }
            }
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Conteúdo base").font(.system(size: 18, weight: .semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Mídia").font(.system(size: 13, weight: .semibold))
                        Text(draft.media.isEmpty ? "Arraste arquivos ou escolha da biblioteca" : mediaSummary).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 14)
                        if !draft.media.isEmpty { mediaStrip.padding(.top, 14) }
                        HStack(spacing: 10) {
                            SecondaryButton("Escolher mídia") { openMedia() }
                            SecondaryButton("Importar do Mac") { chooseFiles() }
                            if draft.videos.count == 1 && draft.images.isEmpty { SecondaryButton("Capa") { go(.cover) } }
                        }.padding(.top, 18)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(dropTargeted ? Palette.text : .clear, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Legenda base").font(.system(size: 13, weight: .semibold))
                        PlainEditor(placeholder: "Escreva seu conteúdo…", text: $draft.text, height: 110, boxed: false)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Versões por plataforma").font(.system(size: 18, weight: .semibold)).padding(.bottom, 14)
                    ForEach(PostStore.networks.filter(draft.platforms.contains), id: \.self) { network in
                        let issue = center.problem(for: network, in: post)
                        RuleRow(height: 44) {
                            Text(network).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(issue == nil ? "Pronto" : "Revisar").font(.system(size: 12)).foregroundStyle(issue == nil ? Palette.muted : Palette.warning).help(issue ?? "").frame(width: 70, alignment: .leading)
                            TextLink(title: "Personalizar  ›", muted: false) { go(.customize(network)) }
                        }
                    }
                }.frame(width: 395)
            }.padding(.top, 26)
            HStack {
                if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(Palette.warning) }
                Spacer()
                HeaderButton("Revisar \(draft.platforms.count) \(draft.platforms.count == 1 ? "destino" : "destinos")  →", width: 270) { if validate() { go(.destinationsReview) } }
            }.padding(.top, 60)
        }
    }

    private var destinationsPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(PostStore.networks, id: \.self) { network in
                Button { toggle(network) } label: {
                    HStack(spacing: 10) {
                        DotStatus(on: draft.platforms.contains(network), onLabel: network, offLabel: network)
                        Spacer()
                        Text(center.isConnected(network) ? "Conectada" : "Não conectada").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(8).frame(width: 280).background(Palette.panel)
    }

    // MARK: 15 · Customize per network

    private func customize(_ network: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TabBar(options: draft.platforms.map { ($0, $0) }, selection: Binding(get: { network }, set: { step = .customize($0) }))
            Separator().padding(.top, 10)
            HStack(alignment: .top, spacing: 38) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("\(network) · \(currentFormat(network))").font(.system(size: 16, weight: .semibold))
                    if NetworkCopy.hasTitle(network) {
                        field("Título") { PlainInput(placeholder: draft.title.isEmpty ? "Adicione título…" : draft.title, text: Binding(get: { draft.titles[network] ?? "" }, set: { draft.titles[network] = $0 })) }
                    }
                    field(NetworkCopy.textLabel(network), trailing: AnyView(counter(draft.text(for: network), network: network))) {
                        PlainEditor(placeholder: draft.text.isEmpty ? "Escreva o texto desta rede…" : draft.text, text: Binding(get: { draft.overrides[network] ?? "" }, set: { draft.overrides[network] = $0 }), height: 120)
                    }
                    field("Mídia") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(draft.media.isEmpty ? "Sem mídia" : mediaSummary).font(.system(size: 13))
                            TextLink(title: "Trocar mídia") { openMedia() }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    if NetworkOptions.hasOptions(network, meta: center.meta, host: host) {
                        field("Opções") { NetworkOptions(network: network, draft: $draft).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9)) }
                    }
                }.frame(maxWidth: .infinity)
                SocialPreview(networks: draft.platforms, post: prepared(), network: Binding(get: { network }, set: { step = .customize($0) })).frame(width: 376)
            }.padding(.top, 26)
            HStack {
                TextLink(title: "Restaurar conteúdo base") { draft.overrides[network] = nil; draft.titles[network] = nil }
                Spacer()
                HeaderButton("Salvar versão", width: 236) { back() }
            }.padding(.top, 36)
        }
    }

    // MARK: 32 · Media picker

    private var mediaStep: some View {
        let files = Workspace.mediaLibrary.filter { path in
            let kind = mediaFilter == "Todos" || (mediaFilter == "Vídeos" ? MediaKind.isVideo(path) : MediaKind.isImage(path))
            return kind && FileManager.default.fileExists(atPath: path) && (mediaQuery.isEmpty || path.localizedCaseInsensitiveContains(mediaQuery))
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                TabBar(options: [("Todos", "Todos"), ("Vídeos", "Vídeos"), ("Imagens", "Imagens")], selection: $mediaFilter)
                Spacer()
                TextLink(title: "Importar do Mac") { chooseFiles(toPicker: true) }.padding(.trailing, 20)
                TextField("", text: $mediaQuery, prompt: Text("Buscar arquivo ou pasta").foregroundStyle(Palette.muted)).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 200)
            }
            Separator().padding(.top, 10)
            if files.isEmpty {
                Text("Nenhum arquivo. Adicione uma pasta em Biblioteca ou importe do Mac.").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 30)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 4), spacing: 22) {
                ForEach(files, id: \.self) { path in
                    let order = picks.firstIndex(of: path)
                    Button { if let order { picks.remove(at: order) } else { picks.append(path) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Thumbnail(path: path, height: 124, fit: true)
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).padding(.top, 6)
                            DotStatus(on: order != nil, onLabel: order.map { "Selecionado · \($0 + 1)" } ?? "Selecionado", offLabel: "Selecionar").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }.padding(10).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(order != nil ? Palette.stroke : .clear)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 30)
            HStack {
                Text("\(picks.count) \(picks.count == 1 ? "arquivo selecionado" : "arquivos selecionados")").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                HeaderButton("Adicionar à publicação", width: 260) { draft.media = picks; recordLibrary(picks); if draft.videos.isEmpty { draft.coverTime = nil }; back() }
            }.padding(.top, 40)
        }
    }

    // MARK: 34 · Destinations review

    private var destinationsReview: some View {
        let post = prepared()
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(post.platforms.count) \(post.platforms.count == 1 ? "destino selecionado" : "destinos selecionados")").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.bottom, 4)
            ForEach(PostStore.networks.filter(post.platforms.contains), id: \.self) { network in
                let issue = center.problem(for: network, in: post)
                RuleRow(height: 72) {
                    Text("\(network) · \(post.format(for: network))").font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(issue == nil ? "Pronto" : issue == "Conta não conectada." ? "Requer conexão" : issue!).font(.system(size: 12)).foregroundStyle(issue == nil ? Palette.muted : Palette.warning).lineLimit(1).frame(width: 300, alignment: .leading).help(issue ?? "")
                    TextLink(title: "Editar  ›", muted: false) { if issue == "Conta não conectada." { router.connect(network) } else { go(.customize(network)) } }.frame(width: 70, alignment: .leading)
                }
            }
            HStack { Spacer(); HeaderButton("Escolher data e horário", width: 260) { go(.moment) } }.padding(.top, 56)
        }
    }

    // MARK: 08 · Review

    private var review: some View {
        let post = prepared()
        let issues = center.problems(for: post)
        return VStack(alignment: .leading, spacing: 0) {
            trail(3)
            HStack(alignment: .top, spacing: 58) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Publicação").font(.system(size: 16, weight: .semibold))
                    Text(post.title.isEmpty ? String(post.text.prefix(60)) : post.title).font(.system(size: 15, weight: .medium)).padding(.top, 26)
                    Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
                    Separator().padding(.vertical, 26)
                    Text(issues.isEmpty ? "\(post.platforms.count) \(post.platforms.count == 1 ? "destino pronto" : "destinos prontos") para publicação" : "\(issues.count) \(issues.count == 1 ? "destino precisa" : "destinos precisam") de ajuste").font(.system(size: 13))
                    ForEach(issues.sorted { $0.key < $1.key }, id: \.key) { item in Text("\(item.key): \(item.value)").font(.system(size: 12)).foregroundStyle(Palette.warning).padding(.top, 8) }
                    SecondaryButton("Editar conteúdo") { back() }.padding(.top, 26)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Quando publicar?").font(.system(size: 18, weight: .semibold))
                        TabBar(options: [(false, "Agendar"), (true, "Publicar agora")], selection: $publishNow, size: 12).padding(.top, 14)
                        if publishNow {
                            Text("O conteúdo será enviado para \(post.platforms.joined(separator: ", ")) logo após a confirmação.").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 24)
                        } else {
                            whenFields.padding(.top, 20)
                        }
                    }.padding(22).frame(maxWidth: .infinity, minHeight: 440, alignment: .topLeading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                    if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(Palette.warning) }
                    HeaderButton(publishNow ? "Publicar agora" : "Confirmar agendamento", width: 395) { if publishNow { if validate() { go(.confirmNow) } } else { save(PostStatus.scheduled) } }
                    Text("Você pode reagendar ou cancelar antes do envio.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(width: 395)
            }.padding(.top, 34)
        }
    }

    @State private var dateOpen = false
    private var whenFields: some View {
        VStack(alignment: .leading, spacing: 22) {
            whenField("Data", Workspace.format(draft.date, date: .long, time: .omitted), open: $dateOpen) { MonthGrid(date: $draft.date).padding(16).frame(width: 320).background(Palette.panel) }
            timeFields
            VStack(alignment: .leading, spacing: 8) {
                Text("Fuso horário").font(.system(size: 12)).foregroundStyle(Palette.muted)
                ZoneMenu(identifier: $timezone)
            }
        }
    }
    private func whenField<Popup: View>(_ label: String, _ value: String, open: Binding<Bool>, @ViewBuilder popup: @escaping () -> Popup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Button { open.wrappedValue.toggle() } label: { Text(value).font(.system(size: 13)).padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                .popover(isPresented: open, arrowEdge: .bottom, content: popup)
        }
    }

    private var timeFields: some View {
        ScheduleTimeFields(date: $draft.date)
    }

    // MARK: 21 · Moment

    private var moment: some View {
        let post = prepared()
        return VStack(alignment: .leading, spacing: 0) {
            TabBar(options: [(false, "Agendar"), (true, "Publicar agora")], selection: $publishNow)
            HStack(alignment: .top, spacing: 70) {
                MonthGrid(date: $draft.date, large: true).frame(width: 380).opacity(publishNow ? 0.35 : 1).disabled(publishNow)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 36) {
                    VStack(alignment: .leading, spacing: 0) {
                        if publishNow {
                            Text("Publicar agora").font(.system(size: 13, weight: .semibold))
                            Text("O envio começa logo após a confirmação.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 14)
                        } else {
                            Text("Horário").font(.system(size: 13, weight: .semibold))
                            timeFields.padding(.top, 18)
                            Separator().padding(.vertical, 18)
                            Text("Fuso horário").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            ZoneMenu(identifier: $timezone).padding(.top, 8)
                        }
                        Separator().padding(.vertical, 18)
                        Text(publishNow ? "Agora" : "\(Workspace.format(draft.date, date: .long, time: .omitted)) · \(Workspace.time(draft.date))").font(.system(size: 13, weight: .medium))
                        Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
                        if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(Palette.warning).padding(.top, 12) }
                    }.padding(22).frame(width: 476, alignment: .leading).frame(minHeight: 360, alignment: .topLeading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                    HeaderButton(publishNow ? "Publicar agora" : "Confirmar agendamento", width: 280) { if publishNow { if validate() { go(.confirmNow) } } else { save(PostStatus.scheduled) } }
                }
            }.padding(.top, 30)
        }
    }

    // MARK: 35 / 09 / 36 / 17 · Results

    private var confirmNow: some View {
        let post = prepared()
        return ResultCard(width: 846) {
            Text("Pronto para publicar").font(.system(size: 20, weight: .semibold))
            Text(post.title.isEmpty ? String(post.text.prefix(60)) : post.title).font(.system(size: 15)).padding(.top, 22)
            Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
            Separator().padding(.vertical, 22)
            Text(center.problems(for: post).isEmpty ? "O envio começará após a confirmação." : "O envio começará após a confirmação. Destinos com pendência serão marcados como falha.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(spacing: 14) {
                SecondaryButton("Voltar") { back() }.frame(width: 156)
                HeaderButton("Confirmar publicação", width: 240) { publishNowAction() }
            }.padding(.top, 50)
        }
    }

    private var scheduled: some View {
        let post = store.post(draft.id) ?? draft
        return ResultCard(width: 820) {
            Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold))
            Text("Publicação agendada").font(.system(size: 22, weight: .semibold)).padding(.top, 22)
            Text("\(Workspace.format(post.date, date: .abbreviated, time: .omitted)) · \(Workspace.time(post.date)) · \(Workspace.timeZone.identifier)").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 16)
            Separator().padding(.vertical, 24)
            Text(post.title).font(.system(size: 14, weight: .medium))
            Text(post.platforms.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 12)
            HStack(spacing: 14) {
                HeaderButton("Ver no calendário", width: 204) { router.page = "Calendário" }
                HeaderButton("Voltar às publicações", primary: false, width: 204) { router.page = "Publicações" }
            }.padding(.top, 34)
        }
    }

    private func sent(_ post: Publication) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(post.platforms, id: \.self) { network in
                let result = post.results[network]
                RuleRow(height: 100) {
                    Text(network).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(resultLabel(result, running: center.running.contains(post.id))).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 340, alignment: .leading)
                    TextLink(title: "Ver detalhes  ↗", muted: false) {
                        if let link = result?.link.flatMap(URL.init(string:)) { NSWorkspace.shared.open(link) } else { router.detail(post.id) }
                    }.frame(width: 120, alignment: .leading)
                }
            }
            HeaderButton("Voltar às publicações", width: 220) { router.page = "Publicações" }.padding(.top, 96)
        }
    }

    private func attention(_ post: Publication) -> String? {
        guard !center.running.contains(post.id) else { return nil }
        return post.platforms.first { post.results[$0].map { !$0.succeeded && !$0.pending } ?? false }
    }
    private func attentionCard(_ post: Publication) -> some View {
        let network = attention(post) ?? ""
        return VStack(alignment: .leading, spacing: 18) {
            ResultCard(width: 846) {
                Text("!").font(.system(size: 20, weight: .semibold))
                Text("Não foi possível publicar no \(network)").font(.system(size: 20, weight: .semibold)).padding(.top, 16)
                Text("Verifique a conexão e tente novamente. Os outros destinos foram preservados.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 16)
                Separator().padding(.vertical, 24)
                Text("\(network)  ·  \(post.results[network]?.detail ?? "conexão precisa de atenção")").font(.system(size: 13)).textSelection(.enabled)
                Spacer(minLength: 60)
            }
            HStack(spacing: 14) {
                HeaderButton("Revisar conexão", width: 190) { router.connect(network) }
                HeaderButton("Voltar à publicação", primary: false, width: 190) { router.detail(post.id) }
            }.padding(.leading, 120)
        }
    }

    private func resultLabel(_ result: PlatformResult?, running: Bool) -> String {
        guard let result else { return running ? "Em processamento" : "Aguardando" }
        if result.pending { return "Na caixa de entrada do app" }
        return result.succeeded ? "Publicado" : "Falhou"
    }

    // MARK: Shared pieces

    private func trail(_ current: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(["Destinos", "Conteúdo", "Revisão"].enumerated()), id: \.offset) { index, name in
                if index > 0 { Text("/").foregroundStyle(Palette.muted) }
                Button { jump(to: index + 1) } label: { Text(String(format: "%02d  %@", index + 1, L(name))).foregroundStyle(index + 1 == current ? Palette.text : Palette.muted) }.buttonStyle(.plain).disabled(index + 1 > current)
            }
        }.font(.system(size: 12, weight: .medium))
    }
    private func field<Content: View>(_ label: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted); Spacer(); trailing }
            content()
        }
    }
    private func footer(note: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(message.isEmpty ? note : message).font(.system(size: 11)).foregroundStyle(message.isEmpty ? Palette.muted : Palette.warning)
            Spacer()
            HeaderButton(button, width: 280, action: action)
        }.padding(.top, 60)
    }
    private var mediaSummary: String {
        let images = draft.images.count, videos = draft.videos.count
        if videos == 1 && images == 0 { return URL(fileURLWithPath: draft.videos[0]).lastPathComponent }
        if images == 1 && videos == 0 { return URL(fileURLWithPath: draft.images[0]).lastPathComponent }
        return "Carrossel · \(draft.media.count) itens"
    }
    private func counter(_ text: String, network: String) -> some View {
        let used = NetworkLimits.length(text, for: network), limit = NetworkLimits.text(network)
        return Text("\(used)/\(limit)").font(.system(size: 11).monospacedDigit()).foregroundStyle(used > limit ? Palette.danger : Palette.muted)
    }

    // MARK: Navigation

    private func go(_ next: Step) { history.append(step); message = ""; step = next }
    private func back() {
        guard let previous = history.popLast() else { router.page = "Publicações"; return }
        message = ""; step = previous
    }
    private func jump(to number: Int) {
        let target: Step = number == 1 ? .destinations : number == 2 ? (single == nil ? .content : .individual) : .review
        if let index = history.lastIndex(of: target) { history.removeSubrange(index...) }
        step = target
    }
    private func continueFromDestinations() {
        let chosen = draft.platforms.filter(center.isConnected)
        guard !chosen.isEmpty else { message = "Selecione ao menos uma plataforma conectada."; return }
        if chosen.count == 1 { single = chosen[0]; go(.format) } else { single = nil; go(.content) }
    }
    private func startUnified() {
        single = nil
        if draft.platforms.isEmpty { draft.platforms = PostStore.networks.filter(center.isConnected) }
        if draft.platforms.isEmpty { draft.platforms = PostStore.networks }
        go(.unified)
    }
    private func openMedia() { picks = draft.media; if let network = single, let video = FormatChoice.wantsVideo(currentFormat(network)) { mediaFilter = video ? "Vídeos" : "Imagens" } else { mediaFilter = "Todos" }; go(.media) }
    private func currentFormat(_ network: String) -> String { formats[network] ?? draft.format(for: network).components(separatedBy: " ·").first ?? "" }
    private func applyFormat(_ network: String) {
        if formats[network] == "Story" { draft.stories = true }
    }

    // MARK: Data

    private func toggle(_ network: String) {
        if let index = draft.platforms.firstIndex(of: network) { draft.platforms.remove(at: index) } else { draft.platforms.append(network) }
        draft.platforms = PostStore.networks.filter(draft.platforms.contains)
    }
    private func recordLibrary(_ paths: [String]) {
        var files = library.components(separatedBy: "\n").filter { !$0.isEmpty }
        for path in paths where !files.contains(path) { files.append(path) }
        library = files.sorted().joined(separator: "\n")
    }
    private func addMedia(_ paths: [String]) {
        for path in paths where !draft.media.contains(path) { draft.media.append(path) }
        recordLibrary(paths)
    }
    private func chooseFiles(toPicker: Bool = false) {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = false; picker.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        guard picker.runModal() == .OK else { return }
        let paths = picker.urls.map(\.path)
        if toPicker { recordLibrary(paths); for path in paths where !picks.contains(path) { picks.append(path) } } else { addMedia(paths) }
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        if let id = seed.postID, let post = store.post(id) {
            draft = post
            if post.date < Date() { draft.date = Workspace.nextSlot }
            if post.platforms.count == 1 { single = post.platforms.first }
            step = seed.publishNow ? .confirmNow : seed.reschedule ? .moment : (single == nil ? .unified : .individual)
            history = seed.reschedule || seed.publishNow ? [] : [.destinations]
        } else {
            if let date = seed.date { draft.date = max(date, Date().addingTimeInterval(300)) }
            if !seed.mediaPaths.isEmpty { draft.media = seed.mediaPaths } else if let media = seed.mediaPath { draft.media = [media] }
            draft.platforms = []
        }
        #if DEBUG
        if let name = seed.startStep {
            if draft.platforms.isEmpty && name != "destinations" { draft.platforms = ["Instagram", "YouTube"] }
            if name == "format" { single = draft.platforms.first }
            let steps: [String: Step] = ["destinations": .destinations, "format": .format, "individual": .individual, "content": .content, "unified": .unified, "customize": .customize(draft.platforms.first ?? "Instagram"),
                                         "media": .media, "review": .review, "destinationsReview": .destinationsReview, "moment": .moment, "confirmNow": .confirmNow, "scheduled": .scheduled, "cover": .cover]
            if name == "individual" { single = draft.platforms.first }
            if name == "media" { picks = draft.media }
            step = steps[name] ?? .destinations
        }
        #endif
    }
    private func prepared() -> Publication {
        var post = draft
        post.title = post.title.trimmingCharacters(in: .whitespacesAndNewlines)
        post.overrides = post.overrides.filter { post.platforms.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        post.titles = post.titles.filter { post.platforms.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        post.results = post.results.filter { post.platforms.contains($0.key) }
        return post
    }
    private func validate() -> Bool {
        let post = prepared()
        if post.platforms.isEmpty { message = "Selecione pelo menos um destino."; return false }
        if post.title.isEmpty && post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && post.media.isEmpty { message = "Adicione conteúdo ou mídia."; return false }
        message = ""; return true
    }
    private func save(_ status: String) {
        var post = prepared()
        if status == PostStatus.scheduled {
            guard validate() else { return }
            guard post.date > Date() else { message = "Escolha um horário no futuro."; return }
        }
        if post.title.isEmpty { post.title = String(post.text.prefix(60)).components(separatedBy: "\n").first ?? "" }
        if post.title.isEmpty { post.title = "Sem título" }
        post.status = status
        store.update(post); draft = post
        if status == PostStatus.scheduled { history = []; step = .scheduled } else { router.page = "Publicações" }
    }
    private func publishNowAction() {
        guard validate() else { return }
        var post = prepared()
        if post.title.isEmpty { post.title = String(post.text.prefix(60)).components(separatedBy: "\n").first ?? "Sem título" }
        post.status = PostStatus.publishing
        let id = post.id
        history = []; step = .sent
        Task {
            // A post scheduled in the cloud is taken back first, while its date is still in the future.
            await center.cloud.release(id)
            post.date = Date()
            store.update(post); draft = post
            await center.publish(id)
        }
    }
}

/// App-styled hour and minute controls used by both scheduling steps.
struct ScheduleTimeFields: View {
    @Binding var date: Date
    @State private var openPart: Part?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 4)
    private var calendar: Calendar { Workspace.calendar }
    private enum Part: Equatable { case hour, minute }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            field("Hora", value: calendar.component(.hour, from: date), part: .hour, values: Array(0..<24))
            field("Minutos", value: calendar.component(.minute, from: date) / 15 * 15, part: .minute, values: [0, 15, 30, 45])
        }
    }

    private func field(_ title: String, value: Int, part: Part, values: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Button { openPart = openPart == part ? nil : part } label: {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", value)).font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Palette.text)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 11).frame(width: 88, height: 38).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(openPart == part ? Palette.accent.opacity(0.75) : Palette.stroke, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .popover(isPresented: Binding(get: { openPart == part }, set: { if !$0 && openPart == part { openPart = nil } }), arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(part == .hour ? "Selecione a hora" : "Selecione os minutos").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                        LazyVGrid(columns: columns, spacing: 5) {
                            ForEach(values, id: \.self) { option in
                                Button {
                                    let hour = part == .hour ? option : calendar.component(.hour, from: date)
                                    let minute = part == .minute ? option : calendar.component(.minute, from: date) / 15 * 15
                                    date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
                                    openPart = nil
                                } label: {
                                    Text(String(format: "%02d", option)).font(.system(size: 12, weight: option == value ? .semibold : .regular).monospacedDigit())
                                        .foregroundStyle(option == value ? Palette.bg : Palette.text)
                                        .frame(maxWidth: .infinity).frame(height: 32)
                                        .background(option == value ? Palette.accent : Palette.raised).clipShape(RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(12).frame(width: part == .hour ? 218 : 192).background(Palette.panel)
                }
        }
    }
}

// MARK: - Inputs without borders (Figma fields)

struct PlainInput: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.muted)).textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 14).frame(height: 50).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct PlainEditor: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 120
    var boxed = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text).scrollContentBackground(.hidden).font(.system(size: 13)).padding(.horizontal, boxed ? 9 : -5).padding(.vertical, boxed ? 10 : 0)
            if text.isEmpty { Text(placeholder).font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.horizontal, boxed ? 14 : 0).padding(.vertical, boxed ? 10 : 0).allowsHitTesting(false) }
        }
        .frame(height: height).background(boxed ? Palette.panel : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Month grid used by the scheduling screens (D S T Q Q S S, selected day as an inverted chip).
struct MonthGrid: View {
    @Binding var date: Date
    var large = false
    @State private var month = Date()
    private var calendar: Calendar { Workspace.calendar }
    var body: some View {
        VStack(alignment: .leading, spacing: large ? 22 : 12) {
            HStack(spacing: 18) {
                Text(title).font(.system(size: large ? 16 : 13, weight: .semibold))
                Button { shift(-1) } label: { Text("‹") }.buttonStyle(.plain).disabled(!canGoBack).opacity(canGoBack ? 1 : 0.3)
                Button { shift(1) } label: { Text("›") }.buttonStyle(.plain)
            }.font(.system(size: large ? 16 : 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: large ? 16 : 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, day in Text(verbatim: day).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted) }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let selected = calendar.isDate(day, inSameDayAs: date)
                        let past = calendar.startOfDay(for: day) < calendar.startOfDay(for: Date())
                        Button { pick(day) } label: {
                            Text("\(calendar.component(.day, from: day))").font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Palette.bg : past ? Palette.muted.opacity(0.4) : Palette.text)
                                .frame(width: 42, height: 32).background(selected ? Palette.accent : .clear).clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(past)
                    } else { Color.clear.frame(height: 32) }
                }
            }
        }.onAppear { month = date }
    }
    private var title: String {
        var style = Date.FormatStyle().month(.wide).year(); style.timeZone = Workspace.timeZone; style.locale = AppLanguage.locale
        let text = month.formatted(style).replacingOccurrences(of: " de ", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    private var canGoBack: Bool { calendar.compare(month, to: Date(), toGranularity: .month) == .orderedDescending }
    private var weekdaySymbols: [String] { var c = calendar; c.locale = AppLanguage.locale; return c.veryShortWeekdaySymbols }
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month), let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - 1 + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }
    private func shift(_ delta: Int) { month = calendar.date(byAdding: .month, value: delta, to: month) ?? month }
    private func pick(_ day: Date) {
        let h = calendar.component(.hour, from: date), m = calendar.component(.minute, from: date)
        date = calendar.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
    }
}

// MARK: - 20 · Cover

struct CoverStep: View {
    let video: String
    @Binding var coverTime: Double?
    @Binding var coverPath: String?
    let done: () -> Void
    @State private var duration = 0.0
    @State private var frame: NSImage?
    @State private var scrub = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Capa / miniatura").font(.system(size: 16, weight: .semibold))
            HStack(alignment: .top, spacing: 46) {
                ZStack {
                    Palette.raised
                    if let path = coverPath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else if let frame { Image(nsImage: frame).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "play.fill").font(.system(size: 24)).foregroundStyle(Palette.muted) }
                }.frame(width: 234, height: 350).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Quadro do vídeo (TikTok)").font(.system(size: 13, weight: .semibold)).padding(.top, 14)
                    if coverPath != nil, let frame { Image(nsImage: frame).resizable().aspectRatio(contentMode: .fit).frame(width: 90, height: 120).padding(.top, 8) }
                    Text(coverPath == nil ? "Escolha o momento que representa seu conteúdo." : URL(fileURLWithPath: coverPath!).lastPathComponent).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 14)
                    Slider(value: $scrub, in: 0...max(duration, 0.1)) { editing in if !editing { coverTime = scrub } }.tint(Palette.text).frame(width: 600).padding(.top, 28)
                    Text("\(stamp(scrub))  /  \(stamp(duration))").font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted).padding(.top, 14)
                    SecondaryButton(coverPath == nil ? "Usar imagem personalizada" : "Trocar imagem") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png]
                        if panel.runModal() == .OK { coverPath = panel.url?.path }
                    }.padding(.top, 34)
                    Text("Imagem: YouTube e Instagram Reels. No TikTok, escolha um quadro do vídeo; em rascunhos, ajuste a capa no TikTok.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 16)
                    HStack {
                        SecondaryButton("Usar padrão") { coverPath = nil; coverTime = nil; done() }
                        Spacer()
                        HeaderButton("Salvar capa", width: 266) { coverTime = scrub; done() }
                    }.padding(.top, 46)
                }
            }.padding(.top, 26)
        }
        .task(id: video) { duration = await CoverFrame.duration(video); scrub = coverTime ?? 0; await loadFrame(scrub) }
        .onChange(of: scrub) { _, value in Task { await loadFrame(value) } }
    }
    private func stamp(_ seconds: Double) -> String { String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)).replacingOccurrences(of: ".", with: ",") }
    private func loadFrame(_ seconds: Double) async {
        guard !video.isEmpty else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: video)))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600); generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image { frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
    }
}
