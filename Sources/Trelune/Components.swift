import SwiftUI
import AppKit
import AVFoundation
import Charts

/// Design tokens from the Figma file (Trelune · Minimalista), in dark and light variants.
/// Every color resolves against the current appearance, so the whole UI follows Ajustes → Aparência.
enum Palette {
    static let bg = dynamic(0x101010, 0xFAFAFA)
    static let sidebar = dynamic(0x141414, 0xF2F2F0)
    static let panel = dynamic(0x1A1A1A, 0xF0F0EE)
    static let raised = dynamic(0x262626, 0xE6E6E4)
    static let field = dynamic(0x1A1A1A, 0xF0F0EE)
    static let stroke = dynamic(0x303030, 0xD9D9D6)
    static let grid = dynamic(0x282828, 0xE5E5E3)
    static let text = dynamic(0xEEEEEB, 0x181818)
    static let secondary = dynamic(0xBCBCB8, 0x3F3F3D)
    static let muted = dynamic(0x92928F, 0x686866)
    /// Primary actions and selection: the design is monochrome, so the accent is the text color.
    static let accent = dynamic(0xEEEEEB, 0x181818)
    static let warning = dynamic(0xE3B341, 0x9A6700)
    static let danger = dynamic(0xF07B7B, 0xC2362F)

    private static func dynamic(_ dark: UInt, _ light: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(Color(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light))
        })
    }
}

/// Ajustes → Aparência. Applied to NSApp so windows, sheets, popovers and menus all follow it.
enum Appearance: String, CaseIterable {
    case dark = "Escuro", light = "Claro", system = "Sistema"
    static let key = "appearance"
    static var current: Appearance {
        // TRELUNE_APPEARANCE (Escuro/Claro) lets snapshot runs pick a theme without touching the saved one.
        Appearance(rawValue: ProcessInfo.processInfo.environment["TRELUNE_APPEARANCE"] ?? UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }
    @MainActor static func apply(_ value: Appearance = current) {
        switch value {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }
}
extension Color { init(hex: UInt) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) } }

func statusColor(_ status: String) -> Color {
    switch status {
    case PostStatus.published: Palette.accent
    case PostStatus.scheduled, PostStatus.publishing: Palette.secondary
    case PostStatus.partial: Palette.warning
    case PostStatus.failed: Palette.danger
    default: Palette.muted
    }
}

/// Figma page frame: title, subtitle, header button on the right, a rule, then the content.
struct PageScroll<Content: View>: View {
    let title: String
    let subtitle: String
    let action: String
    var primary = true
    var actionHandler: () -> Void
    @ViewBuilder let content: Content
    init(title: String, subtitle: String, action: String, primary: Bool = true, actionHandler: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.action = action; self.primary = primary; self.actionHandler = actionHandler; self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Heading(title: title, subtitle: subtitle)
                    Spacer()
                    if !action.isEmpty { HeaderButton(action, primary: primary, action: actionHandler) }
                }.padding(.bottom, 36)
                Separator()
                VStack(alignment: .leading, spacing: 24) { content }.padding(.top, 30)
            }.padding(.horizontal, 50).padding(.top, 54).padding(.bottom, 40).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Palette.bg)
    }
}

/// Button used in page headers and footers (Figma: 42 pt tall, inverted when primary).
struct HeaderButton: View {
    let title: String
    var primary = true
    var width: CGFloat? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, primary: Bool = true, width: CGFloat? = nil, action: @escaping () -> Void) { self.title = title; self.primary = primary; self.width = width; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(primary ? Palette.bg : Palette.text)
                .padding(.horizontal, 28).frame(minWidth: width ?? 168).frame(height: 42)
                .background(primary ? (enabled ? Palette.accent : Palette.muted.opacity(0.45)) : Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct Heading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.3)
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 14)).foregroundStyle(Palette.muted) }
        }
    }
}

/// 1 px rule used between sections (Figma "Separador").
struct Separator: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Palette.stroke).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1).frame(maxWidth: vertical ? nil : .infinity)
    }
}

/// Primary action: inverted fill (light on dark, dark on light).
struct ActionButton: View {
    let title: String
    var large = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ title: String, large: Bool = false, _ action: @escaping () -> Void = {}) { self.title = title; self.large = large; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.bg)
                .padding(.horizontal, large ? 26 : 16).frame(height: large ? 42 : 34)
                .background(enabled ? Palette.accent : Palette.muted.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var role: ButtonRole?
    var action: () -> Void
    init(_ title: String, role: ButtonRole? = nil, _ action: @escaping () -> Void) { self.title = title; self.role = role; self.action = action }
    var body: some View {
        Button(role: role, action: action) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(role == .destructive ? Palette.danger : Palette.text)
                .padding(.horizontal, 16).frame(height: 34).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct Pill: View {
    let title: String
    var selected: Bool
    init(_ title: String, selected: Bool = false) { self.title = title; self.selected = selected }
    var body: some View {
        Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).foregroundStyle(selected ? Palette.text : Palette.muted)
            .padding(.horizontal, 12).frame(height: 32).background(selected ? Palette.raised : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }
}

struct StatusBadge: View {
    let status: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor(status)).frame(width: 6, height: 6)
            Text(status).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
        }.frame(height: 24)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let delta: String
    let icon: String
    init(_ title: String, _ value: String, _ delta: String, _ icon: String) { self.title = title; self.value = value; self.delta = delta; self.icon = icon }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 25, weight: .semibold))
            Text(delta).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
        }.font(.system(size: 12)).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PostRow: View {
    let post: Publication
    var body: some View {
        HStack(spacing: 13) {
            Thumbnail(path: post.mediaPath, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(post.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(post.platforms, id: \.self) { network in
                        let result = post.results[network]
                        HStack(spacing: 4) {
                            if let result { Image(systemName: result.pending ? "tray.and.arrow.down.fill" : result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") } else { BrandLogo(network: network, size: 10) }
                            Text(result?.pending == true ? "\(network) · concluir no app" : network)
                        }
                            .font(.system(size: 10)).foregroundStyle(result == nil ? Palette.muted : result!.pending ? Palette.warning : result!.succeeded ? Palette.accent : Palette.danger)
                            .help(result?.detail ?? "")
                    }
                }
            }
            Spacer()
            Text(Workspace.format(post.date)).font(.system(size: 12)).foregroundStyle(Palette.muted)
            StatusBadge(status: post.status)
        }.padding(10)
    }
}

func panel(title: String, body: String, foot: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: 15, weight: .semibold))
        Text(body).font(.system(size: 13)).foregroundStyle(Palette.muted)
        if !foot.isEmpty { Text(foot).font(.system(size: 11)).foregroundStyle(Palette.muted) }
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Image or first video frame of a local file, cached in memory.
struct Thumbnail: View {
    let path: String?
    var size: CGFloat = 44
    var height: CGFloat?
    /// Shows the whole image (letterboxed over a blurred copy) instead of cropping it.
    var fit = false
    @State private var image: NSImage?
    var body: some View {
        // The frame comes from the color; images live in an overlay so they never change the tile's size.
        Palette.raised
            .frame(width: height == nil ? size : nil, height: height ?? size).frame(maxWidth: height == nil ? nil : .infinity)
            .overlay { if let image, fit { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).opacity(0.45) } }
            .overlay {
                if let image, fit { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                else if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: icon).font(.system(size: (height ?? size) * 0.35)).foregroundStyle(Palette.accent) }
            }
            .overlay { if let path, MediaKind.isVideo(path), image != nil { Image(systemName: "play.circle.fill").font(.system(size: min(size, height ?? size) * 0.3)).foregroundStyle(.white.opacity(0.85)) } }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        .task(id: path) { image = await ThumbnailCache.image(for: path) }
    }
    private var icon: String {
        guard let path, !path.isEmpty else { return "text.alignleft" }
        if !FileManager.default.fileExists(atPath: path) { return "exclamationmark.triangle" }
        return MediaKind.isVideo(path) ? "play.rectangle" : "photo"
    }
}

@MainActor enum ThumbnailCache {
    private static var images: [String: NSImage] = [:]
    static func image(for path: String?) async -> NSImage? {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        if let cached = images[path] { return cached }
        let url = URL(fileURLWithPath: path)
        var result: NSImage?
        if MediaKind.isVideo(path) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                result = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        } else {
            // Decode off the main thread so long libraries scroll without stalls.
            let thumb = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            if let thumb { result = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height)) }
        }
        if let result { images[path] = result }
        return result
    }
}

private let decimalFormatter: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = AppLanguage.locale; return f }()
func formatted(_ number: Int) -> String { decimalFormatter.string(from: NSNumber(value: number)) ?? "\(number)" }
func formatted(_ number: Int64) -> String { decimalFormatter.string(from: NSNumber(value: number)) ?? "\(number)" }

func copyToPasteboard(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }


// MARK: - Form controls (Figma style)

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted) }
}

extension View {
    /// Dark rounded field look used by inputs and selects.
    func fieldBox(height: CGFloat? = 40, focused: Bool = false) -> some View {
        padding(.horizontal, 12).frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Palette.accent.opacity(0.7) : Palette.stroke, lineWidth: 1))
    }
}

struct InputField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; _text = text }
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.muted.opacity(0.7)))
            .textFieldStyle(.plain).font(.system(size: 13)).focused($focused).fieldBox(focused: focused)
    }
}

struct TextArea: View {
    @Binding var text: String
    var placeholder = ""
    var height: CGFloat = 130
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text).scrollContentBackground(.hidden).font(.system(size: 13)).padding(.horizontal, 6).padding(.vertical, 8)
            if text.isEmpty && !placeholder.isEmpty { Text(placeholder).font(.system(size: 13)).foregroundStyle(Palette.muted.opacity(0.7)).padding(.horizontal, 11).padding(.vertical, 8).allowsHitTesting(false) }
        }
        .frame(height: height).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke, lineWidth: 1))
    }
}

/// Dropdown rendered as a dark field with a popover list of options.
struct SelectField<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var width: CGFloat?
    var compact = false
    @State private var open = false
    init(_ options: [(Value, String)], selection: Binding<Value>, width: CGFloat? = nil, compact: Bool = false) {
        self.options = options; _selection = selection; self.width = width; self.compact = compact
    }
    private var label: String { options.first { $0.0 == selection }?.1 ?? "Selecione" }
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: compact ? 12 : 13, weight: compact ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12).frame(height: compact ? 32 : 40).frame(maxWidth: width ?? .infinity)
            .background(compact ? Palette.raised : Palette.field).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(open ? Palette.accent.opacity(0.7) : compact ? .clear : Palette.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        OptionRow(title: option.1, selected: option.0 == selection) { selection = option.0; open = false }
                    }
                }.padding(6)
            }
            .frame(width: max(width ?? 220, 200)).frame(maxHeight: 320)
            .background(Palette.panel)
            
        }
    }
}

private struct OptionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.text)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(hover ? Palette.raised : selected ? Palette.raised.opacity(0.5) : .clear).clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// Segmented control made of pills.
struct PillPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.0 } label: { Pill(option.1, selected: option.0 == selection).frame(minWidth: 100) }.buttonStyle(.plain)
            }
        }
    }
}

struct NetworkChip: View {
    let network: String
    var selected = false
    var dimmed = false
    var body: some View {
        HStack(spacing: 6) {
            BrandLogo(network: network, size: 12)
            Text(network).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(selected ? Palette.bg : dimmed ? Palette.muted.opacity(0.55) : Palette.text)
        .padding(.horizontal, 12).frame(height: 32)
        .background(selected ? Palette.accent : Palette.raised).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Month grid + time selection, in the workspace time zone.
struct DateTimeSelector: View {
    @Binding var date: Date
    var minimum = Date()
    @State private var month = Date()
    @State private var timeOpen = false
    private var calendar: Calendar { var c = Workspace.calendar; c.firstWeekday = 2; return c }
    private let weekdays = ["S", "T", "Q", "Q", "S", "S", "D"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(monthTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(canGoBack ? Palette.text : Palette.muted.opacity(0.4)).disabled(!canGoBack)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).padding(.leading, 12)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in Text(day).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let selected = calendar.isDate(day, inSameDayAs: date)
                        let past = calendar.startOfDay(for: day) < calendar.startOfDay(for: minimum)
                        Button { pick(day) } label: {
                            Text("\(calendar.component(.day, from: day))").font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Palette.bg : past ? Palette.muted.opacity(0.35) : Palette.text)
                                .frame(maxWidth: .infinity).frame(height: 32)
                                .background(selected ? Palette.accent : past ? Color.clear : Palette.raised).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(calendar.isDateInToday(day) && !selected ? Palette.accent.opacity(0.6) : .clear))
                        }.buttonStyle(.plain).disabled(past)
                    } else { Color.clear.frame(height: 32) }
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Data"); Text(Workspace.format(date, date: .numeric, time: .omitted)).font(.system(size: 13)).fieldBox() }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Horário")
                    Button { timeOpen.toggle() } label: {
                        HStack { Text(timeText).font(.system(size: 13)); Spacer(); Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Palette.muted) }.fieldBox(focused: timeOpen).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .popover(isPresented: $timeOpen, arrowEdge: .bottom) { timePopover }
                }
            }
            HStack(spacing: 6) {
                ForEach(["09:00", "12:00", "18:00", "20:00"], id: \.self) { preset in
                    let parts = preset.split(separator: ":").compactMap { Int($0) }
                    Button { setTime(parts[0], parts[1]) } label: { Pill(preset, selected: timeText == preset) }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { month = date }
    }

    private var timePopover: some View {
        let hour = calendar.component(.hour, from: date), minute = calendar.component(.minute, from: date)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Hora")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 4), count: 6), spacing: 4) {
                    ForEach(0..<24, id: \.self) { h in timeCell(String(format: "%02d", h), selected: h == hour) { setTime(h, minute) } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Minuto")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 4), count: 3), spacing: 4) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in timeCell(String(format: "%02d", m), selected: m == minute) { setTime(hour, m) } }
                }
            }
        }.padding(14).background(Palette.panel)
    }
    private func timeCell(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit()).foregroundStyle(selected ? Palette.bg : Palette.text)
                .frame(width: 38, height: 28).background(selected ? Palette.accent : Palette.raised).clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private var monthTitle: String {
        var style = Date.FormatStyle().month(.wide).year(); style.timeZone = Workspace.timeZone; style.locale = AppLanguage.locale
        return month.formatted(style).uppercased()
    }
    private var timeText: String { String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date)) }
    private var canGoBack: Bool { calendar.compare(month, to: minimum, toGranularity: .month) == .orderedDescending }
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month), let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }
    private func shiftMonth(_ delta: Int) { month = calendar.date(byAdding: .month, value: delta, to: month) ?? month }
    private func pick(_ day: Date) {
        let h = calendar.component(.hour, from: date), m = calendar.component(.minute, from: date)
        date = calendar.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
    }
    private func setTime(_ hour: Int, _ minute: Int) {
        date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }
}

/// Centered confirmation card over a dimmed page (Figma "Tudo agendado").
struct ModalCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(32).frame(width: 620, alignment: .leading)
                .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.stroke))
        }
    }
}

struct WideButton: View {
    let title: String
    var primary = true
    let action: () -> Void
    init(_ title: String, primary: Bool = true, action: @escaping () -> Void) { self.title = title; self.primary = primary; self.action = action }
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(primary ? Palette.bg : Palette.text)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(primary ? (enabled ? Palette.accent : Palette.muted.opacity(0.4)) : Palette.raised).clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

/// Remote image (API thumbnails) with a neutral placeholder.
struct RemoteThumb: View {
    let url: String?
    var width: CGFloat = 82
    var height: CGFloat = 50
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
            else { ZStack { Palette.raised; Image(systemName: "photo").foregroundStyle(Palette.muted) } }
        }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}


/// Code snippet with a header (file or shell), monospaced body, copy button and an optional extra action.
struct CodeBlock: View {
    let title: String
    var language = ""
    let code: String
    var extra: (String, () -> Void)? = nil
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: language == "bash" ? "terminal" : "doc.text").font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
                if !language.isEmpty { Text(language).font(.system(size: 10, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2).background(Palette.panel).clipShape(Capsule()) }
                Spacer()
                if let extra { Button(extra.0, action: extra.1).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent) }
                Button { copyToPasteboard(code); copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false } } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(copied ? Palette.accent : Palette.text)
            }
            .foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.vertical, 8).background(Palette.raised)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize().padding(12)
            }
        }
        .background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke.opacity(0.7)))
    }
}


/// One line of a TrendChart.
struct TrendSeries: Identifiable {
    let name: String
    let color: Color
    let points: [(Date, Int)]
    var dashed = false
    var id: String { name }
}

/// The app's single chart style: monotone line with a soft area for the main series, dashed comparison
/// series, pt-BR axes and a hover guide that shows every series' value for that day.
struct TrendChart: View {
    let series: [TrendSeries]
    var height: CGFloat = 220
    /// Figma style: no legend row (the page shows it) and no area under the line.
    var minimal = false
    @State private var selected: Date?
    private var calendar: Calendar { Workspace.calendar }
    private var domain: ClosedRange<Date> {
        let dates = series.flatMap { $0.points.map(\.0) }
        let first = dates.min() ?? Date(), last = dates.max() ?? Date()
        return first...max(last, first.addingTimeInterval(86400))
    }
    private func value(_ item: TrendSeries, at day: Date) -> Int? { item.points.first { calendar.isDate($0.0, inSameDayAs: day) }?.1 }
    private var empty: Bool { series.allSatisfy { $0.points.allSatisfy { $0.1 == 0 } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !minimal { HStack(spacing: 14) {
                ForEach(series) { item in
                    HStack(spacing: 6) {
                        if item.dashed { Capsule().stroke(item.color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 14, height: 3) }
                        else { Capsule().fill(item.color).frame(width: 14, height: 3) }
                        Text(item.name).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(compact(item.points.map(\.1).reduce(0, +))).font(.system(size: 11, weight: .semibold)).foregroundStyle(item.dashed ? Palette.muted : Palette.text)
                    }
                }
                Spacer()
                Text("Passe o mouse para ver cada dia").font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.7))
            } }
            if empty {
                ContentUnavailableView(L("Sem dados no período"), systemImage: "chart.xyaxis.line", description: Text("Nada registrado pelas redes conectadas nestes dias.")).frame(height: height)
            } else {
                chart.frame(height: height)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                ForEach(item.points, id: \.0) { point in
                    if index == 0 && !item.dashed && !minimal {
                        AreaMark(x: .value("Dia", point.0, unit: .day), y: .value("Valor", point.1))
                            .foregroundStyle(LinearGradient(colors: [item.color.opacity(0.10), item.color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Dia", point.0, unit: .day), y: .value("Valor", point.1), series: .value("Série", item.name))
                        .foregroundStyle(item.color)
                        .lineStyle(item.dashed ? StrokeStyle(lineWidth: 1.4, dash: [4, 4]) : StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .interpolationMethod(minimal ? .linear : .monotone)
                }
            }
            if let selected {
                RuleMark(x: .value("Dia", selected, unit: .day))
                    .foregroundStyle(Palette.muted.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(for: selected) }
                ForEach(series) { item in
                    if let value = value(item, at: selected) {
                        PointMark(x: .value("Dia", selected, unit: .day), y: .value("Valor", value)).foregroundStyle(item.color).symbolSize(item.dashed ? 25 : 55)
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel { if let date = value.as(Date.self) { Text(Workspace.format(date, date: .abbreviated, time: .omitted).components(separatedBy: " de 20").first ?? "").foregroundStyle(Palette.muted) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel { if let number = value.as(Int.self) { Text(compact(number)).foregroundStyle(Palette.muted) } }
            }
        }
        .environment(\.locale, AppLanguage.locale)
        .environment(\.timeZone, Workspace.timeZone)
    }

    private func tooltip(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Workspace.format(day, date: .complete, time: .omitted)).font(.system(size: 11, weight: .semibold))
            ForEach(series) { item in
                HStack(spacing: 6) {
                    Circle().fill(item.color.opacity(item.dashed ? 0.6 : 1)).frame(width: 7, height: 7)
                    Text(item.name).foregroundStyle(Palette.muted)
                    Spacer(minLength: 12)
                    Text(value(item, at: day).map(formatted) ?? "—").fontWeight(.semibold)
                }.font(.system(size: 11))
            }
        }
        .padding(10).frame(minWidth: 190).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}


/// Metric switcher shared by the charts (Visualizações / Interações / Publicações).
struct TrendMetricPicker: View {
    @Binding var metric: String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(["Visualizações", "Interações", "Publicações"], id: \.self) { item in
                Button { metric = item } label: {
                    Text(item).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(metric == item ? Palette.text : Palette.muted)
                        .overlay(alignment: .bottom) { if metric == item { Rectangle().fill(Palette.accent).frame(height: 2).offset(y: 6) } }
                }.buttonStyle(.plain)
            }
        }
    }
}
func trendSeries(_ trend: (current: [(Date, Int)], previous: [(Date, Int)]), days: Int) -> [TrendSeries] {
    [TrendSeries(name: "Atual", color: Palette.accent, points: trend.current),
     TrendSeries(name: "Período anterior", color: Palette.muted, points: trend.previous, dashed: true)]
}

/// Text tabs with an underline on the selected one (Figma network and status filters).
struct TabBar<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 26) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(.system(size: size, weight: selected ? .semibold : .medium)).foregroundStyle(selected ? Palette.text : Palette.muted)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(selected ? Palette.accent : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}
