import Foundation

/// Ağ katmanı soyutlaması — testler gerçek URLSession yerine sahte taşıyıcı verir.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VeribenimError.invalidResponse
        }
        return (data, http)
    }
}

public enum VeribenimError: Error, Equatable {
    case invalidResponse
    case handshakeFailed(status: Int)
    case moduleDisabled
    case notConfigured
    case http(status: Int)
}

/// Sunucudan gelen kategori beyanı — banner'ın metnini bu besler.
public struct ConsentCategoryInfo: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let labelEn: String
    public let required: Bool
    public let cookies: [Tracker]

    public struct Tracker: Decodable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let description: String?
        /// Mobilde 'device_id' / 'app_storage' — 'cookie' DEĞİL (KVKK Rehberi No:69).
        public let storageType: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, description
            case storageType = "storage_type"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, required, cookies
        case labelEn = "label_en"
    }
}

public struct PreferencesResponse: Decodable, Equatable, Sendable {
    public let status: Bool
    public let environmentName: String?
    public let bannerSettings: [String: AnyCodable]?
    public let categories: [ConsentCategoryInfo]
    public let platform: String?

    private enum CodingKeys: String, CodingKey {
        case status, categories, platform
        case environmentName = "environment_name"
        case bannerSettings = "banner_settings"
    }
}

/// Banner ayarları serbest şekilli JSON; tipini sabitlemek sunucu tarafında
/// eklenen her yeni alanda SDK güncellemesi gerektirirdi.
public struct AnyCodable: Decodable, Equatable, Sendable {
    public let value: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = String(b) }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = nil }
    }
}

struct HandshakeResponse: Decodable {
    let status: Bool
    let token: String
    let deviceToken: String
    let secret: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case status, token, secret
        case deviceToken = "device_token"
        case expiresAt = "expires_at"
    }
}

/// Veribenim API istemcisi.
///
/// Uçlar `veribenim.api/routes/api.php` ile birebir:
///   POST /api/app/session          → el sıkışma (imzasız, tek meşru istisna)
///   GET  /api/preferences/{token}  → kategori beyanı (?platform=mobile)
///   POST /api/v/{token}/c          → rıza kaydı (imzalı)
public actor VeribenimAPI {
    private let baseURL: URL
    private let transport: Transport
    private let decoder: JSONDecoder

    public init(baseURL: URL, transport: Transport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    // MARK: - El sıkışma

    public func handshake(appIdentifier: String, platform: String, appVersion: String?, osVersion: String?) async throws -> DeviceSession {
        var body: [String: String] = ["app_identifier": appIdentifier, "platform": platform]
        body["app_version"] = appVersion
        body["os_version"] = osVersion

        var request = URLRequest(url: baseURL.appendingPathComponent("api/app/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport.send(request)

        // 404 = uygulama bulunamadı VEYA mobil rıza modülü kapalı. Sunucu bu ikisini
        // bilerek ayırmıyor (numaralandırma kanalı); SDK da ayırt etmeye çalışmaz.
        guard http.statusCode == 200 else {
            throw VeribenimError.handshakeFailed(status: http.statusCode)
        }

        let decoded = try decoder.decode(HandshakeResponse.self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let expiry = formatter.date(from: decoded.expiresAt)
            ?? ISO8601DateFormatter().date(from: decoded.expiresAt)
            ?? Date().addingTimeInterval(30 * 86_400)

        return DeviceSession(
            environmentToken: decoded.token,
            deviceToken: decoded.deviceToken,
            secret: decoded.secret,
            expiresAt: expiry
        )
    }

    // MARK: - Beyan

    public func preferences(token: String, sessionId: String?) async throws -> PreferencesResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/preferences/\(token)"),
            resolvingAgainstBaseURL: false
        )!
        var items = [URLQueryItem(name: "platform", value: "mobile")]
        if let sessionId { items.append(URLQueryItem(name: "session_id", value: sessionId)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await transport.send(request)
        guard http.statusCode == 200 else { throw VeribenimError.http(status: http.statusCode) }

        return try decoder.decode(PreferencesResponse.self, from: data)
    }

    // MARK: - Rıza kaydı (imzalı)

    @discardableResult
    public func logConsent(session: DeviceSession, entry: QueuedConsent) async throws -> Bool {
        let payload: [String: Any] = [
            "action": entry.action.rawValue,
            "consents": entry.preferences.payload,
            "session_id": entry.sessionId,
            "platform": "mobile",
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/v/\(session.environmentToken)/c")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        // İmza gövdenin TAM baytları üzerinden üretilir — request.httpBody ile
        // imzalanan dize ayrışırsa sunucu 403 döner.
        for (key, value) in RequestSigner.headers(for: session, body: body) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (_, http) = try await transport.send(request)

        // 403 → cihaz oturumu geçersiz veya modül kapandı. Çağıran yeniden
        // el sıkışır; kuyruktaki kayıt korunur.
        guard http.statusCode == 200 else { throw VeribenimError.http(status: http.statusCode) }
        return true
    }
}
