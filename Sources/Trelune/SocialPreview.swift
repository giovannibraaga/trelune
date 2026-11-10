import SwiftUI

/// Preview of a publication as each network shows it. The header switches between the selected
/// networks (tabs or ‹ ›) and carousels page through their media.
struct SocialPreview: View {
    let networks: [String]
    let post: Publication
    @Binding var network: String
    @EnvironmentObject private var center: PublishingCenter
    @AppStorage("userName") private var userName = NSFullUserName()
    @State private var page = 0

    private var current: String { networks.contains(network) ? network : (networks.first ?? "Instagram") }
    private var account: String {
        let label = center.accountLabel(current)
        return center.isConnected(current) && !label.isEmpty ? label : (userName.isEmpty ? "Sua conta" : userName)
    }
    private var handle: String { "@" + account.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "@", with: "") }
    private var text: String { post.text(for: current) }
    private var title: String { post.title(for: current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ColumnHeader("Prévia")
                Spacer()
                Button { step(-1) } label: { Text("‹") }.buttonStyle(.plain).disabled(networks.count < 2)
                Text("\(current) · \(post.format(for: current))").font(.system(size: 11, weight: .medium))
                Button { step(1) } label: { Text("›") }.buttonStyle(.plain).disabled(networks.count < 2)
            }.font(.system(size: 13, weight: .semibold))
            if networks.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(networks, id: \.self) { item in
                            Button { network = item; page = 0 } label: {
                                BrandLogo(network: item, size: 13).foregroundStyle(item == current ? Palette.text : Palette.muted)
                                    .frame(width: 30, height: 26).background(item == current ? Palette.raised : .clear).clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(item)
                        }
                    }
                }.padding(.top, 12)
            }
            mock.padding(.top, 16)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: post.media.count) { _, count in if page >= count { page = max(count - 1, 0) } }
    }

    private func step(_ delta: Int) {
        guard let index = networks.firstIndex(of: current), !networks.isEmpty else { return }
        network = networks[(index + delta + networks.count) % networks.count]; page = 0
    }

    // MARK: Per-network frames

    @ViewBuilder private var mock: some View {
        switch current {
        case "YouTube": youtube
        case "TikTok": tiktok
        case "X": xPost
        case "Threads": threads
        case "Facebook": facebook
        default: instagram
        }
    }

    private var instagram: some View {
        VStack(alignment: .leading, spacing: 10) {
            profile(account, subtitle: nil)
            media(aspect: post.videos.isEmpty ? 4.0 / 5.0 : 9.0 / 16.0, maxHeight: 360)
            HStack(spacing: 14) { icon("heart"); icon("bubble.right"); icon("paperplane"); Spacer(); icon("bookmark") }
            caption(bold: account, text: text, lines: 3)
        }
    }

    private var facebook: some View {
        VStack(alignment: .leading, spacing: 10) {
            profile(account, subtitle: "Agora · Público")
            if !text.isEmpty { Text(text).font(.system(size: 12)).lineLimit(4) }
            media(aspect: post.videos.isEmpty ? 1 : 9.0 / 16.0, maxHeight: 320)
            Separator()
            HStack { Label("Curtir", systemImage: "hand.thumbsup"); Spacer(); Label("Comentar", systemImage: "bubble.left"); Spacer(); Label("Compartilhar", systemImage: "arrowshape.turn.up.right") }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var youtube: some View {
        let short = post.format(for: "YouTube") == "Short" || (post.videos.first.map { _ in false } ?? false)
        return VStack(alignment: .leading, spacing: 10) {
            media(aspect: short ? 9.0 / 16.0 : 16.0 / 9.0, maxHeight: short ? 340 : 200)
            Text(title.isEmpty ? "Título do vídeo" : title).font(.system(size: 14, weight: .semibold)).lineLimit(2).foregroundStyle(title.isEmpty ? Palette.muted : Palette.text)
            HStack(spacing: 8) { avatar(size: 22); Text(account).font(.system(size: 11)).foregroundStyle(Palette.muted); Text("· \(privacy)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if !text.isEmpty { Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(3) }
        }
    }
    private var privacy: String { L(["public": "Público", "unlisted": "Não listado", "private": "Privado"][post.youtubePrivacy] ?? post.youtubePrivacy) }

    private var tiktok: some View {
        ZStack(alignment: .bottomLeading) {
            media(aspect: 9.0 / 16.0, maxHeight: 380, rounded: 14)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom).clipShape(RoundedRectangle(cornerRadius: 14)).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 4) {
                Text(handle).font(.system(size: 12, weight: .semibold))
                Text(text.isEmpty ? "Sua legenda aparece aqui." : text).font(.system(size: 11)).lineLimit(3)
            }.foregroundStyle(.white).padding(12).padding(.trailing, 40)
            VStack(spacing: 14) { Image(systemName: "heart.fill"); Image(systemName: "ellipsis.bubble.fill"); Image(systemName: "bookmark.fill"); Image(systemName: "arrowshape.turn.up.right.fill") }
                .font(.system(size: 16)).foregroundStyle(.white).padding(12).frame(maxWidth: .infinity, alignment: .bottomTrailing)
        }.frame(maxWidth: 220).frame(maxWidth: .infinity)
    }

    private var threads: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(size: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(handle.dropFirst()).font(.system(size: 12, weight: .semibold))
                Text(text.isEmpty ? "Escreva seu texto…" : text).font(.system(size: 12)).foregroundStyle(text.isEmpty ? Palette.muted : Palette.text).lineLimit(8)
                if !post.media.isEmpty { media(aspect: 4.0 / 5.0, maxHeight: 260) }
                HStack(spacing: 16) { icon("heart"); icon("bubble.right"); icon("arrow.2.squarepath"); icon("paperplane") }.padding(.top, 2)
            }
        }
    }

    private var xPost: some View {
        let length = NetworkLimits.length(text, for: "X")
        return HStack(alignment: .top, spacing: 10) {
            avatar(size: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) { Text(account).font(.system(size: 12, weight: .semibold)); Text("\(handle) · agora").font(.system(size: 11)).foregroundStyle(Palette.muted) }.lineLimit(1)
                Text(text.isEmpty ? "O que está acontecendo?" : text).font(.system(size: 12)).foregroundStyle(text.isEmpty ? Palette.muted : Palette.text).lineLimit(8)
                if !post.images.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(post.images.count, 2)), spacing: 4) {
                        ForEach(post.images.prefix(4), id: \.self) { Thumbnail(path: $0, height: post.images.count > 2 ? 80 : 140) }
                    }
                }
                HStack(spacing: 18) { icon("bubble.left"); icon("arrow.2.squarepath"); icon("heart"); icon("chart.bar"); Spacer(); Text("\(length)/280").font(.system(size: 10).monospacedDigit()).foregroundStyle(length > 280 ? Palette.danger : Palette.muted) }
            }
        }
    }

    // MARK: Pieces

    private func profile(_ name: String, subtitle: String?) -> some View {
        HStack(spacing: 8) {
            avatar(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            }
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
    private func avatar(size: CGFloat) -> some View {
        Text(String(account.replacingOccurrences(of: "@", with: "").prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Palette.bg)
            .frame(width: size, height: size).background(Palette.accent).clipShape(Circle())
    }
    private func icon(_ name: String) -> some View { Image(systemName: name).font(.system(size: 13)).foregroundStyle(Palette.secondary) }
    private func caption(bold: String, text: String, lines: Int) -> some View {
        (Text(verbatim: bold).fontWeight(.semibold) + Text(verbatim: " ") + Text(text.isEmpty ? "Sua legenda aparece aqui." : text)).font(.system(size: 12)).lineLimit(lines)
    }

    /// Media area with carousel paging; a neutral placeholder when there is no media.
    @ViewBuilder private func media(aspect: CGFloat, maxHeight: CGFloat, rounded: CGFloat = 8) -> some View {
        if post.media.isEmpty {
            if current != "Threads" && current != "X" {
                ZStack { Palette.raised; Image(systemName: "photo").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.muted) }
                    .aspectRatio(aspect, contentMode: .fit).frame(maxHeight: maxHeight).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: rounded))
            }
        } else {
            let index = min(page, post.media.count - 1)
            ZStack {
                Thumbnail(path: post.media[index], height: maxHeight, fit: true)
                if post.media.count > 1 {
                    HStack {
                        pager("chevron.left") { page = max(page - 1, 0) }.opacity(index == 0 ? 0 : 1)
                        Spacer()
                        pager("chevron.right") { page = min(page + 1, post.media.count - 1) }.opacity(index >= post.media.count - 1 ? 0 : 1)
                    }.padding(.horizontal, 8)
                    VStack {
                        Spacer()
                        HStack(spacing: 4) { ForEach(0..<min(post.media.count, 20), id: \.self) { i in Circle().fill(Color.white.opacity(i == index ? 1 : 0.45)).frame(width: 5, height: 5) } }.padding(8)
                    }
                    VStack { HStack { Spacer(); Text("\(index + 1)/\(post.media.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3).background(Color.black.opacity(0.55)).clipShape(Capsule()).padding(8) }; Spacer() }
                }
            }.frame(height: maxHeight).clipShape(RoundedRectangle(cornerRadius: rounded))
        }
    }
    private func pager(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.black).frame(width: 24, height: 24).background(Color.white.opacity(0.85)).clipShape(Circle()) }.buttonStyle(.plain)
    }
}
