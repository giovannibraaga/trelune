import Foundation
import CryptoKit
import AVFoundation
import AppKit

/// AWS Signature Version 4 for S3 requests.
enum SigV4 {
    static func encode(_ value: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }

    /// Returns the Authorization header value. `headers` must include host, x-amz-date and x-amz-content-sha256.
    static func authorization(method: String, path: String, query: String = "", headers: [String: String], payloadHash: String, region: String, service: String = "s3", accessKey: String, secretKey: String) -> String {
        let lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        let names = lower.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lower[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [method, encode(path, keepSlash: true), query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let amzDate = lower["x-amz-date"] ?? ""
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(Data(canonical.utf8))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(secretKey)".utf8), day)
        key = hmac(key, region); key = hmac(key, service); key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, stringToSign))
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
}

/// Uploads local media to an S3 bucket so APIs that only accept public URLs (Instagram, Threads, TikTok photos) can fetch it.
@MainActor final class MediaHost: ObservableObject {
    struct Config: Codable, Equatable {
        var bucket = ""
        var region = "us-east-1"
        var accessKey = ""
        var secretKey = ""
        var prefix = CloudNames.mediaPrefix
        /// Optional CloudFront or custom domain, e.g. https://media.example.com
        var publicBaseURL = ""
    }
    private let vault = KeychainSlot(service: AppIdentity.keychainService("mediahost"))
    @Published private(set) var config: Config?
    @Published private(set) var loading = true
    @Published var message = ""
    var configured: Bool { config.map { !$0.bucket.isEmpty && !$0.accessKey.isEmpty && !$0.secretKey.isEmpty } ?? false }
    private static let cacheKey = "mediaHostCache"

    init() {
        Task {
            defer { loading = false }
            let slot = vault
            if let data = try? await Task.detached(operation: { try slot.read() }).value, let saved = try? JSONDecoder().decode(Config.self, from: data) { config = saved }
        }
    }

    func save(_ value: Config) {
        var value = value
        value.bucket = value.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        value.region = value.region.trimmingCharacters(in: .whitespacesAndNewlines)
        value.accessKey = value.accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        value.secretKey = value.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        value.publicBaseURL = value.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !value.prefix.isEmpty && !value.prefix.hasSuffix("/") { value.prefix += "/" }
        do { try vault.write(JSONEncoder().encode(value)); config = value; UserDefaults.standard.removeObject(forKey: Self.cacheKey); message = "Hospedagem salva no Chaves do macOS." } catch { message = error.localizedDescription }
    }
    func remove() { try? vault.delete(); config = nil; message = "Hospedagem removida." }

    @Published private(set) var provisioning = false
    /// Creates an access key for the upload-only IAM user with the local AWS CLI session and stores it straight
    /// in the Keychain; the secret is never shown or logged.
    func provisionWithAWSCLI(bucket: String, region: String, prefix: String, user: String) async {
        guard !provisioning else { return }
        guard let aws = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            message = "AWS CLI não encontrada. Instale com: brew install awscli"; return
        }
        provisioning = true; defer { provisioning = false }
        message = "Gerando a chave com a AWS CLI…"
        let result: (status: Int32, output: Data, error: String) = await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: aws)
            process.arguments = ["iam", "create-access-key", "--user-name", user, "--output", "json"]
            var environment = ProcessInfo.processInfo.environment; environment["AWS_PAGER"] = ""
            process.environment = environment
            let out = Pipe(), err = Pipe(); process.standardOutput = out; process.standardError = err
            do { try process.run() } catch { return (-1, Data(), error.localizedDescription) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, data, errorText)
        }.value
        guard result.status == 0 else {
            if result.error.contains("expired") || result.error.contains("aws login") { message = "A sessão da AWS CLI expirou. Rode “aws login” no Terminal e tente de novo." }
            else if result.error.contains("LimitExceeded") { message = "O usuário \(user) já tem 2 chaves. Apague uma no console da AWS (IAM → Usuários) e tente de novo." }
            else { message = "A AWS CLI recusou: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))" }
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any], let key = json["AccessKey"] as? [String: Any],
              let id = key["AccessKeyId"] as? String, let secret = key["SecretAccessKey"] as? String else { message = "A AWS CLI não retornou uma chave válida."; return }
        save(Config(bucket: bucket, region: region, accessKey: id, secretKey: secret, prefix: prefix, publicBaseURL: config?.publicBaseURL ?? ""))
        // New IAM keys can take a few seconds to propagate.
        try? await Task.sleep(for: .seconds(8))
        await test()
    }

    /// Uploads (once per file version) and returns the public HTTPS URL.
    func publicURL(for path: String) async throws -> String {
        guard let config, configured else { throw AppIssue("Configure a hospedagem de mídia (S3) em Ajustes → Hospedagem para enviar arquivos do Mac a esta rede.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fingerprint = SigV4.sha256(Data("\(path)|\(size)|\(stamp)|\(config.bucket)|\(config.prefix)".utf8))
        var cache = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        // Bucket objects may expire (lifecycle rule); reuse an upload only while it is recent.
        if let cached = cache[fingerprint], let separator = cached.lastIndex(of: "|"), let uploaded = Double(cached[cached.index(after: separator)...]),
           Date().timeIntervalSince1970 - uploaded < 3 * 86400 { return String(cached[..<separator]) }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let key = "\(config.prefix)\(fingerprint.prefix(24)).\(ext)"
        try await upload(file: URL(fileURLWithPath: path), key: key, contentType: MediaKind.mime(path), config: config)
        let url = publicURL(key: key, config: config)
        cache[fingerprint] = "\(url)|\(Date().timeIntervalSince1970)"
        UserDefaults.standard.set(cache, forKey: Self.cacheKey)
        return url
    }

    /// Uploads a tiny file and fetches it anonymously to confirm the bucket is publicly readable.
    func test() async {
        guard let config, configured else { message = "Preencha bucket, região e chaves."; return }
        message = "Testando…"
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("trelune-test.txt")
            try Data("ok \(Date())".utf8).write(to: file)
            let key = "\(config.prefix)teste-conexao.txt"
            try await upload(file: file, key: key, contentType: "text/plain", config: config)
            let url = URL(string: publicURL(key: key, config: config))!
            let (_, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            message = status == 200 ? "✓ Envio e leitura pública funcionando: \(url.absoluteString)" : "O envio funcionou, mas a leitura pública retornou HTTP \(status). Libere leitura pública do prefixo \(config.prefix) (política do bucket ou CloudFront)."
        } catch { message = error.localizedDescription }
    }

    // MARK: Signed AWS requests (cloud publishing)

    /// Sends a SigV4-signed request with the hosting credentials. Returns the body and HTTP status.
    func aws(_ method: String, service: String, host awsHost: String? = nil, path: String = "/", query: [String: String] = [:], body: Data = Data(), headers extra: [String: String] = [:]) async throws -> (data: Data, status: Int) {
        guard let config, configured else { throw AppIssue("Configure a hospedagem S3 em Ajustes → Hospedagem.") }
        let host = awsHost ?? "\(service).\(config.region).amazonaws.com"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let hash = SigV4.sha256(body)
        var headers = extra.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        headers["host"] = host; headers["x-amz-date"] = formatter.string(from: Date()); headers["x-amz-content-sha256"] = hash
        let canonicalQuery = query.keys.sorted().map { "\(SigV4.encode($0, keepSlash: false))=\(SigV4.encode(query[$0]!, keepSlash: false))" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://\(host)\(SigV4.encode(path, keepSlash: true))\(canonicalQuery.isEmpty ? "" : "?" + canonicalQuery)")!)
        request.httpMethod = method; request.timeoutInterval = 1800
        if !body.isEmpty || method == "PUT" || method == "POST" { request.httpBody = body }
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(SigV4.authorization(method: method, path: path, query: canonicalQuery, headers: headers, payloadHash: hash, region: config.region, service: service, accessKey: config.accessKey, secretKey: config.secretKey), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private var bucketHost: String {
        guard let config else { return "" }
        return config.bucket.contains(".") ? "s3.\(config.region).amazonaws.com" : "\(config.bucket).s3.\(config.region).amazonaws.com"
    }
    private func objectPath(_ key: String) -> String { (config?.bucket.contains(".") == true ? "/\(config!.bucket)/" : "/") + key }
    /// Uploads a local file to a private key of the bucket.
    func putObject(file: URL, key: String) async throws {
        guard let config, configured else { throw AppIssue("Configure a hospedagem S3 em Ajustes → Hospedagem.") }
        try await upload(file: file, key: key, contentType: MediaKind.mime(file.path), config: config)
    }
    func putObject(_ data: Data, key: String, contentType: String) async throws {
        let result = try await aws("PUT", service: "s3", host: bucketHost, path: objectPath(key), body: data, headers: ["content-type": contentType])
        guard (200..<300).contains(result.status) else { throw AppIssue("O S3 recusou o envio de \(key) (HTTP \(result.status)).") }
    }
    /// Returns nil when the object does not exist.
    func getObject(_ key: String) async throws -> Data? {
        let result = try await aws("GET", service: "s3", host: bucketHost, path: objectPath(key))
        if result.status == 404 { return nil }
        guard (200..<300).contains(result.status) else { throw AppIssue("O S3 recusou a leitura de \(key) (HTTP \(result.status)).") }
        return result.data
    }
    func deleteObject(_ key: String) async throws {
        let result = try await aws("DELETE", service: "s3", host: bucketHost, path: objectPath(key))
        guard (200..<300).contains(result.status) || result.status == 404 else { throw AppIssue("O S3 recusou a remoção de \(key) (HTTP \(result.status)).") }
    }

    private func publicURL(key: String, config: Config) -> String {
        let encoded = SigV4.encode(key, keepSlash: true)
        if !config.publicBaseURL.isEmpty { return "\(config.publicBaseURL)/\(encoded)" }
        return config.bucket.contains(".") ? "https://s3.\(config.region).amazonaws.com/\(config.bucket)/\(encoded)" : "https://\(config.bucket).s3.\(config.region).amazonaws.com/\(encoded)"
    }

    private func upload(file: URL, key: String, contentType: String, config: Config) async throws {
        let pathStyle = config.bucket.contains(".")
        let host = pathStyle ? "s3.\(config.region).amazonaws.com" : "\(config.bucket).s3.\(config.region).amazonaws.com"
        let path = pathStyle ? "/\(config.bucket)/\(key)" : "/\(key)"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: Date())
        let headers = ["host": host, "x-amz-date": amzDate, "x-amz-content-sha256": "UNSIGNED-PAYLOAD", "content-type": contentType]
        var request = URLRequest(url: URL(string: "https://\(host)\(SigV4.encode(path, keepSlash: true))")!)
        request.httpMethod = "PUT"; request.timeoutInterval = 1800
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(SigV4.authorization(method: "PUT", path: path, headers: headers, payloadHash: "UNSIGNED-PAYLOAD", region: config.region, accessKey: config.accessKey, secretKey: config.secretKey), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data, as: UTF8.self)
            let code = body.range(of: "<Code>").flatMap { start in body.range(of: "</Code>").map { String(body[start.upperBound..<$0.lowerBound]) } } ?? "HTTP \(status)"
            throw AppIssue("O S3 recusou o envio de \(file.lastPathComponent): \(code). Confira bucket, região e permissão s3:PutObject.")
        }
    }
}

enum CoverFrame {
    /// Exports a JPEG frame of the video at `seconds`, for networks that take a cover image.
    static func export(video: String, at seconds: Double) async throws -> String {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: video)))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw AppIssue("Não foi possível gerar a capa do vídeo.") }
        let url = AppPaths.covers.appendingPathComponent("\(SigV4.sha256(Data("\(video)|\(seconds)".utf8)).prefix(20)).jpg")
        try data.write(to: url)
        return url.path
    }
    static func duration(_ video: String) async -> Double {
        (try? await AVURLAsset(url: URL(fileURLWithPath: video)).load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
    }
}
