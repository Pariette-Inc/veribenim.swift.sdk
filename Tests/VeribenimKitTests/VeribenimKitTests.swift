import XCTest
@testable import VeribenimKit

/// Sahte taşıyıcı — istekleri kaydeder, hazır yanıt döner.
final class StubTransport: Transport, @unchecked Sendable {
    var responses: [(Data, Int)] = []
    private(set) var requests: [URLRequest] = []
    private(set) var bodies: [Data] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        bodies.append(request.httpBody ?? Data())

        guard !responses.isEmpty else { throw VeribenimError.invalidResponse }
        let (data, status) = responses.removeFirst()

        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (data, http)
    }
}

private let handshakeJSON = """
{"status":true,"token":"env-token","device_token":"dev-token","secret":"s3cr3t","expires_at":"2099-01-01T00:00:00+00:00"}
"""

final class SignatureTests: XCTestCase {
    /// Sunucudaki `AppDeviceSession::verifySignature` ile BİREBİR aynı dizeyi
    /// imzaladığımızın kanıtı. Bu bozulursa her native istek 403 döner.
    func testSignatureMatchesServerAlgorithm() {
        let sig = RequestSigner.signature(
            deviceToken: "dev-token",
            secret: "s3cr3t",
            timestamp: 1_700_000_000,
            body: Data(#"{"action":"accept_all"}"#.utf8)
        )

        // Beklenen değer PHP'nin kendisinden alındı — uydurulmuş bir sabit değil:
        //   php -r 'echo hash_hmac("sha256",
        //     "dev-token.1700000000." . json_encode(["action"=>"accept_all"]), "s3cr3t");'
        XCTAssertEqual(sig, "78ae089b104fd31c6509393ffd15e1b9c4875b43877de1a69bcf55399bbe9ff7")
    }

    func testSignatureChangesWithBody() {
        let a = RequestSigner.signature(deviceToken: "d", secret: "s", timestamp: 1, body: Data("a".utf8))
        let b = RequestSigner.signature(deviceToken: "d", secret: "s", timestamp: 1, body: Data("b".utf8))
        XCTAssertNotEqual(a, b, "Gövde imzaya girmezse imza başka bir isteğe yapıştırılabilir.")
    }

    func testHeadersCarryAllThreeFields() {
        let session = DeviceSession(
            environmentToken: "e", deviceToken: "d", secret: "s",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        let headers = RequestSigner.headers(for: session, body: Data())

        XCTAssertEqual(headers[RequestSigner.appHeader], "d")
        XCTAssertNotNil(headers[RequestSigner.timestampHeader])
        XCTAssertNotNil(headers[RequestSigner.signatureHeader])
    }
}

final class ConsentModelTests: XCTestCase {
    func testStrictlyNecessaryCannotBeDisabled() {
        var prefs = ConsentPreferences.denied
        prefs[.strictlyNecessary] = false
        XCTAssertTrue(prefs[.strictlyNecessary])
        XCTAssertTrue(prefs.payload["strictly_necessary"] == true)
    }

    func testPayloadRoundTrip() {
        let prefs = ConsentPreferences(functional: true, analytics: false, marketing: true)
        XCTAssertEqual(ConsentPreferences(payload: prefs.payload), prefs)
    }
}

final class ConsentFlowTests: XCTestCase {
    private func makeSDK(_ transport: StubTransport, storage: ConsentStorage = InMemoryConsentStorage()) -> Veribenim {
        Veribenim(
            config: .init(appIdentifier: "com.ornek.uygulama", baseURL: URL(string: "https://api.test")!),
            storage: storage,
            transport: transport
        )
    }

    func testNeedsConsentBeforeAnyDecision() async {
        let sdk = makeSDK(StubTransport())
        let needs = await sdk.needsConsent()
        XCTAssertTrue(needs)
    }

    func testAcceptPersistsAndUnlocksCategories() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]

        let storage = InMemoryConsentStorage()
        let sdk = makeSDK(transport, storage: storage)

        await sdk.accept(.granted)

        let needs = await sdk.needsConsent()
        let analytics = await sdk.isAllowed(.analytics)

        XCTAssertFalse(needs)
        XCTAssertTrue(analytics)
        XCTAssertNotNil(storage.loadRecord())
        XCTAssertTrue(storage.loadQueue().isEmpty, "Başarılı gönderimden sonra kuyruk boşalmalı.")
    }

    func testRejectBlocksEverythingButNecessary() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]
        let sdk = makeSDK(transport)

        await sdk.rejectAll()

        let analytics = await sdk.isAllowed(.analytics)
        let marketing = await sdk.isAllowed(.marketing)
        let necessary = await sdk.isAllowed(.strictlyNecessary)

        XCTAssertFalse(analytics)
        XCTAssertFalse(marketing)
        XCTAssertTrue(necessary)
    }

    /// Ağ yokken karar KAYBOLMAMALI — rıza ispatı veri sorumlusundadır.
    func testConsentSurvivesNetworkFailure() async {
        let transport = StubTransport()   // yanıt yok → her istek hata
        let storage = InMemoryConsentStorage()
        let sdk = makeSDK(transport, storage: storage)

        await sdk.accept(.granted)

        let needs = await sdk.needsConsent()
        XCTAssertFalse(needs, "Ağ hatası kullanıcıya soruyu ikinci kez sordurmamalı.")
        XCTAssertEqual(storage.loadQueue().count, 1, "Gönderilemeyen kayıt kuyrukta beklemeli.")
    }

    func testQueueDrainsOnNextFlush() async {
        let transport = StubTransport()
        let storage = InMemoryConsentStorage()
        let sdk = makeSDK(transport, storage: storage)

        await sdk.accept(.granted)
        XCTAssertEqual(storage.loadQueue().count, 1)

        // Ağ geri geldi.
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]
        await sdk.flush()

        XCTAssertTrue(storage.loadQueue().isEmpty)
    }

    /// 403 = oturum düşmüş veya modül kapanmış. Oturum atılır, kayıt korunur.
    func testForbiddenDropsSessionButKeepsRecord() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 403)]

        let storage = InMemoryConsentStorage()
        let sdk = makeSDK(transport, storage: storage)

        await sdk.accept(.granted)

        XCTAssertNil(storage.loadSession(), "403 sonrası cihaz oturumu atılmalı.")
        XCTAssertEqual(storage.loadQueue().count, 1, "Rıza kaydı silinmemeli.")
    }

    func testTrackingPromptOnlyAfterMarketingConsent() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]
        let sdk = makeSDK(transport)

        await sdk.accept(ConsentPreferences(functional: true, analytics: true, marketing: false))
        var shouldAsk = await sdk.shouldRequestTracking
        XCTAssertFalse(shouldAsk, "Pazarlamayı reddedene ATT sorulmaz.")

        transport.responses = [(Data("{}".utf8), 200)]
        await sdk.accept(.granted)
        shouldAsk = await sdk.shouldRequestTracking
        XCTAssertTrue(shouldAsk)
    }

    func testObserverFiresOnChange() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]
        let sdk = makeSDK(transport)

        final class Box: @unchecked Sendable { var values: [ConsentPreferences] = [] }
        let box = Box()

        await sdk.onConsentChange { box.values.append($0) }
        await sdk.accept(.granted)

        XCTAssertEqual(box.values.count, 2, "İlk çağrı mevcut durumu, ikincisi değişikliği taşır.")
        XCTAssertTrue(box.values.last?.analytics == true)
    }

    func testSignedRequestCarriesHeaders() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]
        let sdk = makeSDK(transport)

        await sdk.accept(.granted)

        let consentRequest = transport.requests.last!
        XCTAssertEqual(consentRequest.url?.path, "/api/v/env-token/c")
        XCTAssertNotNil(consentRequest.value(forHTTPHeaderField: RequestSigner.signatureHeader))

        // İmza, gönderilen gövdenin TAM baytları üzerinden üretilmiş olmalı.
        let body = transport.bodies.last!
        let ts = consentRequest.value(forHTTPHeaderField: RequestSigner.timestampHeader)!
        let expected = RequestSigner.signature(
            deviceToken: "dev-token", secret: "s3cr3t", timestamp: Int(ts)!, body: body
        )
        XCTAssertEqual(consentRequest.value(forHTTPHeaderField: RequestSigner.signatureHeader), expected)
    }

    func testHandshakeIsUnsigned() async {
        let transport = StubTransport()
        transport.responses = [(Data(handshakeJSON.utf8), 200), (Data("{}".utf8), 200)]
        let sdk = makeSDK(transport)

        await sdk.accept(.granted)

        let handshake = transport.requests.first!
        XCTAssertEqual(handshake.url?.path, "/api/app/session")
        XCTAssertNil(
            handshake.value(forHTTPHeaderField: RequestSigner.signatureHeader),
            "El sıkışma imzasızdır — imzalayacak sır henüz yok."
        )
    }
}

final class PreferencesDecodingTests: XCTestCase {
    func testDecodesMobileStorageType() throws {
        let json = """
        {"status":true,"environment_name":"Uygulama","platform":"mobile","categories":[
          {"id":"analytics","label":"Analitik","label_en":"Analytics","required":false,
           "cookies":[{"id":1,"name":"Firebase","description":"Ölçüm","storage_type":"device_id"}]}
        ]}
        """
        let decoded = try JSONDecoder().decode(PreferencesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.platform, "mobile")
        XCTAssertEqual(decoded.categories.first?.cookies.first?.storageType, "device_id")
    }
}
