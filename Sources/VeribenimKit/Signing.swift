import Foundation
import CryptoKit

/// Cihaz oturumu — sunucudaki `app_device_sessions` satırının istemci tarafı.
public struct DeviceSession: Codable, Equatable, Sendable {
    public let environmentToken: String
    public let deviceToken: String
    /// Paylaşılan sır. Keychain'de yaşar, asla loglanmaz.
    public let secret: String
    public let expiresAt: Date

    public init(environmentToken: String, deviceToken: String, secret: String, expiresAt: Date) {
        self.environmentToken = environmentToken
        self.deviceToken = deviceToken
        self.secret = secret
        self.expiresAt = expiresAt
    }

    /// Süresi dolmadan önce yenilenir — tam sınırda yenilemek, uçuştaki bir
    /// isteğin sunucuya süresi dolmuş olarak varmasına yol açar.
    public func isUsable(now: Date = Date(), margin: TimeInterval = 3600) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

/// İstek imzalayıcı.
///
/// Sunucu tarafı karşılığı: `AppDeviceSession::verifySignature`
/// (veribenim.api/app/Models/AppDeviceSession.php).
///
/// İmzalanan dize: `"{deviceToken}.{timestamp}.{ham gövde}"`
///   • timestamp → replay penceresi (sunucu ±5 dk kabul eder)
///   • gövde     → imza başka bir gövdeye yapıştırılamasın diye
public enum RequestSigner {
    public static let appHeader = "X-VB-App"
    public static let timestampHeader = "X-VB-Timestamp"
    public static let signatureHeader = "X-VB-Signature"

    public static func signature(deviceToken: String, secret: String, timestamp: Int, body: Data) -> String {
        let payload = "\(deviceToken).\(timestamp).\(String(decoding: body, as: UTF8.self))"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public static func headers(for session: DeviceSession, body: Data, now: Date = Date()) -> [String: String] {
        let ts = Int(now.timeIntervalSince1970)
        return [
            appHeader: session.deviceToken,
            timestampHeader: String(ts),
            signatureHeader: signature(
                deviceToken: session.deviceToken,
                secret: session.secret,
                timestamp: ts,
                body: body
            ),
        ]
    }
}
