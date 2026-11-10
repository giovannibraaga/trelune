import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// MARK: - Library

struct Library: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var store: PostStore
    @AppStorage("mediaFiles") private var serialized = ""
    @AppStorage("libraryFolders") private var foldersSerialized = ""
    @State var filter = "Todos os arquivos"
    @State var query = ""
    @State var dropTargeted = false
    @State private var files: [String] = []
    @State private var scanned: Set<String> = []
    @State private var selection: [String] = []
    @State private var loading = true
    private var imported: [String] { serialized.components(separatedBy: "\n").filter { !$0.isEmpty } }
    private var folders: [String] { foldersSerialized.components(separatedBy: "\n").filter { !$0.isEmpty } }
    private var shown: [String] {
        files.filter { path in
            let kind = filter == "Todos os arquivos" || (filter == "Vídeos" ? MediaKind.isVideo(path) : filter == "Imagens" ? MediaKind.isImage(path) : !FileManager.default.fileExists(atPath: path))
            return kind && (query.isEmpty || path.localizedCaseInsensitiveContains(query))
        }
    }
    /// Files grouped by their folder, most recently changed folder first.
    private var groups: [(folder: String, files: [String])] {
        let grouped = Dictionary(grouping: shown) { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        func stamp(_ folder: String) -> Date { ((try? FileManager.default.attributesOfItem(atPath: folder))?[.modificationDate] as? Date) ?? .distantPast }
        return grouped.map { ($0.key, $0.value.sorted { $0.localizedStandardCompare($1) == .orderedAscending }) }.sorted { stamp($0.folder) > stamp($1.folder) }
    }
    var body: some View {
        PageScroll(title: "Biblioteca", subtitle: "Suas mídias, prontas para criar.", action: "+ Importar mídia", actionHandler: load) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 14) {
                        ForEach(["Todos os arquivos", "Vídeos", "Imagens", "Indisponíveis"], id: \.self) { category in
                            Button { filter = category } label: { Text(category).font(.system(size: 13, weight: .medium)).foregroundStyle(filter == category ? Palette.text : Palette.muted) }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    TextField("", text: $query, prompt: Text("Buscar arquivo ou pasta").foregroundStyle(Palette.muted)).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 230)
                }
                Separator().padding(.top, 16)
                HStack {
                    Text("Pastas monitoradas").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    TextLink(title: "Adicionar pasta  +") { pickFolder() }.padding(.trailing, 20)
                }.padding(.top, 26)
                if folders.isEmpty { Text("Nenhuma pasta. Adicione a pasta onde você salva os conteúdos (ou arraste uma pasta para cá).").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 14) }
                if !selection.isEmpty {
                    HStack(spacing: 16) {
                        Text("\(selection.count) \(selection.count == 1 ? "arquivo selecionado" : "arquivos selecionados")").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        TextLink(title: "Limpar") { selection = [] }
                        Spacer()
                        HeaderButton(selection.count > 1 ? "Criar carrossel" : "Criar publicação", width: 200) { router.compose(ComposerSeed(mediaPaths: selection)); selection = [] }
                    }.padding(.top, 18)
                }
                if loading && files.isEmpty { ProgressView().controlSize(.small).padding(.top, 30) }
                else if files.isEmpty { Text("Sua biblioteca está vazia. Adicione uma pasta monitorada ou importe imagens e vídeos.").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 30) }
                else if shown.isEmpty { Text("Nenhum arquivo corresponde ao filtro.").font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 30) }
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(groups, id: \.folder) { group in
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(spacing: 14) {
                                Text(folderLabel(group.folder)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                Spacer()
                                TextLink(title: "Selecionar todos") { selection = Array(NSOrderedSet(array: selection + group.files.filter(FileManager.default.fileExists))) as? [String] ?? selection }
                                TextLink(title: "Mostrar no Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: group.folder)) }
                                if folders.contains(group.folder) { TextLink(title: "Parar de monitorar") { foldersSerialized = folders.filter { $0 != group.folder }.joined(separator: "\n") } }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 26), count: 3), spacing: 26) {
                                ForEach(group.files, id: \.self) { path in tile(path) }
                            }
                        }
                    }
                }.padding(.top, 18)
            }.padding(.top, -6)
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 16).stroke(Palette.text, style: StrokeStyle(lineWidth: 1.5, dash: [8])).padding(12).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let path = url.path
                    Task { @MainActor in
                        var isFolder: ObjCBool = false
                        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { addFolder(path) }
                        else if MediaKind.isVideo(path) || MediaKind.isImage(path) { add([path]) }
                    }
                }
            }
            return true
        }
        .task(id: serialized + foldersSerialized) { await refresh(force: true) }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(20)); await refresh(force: false) } }
    }

    private func tile(_ path: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        let order = selection.firstIndex(of: path)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if exists { Thumbnail(path: path, height: 146, fit: true) } else { MediaPlaceholder(video: MediaKind.isVideo(path), height: 146) }
            }
            .overlay(alignment: .topTrailing) { if let order { Text("\(order + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.bg).frame(width: 22, height: 22).background(Palette.accent).clipShape(Circle()).padding(8) } }
            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).padding(.top, 14).padding(.horizontal, 14)
            Text(exists ? details(path) : "Indisponível").font(.system(size: 10)).foregroundStyle(exists ? Palette.muted : Palette.danger).padding(.top, 6).padding(.horizontal, 14).padding(.bottom, 14)
        }
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(order != nil ? Palette.text.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if exists { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
        .onTapGesture { if exists { toggle(path) } }
        .contextMenu {
            Button("Criar publicação com este arquivo") { router.compose(ComposerSeed(mediaPath: path)) }.disabled(!exists)
            Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.disabled(!exists)
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.disabled(!exists)
            if imported.contains(path) && !scanned.contains(path) { Divider(); Button("Remover da biblioteca", role: .destructive) { serialized = imported.filter { $0 != path }.joined(separator: "\n") } }
        }
    }

    private func folderLabel(_ folder: String) -> String {
        for root in folders where folder.hasPrefix(root) {
            let relative = String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : relative.replacingOccurrences(of: "/", with: " / ")
        }
        return folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    private func refresh(force: Bool) async {
        let list = imported
        let found = await Task.detached(priority: .userInitiated) { Workspace.scannedFolders(force: force) }.value
        scanned = Set(found)
        files = Array(Set(list + found)).sorted()
        loading = false
    }
    private func toggle(_ path: String) { if let index = selection.firstIndex(of: path) { selection.remove(at: index) } else { selection.append(path) } }
    private func details(_ path: String) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(MediaKind.isVideo(path) ? "Vídeo" : "Imagem") · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
    private func add(_ paths: [String]) { serialized = Array(Set(imported + paths)).sorted().joined(separator: "\n") }
    private func addFolder(_ path: String) { if !folders.contains(path) { foldersSerialized = (folders + [path]).joined(separator: "\n") } }
    private func pickFolder() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true; picker.prompt = "Monitorar"
        if picker.runModal() == .OK { for url in picker.urls { addFolder(url.path) } }
    }
    func load() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = false; picker.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        if picker.runModal() == .OK { add(picker.urls.map(\.path)) }
    }
}

// MARK: - Connections

struct Connections: View {
    @EnvironmentObject var center: PublishingCenter
    @EnvironmentObject var router: Router
    @EnvironmentObject var youtube: YouTubeConnection
    @EnvironmentObject var tiktok: TikTokConnection
    @EnvironmentObject var meta: MetaConnection
    @EnvironmentObject var threads: ThreadsConnection
    @EnvironmentObject var x: XConnection
    var body: some View {
        let connected = PostStore.networks.filter(center.isConnected)
        PageScroll(title: "Conexões", subtitle: "Gerencie suas contas e os destinos de publicação.", action: "+ Conectar conta", actionHandler: { router.dialog = .choose }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(connected.count) \(connected.count == 1 ? "conectada" : "conectadas")   ·   \(PostStore.networks.count - connected.count) \(PostStore.networks.count - connected.count == 1 ? "disponível" : "disponíveis")").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Separator().padding(.top, 18)
                ForEach(PostStore.networks, id: \.self) { network in
                    let on = center.isConnected(network)
                    let attention = needsAttention(network)
                    RuleRow(height: 90) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(network).font(.system(size: 15, weight: .semibold))
                            Text(on ? center.accountLabel(network) : attention ? "Autorização expirada ou incompleta" : "Ainda não conectada").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            if on { DotStatus(on: true, onLabel: "Conectada") }
                            else if attention { DotStatus(on: false, offLabel: "Precisa de atenção") }
                            else { Text("Não conectada") }
                        }.foregroundStyle(Palette.muted).font(.system(size: 11, weight: .medium)).frame(width: 220, alignment: .leading)
                        HeaderButton(on ? "Gerenciar" : attention ? "Revisar" : "Conectar", primary: !on, width: 158) { router.dialog = on ? .manage(network) : attention ? .reconnect(network) : .setup(network) }
                    }
                }
            }.padding(.top, -6)
        }
        .task { if meta.connected && meta.pagePosts.isEmpty { await meta.refreshContent() }; if threads.connected && threads.recent.isEmpty { await threads.refresh() } }
    }
    /// Credentials saved but no working authorization.
    private func needsAttention(_ network: String) -> Bool {
        switch network {
        case "YouTube": youtube.configured && !center.isConnected(network)
        case "TikTok": tiktok.configured && !tiktok.connected
        case "X": x.configured && !x.connected
        case "Instagram", "Facebook": meta.configured && !center.isConnected(network)
        default: false
        }
    }
}

