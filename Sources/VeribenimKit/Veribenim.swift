import Foundation

public struct VeribenimConfig: Sendable {
    /// Bugünkü üretim adresi. `baseURL` ile değiştirilebilir (staging, kendi
    /// alan adınız üzerinden proxy vb.).
    public static let defaultBaseURL = URL(string: "https://live.veribenim.com")!

    /// Bundle id (iOS) / package name (Android) — konsolda kayıtlı olan değer.
    public let appIdentifier: String
    public let platform: String
    public let baseURL: URL
    /// Rıza kaç gün sonra yeniden sorulsun. Sunucu beyanı değişirse zaten sorulur.
    public let reconsentDays: Int
    /// El sıkışmada gönderilir; nil ise Info.plist'teki `CFBundleShortVersionString`.
    public let appVersion: String?
    /// El sıkışmada gönderilir; nil ise `ProcessInfo` sürümü.
    public let osVersion: String?
    /// Rıza kaydının `user_agent` alanı. Sunucu boş değeri bot sayar.
    public let userAgent: String

    public init(
        appIdentifier: String,
        platform: String = "ios",
        baseURL: URL = VeribenimConfig.defaultBaseURL,
        reconsentDays: Int = 365,
        appVersion: String? = nil,
        osVersion: String? = nil,
        userAgent: String? = nil
    ) {
        self.appIdentifier = appIdentifier
        self.platform = platform
        self.baseURL = baseURL
        self.reconsentDays = reconsentDays
        self.appVersion = appVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.osVersion = osVersion ?? {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }()
        self.userAgent = userAgent ?? Self.defaultUserAgent(platform: platform, osVersion: self.osVersion)
    }

    /// Dört mobil SDK'da aynı biçim: `VeribenimSDK/<sürüm> (<platform>[ <os>]; <dil>)`.
    /// Sunucudaki `BotDetector` kalıplarından (ör. `bot/`, `okhttp`, `java/`)
    /// hiçbirini içermemesi gerekir — testle sabitlendi.
    public static func defaultUserAgent(platform: String, osVersion: String? = nil) -> String {
        let os = osVersion.map { "\(platform) \($0)" } ?? platform
        return "VeribenimSDK/\(Veribenim.sdkVersion) (\(os); swift)"
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
    /// Paket sürümü — `user_agent` alanına girer. Etiketle birlikte güncelleyin.
    public static let sdkVersion = "1.0.0"

    private let config: VeribenimConfig
    private let api: VeribenimAPI
    private let storage: ConsentStorage

    private var session: DeviceSession?
    private var record: ConsentRecord?
    private var latestVersion: String?

    /// Uçuştaki kuyruk boşaltma. Actor yeniden girişlidir: `await` sırasında
    /// ikinci bir `flush()` başlarsa aynı kaydı iki kez gönderir, ve ilk
    /// çağrının sonunda yazdığı kuyruk aradaki yeni kararı SİLERDİ.
    private var flushTask: Task<Void, Never>?
    private var flushAgain = false

    /// Rıza değiştiğinde tetiklenir — Firebase/AppsFlyer köprüsü buraya bağlanır.
    private var observers: [(ConsentPreferences) -> Void] = []

    public init(
        config: VeribenimConfig,
        storage: ConsentStorage = UserDefaultsConsentStorage(),
        transport: Transport = URLSessionTransport()
    ) {
        self.config = config
        self.storage = storage
        self.api = VeribenimAPI(baseURL: config.baseURL, transport: transport, userAgent: config.userAgent)
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
            appVersion: config.appVersion,
            osVersion: config.osVersion
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
    ///
    /// Aynı anda tek boşaltma çalışır; arada gelen çağrı onun bitmesini bekler
    /// ve yeni eklenen kayıt aynı turda gönderilir.
    public func flush() async {
        if let running = flushTask {
            flushAgain = true
            await running.value
            return
        }

        let task = Task { await self.runFlushLoop() }
        flushTask = task
        await task.value
    }

    private func runFlushLoop() async {
        repeat {
            flushAgain = false
            await drainOnce()
        } while flushAgain
        // Döngü kontrolüyle bu satır arasında `await` yok: araya giren çağrı
        // ya döngüyü bir tur daha döndürür ya da yeni bir görev başlatır.
        flushTask = nil
    }

    /// Tek tur. Kurallar dört SDK'da aynı (README → "Sunucu sözleşmesi"):
    ///
    /// - Sıra korunur: geçici bir hatada DURULUR, sonraki kayıtlar gönderilmez.
    ///   Sunucu aynı `session_id` satırını günceller; "geri çek" ile "kabul"
    ///   yer değiştirirse son durum ters yazılırdı.
    /// - 403 / 404 → cihaz oturumu atılır, BİR KEZ yeniden el sıkışılır ve
    ///   aynı kayıt yeniden denenir (iptal, süre dolumu, ürün devri).
    /// - 400 / 422 → kalıcı ret: kayıt hiçbir zaman kabul edilmeyecek, kuyruğu
    ///   sonsuza dek tıkamasın diye atılır.
    /// - 402 (kota), 429, 5xx, ağ hatası → kayıt kuyrukta kalır.
    private func drainOnce() async {
        let snapshot = storage.loadQueue()
        guard !snapshot.isEmpty else { return }

        var session: DeviceSession
        do { session = try await ensureSession() } catch { return }

        var handled = 0
        var rehandshaken = false

        entries: for entry in snapshot {
            while true {
                do {
                    try await api.logConsent(session: session, entry: entry)
                    handled += 1
                    continue entries
                } catch VeribenimError.http(let status) where status == 400 || status == 422 {
                    handled += 1
                    continue entries
                } catch VeribenimError.http(let status) where (status == 403 || status == 404) && !rehandshaken {
                    rehandshaken = true
                    self.session = nil
                    storage.clearSession()
                    do { session = try await ensureSession() } catch { break entries }
                    // aynı kaydı yeni oturumla yeniden dene
                } catch {
                    if case VeribenimError.http(let status) = error, status == 403 {
                        // Yeni oturum da reddedildi: bir sonraki denemede yine
                        // el sıkışılsın.
                        self.session = nil
                        storage.clearSession()
                    }
                    break entries
                }
            }
        }

        // Tur sürerken eklenen kayıtlar kuyruğun SONUNDA durur; yalnızca bu
        // turda işlenen baştaki kayıtlar çıkarılır.
        let current = storage.loadQueue()
        storage.save(queue: Array(current.dropFirst(min(handled, current.count))))
    }
}
