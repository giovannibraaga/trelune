import Foundation
import Security

/// Brings preferences and connections from builds made before the rename (Post Orchestrator) or with
/// another bundle identifier into this build. Nothing identifies a person here: the old copies are found
/// by name pattern in ~/Library/Preferences and in the login Keychain.
enum LegacyImport {
    static let doneKey = "legacyImportDone"
    static let connections = ["youtube", "meta", "tiktok", "threads", "x", "mediahost"]

    struct Report { var preferences = 0; var connections: [String] = []; var source = "" }

    /// Runs once per build identifier, before the connections read the Keychain.
    @discardableResult static func runIfNeeded() -> Report? {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return nil }
        let report = run()
        UserDefaults.standard.set(true, forKey: doneKey)
        return report
    }

    /// Copies everything that is missing here. Existing values are never overwritten.
    static func run() -> Report {
        var report = Report()
        let own = AppIdentity.bundleID
        // Preferences: the newest legacy domain wins.
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent
                return url.pathExtension == "plist" && name != own && (name.lowercased().hasSuffix("postorchestrator") || name == "Trelune" || name.lowercased().hasSuffix(".trelune.mac"))
            }
            .sorted { modified($0) > modified($1) }
        if let source = candidates.first, let domain = UserDefaults(suiteName: source.deletingPathExtension().lastPathComponent) {
            report.source = source.deletingPathExtension().lastPathComponent
            for (key, value) in domain.dictionaryRepresentation() where !ignored(key) && UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key); report.preferences += 1
            }
        }
        // Keychain: same item names under the old service prefix.
        for name in connections {
            let target = KeychainSlot(service: AppIdentity.keychainService(name))
            guard (try? target.read()) == nil else { continue }
            for service in legacyServices(for: name) where service != target.service {
                if let data = try? KeychainSlot(service: service).read() {
                    if (try? target.write(data)) != nil { report.connections.append(name) }
                    break
                }
            }
        }
        return report
    }

    private static func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    private static func ignored(_ key: String) -> Bool {
        key == doneKey || key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple") || key.hasPrefix("AK") || key.hasPrefix("PK")
    }
    /// Services named `<some id>.<name>` whose id looks like an earlier build of this app.
    private static func legacyServices(for name: String) -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrService as String] as? String }.filter { service in
            let lower = service.lowercased()
            return lower.hasSuffix(".\(name)") && (lower.contains("postorchestrator") || lower.contains("trelune"))
        }
    }
}
