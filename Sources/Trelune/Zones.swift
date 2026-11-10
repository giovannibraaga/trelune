import SwiftUI

/// Every time zone in use, one entry per distinct zone of each country (Brazil has four, for example),
/// ordered by UTC offset from the highest to the lowest. Built from the system tz database (zone.tab).
enum ZoneCatalog {
    struct Entry: Identifiable, Hashable {
        let id: String          // representative identifier, e.g. America/Sao_Paulo
        let offset: Int         // seconds from GMT right now
        let country: String     // localized country name
        let name: String        // localized zone name, e.g. "Horário de Brasília"
        var label: String { "(\(ZoneCatalog.offsetText(offset))) \(country) · \(name)" }
    }

    /// Zones people usually mean when a country has several identifiers with the same rules.
    private static let preferred: Set<String> = [
        "America/Sao_Paulo", "America/Manaus", "America/Rio_Branco", "America/Noronha", "America/New_York", "America/Chicago", "America/Denver",
        "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu", "America/Toronto", "America/Vancouver", "America/Edmonton",
        "America/Winnipeg", "America/Halifax", "America/St_Johns", "America/Mexico_City", "America/Cancun", "America/Tijuana", "America/Argentina/Buenos_Aires",
        "America/Santiago", "America/Bogota", "America/Lima", "America/Caracas", "Europe/Lisbon", "Atlantic/Azores", "Europe/Madrid", "Atlantic/Canary",
        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Rome", "Europe/Moscow", "Asia/Kolkata", "Asia/Shanghai", "Asia/Tokyo", "Australia/Sydney",
        "Australia/Brisbane", "Australia/Adelaide", "Australia/Darwin", "Australia/Perth", "Pacific/Auckland", "Asia/Jakarta", "Asia/Makassar", "Asia/Jayapura",
        "Africa/Johannesburg", "Africa/Lagos", "Africa/Cairo", "Asia/Dubai", "Asia/Singapore", "Asia/Seoul", "Asia/Hong_Kong",
    ]

    static var entries: [Entry] { cache ?? build() }
    nonisolated(unsafe) private static var cache: [Entry]?

    private static func build() -> [Entry] {
        let locale = AppLanguage.locale
        let rows = ((try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "\t")
                return parts.count >= 3 ? (String(parts[0]), String(parts[2])) : nil
            }
        let now = Date(), later = now.addingTimeInterval(182 * 86400)
        var groups: [String: [String]] = [:], order: [String] = []
        for (country, id) in rows {
            guard let zone = TimeZone(identifier: id) else { continue }
            // Same country and same rules (offset now and in six months) means the same zone for the user.
            let key = "\(country)|\(zone.secondsFromGMT(for: now))|\(zone.secondsFromGMT(for: later))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(id)
        }
        let current = TimeZone.current.identifier
        var list: [Entry] = order.compactMap { key in
            guard let ids = groups[key], let country = key.split(separator: "|").first.map(String.init) else { return nil }
            let id = ids.first { $0 == current } ?? ids.first { preferred.contains($0) } ?? ids[0]
            guard let zone = TimeZone(identifier: id) else { return nil }
            return Entry(id: id, offset: zone.secondsFromGMT(for: now), country: locale.localizedString(forRegionCode: country) ?? country, name: zoneName(zone, locale: locale))
        }
        list.append(Entry(id: "UTC", offset: 0, country: "UTC", name: locale.language.languageCode?.identifier == "pt" ? "Tempo Universal Coordenado" : "Coordinated Universal Time"))
        list.sort { $0.offset != $1.offset ? $0.offset > $1.offset : $0.country.localizedCompare($1.country) == .orderedAscending }
        cache = list
        return list
    }

    static func zoneName(_ zone: TimeZone, locale: Locale) -> String {
        if let name = zone.localizedName(for: .generic, locale: locale), !name.hasPrefix("GMT") { return name }
        return zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
    }
    static func offsetText(_ seconds: Int) -> String {
        String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
    }
    /// Label for any identifier, including ones that are not the representative of their group.
    static func label(_ identifier: String) -> String {
        if let entry = entries.first(where: { $0.id == identifier }) { return entry.label }
        let zone = TimeZone(identifier: identifier) ?? .current
        let country = countryOf(identifier)
        if let match = entries.first(where: { entry in entry.country == country && TimeZone(identifier: entry.id)?.secondsFromGMT() == zone.secondsFromGMT() }) { return match.label }
        return "(\(offsetText(zone.secondsFromGMT()))) \(zoneName(zone, locale: AppLanguage.locale))"
    }
    private static func countryOf(_ identifier: String) -> String? {
        let rows = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
        guard let line = rows.split(separator: "\n").first(where: { $0.split(separator: "\t").count >= 3 && $0.split(separator: "\t")[2] == identifier }) else { return nil }
        let code = String(line.split(separator: "\t")[0])
        return AppLanguage.locale.localizedString(forRegionCode: code) ?? code
    }
}

/// "(UTC−03:00) Brasil · Horário de Brasília ▾" opening a searchable list of every zone.
struct ZoneMenu: View {
    @Binding var identifier: String
    @State private var open = false
    @State private var query = ""
    var body: some View {
        Button { open.toggle() } label: { Text("\(ZoneCatalog.label(identifier))  ▾").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1) }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("", text: $query, prompt: Text("Buscar país, cidade ou UTC").foregroundStyle(Palette.muted)).textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 34).background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 8))
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filtered) { entry in
                                    Button { identifier = entry.id; open = false } label: {
                                        HStack(spacing: 10) {
                                            Text(ZoneCatalog.offsetText(entry.offset)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted).frame(width: 82, alignment: .leading)
                                            Text("\(entry.country) · \(entry.name)").font(.system(size: 13)).lineLimit(1)
                                            Spacer()
                                            if entry.id == identifier { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                                        }.padding(.horizontal, 10).frame(height: 30).background(entry.id == identifier ? Palette.raised : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                                    }.buttonStyle(.plain).id(entry.id)
                                }
                            }
                        }.onAppear { proxy.scrollTo(identifier, anchor: .center) }
                    }
                }.padding(10).frame(width: 440, height: 420).background(Palette.panel)
            }
    }
    private var filtered: [ZoneCatalog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !q.isEmpty else { return ZoneCatalog.entries }
        return ZoneCatalog.entries.filter { "\($0.label) \($0.id)".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(q) }
    }
}
