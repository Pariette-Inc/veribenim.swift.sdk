import XCTest
@testable import VeribenimKit

/// API sözleşmesini sabitleyen testler.
///
/// Kaynak: veribenim.api → `AppSessionController::issue`, `ConsentController::log`,
/// `PreferenceCenterController::show`, `EnvironmentOriginCheck::handleNativeRequest`
/// ve `tests/Feature/MobileConsentTest.php`. Bu testlerden biri kırılıyorsa ya
/// SDK sözleşmeden saptı ya da sunucu değişti — ikisi de bilinçli karar ister.

/// Sıralı yanıt veren, istekleri kaydeden sahte taşıyıcı. İsteğe bağlı bir
/// kapı ile ilk rıza isteğini bekletebilir (eşzamanlılık testi için).
final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(Int, String)] = []
    private var _requests: [URLRequest] = []
    var gate: Gate?

    init(_ responses: [(Int, String)] = []) { queue = responses }

    func push(_ responses: (Int, String)...) {
        lock.lock(); queue.append(contentsOf: responses); lock.unlock()
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var consentRequests: [URLRequest] { requests.filter { $0.url!.path.hasSuffix("/c") } }
    var handshakeRequests: [URLRequest] { requests.filter { $0.url!.path == "/api/app/session" } }

    private func record(_ request: URLRequest) {
        lock.lock(); _requests.append(request); lock.unlock()
    }

    private func next() -> (Int, String)? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)

        if let gate, request.url!.path.hasSuffix("/c") { await gate.passOnce() }

        guard let (status, body) = next() else { throw URLError(.notConnectedToInternet) }

        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }
}

/// İlk geçişi `open()` çağrılana dek bekleten kapı.
actor Gate {
    private var used = false
    private var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    func passOnce() async {
        guard !used else { return }
        used = true
        arrived = true
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func hasArrived() -> Bool { arrived }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

private func handshake(token: String = "env-token", device: String = "dev-token", secret: String = "s3cr3t") -> (Int, String) {
    (200, #"{"status":true,"token":"\#(token)","device_token":"\#(device)","secret":"\#(secret)","expires_at":"2099-01-01T00:00:00+00:00"}"#)
}

private let ok: (Int, String) = (200, #"{"status":true,"message":"Consent recorded","consent_renewal_required":false}"#)

private func json(_ data: Data?) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
}

/// Sunucudaki `BotDetector::BOT_PATTERNS` içinden SDK user-agent'ına
/// karışabilecek olanlar. Biri eşleşirse mobil rıza raporlardan düşer.
let botPatterns = ["bot/", "crawler", "spider", "scraper", "fetcher", "wget/", "curl/",
                   "python-requests", "go-http-client", "ruby", "java/", "apache-httpclient",
                   "okhttp", "axios/", "node-fetch", "got/", "headlesschrome", "whatsapp"]

final class HandshakeContractTests: XCTestCase {
    private func sdk(_ t: ScriptedTransport, storage: ConsentStorage = InMemoryConsentStorage(),
                     appVersion: String? = "1.4.2") -> Veribenim {
        Veribenim(
            config: .init(appIdentifier: "com.ornek.uygulama", baseURL: URL(string: "https://api.test")!,
                          appVersion: appVersion, osVersion: "17.4"),
            storage: storage, transport: t
        )
    }

    func testHandshakeRequestShape() async throws {
        let t = ScriptedTransport([handshake(), ok])
        await sdk(t).accept(.granted)

        let req = try XCTUnwrap(t.handshakeRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.test/api/app/session")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-VB-App"))

        let body = json(req.httpBody)
        XCTAssertEqual(Set(body.keys), ["app_identifier", "platform", "app_version", "os_version"])
        XCTAssertEqual(body["app_identifier"] as? String, "com.ornek.uygulama")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["app_version"] as? String, "1.4.2")
        XCTAssertEqual(body["os_version"] as? String, "17.4")
    }

    /// Sunucu `max:32` doğrular; uzun sürüm dizesi el sıkışmayı 422'ye düşürürdü.
    func testHandshakeTruncatesLongVersion() async {
        let t = ScriptedTransport([handshake(), ok])
        await sdk(t, appVersion: String(repeating: "9", count: 60)).accept(.granted)

        XCTAssertEqual((json(t.handshakeRequests.first?.httpBody)["app_version"] as? String)?.count, 32)
    }

    func testSessionIsStoredAndReused() async throws {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport([handshake(), ok, ok])
        let vb = sdk(t, storage: storage)

        await vb.accept(.granted)
        await vb.rejectAll()

        XCTAssertEqual(t.handshakeRequests.count, 1, "Geçerli oturum varken yeniden el sıkışılmaz.")
        let saved = try XCTUnwrap(storage.loadSession())
        XCTAssertEqual(saved.environmentToken, "env-token")
        XCTAssertEqual(saved.deviceToken, "dev-token")
        XCTAssertEqual(saved.secret, "s3cr3t")
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: saved.expiresAt), 2099)
    }

    func testSessionSurvivesRestart() async {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport([handshake(), ok, ok])
        await sdk(t, storage: storage).accept(.granted)
        await sdk(t, storage: storage).rejectAll()

        XCTAssertEqual(t.handshakeRequests.count, 1)
    }

    /// Süresine 1 saatten az kalan oturum kullanılmaz — uçuştaki istek süresi
    /// dolmuş olarak varırdı.
    func testNearlyExpiredSessionIsRenewed() async {
        let storage = InMemoryConsentStorage()
        storage.save(session: DeviceSession(environmentToken: "old-env", deviceToken: "old-dev",
                                            secret: "x", expiresAt: Date().addingTimeInterval(600)))
        let t = ScriptedTransport([handshake(), ok])
        await sdk(t, storage: storage).accept(.granted)

        XCTAssertEqual(t.handshakeRequests.count, 1)
        XCTAssertEqual(t.consentRequests.first?.url?.path, "/api/v/env-token/c")
        XCTAssertEqual(storage.loadSession()?.deviceToken, "dev-token")
    }

    /// 404 = bilinmeyen uygulama VEYA modül kapalı (sunucu bilerek ayırmaz).
    func testHandshake404KeepsDecisionQueued() async {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport([(404, #"{"status":false}"#)])
        let vb = sdk(t, storage: storage)
        await vb.accept(.granted)

        XCTAssertEqual(t.requests.count, 1)
        XCTAssertNil(storage.loadSession())
        XCTAssertEqual(storage.loadQueue().count, 1)
        let needs = await vb.needsConsent()
        XCTAssertFalse(needs)
    }

    func testHandshakeErrorSurfaces() async {
        let api = VeribenimAPI(baseURL: URL(string: "https://api.test")!,
                               transport: ScriptedTransport([(404, "{}")]))
        do {
            _ = try await api.handshake(appIdentifier: "a", platform: "ios", appVersion: nil, osVersion: nil)
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? VeribenimError, .handshakeFailed(status: 404))
        }
    }

    func testHandshakeOmitsNilVersions() async throws {
        let t = ScriptedTransport([handshake()])
        let api = VeribenimAPI(baseURL: URL(string: "https://api.test")!, transport: t)
        _ = try await api.handshake(appIdentifier: "a", platform: "ios", appVersion: nil, osVersion: nil)
        XCTAssertEqual(Set(json(t.requests.first?.httpBody).keys), ["app_identifier", "platform"])
    }
}

final class ConsentContractTests: XCTestCase {
    private func sdk(_ t: ScriptedTransport, storage: ConsentStorage = InMemoryConsentStorage()) -> Veribenim {
        Veribenim(
            config: .init(appIdentifier: "com.ornek.uygulama", baseURL: URL(string: "https://api.test")!,
                          appVersion: "1.0", osVersion: "17.4"),
            storage: storage, transport: t
        )
    }

    func testConsentBodyMatchesContract() async throws {
        let t = ScriptedTransport([handshake(), ok])
        await sdk(t).accept(ConsentPreferences(functional: true, analytics: false, marketing: true))

        let req = try XCTUnwrap(t.consentRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.test/api/v/env-token/c")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Origin"), "Origin varsa sunucu native dalı hiç denemez.")
        XCTAssertNil(req.value(forHTTPHeaderField: "Referer"))

        let body = json(req.httpBody)
        XCTAssertEqual(Set(body.keys), ["action", "consents", "session_id", "user_agent"],
                       "`platform` gövdede olmamalı: sunucu damgayı imzalı oturumdan okur.")
        XCTAssertEqual(body["action"] as? String, "save_preferences")
        XCTAssertEqual(body["consents"] as? [String: Bool],
                       ["strictly_necessary": true, "functional": true, "analytics": false, "marketing": true])
        XCTAssertFalse((body["session_id"] as? String ?? "").isEmpty)
    }

    func testActionsMapToServerEnum() async {
        let t = ScriptedTransport([handshake(), ok, ok, ok, ok])
        let vb = sdk(t)
        await vb.accept(.granted)
        await vb.accept(ConsentPreferences(analytics: true))
        await vb.rejectAll()
        await vb.withdraw()

        let actions = t.consentRequests.map { json($0.httpBody)["action"] as? String }
        XCTAssertEqual(actions, ["accept_all", "save_preferences", "reject_all", "withdraw"])

        let sessionIds = Set(t.consentRequests.map { json($0.httpBody)["session_id"] as? String })
        XCTAssertEqual(sessionIds.count, 1, "Aynı cihazın kararları aynı session_id ile gider.")
    }

    /// Sunucu `user_agent` boşsa kaydı bot sayar (BotDetector: empty_ua).
    func testUserAgentIsSentAndNotBotLike() async throws {
        let t = ScriptedTransport([handshake(), ok])
        await sdk(t).accept(.granted)

        let ua = try XCTUnwrap(json(t.consentRequests.first?.httpBody)["user_agent"] as? String)
        XCTAssertEqual(ua, "VeribenimSDK/\(Veribenim.sdkVersion) (ios 17.4; swift)")
        for p in botPatterns { XCTAssertFalse(ua.lowercased().contains(p), "UA bot kalıbı içeriyor: \(p)") }
    }

    func testSignatureCoversExactBodyBytes() async throws {
        let t = ScriptedTransport([handshake(), ok])
        await sdk(t).accept(.granted)

        let req = try XCTUnwrap(t.consentRequests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-VB-App"), "dev-token")
        let ts = try XCTUnwrap(Int(req.value(forHTTPHeaderField: "X-VB-Timestamp") ?? ""))
        XCTAssertLessThan(abs(ts - Int(Date().timeIntervalSince1970)), 5, "Sunucu ±300 sn kabul eder; saniye cinsinden olmalı.")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-VB-Signature"),
                       RequestSigner.signature(deviceToken: "dev-token", secret: "s3cr3t", timestamp: ts, body: req.httpBody!))
    }

    // MARK: Hata durumları

    /// 403 (oturum iptal / süre dolumu / ürün devri) → bir kez yeniden el
    /// sıkış ve aynı kaydı YENİ token ile yeniden dene.
    func testForbiddenRehandshakesAndRetriesOnce() async throws {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport([handshake(), (403, #"{"status":false,"message":"Unauthorized device"}"#),
                                   handshake(token: "new-env", device: "new-dev", secret: "new"), ok])
        await sdk(t, storage: storage).accept(.granted)

        XCTAssertEqual(t.handshakeRequests.count, 2)
        XCTAssertEqual(t.consentRequests.count, 2)
        let retry = try XCTUnwrap(t.consentRequests.last)
        XCTAssertEqual(retry.url?.path, "/api/v/new-env/c")
        XCTAssertEqual(retry.value(forHTTPHeaderField: "X-VB-App"), "new-dev")
        XCTAssertTrue(storage.loadQueue().isEmpty)
        XCTAssertEqual(storage.loadSession()?.deviceToken, "new-dev")
    }

    func testForbiddenTwiceStopsAndKeepsRecord() async {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport([handshake(), (403, "{}"), handshake(), (403, "{}"), ok])
        await sdk(t, storage: storage).accept(.granted)

        XCTAssertEqual(t.requests.count, 4, "Sonsuz el sıkışma döngüsü olmamalı.")
        XCTAssertNil(storage.loadSession())
        XCTAssertEqual(storage.loadQueue().count, 1)
    }

    /// Kota dolu → kayıt kuyrukta kalır, SIRA korunur (sonraki kayıt gönderilmez).
    func testQuotaExceededKeepsQueueAndOrder() async {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport()
        let vb = sdk(t, storage: storage)
        await vb.accept(.granted)     // çevrimdışı
        await vb.withdraw()           // çevrimdışı
        XCTAssertEqual(storage.loadQueue().count, 2)

        t.push(handshake(), (402, #"{"status":false,"message":"Impression quota exceeded"}"#))
        await vb.flush()

        XCTAssertEqual(t.consentRequests.count, 1, "İlk kayıt gidemediyse ikincisi öne geçmemeli.")
        XCTAssertEqual(storage.loadQueue().map(\.action), [.acceptAll, .withdraw])
    }

    /// 422 hiçbir zaman düzelmez; kuyruğu sonsuza dek tıkamamalı.
    func testValidationErrorDropsOnlyThatEntry() async {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport()
        let vb = sdk(t, storage: storage)
        await vb.accept(.granted)
        await vb.rejectAll()

        t.push(handshake(), (422, #"{"message":"invalid","errors":{}}"#), ok)
        await vb.flush()

        XCTAssertEqual(t.consentRequests.count, 2)
        XCTAssertTrue(storage.loadQueue().isEmpty)
    }

    func testServerErrorAndThrottleKeepQueue() async {
        for status in [429, 500, 503] {
            let storage = InMemoryConsentStorage()
            let t = ScriptedTransport([handshake(), (status, "{}")])
            await sdk(t, storage: storage).accept(.granted)
            XCTAssertEqual(storage.loadQueue().count, 1, "\(status) geçicidir")
            XCTAssertNotNil(storage.loadSession(), "\(status) oturumu düşürmemeli")
        }
    }

    func testOfflineQueueSendsInOrderWhenBack() async {
        let storage = InMemoryConsentStorage()
        let t = ScriptedTransport()
        let vb = sdk(t, storage: storage)
        await vb.accept(.granted)
        await vb.withdraw()

        t.push(handshake(), ok, ok)
        await vb.flush()

        XCTAssertEqual(t.consentRequests.map { json($0.httpBody)["action"] as? String }, ["accept_all", "withdraw"])
        XCTAssertTrue(storage.loadQueue().isEmpty)
    }

    /// Boşaltma sürerken verilen karar kaybolmamalı ve iki kez gönderilmemeli.
    func testDecisionDuringFlushIsNotLostOrDuplicated() async throws {
        let storage = InMemoryConsentStorage()
        let gate = Gate()
        let t = ScriptedTransport([handshake(), ok, ok])
        t.gate = gate
        let vb = sdk(t, storage: storage)

        let first = Task { await vb.accept(.granted) }
        while !(await gate.hasArrived()) { await Task.yield() }

        let second = Task { await vb.rejectAll() }
        try await Task.sleep(nanoseconds: 50_000_000)   // ikinci karar kuyruğa girsin
        await gate.open()
        await first.value
        await second.value

        XCTAssertEqual(t.consentRequests.map { json($0.httpBody)["action"] as? String }, ["accept_all", "reject_all"])
        XCTAssertTrue(storage.loadQueue().isEmpty)
    }
}

final class PreferencesContractTests: XCTestCase {
    func testPreferencesRequestShape() async throws {
        let storage = InMemoryConsentStorage()
        storage.save(record: ConsentRecord(preferences: .granted, action: .acceptAll, sessionId: "cihaz-1"))
        let t = ScriptedTransport([handshake(), (200, #"{"status":true,"categories":[],"platform":"mobile"}"#)])
        let vb = Veribenim(config: .init(appIdentifier: "a", baseURL: URL(string: "https://api.test")!),
                           storage: storage, transport: t)

        _ = try await vb.refresh()

        let req = try XCTUnwrap(t.requests.last)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/api/preferences/env-token")
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "platform" }?.value, "mobile")
        XCTAssertEqual(items.first { $0.name == "session_id" }?.value, "cihaz-1")
    }

    func testPreferencesErrorIsThrown() async {
        let t = ScriptedTransport([handshake(), (404, #"{"status":false}"#)])
        let vb = Veribenim(config: .init(appIdentifier: "a", baseURL: URL(string: "https://api.test")!),
                           storage: InMemoryConsentStorage(), transport: t)
        do { _ = try await vb.refresh(); XCTFail("hata bekleniyordu") }
        catch { XCTAssertEqual(error as? VeribenimError, .http(status: 404)) }
    }

    /// `PreferenceCenterController::show` yanıtının tamamı (gerçek alan adlarıyla).
    func testDecodesFullServerResponse() throws {
        let body = """
        {"status":true,"environment_name":"Penyu","environment_url":"https://penyu.test",
         "banner_settings":{"position":"bottom","reconsent_days":365,"follow_system_color_scheme":true},
         "active_regulations":["kvkk","gdpr"],
         "categories":[{"id":"strictly_necessary","label":"Zorunlu Çerezler","label_en":"Strictly Necessary","required":true,"cookies":[]},
                       {"id":"analytics","label":"Analitik Çerezler","label_en":"Analytics","required":false,
                        "cookies":[{"id":7,"name":"Firebase","description":"","mandatory":false,"is_enabled_by_default":false,"storage_type":"device_id"}]}],
         "current_consents":{"strictly_necessary":true,"analytics":true,"functional":false,"marketing":false},
         "platform":"mobile"}
        """
        let r = try JSONDecoder().decode(PreferencesResponse.self, from: Data(body.utf8))
        XCTAssertEqual(r.environmentName, "Penyu")
        XCTAssertEqual(r.categories.map(\.id), ["strictly_necessary", "analytics"])
        XCTAssertEqual(r.categories[1].cookies.first?.storageType, "device_id")
        XCTAssertEqual(r.currentConsents?["analytics"], true)
        XCTAssertEqual(r.bannerSettings?["position"]?.value, "bottom")
    }

    /// Boş PHP dizisi `[]`, kayıt yoksa `null` — ikisi de çözmeyi düşürmemeli.
    func testToleratesEmptyAndNullFreeformFields() throws {
        let body = #"{"status":true,"banner_settings":[],"categories":[],"current_consents":null}"#
        let r = try JSONDecoder().decode(PreferencesResponse.self, from: Data(body.utf8))
        XCTAssertNil(r.bannerSettings)
        XCTAssertNil(r.currentConsents)
    }
}
