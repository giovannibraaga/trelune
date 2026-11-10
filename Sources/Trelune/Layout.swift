import SwiftUI

// Building blocks from the Figma file (Trelune · Minimalista).

/// "01 Destinos  /  02 Conteúdo  /  03 Revisão"
struct StepTrail: View {
    let current: Int
    var steps = ["Destinos", "Conteúdo", "Revisão"]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Text("/").foregroundStyle(Palette.muted) }
                Text(String(format: "%02d  %@", index + 1, L(step))).foregroundStyle(index + 1 == current ? Palette.text : Palette.muted)
            }
        }.font(.system(size: 12, weight: .medium))
    }
}

/// Section heading inside a page (16–18 pt semibold) with an optional line below.
struct SectionTitle: View {
    let title: String
    var subtitle = ""
    var size: CGFloat = 16
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: size, weight: .semibold))
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted) }
        }
    }
}

enum CardState { case selected, available, connect, none }

/// Selectable card: name, account line and "● Selecionada" / "○ Selecionar" / "Conectar ↗".
struct SelectCard<Footer: View>: View {
    let title: String
    var subtitle = ""
    var state: CardState = .none
    var selectedLabel = "Selecionada"
    var action: () -> Void = {}
    @ViewBuilder var footer: Footer
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 12) }
                Spacer(minLength: 18)
                switch state {
                case .selected: Label { Text(selectedLabel) } icon: { Circle().fill(Palette.text).frame(width: 8, height: 8) }.labelStyle(DotLabel())
                case .available: Label { Text("Selecionar") } icon: { Circle().stroke(Palette.text, lineWidth: 1.2).frame(width: 8, height: 8) }.labelStyle(DotLabel())
                case .connect: Text("Conectar  ↗").font(.system(size: 12, weight: .medium))
                case .none: footer
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(20).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(state == .selected ? Palette.stroke : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
extension SelectCard where Footer == EmptyView {
    init(title: String, subtitle: String = "", state: CardState, selectedLabel: String = "Selecionada", action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, state: state, selectedLabel: selectedLabel, action: action) { EmptyView() }
    }
}

struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 6) { configuration.icon; configuration.title } }
}

/// "● Ativado" / "○ Desativado"
struct DotStatus: View {
    let on: Bool
    var onLabel = "Ativado"
    var offLabel = "Desativado"
    var body: some View {
        HStack(spacing: 8) {
            if on { Circle().fill(Palette.text).frame(width: 8, height: 8) } else { Circle().stroke(Palette.text, lineWidth: 1.2).frame(width: 8, height: 8) }
            Text(on ? onLabel : offLabel)
        }
    }
}

/// Label above a filled box (Ajustes, Revisão): 13 pt muted label, panel box 58 pt tall.
struct ValueBox<Content: View>: View {
    let label: String
    var width: CGFloat? = 640
    var height: CGFloat = 58
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !label.isEmpty { Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted) }
            Group {
                if let action { Button(action: action) { box }.buttonStyle(.plain) } else { box }
            }
        }
    }
    private var box: some View {
        HStack(spacing: 8) { content }.font(.system(size: 14)).foregroundStyle(Palette.text)
            .padding(.horizontal, 16).frame(maxWidth: width ?? .infinity, minHeight: height, alignment: .leading)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
    }
}

/// Row of a list separated by rules (Publicações, Conexões, Revise seus destinos).
struct RuleRow<Content: View>: View {
    var height: CGFloat = 64
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) { content }.frame(minHeight: height)
            Separator()
        }
    }
}

/// Small text link such as "Ver métricas ↗" or "Personalizar ›".
struct TextLink: View {
    let title: String
    var muted = true
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(muted ? Palette.muted : Palette.text).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

/// Uppercase column header (10 pt semibold muted).
struct ColumnHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(verbatim: L(text).uppercased(with: AppLanguage.locale)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted) }
}

/// Centered result card (Tudo pronto, Publicar agora?, Precisa de atenção).
struct ResultCard<Content: View>: View {
    var width: CGFloat = 600
    @ViewBuilder var content: Content
    var body: some View {
        HStack { Spacer(); VStack(alignment: .leading, spacing: 0) { content }.padding(.horizontal, 32).padding(.vertical, 30).frame(width: width, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 14)); Spacer() }
            .padding(.top, 34)
    }
}

/// Placeholder glyph for media without a preview (◇ / ▶).
struct MediaPlaceholder: View {
    var video = false
    var height: CGFloat = 112
    var body: some View {
        ZStack {
            Palette.raised
            Image(systemName: video ? "play.fill" : "diamond").font(.system(size: video ? 20 : 18, weight: .light)).foregroundStyle(Palette.muted)
        }.frame(height: height).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
