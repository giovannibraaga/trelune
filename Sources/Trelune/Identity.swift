import Foundation

/// Names that identify this copy of the app. Nothing here is tied to a person or an account:
/// the bundle identifier comes from the build (script/build_and_run.sh, `BUNDLE_ID`), and every
/// Keychain item is namespaced by it, so forks and personal builds never share credentials.
enum AppIdentity {
    static let name = "Trelune"
    static let defaultBundleID = "app.trelune.mac"
    static var bundleID: String { Bundle.main.bundleIdentifier ?? defaultBundleID }
    /// Keychain service for one connection, e.g. `app.trelune.mac.youtube`.
    static func keychainService(_ name: String) -> String { "\(bundleID).\(name)" }
    /// Project home; setup guides live in docs/ there.
    static let repository = "https://github.com/giovannibraaga/trelune"
    /// Step-by-step guide to create the developer app for one network (docs/CONNECTIONS.md).
    static func setupGuide(_ network: String) -> URL {
        let anchor = ["YouTube": "youtube", "Instagram": "instagram-e-facebook-meta", "Facebook": "instagram-e-facebook-meta", "Threads": "threads", "TikTok": "tiktok", "X": "x"][network] ?? ""
        return URL(string: "\(repository)/blob/main/docs/CONNECTIONS.md\(anchor.isEmpty ? "" : "#" + anchor)")!
    }
}

/// AWS resource names used by cloud publishing (see cloud/deploy.sh). The prefix defaults to "trelune"
/// and can be changed in Ajustes → Agendamento when the stack was deployed with another `NAME`.
enum CloudNames {
    static let prefixKey = "cloudResourcePrefix"
    static let accountKey = "cloudAccountID"
    static var prefix: String {
        let value = UserDefaults.standard.string(forKey: prefixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "trelune" : value
    }
    static var functionName: String { "\(prefix)-publisher" }
    static var schedulerRole: String { "\(prefix)-scheduler" }
    static var uploaderUser: String { "\(prefix)-uploader" }
    static var vaultPath: String { "/\(prefix)/vault/" }
    static var mediaPrefix: String { "\(prefix)/" }
}
