# VeribenimKit (iOS / Swift)

KVKK & GDPR rıza yönetimi — native iOS uygulamaları için. Web SDK'sı
(`@veribenim/core`) tarayıcıya bağlıdır ve mobilde çalışmaz; bu paket onun
native karşılığıdır.

Sıfır üçüncü parti bağımlılık.

## Kurulum

```swift
.package(url: "https://github.com/Pariette-Inc/veribenim.swift.sdk", from: "1.0.0")
```

## Konsol kurulumu

Ürününüzün (sitenizin) konsolunda **Uygulamalar** ekranından iOS ve/veya Android
sürümünü ekleyin (`mobile_consent` modülü gerekir; ürün başına bir kez satılır,
iki platformu da kapsar). SDK'daki `appIdentifier` konsolda girilen bundle id /
package name ile **birebir** aynı olmalı — el sıkışma kimlik + platform çiftiyle
eşleşir. Aynı kimlik iOS ve Android için ayrı iki kayıt olarak eklenir.

## Kullanım

```swift
let vb = Veribenim(config: .init(appIdentifier: "com.ornek.uygulama"))

if await vb.needsConsent() {
    // Kendi rıza ekranınızı gösterin.
    // Kategori metinleri sunucudan: try await vb.refresh()
}

await vb.accept(.granted)          // veya .init(functional: true, analytics: true)
await vb.rejectAll()

if await vb.isAllowed(.analytics) {
    FirebaseAnalytics.setAnalyticsCollectionEnabled(true)
}
```

### Yapılandırma

```swift
Veribenim(config: .init(
    appIdentifier: "com.ornek.uygulama",
    baseURL: URL(string: "https://live.veribenim.com")!, // varsayılan; staging / proxy için değiştirin
    appVersion: nil,   // nil → CFBundleShortVersionString
    userAgent: nil     // nil → "VeribenimSDK/1.0.0 (ios <sürüm>; swift)"
))
```

Varsayılan depo `UserDefaultsConsentStorage`'dır (cihaz sırrı dahil). Sırrı
Keychain'de tutmak isterseniz kendi `ConsentStorage` uygulamanızı verin.

### Google Consent Mode v2

```swift
await vb.onConsentChange { prefs in
    Analytics.setConsent([
        .analyticsStorage: prefs.analytics ? .granted : .denied,
        .adStorage:        prefs.marketing ? .granted : .denied,
        .adUserData:       prefs.marketing ? .granted : .denied,
        .adPersonalization:prefs.marketing ? .granted : .denied,
    ])
}
```

### ATT sırası (önemli)

Apple, ATT prompt'undan önce kendi izin ekranınızı göstermenize izin verir ama
ATT'yi **atlamanıza** izin vermez. Doğru sıra:

```swift
await vb.accept(prefs)
if await vb.shouldRequestTracking {
    ATTrackingManager.requestTrackingAuthorization { _ in }
}
```

SDK ATT'yi kendisi çağırmaz — yalnızca ne zaman çağırmanız gerektiğini söyler.
Ters sıra App Store reddi sebebidir.

## Tasarım notları

- **Önce diske, sonra ağa.** Ziyaretçinin kararı ağ hatasında kaybolmaz; banner
  bir sonraki açılışta ikinci kez çıkmaz.
- **Offline kuyruk.** Gönderilemeyen rıza kaydı diskte bekler. Rıza ispatı
  (KVKK Md.3) veri sorumlusundadır — kaybolmamalı.
- **İmzalı istekler.** Her rıza kaydı HMAC-SHA256 ile imzalanır; imza gövdeyi ve
  zaman damgasını kapsar. Sunucu karşılığı `AppDeviceSession::verifySignature`.
- **`strictlyNecessary` ayarlanamaz.** Reddedilemeyen bir kategoriyi ayarlanabilir
  göstermek yanıltıcıdır.

## Sunucu sözleşmesi

Dört mobil SDK (Swift, Kotlin, Flutter, React Native) aynı sözleşmeyi uygular;
kaynak `veribenim.api` (`AppSessionController`, `ConsentController::log`,
`EnvironmentOriginCheck`, `PreferenceCenterController::show`).

| Adım | İstek | Not |
|---|---|---|
| El sıkışma | `POST /api/app/session` `{app_identifier, platform, app_version?, os_version?}` | İmzasız. Yanıt `{token, device_token, secret, expires_at}`; 30 gün geçerli. 404 = bilinmeyen uygulama **veya** `mobile_consent` modülü kapalı (sunucu bilerek ayırmaz). |
| Rıza kaydı | `POST /api/v/{token}/c` `{action, consents, session_id, user_agent}` | `X-VB-App`, `X-VB-Timestamp` (saniye), `X-VB-Signature` = HMAC-SHA256(`secret`, `"{device_token}.{timestamp}.{ham gövde}"`). Sunucu ±300 sn kabul eder. `Origin`/`Referer` gönderilmez. |
| Tercih okuma | `GET /api/preferences/{token}?platform=mobile&session_id=…` | İmzasız. Kategoriler, mobil kapsamlı izleyiciler, `current_consents`. |

- `platform` rıza gövdesinde **gönderilmez**: sunucu damgayı imzalı cihaz oturumundan okur.
- `user_agent` **şarttır**: sunucu boş değeri bot sayar ve kayıt raporlardan düşer.
  Varsayılan `VeribenimSDK/<sürüm> (<platform> <os>; <dil>)`; yapılandırmadan değiştirilebilir.
- Hata işleme (çevrimdışı kuyruk):
  - 403 / 404 → cihaz oturumu atılır, **bir kez** yeniden el sıkışılır ve aynı kayıt
    yeniden denenir (oturum iptali, süre dolumu, ürün devri).
  - 400 / 422 → kalıcı ret; kayıt atılır, kuyruğu tıkamaz.
  - 402 (kota dolu), 429, 5xx, ağ hatası → kayıt kuyrukta kalır, **sıra korunur**
    (ilk kayıt gidemezse sonrakiler gönderilmez).
- Aynı anda tek kuyruk boşaltma çalışır; boşaltma sürerken verilen karar kaybolmaz.

## Test

```bash
swift test
```
