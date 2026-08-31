import Foundation

public struct VeribenimConfig: Sendable {
    /// Bundle id (iOS) / package name (Android) — konsolda kayıtlı olan değer.
    public let appIdentifier: String
    public let platform: String
    public let baseURL: URL
    /// Rıza kaç gün sonra yeniden sorulsun. Sunucu beyanı değişirse zaten sorulur.
    public let reconsentDays: Int

    public init(
        appIdentifier: String,
        platform: String = "ios",
        baseURL: URL = URL(string: "https://live.veribenim.com")!,
        reconsentDays: Int = 365
    ) {
        self.appIdentifier = appIdentifier
        self.platform = platform
        self.baseURL = baseURL
        self.reconsentDays = reconsentDays
    }
}

/// Veribenim mobil rıza yöneticisi.
///
/// Kullanım:
/// ```swift
/// let vb = Veribenim(config: .init(appIdentifier: "com.ornek.uygulama"))
/// if await vb.needsConsent() { /* rıza ekranını göster */ }
/// await vb.accept(.granted)                 // ziyaretçi karar verdi
/// if await vb.isAllowed(.analytics) { ... } // ölçüm başlat
/// ```
///
/// ATT SIRASI (iOS): Apple, ATT prompt'undan önce kendi izin ekranınızı
/// göstermenize izin verir ama ATT'yi ATLAMANIZA izin vermez. Doğru sıra:
/// önce Veribenim rızası → `marketing == true` ise ATT prompt'u. Ters sıra
/// App Store reddi sebebidir; bu yüzden SDK ATT'yi kendisi ÇAĞIRMAZ, yalnızca
/// `shouldRequestTracking` ile ne zaman çağırmanız gerektiğini söyler.
public actor Veribenim {
    private let config: VeribenimConfig
    private let api: VeribenimAPI
    private let storage: ConsentStorage

    private var session: DeviceSession?
    private var record: ConsentRecord?
    private var latestVersion: String?

    /// Rıza değiştiğinde tetiklenir — Firebase/AppsFlyer köprüsü buraya bağlanır.
    private var observers: [(ConsentPreferences) -> Void] = []

    public init(
        config: VeribenimConfig,
        storage: ConsentStorage = UserDefaultsConsentStorage(),
        transport: Transport = URLSessionTransport()
    ) {
        self.config = config
        self.storage = storage
        self.api = VeribenimAPI(baseURL: config.baseURL, transport: transport)
        self.session = storage.loadSession()
        self.record = storage.loadRecord()
    }

    // MARK: - Durum sorgulama

    public var preferences: ConsentPreferences {
        record?.preferences ?? .denied
    }

    /// Rıza gerekiyor mu? Üç sebepten biri: hiç karar yok, karar eskidi,
    /// veya sunucudaki beyan sürümü değişti.
    public func needsConsent(now: Date = Date()) -> Bool {
        guard let record else { return true }

        let age = now.timeIntervalSince(record.decidedAt)
        if age > Double(config.reconsentDays) * 86_400 { return true }

        if let latestVersion, let recorded = record.consentVersion, latestVersion != recorded {
            return true
        }

        return false
    }

    /// Bu kategoriye izin var mı? Ölçüm/reklam SDK'ları bu kapıdan geçmeli.
    public func isAllowed(_ category: ConsentCategory) -> Bool {
        preferences[category]
    }

    /// iOS: ATT prompt'u şimdi gösterilmeli mi?
    ///
    /// Yalnızca pazarlama rızası verilmişse `true`. Reddeden kullanıcıya ATT
    /// sormak, kullanıcının az önce verdiği kararı yok saymaktır.
    public var shouldRequestTracking: Bool {
        preferences.marketing
    }

    public func onConsentChange(_ handler: @escaping (ConsentPreferences) -> Void) {
        observers.append(handler)
        handler(preferences)
    }

    // MARK: - Karar yazma

    public func accept(_ preferences: ConsentPreferences = .granted) async {
        await record(preferences, action: preferences == .granted ? .acceptAll : .savePreferences)
    }

    public func rejectAll() async {
        await record(.denied, action: .rejectAll)
    }

    public func withdraw() async {
        await record(.denied, action: .withdraw)
    }

    private func record(_ preferences: ConsentPreferences, action: ConsentAction) async {
        let sessionId = self.record?.sessionId ?? UUID().uuidString

        let entry = ConsentRecord(
            preferences: preferences,
            action: action,
            consentVersion: latestVersion,
            sessionId: sessionId
        )

        // Önce DİSKE, sonra ağa. Ters sırada, ağ hatasında ziyaretçinin kararı
        // hiç var olmamış gibi olurdu — ve banner bir sonraki açılışta yeniden
        // çıkardı. Kullanıcı iki kez aynı soruyu cevaplamamalı.
        self.record = entry
        storage.save(record: entry)

        observers.forEach { $0(preferences) }

        enqueue(QueuedConsent(
            action: action,
            preferences: preferences,
            sessionId: sessionId,
            occurredAt: entry.decidedAt
        ))

        await flush()
    }

    // MARK: - Sunucu iletişimi

    /// Beyanı çeker; sürüm değiştiyse `needsConsent()` yeniden true olur.
    @discardableResult
    public func refresh() async throws -> PreferencesResponse {
        let session = try await ensureSession()
        let response = try await api.preferences(
            token: session.environmentToken,
            sessionId: record?.sessionId
        )
        return response
    }

    private func ensureSession() async throws -> DeviceSession {
        if let session, session.isUsable() { return session }

        let fresh = try await api.handshake(
            appIdentifier: config.appIdentifier,
            platform: config.platform,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: nil
        )

        session = fresh
        storage.save(session: fresh)
        return fresh
    }

    // MARK: - Offline kuyruk

    private func enqueue(_ entry: QueuedConsent) {
        var queue = storage.loadQueue()
        queue.append(entry)
        storage.save(queue: queue)
    }

    /// Kuyruğu boşaltmayı dener. Ağ yoksa kayıtlar diskte kalır ve bir sonraki
    /// açılışta yeniden denenir — rıza ispatı kaybolmaz.
    public func flush() async {
        var queue = storage.loadQueue()
        guard !queue.isEmpty else { return }

        let session: DeviceSession
        do { session = try await ensureSession() } catch { return }

        var remaining: [QueuedConsent] = []

        for entry in queue {
            do {
                try await api.logConsent(session: session, entry: entry)
            } catch {
                // 403 → oturum düşmüş olabilir; bir sonraki denemede yeniden
                // el sıkışılsın diye oturum atılır. Kayıt kuyrukta kalır.
                if case VeribenimError.http(let status) = error, status == 403 {
                    self.session = nil
                    storage.clearSession()
                }
                remaining.append(entry)
            }
        }

        queue = remaining
        storage.save(queue: queue)
    }
}
