import AppKit
import Foundation

/// Optional, anonymous first-open measurement. No identifier or workspace data is sent.
@MainActor enum InstallMetrics {
    static let choiceKey = "installMetricsChoice"
    private static let sentKey = "installMetricsSent"
    private static var inFlight = false

    static func start() {
        #if DEBUG
        return
        #else
        let defaults = UserDefaults.standard
        if defaults.object(forKey: choiceKey) == nil {
            let alert = NSAlert()
            alert.messageText = L("Ajudar a melhorar o Trelune?")
            alert.informativeText = L("Com sua permissão, enviaremos à Cloudflare um evento de primeira abertura e a versão do app. Nenhuma publicação, credencial, nome ou identificador do dispositivo é enviado. Você pode mudar sua escolha em Ajustes → Privacidade.")
            alert.addButton(withTitle: L("Permitir"))
            alert.addButton(withTitle: L("Agora não"))
            defaults.set(alert.runModal() == .alertFirstButtonReturn, forKey: choiceKey)
        }
        sendIfNeeded()
        #endif
    }

    static func sendIfNeeded() {
        #if DEBUG
        return
        #else
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: choiceKey), !defaults.bool(forKey: sentKey), !inFlight else { return }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        guard let body = try? JSONSerialization.data(withJSONObject: ["event": "first_open", "version": version]),
              let url = URL(string: "https://trelune.app/api/metrics") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        inFlight = true
        Task {
            defer { inFlight = false }
            do {
                let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 204 { defaults.set(true, forKey: sentKey) }
            } catch { /* Retry on a future launch while permission remains enabled. */ }
        }
        #endif
    }
}
