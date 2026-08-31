import Foundation

/// Rızanın kalıcı olarak saklandığı yer.
///
/// Protokol olması test için değil, DOĞRULUK için: uygulama kendi güvenli
/// deposunu (Keychain, şifreli dosya) getirebilmeli. Varsayılan UserDefaults
/// rıza kaydı için yeterlidir — sır değil, kullanıcının kendi kararıdır.
public protocol ConsentStorage: AnyObject {
    func loadRecord() -> ConsentRecord?
    func save(record: ConsentRecord)
    func clearRecord()

    func loadSession() -> DeviceSession?
    func save(session: DeviceSession)
    func clearSession()

    func loadQueue() -> [QueuedConsent]
    func save(queue: [QueuedConsent])
}

/// Ağ yokken diske yazılan rıza kaydı.
///
/// Rıza ispatı KVKK Md.3/1-a gereği veri sorumlusundadır: ziyaretçi uçakta
/// "reddet" dediyse ve bu kayıt kaybolduysa, sistemde rıza yokmuş gibi değil
/// **hiç sorulmamış** gibi görünür. Bu yüzden kuyruk kalıcıdır.
public struct QueuedConsent: Codable, Equatable, Sendable {
    public let action: ConsentAction
    public let preferences: ConsentPreferences
    public let sessionId: String
    public let occurredAt: Date

    public init(action: ConsentAction, preferences: ConsentPreferences, sessionId: String, occurredAt: Date = Date()) {
        self.action = action
        self.preferences = preferences
        self.sessionId = sessionId
        self.occurredAt = occurredAt
    }
}

public final class UserDefaultsConsentStorage: ConsentStorage {
    private enum Key {
        static let record  = "com.veribenim.consent.record"
        static let session = "com.veribenim.consent.session"
        static let queue   = "com.veribenim.consent.queue"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    public func loadRecord() -> ConsentRecord? { read(Key.record) }
    public func save(record: ConsentRecord) { write(record, Key.record) }
    public func clearRecord() { defaults.removeObject(forKey: Key.record) }

    public func loadSession() -> DeviceSession? { read(Key.session) }
    public func save(session: DeviceSession) { write(session, Key.session) }
    public func clearSession() { defaults.removeObject(forKey: Key.session) }

    public func loadQueue() -> [QueuedConsent] { read(Key.queue) ?? [] }
    public func save(queue: [QueuedConsent]) { write(queue, Key.queue) }
}

/// Bellekte tutan depo — testler ve önizleme için.
public final class InMemoryConsentStorage: ConsentStorage {
    private var record: ConsentRecord?
    private var session: DeviceSession?
    private var queue: [QueuedConsent] = []

    public init() {}

    public func loadRecord() -> ConsentRecord? { record }
    public func save(record: ConsentRecord) { self.record = record }
    public func clearRecord() { record = nil }

    public func loadSession() -> DeviceSession? { session }
    public func save(session: DeviceSession) { self.session = session }
    public func clearSession() { session = nil }

    public func loadQueue() -> [QueuedConsent] { queue }
    public func save(queue: [QueuedConsent]) { self.queue = queue }
}
