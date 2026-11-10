import SwiftUI
import Foundation

/// The app speaks Brazilian Portuguese when the Mac's preferred language is Portuguese, English otherwise.
/// Strings are written in Portuguese in the code; `L` looks them up in `Translations.english`, including
/// interpolated ones ("Criar para YouTube" matches the key "Criar para %@").
enum AppLanguage {
    static let isPortuguese: Bool = {
        if let forced = ProcessInfo.processInfo.environment["TRELUNE_LANGUAGE"] { return forced.hasPrefix("pt") }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("pt")
    }()
    static var locale: Locale { Locale(identifier: isPortuguese ? "pt_BR" : "en_US") }
}

private final class Localizer: @unchecked Sendable {
    static let shared = Localizer()
    private let exact: [String: String]
    private let patterns: [(NSRegularExpression, String)]
    private var cache: [String: String] = [:]
    private let lock = NSRecursiveLock()
    init() {
        exact = Translations.english
        patterns = Translations.english.compactMap { key, value in
            guard key.contains("%@") else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: key).replacingOccurrences(of: "%@", with: "(.*?)")
            return (try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.dotMatchesLineSeparators])).map { ($0, value) }
        }.sorted { $0.0.pattern.count > $1.0.pattern.count }
    }
    fileprivate func exactEntry(_ text: String) -> String? { exact[text] }
    func translate(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[text] { return hit }
        var result = exact[text]
        if result == nil, text.count < 600 {
            let range = NSRange(text.startIndex..., in: text)
            for (regex, template) in patterns {
                guard let match = regex.firstMatch(in: text, range: range) else { continue }
                var output = template
                for index in 1..<match.numberOfRanges {
                    guard let r = Range(match.range(at: index), in: text), let slot = output.range(of: "%@") else { continue }
                    output.replaceSubrange(slot, with: translate(String(text[r])))
                }
                result = output; break
            }
        }
        // Composite text: "0 conectadas   ·   6 disponíveis", "3 plataformas selecionadas".
        if result == nil {
            for separator in ["   ·   ", "  ·  ", " · "] where text.contains(separator) {
                let parts = text.components(separatedBy: separator)
                let translated = parts.map { translate($0) }
                if translated != parts { result = translated.joined(separator: separator) }
                break
            }
        }
        if result == nil, let space = text.firstIndex(of: " "), Int(text[..<space]) != nil {
            let rest = String(text[text.index(after: space)...])
            let translated = translate(rest)
            if translated != rest { result = String(text[...space]) + translated }
        }
        // Phrases glued from known pieces ("destinos prontos" + "para publicação"): longest known prefix first.
        if result == nil, text.contains(" "), text.count < 200 { result = segmented(text) }
        let value = result ?? text
        cache[text] = value
        return value
    }
}

extension Localizer {
    fileprivate func segmented(_ text: String) -> String? {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 1 else { return nil }
        for cut in stride(from: words.count - 1, through: 1, by: -1) {
            let head = words[..<cut].joined(separator: " "), tail = words[cut...].joined(separator: " ")
            guard let first = known(head) else { continue }
            if let rest = known(tail) ?? segmented(tail) { return first + " " + rest }
        }
        return nil
    }
    /// Exact entry, or a number followed by an exact entry.
    fileprivate func known(_ text: String) -> String? {
        if let hit = exactEntry(text) { return hit }
        if let space = text.firstIndex(of: " "), Int(text[..<space]) != nil, let hit = exactEntry(String(text[text.index(after: space)...])) { return String(text[...space]) + hit }
        if Int(text) != nil { return text }
        return nil
    }
}

/// Localized version of a Portuguese UI string.
func L(_ text: String) -> String {
    AppLanguage.isPortuguese || text.isEmpty ? text : Localizer.shared.translate(text)
}

// Every Text, Button, Toggle, Label and help tag built from a String goes through `L`.
extension Text {
    init(_ content: String) {
        let text = L(content)
        if text.contains("](") , let attributed = try? AttributedString(markdown: text) { self.init(attributed) } else { self.init(verbatim: text) }
    }
}
extension Button where Label == Text {
    init(_ title: String, action: @escaping () -> Void) { self.init(action: action) { Text(title) } }
    init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) { self.init(role: role, action: action) { Text(title) } }
}
extension Toggle where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) { self.init(isOn: isOn) { Text(title) } }
}
extension SwiftUI.Label where Title == Text, Icon == Image {
    init(_ title: String, systemImage: String) { self.init { Text(title) } icon: { Image(systemName: systemImage) } }
}
extension Link where Label == Text {
    init(_ title: String, destination: URL) { self.init(destination: destination) { Text(title) } }
}
extension ProgressView where Label == Text, CurrentValueLabel == EmptyView {
    init(_ title: String) { self.init { Text(title) } }
}
extension View {
    func help(_ text: String) -> some View { help(Text(text)) }
}
